// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'smb2_client.dart';
import 'smb2_error_type.dart';
import 'smb2_exceptions.dart';
import 'smb2_types.dart';

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
  final List<_Worker> _workers;
  final _ConnectParams _params;
  int _next = 0;
  bool _closed = false;

  Smb2Pool._(this._workers, this._params);

  /// Connect [workers] isolates to the SMB share.
  ///
  /// Each isolate opens its own TCP connection to the server.
  /// All isolates share the same credentials and target share.
  static Future<Smb2Pool> connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    int workers = 4,
    int timeoutSeconds = 30,
    String? libPath,
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
  }) async {
    final params = _ConnectParams(
      host: host,
      share: share,
      user: user,
      password: password,
      domain: domain,
      timeoutSeconds: timeoutSeconds,
      libPath: libPath,
      seal: seal,
      signing: signing,
      version: version,
    );
    final futures = List.generate(workers, (_) => _Worker.spawn(params));
    late final List<_Worker> workerList;
    try {
      workerList = await Future.wait(futures);
    } catch (_) {
      // Kill any workers that succeeded before the failure.
      for (final f in futures) {
        f.then((w) => w.close()).ignore();
      }
      rethrow;
    }
    return Smb2Pool._(workerList, params);
  }

  /// Number of active workers.
  int get workerCount => _workers.length;

  /// List available shares on a server (no active connection needed).
  ///
  /// Spawns a temporary isolate, connects to IPC$, enumerates, and cleans up.
  static Future<List<Smb2ShareInfo>> listSharesOn({
    required String host,
    String? user,
    String? password,
    String? domain,
    int timeoutSeconds = 15,
    String? libPath,
  }) async {
    return await Isolate.run(() {
      final client = libPath != null
          ? Smb2Client.open(libPath)
          : Smb2Client.open();
      return client.listShares(
        host: host,
        user: user,
        password: password,
        domain: domain,
        timeoutSeconds: timeoutSeconds,
      );
    });
  }

  _Worker get _nextWorker {
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
  }) => _nextWorker.send('listShares', {
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
  }) => _sendWithRetry('readRange', {
    'path': path,
    'offset': offset,
    'length': length,
  });

  /// Read an entire file into memory.
  Future<Uint8List> readFile(String path) =>
      _sendWithRetry('readFile', {'path': path});

  /// Get file metadata.
  Future<Smb2Stat> stat(String path) =>
      _sendWithRetry('stat', {'path': path});

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
  Future<void> fsyncHandle(Smb2PoolHandle handle) async {
    await handle._worker.send('fsync', {'handleId': handle._id});
  }

  /// Truncate an open file handle to [length] bytes.
  Future<void> ftruncateHandle(Smb2PoolHandle handle, int length) async {
    await handle._worker.send('ftruncate', {
      'handleId': handle._id,
      'length': length,
    });
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
  }) => _sendWriteWithRetry('writeRange', data, {
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
  Future<void> mkdir(String path) =>
      _sendWithRetry('mkdir', {'path': path});

  /// Delete an empty directory.
  Future<void> rmdir(String path) =>
      _sendWithRetry('rmdir', {'path': path});

  /// Rename or move a file or directory.
  Future<void> rename(String oldPath, String newPath) =>
      _sendWithRetry('rename', {'oldPath': oldPath, 'newPath': newPath});

  /// Truncate a file to [length] bytes.
  Future<void> truncate(String path, int length) =>
      _sendWithRetry('truncate', {'path': path, 'length': length});

  // ─── File handles ──────────────────────────────────────────────────────

  /// Open a file for reading and return a handle tied to one worker.
  ///
  /// Use [readFromHandle] and [closeHandle] with the returned handle.
  /// All operations on a handle are routed to the same worker isolate.
  Future<Smb2PoolHandle> openFile(String path) async {
    var worker = _nextWorker;
    try {
      final handleId = await worker.send<int>('openFile', {'path': path});
      return Smb2PoolHandle._(worker, handleId, path);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      final handleId = await worker.send<int>('openFile', {'path': path});
      return Smb2PoolHandle._(worker, handleId, path);
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
    _Worker worker,
    String path,
  ) async {
    final result = await worker.send<List<dynamic>>(
      'openFileWithSize',
      {'path': path},
    );
    return (Smb2PoolHandle._(worker, result[0] as int, path), result[1] as int);
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
      return await handle._worker.send('readHandle', {
        'handleId': handle._id,
        'offset': offset,
        'length': length,
      });
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      await _reopenHandle(handle);
      return await handle._worker.send('readHandle', {
        'handleId': handle._id,
        'offset': offset,
        'length': length,
      });
    }
  }

  /// Close an open file handle.
  Future<void> closeHandle(Smb2PoolHandle handle) async {
    try {
      await handle._worker.send('closeHandle', {'handleId': handle._id});
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
      return Smb2PoolHandle._(worker, handleId, path);
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      worker = await _reconnectWorker(worker);
      final handleId = await worker.send<int>('openFileWrite', {'path': path});
      return Smb2PoolHandle._(worker, handleId, path);
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
      await handle._worker.send('writeHandle', {
        'handleId': handle._id,
        'data': TransferableTypedData.fromList([data]),
        'offset': offset,
      });
    } on Smb2Exception catch (e) {
      if (!_isConnectionError(e) || _closed) rethrow;
      await _reopenWriteHandle(handle);
      await handle._worker.send('writeHandle', {
        'handleId': handle._id,
        'data': TransferableTypedData.fromList([data]),
        'offset': offset,
      });
    }
  }

  /// Reconnect the worker and reopen the file for writing.
  Future<void> _reopenWriteHandle(Smb2PoolHandle handle) async {
    handle._worker = await _reconnectWorker(handle._worker);
    final newId = await handle._worker.send<int>(
      'openFileWrite',
      {'path': handle._path},
    );
    handle._id = newId;
  }

  /// Reconnect the worker and reopen the file, updating the handle in-place.
  Future<void> _reopenHandle(Smb2PoolHandle handle) async {
    handle._worker = await _reconnectWorker(handle._worker);
    final newId = await handle._worker.send<int>(
      'openFile',
      {'path': handle._path},
    );
    handle._id = newId;
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
        await handle._worker.send('writeHandle', {
          'handleId': handle._id,
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
  /// Yields [Uint8List] chunks of up to [chunkSize] bytes.
  /// The stream completes when the entire file has been read.
  Stream<Uint8List> streamFile(
    String path, {
    int chunkSize = 1024 * 1024,
  }) async* {
    final size = await fileSize(path);
    if (size <= 0) return;
    int offset = 0;
    while (offset < size) {
      final toRead = (size - offset).clamp(0, chunkSize);
      final chunk = await readFileRange(path, offset: offset, length: toRead);
      yield chunk;
      offset += toRead;
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

  /// Closes [worker], spawns a fresh replacement at the same slot, and returns it.
  Future<_Worker> _reconnectWorker(_Worker worker) async {
    final idx = _workers.indexOf(worker);
    if (idx < 0) return worker;
    try {
      await worker.close();
    } catch (_) {}
    final newWorker = await _Worker.spawn(_params);
    _workers[idx] = newWorker;
    return newWorker;
  }

  static bool _isConnectionError(Smb2Exception e) => e.isConnectionError;
}

/// Opaque handle to an open file on a specific worker.
///
/// Use with [Smb2Pool.readFromHandle] and [Smb2Pool.closeHandle].
class Smb2PoolHandle {
  _Worker _worker;
  int _id;
  final String _path;
  Smb2PoolHandle._(this._worker, this._id, this._path);
}

// ─── Connection params ─────────────────────────────────────────────────────

class _ConnectParams {
  final String host, share;
  final String? user, password, domain, libPath;
  final int timeoutSeconds;
  final bool seal, signing;
  final Smb2Version version;

  const _ConnectParams({
    required this.host,
    required this.share,
    this.user,
    this.password,
    this.domain,
    this.timeoutSeconds = 30,
    this.libPath,
    this.seal = false,
    this.signing = false,
    this.version = Smb2Version.any,
  });
}

// ─── Worker isolate ─────────────────────────────────────────────────────────

class _Worker {
  final SendPort _sendPort;
  final Isolate _isolate;

  _Worker._(this._sendPort, this._isolate);

  static Future<_Worker> spawn(_ConnectParams p) async {
    final initPort = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      _InitMsg(
        sendPort: initPort.sendPort,
        host: p.host,
        share: p.share,
        user: p.user,
        password: p.password,
        domain: p.domain,
        timeoutSeconds: p.timeoutSeconds,
        libPath: p.libPath,
        seal: p.seal,
        signing: p.signing,
        version: p.version,
      ),
    );

    final result = await initPort.first;
    initPort.close();

    if (result is SendPort) {
      return _Worker._(result, isolate);
    }
    throw Smb2Exception('Worker failed to start: $result');
  }

  Future<T> send<T>(String cmd, Map<String, dynamic> args) async {
    final replyPort = ReceivePort();
    try {
      _sendPort.send({...args, 'cmd': cmd, 'replyTo': replyPort.sendPort});
      final result = await replyPort.first;
      if (result is _ErrorMsg) {
        throw Smb2Exception(
          result.message,
          result.errorCode,
          result.errorTypeIndex != null
              ? Smb2ErrorType.values[result.errorTypeIndex!]
              : Smb2ErrorType.unknown,
        );
      }
      // Materialize zero-copy transferred buffers back to Uint8List.
      if (result is TransferableTypedData) {
        return result.materialize().asUint8List() as T;
      }
      return result as T;
    } finally {
      replyPort.close();
    }
  }

  Future<void> close() async {
    final replyPort = ReceivePort();
    _sendPort.send({'cmd': 'close', 'replyTo': replyPort.sendPort});
    try {
      // Give the worker 5 s to finish the current operation and shut down
      // cleanly. If it is already dead or unresponsive, the timeout fires and
      // we fall through to the unconditional kill below.
      await replyPort.first.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Worker may be unresponsive or already dead — kill immediately.
    } finally {
      replyPort.close();
    }
    _isolate.kill(priority: Isolate.immediate);
  }
}

// ─── Messages ───────────────────────────────────────────────────────────────

class _InitMsg {
  final SendPort sendPort;
  final String host, share;
  final String? user, password, domain, libPath;
  final int timeoutSeconds;
  final bool seal, signing;
  final Smb2Version version;

  _InitMsg({
    required this.sendPort,
    required this.host,
    required this.share,
    this.user,
    this.password,
    this.domain,
    this.timeoutSeconds = 30,
    this.libPath,
    this.seal = false,
    this.signing = false,
    this.version = Smb2Version.any,
  });
}

class _ErrorMsg {
  final String message;
  final int? errorCode;
  final int? errorTypeIndex;
  _ErrorMsg(this.message, [this.errorCode, this.errorTypeIndex]);
}

// ─── Isolate entry point ────────────────────────────────────────────────────

void _workerMain(_InitMsg init) {
  final client = init.libPath != null
      ? Smb2Client.open(init.libPath)
      : Smb2Client.open();

  try {
    client.connect(
      host: init.host,
      share: init.share,
      user: init.user,
      password: init.password,
      domain: init.domain,
      timeoutSeconds: init.timeoutSeconds,
      seal: init.seal,
      signing: init.signing,
      version: init.version,
    );
  } catch (e) {
    init.sendPort.send(e.toString());
    return;
  }

  final cmdPort = ReceivePort();
  init.sendPort.send(cmdPort.sendPort);

  // Handle ID → native pointer map for file handles
  final handles = <int, dynamic>{};
  int nextHandleId = 0;

  cmdPort.listen((msg) {
    if (msg is! Map) return;
    final cmd = msg['cmd'] as String;
    final replyTo = msg['replyTo'] as SendPort?;

    try {
      switch (cmd) {
        case 'listDir':
          replyTo?.send(client.listDirectory(msg['path'] as String));
        case 'listShares':
          replyTo?.send(client.listShares(
            host: msg['host'] as String,
            user: msg['user'] as String?,
            password: msg['password'] as String?,
            domain: msg['domain'] as String?,
          ));
        case 'readRange':
          final rangeData = client.readFileRange(
            msg['path'] as String,
            offset: msg['offset'] as int? ?? 0,
            length: msg['length'] as int,
          );
          replyTo?.send(TransferableTypedData.fromList([rangeData]));
        case 'readFile':
          final fileData = client.readFile(msg['path'] as String);
          replyTo?.send(TransferableTypedData.fromList([fileData]));
        case 'stat':
          replyTo?.send(client.stat(msg['path'] as String));
        case 'fileSize':
          replyTo?.send(client.fileSize(msg['path'] as String));

        case 'echo':
          client.echo();
          replyTo?.send(true);
        case 'statvfs':
          replyTo?.send(client.statvfs(msg['path'] as String));
        case 'readlink':
          replyTo?.send(client.readlink(msg['path'] as String));
        case 'fsync':
          final fhSync = handles[msg['handleId'] as int];
          if (fhSync == null) {
            replyTo?.send(_ErrorMsg('Invalid handle'));
            return;
          }
          client.fsync(fhSync);
          replyTo?.send(true);
        case 'ftruncate':
          final fhTrunc = handles[msg['handleId'] as int];
          if (fhTrunc == null) {
            replyTo?.send(_ErrorMsg('Invalid handle'));
            return;
          }
          client.ftruncate(fhTrunc, msg['length'] as int);
          replyTo?.send(true);

        // ── Write commands ────────────────────────────────────────────
        case 'writeRange':
          final writeRangeData = (msg['data'] as TransferableTypedData)
              .materialize().asUint8List();
          client.writeFileRange(
            msg['path'] as String,
            writeRangeData,
            offset: msg['offset'] as int? ?? 0,
          );
          replyTo?.send(true);
        case 'writeFile':
          final writeFileData = (msg['data'] as TransferableTypedData)
              .materialize().asUint8List();
          client.writeFile(msg['path'] as String, writeFileData);
          replyTo?.send(true);
        case 'deleteFile':
          client.deleteFile(msg['path'] as String);
          replyTo?.send(true);
        case 'mkdir':
          client.mkdir(msg['path'] as String);
          replyTo?.send(true);
        case 'rmdir':
          client.rmdir(msg['path'] as String);
          replyTo?.send(true);
        case 'rename':
          client.rename(
            msg['oldPath'] as String,
            msg['newPath'] as String,
          );
          replyTo?.send(true);
        case 'truncate':
          client.truncate(msg['path'] as String, msg['length'] as int);
          replyTo?.send(true);

        // ── File handle commands ──────────────────────────────────────
        case 'openFile':
          final fh = client.openFileHandle(msg['path'] as String);
          final id = nextHandleId++;
          handles[id] = fh;
          replyTo?.send(id);
        case 'openFileWithSize':
          final (fh, size) = client.openFileWithSize(msg['path'] as String);
          final id = nextHandleId++;
          handles[id] = fh;
          replyTo?.send([id, size]);
        case 'readHandle':
          final fh = handles[msg['handleId'] as int];
          if (fh == null) {
            replyTo?.send(_ErrorMsg('Invalid handle'));
            return;
          }
          final handleData = client.readHandle(
            fh,
            offset: msg['offset'] as int? ?? 0,
            length: msg['length'] as int,
          );
          replyTo?.send(TransferableTypedData.fromList([handleData]));
        case 'openFileWrite':
          final fh = client.openFileHandleWrite(msg['path'] as String);
          final id = nextHandleId++;
          handles[id] = fh;
          replyTo?.send(id);
        case 'writeHandle':
          final fh = handles[msg['handleId'] as int];
          if (fh == null) {
            replyTo?.send(_ErrorMsg('Invalid handle'));
            return;
          }
          final writeHandleData = (msg['data'] as TransferableTypedData)
              .materialize().asUint8List();
          client.writeHandle(
            fh,
            writeHandleData,
            offset: msg['offset'] as int? ?? 0,
          );
          replyTo?.send(true);
        case 'closeHandle':
          final id = msg['handleId'] as int;
          final fh = handles.remove(id);
          if (fh != null) client.closeHandle(fh);
          replyTo?.send(true);

        case 'close':
          // Close all open handles before disconnecting
          for (final fh in handles.values) {
            try { client.closeHandle(fh); } catch (_) {}
          }
          handles.clear();
          client.disconnect();
          replyTo?.send(true);
          cmdPort.close();
      }
    } catch (e) {
      if (e is Smb2Exception) {
        replyTo?.send(_ErrorMsg(e.message, e.errorCode, e.type.index));
      } else {
        replyTo?.send(_ErrorMsg(e.toString()));
      }
    }
  });
}
