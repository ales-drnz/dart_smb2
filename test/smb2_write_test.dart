// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

/// Integration tests for write operations across Smb2Client and Smb2Pool.
///
/// These tests require a running SMB server with **write access**.
/// Set the environment variables:
///   SMB2_HOST, SMB2_SHARE, SMB2_USER, SMB2_PASS, SMB2_LIB_PATH
///
/// The tests create and clean up temporary files/directories under a
/// `_dart_smb2_test` folder on the share root.
///
/// Run with:
///   SMB2_HOST=192.168.1.1 SMB2_SHARE=Files SMB2_USER=user SMB2_PASS=pass \
///   SMB2_LIB_PATH=scripts/output/macos/lib/libsmb2_wrapper.dylib \
///   dart test test/smb2_write_test.dart -r expanded
void main() {
  final host = Platform.environment['SMB2_HOST'];
  final share = Platform.environment['SMB2_SHARE'];
  final user = Platform.environment['SMB2_USER'];
  final pass = Platform.environment['SMB2_PASS'];
  final libPath = Platform.environment['SMB2_LIB_PATH'];

  if (host == null || share == null || libPath == null) {
    print(
      'Skipping write integration tests — set SMB2_HOST, SMB2_SHARE, SMB2_LIB_PATH',
    );
    return;
  }

  const testDir = '_dart_smb2_test';

  // ─── Smb2Client (sync) ──────────────────────────────────────────────────

  group('Smb2Client — write operations', () {
    late Smb2Client client;

    setUp(() {
      client = Smb2Client.open(libPath);
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
      client.writeHandle(handle, part1, offset: 0);
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
      libPath: libPath,
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
        offset: 0,
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
}
