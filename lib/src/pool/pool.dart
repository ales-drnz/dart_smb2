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

  /// Closes still on their way to the server, by path: a call that would
  /// conflict with the open file waits for them (see [_mutates]).
  final Map<String, Future<void>> _pendingCloses = {};

  /// The server's refusal of the last reconnect (credentials, the share),
  /// while it stands: reconnects fail with it at once, without asking the
  /// server, until [_refusalRetry] tries again.
  Smb2Exception? _refusal;
  Timer? _refusalRetry;

  /// Cancelled on [disconnect], to abort the spawns of reconnects.
  final Smb2CancelToken _closing = Smb2CancelToken();
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
  /// When a reconnect fails, the slot's calls go to the other workers, and
  /// the slot tries again in the background, from 1 to 32 seconds apart,
  /// after a network failure. A refusal (credentials, the share) is kept for
  /// five minutes: reconnects fail with it at once, and one login is tried
  /// per interval for the whole pool.
  ///
  /// The credentials work as in [Smb2Client.connect]: without a [user], or
  /// with a null [password], the logon is anonymous; `password: ''` logs on
  /// to an account whose password is empty.
  ///
  /// Throws the first worker's [Smb2Exception] when one cannot connect
  /// (the others are closed): [Smb2ErrorType.auth] for bad credentials,
  /// [Smb2ErrorType.notFound] for a share that does not exist, a network
  /// failure for a host that does not answer. [workers] below 1 throws
  /// [Smb2ErrorType.invalidParam].
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
    final pool = Smb2Pool._([
      for (final w in spawned) Slot(w as Worker),
    ], params);
    for (final slot in pool._slots) {
      pool._watch(slot, slot.worker);
    }
    return pool;
  }

  /// Reconnects [slot] when [worker] is lost without a call failing on it:
  /// its isolate died, or a request a caller cancelled hit a network
  /// failure that the requests queued behind it would hit too.
  void _watch(Slot slot, Worker worker) {
    worker.onLost = () {
      if (!_closed) _reconnect(slot, worker).ignore();
    };
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
  Future<void> echo({Smb2CancelToken? cancelToken}) =>
      _run<void>(Op.echo, const [], cancelToken: cancelToken);

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

  /// Deletes the file [path]; a directory, or a link to one, fails with
  /// [Smb2ErrorType.isADirectory] (remove it with [rmdir]). Not repeated
  /// after a network failure.
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
  ///
  /// [data] is copied into a native buffer in the calling isolate, at
  /// memory speed; for large writes from the UI isolate prefer
  /// [streamWrite] with chunks of a few MiB.
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
  /// exist. The rest of the file is left as it is. [data] is copied in the
  /// calling isolate, as for [writeFile].
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

  /// Writes [data] to [handle] at [offset]. [data] is copied in the calling
  /// isolate, as for [writeFile].
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

  /// Closes [handle], and completes once the server has closed the file, so
  /// a delete or rename of it can follow. Closing a closed handle does
  /// nothing, and a close that fails is not reported: the server drops the
  /// handle with the connection anyway.
  Future<void> closeHandle(Smb2PoolHandle handle) async {
    final target = handle.markClosed();
    if (target == null) return;
    final (worker, id) = target;
    final done = worker
        .call<void>(Op.closeHandle, [id])
        // The worker is gone or reconnecting; its handles went with it.
        .catchError((Object _) {}, test: (e) => e is Smb2Exception);
    final key = _pathKey(handle.path);
    final before = _pendingCloses[key];
    final pending = before == null
        ? done
        : Future.wait([before, done]).then((_) {});
    _pendingCloses[key] = pending;
    unawaited(
      pending.whenComplete(() {
        if (identical(_pendingCloses[key], pending)) {
          _pendingCloses.remove(key)?.ignore();
        }
      }),
    );
    await done;
  }

  /// The closes in flight for [key], and with [below] for the paths in the
  /// directory [key] too.
  Iterable<Future<void>> _closesOf(String key, {required bool below}) sync* {
    for (final MapEntry(key: path, value: close) in _pendingCloses.entries) {
      if (path == key || (below && path.startsWith('$key/'))) yield close;
    }
  }

  /// Closes [handle] without waiting: for a call that failed or was
  /// cancelled, whose close may queue behind a read stuck on the network. A
  /// later delete, rename or write of the same path waits for the close.
  void _closeLater(Smb2PoolHandle handle) => unawaited(closeHandle(handle));

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
    final T result;
    try {
      result = await body(Smb2File(this, handle, size, cancelToken));
    } catch (_) {
      _closeLater(handle);
      rethrow;
    }
    await closeHandle(handle);
    return result;
  }

  /// Streams the file at [path] in chunks of [chunkSize] bytes, keeping
  /// one handle open for the whole read and the next chunk in flight while
  /// the listener handles the current one.
  ///
  /// The stream waits while its listener is paused, so at most two chunks
  /// are in memory. [onProgress] gets the bytes received so far and the
  /// file size after each chunk. Cancelling the subscription closes the
  /// handle, and its future completes without error; [cancelToken] also
  /// closes it, and ends the stream with a [Smb2ErrorType.cancelled]
  /// error.
  Stream<Uint8List> streamFile(
    String path, {
    int chunkSize = defaultChunkSize,
    void Function(int received, int total)? onProgress,
    Smb2CancelToken? cancelToken,
    @Deprecated('Use cancelToken. Will be removed in 0.3.0.')
    bool Function()? isCanceled,
  }) {
    final controller = StreamController<Uint8List>();
    // The token of the stream's own requests, cancelled by [cancelToken]
    // and by the listener leaving.
    final reads = Smb2CancelToken();
    var unlink = _noop;
    var stopped = false;
    Completer<void>? resumed;
    Future<void>? pumping;

    Smb2Exception cancelled() =>
        Smb2Exception('Cancelled', type: Smb2ErrorType.cancelled, path: path);

    Future<void> pump() async {
      Smb2PoolHandle? handle;
      Future<Uint8List>? next;
      try {
        if (chunkSize <= 0) {
          throw Smb2Exception(
            'chunkSize must be positive',
            type: Smb2ErrorType.invalidParam,
            path: path,
          );
        }
        if (cancelToken != null) {
          if (cancelToken.isCancelled) reads.cancel(cancelToken.reason);
          unlink = cancelToken.register(() => reads.cancel(cancelToken.reason));
        }
        final (opened, size) = await openFileWithSize(path, cancelToken: reads);
        handle = opened;
        // The read ahead may fail while the chunk before it waits for the
        // listener; mark it observed so the failure is not reported as
        // unhandled. The `await` below still receives it.
        Future<Uint8List> fetch(int offset) => readFromHandle(
          opened,
          offset: offset,
          length: min(chunkSize, size - offset),
          cancelToken: reads,
        )..ignore();
        var received = 0;
        if (size > 0 && !stopped) {
          if (isCanceled?.call() ?? false) throw cancelled();
          next = fetch(0);
        }
        while (next != null) {
          final chunk = await next;
          next = null;
          if (stopped) return;
          if (chunk.isEmpty) {
            throw Smb2Exception(
              'The file shrank while it was read: $received of $size bytes',
              type: Smb2ErrorType.io,
              path: path,
            );
          }
          // One chunk waits here while the listener holds the one before:
          // two in memory at most.
          while (controller.isPaused && !stopped && !reads.isCancelled) {
            await Future.any([
              (resumed ??= Completer<void>()).future,
              reads.whenCancelled,
            ]);
          }
          if (stopped) return;
          reads.throwIfCancelled(path: path);
          // Like 0.1.x, which asked before each read: nothing more reaches
          // the listener once isCanceled says so.
          if (received > 0 && (isCanceled?.call() ?? false)) {
            throw cancelled();
          }
          received += chunk.length;
          if (received < size) next = fetch(received);
          onProgress?.call(received, size);
          controller.add(chunk);
        }
        // Read to the end: the stream is done once the file is closed, so
        // the listener can delete or rename it next.
        handle = null;
        await closeHandle(opened);
      } catch (e, st) {
        if (!stopped) controller.addError(e, st);
      } finally {
        unlink();
        // A read still in flight when the listener left: drop its result.
        next?.ignore();
        // Left early: the close may queue behind a read stuck on the network.
        if (handle != null) _closeLater(handle);
        if (!stopped) unawaited(controller.close());
      }
    }

    void wake() {
      resumed?.complete();
      resumed = null;
    }

    controller.onListen = () => pumping = pump();
    controller.onResume = wake;
    controller.onCancel = () {
      stopped = true;
      // Ends the requests in flight at once: their results are not wanted.
      reads.cancel();
      wake();
      return pumping;
    };
    return controller.stream;
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
    @Deprecated('Use cancelToken. Will be removed in 0.3.0.')
    bool Function()? isCanceled,
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
        // ignore: deprecated_member_use_from_same_package
        isCanceled: isCanceled,
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
    } catch (_) {
      _closeLater(handle);
      rethrow;
    }
    await closeHandle(handle);
  }

  /// Closes every worker: each closes its handles and logs off.
  ///
  /// Requests a worker has already been sent finish first (a worker that
  /// does not finish within 5 seconds is killed, and they fail with a
  /// [Smb2ErrorType.connection] error). Calls waiting for a reconnect, and
  /// calls made later, fail with a [Smb2ErrorType.state] error. A reconnect
  /// in progress is aborted.
  Future<void> disconnect() async {
    if (_closed) return;
    _closed = true;
    _closing.cancel();
    for (final slot in _slots) {
      slot.retry?.cancel();
      slot.retry = null;
    }
    _refusalRetry?.cancel();
    _refusalRetry = null;
    // Wait for the reconnects so nothing outlives this call.
    await Future.wait(_reconnects.toList());
    await Future.wait(_slots.map((s) => s.worker.close()));
  }

  /// How long a slot whose reconnect the server refused waits before it
  /// tries again. Shortened by tests.
  @visibleForTesting
  static Duration debugRefusedRetry = const Duration(minutes: 5);

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
          handle.writable ? [handle.path, false] : [handle.path],
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
  /// again after [debugRefusedRetry]; when it connects, the other dead slots
  /// follow. One login attempt per interval, however many workers and
  /// calls, so retries do not lock an account out.
  void _refuse(Smb2Exception refusal) {
    _refusal = refusal;
    if (_closed || _refusalRetry != null) return;
    _refusalRetry = Timer(debugRefusedRetry, () async {
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
  Op.rmdir,
  Op.truncate,
  Op.setFileTimes,
  Op.writeFile,
  Op.writeRange,
  Op.openWrite,
};

/// [path] as the server compares it: leading slashes dropped, backslashes
/// as slashes, case folded.
String _pathKey(String path) => path
    .replaceAll(r'\', '/')
    .replaceAll(_slashes, '/')
    .replaceFirst(_edgeSlashes, '')
    .replaceFirst(_edgeSlashes, '')
    .toLowerCase();

final _slashes = RegExp('/{2,}');
final _edgeSlashes = RegExp(r'^/|/$');

void _noop() {}

/// A copy of [data] in a `malloc` buffer for a write request. The copy is
/// made in the calling isolate, at memory speed (about 9 ms for 64 MiB);
/// [Worker] frees the buffer once the request is done or never sent.
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
