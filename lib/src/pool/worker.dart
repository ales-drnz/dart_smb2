// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The main isolate's proxy for one worker isolate.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../smb2_cancel_token.dart';
import '../smb2_error_type.dart';
import '../smb2_exception.dart';
import 'protocol.dart';
import 'worker_main.dart';

/// One worker isolate: its connection, the requests it is serving, and
/// the replies nobody waits for any more.
///
/// Requests run one at a time, in the order sent. Every reply comes back
/// on one port and is matched to its request by id.
///
/// The native buffer of a write belongs to this side: the worker only
/// reads it, and it is freed here when the reply arrives, when the request
/// is never sent, or once the isolate has exited — never while the worker
/// may still be writing it out.
final class Worker {
  final Isolate _isolate;
  final RawReceivePort _port;
  final SendPort _commands;

  final Map<int, _Pending<Object?>> _pending = {};

  /// Requests whose caller gave up (cancelled): their replies are freed on
  /// arrival.
  final Map<int, _Abandoned> _abandoned = {};

  /// Write buffers of requests the isolate never answered: freed once it
  /// has exited.
  final List<int> _orphans = [];
  int _nextId = 1;
  bool _dead = false;
  bool _exited = false;
  Completer<void>? _closing;

  Worker._(this._isolate, this._port, this._commands);

  /// Workers spawning or alive, in this isolate. For tests that check
  /// nothing outlives a pool.
  @visibleForTesting
  static int debugAlive = 0;

  /// Makes the next spawned workers exit before connecting, as a crash
  /// would. For tests.
  @visibleForTesting
  static bool debugExitBeforeConnect = false;

  /// Makes the next spawned workers never answer, as a hung isolate would.
  /// For tests.
  @visibleForTesting
  static bool debugNeverReady = false;

  /// How long a spawn waits beyond the connection timeout for an isolate
  /// that never answers. Shortened by tests.
  @visibleForTesting
  static Duration debugSpawnMargin = const Duration(seconds: 15);

  /// Write buffers freed so far, in this isolate. For tests that check
  /// every buffer is freed exactly once.
  @visibleForTesting
  static int debugBuffersFreed = 0;

  /// Called when the worker is lost without the caller of a pending
  /// request learning it: the isolate died while not closing, or a request
  /// whose caller cancelled failed with a network failure. The pool
  /// reconnects the slot.
  void Function()? onLost;

  /// Whether the isolate has exited, or [close] was called.
  bool get isDead => _dead;

  /// Whether the worker takes requests: not dead and not closing.
  bool get isUsable => !_dead && _closing == null;

  /// Requests sent and not answered yet, those whose caller cancelled
  /// included: the worker still runs them, in order.
  int get load => _pending.length + _abandoned.length;

  /// Spawns a worker and waits until it is connected.
  ///
  /// Throws the connection's own [Smb2Exception] (auth, not found, ...)
  /// when it fails, and one of type [Smb2ErrorType.connection] when the
  /// isolate dies first, for example because libsmb2 cannot be loaded.
  /// When [abort] is cancelled first, the isolate is killed and the spawn
  /// fails with a [Smb2ErrorType.state] error.
  static Future<Worker> spawn(
    ConnectParams params, {
    Smb2CancelToken? abort,
  }) async {
    debugAlive++;
    try {
      return await _spawn(params, abort);
    } catch (_) {
      debugAlive--;
      rethrow;
    }
  }

