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

/// Async wrapper that runs [Smb2Client] in a dedicated Dart isolate.
///
/// All operations are non-blocking and safe to call from the Flutter UI thread.
/// Each [Smb2Isolate] owns one SMB connection in its own isolate.
///
/// ```dart
/// final smb = await Smb2Isolate.connect(
///   libPath: '/path/to/libsmb2.dylib',
///   host: '192.168.1.1',
///   share: 'Music',
///   user: 'guest',
/// );
/// final entries = await smb.listDirectory('');
/// await smb.disconnect();
/// ```
class Smb2Isolate {
  final SendPort _commandPort;
  final Isolate _isolate;

  Smb2Isolate._(this._commandPort, this._isolate);

  /// Spawn an isolate, connect to the SMB share, and return the wrapper.
  ///
  /// [libPath] is the path to the `libsmb2` shared library.
  /// Throws [Smb2Exception] if the connection fails.
  static Future<Smb2Isolate> connect({
    required String libPath,
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    int timeoutSeconds = 30,
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
  }) async {
    final initPort = ReceivePort();

    final isolate = await Isolate.spawn(
      _isolateMain,
      _InitRequest(
        sendPort: initPort.sendPort,
        libPath: libPath,
        host: host,
        share: share,
        user: user,
        password: password,
        domain: domain,
        timeoutSeconds: timeoutSeconds,
        seal: seal,
        signing: signing,
        version: version,
      ),
    );

    final response = await initPort.first;
    initPort.close();

    if (response is SendPort) {
      return Smb2Isolate._(response, isolate);
    }
    throw Smb2Exception(response.toString());
  }

  /// List available shares on the connected server.
  Future<List<Smb2ShareInfo>> listShares() =>
      _call('listShares', {});

  /// List all entries in a directory.
  Future<List<Smb2DirEntry>> listDirectory(String path) =>
      _call('listDir', {'path': path});

  /// Read [length] bytes from a file at [offset].
  Future<Uint8List> readFileRange(
    String path, {
    int offset = 0,
    required int length,
  }) => _call('readRange', {'path': path, 'offset': offset, 'length': length});

  /// Read an entire file into memory.
  Future<Uint8List> readFile(String path) =>
      _call('readFile', {'path': path});

  /// Get file metadata.
  Future<Smb2Stat> stat(String path) =>
      _call('stat', {'path': path});

  /// Get file size in bytes.
  Future<int> fileSize(String path) =>
      _call('fileSize', {'path': path});

  /// Send a keepalive echo to the server.
  Future<void> echo() => _call('echo', {});

  /// Get filesystem statistics (total/free space).
  Future<Smb2StatVfs> statvfs(String path) =>
      _call('statvfs', {'path': path});

  /// Read the target path of a symbolic link.
  Future<String> readlink(String path) =>
      _call('readlink', {'path': path});

  /// Flush all buffered writes on a file handle to the server.
  Future<void> fsync(int handleId) =>
      _call('fsync', {'handleId': handleId});

  /// Truncate an open file handle to [length] bytes.
  Future<void> ftruncate(int handleId, int length) =>
      _call('ftruncate', {'handleId': handleId, 'length': length});

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

  /// Write [data] to a file at [offset], creating it if it doesn't exist.
  Future<void> writeFileRange(
    String path,
    Uint8List data, {
    int offset = 0,
  }) => _call('writeRange', {
    'path': path,
    'data': TransferableTypedData.fromList([data]),
    'offset': offset,
  });

  /// Write [data] to a file, creating or truncating it.
  Future<void> writeFile(String path, Uint8List data) =>
      _call('writeFile', {
        'path': path,
        'data': TransferableTypedData.fromList([data]),
      });

  /// Delete a file.
  Future<void> deleteFile(String path) =>
      _call('deleteFile', {'path': path});

  /// Create a directory.
  Future<void> mkdir(String path) =>
      _call('mkdir', {'path': path});

  /// Delete an empty directory.
  Future<void> rmdir(String path) =>
      _call('rmdir', {'path': path});

  /// Rename or move a file or directory.
  Future<void> rename(String oldPath, String newPath) =>
      _call('rename', {'oldPath': oldPath, 'newPath': newPath});

  /// Truncate a file to [length] bytes.
  Future<void> truncate(String path, int length) =>
      _call('truncate', {'path': path, 'length': length});

  /// Open a file for writing and return a handle ID.
  ///
  /// Use [writeToHandle] to write, then [closeHandle] when done.
  Future<int> openFileWrite(String path) =>
      _call('openFileWrite', {'path': path});

  /// Write [data] at [offset] to an open write handle.
  Future<void> writeToHandle(int handleId, Uint8List data, {int offset = 0}) =>
      _call('writeHandle', {
        'handleId': handleId,
        'data': TransferableTypedData.fromList([data]),
        'offset': offset,
      });

  /// Close a file handle.
  Future<void> closeHandle(int handleId) =>
      _call('closeHandle', {'handleId': handleId});

