// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Files opened through a [Smb2Pool].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../smb2_cancel_token.dart';
import '../smb2_error_type.dart';
import '../smb2_exception.dart';
import 'pool.dart';
import 'protocol.dart';
import 'worker.dart';

/// A worker slot of a pool: the worker serving it now, and how many times
/// it has been replaced.
@internal
final class Slot {
  /// The worker serving the slot now.
  Worker worker;

  /// How many times [worker] has been replaced.
  int generation = 0;

  /// The replacement being connected, while there is one.
  Future<Worker>? reconnecting;

  /// The background retry after a failed reconnect, while one is due.
  Timer? retry;

  /// Reconnects that failed in a row, for the retry's backoff.
  int failures = 0;

  /// A slot served by [worker].
  Slot(this.worker);
}

/// A file opened through a [Smb2Pool], bound to one of its workers.
///
/// Pass it back to the pool's handle methods ([Smb2Pool.readFromHandle],
/// [Smb2Pool.writeToHandle], [Smb2Pool.closeHandle], ...), or let
/// [Smb2Pool.withFile] and the streaming helpers manage it.
///
/// When the worker's connection drops, the pool reconnects it and opens
/// the file again before the next call on the handle, so a handle outlives
/// a reconnect. Once closed it stays closed: closing it again does nothing,
/// and any other use throws a [Smb2Exception] of type
/// [Smb2ErrorType.state]. A handle dropped without being closed is closed
/// when it is garbage collected.
final class Smb2PoolHandle {
  /// The share-relative path the handle was opened for.
  final String path;

  /// Whether the handle writes (it was opened with
  /// [Smb2Pool.openFileWrite]).
  final bool writable;

  final Slot _slot;
  int _generation;
  int _id;
  bool _closed = false;
  Future<void>? _reopening;

  Smb2PoolHandle._(this._slot, this._id, this.path, {required this.writable})
    : _generation = _slot.generation {
    _finalizer.attach(this, _Leak(_slot.worker, _id), detach: this);
  }

  /// Whether [Smb2Pool.closeHandle] was called on the handle.
  bool get isClosed => _closed;

  /// Same as [isClosed].
  @Deprecated('Use isClosed. Will be removed in 0.3.0.')
  bool get closed => _closed;

  /// Does nothing: the pool keeps the finalizer up to date by itself.
  @Deprecated('Not needed any more. Will be removed in 0.3.0.')
  void refreshFinalizer() {}

  static final _finalizer = Finalizer<_Leak>(
    (leak) => leak.worker.post(Op.closeHandle, [leak.id]),
  );
}

/// The worker and id of a handle, for the finalizer (which must not keep
/// the handle itself alive).
final class _Leak {
  final Worker worker;
  final int id;
  const _Leak(this.worker, this.id);
}

/// Package-private access to [Smb2PoolHandle] for the pool.
@internal
extension Smb2PoolHandleInternal on Smb2PoolHandle {
  /// A handle on [slot] for the worker-local [id].
  static Smb2PoolHandle create(
    Slot slot,
    int id,
    String path, {
    required bool writable,
  }) => Smb2PoolHandle._(slot, id, path, writable: writable);

  /// The slot whose worker holds the file.
  Slot get slot => _slot;

  /// The worker-local id of the open file.
  int get id => _id;

  /// Whether the slot's worker was replaced since the file was opened.
  bool get isStale => _generation != _slot.generation;

  /// Marks the handle closed and returns the worker and id to close it
  /// on, or null when it was closed already.
  (Worker, int)? markClosed() {
    if (_closed) return null;
    _closed = true;
    Smb2PoolHandle._finalizer.detach(this);
    return isStale ? null : (_slot.worker, _id);
  }

  /// Opens the file again on the slot's current worker, once for any
  /// number of concurrent callers.
  Future<void> reopen(Future<int> Function(Worker worker) open) {
    return _reopening ??= () async {
      try {
        final worker = _slot.worker;
        final generation = _slot.generation;
        final id = await open(worker);
        if (_closed) {
          worker.post(Op.closeHandle, [id]);
          throw Smb2Exception(
            'The handle was closed while it was opened again',
            type: Smb2ErrorType.state,
            path: path,
          );
        }
        _id = id;
        _generation = generation;
        Smb2PoolHandle._finalizer
          ..detach(this)
          ..attach(this, _Leak(worker, id), detach: this);
      } finally {
        _reopening = null;
      }
    }();
  }
}

/// A file opened by [Smb2Pool.withFile], valid inside its callback.
final class Smb2File {
  final Smb2Pool _pool;
  final Smb2PoolHandle _handle;
  final Smb2CancelToken? _cancelToken;

  /// Size in bytes when the file was opened (or the `knownSize` passed to
  /// [Smb2Pool.withFile]).
  final int size;

  /// Wraps an open pool handle for the callback of [Smb2Pool.withFile].
  @internal
  Smb2File(this._pool, this._handle, this.size, [this._cancelToken]);

  /// The share-relative path of the file.
  String get path => _handle.path;

  /// Reads [length] bytes at [offset]: fewer only when the file ends first.
  /// Same as [Smb2Pool.readFromHandle], reconnecting when needed.
  Future<Uint8List> read({int offset = 0, required int length}) =>
      _pool.readFromHandle(
        _handle,
        offset: offset,
        length: length,
        cancelToken: _cancelToken,
      );
}
