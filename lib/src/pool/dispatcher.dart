// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The state of a pool and how a call reaches a worker: the slots, the
/// dispatch, the reconnects and the closes still in flight.
part of 'pool.dart';

/// What every part of [Smb2Pool] works on: its workers and its dispatch.
abstract class _PoolCore {
  _PoolCore(this._slots, this._params);

  final List<Slot> _slots;
  final ConnectParams _params;
  final Set<Future<void>> _reconnects = {};

  /// Stops the watches in progress, for [Smb2Pool.disconnect].
  final Set<Future<void> Function()> _watches = {};

  /// Closes still on their way to the server, by path: a call that would
  /// conflict with the open file waits for them (see [_mutates]).
  final Map<String, Future<void>> _pendingCloses = {};

  /// The server's refusal of the last reconnect (credentials, the share),
  /// while it stands: reconnects fail with it at once, without asking the
  /// server, until [_refusalRetry] tries again.
  Smb2Exception? _refusal;
  Timer? _refusalRetry;

  /// Cancelled on [Smb2Pool.disconnect], to abort the spawns of reconnects.
  final Smb2CancelToken _closing = Smb2CancelToken();
  int _next = 0;
  bool _closed = false;

  /// The [Smb2Pool.disconnect] in progress or done, for the calls after the first.
  Future<void>? _disconnecting;

  /// Reconnects [slot] when [worker] is lost without a call failing on it:
  /// its isolate died, or a request a caller cancelled hit a network
  /// failure that the requests queued behind it would hit too.
  void _watch(Slot slot, Worker worker) {
    worker.onLost = () {
      if (!_closed) _reconnect(slot, worker).ignore();
    };
  }

  /// Number of workers.
  int get workerCount => _slots.length;

  /// Whether [Smb2Pool.disconnect] has been called.
  bool get isClosed => _closed;

  /// The workers, for the concurrency tests' fault injection.
  @internal
  List<Worker> get workersForTest => [for (final s in _slots) s.worker];

  /// The closes in flight for [key], and with [below] for the paths in the
  /// directory [key] too.
  Iterable<Future<void>> _closesOf(String key, {required bool below}) sync* {
    for (final MapEntry(key: path, value: close) in _pendingCloses.entries) {
      if (path == key || (below && path.startsWith('$key/'))) yield close;
    }
  }

  void _ensureOpen(String? path) {
    if (_closed) {
      throw Smb2Exception(
        'The pool is closed',
        type: Smb2ErrorType.state,
        path: path,
      );
    }
  }

  /// The least busy slot that is not reconnecting (round robin among
  /// equals), preferring live workers to ones whose reconnect failed; null
  /// when every slot is reconnecting.
  Slot? _pickNow() {
    final start = _next++;
    Slot? best;
    for (var i = 0; i < _slots.length; i++) {
      final slot = _slots[(start + i) % _slots.length];
      if (slot.reconnecting != null) continue;
      if (best == null || _better(slot, best)) best = slot;
    }
    return best;
  }

  static bool _better(Slot a, Slot b) {
    final aLive = a.worker.isUsable, bLive = b.worker.isUsable;
    if (aLive != bLive) return aLive;
    return a.worker.load < b.worker.load;
  }

  /// The first slot to finish reconnecting.
  Future<Slot> _pickLater() async {
    while (true) {
      await Future.any(
        _slots.map((s) => s.reconnecting ?? Future<void>.value()),
      ).catchError((Object _) {});
      _ensureOpen(null);
      final slot = _pickNow();
      if (slot != null) return slot;
    }
  }

  /// Runs [op] on the least busy worker, reconnecting and repeating once
  /// after a network failure when [idempotent]. [args] is a list, or a
  /// function that builds it (for writes, whose native buffer each attempt
  /// consumes).
  Future<T> _run<T>(
    Op op,
    Object args, {
    String? path,
    bool idempotent = true,
    Smb2CancelToken? cancelToken,
  }) => _dispatch<T, T>(
    op,
    args,
    _valueOnly,
    path: path,
    idempotent: idempotent,
    cancelToken: cancelToken,
  );

