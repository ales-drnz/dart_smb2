// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

@Tags(['integration'])
library;

import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

import '_fixture.dart';

/// [length] bytes that differ at every offset of a 64 KiB period, so a
/// chunk read at the wrong offset never matches by chance.
Uint8List pattern(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + (i >> 16)) & 0xff;
  }
  return out;
}

/// Whether [a] and [b] hold the same bytes; `expect(a, b)` on megabytes
/// spends seconds in the matcher.
bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  final scratch = Scratch('client');
  late Smb2Client client;

  setUpAll(scratch.create);
  tearDownAll(scratch.delete);
  setUp(() => client = connectClient());
  tearDown(() => client.disconnect());

  group('connection', () {
    test('reports the negotiated request sizes', () {
      expect(client.isConnected, isTrue);
      expect(client.maxReadSize, greaterThan(0));
      expect(client.maxWriteSize, greaterThan(0));
    });

    test('disconnect is idempotent and later calls fail with state', () {
      client.disconnect();
      client.disconnect();
      expect(client.isConnected, isFalse);
      expect(
        () => client.stat(seedFile),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.state,
          ),
        ),
      );
      client = connectClient();
    });

    test('a wrong password fails with auth and the NT status', () {
      expect(
        () => Smb2Client().connect(
          host: server.host,
          share: server.share,
          user: server.user,
          password: 'wrong',
        ),
        throwsA(
          isA<Smb2Exception>()
              .having((e) => e.type, 'type', Smb2ErrorType.auth)
              .having((e) => e.ntStatus, 'ntStatus', 0xC000006D),
        ),
      );
    });

    test('a share that does not exist fails with notFound', () {
      expect(
        () => Smb2Client().connect(
          host: server.host,
          share: 'no_such_share',
          user: server.user,
          password: server.password,
        ),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
    });

    test('echo succeeds', () => client.echo());

    test('listShares lists the share without a connection', () {
      final shares = Smb2Client.listShares(
        host: server.host,
        user: server.user,
        password: server.password,
      );
      final share = shares.singleWhere((s) => s.name == server.share);
      expect(share.isDisk, isTrue);
      expect(shares.where((s) => s.name == r'IPC$').single.isHidden, isTrue);
    });
  });

  group('reads', () {
    test('readFile returns the whole seed', () {
      final data = client.readFile(seedFile);
      expect(data.length, seedSize);
      expect(data.every((b) => b == 0), isTrue);
    });

    test('a range larger than MaxReadSize comes back whole and in order', () {
      final size = client.maxReadSize * 2 + 12345;
      final data = pattern(size);
      final path = scratch.path('big.bin');
      client.writeFile(path, data);
      final range = client.readFileRange(path, offset: 7, length: size - 7);
      expect(sameBytes(range, data.sublist(7)), isTrue);
      expect(sameBytes(client.readFile(path), data), isTrue);
    });

    test(
      'readFileChunked with chunks larger than MaxReadSize keeps every byte',
      () {
        final size = client.maxReadSize * 2 + 999;
        final data = pattern(size);
        final path = scratch.path('chunked.bin');
        client.writeFile(path, data);
        final chunks = client
            .readFileChunked(path, chunkSize: client.maxReadSize + 4096)
            .toList();
        expect(chunks.fold<int>(0, (n, c) => n + c.length), size);
        expect(sameBytes([for (final c in chunks) ...c], data), isTrue);
      },
    );

    test('a range past the end returns the bytes there are', () {
      expect(
        client
            .readFileRange(seedFile, offset: seedSize - 10, length: 100)
            .length,
        10,
      );
      expect(
        client.readFileRange(seedFile, offset: seedSize, length: 100),
        isEmpty,
      );
      expect(client.readFileRange(seedFile, length: 0), isEmpty);
    });

    test('negative offsets and lengths fail with invalidParam', () {
      final invalid = throwsA(
        isA<Smb2Exception>().having(
          (e) => e.type,
          'type',
          Smb2ErrorType.invalidParam,
        ),
      );
      expect(
        () => client.readFileRange(seedFile, offset: -1, length: 1),
        invalid,
      );
      expect(() => client.readFileRange(seedFile, length: -1), invalid);
      expect(() => client.truncate(scratch.path('x'), -1), invalid);
    });

    test('a missing path fails with notFound and exists says false', () {
      expect(
        () => client.stat('no/such/file'),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
      expect(client.exists('no_such_file'), isFalse);
      expect(client.exists(seedFile), isTrue);
    });

    test('leading slashes and backslashes name the same path', () {
      expect(client.stat('/$seedFile').size, seedSize);
      client.writeFile(scratch.path('slash.bin'), Uint8List(3));
      expect(client.stat('\\${scratch.dir}\\slash.bin').size, 3);
    });

    test(
      'a NUL in a path fails with invalidParam before reaching the server',
      () {
        for (final call in <void Function()>[
          () => client.stat('a\u0000b'),
          () => client.writeFile('a\u0000b', Uint8List(1)),
          () => client.mkdir('a\u0000b'),
          () => client.rename(seedFile, 'a\u0000b'),
          () => client.setFileTimes('a\u0000b', modified: DateTime.now()),
        ]) {
          expect(
            call,
            throwsA(
              isA<Smb2Exception>().having(
                (e) => e.type,
                'type',
                Smb2ErrorType.invalidParam,
              ),
            ),
          );
        }
      },
    );

    test('stat and listDirectory agree, with sub-second times', () {
      final path = scratch.path('times.bin');
      client.writeFile(path, Uint8List(5));
      final when = DateTime.utc(2024, 5, 6, 7, 8, 9, 123, 456);
      client.setFileTimes(path, modified: when);
      final st = client.stat(path);
      expect(st.modified, when);
      final entry = client
          .listDirectory(scratch.dir)
          .singleWhere((e) => e.name == 'times.bin');
      expect(entry.stat, st);
      expect(entry.isFile, isTrue);
    });

    test('statvfs reports plausible totals', () {
      final vfs = client.statvfs('');
      expect(vfs.totalSize, greaterThan(0));
      expect(vfs.freeSize, lessThanOrEqualTo(vfs.totalSize));
    });

    test('readlink of a regular file fails', () {
      expect(() => client.readlink(seedFile), throwsA(isA<Smb2Exception>()));
    });
  });

  group('handles', () {
    test('openFileWithSize + readFromHandle round-trip', () {
      final (h, size) = client.openFileWithSize(seedFile);
      expect(size, seedSize);
      expect(client.readFromHandle(h, offset: 100, length: 50).length, 50);
      client.closeHandle(h);
      expect(h.isClosed, isTrue);
    });

    test('closing twice does nothing, any other use fails with state', () {
      final h = client.openFile(seedFile);
      client.closeHandle(h);
      client.closeHandle(h);
      final state = throwsA(
        isA<Smb2Exception>().having((e) => e.type, 'type', Smb2ErrorType.state),
      );
      expect(() => client.readFromHandle(h, length: 1), state);
      expect(() => client.fsyncHandle(h), state);
    });

    test('a handle of another client is refused', () {
      final other = connectClient();
      try {
        final h = other.openFile(seedFile);
        expect(
          () => client.readFromHandle(h, length: 1),
          throwsA(
            isA<Smb2Exception>().having(
              (e) => e.type,
              'type',
              Smb2ErrorType.state,
            ),
          ),
        );
        expect(() => client.closeHandle(h), throwsA(isA<Smb2Exception>()));
        other.closeHandle(h);
      } finally {
        other.disconnect();
      }
    });

    test('disconnect closes the open handles', () {
      final h = client.openFile(seedFile);
      client.disconnect();
      expect(h.isClosed, isTrue);
      client = connectClient();
    });

    test('write handle: write, fsync, ftruncate, read back', () {
      final path = scratch.path('handle.bin');
      final h = client.openFileWrite(path, truncate: true);
      client.writeToHandle(h, Uint8List.fromList([1, 2, 3, 4]));
      client.writeToHandle(h, Uint8List.fromList([9]), offset: 6);
      client.fsyncHandle(h);
      client.closeHandle(h);
      expect(client.readFile(path), [1, 2, 3, 4, 0, 0, 9]);
      final t = client.openFileWrite(path);
      client.ftruncateHandle(t, 2);
      client.closeHandle(t);
      expect(client.readFile(path), [1, 2]);
    });
  });

  group('writes and management', () {
    test(
      'writeFile replaces, writeFileRange patches, writeFileChunked streams',
      () {
        final path = scratch.path('w.bin');
        client.writeFile(path, Uint8List.fromList([1, 2, 3, 4, 5]));
        client.writeFile(path, Uint8List.fromList([7, 7]));
        expect(client.readFile(path), [7, 7]);
        client.writeFileRange(path, Uint8List.fromList([5]), offset: 3);
        expect(client.readFile(path), [7, 7, 0, 5]);
        client.writeFileChunked(path, [
          Uint8List.fromList([1]),
          Uint8List.fromList([2, 3]),
        ]);
        expect(client.readFile(path), [1, 2, 3]);
      },
    );

    test('a write larger than MaxWriteSize lands whole', () {
      final data = pattern(client.maxWriteSize * 2 + 77);
      final path = scratch.path('bigwrite.bin');
      client.writeFile(path, data);
      expect(sameBytes(client.readFile(path), data), isTrue);
    });

    test('mkdir, rename, rmdir, deleteFile and their typed failures', () {
      final dir = scratch.path('d');
      client.mkdir(dir);
      expect(
        () => client.mkdir(dir),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.alreadyExists,
          ),
        ),
      );
      client.writeFile('$dir/f', Uint8List(1));
      expect(
        () => client.rmdir(dir),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.notEmpty,
          ),
        ),
      );
      client.rename('$dir/f', '$dir/g');
      expect(client.exists('$dir/f'), isFalse);
      client.deleteFile('$dir/g');
      expect(
        () => client.deleteFile('$dir/g'),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
      client.rmdir(dir);
      expect(client.exists(dir), isFalse);
      expect(
        () => client.rmdir(dir),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
    });

    test('truncate shrinks and extends', () {
      final path = scratch.path('t.bin');
      client.writeFile(path, Uint8List(10));
      client.truncate(path, 4);
      expect(client.fileSize(path), 4);
      client.truncate(path, 8);
      expect(client.fileSize(path), 8);
    });

    test('setFileTimes validates its arguments and works on directories', () {
      final invalid = throwsA(
        isA<Smb2Exception>().having(
          (e) => e.type,
          'type',
          Smb2ErrorType.invalidParam,
        ),
      );
      expect(() => client.setFileTimes(seedFile), invalid);
      expect(
        () => client.setFileTimes(seedFile, modified: DateTime.utc(1960)),
        invalid,
      );
      final when = DateTime.utc(2020, 1, 2, 3, 4, 5);
      client.setFileTimes(scratch.dir, modified: when, accessed: when);
      expect(client.stat(scratch.dir).modified, when);
      expect(
        () => client.setFileTimes('no_such', modified: when),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
    });
  });
}
