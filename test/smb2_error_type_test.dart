// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

void main() {
  group('Smb2ErrorType.fromErrno', () {
    test('maps ENOENT to fileNotFound', () {
      expect(Smb2ErrorType.fromErrno(2), Smb2ErrorType.fileNotFound);
    });

    test('maps EACCES to accessDenied', () {
      expect(Smb2ErrorType.fromErrno(13), Smb2ErrorType.accessDenied);
    });

    test('maps EIO to io', () {
      expect(Smb2ErrorType.fromErrno(5), Smb2ErrorType.io);
    });

    test('maps EINVAL to invalidParam', () {
      expect(Smb2ErrorType.fromErrno(22), Smb2ErrorType.invalidParam);
    });

    test('maps ENOSPC to diskFull', () {
      expect(Smb2ErrorType.fromErrno(28), Smb2ErrorType.diskFull);
    });

    test('maps EEXIST to alreadyExists', () {
      expect(Smb2ErrorType.fromErrno(17), Smb2ErrorType.alreadyExists);
    });

    test('maps ENOTDIR to notADirectory', () {
      expect(Smb2ErrorType.fromErrno(20), Smb2ErrorType.notADirectory);
    });

    test('maps EPIPE to connection', () {
      expect(Smb2ErrorType.fromErrno(32), Smb2ErrorType.connection);
    });

    // macOS errno values
    test('maps macOS ETIMEDOUT (60) to timeout', () {
      expect(Smb2ErrorType.fromErrno(60), Smb2ErrorType.timeout);
    });

    test('maps macOS ECONNREFUSED (61) to auth', () {
      expect(Smb2ErrorType.fromErrno(61), Smb2ErrorType.auth);
    });

    test('maps macOS ECONNRESET (54) to connection', () {
      expect(Smb2ErrorType.fromErrno(54), Smb2ErrorType.connection);
    });

    test('maps macOS ENETRESET (52) to connection', () {
      expect(Smb2ErrorType.fromErrno(52), Smb2ErrorType.connection);
    });

    test('maps macOS ECONNABORTED (53) to connection', () {
      expect(Smb2ErrorType.fromErrno(53), Smb2ErrorType.connection);
    });

    test('maps macOS ENOTCONN (57) to connection', () {
      expect(Smb2ErrorType.fromErrno(57), Smb2ErrorType.connection);
    });

    test('maps macOS ENETDOWN (50) to connection', () {
      expect(Smb2ErrorType.fromErrno(50), Smb2ErrorType.connection);
    });

    test('maps macOS ENETUNREACH (51) to connection', () {
      expect(Smb2ErrorType.fromErrno(51), Smb2ErrorType.connection);
    });

    test('maps macOS EHOSTDOWN (64) to connection', () {
      expect(Smb2ErrorType.fromErrno(64), Smb2ErrorType.connection);
    });

    test('maps macOS EHOSTUNREACH (65) to connection', () {
      expect(Smb2ErrorType.fromErrno(65), Smb2ErrorType.connection);
    });

    // Linux errno values
    test('maps Linux ETIMEDOUT (110) to timeout', () {
      expect(Smb2ErrorType.fromErrno(110), Smb2ErrorType.timeout);
    });

    test('maps Linux ECONNREFUSED (111) to auth', () {
      expect(Smb2ErrorType.fromErrno(111), Smb2ErrorType.auth);
    });

    test('maps Linux ECONNRESET (104) to connection', () {
      expect(Smb2ErrorType.fromErrno(104), Smb2ErrorType.connection);
    });

    test('maps Linux ECONNABORTED (103) to connection', () {
      expect(Smb2ErrorType.fromErrno(103), Smb2ErrorType.connection);
    });

    test('maps Linux ENETDOWN (100) to connection', () {
      expect(Smb2ErrorType.fromErrno(100), Smb2ErrorType.connection);
    });

    test('maps Linux ENETUNREACH (101) to connection', () {
      expect(Smb2ErrorType.fromErrno(101), Smb2ErrorType.connection);
    });

    test('maps Linux ENETRESET (102) to connection', () {
      expect(Smb2ErrorType.fromErrno(102), Smb2ErrorType.connection);
    });

    test('maps Linux EHOSTDOWN (112) to connection', () {
      expect(Smb2ErrorType.fromErrno(112), Smb2ErrorType.connection);
    });

    test('maps Linux EHOSTUNREACH (113) to connection', () {
      expect(Smb2ErrorType.fromErrno(113), Smb2ErrorType.connection);
    });

    test('maps unknown errno to unknown', () {
      expect(Smb2ErrorType.fromErrno(9999), Smb2ErrorType.unknown);
    });

    test('maps 0 to unknown', () {
      expect(Smb2ErrorType.fromErrno(0), Smb2ErrorType.unknown);
    });
  });

  group('Smb2ErrorType.isConnectionError', () {
    test('connection is retriable', () {
      expect(Smb2ErrorType.connection.isConnectionError, isTrue);
    });

    test('timeout is retriable', () {
      expect(Smb2ErrorType.timeout.isConnectionError, isTrue);
    });

    test('fileNotFound is not retriable', () {
      expect(Smb2ErrorType.fileNotFound.isConnectionError, isFalse);
    });

    test('auth is not retriable', () {
      expect(Smb2ErrorType.auth.isConnectionError, isFalse);
    });

    test('accessDenied is not retriable', () {
      expect(Smb2ErrorType.accessDenied.isConnectionError, isFalse);
    });

    test('unknown is not retriable', () {
      expect(Smb2ErrorType.unknown.isConnectionError, isFalse);
    });
  });

  group('Smb2ErrorType.fromMessage', () {
    // The exact wording of these strings comes from libsmb2's
    // smb2_set_error() call sites in socket.c, libsmb2.c, and sync.c.
    // They are emitted on transport failures *without* updating the NT
    // status, so errno-based classification cannot catch them.

    test('classifies POLLHUP socket error as connection', () {
      expect(
        Smb2ErrorType.fromMessage('smb2_service: POLLHUP, socket error.'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies POLLERR socket error as connection', () {
      expect(
        Smb2ErrorType.fromMessage('smb2_service: POLLERR, Unknown socket error.'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies smb2_service socket error variant as connection', () {
      expect(
        Smb2ErrorType.fromMessage('smb2_service: socket error Connection reset by peer(54).'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "Read from socket failed" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('Read from socket failed, errno:104. Closing socket.'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "remote closed connection" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('Read from socket failed, remote closed connection.'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "Error when writing to" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('Error when writing to socket'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "trying to write but not connected" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('trying to write but not connected'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "Not Connected to Server" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('Not Connected to Server'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "Socket connect failed" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('Socket connect failed with 111'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "Failed to open smb2 socket" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('Failed to open smb2 socket. Errno:Address family not supported(47).'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "Connect failed with errno" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('Connect failed with errno : Connection refused(61)'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "No connected tree-id" as connection', () {
      // Server-side idle session teardown: socket alive, tree gone.
      expect(
        Smb2ErrorType.fromMessage('No connected tree-id 12345678 to select'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "No tree-id connected" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('No tree-id connected'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies upstream typo "alreeady disconnected" as connection', () {
      expect(
        Smb2ErrorType.fromMessage('connection is alreeady disconnected or was never connected'),
        Smb2ErrorType.connection,
      );
    });

    test('classifies "Timeout expired" as timeout', () {
      expect(
        Smb2ErrorType.fromMessage('Timeout expired and no connection exists'),
        Smb2ErrorType.timeout,
      );
    });

    test('matches case-insensitively', () {
      expect(
        Smb2ErrorType.fromMessage('SMB2_SERVICE: POLLHUP, SOCKET ERROR.'),
        Smb2ErrorType.connection,
      );
    });

    test('returns unknown for unrelated messages', () {
      expect(
        Smb2ErrorType.fromMessage('Wrong signature in received pdu'),
        Smb2ErrorType.unknown,
      );
    });

    test('returns unknown for empty message', () {
      expect(Smb2ErrorType.fromMessage(''), Smb2ErrorType.unknown);
    });
  });

  group('Smb2ErrorType.classify', () {
    test('prefers message classification over stale errno', () {
      // Reproduces the original bug: libsmb2 emits a POLLHUP message but
      // nterror still holds a stale ENOENT from a prior successful stat.
      // Without the message-first rule, classify would say fileNotFound.
      expect(
        Smb2ErrorType.classify('smb2_service: POLLHUP, socket error.', 2),
        Smb2ErrorType.connection,
      );
    });

    test('falls through to errno when message is unrelated', () {
      expect(
        Smb2ErrorType.classify('Create failed with status', 13),
        Smb2ErrorType.accessDenied,
      );
    });

    test('falls through to errno when message is empty', () {
      expect(
        Smb2ErrorType.classify('', 32),
        Smb2ErrorType.connection,
      );
    });

    test('returns unknown when neither signal helps', () {
      expect(
        Smb2ErrorType.classify('Some unrelated text', 9999),
        Smb2ErrorType.unknown,
      );
    });

    test('reproduces the original POLLHUP bug — errno=0', () {
      // The exact error from the bug report.
      const msg = 'Open failed: smb2_service failed with : '
          'smb2_service: POLLHUP, socket error.';
      final type = Smb2ErrorType.classify(msg, 0);
      expect(type, Smb2ErrorType.connection);
      expect(type.isConnectionError, isTrue);
    });
  });

  group('Smb2Exception', () {
    test('carries error type', () {
      final e = Smb2Exception('test', 2, Smb2ErrorType.fileNotFound);
      expect(e.type, Smb2ErrorType.fileNotFound);
      expect(e.errorCode, 2);
      expect(e.isConnectionError, isFalse);
    });

    test('defaults to unknown type', () {
      const e = Smb2Exception('test');
      expect(e.type, Smb2ErrorType.unknown);
      expect(e.isConnectionError, isFalse);
    });

    test('isConnectionError delegates to type', () {
      final e = Smb2Exception('broken pipe', 32, Smb2ErrorType.connection);
      expect(e.isConnectionError, isTrue);
    });

    test('toString includes type', () {
      final e = Smb2Exception('file not found', 2, Smb2ErrorType.fileNotFound);
      expect(e.toString(), contains('fileNotFound'));
      expect(e.toString(), contains('errno=2'));
    });
  });
}
