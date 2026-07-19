// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../ffi/native_lib.dart';
import '../smb2_client.dart';
import '../smb2_error_type.dart';
import '../smb2_exceptions.dart';
import '../smb2_types.dart';
import 'handle.dart';
import 'messages.dart';
import 'worker.dart';

export 'handle.dart' show Smb2PoolHandle, Smb2File;

/// A pool of SMB2 worker isolates for non-blocking parallel operations.
///
/// Each worker owns its own SMB connection and runs in a dedicated isolate.
/// All public methods are async and safe to call from the Flutter UI thread.
///
/// ```dart
/// final pool = await Smb2Pool.connect(
///   host: '192.168.1.100',
///   share: 'Music',
///   user: 'user',
///   password: 'pass',
///   workers: 4,
/// );
///
/// final entries = await pool.listDirectory('');
/// final bytes = await pool.readFile('Artist/cover.jpg');
/// await pool.disconnect();
/// ```
class Smb2Pool {
  final List<Worker> _workers;
  final ConnectParams _params;

  int _next = 0;
  bool _closed = false;

  Smb2Pool._(this._workers, this._params);

  /// Connect [workers] isolates to the SMB share.
  ///
  /// Each isolate opens its own TCP connection to the server.
  /// All isolates share the same credentials and target share.
  ///
  /// Workers are spawned **sequentially** — each spawn is `await`ed
  /// before the next starts. libsmb2 mutates a global `active_contexts`
  /// list (init.c) without internal locking, so concurrent
  /// `smb2_init_context` calls from multiple isolates would race on it.
  /// Sequencing the spawns guarantees that at most one isolate is inside
  /// `smb2_init_context` at any given moment within this pool.
  ///
  /// The startup cost is N × per-worker connect latency instead of
  /// max(per-worker latency). For typical `workers = 4` and a local SMB
  /// server that's ~100 ms vs ~25 ms — well below human-perceptible.
  static Future<Smb2Pool> connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    int workers = 4,
    int timeoutSeconds = 30,
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
  }) async {
    final params = ConnectParams(
      host: host,
      share: share,
      user: user,
      password: password,
      domain: domain,
      timeoutSeconds: timeoutSeconds,
      seal: seal,
      signing: signing,
      version: version,
      testLibOverride: debugLibSmb2PathOverride,
    );
    final workerList = <Worker>[];
    try {
      for (var i = 0; i < workers; i++) {
        workerList.add(await Worker.spawn(params));
      }
    } catch (_) {
      // Spawn failure: tear down any workers that already came up so we
      // don't leak isolates on the way out. `close()` is fire-and-forget
      // here because the caller is about to see `rethrow` and we don't
      // want to mask the original error with a teardown timeout.
      for (final w in workerList) {
        w.close().ignore();
      }
      rethrow;
    }
    return Smb2Pool._(workerList, params);
  }

  /// Number of active workers.
  int get workerCount => _workers.length;

  /// Package-internal view on the underlying [Worker] list. Read-only —
  /// returning the live list lets the concurrency suite call
  /// `killForTest()` and send fault-injection commands directly on a
  /// worker. Reached via `lib/src/pool/test_hooks.dart`.
  @internal
  List<Worker> get workersForTest => _workers;

  /// List available shares on a server (no active connection needed).
  ///
  /// Spawns a temporary isolate, connects to IPC$, enumerates, and cleans up.
  static Future<List<Smb2ShareInfo>> listSharesOn({
    required String host,
    String? user,
    String? password,
    String? domain,
    int timeoutSeconds = 15,
  }) async {
    // Capture the test override here so the spawned isolate (which
    // doesn't inherit the main isolate's static fields) can re-apply
    // it before opening libsmb2.
    final override = debugLibSmb2PathOverride;
    return await Isolate.run(() {
      if (override != null) debugLibSmb2PathOverride = override;
      final client = Smb2Client.open();
      return client.listShares(
        host: host,
        user: user,
        password: password,
        domain: domain,
        timeoutSeconds: timeoutSeconds,
      );
    });
  }

  Worker get _nextWorker {
    if (_closed || _workers.isEmpty) {
      throw const Smb2Exception('Pool is closed');
    }
    final w = _workers[_next % _workers.length];
    _next++;
    return w;
  }

  /// List all entries in a directory.
  Future<List<Smb2DirEntry>> listDirectory(String path) =>
      _sendWithRetry('listDir', {'path': path});

  /// List available shares on the connected server.
  Future<List<Smb2ShareInfo>> listShares({
    required String host,
    String? user,
    String? password,
    String? domain,
  }) =>
      _nextWorker.send('listShares', {
        'host': host,
        'user': user,
        'password': password,
        'domain': domain,
      });

  /// Read [length] bytes from a file at [offset].
  Future<Uint8List> readFileRange(
    String path, {
    int offset = 0,
    required int length,
  }) =>
      _sendWithRetry('readRange', {
        'path': path,
        'offset': offset,
        'length': length,
      });

  /// Read an entire file into memory.
  Future<Uint8List> readFile(String path) =>
      _sendWithRetry('readFile', {'path': path});

  /// Get file metadata.
  Future<Smb2Stat> stat(String path) => _sendWithRetry('stat', {'path': path});

  /// Get file size in bytes.
  Future<int> fileSize(String path) =>
      _sendWithRetry('fileSize', {'path': path});

  /// Send a keepalive echo to the server.
  ///
  /// Uses one worker to check if the connection is healthy.
  Future<void> echo() => _sendWithRetry('echo', {});

  /// Get filesystem statistics (total/free space).
  Future<Smb2StatVfs> statvfs(String path) =>
      _sendWithRetry('statvfs', {'path': path});

  /// Read the target path of a symbolic link.
  Future<String> readlink(String path) =>
      _sendWithRetry('readlink', {'path': path});

  /// Flush all buffered writes on a file handle to the server.
  ///
  /// On connection failure, reconnects the worker, reopens the file,
  /// and retries the flush transparently.
  Future<void> fsyncHandle(Smb2PoolHandle handle) async {
    try {
      await handle.worker.send('fsync', {'handleId': handle.id});
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      await _reopenWriteHandle(handle);
      await handle.worker.send('fsync', {'handleId': handle.id});
    }
  }

  /// Truncate an open file handle to [length] bytes.
  ///
  /// On connection failure, reconnects the worker, reopens the file,
  /// and retries the truncate transparently.
  Future<void> ftruncateHandle(Smb2PoolHandle handle, int length) async {
    try {
      await handle.worker.send('ftruncate', {
        'handleId': handle.id,
        'length': length,
      });
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      await _reopenWriteHandle(handle);
      await handle.worker.send('ftruncate', {
        'handleId': handle.id,
        'length': length,
      });
    }
  }

  /// Check whether a file or directory exists.
  ///
  /// Returns `true` if the path exists, `false` if it does not.
  /// Throws [Smb2Exception] on connection or permission errors.
  Future<bool> exists(String path) async {
    try {
      await stat(path);
      return true;
    } on Smb2Exception catch (e) {
      if (e.type == Smb2ErrorType.fileNotFound) return false;
      rethrow;
    }
  }

  // ─── File writing ──────────────────────────────────────────────────────

  /// Write [data] to a file at [offset], creating it if it doesn't exist.
  Future<void> writeFileRange(
    String path,
    Uint8List data, {
    int offset = 0,
  }) =>
      _sendWriteWithRetry('writeRange', data, {
        'path': path,
        'offset': offset,
      });

  /// Write [data] to a file, creating or truncating it.
  Future<void> writeFile(String path, Uint8List data) =>
      _sendWriteWithRetry('writeFile', data, {'path': path});

  // ─── File/directory management ────────────────────────────────────────

  /// Delete a file.
  Future<void> deleteFile(String path) =>
      _sendWithRetry('deleteFile', {'path': path});

  /// Create a directory.
  Future<void> mkdir(String path) => _sendWithRetry('mkdir', {'path': path});

  /// Delete an empty directory.
  Future<void> rmdir(String path) => _sendWithRetry('rmdir', {'path': path});

  /// Rename or move a file or directory.
  Future<void> rename(String oldPath, String newPath) =>
      _sendWithRetry('rename', {'oldPath': oldPath, 'newPath': newPath});

  /// Truncate a file to [length] bytes.
  Future<void> truncate(String path, int length) =>
      _sendWithRetry('truncate', {'path': path, 'length': length});

  /// Set the last-modified and/or last-accessed time of a file or directory.
  ///
  /// Fields left `null` are not changed on the server. At least one of
  /// [modified] / [accessed] must be provided. Call this *after* any write
  /// handle on [path] is closed — servers refresh the modified time on
  /// write/close, which would overwrite an earlier set.
  Future<void> setFileTimes(
    String path, {
    DateTime? modified,
    DateTime? accessed,
  }) =>
      _sendWithRetry('setFileTimes', {
        'path': path,
        'modifiedUs': modified?.microsecondsSinceEpoch,
        'accessedUs': accessed?.microsecondsSinceEpoch,
      });

  // ─── File handles ──────────────────────────────────────────────────────

  /// Open a file for reading and return a handle tied to one worker.
  ///
  /// Use [readFromHandle] and [closeHandle] with the returned handle.
  /// All operations on a handle are routed to the same worker isolate.
  Future<Smb2PoolHandle> openFile(String path) async {
    var worker = _nextWorker;
    try {
      final handleId = await worker.send<int>('openFile', {'path': path});
      return Smb2PoolHandle(worker, handleId, path);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      final handleId = await worker.send<int>('openFile', {'path': path});
      return Smb2PoolHandle(worker, handleId, path);
    }
  }

  /// Open a file and get its size in one call.
  ///
  /// Returns `(handle, fileSize)`. Saves a network round-trip vs
  /// calling [fileSize] + [openFile] separately.
  Future<(Smb2PoolHandle, int)> openFileWithSize(String path) async {
    var worker = _nextWorker;
    try {
      return await _openFileWithSizeOn(worker, path);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      return await _openFileWithSizeOn(worker, path);
    }
  }

  Future<(Smb2PoolHandle, int)> _openFileWithSizeOn(
    Worker worker,
    String path,
  ) async {
    final result = await worker.send<List<dynamic>>(
      'openFileWithSize',
      {'path': path},
    );
    return (Smb2PoolHandle(worker, result[0] as int, path), result[1] as int);
  }

  /// Read [length] bytes at [offset] from an open handle.
  ///
  /// On connection failure, reconnects the worker, reopens the file,
  /// and retries the read transparently.
  Future<Uint8List> readFromHandle(
    Smb2PoolHandle handle, {
    int offset = 0,
    required int length,
  }) async {
    try {
      return await handle.worker.send('readHandle', {
        'handleId': handle.id,
        'offset': offset,
        'length': length,
      });
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      await _reopenHandle(handle);
      return await handle.worker.send('readHandle', {
        'handleId': handle.id,
        'offset': offset,
        'length': length,
      });
    }
  }

  /// Close an open file handle.
  Future<void> closeHandle(Smb2PoolHandle handle) async {
    if (handle.closed) return;
    handle.markClosed();
    try {
      await handle.worker.send('closeHandle', {'handleId': handle.id});
    } catch (_) {
      // Best-effort — the handle may already be invalid after reconnect.
    }
  }

  /// Open a file for writing and return a handle tied to one worker.
  ///
  /// The file is created if it doesn't exist.
  /// Use [writeToHandle] to write, then [closeHandle] when done.
  Future<Smb2PoolHandle> openFileWrite(String path) async {
    var worker = _nextWorker;
    try {
      final handleId = await worker.send<int>('openFileWrite', {'path': path});
      return Smb2PoolHandle(worker, handleId, path);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      final handleId = await worker.send<int>('openFileWrite', {'path': path});
      return Smb2PoolHandle(worker, handleId, path);
    }
  }

  /// Write [data] at [offset] to an open write handle.
  ///
  /// On connection failure, reconnects the worker, reopens the file,
  /// and retries the write transparently.
  Future<void> writeToHandle(
    Smb2PoolHandle handle,
    Uint8List data, {
    int offset = 0,
  }) async {
    try {
      await handle.worker.send('writeHandle', {
        'handleId': handle.id,
        'data': TransferableTypedData.fromList([data]),
        'offset': offset,
      });
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      await _reopenWriteHandle(handle);
      await handle.worker.send('writeHandle', {
        'handleId': handle.id,
        'data': TransferableTypedData.fromList([data]),
        'offset': offset,
      });
    }
  }

  /// Reconnect the worker and reopen the file for writing.
  ///
  /// Honors a concurrent [closeHandle] call: if the handle is marked
  /// closed at any of the three observation points (entry, after the
  /// reconnect await, after the new open), we throw a typed
  /// connection error and best-effort close the just-opened handle.
  /// Without this, a parallel `closeHandle(h) + readFromHandle(h)`
  /// could leave the read path reopening a fresh handle that nobody owns.
  Future<void> _reopenWriteHandle(Smb2PoolHandle handle) async {
    _throwIfClosed(handle);
    handle.worker = await _reconnectWorker(handle.worker);
    _throwIfClosed(handle);
    final newId = await handle.worker.send<int>(
      'openFileWrite',
      {'path': handle.path},
    );
    if (handle.closed) {
      _closeOrphanHandle(handle.worker, newId);
      _throwClosedDuringRetry();
    }
    handle.id = newId;
    handle.refreshFinalizer();
  }

  /// Reconnect the worker and reopen the file, updating the handle in-place.
  ///
  /// See [_reopenWriteHandle] for how a concurrent close is handled.
  Future<void> _reopenHandle(Smb2PoolHandle handle) async {
    _throwIfClosed(handle);
    handle.worker = await _reconnectWorker(handle.worker);
    _throwIfClosed(handle);
    final newId = await handle.worker.send<int>(
      'openFile',
      {'path': handle.path},
    );
    if (handle.closed) {
      _closeOrphanHandle(handle.worker, newId);
      _throwClosedDuringRetry();
    }
    handle.id = newId;
    handle.refreshFinalizer();
  }

  static void _throwIfClosed(Smb2PoolHandle handle) {
    if (handle.closed) _throwClosedDuringRetry();
  }

  static Never _throwClosedDuringRetry() {
    throw const Smb2Exception(
      'Handle was closed during reconnect',
      null,
      Smb2ErrorType.connection,
    );
  }

  /// Fire-and-forget close on a handle we just reopened on the new
  /// worker — only invoked when a concurrent [closeHandle] beat us to
  /// the punch, so the caller no longer wants it.
  static void _closeOrphanHandle(Worker worker, int handleId) {
    worker.send('closeHandle', {'handleId': handleId}).ignore();
  }

  /// Write data from a [Stream] to a file without loading everything into RAM.
  ///
  /// Opens a write handle, writes each chunk sequentially, and closes.
  ///
  /// Unlike other write operations, streamed writes do **not** retry on
  /// connection failure — a partial write cannot be safely resumed because
  /// the server-side state is unknown. If the connection drops mid-stream,
  /// the error is propagated immediately.
  Future<void> streamWrite(String path, Stream<Uint8List> chunks) async {
    final handle = await openFileWrite(path);
    try {
      await ftruncateHandle(handle, 0);
      int offset = 0;
      await for (final chunk in chunks) {
        // Send directly to the worker without retry — a reconnect would
        // reopen the file and lose track of how many bytes the server
        // actually received, causing data corruption.
        await handle.worker.send('writeHandle', {
          'handleId': handle.id,
          'data': TransferableTypedData.fromList([chunk]),
          'offset': offset,
        });
        offset += chunk.length;
      }
    } finally {
      await closeHandle(handle);
    }
  }

  /// Stream a file in chunks without loading everything into RAM.
  ///
  /// Keeps a single file handle open for the whole read — one `Create`
  /// on the wire, then `smb2_pread` (splits into server-negotiated
  /// MaxReadSize packets internally), then one `Close`. The handle is
  /// released when the stream completes, errors, or is canceled.
  ///
  /// - [chunkSize] controls the Dart-side buffer per iteration. The
  ///   network layer chunks independently into libsmb2's
  ///   `max_read_size` (typically 1 MiB). Larger [chunkSize] means
  ///   fewer isolate round-trips and fewer progress callbacks.
  /// - [onProgress] fires after each chunk with `(received, total)`
  ///   bytes. `total` is the file size; 0 if unknown.
  /// - [isCanceled] is polled after each chunk. Returning `true`
  ///   aborts the stream with an `Smb2Exception('canceled')`.
  Stream<Uint8List> streamFile(
    String path, {
    int chunkSize = 1024 * 1024,
    void Function(int received, int total)? onProgress,
    bool Function()? isCanceled,
  }) async* {
    final (handle, size) = await openFileWithSize(path);
    try {
      if (size <= 0) return;
      var offset = 0;
      while (offset < size) {
        if (isCanceled?.call() ?? false) {
          throw const Smb2Exception(
            'Read canceled',
          );
        }
        final remaining = size - offset;
        final toRead = remaining < chunkSize ? remaining : chunkSize;
        final chunk = await readFromHandle(
          handle,
          offset: offset,
          length: toRead,
        );
        // A read of 0 bytes before reaching [size] means the file was
        // truncated by another client mid-stream — surface it as an error
        // instead of silently returning a short, incomplete result.
        if (chunk.isEmpty) {
          throw Smb2Exception(
            'File shrank mid-stream: expected $size bytes, got $offset',
            null,
            Smb2ErrorType.io,
          );
        }
        offset += chunk.length;
        onProgress?.call(offset, size);
        yield chunk;
      }
    } finally {
      await closeHandle(handle);
    }
  }

  /// Download [path] to [destFile], writing in chunks via the same
  /// persistent handle [streamFile] uses.
  ///
  /// Returns the number of bytes written. On cancel or error the
  /// destination file is left as-is — callers that want atomic writes
  /// should download to a `.part` file and rename on success.
  Future<int> downloadToFile(
    String path,
    File destFile, {
    int chunkSize = 1024 * 1024,
    void Function(int received, int total)? onProgress,
    bool Function()? isCanceled,
  }) async {
    final sink = destFile.openWrite();
    var total = 0;
    try {
      await for (final chunk in streamFile(
        path,
        chunkSize: chunkSize,
        onProgress: onProgress,
        isCanceled: isCanceled,
      )) {
        sink.add(chunk);
        total += chunk.length;
      }
    } finally {
      await sink.close();
    }
    return total;
  }

  /// Open [path] for reading, run [body] with a scoped [Smb2File],
  /// and guarantee the handle is closed on any exit path.
  ///
  /// Preferred over raw [openFileWithSize]/[closeHandle] pairs because
  /// it composes with exceptions, early returns, and cancellation
  /// without boilerplate.
  ///
  /// Pass [knownSize] when you already have the file size from a prior
  /// `stat` or directory listing — this uses the cheaper [openFile]
  /// (no `fstat` round-trip) and populates [Smb2File.size] from the
  /// argument. Omit it to do one combined `open + fstat`.
  ///
  /// ```dart
  /// final tags = await pool.withFile('Music/song.flac', (file) async {
  ///   final header = await file.read(length: 64 * 1024);
  ///   return parseVorbisComments(
  ///     header,
  ///     fileSize: file.size,
  ///     fallbackRead: (o, n) => file.read(offset: o, length: n),
  ///   );
  /// });
  /// ```
  Future<T> withFile<T>(
    String path,
    FutureOr<T> Function(Smb2File file) body, {
    int? knownSize,
  }) async {
    final Smb2PoolHandle handle;
    final int size;
    if (knownSize != null) {
      handle = await openFile(path);
      size = knownSize;
    } else {
      final (h, s) = await openFileWithSize(path);
      handle = h;
      size = s;
    }
    try {
      return await body(Smb2File(this, handle, size));
    } finally {
      await closeHandle(handle);
    }
  }

  /// Disconnect all workers and release resources.
  Future<void> disconnect() async {
    _closed = true;
    await Future.wait(_workers.map((w) => w.close()));
    _workers.clear();
  }

  // ─── Auto-reconnect wrapper ────────────────────────────────────────────

  /// Send a command with one retry on connection failure.
  ///
  /// If the worker reports a connection error, it is respawned with a fresh
  /// TCP connection and the command is retried once.
  Future<T> _sendWithRetry<T>(String cmd, Map<String, dynamic> args) async {
    var worker = _nextWorker;
    try {
      return await worker.send<T>(cmd, args);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      // Reconnect this worker and retry once
      worker = await _reconnectWorker(worker);
      return await worker.send<T>(cmd, args);
    }
  }

  /// Like [_sendWithRetry] but for write commands that carry [Uint8List] data.
  ///
  /// A fresh [TransferableTypedData] is created for each attempt because
  /// a transferred buffer can only be materialized once — reusing it on
  /// retry would crash.
  Future<void> _sendWriteWithRetry(
    String cmd,
    Uint8List data,
    Map<String, dynamic> args,
  ) async {
    var worker = _nextWorker;
    try {
      await worker.send(cmd, {
        ...args,
        'data': TransferableTypedData.fromList([data]),
      });
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      await worker.send(cmd, {
        ...args,
        'data': TransferableTypedData.fromList([data]),
      });
    }
  }

  /// In-flight reconnect futures, keyed on the failing [Worker] that
  /// triggered the rebuild. Single-flight: concurrent ops that all see
  /// the same worker fail share one reconnect attempt instead of each
  /// racing to spawn its own replacement.
  ///
  /// Without this coalescing, N parallel calls failing on the same worker
  /// would each spawn a replacement — leaking N-1 orphan isolates and
  /// leaving some callers pointing at a worker they never see.
  final Map<Worker, Future<Worker>> _reconnectsInFlight = {};

  /// Closes [worker], spawns a fresh replacement at the same slot, and returns it.
  ///
  /// Coalesces concurrent retries on the same dead worker via
  /// [_reconnectsInFlight] — the first caller starts the work and every
  /// other caller awaits the same future. Once it settles (success or
  /// failure) the map entry is removed so a *future* failure on the
  /// replacement worker can trigger its own reconnect.
  Future<Worker> _reconnectWorker(Worker worker) {
    final existing = _reconnectsInFlight[worker];
    if (existing != null) return existing;

    final future = _doReconnect(worker);
    _reconnectsInFlight[worker] = future;
    future.whenComplete(() => _reconnectsInFlight.remove(worker));
    return future;
  }

  Future<Worker> _doReconnect(Worker worker) async {
    final idx = _workers.indexOf(worker);
    if (idx < 0) return worker;
    try {
      await worker.close();
    } catch (_) {}
    final newWorker = await Worker.spawn(_params);
    _workers[idx] = newWorker;
    return newWorker;
  }

  static bool _isConnectionError(Smb2Exception e) => e.isConnectionError;
}
