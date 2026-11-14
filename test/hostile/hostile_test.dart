// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Drives a subset of the hostile-server cases against the pinned
/// binary through `Smb2Client`, and records what the Dart layer and the VM
/// do with each one.
///
/// The fake server is libsmb2-scripts' verify/hostile/hostile_server.py.
/// Point the suite at that directory and run it on its own preset:
///
///     DART_SMB2_HOSTILE_DIR=../libsmb2-scripts/verify/hostile \
///         dart test -P hostile test/hostile
///
/// Each case runs the client in a child process (hostile_client.dart) so a
/// crash or a hang of the VM is an outcome this suite reports rather than
/// the end of the run. The `_overrun` guard lives in the read and write
/// paths; the cases that reach it are `read_datalen_*` and `write_count_*`.
@Tags(['hostile'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String get _hostileDir {
  final d = Platform.environment['DART_SMB2_HOSTILE_DIR'];
  if (d == null || d.isEmpty) {
    throw StateError(
      'set DART_SMB2_HOSTILE_DIR to libsmb2-scripts/verify/hostile',
    );
  }
  return d;
}

Map<String, String> get _noPreload {
  final e = Map<String, String>.from(Platform.environment);
  e.remove('LD_PRELOAD');
  return e;
}

typedef CaseRun = ({
  String outcome,
  Map<String, Object?>? error,
  Object? result,
  int exitCode,
});

/// One client run against one case: starts the fake server on a free port,
/// runs hostile_client.dart as a child, and returns what happened.
Future<CaseRun> run(String caseName, String op, {String? version}) async {
  final picker = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = picker.port;
  await picker.close();

  final server = await Process.start('python3', [
    '$_hostileDir/hostile_server.py',
    '--port',
    '$port',
    '--case',
    caseName,
  ], environment: _noPreload);
  final serverErr = StringBuffer();
  unawaited(server.stdout.drain<void>());
  server.stderr.transform(utf8.decoder).listen(serverErr.write);
  await _waitListening(port);

  try {
    final client =
        await Process.run(Platform.resolvedExecutable, [
          'run',
          'test/hostile/hostile_client.dart',
          '$port',
          op,
          ?version,
        ], environment: _noPreload).timeout(
          const Duration(seconds: 30),
          onTimeout: () => ProcessResult(0, -99, '', 'client timed out'),
        );
    final line = const LineSplitter()
        .convert(client.stdout as String)
        .firstWhere((l) => l.trim().startsWith('{'), orElse: () => '');
    // Dart prints a crash dump on a native fault; exit != 0 with no JSON is
    // a VM crash or hang.
    if (line.isEmpty) {
      return (
        outcome: client.exitCode == 0 ? 'no-output' : 'vm-crash',
        error: null,
        result: null,
        exitCode: client.exitCode,
      );
    }
    final decoded = jsonDecode(line) as Map<String, Object?>;
    if (decoded.containsKey('error')) {
      return (
        outcome: 'clean-error',
        error: decoded['error']! as Map<String, Object?>,
        result: null,
        exitCode: client.exitCode,
      );
    }
    return (
      outcome: 'accepted',
      error: null,
      result: decoded['result'],
      exitCode: client.exitCode,
    );
  } finally {
    server.kill();
    await server.exitCode;
  }
}

/// Waits until something accepts a connection on [port] (the fake server is
/// up) or a short deadline passes.
Future<void> _waitListening(int port) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final s = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(milliseconds: 200),
      );
      await s.close();
      s.destroy();
      return;
    } on SocketException {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }
}

