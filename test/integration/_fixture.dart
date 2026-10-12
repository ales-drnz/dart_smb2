// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Shared setup of the integration suites: the Samba container's settings
/// (from `.env.test`, or the defaults of `.env.test.example`), connected
/// clients and pools, and a scratch directory per suite on the share.
library;

import 'dart:io';
import 'dart:math';

import 'package:dart_smb2/dart_smb2.dart';

/// The seed file `bootstrap.dart` keeps on the share: 1 MiB of zeros.
const seedFile = 'dart_smb2_seed.bin';

/// Size of [seedFile].
const seedSize = 1024 * 1024;

/// The Samba container's settings.
final class TestServer {
  final String host;
  final String share;
  final String user;
  final String password;

  const TestServer(this.host, this.share, this.user, this.password);

  /// Reads `test/integration/.env.test`, falling back to the example file.
  factory TestServer.load() {
    var file = File('test/integration/.env.test');
    if (!file.existsSync()) file = File('test/integration/.env.test.example');
    final env = <String, String>{};
    for (final line in file.readAsLinesSync()) {
      final t = line.trim();
      final eq = t.indexOf('=');
      if (t.isEmpty || t.startsWith('#') || eq <= 0) continue;
      env[t.substring(0, eq).trim()] = t.substring(eq + 1).trim();
    }
    final port = env['SMB2_HOST_PORT'] ?? '445';
    return TestServer(
      port == '445' ? '127.0.0.1' : '127.0.0.1:$port',
      env['SMB2_SHARE'] ?? 'public',
      env['SMB2_USER'] ?? 'testuser',
      env['SMB2_PASS'] ?? 'testpass',
    );
  }
}

/// The server of this run.
final server = TestServer.load();

/// A connected sync client.
Smb2Client connectClient() => Smb2Client()
  ..connect(
    host: server.host,
    share: server.share,
    user: server.user,
    password: server.password,
  );

/// A connected pool.
Future<Smb2Pool> connectPool({int workers = 2, Duration? timeout}) =>
    Smb2Pool.connect(
      host: server.host,
      share: server.share,
      user: server.user,
      password: server.password,
      workers: workers,
      timeout: timeout ?? const Duration(seconds: 30),
    );

/// A directory of its own on the share for one suite, so suites never see
/// each other's files. Created by [create], removed with everything in it
/// by [delete].
final class Scratch {
  /// Share-relative path of the directory.
  final String dir;

  Scratch(String suite)
    : dir = 'zz_${suite}_${Random().nextInt(1 << 32).toRadixString(16)}';

  /// [name] inside the directory.
  String path(String name) => '$dir/$name';

  /// Creates the directory.
  void create() {
    final c = connectClient();
    try {
      c.mkdir(dir);
    } finally {
      c.disconnect();
    }
  }

  /// Removes the directory and its content.
  void delete() {
    final c = connectClient();
    try {
      _deleteTree(c, dir);
    } finally {
      c.disconnect();
    }
  }
}

void _deleteTree(Smb2Client c, String dir) {
  for (final e in c.listDirectory(dir)) {
    final p = '$dir/${e.name}';
    e.isDirectory ? _deleteTree(c, p) : c.deleteFile(p);
  }
  c.rmdir(dir);
}
