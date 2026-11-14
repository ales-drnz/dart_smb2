// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// One client run against the hostile fake server, in a process of its own:
/// hostile_test.dart starts it, so a crash or a hang of the VM is an
/// outcome the test can see instead of the end of the test run.
///
///     dart run test/hostile/hostile_client.dart <port> <op> [version]
///
/// Prints one line of JSON: `{"result": ...}` or `{"error": {type,
/// message, ntStatus, errno}}`, then `done`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';

void main(List<String> args) {
  final host = '127.0.0.1:${args[0]}';
  final op = args[1];
  final version = args.length > 2
      ? Smb2Version.values.firstWhere((v) => v.name == args[2])
      : Smb2Version.any;
  const timeout = Duration(seconds: 2);
  Object? result;
  Map<String, Object?>? error;
  try {
    if (op == 'shares') {
      final shares = Smb2Client.listShares(
        host: host,
        user: 'testuser',
        password: 'testpass',
        timeout: timeout,
      );
      result = [
        for (final s in shares) [s.name.length, s.remark.length],
      ];
    } else {
      final client = Smb2Client()
        ..connect(
          host: host,
          share: 'public',
          user: 'testuser',
          password: 'testpass',
          timeout: timeout,
          version: version,
        );
      switch (op) {
        case 'echo':
          client.echo();
          result = 'ok';
        case 'list':
          final entries = client.listDirectory('dir');
          result = [for (final e in entries.take(20)) e.name.length];
        case 'stat':
          final s = client.stat('dir/file.bin');
          result = [s.size, s.modified.millisecondsSinceEpoch];
        case 'statvfs':
          final s = client.statvfs('dir');
          result = [s.blockSize, s.totalBlocks];
        case 'readlink':
          result = client.readlink('dir/link').length;
        case 'read':
          // Handle reads of the harness sizes: 1, 100, 4096 bytes.
          final h = client.openFile('dir/file.bin');
          final sizes = <int>[];
          try {
            for (final n in [1, 100, 4096]) {
              final Uint8List data = client.readFromHandle(h, length: n);
              sizes.add(data.length);
              // Touch every byte the call says it returned.
              var x = 0;
              for (final b in data) {
                x ^= b;
              }
              sizes.add(x & 0);
            }
          } finally {
            client.closeHandle(h);
          }
          result = sizes;
        case 'write':
          final h = client.openFileWrite('dir/file.bin');
          try {
            for (final n in [1, 4096, 70000]) {
              client.writeToHandle(h, Uint8List(n)..fillRange(0, n, 0x41));
            }
          } finally {
            client.closeHandle(h);
          }
          result = 'ok';
        case 'readfile':
          result = client.readFile('dir/file.bin').length;
        default:
          throw ArgumentError(op);
      }
      client.disconnect();
    }
  } on Smb2Exception catch (e) {
    error = {
      'type': e.type.name,
      'message': e.message,
      'ntStatus': e.ntStatus,
      'errno': e.errno,
    };
  }
  stdout.writeln(
    jsonEncode(error == null ? {'result': result} : {'error': error}),
  );
  stdout.writeln('done');
}
