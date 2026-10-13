// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The build hook bundles libsmb2 for this host and every binding resolves
/// in it. Needs no server.
library;

import 'dart:ffi';
import 'dart:isolate';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dart_smb2/src/ffi/libsmb2.g.dart';
import 'package:test/test.dart';

void main() {
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
      // Exercises the active_contexts lock patch: every isolate creates and
      // destroys contexts at the same time. Without the lock (libsmb2-r8)
      // the list is corrupted within a few thousand rounds, and the run
      // crashes or hangs.
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
    expect(
      () => Smb2Client().listDirectory(''),
      throwsA(
        isA<Smb2Exception>().having((e) => e.type, 'type', Smb2ErrorType.state),
      ),
    );
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
}