  static Future<Worker> _spawn(
    ConnectParams params,
    Smb2CancelToken? abort,
  ) async {
    final first = Completer<Object?>();
    final port = RawReceivePort((Object? m) {
      if (!first.isCompleted) first.complete(m);
    }, 'dart_smb2 worker replies');
    Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        workerMain,
        Init(
          port.sendPort,
          params,
          exitBeforeConnect: debugExitBeforeConnect,
          neverReady: debugNeverReady,
        ),
        onExit: port.sendPort,
        onError: port.sendPort,
        debugName: 'dart_smb2 worker',
      );
    } catch (e) {
      port.close();
      throw Smb2Exception(
        'Cannot spawn a worker isolate: $e',
        type: Smb2ErrorType.state,
        cause: e,
      );
    }

    // The connect itself is bounded by params.timeout inside libsmb2; this
    // is a margin for an isolate that never answers at all.
    final limit = params.timeout + debugSpawnMargin;
    // The abort is a token so the listener goes away with the spawn.
    final unregister =
        abort?.register(() {
          if (!first.isCompleted) first.complete(_aborted);
        }) ??
        _noop;
    if (abort != null && abort.isCancelled && !first.isCompleted) {
      first.complete(_aborted);
    }
    Object? reply;
    try {
      reply = await first.future.timeout(limit);
    } on TimeoutException {
      reply = _timedOut;
    } finally {
      unregister();
    }

    if (reply is Ready) {
      final worker = Worker._(isolate, port, reply.commands);
      port.handler = worker._receive;
      return worker;
    }

    isolate.kill(priority: Isolate.immediate);
    port.close();
    throw switch (reply) {
      _aborted => const Smb2Exception(
        'The pool closed while the worker was connecting',
        type: Smb2ErrorType.state,
      ),
      Failure() => reply.toException(),
      _timedOut => Smb2Exception(
        'The worker did not connect within $limit',
        type: Smb2ErrorType.timeout,
      ),
      // onError delivers [error, stack]; onExit delivers null after it.
      List<Object?>(:final first) => Smb2Exception(
        'The worker isolate failed while connecting: $first',
        type: Smb2ErrorType.connection,
        cause: first,
      ),
      _ => Smb2Exception(
        'The worker isolate exited while connecting',
        type: Smb2ErrorType.connection,
        cause: reply,
      ),
    };
  }

  /// Sends [op] with [args] and returns its result. Byte results arrive as
  /// [Uint8List]s over the worker's native buffers, without a copy.
  ///
  /// When [cancelToken] is cancelled first, completes with the
  /// cancellation at once; the worker still finishes the request, and its
  /// result is freed (a handle it opened is closed).
  ///
  /// A write's native buffer (`args[1]`) stays this side's: it is freed
  /// here when the reply arrives, at once when the request is not sent,
  /// and once the isolate has exited when the worker never answers.
  ///
  /// Once [close] has started, fails at once with a
  /// [Smb2ErrorType.connection] error, like a dead worker: the worker
  /// would never run the request.
  Future<T> call<T>(
    Op op,
    List<Object?> args, {
    Smb2CancelToken? cancelToken,
    String? path,
  }) => _send(op, args, cancelToken: cancelToken, path: path);

  Future<T> _send<T>(
    Op op,
    List<Object?> args, {
    Smb2CancelToken? cancelToken,
    String? path,
    bool closing = false,
  }) {
    final buffer = _writeBuffer(op, args);
    if (cancelToken != null && cancelToken.isCancelled) {
      _free(buffer);
      return Future.error(cancelToken.cancelledException(path: path));
    }
    if (_dead || (_closing != null && !closing)) {
      _free(buffer);
      return Future.error(_gone(path));
    }
    final id = _nextId++;
    final pending = _Pending<T>(op, path, buffer);
    _pending[id] = pending;
    if (cancelToken != null) {
      pending.unregister = cancelToken.register(() {
        if (_pending.remove(id) == null) return;
        _abandoned[id] = _Abandoned(op, buffer);
        pending.completer.completeError(
          cancelToken.cancelledException(path: path),
        );
      });
    }
    _commands.send(Request(id, op, args));
    return pending.completer.future;
  }

  /// Sends [op], which carries no buffer, without waiting for a reply.
  void post(Op op, List<Object?> args) {
    if (_dead) return;
    _commands.send(Request(0, op, args));
  }

  void _receive(Object? message) {
    switch (message) {
      case Reply(:final id, :final value):
        final pending = _pending.remove(id);
        if (pending == null) {
          final abandoned = _abandoned.remove(id);
          _free(abandoned?.buffer);
          _dispose(abandoned?.op, value);
          return;
        }
        _free(pending.buffer);
        pending.unregister?.call();
        if (_dead) {
          _dispose(pending.op, value);
        } else {
          pending.complete(_unwrap(value));
        }
      case Failure(:final id):
        final abandoned = _abandoned.remove(id);
        _free(abandoned?.buffer);
        if (abandoned != null && message.toException().isNetworkFailure) {
          onLost?.call();
        }
        final pending = _pending.remove(id);
        _free(pending?.buffer);
        pending?.unregister?.call();
        pending?.completer.completeError(message.toException());
      case null:
        // onExit: the isolate is gone, and with it any use of the buffers.
        final unexpected = !_dead && _closing == null;
        _markDead(null);
        if (unexpected) onLost?.call();
        _exited = true;
        _orphans.forEach(_free);
        _orphans.clear();
        _port.close();
      default:
        // onError ([error, stack]): the isolate is ending; onExit follows.
        final unexpected = !_dead && _closing == null;
        _markDead(message);
        if (unexpected) onLost?.call();
    }
  }

  /// Asks the worker to close its handles and log off, then ends the
  /// isolate. The logoff gets 5 seconds; a worker stuck in a call is
  /// killed. Requests sent before it finish first; requests still pending
  /// when the worker is killed fail with a [Smb2ErrorType.connection]
  /// error, and their buffers are freed once the isolate has exited. A read
  /// the worker was in the middle of when killed loses its buffer.
  Future<void> close() async {
    if (_closing != null) return _closing!.future;
    final closing = _closing = Completer<void>();
    if (!_dead) {
      try {
        await _send<void>(
          Op.close,
          const [],
          closing: true,
        ).timeout(const Duration(seconds: 5));
      } catch (_) {
        // Dead, stuck or failing: kill it below either way.
      }
    }
    _isolate.kill(priority: Isolate.immediate);
    _markDead(null);
    closing.complete();
  }

  /// Ends the isolate without the logoff, as a crash would. For tests.
  @visibleForTesting
  void killForTest() {
    _isolate.kill(priority: Isolate.immediate);
    _markDead(null);
  }

  /// Write buffers held for requests the isolate never answered. For
  /// tests.
  @visibleForTesting
  int get debugHeldBuffers =>
      _orphans.length +
      _pending.values.where((p) => p.buffer != null).length +
      _abandoned.values.where((a) => a.buffer != null).length;

  void _markDead(Object? cause) {
    if (_dead) return;
    _dead = true;
    debugAlive--;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final p in pending) {
      if (p.buffer != null) _orphans.add(p.buffer!);
      p.unregister?.call();
      p.completer.completeError(_gone(p.path, cause));
    }
    for (final a in _abandoned.values) {
      if (a.buffer != null) _orphans.add(a.buffer!);
    }
    _abandoned.clear();
    if (_exited) {
      _orphans.forEach(_free);
      _orphans.clear();
    } else {
      // Wait for onExit to free the orphans, without keeping this isolate
      // alive for a worker that never exits.
      _port.keepIsolateAlive = false;
    }
  }

  Smb2Exception _gone(String? path, [Object? cause]) => Smb2Exception(
    'The worker isolate is gone',
    type: Smb2ErrorType.connection,
    path: path,
    cause: cause,
  );

  /// Frees what an abandoned request returned.
  void _dispose(Op? op, Object? value) {
    switch (value) {
      case NativeBytes(:final address) when address != 0:
        malloc.free(Pointer<Uint8>.fromAddress(address));
      case final int id when op != null && op.opensHandle:
        post(Op.closeHandle, [id]);
      case (final int id, int _) when op == Op.openWithSize:
        post(Op.closeHandle, [id]);
    }
  }
}

