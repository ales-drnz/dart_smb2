// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// First-run bootstrap for the dart_smb2 integration test suite.
///
/// Idempotent — safe to re-run. Performs in order:
///   1. Reads `.env.test` (copy `.env.test.example` first).
///   2. Brings up the Samba container with `docker compose up -d --wait`.
///   3. Resolves the path to the libsmb2 dynamic library for the current
///      host (macOS or Linux). The `.dylib` / `.so` must already exist —
///      run `cd ../libsmb2-scripts && ./build lib-local` once after a
///      fresh clone.
///   4. Connects via `Smb2Pool` and seeds a known test file on the share.
///   5. Persists the configuration to `.bootstrap-cache.json` so test files
///      can call `poolFromCache()` without re-running this script.
///
/// Run:
///   dart run test/integration/bootstrap.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
// ignore: implementation_imports — bootstrap is internal tooling; it
// installs the test override so `Smb2Pool.connect()` below targets the
// dev-machine `.dylib` / `.so` instead of the platform-default loader
// name.
import 'package:dart_smb2/src/ffi/native_lib.dart';

const String _integrationDir = 'test/integration';
const String _envFile = '$_integrationDir/.env.test';
const String _cacheFile = '$_integrationDir/.bootstrap-cache.json';
const String _seedFileName = 'dart_smb2_seed.bin';

Future<void> main() async {
  if (!File(_envFile).existsSync()) {
    stderr.writeln(
      'Missing $_envFile. Copy $_envFile.example to $_envFile and edit it.',
    );
    exit(1);
  }

  final env = _readEnv(_envFile);
  final hostPort = int.parse(env['SMB2_HOST_PORT'] ?? '445');
  final share = env['SMB2_SHARE'] ?? 'public';
  final user = env['SMB2_USER'] ?? 'testuser';
  final password = env['SMB2_PASS'] ?? 'testpass';

  // ── Docker up ──────────────────────────────────────────────────────────
  // Create the bind-mounted share dir ourselves: on Linux a missing host
  // path is created by the Docker daemon as root, and the container's
  // testuser (uid 1000) then gets STATUS_ACCESS_DENIED on every write.
  Directory('$_integrationDir/volumes/share').createSync(recursive: true);
  await _runOrDie(
    ['docker', 'compose', '--env-file', '.env.test', 'up', '-d', '--wait'],
    workingDir: _integrationDir,
  );

  // ── Resolve libsmb2 path for the current host platform ─────────────────
  final libPath = _resolveLibPath();
  stdout.writeln('Using libsmb2 at: $libPath');

  // ── Smoke connect + seed ───────────────────────────────────────────────
  final host = hostPort == 445 ? '127.0.0.1' : '127.0.0.1:$hostPort';

  // libsmb2 doesn't accept "host:port" in our wrapper — for non-default
  // ports the user must rebuild with a custom port. Warn loudly.
  if (hostPort != 445) {
    stderr.writeln(
      'WARNING: SMB2_HOST_PORT=$hostPort but the libsmb2 wrapper does not '
      'support custom ports. Either bind to 445 or extend smb2_wrapper.c '
      'with smb2_set_port().',
    );
  }

  stdout.writeln('Connecting to smb://$host/$share as $user...');
  debugLibSmb2PathOverride = libPath;
  final pool = await _connectWithRetry(
    host: host,
    share: share,
    user: user,
    password: password,
  );

  // Drop a known seed file (1 MiB of zero-bytes) so read/handle tests have
  // a stable target. Idempotent: only writes if missing or wrong size.
  const seedSize = 1024 * 1024;
  final exists = await pool.exists(_seedFileName);
  var skipWrite = false;
  if (exists) {
    final size = await pool.fileSize(_seedFileName);
    if (size == seedSize) skipWrite = true;
  }
  if (!skipWrite) {
    stdout.writeln('Seeding $_seedFileName (1 MiB)...');
    await pool.writeFile(_seedFileName, Uint8List(seedSize));
  } else {
    stdout.writeln('Seed already present, skipping.');
  }

  await pool.disconnect();

  // ── Persist cache ──────────────────────────────────────────────────────
  final cache = <String, dynamic>{
    'host': host,
    'share': share,
    'user': user,
    'password': password,
    'libPath': libPath,
    'testFile': _seedFileName,
    'bootstrapedAt': DateTime.now().toUtc().toIso8601String(),
  };
  File(_cacheFile).writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(cache),
  );
  stdout.writeln('Wrote $_cacheFile');
  stdout.writeln('Done. Run `dart test --tags integration` to start.');
}

// ─── Helpers ─────────────────────────────────────────────────────────────

Map<String, String> _readEnv(String path) {
  final out = <String, String>{};
  for (final line in File(path).readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final eq = trimmed.indexOf('=');
    if (eq <= 0) continue;
    out[trimmed.substring(0, eq).trim()] = trimmed.substring(eq + 1).trim();
  }
  return out;
}

Future<void> _runOrDie(List<String> argv, {String? workingDir}) async {
  stdout.writeln('\$ ${argv.join(' ')}');
  final r = await Process.run(
    argv.first,
    argv.sublist(1),
    workingDirectory: workingDir,
  );
  stdout.write(r.stdout);
  stderr.write(r.stderr);
  if (r.exitCode != 0) exit(r.exitCode);
}

/// Pick the right per-platform libsmb2 path from the consumer dirs. Falls
/// back to a $SMB2_LIB_PATH override.
String _resolveLibPath() {
  final override = Platform.environment['SMB2_LIB_PATH'];
  if (override != null && File(override).existsSync()) return override;

  String? candidate;
  if (Platform.isMacOS) {
    candidate =
        'macos/dart_smb2/Frameworks/libsmb2.xcframework/macos-arm64_x86_64/libsmb2.framework/Versions/A/libsmb2';
  } else if (Platform.isLinux) {
    // Pick the host arch's bundled .so. Falls back to the canonical link
    // if generate_checksums.sh has been run.
    final arch = _linuxArch();
    candidate = 'linux/libs/$arch/libsmb2.so';
  }
  if (candidate != null && File(candidate).existsSync()) return candidate;

  stderr.writeln(
    'Could not locate libsmb2 native binary. Run `./build lib-local` from '
    'libsmb2-scripts/ to install the prebuilt library, or set '
    '\$SMB2_LIB_PATH to an absolute path.',
  );
  exit(1);
}

String _linuxArch() {
  final result = Process.runSync('uname', ['-m']);
  final m = (result.stdout as String).trim();
  return (m == 'arm64' || m == 'aarch64') ? 'aarch64' : 'x86_64';
}

Future<Smb2Pool> _connectWithRetry({
  required String host,
  required String share,
  required String user,
  required String password,
}) async {
  Object? lastError;
  for (var attempt = 1; attempt <= 6; attempt++) {
    try {
      return await Smb2Pool.connect(
        host: host,
        share: share,
        user: user,
        password: password,
        workers: 1,
        timeoutSeconds: 10,
      );
    } catch (e) {
      lastError = e;
      stderr.writeln('Connect attempt $attempt failed: $e. Retrying...');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }
  throw StateError('Could not connect to Samba after 6 attempts: $lastError');
}
