// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../smb2_cancel_token.dart';
import '../smb2_client.dart';
import '../smb2_error_type.dart';
import '../smb2_exception.dart';
import '../smb2_types.dart';
import 'handle.dart';
import 'protocol.dart';
import 'worker.dart';

export 'handle.dart' show Smb2File, Smb2PoolHandle;

/// SMB2/3 client for async code: a pool of worker isolates, each with its
/// own connection to the share.
///
/// Every method is async and safe to call from the UI isolate. Calls go to
/// the least busy worker; a file handle stays on the worker that opened it.
/// When a worker's connection drops, the pool reconnects it and repeats the
/// call once, for every call that is safe to repeat (see [connect]).
///
/// ```dart
/// final pool = await Smb2Pool.connect(
///   host: '192.168.1.10',
///   share: 'Music',
///   user: 'user',
///   password: 'pass',
/// );
/// try {
///   final entries = await pool.listDirectory('');
///   final cover = await pool.readFile('Artist/cover.jpg');
/// } finally {
///   await pool.disconnect();
/// }
/// ```
final class Smb2Pool {
  final List<Slot> _slots;
  final ConnectParams _params;
  final Set<Future<void>> _reconnects = {};
  int _next = 0;
  bool _closed = false;

  Smb2Pool._(this._slots, this._params);