void main() {
  // The cases this suite drives, and the client op that reaches each.
  // "survive" is the hard assertion: the VM must come back, with either a
  // clean Smb2Exception or an accepted (and self-consistent) result. A
  // vm-crash fails the test, except where it is the documented finding.
  const cases = <(String, String, String?)>[
    // Baselines.
    ('none', 'echo', null),
    ('none', 'read', null),
    // The _overrun paths named in the claim.
    ('read_datalen_gt_asked_all_sent', 'read', null),
    ('read_datalen_asked_plus1', 'read', null),
    ('read_datalen_1m_for_100', 'read', null),
    ('read_datalen_ffffffff', 'read', null),
    ('read_datalen_gt_sent_consistent', 'read', null),
    ('write_count_gt_sent', 'write', null),
    ('write_count_sent_plus1', 'write', null),
    ('write_count_ffffffff', 'write', null),
    // NetBIOS length edits the claim asks about.
    ('nb_len_00ffffff_close_echo', 'echo', null),
    ('nb_len_63_echo', 'echo', null),
    // Directory / info / readlink decoders.
    ('qdir_next_entry_ffffffff', 'list', null),
    ('qdir_name_length_ffffffff', 'list', null),
    ('qinfo_all_info_name_length_ffffffff', 'stat', null),
    ('readlink_substitute_len_ffff', 'readlink', null),
    ('readlink_buffer_cut_8', 'readlink', null),
    // Share enumeration (DCE/RPC NDR).
    ('shareenum_count_ffffffff', 'shares', null),
    ('shareenum_string_actual_gt_max', 'shares', null),
    ('shareenum_stub_cut_mid_string', 'shares', null),
  ];

  group('the VM survives a hostile server', () {
    for (final (caseName, op, version) in cases) {
      test('$caseName ($op)', () async {
        final r = await run(caseName, op, version: version);
        printOnFailure(
          'outcome=${r.outcome} exit=${r.exitCode} '
          'error=${r.error} result=${r.result}',
        );
        expect(
          r.outcome,
          isNot('vm-crash'),
          reason: 'the VM crashed instead of throwing',
        );
        expect(r.outcome, anyOf('clean-error', 'accepted'));
      });
    }
  });

  group('_overrun and the read/write accounting', () {
    // READ returning more than asked: the native patch_read_write_eof.py
    // layer (smb2_process_read_fixed) rejects "Read returned N bytes, M
    // were asked for" before the Dart `_overrun` is reached, so the Dart
    // call sees a clean error, never bytes past its buffer.
    test('READ reporting more than asked is a clean error', () async {
      final r = await run('read_datalen_gt_asked_all_sent', 'read');
      printOnFailure('${r.outcome} ${r.error}');
      expect(r.outcome, 'clean-error');
    });

    // WRITE reporting more than sent: the native side passes the inflated
    // Count through, and the Dart `_overrun` guard in the write path is
    // what turns it into an error.
    test('WRITE reporting more than sent is a clean error', () async {
      final r = await run('write_count_gt_sent', 'write');
      printOnFailure('${r.outcome} ${r.error}');
      expect(r.outcome, 'clean-error');
      expect(r.error?['type'], 'io');
    });
  });

  // What libsmb2-r12 did with these, and r13 no longer does.
  group('libsmb2-r13', () {
    // The acknowledgement of a break had no callback, and the reply to it
    // made the client call address 0: the VM died with SIGSEGV.
    for (final name in const [
      'unsolicited_oplock_break_x5',
      'unsolicited_oplock_break_flood',
    ]) {
      test('$name does not stop the VM', () async {
        final r = await run(name, 'echo');
        printOnFailure('outcome=${r.outcome} exit=${r.exitCode}');
        expect(r.outcome, 'accepted');
      });
    }

    // A reply that stopped after its header, or a session setup that never
    // ended, kept the call waiting whatever the timeout said: the child
    // was killed after 30 seconds.
    for (final (name, op) in const [
      ('negotiate_header_only', 'echo'),
      ('nb_len_plus100_stall_negotiate', 'echo'),
      ('session_setup2_body_cut_to_4', 'echo'),
      ('tree_connect_header_only', 'echo'),
      ('ss_more_processing_forever', 'echo'),
      ('echo_header_only', 'echo'),
      ('read_header_only', 'read'),
      ('read_datalen_gt_sent_stall', 'read'),
    ]) {
      test('$name ends in an error', () async {
        final r = await run(name, op);
        printOnFailure('outcome=${r.outcome} ${r.error}');
        expect(r.outcome, 'clean-error');
        expect(r.error?['type'], anyOf('timeout', 'connection', 'auth'));
      });
    }
  });
}
