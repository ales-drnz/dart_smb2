// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The build hook bundles libsmb2 for this host and every binding resolves
/// in it, poll() included. Needs no server.
library;

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dart_smb2/src/ffi/libsmb2.g.dart';
import 'package:dart_smb2/src/ffi/poll.dart';
import 'package:dart_smb2/src/libsmb2_release.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import '_helpers.dart';

void main() {
  test('the bundled libsmb2 reports the pinned release', () {
    final release = smb2_scripts_release().cast<Utf8>().toDartString();
    expect(release, libsmb2Release);
    expect(libsmb2Mismatch(release), isNull);
  });

  test('a context can be created and destroyed', () {
    final ctx = smb2_init_context();
    expect(ctx, isNot(nullptr));
    smb2_destroy_context(ctx);
  });

  test('the addresses of the bound functions resolve', () {
    expect(
      Native.addressOf<NativeFunction<Pointer<smb2_context> Function()>>(
        smb2_init_context,
      ),
      isNot(nullptr),
    );
    expect(
      Native.addressOf<NativeFunction<Void Function(Pointer<smb2_context>)>>(
        smb2_destroy_context,
      ),
      isNot(nullptr),
    );
  });

  test('nterror_to_errno maps a status', () {
    expect(nterror_to_errno(0xC000006D), greaterThan(0));
    expect(nterror_to_errno(0), 0);
  });

  test(
    'contexts created in parallel isolates do not corrupt each other',
    () async {
      // Every isolate creates and destroys contexts at the same time. In
      // libsmb2-r8 every context went on one global list, unlocked, which
      // was corrupted within a few thousand rounds (the run crashed or
      // hung); r9 locked it, and since r10 client contexts stay off it
      // (upstream 565460d).
      await Future.wait([
        for (var i = 0; i < 8; i++)
          Isolate.run(() {
            for (var j = 0; j < 10000; j++) {
              smb2_destroy_context(smb2_init_context());
            }
          }),
      ]);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a client that is never connected refuses calls with state', () {
    final client = Smb2Client();
    expect(() => client.listDirectory(''), throwsType(Smb2ErrorType.state));
    expect(
      () => client.rename('a', 'b', overwrite: true),
      throwsType(Smb2ErrorType.state),
    );
    expect(() => client.link('a', 'b'), throwsType(Smb2ErrorType.state));
    expect(() => client.symlink('a', 'b'), throwsType(Smb2ErrorType.state));
    expect(() => client.watch('a'), throwsType(Smb2ErrorType.state));
  });

  test('connecting to a closed port fails with a network failure', () {
    // Port 1: nothing listens there. (Port 445 of the loopback is Windows'
    // own SMB server on a Windows host.)
    expect(
      () => Smb2Client().connect(
        host: '127.0.0.1:1',
        share: 'x',
        timeout: const Duration(seconds: 3),
      ),
      throwsA(
        isA<Smb2Exception>().having(
          (e) => e.isNetworkFailure,
          'isNetworkFailure',
          isTrue,
        ),
      ),
    );
  });

  group('pollSocket', () {
    test('a negative descriptor times out without events', () {
      // POSIX poll ignores a negative fd; WSAPoll fails on it.
      final rc = pollSocket(-1, 1, 0);
      expect(rc, Platform.isWindows ? -1 : 0);
    });

    test('waits for the time asked when nothing happens', () {
      final clock = Stopwatch()..start();
      pollSocket(-1, 1, 50);
      if (!Platform.isWindows) {
        expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(40));
      }
    });
  });
}