  /// Connects [workers] worker isolates to [share] on [host], in parallel.
  ///
  /// [timeout] bounds every request a worker makes, the connection
  /// included; a request that runs out of it fails with
  /// [Smb2ErrorType.timeout] and the worker reconnects.
  ///
  /// After a network failure the pool reconnects the worker and repeats
  /// the call once, when repeating cannot change the outcome: reads,
  /// listings, metadata, writes at an offset, whole-file writes, truncates
  /// and timestamps. [mkdir], [rmdir], [deleteFile] and [rename] are not
  /// repeated — the server may have done them before the connection
  /// dropped — and their failure reaches the caller.
  ///
  /// Throws the first worker's [Smb2Exception] when one cannot connect
  /// (the others are closed): [Smb2ErrorType.auth] for bad credentials,
  /// [Smb2ErrorType.notFound] for a share that does not exist, a network
  /// failure for a host that does not answer.
  static Future<Smb2Pool> connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    int workers = 4,
    Duration timeout = const Duration(seconds: 30),
    @Deprecated('Use timeout. Will be removed in 0.3.0.') int? timeoutSeconds,
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
  }) async {
    if (workers < 1) {
      throw const Smb2Exception(
        'A pool needs at least one worker',
        type: Smb2ErrorType.invalidParam,
      );
    }
    final params = ConnectParams(
      host: host,
      share: share,
      user: user,
      password: password,
      domain: domain,
      timeout: timeoutSeconds != null
          ? Duration(seconds: timeoutSeconds)
          : timeout,
      seal: seal,
      signing: signing,
      version: version,
    );
    final spawned = await Future.wait(
      List.generate(workers, (_) => _spawnResult(params)),
    );
    final failure = spawned.whereType<Smb2Exception>().firstOrNull;
    if (failure != null) {
      await Future.wait(spawned.whereType<Worker>().map((w) => w.close()));
      throw failure;
    }
    return Smb2Pool._([for (final w in spawned) Slot(w as Worker)], params);
  }

  static Future<Object> _spawnResult(ConnectParams params) =>
      Worker.spawn(params).then<Object>(
        (w) => w,
        onError: (Object e) => e is Smb2Exception
            ? e
            : Smb2Exception('Cannot start a worker: $e', cause: e),
      );

  /// Lists the shares of [host] from a short-lived isolate, without a pool.
  static Future<List<Smb2ShareInfo>> listSharesOn({
    required String host,
    String? user,
    String? password,
    String? domain,
    Duration timeout = const Duration(seconds: 15),
    @Deprecated('Use timeout. Will be removed in 0.3.0.') int? timeoutSeconds,
  }) {
    final limit = timeoutSeconds != null
        ? Duration(seconds: timeoutSeconds)
        : timeout;
    return Isolate.run(
      () => Smb2Client.listShares(
        host: host,
        user: user,
        password: password,
        domain: domain,
        timeout: limit,
      ),
      debugName: 'dart_smb2 listShares',
    );
  }

  /// The shares of [host], as [listSharesOn] lists them.
  @Deprecated('Use Smb2Pool.listSharesOn. Will be removed in 0.3.0.')
  Future<List<Smb2ShareInfo>> listShares({
    required String host,
    String? user,
    String? password,
    String? domain,
  }) => listSharesOn(
    host: host,
    user: user,
    password: password,
    domain: domain,
    timeout: _params.timeout,
  );

  /// Number of workers.
  int get workerCount => _slots.length;

  /// Whether [disconnect] has been called.
  bool get isClosed => _closed;

  /// The workers, for the concurrency tests' fault injection.
  @internal
  List<Worker> get workersForTest => [for (final s in _slots) s.worker];

  // ─── Directories and metadata ──────────────────────────────────────────

  /// Lists the entries of the directory at [path] (`''` for the share
  /// root), without `.` and `..`.
  Future<List<Smb2DirEntry>> listDirectory(
    String path, {
    Smb2CancelToken? cancelToken,
  }) => _run(Op.listDirectory, [path], path: path, cancelToken: cancelToken);

  /// The metadata of [path].
  Future<Smb2Stat> stat(String path, {Smb2CancelToken? cancelToken}) =>
      _run(Op.stat, [path], path: path, cancelToken: cancelToken);

  /// The size of the file at [path], in bytes.
  Future<int> fileSize(String path, {Smb2CancelToken? cancelToken}) async =>
      (await stat(path, cancelToken: cancelToken)).size;

  /// Whether [path] exists. Throws on any failure other than a missing
  /// path.
  Future<bool> exists(String path, {Smb2CancelToken? cancelToken}) async {
    try {
      await stat(path, cancelToken: cancelToken);
      return true;
    } on Smb2Exception catch (e) {
      if (e.isNotFound) return false;
      rethrow;
    }
  }

  /// Space statistics of the share that holds [path] (`''` for the root).
  Future<Smb2StatVfs> statvfs(String path, {Smb2CancelToken? cancelToken}) =>
      _run(Op.statvfs, [path], path: path, cancelToken: cancelToken);

  /// The target of the symbolic link at [path].
  Future<String> readlink(String path, {Smb2CancelToken? cancelToken}) =>
      _run(Op.readlink, [path], path: path, cancelToken: cancelToken);

  /// Sends a keepalive echo on one worker. Completes when its connection is
  /// healthy, reconnecting it first when it is not.
  Future<void> echo() => _run<void>(Op.echo, const []);

  /// Creates the directory [path]. Not repeated after a network failure.
  Future<void> mkdir(String path, {Smb2CancelToken? cancelToken}) => _run(
    Op.mkdir,
    [path],
    path: path,
    idempotent: false,
    cancelToken: cancelToken,
  );

  /// Removes the empty directory [path]. Not repeated after a network
  /// failure.
  Future<void> rmdir(String path, {Smb2CancelToken? cancelToken}) => _run(
    Op.rmdir,
    [path],
    path: path,
    idempotent: false,
    cancelToken: cancelToken,
  );

  /// Deletes the file [path]. Not repeated after a network failure.
  Future<void> deleteFile(String path, {Smb2CancelToken? cancelToken}) => _run(
    Op.deleteFile,
    [path],
    path: path,
    idempotent: false,
    cancelToken: cancelToken,
  );

  /// Renames or moves [oldPath] to [newPath]. Not repeated after a network
  /// failure.
  Future<void> rename(
    String oldPath,
    String newPath, {
    Smb2CancelToken? cancelToken,
  }) => _run(
    Op.rename,
    [oldPath, newPath],
    path: oldPath,
    idempotent: false,
    cancelToken: cancelToken,
  );

  /// Truncates (or extends with zeros) the file [path] to [length] bytes.
  Future<void> truncate(
    String path,
    int length, {
    Smb2CancelToken? cancelToken,
  }) => _run(Op.truncate, [path, length], path: path, cancelToken: cancelToken);

  /// Sets the last-modified and/or last-accessed time of [path]; see
  /// [Smb2Client.setFileTimes].
  Future<void> setFileTimes(
    String path, {
    DateTime? modified,
    DateTime? accessed,
    Smb2CancelToken? cancelToken,
  }) => _run(
    Op.setFileTimes,
    [path, modified?.microsecondsSinceEpoch, accessed?.microsecondsSinceEpoch],
    path: path,
    cancelToken: cancelToken,
  );

  // ─── Whole-file reads and writes ───────────────────────────────────────

  /// Reads the whole file at [path] into memory. For large files prefer
  /// [streamFile] or [downloadToFile].
  Future<Uint8List> readFile(String path, {Smb2CancelToken? cancelToken}) =>
      _run(Op.readFile, [path], path: path, cancelToken: cancelToken);

  /// Reads [length] bytes of [path] from [offset]: fewer only when the file
  /// ends first.
  Future<Uint8List> readFileRange(
    String path, {
    int offset = 0,
    required int length,
    Smb2CancelToken? cancelToken,
  }) => _run(
    Op.readRange,
    [path, offset, length],
    path: path,
    cancelToken: cancelToken,
  );

  /// Replaces the content of [path] with [data], creating the file if it
  /// does not exist.
  Future<void> writeFile(
    String path,
    Uint8List data, {
    Smb2CancelToken? cancelToken,
  }) => _run(
    Op.writeFile,
    () => [path, _native(data), data.length, 0],
    path: path,
    cancelToken: cancelToken,
  );

  /// Writes [data] to [path] at [offset], creating the file if it does not
  /// exist. The rest of the file is left as it is.
  Future<void> writeFileRange(
    String path,
    Uint8List data, {
    int offset = 0,
    Smb2CancelToken? cancelToken,
  }) => _run(
    Op.writeRange,
    () => [path, _native(data), data.length, offset],
    path: path,
    cancelToken: cancelToken,
  );

  // ─── Handles ───────────────────────────────────────────────────────────

  /// Opens [path] for reading on one worker. Read it with
  /// [readFromHandle], then [closeHandle] — or use [withFile].
  Future<Smb2PoolHandle> openFile(
    String path, {
    Smb2CancelToken? cancelToken,
  }) async {
    return _dispatch<int, Smb2PoolHandle>(
      Op.open,
      [path],
      (slot, id) =>
          Smb2PoolHandleInternal.create(slot, id, path, writable: false),
      path: path,
      cancelToken: cancelToken,
    );
  }

  /// Opens [path] for reading and returns its size with the handle.
  Future<(Smb2PoolHandle, int)> openFileWithSize(
    String path, {
    Smb2CancelToken? cancelToken,
  }) async {
    return _dispatch<(int, int), (Smb2PoolHandle, int)>(
      Op.openWithSize,
      [path],
      (slot, opened) => (
        Smb2PoolHandleInternal.create(slot, opened.$1, path, writable: false),
        opened.$2,
      ),
      path: path,
      cancelToken: cancelToken,
    );
  }

  /// Opens [path] for writing on one worker, creating it if it does not
  /// exist and emptying it first when [truncate] is set. Write with
  /// [writeToHandle], then [closeHandle].
  Future<Smb2PoolHandle> openFileWrite(
    String path, {
    bool truncate = false,
    Smb2CancelToken? cancelToken,
  }) async {
    return _dispatch<int, Smb2PoolHandle>(
      Op.openWrite,
      [path, truncate],
      (slot, id) =>
          Smb2PoolHandleInternal.create(slot, id, path, writable: true),
      path: path,
      cancelToken: cancelToken,
    );
  }

  /// Reads [length] bytes from [handle] at [offset]: fewer only when the
  /// file ends first.
  Future<Uint8List> readFromHandle(
    Smb2PoolHandle handle, {
    int offset = 0,
    required int length,
    Smb2CancelToken? cancelToken,
  }) => _onHandle(
    handle,
    Op.readHandle,
    (id) => [id, offset, length],
    cancelToken: cancelToken,
  );

  /// Writes [data] to [handle] at [offset].
  Future<void> writeToHandle(
    Smb2PoolHandle handle,
    Uint8List data, {
    int offset = 0,
    Smb2CancelToken? cancelToken,
  }) => _onHandle(
    handle,
    Op.writeHandle,
    (id) => [id, _native(data), data.length, offset],
    cancelToken: cancelToken,
  );

  /// Flushes the writes on [handle] to the server's disk.
  Future<void> fsyncHandle(
    Smb2PoolHandle handle, {
    Smb2CancelToken? cancelToken,
  }) =>
      _onHandle(handle, Op.fsyncHandle, (id) => [id], cancelToken: cancelToken);

  /// Truncates (or extends with zeros) the file of [handle] to [length]
  /// bytes.
  Future<void> ftruncateHandle(
    Smb2PoolHandle handle,
    int length, {
    Smb2CancelToken? cancelToken,
  }) => _onHandle(
    handle,
    Op.ftruncateHandle,
    (id) => [id, length],
    cancelToken: cancelToken,
  );

  /// Closes [handle]. Closing a closed handle does nothing, and a close
  /// that fails is not reported: the server drops the handle with the
  /// connection anyway.
  Future<void> closeHandle(Smb2PoolHandle handle) async {
    final target = handle.markClosed();
    if (target == null) return;
    final (worker, id) = target;
    try {
      await worker.call<void>(Op.closeHandle, [id]);
    } on Smb2Exception {
      // The worker is gone or reconnecting; its handles went with it.
    }
  }

  // ─── Scoped and streaming helpers ──────────────────────────────────────

  /// Opens [path], runs [body] with the open [Smb2File], and closes it on
  /// every exit path.
  ///
  /// Pass [knownSize] when a listing or `stat` already gave the size: the
  /// open then skips the size request.
  ///
  /// ```dart
  /// final header = await pool.withFile('Music/song.flac', (file) {
  ///   return file.read(length: min(file.size, 64 * 1024));
  /// });
  /// ```
  Future<T> withFile<T>(
    String path,
    FutureOr<T> Function(Smb2File file) body, {
    int? knownSize,
    Smb2CancelToken? cancelToken,
  }) async {
    final Smb2PoolHandle handle;
    final int size;
    if (knownSize != null) {
      handle = await openFile(path, cancelToken: cancelToken);
      size = knownSize;
    } else {
      (handle, size) = await openFileWithSize(path, cancelToken: cancelToken);
    }
    try {
      return await body(Smb2File(this, handle, size, cancelToken));
    } finally {
      await closeHandle(handle);
    }
  }

  /// Streams the file at [path] in chunks of [chunkSize] bytes, keeping
  /// one handle open for the whole read and the next chunk in flight while
  /// the listener handles the current one.
  ///
  /// The stream waits while its listener is paused, so at most two chunks
  /// are in memory. [onProgress] gets the bytes received so far and the
  /// file size after each chunk. Cancelling the subscription or
  /// [cancelToken] closes the handle; the token also ends the stream with a
  /// [Smb2ErrorType.cancelled] error.
  Stream<Uint8List> streamFile(
    String path, {
    int chunkSize = defaultChunkSize,
    void Function(int received, int total)? onProgress,
    Smb2CancelToken? cancelToken,
    @Deprecated('Use cancelToken. Will be removed in 0.3.0.')
    bool Function()? isCanceled,
  }) async* {
    if (chunkSize <= 0) {
      throw Smb2Exception(
        'chunkSize must be positive',
        type: Smb2ErrorType.invalidParam,
        path: path,
      );
    }
    final (handle, size) = await openFileWithSize(
      path,
      cancelToken: cancelToken,
    );
    Future<Uint8List>? next;
    try {
      // The read ahead may fail while the stream waits at `yield`; mark it
      // observed so the failure is not reported as unhandled. The `await`
      // below still receives it.
      Future<Uint8List> fetch(int offset) => readFromHandle(
        handle,
        offset: offset,
        length: min(chunkSize, size - offset),
        cancelToken: cancelToken,
      )..ignore();
      var received = 0;
      if (size > 0) next = fetch(0);
      while (next != null) {
        final chunk = await next;
        next = null;
        if (chunk.isEmpty) {
          throw Smb2Exception(
            'The file shrank while it was read: $received of $size bytes',
            type: Smb2ErrorType.io,
            path: path,
          );
        }
        received += chunk.length;
        if (received < size) next = fetch(received);
        onProgress?.call(received, size);
        yield chunk;
        if (isCanceled?.call() ?? false) {
          throw Smb2Exception(
            'Cancelled',
            type: Smb2ErrorType.cancelled,
            path: path,
          );
        }
      }
    } finally {
      // A read still in flight when the listener left: drop its result.
      next?.ignore();
      await closeHandle(handle);
    }
  }

  /// Downloads [path] to the local file [destination] and returns the
  /// bytes written.
  ///
  /// The data goes to a temporary file next to [destination] as it
  /// arrives, at the pace the disk takes it, and is renamed to
  /// [destination] only once complete. A failure or a cancellation through
  /// [cancelToken] removes the temporary file and throws a
  /// [Smb2Exception] (of type [Smb2ErrorType.cancelled] for a
  /// cancellation); whatever was at [destination] before is left as it
  /// was. Two downloads to the same [destination] never share a temporary
  /// file.
  Future<int> downloadToFile(
    String path,
    String destination, {
    int chunkSize = defaultChunkSize,
    void Function(int received, int total)? onProgress,
    Smb2CancelToken? cancelToken,
  }) async {
    final File part;
    final RandomAccessFile out;
    try {
      part = await _createPart(destination);
      out = await part.open(mode: FileMode.writeOnly);
    } on FileSystemException catch (e, st) {
      throw Smb2Exception(
        'Cannot write $destination: ${e.message}',
        type: Smb2ErrorType.io,
        path: path,
        cause: e,
        stackTrace: st,
      );
    }
    var written = 0;
    try {
      await for (final chunk in streamFile(
        path,
        chunkSize: chunkSize,
        onProgress: onProgress,
        cancelToken: cancelToken,
      )) {
        await out.writeFrom(chunk);
        written += chunk.length;
      }
      await out.close();
      cancelToken?.throwIfCancelled(path: path);
      await part.rename(destination);
      return written;
    } catch (e, st) {
      await out.close().catchError((Object _) => out);
      await part.delete().catchError((Object _) => part);
      if (e is Smb2Exception) rethrow;
      if (e is FileSystemException) {
        throw Smb2Exception(
          'Cannot write $destination: ${e.message}',
          type: Smb2ErrorType.io,
          path: path,
          cause: e,
          stackTrace: st,
        );
      }
      rethrow;
    }
  }

  /// Replaces the content of [path] with [chunks], written in order through
  /// one handle, so only one chunk is in memory at a time.
  ///
  /// Each chunk goes to its own offset, so after a network failure the pool
  /// reconnects, reopens the file (without emptying it again) and writes the
  /// chunk once more.
  Future<void> streamWrite(
    String path,
    Stream<Uint8List> chunks, {
    Smb2CancelToken? cancelToken,
  }) async {
    final handle = await openFileWrite(
      path,
      truncate: true,
      cancelToken: cancelToken,
    );
    try {
      var offset = 0;
      await for (final chunk in chunks) {
        await writeToHandle(
          handle,
          chunk,
          offset: offset,
          cancelToken: cancelToken,
        );
        offset += chunk.length;
      }
    } finally {
      await closeHandle(handle);
    }
  }

  /// Closes every worker: each closes its handles and logs off. Calls still
  /// running fail with a [Smb2ErrorType.connection] error, and later calls
  /// with a [Smb2ErrorType.state] one.
  Future<void> disconnect() async {
    if (_closed) return;
    _closed = true;
    // A reconnect in progress closes the worker it spawns once it sees the
    // pool closed; wait for it so nothing outlives this call.
    await Future.wait(_reconnects.toList());
    await Future.wait(_slots.map((s) => s.worker.close()));
  }

  /// The default chunk of [streamFile] and [downloadToFile]: 4 MiB.
  static const int defaultChunkSize = 4 * 1024 * 1024;

  // ─── Dispatch and reconnect ────────────────────────────────────────────

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
  /// equals), or null when every slot is reconnecting.
  Slot? _pickNow() {
    final start = _next++;
    Slot? best;
    for (var i = 0; i < _slots.length; i++) {
      final slot = _slots[(start + i) % _slots.length];
      if (slot.reconnecting != null) continue;
      if (best == null || slot.worker.load < best.worker.load) best = slot;
    }
    return best;
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
    List<Object?> build() =>
        args is List<Object?> ? args : (args as List<Object?> Function())();
    final slot = _pickNow() ?? await _pickLater();
    final worker = slot.worker;
    try {
      return result(
        slot,
        await worker.call<T>(op, build(), cancelToken: cancelToken, path: path),
      );
    } on Smb2Exception catch (e) {
      if (!e.isNetworkFailure || _closed) rethrow;
      final fresh = await _reconnect(slot, worker);
      if (!idempotent) rethrow;
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
    if (handle.isStale) await _reopen(handle, cancelToken);
    final worker = handle.slot.worker;
    try {
      return await worker.call<T>(
        op,
        args(handle.id),
        cancelToken: cancelToken,
        path: path,
      );
    } on Smb2Exception catch (e) {
      if (!e.isNetworkFailure || _closed || handle.isClosed) rethrow;
      await _reconnect(handle.slot, worker);
      cancelToken?.throwIfCancelled(path: path);
      await _reopen(handle, cancelToken);
      return handle.slot.worker.call<T>(
        op,
        args(handle.id),
        cancelToken: cancelToken,
        path: path,
      );
    }
  }

  Future<void> _reopen(Smb2PoolHandle handle, Smb2CancelToken? cancelToken) {
    _ensureHandleOpen(handle);
    return handle.reopen(
      (worker) => worker.call<int>(
        handle.writable ? Op.openWrite : Op.open,
        // Never truncate again: the data written so far must stay.
        handle.writable ? [handle.path, false] : [handle.path],
        cancelToken: cancelToken,
        path: handle.path,
      ),
    );
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
    final future = slot.reconnecting = _replace(slot, failed);
    final done = future.then<void>((_) {}, onError: (Object _) {});
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
    final worker = await Worker.spawn(_params);
    if (_closed) {
      await worker.close();
      _ensureOpen(null);
    }
    slot.worker = worker;
    slot.generation++;
    return worker;
  }
}

T _valueOnly<T>(Slot _, T value) => value;

/// A copy of [data] in a `malloc` buffer, which the worker frees after
/// writing it (or [Worker.call] frees when the request is never sent).
int _native(Uint8List data) {
  final buf = malloc<Uint8>(max(data.length, 1));
  buf.asTypedList(data.length).setAll(0, data);
  return buf.address;
}

/// A new, empty file next to [destination] for a download to fill.
Future<File> _createPart(String destination) async {
  final random = Random();
  for (var attempt = 0; ; attempt++) {
    final suffix = random.nextInt(1 << 32).toRadixString(16);
    final part = File('$destination.part-$suffix');
    try {
      return await part.create(exclusive: true);
    } on FileSystemException {
      if (attempt >= 8) rethrow;
    }
  }
}
