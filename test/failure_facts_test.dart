// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Which of libsmb2's leftovers a failure may trust: the message and the NT
/// status libsmb2 keeps from earlier calls. Needs no server.
library;

import 'package:dart_smb2/src/smb2_client.dart';
import 'package:test/test.dart';

const notFound = 0xC0000034; // OBJECT_NAME_NOT_FOUND, ENOENT
const collision = 0xC0000035; // OBJECT_NAME_COLLISION, EEXIST
const isDir = 0xC00000BA; // FILE_IS_A_DIRECTORY, EPERM

int errnoOf(int status) => switch (status) {
  notFound => 2,
  collision => 17,
  isDir => 1,
  _ => 0,
};

String nameOf(int status) => switch (status) {
  notFound => 'STATUS_OBJECT_NAME_NOT_FOUND',
  collision => 'STATUS_OBJECT_NAME_COLLISION',
  isDir => 'STATUS_FILE_IS_A_DIRECTORY',
  _ => 'Unknown',
};

({String message, int? ntStatus, int? errno}) facts(
  String message,
  int status, {
  int? rc,
}) => failureFacts(
  message: message,
  status: status,
  rc: rc,
  errnoOf: errnoOf,
  nameOf: nameOf,
);

void main() {
  group('a call that returns an errno', () {
    test('a quoted status that agrees counts', () {
      final f = facts(
        'Open failed with (0xc0000035) STATUS_OBJECT_NAME_COLLISION.',
        collision,
        rc: -17,
      );
      expect(f.ntStatus, collision);
      expect(f.errno, 17);
      expect(f.message, contains('COLLISION'));
    });

    test('a quoted status that disagrees is stale: no status, no message', () {
      final f = facts(
        'Open failed with (0xc0000034) STATUS_OBJECT_NAME_NOT_FOUND.',
        notFound,
        rc: -17,
      );
      expect(f.ntStatus, isNull);
      expect(f.errno, 17);
      expect(f.message, isEmpty);
    });

    test('a named status that disagrees is stale too', () {
      final f = facts(
        'Stat failed: STATUS_OBJECT_NAME_NOT_FOUND',
        notFound,
        rc: -17,
      );
      expect(f.message, isEmpty);
      expect(f.ntStatus, isNull);
    });

    test('an unnamed status counts when it agrees', () {
      expect(facts('Rename failed', collision, rc: -17).ntStatus, collision);
      expect(facts('Rename failed', notFound, rc: -17).ntStatus, isNull);
    });
  });

  group('a call without an errno', () {
    test('a pointer result takes the status its message quotes', () {
      final f = facts(
        'Open failed with (0xc0000034) STATUS_OBJECT_NAME_NOT_FOUND.',
        notFound,
      );
      expect(f.ntStatus, notFound);
      expect(f.errno, 2);
    });

    test('a pointer result ignores a status its message does not name', () {
      final f = facts('Failed to open', notFound);
      expect(f.ntStatus, isNull);
      expect(f.errno, isNull);
    });

    test('rc -1 is EPERM only through a status the message names', () {
      final named = facts(
        'Create failed with status STATUS_FILE_IS_A_DIRECTORY.',
        isDir,
        rc: -1,
      );
      expect(named.ntStatus, isDir);
      expect(named.errno, 1);
      final stale = facts('Something failed', isDir, rc: -1);
      expect(stale.ntStatus, isNull);
      expect(stale.errno, isNull);
    });
  });

  test('a name counts whole, not as the prefix of a longer one', () {
    // STATUS_OBJECT_NAME_NOT_FOUND is not named by
    // STATUS_OBJECT_NAME_NOT_FOUND_EXTRA.
    final f = facts(
      'Open failed: STATUS_OBJECT_NAME_NOT_FOUND_EXTRA',
      notFound,
    );
    expect(f.ntStatus, isNull);
  });

  test('a transport failure carries neither status nor errno', () {
    final f = facts('Read from socket failed', notFound, rc: -104);
    expect(f.ntStatus, isNull);
    expect(f.errno, isNull);
    expect(f.message, 'Read from socket failed');
  });
}