  /// Like [_run], returning [result] of the slot that answered and the
  /// value.
  ///
  /// A cancelled [cancelToken] ends the call at once, also while it waits
  /// for a slot or a reconnect.
  Future<R> _dispatch<T, R>(
    Op op,
    Object args,
    R Function(Slot slot, T value) result, {
    String? path,
    bool idempotent = true,
    Smb2CancelToken? cancelToken,
  }) async {
    _ensureOpen(path);
    cancelToken?.throwIfCancelled(path: path);
    if (_mutates.contains(op) && _pendingCloses.isNotEmpty) {
      // A rename or rmdir of a directory also waits for the files in it:
      // the server refuses one while a file below is open.
      final below = op == Op.rename || op == Op.rmdir;
      final closes = [
        for (final p in [path, if (op == Op.rename) (args as List)[1]])
          if (p is String) ..._closesOf(_pathKey(p), below: below),
      ];
      if (closes.isNotEmpty) {
        await _orCancel(Future.wait(closes), cancelToken, path);
      }
    }
    List<Object?> build() =>
        args is List<Object?> ? args : (args as List<Object?> Function())();
    Slot slot = _pickNow() ?? await _orCancel(_pickLater(), cancelToken, path);
    final worker = slot.worker;
    // A worker already dead never sends the request: repeating it is safe
    // whatever the call.
    final repeatable = idempotent || !worker.isUsable;
    try {
      return result(
        slot,
        await worker.call<T>(op, build(), cancelToken: cancelToken, path: path),
      );
    } on Smb2Exception catch (e) {
      if (!e.isNetworkFailure || _closed) rethrow;
      Worker fresh;
      try {
        fresh = await _orCancel(_reconnect(slot, worker), cancelToken, path);
      } on Smb2Exception catch (reconnect) {
        if (reconnect.isCancelled || _closed) rethrow;
        if (!repeatable) throw e;
        // The slot cannot reconnect now: repeat on another live worker, or
        // report why the reconnect failed.
        final other = _pickNow();
        if (other == null || !other.worker.isUsable) rethrow;
        slot = other;
        fresh = other.worker;
      }
      if (!repeatable) rethrow;
      cancelToken?.throwIfCancelled(path: path);
      return result(
        slot,
        await fresh.call<T>(op, build(), cancelToken: cancelToken, path: path),
      );
    }
  }

  /// Runs [op] on [handle]'s worker, reopening the file first when the
  /// worker was replaced, and reconnecting, reopening and repeating once
  /// after a network failure.
  Future<T> _onHandle<T>(
    Smb2PoolHandle handle,
    Op op,
    List<Object?> Function(int id) args, {
    Smb2CancelToken? cancelToken,
  }) async {
    final path = handle.path;
    _ensureOpen(path);
    _ensureHandleOpen(handle);
    cancelToken?.throwIfCancelled(path: path);
    final reconnecting = handle.slot.reconnecting;
    if (reconnecting != null) {
      await _orCancel(reconnecting, cancelToken, path);
      _ensureOpen(path);
      _ensureHandleOpen(handle);
    }
    if (handle.isStale) await _reopen(handle, cancelToken);
    final worker = handle.slot.worker;
    _ensureCurrent(handle);
    try {
      return await worker.call<T>(
        op,
        args(handle.id),
        cancelToken: cancelToken,
        path: path,
      );
    } on Smb2Exception catch (e) {
      if (!e.isNetworkFailure || _closed || handle.isClosed) rethrow;
      await _orCancel(_reconnect(handle.slot, worker), cancelToken, path);
      cancelToken?.throwIfCancelled(path: path);
      await _reopen(handle, cancelToken);
      _ensureCurrent(handle);
      return handle.slot.worker.call<T>(
        op,
        args(handle.id),
        cancelToken: cancelToken,
        path: path,
      );
    }
  }

  /// Opens [handle]'s file again on its slot's current worker. The open is
  /// shared by every caller that needs it, so it runs without a token;
  /// each caller's [cancelToken] ends only that caller's wait.
  Future<void> _reopen(Smb2PoolHandle handle, Smb2CancelToken? cancelToken) {
    _ensureHandleOpen(handle);
    return _orCancel(
      handle.reopen(
        (worker) => worker.call<int>(
          handle.writable ? Op.openWrite : Op.open,
          // Never truncate again: the data written so far must stay.
          handle.writable
              ? [handle.path, false, handle.temporary]
              : [handle.path],
          path: handle.path,
        ),
      ),
      cancelToken,
      handle.path,
    );
  }

  /// Fails when [handle] was closed, or could not be opened again, while
  /// the call waited for its reopen: its id would name another file.
  void _ensureCurrent(Smb2PoolHandle handle) {
    _ensureHandleOpen(handle);
    if (handle.isStale) {
      throw Smb2Exception(
        'The handle could not be opened again after a reconnect',
        type: Smb2ErrorType.state,
        path: handle.path,
      );
    }
  }

