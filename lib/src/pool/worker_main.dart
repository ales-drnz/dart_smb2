// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The worker isolate: owns one [Smb2Client] and serves the [Call]s of
/// its [Worker] proxy in order.
///
/// @docImport 'worker.dart';
library;

import 'dart:isolate';

import '../smb2_client.dart';
import '../smb2_error_type.dart';
import '../smb2_exception.dart';
import 'protocol.dart';

/// Entry point of a worker isolate. Connects, then answers [Ready] — or a
/// [Failure] with id -1 when the connection (or loading libsmb2) fails.
void workerMain(Init init) {
  final replies = init.replies;
  if (init.exitBeforeConnect) Isolate.exit();
  if (init.neverReady) {
    ReceivePort(); // Keeps the isolate alive, silent.
    return;
  }
  final Smb2Client client;
  try {
    final p = init.params;
    client = Smb2Client()
      ..connect(
        host: p.host,
        share: p.share,
        user: p.user,
        password: p.password,
        domain: p.domain,
        timeout: p.timeout,
        seal: p.seal,
        signing: p.signing,
        version: p.version,
      );
  } on Smb2Exception catch (e) {
    replies.send(Failure(-1, e));
    return;
  } catch (e) {
    // libsmb2 could not be loaded, or anything else unexpected.
    replies.send(
      Failure(-1, Smb2Exception('Cannot start the worker: $e', cause: e)),
    );
    return;
  }

  final commands = ReceivePort();
  final server = _Server(client, replies, commands);
  replies.send(Ready(commands.sendPort));
  commands.listen((Object? message) => server.handle(message! as Call));
}

final class _Server {
  final Smb2Client client;
  final SendPort replies;
  final ReceivePort commands;
  final Map<int, Smb2Handle> handles = {};
  int nextHandle = 1;

  // Test-only fault injection (the Injection requests).
  int failNext = 0;
  bool hangNext = false;
  bool emptyReadNext = false;

  _Server(this.client, this.replies, this.commands);

  void handle(Call c) {
    final r = c.request;
    if (r is! Injection) {
      if (hangNext) {
        hangNext = false;
        return;
      }
      if (failNext > 0) {
        failNext--;
        _fail(
          c,
          const Smb2Exception(
            'Injected connection failure',
            type: Smb2ErrorType.connection,
          ),
        );
        return;
      }
    }
    try {
      final value = _run(r, c.buffer);
      if (c.id != 0) replies.send(Reply(c.id, value));
    } on Smb2Exception catch (e) {
      _fail(c, e);
    } catch (e) {
      _fail(c, Smb2Exception('Unexpected worker error: $e', cause: e));
    }
    if (r is Close) commands.close();
  }

  void _fail(Call c, Smb2Exception e) {
    if (c.id != 0) replies.send(Failure(c.id, e));
  }

  Smb2Handle _handle(int id, String what) {
    final h = handles[id];
    if (h == null) {
      throw Smb2Exception('$what: unknown handle', type: Smb2ErrorType.state);
    }
    return h;
  }

  int _keep(Smb2Handle h) {
    final id = nextHandle++;
    handles[id] = h;
    return id;
  }

  /// Serves [r], with the native [buffer] of a write, which stays the main
  /// isolate's: it frees it on the reply.
  Object? _run(Request<Object?> r, int? buffer) {
    switch (r) {
      case ListDirectory(:final path):
        return client.listDirectory(path);
      case ListDirectoryIds(:final path):
        return listDirectoryIds(client, path);
      case Stat(:final path):
        return client.stat(path);
      case StatVfs(:final path):
        return client.statvfs(path);
      case Readlink(:final path):
        return client.readlink(path);
      case Echo():
        client.echo();
        return null;
      case ReadFile(:final path):
        final (h, size) = client.openFileWithSize(path);
        try {
          return _bytes(client.readNative(h, length: size));
        } finally {
          client.closeHandle(h);
        }
      case ReadRange(:final path, :final offset, :final length):
        final h = client.openFile(path);
        try {
          return _bytes(client.readNative(h, offset: offset, length: length));
        } finally {
          client.closeHandle(h);
        }
      case WriteFile(:final path, :final length):
        final h = client.openFileWrite(path, truncate: true);
        try {
          client.writeNative(h, buffer!, length);
        } finally {
          client.closeHandle(h);
        }
        return null;
      case WriteRange(:final path, :final length, :final offset):
        final h = client.openFileWrite(path);
        try {
          client.writeNative(h, buffer!, length, offset: offset);
        } finally {
          client.closeHandle(h);
        }
        return null;
      case Mkdir(:final path):
        client.mkdir(path);
        return null;
      case Rmdir(:final path):
        client.rmdir(path);
        return null;
      case DeleteFile(:final path):
        client.deleteFile(path);
        return null;
      case Rename(:final oldPath, :final newPath, :final overwrite):
        client.rename(oldPath, newPath, overwrite: overwrite);
        return null;
      case Link(:final existingPath, :final newPath):
        client.link(existingPath, newPath);
        return null;
      case Symlink(:final target, :final linkPath, :final directory):
        client.symlink(target, linkPath, directory: directory);
        return null;
      case Truncate(:final path, :final length):
        client.truncate(path, length);
        return null;
      case SetFileTimes(:final path, :final modifiedUs, :final accessedUs):
        client.setFileTimes(
          path,
          modified: modifiedUs == null
              ? null
              : DateTime.fromMicrosecondsSinceEpoch(modifiedUs, isUtc: true),
          accessed: accessedUs == null
              ? null
              : DateTime.fromMicrosecondsSinceEpoch(accessedUs, isUtc: true),
        );
        return null;
      case Open(:final path):
        return _keep(client.openFile(path));
      case OpenWithSize(:final path):
        final (h, size) = client.openFileWithSize(path);
        return (_keep(h), size);
      case OpenWrite(:final path, :final truncate, :final temporary):
        return _keep(
          temporary
              ? openTemporaryWrite(client, path, truncate: truncate)
              : client.openFileWrite(path, truncate: truncate),
        );
      case ReadHandle(:final id, :final offset, :final length):
        final h = _handle(id, 'Read');
        if (emptyReadNext) {
          emptyReadNext = false;
          return const NativeBytes(0, 0);
        }
        return _bytes(client.readNative(h, offset: offset, length: length));
      case WriteHandle(:final id, :final length, :final offset):
        client.writeNative(
          _handle(id, 'Write'),
          buffer!,
          length,
          offset: offset,
        );
        return null;
      case FsyncHandle(:final id):
        client.fsyncHandle(_handle(id, 'Fsync'));
        return null;
      case FtruncateHandle(:final id, :final length):
        client.ftruncateHandle(_handle(id, 'Ftruncate'), length);
        return null;
      case CloseHandle(:final id):
        final h = handles.remove(id);
        if (h != null) client.closeHandle(h);
        return null;
      case Close():
        handles.clear();
        client.disconnect();
        return null;
      case InjectFailures(:final count):
        failNext = count;
        return null;
      case InjectHang():
        hangNext = true;
        return null;
      case InjectEmptyRead():
        emptyReadNext = true;
        return null;
      case InjectHandleCount():
        return handles.length;
      case InjectExit():
        Isolate.exit();
    }
  }
}

NativeBytes _bytes((int, int) read) => NativeBytes(read.$1, read.$2);
