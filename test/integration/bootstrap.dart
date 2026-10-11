// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Starts the Samba container and seeds the share for the integration
/// suites:
///
///     dart run test/integration/bootstrap.dart
///
/// Idempotent: a running container and a present seed are left alone.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';

import '_fixture.dart';

const _dir = 'test/integration';

Future<void> main() async {
  // On Linux a bind-mounted path Docker creates belongs to root, and the
  // container's testuser could not write to it.
  Directory('$_dir/volumes/share').createSync(recursive: true);
  final env = File('$_dir/.env.test').existsSync()
      ? '.env.test'
      : '.env.test.example';
  final up = await Process.run('docker', [
    'compose',
    '--env-file',
    env,
    'up',
    '-d',
    '--wait',
  ], workingDirectory: _dir);
  stdout.write(up.stdout);
  stderr.write(up.stderr);
  if (up.exitCode != 0) exit(up.exitCode);

  // Samba may still be starting its share service after the health check.
  Smb2Pool? pool;
  for (var attempt = 1; pool == null; attempt++) {
    try {
      pool = await connectPool(workers: 1);
    } on Smb2Exception catch (e) {
      if (attempt == 10) rethrow;
      stdout.writeln('Waiting for Samba ($e)');
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  }
  try {
    final present =
        await pool.exists(seedFile) &&
        await pool.fileSize(seedFile) == seedSize;
    if (!present) {
      stdout.writeln('Seeding $seedFile');
      await pool.writeFile(seedFile, Uint8List(seedSize));
    }
  } finally {
    await pool.disconnect();
  }
  stdout.writeln(
    'Ready: //${server.host}/${server.share}. '
    'Run `dart test -P integration`.',
  );
}