/// The reply a spawn gets when it is aborted.
const Object _aborted = #aborted;

/// The reply a spawn gets when the worker never answers.
const Object _timedOut = #timedOut;

/// Wraps a [NativeBytes] reply as a [Uint8List] that frees the buffer when
/// it is collected.
Object? _unwrap(Object? value) => switch (value) {
  NativeBytes(:final length) when length == 0 => Uint8List(0),
  NativeBytes(:final address, :final length) => Pointer<Uint8>.fromAddress(
    address,
  ).asTypedList(length, finalizer: malloc.nativeFree),
  _ => value,
};

/// The native buffer a write request carries, if [op] is a write.
int? _writeBuffer(Op op, List<Object?> args) =>
    op.carriesBuffer ? args[1]! as int : null;

void _free(int? buffer) {
  if (buffer == null) return;
  malloc.free(Pointer<Uint8>.fromAddress(buffer));
  Worker.debugBuffersFreed++;
}

void _noop() {}

final class _Pending<T> {
  final Op op;
  final String? path;
  final int? buffer;
  final Completer<T> completer = Completer<T>();
  void Function()? unregister;
  _Pending(this.op, this.path, this.buffer);

  void complete(Object? value) => completer.complete(value as T);
}

final class _Abandoned {
  final Op op;
  final int? buffer;
  const _Abandoned(this.op, this.buffer);
}
