// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

import '_fixture.dart';

/// Integration tests for write operations across [Smb2Client] and [Smb2Pool]
/// against the local Samba container seeded by `bootstrap.dart`.
///
/// The tests create and clean up temporary files / directories under a
/// `_dart_smb2_test` folder on the share root.
void main() {
  installTestLibPath();
  final cache = bootstrapCache;
  final host = cache.host;
  final share = cache.share;
  final user = cache.user;
  final pass = cache.password;

  const testDir = '_dart_smb2_test';

  // ─── Smb2Client (sync) ──────────────────────────────────────────────────

  group('Smb2Client — write operations', () {
    late Smb2Client client;

    setUp(() {
      client = Smb2Client.open();
      client.connect(host: host, share: share, user: user, password: pass);
      // Ensure test directory exists.
      try {
        client.mkdir(testDir);
      } on Smb2Exception catch (e) {
        if (e.type != Smb2ErrorType.alreadyExists) rethrow;
      }
    });

    tearDown(() {
      // Best-effort cleanup of files created during the test.
      for (final name in [
        '$testDir/write_test.txt',
        '$testDir/write_range.bin',
        '$testDir/write_chunked.bin',
        '$testDir/renamed.txt',
        '$testDir/truncated.txt',
        '$testDir/to_delete.txt',
        '$testDir/utimes.txt',
      ]) {
        try {
          client.deleteFile(name);
        } catch (_) {}
      }
      for (final name in [
        '$testDir/subdir',
        testDir,
      ]) {
        try {
          client.rmdir(name);
        } catch (_) {}
      }
      client.disconnect();
    });

    test('writeFile creates a new file and readFile returns same data', () {
      final data = Uint8List.fromList('Hello, SMB2!'.codeUnits);
      client.writeFile('$testDir/write_test.txt', data);

      final read = client.readFile('$testDir/write_test.txt');
      expect(read, equals(data));
    });

    test('writeFile overwrites existing file', () {
      final first = Uint8List.fromList('First'.codeUnits);
      final second = Uint8List.fromList('Second version'.codeUnits);

      client.writeFile('$testDir/write_test.txt', first);
      client.writeFile('$testDir/write_test.txt', second);

      final read = client.readFile('$testDir/write_test.txt');
      expect(read, equals(second));
    });

    test('writeFileRange writes at offset without truncating', () {
      final initial = Uint8List.fromList('AAAAAAAAAA'.codeUnits); // 10 bytes
      client.writeFile('$testDir/write_range.bin', initial);

      final patch = Uint8List.fromList('BBB'.codeUnits);
      client.writeFileRange('$testDir/write_range.bin', patch, offset: 3);

      final read = client.readFile('$testDir/write_range.bin');
      expect(String.fromCharCodes(read), equals('AAABBBAAAA'));
    });

    test('writeFileChunked writes data from iterable', () {
      final chunk1 = Uint8List.fromList('Hello '.codeUnits);
      final chunk2 = Uint8List.fromList('World!'.codeUnits);

      client.writeFileChunked('$testDir/write_chunked.bin', [chunk1, chunk2]);

      final read = client.readFile('$testDir/write_chunked.bin');
      expect(String.fromCharCodes(read), equals('Hello World!'));
    });

    test('write handle open + write + close round-trip', () {
      final handle = client.openFileHandleWrite('$testDir/write_test.txt');
      final part1 = Uint8List.fromList('AB'.codeUnits);
      final part2 = Uint8List.fromList('CD'.codeUnits);
      client.writeHandle(handle, part1);
      client.writeHandle(handle, part2, offset: 2);
      client.closeHandle(handle);

      final read = client.readFileRange('$testDir/write_test.txt', length: 4);
      expect(String.fromCharCodes(read), equals('ABCD'));
    });

    test('exists returns true for existing file', () {
      client.writeFile(
        '$testDir/write_test.txt',
        Uint8List.fromList('x'.codeUnits),
      );
      expect(client.exists('$testDir/write_test.txt'), isTrue);
    });

    test('exists returns false for non-existent path', () {
      expect(client.exists('$testDir/no_such_file_12345'), isFalse);
    });

    test('mkdir creates directory', () {
      client.mkdir('$testDir/subdir');
      final info = client.stat('$testDir/subdir');
      expect(info.isDirectory, isTrue);
    });

    test('mkdir throws alreadyExists for existing directory', () {
      client.mkdir('$testDir/subdir');
      expect(
        () => client.mkdir('$testDir/subdir'),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.alreadyExists,
          ),
        ),
      );
    });

    test('rmdir removes empty directory', () {
      client.mkdir('$testDir/subdir');
      client.rmdir('$testDir/subdir');
      expect(client.exists('$testDir/subdir'), isFalse);
    });

    test('deleteFile removes a file', () {
      client.writeFile(
        '$testDir/to_delete.txt',
        Uint8List.fromList('bye'.codeUnits),
      );
      client.deleteFile('$testDir/to_delete.txt');
      expect(client.exists('$testDir/to_delete.txt'), isFalse);
    });

    test('deleteFile throws fileNotFound for non-existent file', () {
      expect(
        () => client.deleteFile('$testDir/no_such_file_12345'),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.fileNotFound,
          ),
        ),
      );
    });

    test('rename moves a file', () {
      client.writeFile(
        '$testDir/write_test.txt',
        Uint8List.fromList('move me'.codeUnits),
      );
      client.rename('$testDir/write_test.txt', '$testDir/renamed.txt');

      expect(client.exists('$testDir/write_test.txt'), isFalse);
      final read = client.readFile('$testDir/renamed.txt');
      expect(String.fromCharCodes(read), equals('move me'));
    });

    test('truncate reduces file size', () {
      client.writeFile(
        '$testDir/truncated.txt',
        Uint8List.fromList('1234567890'.codeUnits),
      );
      client.truncate('$testDir/truncated.txt', 5);

      final size = client.fileSize('$testDir/truncated.txt');
      expect(size, equals(5));

      final read = client.readFile('$testDir/truncated.txt');
      expect(String.fromCharCodes(read), equals('12345'));
    });

    test('truncate with negative length throws invalidParam', () {
      expect(
        () => client.truncate('$testDir/write_test.txt', -1),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.invalidParam,
          ),
        ),
      );
    });

    test('setFileTimes sets remote modified time', () {
      client.writeFile(
        '$testDir/utimes.txt',
        Uint8List.fromList('mtime'.codeUnits),
      );
      final target = DateTime.utc(2020, 5, 17, 10, 30, 12);
      client.setFileTimes('$testDir/utimes.txt', modified: target);

      final st = client.stat('$testDir/utimes.txt');
      expect(st.modified, equals(target));
    });

    test('setFileTimes with modified + accessed round-trips mtime', () {
      client.writeFile(
        '$testDir/utimes.txt',
        Uint8List.fromList('both'.codeUnits),
      );
      final mtime = DateTime.utc(2019, 1, 2, 3, 4, 5);
      final atime = DateTime.utc(2021, 6, 7, 8, 9, 10);
      client.setFileTimes(
        '$testDir/utimes.txt',
        modified: mtime,
        accessed: atime,
      );

      final st = client.stat('$testDir/utimes.txt');
      expect(st.modified, equals(mtime));
    });

    test('setFileTimes works on a directory', () {
      final target = DateTime.utc(2018, 11, 22, 12);
      client.setFileTimes(testDir, modified: target);

      final st = client.stat(testDir);
      expect(st.modified, equals(target));
    });

    test('setFileTimes with no timestamps throws invalidParam', () {
      expect(
        () => client.setFileTimes('$testDir/write_test.txt'),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.invalidParam,
          ),
        ),
      );
    });

    test('setFileTimes with pre-epoch timestamp throws invalidParam', () {
      expect(
        () => client.setFileTimes(
          '$testDir/write_test.txt',
          modified: DateTime.utc(1960),
        ),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.invalidParam,
          ),
        ),
      );
    });

    test('setFileTimes on missing file throws fileNotFound', () {
      expect(
        () => client.setFileTimes(
          '$testDir/no_such_file_98765',
          modified: DateTime.utc(2020),
        ),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.fileNotFound,
          ),
        ),
      );
    });
  });

  // ─── Smb2Pool (async) ──────────────────────────────────────────────────

  group('Smb2Pool — write operations', () {
    late Smb2Pool pool;

    Future<Smb2Pool> connectPool({int workers = 2}) => Smb2Pool.connect(
          host: host,
          share: share,
          user: user,
          password: pass,
          workers: workers,
        );

    setUp(() async {
      pool = await connectPool();
      try {
        await pool.mkdir(testDir);
      } on Smb2Exception catch (e) {
        if (e.type != Smb2ErrorType.alreadyExists) rethrow;
      }
    });

    tearDown(() async {
      for (final name in [
        '$testDir/pool_write.txt',
        '$testDir/pool_range.bin',
        '$testDir/pool_stream.bin',
        '$testDir/pool_handle.bin',
        '$testDir/pool_delete.txt',
        '$testDir/pool_renamed.txt',
        '$testDir/pool_truncate.txt',
        '$testDir/pool_utimes.txt',
      ]) {
        try {
          await pool.deleteFile(name);
        } catch (_) {}
      }
      for (final name in ['$testDir/pool_subdir', testDir]) {
        try {
          await pool.rmdir(name);
        } catch (_) {}
      }
      await pool.disconnect();
    });

    test('writeFile + readFile round-trip', () async {
      final data = Uint8List.fromList('Pool write test'.codeUnits);
      await pool.writeFile('$testDir/pool_write.txt', data);

      final read = await pool.readFile('$testDir/pool_write.txt');
      expect(read, equals(data));
    });

    test('writeFileRange at offset preserves existing data', () async {
      final initial = Uint8List.fromList('XXXXXXXXXX'.codeUnits);
      await pool.writeFile('$testDir/pool_range.bin', initial);

      final patch = Uint8List.fromList('YYY'.codeUnits);
      await pool.writeFileRange('$testDir/pool_range.bin', patch, offset: 4);

      final read = await pool.readFile('$testDir/pool_range.bin');
      expect(String.fromCharCodes(read), equals('XXXXYYYXXX'));
    });

    test('streamWrite writes from async stream', () async {
      final chunks = Stream.fromIterable([
        Uint8List.fromList('Stream '.codeUnits),
        Uint8List.fromList('write '.codeUnits),
        Uint8List.fromList('test!'.codeUnits),
      ]);
      await pool.streamWrite('$testDir/pool_stream.bin', chunks);

      final read = await pool.readFile('$testDir/pool_stream.bin');
      expect(String.fromCharCodes(read), equals('Stream write test!'));
    });

    test('write handle open + write + close', () async {
      final handle = await pool.openFileWrite('$testDir/pool_handle.bin');
      await pool.writeToHandle(
        handle,
        Uint8List.fromList('Hello'.codeUnits),
      );
      await pool.writeToHandle(
        handle,
        Uint8List.fromList(' Pool'.codeUnits),
        offset: 5,
      );
      await pool.closeHandle(handle);

      final read = await pool.readFile('$testDir/pool_handle.bin');
      expect(String.fromCharCodes(read), equals('Hello Pool'));
    });

    test('exists returns true / false correctly', () async {
      await pool.writeFile(
        '$testDir/pool_write.txt',
        Uint8List.fromList('x'.codeUnits),
      );
      expect(await pool.exists('$testDir/pool_write.txt'), isTrue);
      expect(await pool.exists('$testDir/no_such_file_12345'), isFalse);
    });

    test('mkdir + rmdir round-trip', () async {
      await pool.mkdir('$testDir/pool_subdir');
      final info = await pool.stat('$testDir/pool_subdir');
      expect(info.isDirectory, isTrue);

      await pool.rmdir('$testDir/pool_subdir');
      expect(await pool.exists('$testDir/pool_subdir'), isFalse);
    });

    test('deleteFile removes file', () async {
      await pool.writeFile(
        '$testDir/pool_delete.txt',
        Uint8List.fromList('bye'.codeUnits),
      );
      await pool.deleteFile('$testDir/pool_delete.txt');
      expect(await pool.exists('$testDir/pool_delete.txt'), isFalse);
    });

    test('rename moves file', () async {
      await pool.writeFile(
        '$testDir/pool_write.txt',
        Uint8List.fromList('move'.codeUnits),
      );
      await pool.rename('$testDir/pool_write.txt', '$testDir/pool_renamed.txt');

      expect(await pool.exists('$testDir/pool_write.txt'), isFalse);
      final read = await pool.readFile('$testDir/pool_renamed.txt');
      expect(String.fromCharCodes(read), equals('move'));
    });

    test('truncate reduces file size', () async {
      await pool.writeFile(
        '$testDir/pool_truncate.txt',
        Uint8List.fromList('ABCDEFGHIJ'.codeUnits),
      );
      await pool.truncate('$testDir/pool_truncate.txt', 3);

      final read = await pool.readFile('$testDir/pool_truncate.txt');
      expect(String.fromCharCodes(read), equals('ABC'));
    });

    test('setFileTimes sets remote modified time', () async {
      await pool.writeFile(
        '$testDir/pool_utimes.txt',
        Uint8List.fromList('pool mtime'.codeUnits),
      );
      final target = DateTime.utc(2017, 3, 4, 5, 6, 7);
      await pool.setFileTimes('$testDir/pool_utimes.txt', modified: target);

      final st = await pool.stat('$testDir/pool_utimes.txt');
      expect(st.modified, equals(target));
    });

    test('concurrent writes from multiple workers', () async {
      final futures = List.generate(8, (i) {
        final data = Uint8List.fromList('Data from request $i'.codeUnits);
        return pool.writeFile('$testDir/pool_write.txt', data);
      });
      // All should complete without error — last writer wins.
      await Future.wait(futures);
      final read = await pool.readFile('$testDir/pool_write.txt');
      expect(read.length, greaterThan(0));
    });
  });

  // ── L1 fix from the 0.1.0 code review, write-side coverage.
  //
  // The write/management paths route every path through Smb2Client's
  // NUL-rejecting `_path` helper, so the embedded-NUL guard applies
  // uniformly. These tests fail-fast BEFORE any FFI call — they don't
  // touch the share state, so they're safe to leave on top of the
  // existing fixtures without a setUp/tearDown of their own.
  group('Smb2Client — write path NUL byte rejection (L1)', () {
    late Smb2Client client;

    setUp(() {
      client = Smb2Client.open();
      client.connect(host: host, share: share, user: user, password: pass);
    });
    tearDown(() => client.disconnect());

    final payload = Uint8List.fromList('ignored'.codeUnits);

    test('writeFile rejects NUL in path', () {
      expect(
        () => client.writeFile('foo\u0000bar', payload),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.invalidParam,
          ),
        ),
      );
    });

    test('writeFileRange rejects NUL in path', () {
      expect(
        () => client.writeFileRange('foo\u0000bar', payload),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('openFileHandleWrite rejects NUL in path', () {
      expect(
        () => client.openFileHandleWrite('foo\u0000bar'),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('deleteFile rejects NUL in path', () {
      expect(
        () => client.deleteFile('foo\u0000bar'),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('mkdir rejects NUL in path', () {
      expect(
        () => client.mkdir('foo\u0000bar'),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('rmdir rejects NUL in path', () {
      expect(
        () => client.rmdir('foo\u0000bar'),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('truncate rejects NUL in path', () {
      expect(
        () => client.truncate('foo\u0000bar', 0),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('rename rejects NUL in oldPath', () {
      expect(
        () => client.rename('foo\u0000bar', 'good'),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('rename rejects NUL in newPath', () {
      expect(
        () => client.rename('good', 'foo\u0000bar'),
        throwsA(isA<Smb2Exception>()),
      );
    });

    test('setFileTimes rejects NUL in path', () {
      expect(
        () => client.setFileTimes(
          'foo\u0000bar',
          modified: DateTime.utc(2020),
        ),
        throwsA(isA<Smb2Exception>()),
      );
    });
  });
}
