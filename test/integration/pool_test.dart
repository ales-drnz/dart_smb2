// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

import '_fixture.dart';

Uint8List pattern(int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + (i >> 16)) & 0xff;
  }
  return out;
}

bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Matcher throwsType(Smb2ErrorType type) =>
    throwsA(isA<Smb2Exception>().having((e) => e.type, 'type', type));

void main() {
  final scratch = Scratch('pool');
  late Smb2Pool pool;
  late Directory local;

  setUpAll(() async {
    scratch.create();
    pool = await connectPool(workers: 3);
    local = await Directory.systemTemp.createTemp('dart_smb2_test');
  });
  tearDownAll(() async {
    await pool.disconnect();
    await local.delete(recursive: true);
    scratch.delete();
  });

  group('connect', () {
    test('connects the requested workers', () {
      expect(pool.workerCount, 3);
      expect(pool.isClosed, isFalse);
    });

    test('a wrong password fails with auth through the pool', () async {
      await expectLater(
        Smb2Pool.connect(
          host: server.host,
          share: server.share,
          user: server.user,
          password: 'wrong',
          workers: 2,
        ),
        throwsA(
          isA<Smb2Exception>()
              .having((e) => e.isAuthError, 'isAuthError', isTrue)
              .having((e) => e.ntStatus, 'ntStatus', 0xC000006D),
        ),
      );
    });

    test('a share that does not exist fails with notFound', () async {
      await expectLater(
        Smb2Pool.connect(
          host: server.host,
          share: 'no_such_share',
          user: server.user,
          password: server.password,
          workers: 1,
        ),
        throwsType(Smb2ErrorType.notFound),
      );
    });

    test('zero workers is an invalid argument', () async {
      await expectLater(
        Smb2Pool.connect(host: server.host, share: server.share, workers: 0),
        throwsType(Smb2ErrorType.invalidParam),
      );
    });

    test('listSharesOn lists the share', () async {
      final shares = await Smb2Pool.listSharesOn(
        host: server.host,
        user: server.user,
        password: server.password,
      );
      expect(shares.map((s) => s.name), contains(server.share));
    });

    test('a closed pool refuses calls with state', () async {
      final p = await connectPool(workers: 1);
      await p.disconnect();
      await p.disconnect();
      expect(p.isClosed, isTrue);
      await expectLater(p.stat(seedFile), throwsType(Smb2ErrorType.state));
    });
  });

  group('reads and metadata', () {
    test('readFile, readFileRange, stat, fileSize and exists', () async {
      expect((await pool.readFile(seedFile)).length, seedSize);
      expect(
        (await pool.readFileRange(seedFile, offset: 10, length: 20)).length,
        20,
      );
      expect((await pool.stat(seedFile)).size, seedSize);
      expect(await pool.fileSize(seedFile), seedSize);
      expect(await pool.exists(seedFile), isTrue);
      expect(await pool.exists('no_such_file'), isFalse);
      await expectLater(
        pool.stat('no/such'),
        throwsType(Smb2ErrorType.notFound),
      );
    });

    test('listDirectory, statvfs, echo and readlink', () async {
      final root = await pool.listDirectory('');
      expect(root.map((e) => e.name), contains(seedFile));
      expect((await pool.statvfs('')).totalSize, greaterThan(0));
      await pool.echo();
      await expectLater(pool.readlink(seedFile), throwsA(isA<Smb2Exception>()));
    });

    test('200 parallel stats spread over the workers', () async {
      final stats = await Future.wait([
        for (var i = 0; i < 200; i++) pool.stat(seedFile),
      ]);
      expect(stats.every((s) => s.size == seedSize), isTrue);
    });

    test('a large file reads back whole through readFile', () async {
      final data = pattern(20 * 1024 * 1024 + 3);
      final path = scratch.path('large.bin');
      await pool.writeFile(path, data);
      expect(sameBytes(await pool.readFile(path), data), isTrue);
    });
  });

  group('handles', () {
    test('openFileWithSize, readFromHandle and closeHandle', () async {
      final (h, size) = await pool.openFileWithSize(seedFile);
      expect(size, seedSize);
      expect((await pool.readFromHandle(h, offset: 5, length: 10)).length, 10);
      await pool.closeHandle(h);
      await pool.closeHandle(h);
      expect(h.isClosed, isTrue);
      await expectLater(
        pool.readFromHandle(h, length: 1),
        throwsType(Smb2ErrorType.state),
      );
    });

    test('write handle: write, fsync, ftruncate', () async {
      final path = scratch.path('wh.bin');
      final h = await pool.openFileWrite(path, truncate: true);
      expect(h.writable, isTrue);
      await pool.writeToHandle(h, Uint8List.fromList([1, 2, 3, 4]));
      await pool.fsyncHandle(h);
      await pool.ftruncateHandle(h, 3);
      await pool.closeHandle(h);
      expect(await pool.readFile(path), [1, 2, 3]);
    });

    test('withFile closes on success and on error', () async {
      final size = await pool.withFile(seedFile, (f) async {
        expect((await f.read(length: 8)).length, 8);
        expect(f.path, seedFile);
        return f.size;
      });
      expect(size, seedSize);
      await expectLater(
        pool.withFile(seedFile, (_) => throw StateError('boom')),
        throwsStateError,
      );
      final known = await pool.withFile(seedFile, (f) => f.size, knownSize: 7);
      expect(known, 7);
    });
  });

  group('streaming', () {
    late Uint8List data;
    late String path;

    setUpAll(() async {
      data = pattern(9 * 1024 * 1024 + 17);
      path = scratch.path('stream.bin');
      await pool.writeFile(path, data);
    });

    for (final chunk in [64 * 1024, 1024 * 1024, 16 * 1024 * 1024]) {
      test(
        'streamFile with $chunk-byte chunks yields every byte in order',
        () async {
          final progress = <int>[];
          final chunks = await pool
              .streamFile(
                path,
                chunkSize: chunk,
                onProgress: (r, t) {
                  expect(t, data.length);
                  progress.add(r);
                },
              )
              .toList();
          expect(chunks.every((c) => c.length <= chunk), isTrue);
          expect(sameBytes([for (final c in chunks) ...c], data), isTrue);
          expect(progress.last, data.length);
        },
      );
    }

    test('streamFile of an empty file yields nothing', () async {
      final empty = scratch.path('empty.bin');
      await pool.writeFile(empty, Uint8List(0));
      expect(await pool.streamFile(empty).toList(), isEmpty);
    });

    test('cancelling the subscription closes the handle', () async {
      final first = await pool.streamFile(path, chunkSize: 1024 * 1024).first;
      expect(first.length, 1024 * 1024);
      // The read-ahead chunk is dropped; the pool stays usable.
      expect((await pool.stat(path)).size, data.length);
    });

    test('downloadToFile writes the file atomically', () async {
      final dest = '${local.path}/download.bin';
      var last = 0;
      final n = await pool.downloadToFile(
        path,
        dest,
        onProgress: (r, t) => last = r,
      );
      expect(n, data.length);
      expect(last, data.length);
      expect(sameBytes(await File(dest).readAsBytes(), data), isTrue);
      expect(
        local.listSync().map((e) => e.path).where((p) => p.contains('.part-')),
        isEmpty,
      );
    });

    test('a failed download leaves the destination as it was', () async {
      final dest = '${local.path}/kept.txt';
      await File(dest).writeAsString('old');
      await expectLater(
        pool.downloadToFile('no_such_file', dest),
        throwsType(Smb2ErrorType.notFound),
      );
      expect(await File(dest).readAsString(), 'old');
      expect(local.listSync().where((e) => e.path.contains('.part-')), isEmpty);
    });

    test(
      'a cancelled download throws cancelled and removes its part file',
      () async {
        final dest = '${local.path}/cancelled.bin';
        final token = Smb2CancelToken();
        final future = pool.downloadToFile(
          path,
          dest,
          chunkSize: 256 * 1024,
          cancelToken: token,
          onProgress: (r, _) {
            if (r >= 1024 * 1024) token.cancel('stop');
          },
        );
        await expectLater(
          future,
          throwsA(
            isA<Smb2Exception>().having(
              (e) => e.isCancelled,
              'isCancelled',
              isTrue,
            ),
          ),
        );
        expect(File(dest).existsSync(), isFalse);
        expect(
          local.listSync().where((e) => e.path.contains('.part-')),
          isEmpty,
        );
        expect(token.listenerCount, 0);
      },
    );

    test('streamWrite writes a stream through one handle', () async {
      final out = scratch.path('streamed.bin');
      await pool.streamWrite(
        out,
        Stream.fromIterable([
          for (var o = 0; o < data.length; o += 1024 * 1024)
            Uint8List.sublistView(
              data,
              o,
              o + 1024 * 1024 > data.length ? data.length : o + 1024 * 1024,
            ),
        ]),
      );
      expect(sameBytes(await pool.readFile(out), data), isTrue);
    });
  });

  group('cancellation', () {
    test('a cancelled token fails calls at once', () async {
      final token = Smb2CancelToken()..cancel();
      await expectLater(
        pool.listDirectory('', cancelToken: token),
        throwsType(Smb2ErrorType.cancelled),
      );
      await expectLater(
        pool.openFile(seedFile, cancelToken: token),
        throwsType(Smb2ErrorType.cancelled),
      );
    });

    test('cancelling an open in flight closes the file it opened', () async {
      final token = Smb2CancelToken();
      final future = pool.openFile(seedFile, cancelToken: token);
      token.cancel();
      await expectLater(future, throwsType(Smb2ErrorType.cancelled));
      // The worker's late reply is disposed of; the pool keeps working.
      await pool.echo();
      expect((await pool.stat(seedFile)).size, seedSize);
    });
  });

  group('writes and management', () {
    test('writeFile, writeFileRange, truncate, setFileTimes', () async {
      final path = scratch.path('w.bin');
      await pool.writeFile(path, Uint8List.fromList([1, 2, 3]));
      await pool.writeFileRange(path, Uint8List.fromList([9]), offset: 4);
      expect(await pool.readFile(path), [1, 2, 3, 0, 9]);
      await pool.truncate(path, 2);
      expect(await pool.fileSize(path), 2);
      final when = DateTime.utc(2021, 3, 4, 5, 6, 7);
      await pool.setFileTimes(path, modified: when);
      expect((await pool.stat(path)).modified, when);
    });

    test('mkdir, rename, deleteFile, rmdir with typed failures', () async {
      final dir = scratch.path('m');
      await pool.mkdir(dir);
      await expectLater(
        pool.mkdir(dir),
        throwsType(Smb2ErrorType.alreadyExists),
      );
      await pool.writeFile('$dir/a', Uint8List(1));
      await expectLater(pool.rmdir(dir), throwsType(Smb2ErrorType.notEmpty));
      await pool.rename('$dir/a', '$dir/b');
      await pool.deleteFile('$dir/b');
      await pool.rmdir(dir);
      expect(await pool.exists(dir), isFalse);
    });

    test('parallel writes from every worker', () async {
      await Future.wait([
        for (var i = 0; i < 12; i++)
          pool.writeFile(scratch.path('p$i.bin'), Uint8List.fromList([i])),
      ]);
      for (var i = 0; i < 12; i++) {
        expect(await pool.readFile(scratch.path('p$i.bin')), [i]);
      }
    });
  });
}
