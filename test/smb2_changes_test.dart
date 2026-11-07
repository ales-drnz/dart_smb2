// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The 0.3.0 API that needs no server: change notification types, the
// argument and state checks of the new calls, and the poll binding.

import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:dart_smb2/src/ffi/poll.dart';
import 'package:dart_smb2/src/smb2_types.dart' show changePath;
import 'package:test/test.dart';

Matcher throwsType(Smb2ErrorType type) =>
    throwsA(isA<Smb2Exception>().having((e) => e.type, 'type', type));

void main() {
  group('Smb2ChangeAction', () {
    test('reads every FILE_NOTIFY_INFORMATION action', () {
      for (final a in Smb2ChangeAction.values) {
        expect(Smb2ChangeAction.fromValue(a.value), a);
      }
      expect(Smb2ChangeAction.fromValue(1), Smb2ChangeAction.added);
      expect(Smb2ChangeAction.fromValue(5), Smb2ChangeAction.renamedTo);
    });

    test('an unknown action is an overflow', () {
      expect(Smb2ChangeAction.fromValue(42), Smb2ChangeAction.overflow);
      expect(Smb2ChangeAction.fromValue(0), Smb2ChangeAction.overflow);
    });
  });

  group('Smb2ChangeEvent', () {
    test('compares by action and path', () {
      const a = Smb2ChangeEvent(Smb2ChangeAction.added, 'x/y');
      expect(a, const Smb2ChangeEvent(Smb2ChangeAction.added, 'x/y'));
      expect(
        a.hashCode,
        const Smb2ChangeEvent(Smb2ChangeAction.added, 'x/y').hashCode,
      );
      expect(
        a == const Smb2ChangeEvent(Smb2ChangeAction.removed, 'x/y'),
        isFalse,
      );
      expect(a.toString(), 'Smb2ChangeEvent(added, x/y)');
    });
  });

  group('Smb2ChangeFilter', () {
    test('matches the CompletionFilter bits', () {
      expect(Smb2ChangeFilter.fileName, 0x1);
      expect(Smb2ChangeFilter.dirName, 0x2);
      expect(Smb2ChangeFilter.lastWrite, 0x10);
      expect(Smb2ChangeFilter.security, 0x100);
      expect(
        Smb2ChangeFilter.defaults,
        Smb2ChangeFilter.fileName |
            Smb2ChangeFilter.dirName |
            Smb2ChangeFilter.size |
            Smb2ChangeFilter.lastWrite,
      );
      expect(
        Smb2ChangeFilter.all & Smb2ChangeFilter.defaults,
        Smb2ChangeFilter.defaults,
      );
    });
  });

  group('changePath', () {
    test('joins the watched directory and the reported name', () {
      expect(changePath('Music', 'a.flac'), 'Music/a.flac');
      expect(changePath('/Music/', r'Album\01.flac'), 'Music/Album/01.flac');
      expect(changePath(r'\Music', 'x'), 'Music/x');
      expect(changePath('', 'x'), 'x');
      expect(changePath('Music', ''), 'Music');
    });
  });

  group('a client that is not connected', () {
    final client = Smb2Client();

    test('refuses the new calls with state', () {
      expect(
        () => client.rename('a', 'b', overwrite: true),
        throwsType(Smb2ErrorType.state),
      );
      expect(() => client.link('a', 'b'), throwsType(Smb2ErrorType.state));
      expect(() => client.symlink('a', 'b'), throwsType(Smb2ErrorType.state));
      expect(() => client.watch('a'), throwsType(Smb2ErrorType.state));
    });
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
