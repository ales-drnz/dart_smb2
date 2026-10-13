// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The worker isolate: owns one [Smb2Client] and serves the [Request]s of
/// its [Worker] proxy in order.
library;

import 'dart:isolate';

import '../smb2_client.dart';
import '../smb2_error_type.dart';
import '../smb2_exception.dart';
import 'protocol.dart';
import 'worker.dart';

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
  commands.listen((Object? message) => server.handle(message! as Request));
}

final class _Server {
  final Smb2Client client;
  final SendPort replies;
  final ReceivePort commands;
  final Map<int, Smb2Handle> handles = {};
  int nextHandle = 1;

  // Test-only fault injection (Op.inject*).
  int failNext = 0;
  bool hangNext = false;
  bool emptyReadNext = false;

  _Server(this.client, this.replies, this.commands);

  void handle(Request r) {
    if (!r.op.isInjection) {
      if (hangNext) {
        hangNext = false;
        return;
      }
      if (failNext > 0) {
        failNext--;
        _fail(
          r,
          const Smb2Exception(
            'Injected connection failure',
            type: Smb2ErrorType.connection,
          ),
        );
        return;
      }
    }
    try {
      final value = _run(r);
      if (r.id != 0) replies.send(Reply(r.id, value));
    } on Smb2Exception catch (e) {
      _fail(r, e);
    } catch (e) {
      _fail(r, Smb2Exception('Unexpected worker error: $e', cause: e));
    }
    if (r.op == Op.close) commands.close();
  }

  void _fail(Request r, Smb2Exception e) {
    if (r.id != 0) replies.send(Failure(r.id, e));
  }

  Smb2Handle _handle(Object? id, String what) {
    final h = handles[id! as int];
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

  Object? _run(Request r) {
    final a = r.args;
    switch (r.op) {
      case Op.listDirectory:
        return client.listDirectory(a[0]! as String);
      case Op.stat:
        return client.stat(a[0]! as String);
      case Op.statvfs:
        return client.statvfs(a[0]! as String);
      case Op.readlink:
        return client.readlink(a[0]! as String);
      case Op.echo:
        client.echo();
        return null;
      case Op.readFile:
        final (h, size) = client.openFileWithSize(a[0]! as String);
        try {
          return _bytes(client.readNative(h, length: size));
        } finally {
          client.closeHandle(h);
        }
      case Op.readRange:
        final h = client.openFile(a[0]! as String);
        try {
          return _bytes(
            client.readNative(h, offset: a[1]! as int, length: a[2]! as int),
          );
        } finally {
          client.closeHandle(h);
        }
      case Op.writeFile || Op.writeRange:
        // The buffer stays the main isolate's, which frees it on the reply.
        final h = client.openFileWrite(
          a[0]! as String,
          truncate: r.op == Op.writeFile,
        );
        try {
          client.writeNative(
            h,
            a[1]! as int,
            a[2]! as int,
            offset: a[3]! as int,
          );
        } finally {
          client.closeHandle(h);
        }
        return null;
      case Op.mkdir:
        client.mkdir(a[0]! as String);
        return null;
      case Op.rmdir:
        client.rmdir(a[0]! as String);
        return null;
      case Op.deleteFile:
        client.deleteFile(a[0]! as String);
        return null;
      case Op.rename:
        client.rename(a[0]! as String, a[1]! as String);
        return null;
      case Op.truncate:
        client.truncate(a[0]! as String, a[1]! as int);
        return null;
      case Op.setFileTimes:
        final modified = a[1] as int?;
        final accessed = a[2] as int?;
        client.setFileTimes(
          a[0]! as String,
          modified: modified == null
              ? null
              : DateTime.fromMicrosecondsSinceEpoch(modified, isUtc: true),
          accessed: accessed == null
              ? null
              : DateTime.fromMicrosecondsSinceEpoch(accessed, isUtc: true),
        );
        return null;
      case Op.open:
        return _keep(client.openFile(a[0]! as String));
      case Op.openWithSize:
        final (h, size) = client.openFileWithSize(a[0]! as String);
        return (_keep(h), size);
      case Op.openWrite:
        return _keep(
          client.openFileWrite(a[0]! as String, truncate: a[1]! as bool),
        );
      case Op.readHandle:
        final h = _handle(a[0], 'Read');
        if (emptyReadNext) {
          emptyReadNext = false;
          return const NativeBytes(0, 0);
        }
        return _bytes(
          client.readNative(h, offset: a[1]! as int, length: a[2]! as int),
        );
      case Op.writeHandle:
        client.writeNative(
          _handle(a[0], 'Write'),
          a[1]! as int,
          a[2]! as int,
          offset: a[3]! as int,
        );
        return null;
      case Op.fsyncHandle:
        client.fsyncHandle(_handle(a[0], 'Fsync'));
        return null;
      case Op.ftruncateHandle:
        client.ftruncateHandle(_handle(a[0], 'Ftruncate'), a[1]! as int);
        return null;
      case Op.closeHandle:
        final h = handles.remove(a[0]! as int);
        if (h != null) client.closeHandle(h);
        return null;
      case Op.close:
        handles.clear();
        client.disconnect();
        return null;
      case Op.injectFailures:
        failNext = a[0]! as int;
        return null;
      case Op.injectHang:
        hangNext = true;
        return null;
      case Op.injectEmptyRead:
        emptyReadNext = true;
        return null;
      case Op.injectHandleCount:
        return handles.length;
      case Op.injectExit:
        Isolate.exit();
    }
  }
}

NativeBytes _bytes((int, int) read) => NativeBytes(read.$1, read.$2);