  /// Write data from a [Stream] to a file without loading everything into RAM.
  ///
  /// Opens a write handle, writes each chunk sequentially, and closes.
  Future<void> streamWrite(String path, Stream<Uint8List> chunks) async {
    final handleId = await openFileWrite(path);
    try {
      await ftruncate(handleId, 0);
      int offset = 0;
      await for (final chunk in chunks) {
        await writeToHandle(handleId, chunk, offset: offset);
        offset += chunk.length;
      }
    } finally {
      await closeHandle(handleId);
    }
  }

  /// Stream a file in chunks without loading everything into RAM.
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

  /// Disconnect and kill the isolate.
  ///
  /// Sends a disconnect command and waits up to 5 seconds for the worker
  /// to close handles and release the SMB connection gracefully.
  /// Falls back to an immediate kill if the worker is unresponsive.
  Future<void> disconnect() async {
    final replyPort = ReceivePort();
    _commandPort.send({'cmd': 'disconnect', 'replyTo': replyPort.sendPort});
    try {
      await replyPort.first.timeout(const Duration(seconds: 5));
    } catch (_) {
      // Worker may be unresponsive or already dead.
    } finally {
      replyPort.close();
    }
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  Future<T> _call<T>(String cmd, Map<String, dynamic> args) async {
    final replyPort = ReceivePort();
    try {
      _commandPort.send({...args, 'cmd': cmd, 'replyTo': replyPort.sendPort});
      final result = await replyPort.first;
      // Check for errors BEFORE the type check — when T is void,
      // `result is T` is always true and would swallow error responses.
      // All errors are encoded as 3-element lists [message, errorCode, typeIndex].
      if (result is List && result.length == 3 && result[0] is String) {
        throw Smb2Exception(
          result[0] as String,
          result[1] as int?,
          result[2] != null
              ? Smb2ErrorType.values[result[2] as int]
              : Smb2ErrorType.unknown,
        );
      }
      // Materialize zero-copy transferred buffers back to Uint8List.
      if (result is TransferableTypedData) {
        return result.materialize().asUint8List() as T;
      }
      if (result is T) return result;
      throw Smb2Exception('Unexpected response type: ${result.runtimeType}');
    } finally {
      replyPort.close();
    }
  }
}

// ─── Isolate internals ──────────────────────────────────────────────────────

class _InitRequest {
  final SendPort sendPort;
  final String libPath;
  final String host;
  final String share;
  final String? user;
  final String? password;
  final String? domain;
  final int timeoutSeconds;
  final bool seal;
  final bool signing;
  final Smb2Version version;

  _InitRequest({
    required this.sendPort,
    required this.libPath,
    required this.host,
    required this.share,
    this.user,
    this.password,
    this.domain,
    this.timeoutSeconds = 30,
    this.seal = false,
    this.signing = false,
    this.version = Smb2Version.any,
  });
}

void _isolateMain(_InitRequest req) {
  final client = Smb2Client.open(req.libPath);

  try {
    client.connect(
      host: req.host,
      share: req.share,
      user: req.user,
      password: req.password,
      domain: req.domain,
      timeoutSeconds: req.timeoutSeconds,
      seal: req.seal,
      signing: req.signing,
      version: req.version,
    );
  } catch (e) {
    req.sendPort.send(e.toString());
    return;
  }

  final commandPort = ReceivePort();
  req.sendPort.send(commandPort.sendPort);

  final handles = <int, dynamic>{};
  int nextHandleId = 0;

  commandPort.listen((msg) {
    if (msg is! Map) return;
    final cmd = msg['cmd'] as String;
    final replyTo = msg['replyTo'] as SendPort?;

    try {
      switch (cmd) {
        case 'listShares':
          replyTo?.send(client.listShares(
            host: req.host,
            user: req.user,
            password: req.password,
            domain: req.domain,
          ));
        case 'listDir':
          replyTo?.send(client.listDirectory(msg['path'] as String));
        case 'readRange':
          final rangeData = client.readFileRange(
            msg['path'] as String,
            offset: msg['offset'] as int,
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
            replyTo?.send(['Invalid handle', 22, Smb2ErrorType.invalidParam.index]);
            return;
          }
          client.fsync(fhSync);
          replyTo?.send(true);
        case 'ftruncate':
          final fhTrunc = handles[msg['handleId'] as int];
          if (fhTrunc == null) {
            replyTo?.send(['Invalid handle', 22, Smb2ErrorType.invalidParam.index]);
            return;
          }
          client.ftruncate(fhTrunc, msg['length'] as int);
          replyTo?.send(true);
        case 'openFileWrite':
          final fh = client.openFileHandleWrite(msg['path'] as String);
          final id = nextHandleId++;
          handles[id] = fh;
          replyTo?.send(id);
        case 'writeHandle':
          final fh = handles[msg['handleId'] as int];
          if (fh == null) {
            replyTo?.send([
              'Invalid handle',
              22,
              Smb2ErrorType.invalidParam.index,
            ]);
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
        case 'disconnect':
          for (final fh in handles.values) {
            try { client.closeHandle(fh); } catch (_) {}
          }
          handles.clear();
          client.disconnect();
          replyTo?.send(true);
          commandPort.close();
      }
    } catch (e) {
      if (e is Smb2Exception) {
        replyTo?.send([e.message, e.errorCode, e.type.index]);
      } else {
        replyTo?.send([e.toString(), null, Smb2ErrorType.unknown.index]);
      }
    }
  });
}
