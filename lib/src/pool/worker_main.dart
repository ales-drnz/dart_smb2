// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Worker isolate entry point. The code in this file runs *inside* a
/// spawned isolate, owns a single [Smb2Client] connection, and services
/// commands sent over a [ReceivePort] by the main-isolate [Worker]
/// proxy.
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/native_lib.dart';
import '../smb2_client.dart';
import '../smb2_error_type.dart';
import '../smb2_exceptions.dart';
import 'messages.dart';

/// Worker isolate entry function. Spawned via `Isolate.spawn` from
/// [Worker.spawn]. Sends back either a `SendPort` (success — the command
/// channel) or a string (failure — the error message).
void workerMain(InitMsg init) {
  // Re-apply the test-only path override inside this isolate (static
  // fields don't cross the spawn boundary). No-op when production code
  // is driving the pool.
  if (init.testLibOverride != null) {
    debugLibSmb2PathOverride = init.testLibOverride;
  }

  final client = Smb2Client.open();

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

  // Handle ID → opaque [Smb2Handle] map. The worker is the only owner of
  // file handles inside this isolate.
  final handles = <int, Smb2Handle>{};
  int nextHandleId = 0;

  // Test-only fault injection. Production code never uses these knobs;
  // the integration suite uses them to make connection-failure and
  // reconnect scenarios deterministic, without a real network drop.
  //
  // * `injectFailureCount > 0` makes the next N non-`__inject_*` commands
  //   reply with `ErrorMsg` of type `connection`, so callers exercise the
  //   pool's auto-reconnect path without needing a real network drop.
  // * `injectHangNext` makes the next non-`__inject_*` command never
  //   reply at all — the worker silently swallows it. Used to test that
  //   killing an isolate with a pending send doesn't leak a hung Future.
  int injectFailureCount = 0;
  bool injectHangNext = false;
  // `__inject_readhandle_zero_next`: makes the next `readHandle` reply
  // with an empty Uint8List instead of calling `client.readHandle`, to
  // simulate a server returning 0 bytes mid-stream (truncated file).
  bool injectReadHandleZeroNext = false;

  cmdPort.listen((msg) {
    if (msg is! Map) return;
    final cmd = msg['cmd'] as String;
    final replyTo = msg['replyTo'] as SendPort?;

    // Apply pending fault injection BEFORE the normal switch, unless the
    // command itself is an injection knob (those always run).
    if (!cmd.startsWith('__inject_')) {
      if (injectHangNext) {
        injectHangNext = false;
        // Intentionally never reply — the test verifies that the main
        // isolate notices the worker dies and rejects pending sends.
        return;
      }
      if (injectFailureCount > 0) {
        injectFailureCount--;
        replyTo?.send(
          ErrorMsg(
            'Injected connection failure',
            null,
            Smb2ErrorType.connection.index,
          ),
        );
        return;
      }
    }

    try {
      switch (cmd) {
        // ── Test-only fault injection commands ────────────────────────
        case '__inject_fail_next_n':
          injectFailureCount = msg['count'] as int;
          replyTo?.send(true);
          return;
        case '__inject_hang':
          injectHangNext = true;
          replyTo?.send(true);
          return;
        case '__inject_readhandle_zero_next':
          injectReadHandleZeroNext = true;
          replyTo?.send(true);
          return;

        case 'listDir':
          replyTo?.send(client.listDirectory(msg['path'] as String));
        case 'listShares':
          replyTo?.send(
            client.listShares(
              host: msg['host'] as String,
              user: msg['user'] as String?,
              password: msg['password'] as String?,
              domain: msg['domain'] as String?,
            ),
          );
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
            replyTo?.send(ErrorMsg('Invalid handle'));
            return;
          }
          client.fsync(fhSync);
          replyTo?.send(true);
        case 'ftruncate':
          final fhTrunc = handles[msg['handleId'] as int];
          if (fhTrunc == null) {
            replyTo?.send(ErrorMsg('Invalid handle'));
            return;
          }
          client.ftruncate(fhTrunc, msg['length'] as int);
          replyTo?.send(true);

        // ── Write commands ────────────────────────────────────────────
        case 'writeRange':
          final writeRangeData = (msg['data'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          client.writeFileRange(
            msg['path'] as String,
            writeRangeData,
            offset: msg['offset'] as int? ?? 0,
          );
          replyTo?.send(true);
        case 'writeFile':
          final writeFileData = (msg['data'] as TransferableTypedData)
              .materialize()
              .asUint8List();
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
        case 'setFileTimes':
          final modifiedUs = msg['modifiedUs'] as int?;
          final accessedUs = msg['accessedUs'] as int?;
          client.setFileTimes(
            msg['path'] as String,
            modified: modifiedUs == null
                ? null
                : DateTime.fromMicrosecondsSinceEpoch(modifiedUs, isUtc: true),
            accessed: accessedUs == null
                ? null
                : DateTime.fromMicrosecondsSinceEpoch(accessedUs, isUtc: true),
          );
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
            replyTo?.send(ErrorMsg('Invalid handle'));
            return;
          }
          if (injectReadHandleZeroNext) {
            injectReadHandleZeroNext = false;
            replyTo?.send(TransferableTypedData.fromList([Uint8List(0)]));
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
            replyTo?.send(ErrorMsg('Invalid handle'));
            return;
          }
          final writeHandleData = (msg['data'] as TransferableTypedData)
              .materialize()
              .asUint8List();
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
            try {
              client.closeHandle(fh);
            } catch (_) {}
          }
          handles.clear();
          client.disconnect();
          replyTo?.send(true);
          cmdPort.close();
      }
    } catch (e) {
      if (e is Smb2Exception) {
        replyTo?.send(ErrorMsg(e.message, e.errorCode, e.type.index));
      } else {
        replyTo?.send(ErrorMsg(e.toString()));
      }
    }
  });
}
