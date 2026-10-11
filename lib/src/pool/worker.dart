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
final class Worker {
  final Isolate _isolate;
  final RawReceivePort _port;
  final SendPort _commands;

  /// The largest read the server accepts in one request.
  final int maxReadSize;

  /// The largest write the server accepts in one request.
  final int maxWriteSize;

  final Map<int, _Pending<Object?>> _pending = {};

  /// Requests whose caller gave up (cancelled): their replies are freed on
  /// arrival.
  final Map<int, Op> _abandoned = {};
  int _nextId = 1;
  bool _dead = false;
  Completer<void>? _closing;

  Worker._(
    this._isolate,
    this._port,
    this._commands,
    this.maxReadSize,
    this.maxWriteSize,
  );

  /// Workers spawning or alive, in this isolate. For tests that check
  /// nothing outlives a pool.
  @visibleForTesting
  static int debugAlive = 0;

  /// Whether the isolate has exited, or [close] was called.
  bool get isDead => _dead;

  /// Requests sent and not answered yet.
  int get load => _pending.length;

  /// Spawns a worker and waits until it is connected.
  ///
  /// Throws the connection's own [Smb2Exception] (auth, not found, ...)
  /// when it fails, and one of type [Smb2ErrorType.connection] when the
  /// isolate dies first, for example because libsmb2 cannot be loaded.
  static Future<Worker> spawn(ConnectParams params) async {
    debugAlive++;
    try {
      return await _spawn(params);
    } catch (_) {
      debugAlive--;
      rethrow;
    }
  }

  static Future<Worker> _spawn(ConnectParams params) async {
    final first = Completer<Object?>();
    final port = RawReceivePort((Object? m) {
      if (!first.isCompleted) first.complete(m);
    }, 'dart_smb2 worker replies');
    Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        workerMain,
        Init(port.sendPort, params),
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
    final limit = params.timeout + const Duration(seconds: 15);
    Object? reply;
    try {
      reply = await first.future.timeout(limit);
    } on TimeoutException {
      reply = null;
    }

    if (reply is Ready) {
      final worker = Worker._(
        isolate,
        port,
        reply.commands,
        reply.maxReadSize,
        reply.maxWriteSize,
      );
      port.handler = worker._receive;
      return worker;
    }

    isolate.kill(priority: Isolate.immediate);
    port.close();
    throw switch (reply) {
      Failure() => reply.toException(),
      null => Smb2Exception(
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
  Future<T> call<T>(
    Op op,
    List<Object?> args, {
    Smb2CancelToken? cancelToken,
    String? path,
  }) {
    if (cancelToken != null && cancelToken.isCancelled) {
      _releaseArgs(op, args);
      return Future.error(cancelToken.cancelledException(path: path));
    }
    if (_dead) {
      _releaseArgs(op, args);
      return Future.error(_gone(path));
    }
    final id = _nextId++;
    final pending = _Pending<T>(op, path);
    _pending[id] = pending;
    if (cancelToken != null) {
      pending.unregister = cancelToken.register(() {
        if (_pending.remove(id) == null) return;
        _abandoned[id] = op;
        pending.completer.completeError(
          cancelToken.cancelledException(path: path),
        );
      });
    }
    _commands.send(Request(id, op, args));
    return pending.completer.future;
  }

  /// Sends [op] without waiting for a reply.
  void post(Op op, List<Object?> args) {
    if (_dead) return;
    _commands.send(Request(0, op, args));
  }

  void _receive(Object? message) {
    switch (message) {
      case Reply(:final id, :final value):
        final pending = _pending.remove(id);
        if (pending == null) {
          _dispose(_abandoned.remove(id), value);
          return;
        }
        pending.unregister?.call();
        pending.complete(_unwrap(value));
      case Failure(:final id):
        _abandoned.remove(id);
        final pending = _pending.remove(id);
        pending?.unregister?.call();
        pending?.completer.completeError(message.toException());
      default:
        // onError ([error, stack]) or onExit (null): the isolate is gone.
        _markDead(message);
    }
  }

  /// Asks the worker to close its handles and log off, then ends the
  /// isolate. The logoff gets 5 seconds; a worker stuck in a call is
  /// killed. Requests still pending fail with a connection error.
  Future<void> close() async {
    if (_closing != null) return _closing!.future;
    final closing = _closing = Completer<void>();
    if (!_dead) {
      try {
        await call<void>(
          Op.close,
          const [],
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

  void _markDead(Object? cause) {
    if (_dead) return;
    _dead = true;
    debugAlive--;
    final pending = _pending.values.toList();
    _pending.clear();
    for (final p in pending) {
      p.unregister?.call();
      p.completer.completeError(_gone(p.path, cause));
    }
    _port.close();
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

/// Wraps a [NativeBytes] reply as a [Uint8List] that frees the buffer when
/// it is collected.
Object? _unwrap(Object? value) => switch (value) {
  NativeBytes(:final length) when length == 0 => Uint8List(0),
  NativeBytes(:final address, :final length) => Pointer<Uint8>.fromAddress(
    address,
  ).asTypedList(length, finalizer: malloc.nativeFree),
  _ => value,
};

/// Frees the native buffer of a write that is never sent.
void _releaseArgs(Op op, List<Object?> args) {
  if (op == Op.writeFile || op == Op.writeRange || op == Op.writeHandle) {
    malloc.free(Pointer<Uint8>.fromAddress(args[1]! as int));
  }
}

final class _Pending<T> {
  final Op op;
  final String? path;
  final Completer<T> completer = Completer<T>();
  void Function()? unregister;
  _Pending(this.op, this.path);

  void complete(Object? value) => completer.complete(value as T);
}
