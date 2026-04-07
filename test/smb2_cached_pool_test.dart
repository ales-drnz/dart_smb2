// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

/// Fake pool that counts calls to stat and listDirectory.
class _FakePool {
  int statCalls = 0;
  int listDirCalls = 0;

  final _statResults = <String, Smb2Stat>{};
  final _listDirResults = <String, List<Smb2DirEntry>>{};

  void setStat(String path, Smb2Stat stat) => _statResults[path] = stat;
  void setListDir(String path, List<Smb2DirEntry> entries) =>
      _listDirResults[path] = entries;

  Future<Smb2Stat> stat(String path) async {
    statCalls++;
    return _statResults[path] ??
        Smb2Stat(
          type: Smb2FileType.file,
          size: 100,
          modified: DateTime(2024),
          created: DateTime(2024),
        );
  }

  Future<List<Smb2DirEntry>> listDirectory(String path) async {
    listDirCalls++;
    return _listDirResults[path] ?? [];
  }
}

void main() {
  late _FakePool fakePool;
  late CachedSmb2Pool cached;

  setUp(() {
    fakePool = _FakePool();
    // Create CachedSmb2Pool with a very short TTL for testing.
    // We use a custom wrapper since we can't mock Smb2Pool directly.
    cached = CachedSmb2Pool.withDelegates(
      statDelegate: fakePool.stat,
      listDirectoryDelegate: fakePool.listDirectory,
      ttl: const Duration(milliseconds: 100),
    );
  });

  group('stat caching', () {
    test('caches stat result', () async {
      await cached.stat('test.txt');
      await cached.stat('test.txt');
      expect(fakePool.statCalls, 1);
    });

    test('different paths are cached separately', () async {
      await cached.stat('a.txt');
      await cached.stat('b.txt');
      await cached.stat('a.txt');
      expect(fakePool.statCalls, 2);
    });

    test('cache expires after TTL', () async {
      await cached.stat('test.txt');
      await Future.delayed(const Duration(milliseconds: 150));
      await cached.stat('test.txt');
      expect(fakePool.statCalls, 2);
    });

    test('invalidate clears specific path', () async {
      await cached.stat('test.txt');
      cached.invalidate('test.txt');
      await cached.stat('test.txt');
      expect(fakePool.statCalls, 2);
    });
  });

  group('listDirectory caching', () {
    test('caches listDirectory result', () async {
      await cached.listDirectory('');
      await cached.listDirectory('');
      expect(fakePool.listDirCalls, 1);
    });

    test('cache expires after TTL', () async {
      await cached.listDirectory('');
      await Future.delayed(const Duration(milliseconds: 150));
      await cached.listDirectory('');
      expect(fakePool.listDirCalls, 2);
    });
  });

  group('clearCache', () {
    test('clears all cached data', () async {
      await cached.stat('a.txt');
      await cached.listDirectory('');
      cached.clearCache();
      await cached.stat('a.txt');
      await cached.listDirectory('');
      expect(fakePool.statCalls, 2);
      expect(fakePool.listDirCalls, 2);
    });
  });
}