  void _ensureHandleOpen(Smb2PoolHandle handle) {
    if (handle.isClosed) {
      throw Smb2Exception(
        'The handle is closed',
        type: Smb2ErrorType.state,
        path: handle.path,
      );
    }
  }

  /// Replaces [failed], the worker of [slot], with a new connection — once
  /// for any number of callers that saw it fail.
  Future<Worker> _reconnect(Slot slot, Worker failed) {
    if (!identical(slot.worker, failed)) return Future.value(slot.worker);
    final existing = slot.reconnecting;
    if (existing != null) return existing;
    final refusal = _refusal;
    if (refusal != null) return Future.error(refusal);
    slot.retry?.cancel();
    slot.retry = null;
    final future = slot.reconnecting = _replace(slot, failed);
    final done = future.then<void>(
      (_) => slot.failures = 0,
      onError: (Object e) {
        if (e is Smb2Exception && !e.isNetworkFailure) {
          _refuse(e);
        } else {
          _scheduleRetry(slot);
        }
      },
    );
    _reconnects.add(done);
    done.whenComplete(() {
      _reconnects.remove(done);
      if (identical(slot.reconnecting, future)) slot.reconnecting = null;
    }).ignore();
    return future;
  }

  Future<Worker> _replace(Slot slot, Worker failed) async {
    await failed.close();
    _ensureOpen(null);
    final worker = await Worker.spawn(_params, abort: _closing);
    _watch(slot, worker);
    if (_closed) {
      await worker.close();
      _ensureOpen(null);
    }
    slot.worker = worker;
    slot.generation++;
    return worker;
  }

  /// Tries [slot]'s reconnect again in the background after a network
  /// failure, 1, 2, 4, ... up to 32 seconds apart, until it succeeds or the
  /// pool closes.
  void _scheduleRetry(Slot slot) {
    if (_closed) return;
    final delay = Duration(seconds: 1 << min(slot.failures++, 5));
    slot.retry = Timer(delay, () {
      slot.retry = null;
      if (_closed || slot.worker.isUsable || slot.reconnecting != null) return;
      _reconnect(slot, slot.worker).ignore();
    });
  }

  /// Holds [refusal] for every reconnect of the pool, and tries one slot
  /// again after [Smb2Pool.debugRefusedRetry]; when it connects, the other dead slots
  /// follow. One login attempt per interval, however many workers and
  /// calls, so retries do not lock an account out.
  void _refuse(Smb2Exception refusal) {
    _refusal = refusal;
    if (_closed || _refusalRetry != null) return;
    _refusalRetry = Timer(Smb2Pool.debugRefusedRetry, () async {
      _refusalRetry = null;
      _refusal = null;
      if (_closed) return;
      final dead = [
        for (final s in _slots)
          if (!s.worker.isUsable && s.reconnecting == null) s,
      ];
      if (dead.isEmpty) return;
      try {
        await _reconnect(dead.first, dead.first.worker);
      } on Object {
        return; // Refused again (a new timer is set) or the network failed.
      }
      for (final s in dead.skip(1)) {
        _reconnect(s, s.worker).ignore();
      }
    });
  }
}

/// [future], or the cancellation of [token] if that comes first. The work
/// behind [future] goes on; its outcome is dropped.
Future<T> _orCancel<T>(Future<T> future, Smb2CancelToken? token, String? path) {
  if (token == null) return future;
  if (token.isCancelled) {
    future.ignore();
    return Future.error(token.cancelledException(path: path));
  }
  final completer = Completer<T>();
  final unregister = token.register(() {
    if (!completer.isCompleted) {
      completer.completeError(token.cancelledException(path: path));
    }
  });
  unawaited(
    future.then(
      (value) {
        unregister();
        if (!completer.isCompleted) completer.complete(value);
      },
      onError: (Object e, StackTrace st) {
        unregister();
        if (!completer.isCompleted) completer.completeError(e, st);
      },
    ),
  );
  return completer.future;
}

T _valueOnly<T>(Slot _, T value) => value;

/// The calls that conflict with a file still open on the server: they wait
/// for the closes of their paths still in flight.
const _mutates = {
  Op.deleteFile,
  Op.rename,
  Op.link,
  Op.rmdir,
  Op.truncate,
  Op.setFileTimes,
  Op.writeFile,
  Op.writeRange,
  Op.openWrite,
};
