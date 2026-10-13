// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

void main() {
  group('fromNtStatus', () {
    const cases = <int, Smb2ErrorType>{
      0xC000006D: Smb2ErrorType.auth, // LOGON_FAILURE
      0xC0000072: Smb2ErrorType.auth, // ACCOUNT_DISABLED
      0xC0000034: Smb2ErrorType.notFound, // OBJECT_NAME_NOT_FOUND
      0xC000003A: Smb2ErrorType.notFound, // OBJECT_PATH_NOT_FOUND
      0xC00000CC: Smb2ErrorType.notFound, // BAD_NETWORK_NAME
      0xC0000022: Smb2ErrorType.accessDenied,
      0xC0000035: Smb2ErrorType.alreadyExists,
      0xC0000101: Smb2ErrorType.notEmpty,
      0xC0000103: Smb2ErrorType.notADirectory,
      0xC00000BA: Smb2ErrorType.isADirectory,
      0xC0000043: Smb2ErrorType.inUse, // SHARING_VIOLATION
      0xC000007F: Smb2ErrorType.diskFull,
      0xC00000BB: Smb2ErrorType.notSupported,
      0xC00000C9: Smb2ErrorType.connection, // NETWORK_NAME_DELETED
      0xC0000203: Smb2ErrorType.connection, // USER_SESSION_DELETED
      0xC0000128: Smb2ErrorType.connection, // FILE_CLOSED
      0xC00000B5: Smb2ErrorType.timeout, // IO_TIMEOUT
      0xC0000120: Smb2ErrorType.cancelled,
      0x00000000: Smb2ErrorType.unknown,
      0xC0FFEE00: Smb2ErrorType.unknown,
    };
    for (final MapEntry(key: status, value: type) in cases.entries) {
      test('0x${status.toRadixString(16)} is ${type.name}', () {
        expect(Smb2ErrorType.fromNtStatus(status), type);
      });
    }

    test('a status read as a negative int32 maps the same', () {
      expect(
        Smb2ErrorType.fromNtStatus(0xC000006D - 0x100000000),
        Smb2ErrorType.auth,
      );
    });
  });

  group('fromErrno per platform', () {
    // The same failure has different numbers on each libc.
    const timeouts = {
      'linux': 110,
      'android': 110,
      'macos': 60,
      'ios': 60,
      'windows': 138,
    };
    const refused = {'linux': 111, 'macos': 61, 'windows': 107};
    const notEmpty = {'linux': 39, 'macos': 66, 'windows': 41};
    const reset = {'linux': 104, 'macos': 54, 'windows': 108};

    for (final MapEntry(key: os, value: n) in timeouts.entries) {
      test('ETIMEDOUT on $os', () {
        expect(Smb2ErrorType.fromErrno(n, os: os), Smb2ErrorType.timeout);
      });
    }
    for (final MapEntry(key: os, value: n) in refused.entries) {
      test('ECONNREFUSED (libsmb2 LOGON_FAILURE) on $os', () {
        expect(Smb2ErrorType.fromErrno(n, os: os), Smb2ErrorType.auth);
      });
    }
    for (final MapEntry(key: os, value: n) in notEmpty.entries) {
      test('ENOTEMPTY on $os', () {
        expect(Smb2ErrorType.fromErrno(n, os: os), Smb2ErrorType.notEmpty);
      });
    }
    for (final MapEntry(key: os, value: n) in reset.entries) {
      test('ECONNRESET on $os', () {
        expect(Smb2ErrorType.fromErrno(n, os: os), Smb2ErrorType.connection);
      });
    }

    test('Linux numbers mean something else on Windows', () {
      // 110 is ETIMEDOUT on Linux but EHOSTUNREACH on Windows; 107 is
      // ENOTCONN on Linux but ECONNREFUSED on Windows.
      expect(
        Smb2ErrorType.fromErrno(110, os: 'windows'),
        Smb2ErrorType.connection,
      );
      expect(
        Smb2ErrorType.fromErrno(107, os: 'linux'),
        Smb2ErrorType.connection,
      );
      expect(Smb2ErrorType.fromErrno(107, os: 'windows'), Smb2ErrorType.auth);
    });

    test('common values', () {
      for (final os in ['linux', 'macos', 'windows']) {
        expect(Smb2ErrorType.fromErrno(2, os: os), Smb2ErrorType.notFound);
        expect(Smb2ErrorType.fromErrno(13, os: os), Smb2ErrorType.accessDenied);
        expect(
          Smb2ErrorType.fromErrno(17, os: os),
          Smb2ErrorType.alreadyExists,
        );
        expect(Smb2ErrorType.fromErrno(22, os: os), Smb2ErrorType.invalidParam);
        expect(Smb2ErrorType.fromErrno(9999, os: os), Smb2ErrorType.unknown);
      }
    });
  });

  group('fromMessage', () {
    const connection = [
      'smb2_service failed with : POLLHUP, likely a broken connection',
      'Read from socket failed, errno:104. Closing socket.',
      'Socket connect failed with 111',
      'Not Connected to Server',
      'No connected tree-id',
      'Already disconnected',
      'Alreeady disconnected',
    ];
    for (final m in connection) {
      test('"$m" is connection', () {
        expect(Smb2ErrorType.fromMessage(m), Smb2ErrorType.connection);
      });
    }

    test('timeouts', () {
      expect(
        Smb2ErrorType.fromMessage('Timeout expired and no connection exists'),
        Smb2ErrorType.timeout,
      );
      expect(
        Smb2ErrorType.fromMessage('Connection timed out'),
        Smb2ErrorType.timeout,
      );
    });

    test('anything else is unknown', () {
      expect(Smb2ErrorType.fromMessage(''), Smb2ErrorType.unknown);
      expect(Smb2ErrorType.fromMessage('Open failed'), Smb2ErrorType.unknown);
    });

    test('ntStatusInMessage reads the quoted status', () {
      expect(
        Smb2ErrorType.ntStatusInMessage(
          'Session setup failed with (0xc000006d) STATUS_LOGON_FAILURE',
        ),
        0xC000006D,
      );
      expect(Smb2ErrorType.ntStatusInMessage('no status here'), isNull);
    });
  });

  group('fromFailure', () {
    test('a transport message wins over a status', () {
      expect(
        Smb2ErrorType.fromFailure(
          message: 'Read from socket failed',
          ntStatus: 0xC0000034,
          errno: 2,
          os: 'linux',
        ),
        Smb2ErrorType.connection,
      );
    });

    test('the status wins over errno', () {
      expect(
        Smb2ErrorType.fromFailure(
          message: 'Rmdir failed with (0xc0000101) STATUS_DIRECTORY_NOT_EMPTY.',
          ntStatus: 0xC0000101,
          errno: 13,
          os: 'linux',
        ),
        Smb2ErrorType.notEmpty,
      );
    });

    test('the message alone does not give a status', () {
      // Only the caller can tell a quoted status from a stale one.
      expect(
        Smb2ErrorType.fromFailure(
          message:
              'Open failed with (0xc0000034) STATUS_OBJECT_NAME_NOT_FOUND.',
          errno: 17,
          os: 'linux',
        ),
        Smb2ErrorType.alreadyExists,
      );
    });

    test('errno follows the platform, the running one by default', () {
      expect(
        Smb2ErrorType.fromFailure(message: '', errno: 110, os: 'windows'),
        Smb2ErrorType.connection,
      );
      expect(
        Smb2ErrorType.fromFailure(message: '', errno: 2),
        Smb2ErrorType.notFound,
      );
    });

    test('nothing to go on is unknown', () {
      expect(Smb2ErrorType.fromFailure(message: ''), Smb2ErrorType.unknown);
    });

    test('the 0.1.x classify still works', () {
      expect(
        // ignore: deprecated_member_use_from_same_package
        Smb2ErrorType.classify('Read from socket failed', 2),
        Smb2ErrorType.connection,
      );
      expect(
        // ignore: deprecated_member_use_from_same_package
        Smb2ErrorType.classify('Failed', 2),
        Smb2ErrorType.notFound,
      );
    });
  });

  group('failures without a status', () {
    test('a host name that does not resolve is a connection failure', () {
      expect(
        Smb2ErrorType.fromMessage(
          'Invalid address:nas.invalid  Can not resolve into IPv4/v6.',
        ),
        Smb2ErrorType.connection,
      );
    });

    test('libsmb2\'s generic failures are connection failures', () {
      expect(
        Smb2ErrorType.fromMessage('Poll failed'),
        Smb2ErrorType.connection,
      );
      expect(
        Smb2ErrorType.fromMessage(
          'smb2_service failed with : Bad SMB2 signature',
        ),
        Smb2ErrorType.connection,
      );
    });

    test('exhausted server resources are transient', () {
      for (final status in [0xC0000205, 0xC000011F, 0xC000009A, 0xC0000017]) {
        expect(Smb2ErrorType.fromNtStatus(status), Smb2ErrorType.inUse);
      }
      for (final os in ['linux', 'macos', 'windows']) {
        for (final n in [12, 16, 23, 24]) {
          expect(Smb2ErrorType.fromErrno(n, os: os), Smb2ErrorType.inUse);
        }
        expect(Smb2ErrorType.fromErrno(30, os: os), Smb2ErrorType.accessDenied);
      }
      expect(
        Smb2ErrorType.fromNtStatus(0xC00000A2),
        Smb2ErrorType.accessDenied,
      );
    });
  });

  group('Smb2ErrorType', () {
    test('isNetworkFailure covers connection and timeout only', () {
      for (final t in Smb2ErrorType.values) {
        expect(
          t.isNetworkFailure,
          t == Smb2ErrorType.connection || t == Smb2ErrorType.timeout,
          reason: t.name,
        );
      }
    });

    test('the deprecated fileNotFound is notFound', () {
      // ignore: deprecated_member_use_from_same_package
      expect(Smb2ErrorType.fileNotFound, Smb2ErrorType.notFound);
    });
  });

  group('Smb2Exception', () {
    test('predicates follow the type', () {
      const e = Smb2Exception('x', type: Smb2ErrorType.timeout);
      expect(e.isNetworkFailure, isTrue);
      expect(e.isTransient, isTrue);
      expect(e.isNotFound, isFalse);
      expect(e.isCancelled, isFalse);
      expect(
        const Smb2Exception('x', type: Smb2ErrorType.inUse).isTransient,
        isTrue,
      );
      expect(
        const Smb2Exception('x', type: Smb2ErrorType.auth).isTransient,
        isFalse,
      );
      expect(
        const Smb2Exception('x', type: Smb2ErrorType.auth).isAuthError,
        isTrue,
      );
      expect(
        const Smb2Exception('x', type: Smb2ErrorType.cancelled).isCancelled,
        isTrue,
      );
      expect(
        const Smb2Exception('x', type: Smb2ErrorType.notFound).isNotFound,
        isTrue,
      );
    });

    test('toString names the type, status, errno and path', () {
      const e = Smb2Exception(
        'Stat failed',
        type: Smb2ErrorType.notFound,
        ntStatus: 0xC0000034,
        errno: 2,
        path: 'a/b',
      );
      expect(
        e.toString(),
        'Smb2Exception(notFound) status=0xc0000034 errno=2 path=a/b Stat failed',
      );
      expect(const Smb2Exception('m').toString(), 'Smb2Exception(unknown) m');
    });

    test('the deprecated getters still answer', () {
      const e = Smb2Exception('x', type: Smb2ErrorType.connection, errno: 104);
      // ignore: deprecated_member_use_from_same_package
      expect(e.isConnectionError, isTrue);
      // ignore: deprecated_member_use_from_same_package
      expect(e.errorCode, 104);
    });
  });
}
