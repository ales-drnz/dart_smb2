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
  Future<void> disconnect() async {
    _commandPort.send({'cmd': 'disconnect'});
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }

  Future<T> _call<T>(String cmd, Map<String, dynamic> args) async {
    final replyPort = ReceivePort();
    _commandPort.send({...args, 'cmd': cmd, 'replyTo': replyPort.sendPort});
    final result = await replyPort.first;
    replyPort.close();
    if (result is T) return result;
    if (result is List && result.length == 3) {
      throw Smb2Exception(
        result[0] as String,
        result[1] as int?,
        result[2] != null
            ? Smb2ErrorType.values[result[2] as int]
            : Smb2ErrorType.unknown,
      );
    }
    if (result is String) throw Smb2Exception(result);
    throw Smb2Exception('Unexpected response type: ${result.runtimeType}');
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

  _InitRequest({
    required this.sendPort,
    required this.libPath,
    required this.host,
    required this.share,
    this.user,
    this.password,
    this.domain,
    this.timeoutSeconds = 30,
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
    );
  } catch (e) {
    req.sendPort.send(e.toString());
    return;
  }

  final commandPort = ReceivePort();
  req.sendPort.send(commandPort.sendPort);

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
          replyTo?.send(client.readFileRange(
            msg['path'] as String,
            offset: msg['offset'] as int,
            length: msg['length'] as int,
          ));
        case 'readFile':
          replyTo?.send(client.readFile(msg['path'] as String));
        case 'stat':
          replyTo?.send(client.stat(msg['path'] as String));
        case 'fileSize':
          replyTo?.send(client.fileSize(msg['path'] as String));
        case 'disconnect':
          client.disconnect();
          commandPort.close();
      }
    } catch (e) {
      if (e is Smb2Exception) {
        replyTo?.send([e.message, e.errorCode, e.type.index]);
      } else {
        replyTo?.send(e.toString());
      }
    }
  });
}
