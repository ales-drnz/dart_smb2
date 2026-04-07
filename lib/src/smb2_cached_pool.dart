// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:typed_data';

import 'smb2_pool.dart';
import 'smb2_types.dart';

/// A simple cache entry holding a value and its insertion timestamp.
class _CacheEntry<T> {
  final T value;
  final DateTime createdAt;

  _CacheEntry(this.value) : createdAt = DateTime.now();

  /// Whether this entry has expired given [ttl].
  bool isExpired(Duration ttl) =>
      DateTime.now().difference(createdAt) >= ttl;
}

/// An optional caching layer over [Smb2Pool].
///
/// Caches results from [stat] and [listDirectory] with a configurable TTL.
/// All other methods delegate directly to the underlying pool.
///
/// ```dart
/// final pool = await Smb2Pool.connect(host: '...', share: '...');
/// final cached = CachedSmb2Pool(pool, ttl: Duration(seconds: 60));
///
/// // First call hits the network; subsequent calls within TTL are instant.
/// final entries = await cached.listDirectory('Documents');
/// final info = await cached.stat('Documents/report.pdf');
///
/// // Force-refresh a single path.
/// cached.invalidate('Documents');
/// ```
class CachedSmb2Pool {
  final Smb2Pool? _pool;

  /// How long cached entries remain valid.
  final Duration ttl;

  final Map<String, _CacheEntry<Smb2Stat>> _statCache = {};
  final Map<String, _CacheEntry<List<Smb2DirEntry>>> _dirCache = {};

  final Future<Smb2Stat> Function(String)? _statDelegate;
  final Future<List<Smb2DirEntry>> Function(String)? _listDirDelegate;

  CachedSmb2Pool(
    Smb2Pool pool, {
    this.ttl = const Duration(seconds: 30),
  })  : _pool = pool,
        _statDelegate = null,
        _listDirDelegate = null;

  /// Testing constructor that accepts delegate functions instead of a real pool.
  CachedSmb2Pool.withDelegates({
    required Future<Smb2Stat> Function(String) statDelegate,
    required Future<List<Smb2DirEntry>> Function(String) listDirectoryDelegate,
    this.ttl = const Duration(seconds: 30),
  })  : _pool = null,
        _statDelegate = statDelegate,
        _listDirDelegate = listDirectoryDelegate;

  /// Number of active workers in the underlying pool.
  int get workerCount => _pool?.workerCount ?? 0;

  // ─── Cached methods ──────────────────────────────────────────────────

  /// Get file metadata, returning a cached result when available.
  Future<Smb2Stat> stat(String path) async {
    final entry = _statCache[path];
    if (entry != null && !entry.isExpired(ttl)) {
      return entry.value;
    }
    final result = await (_statDelegate ?? _pool!.stat)(path);
    _statCache[path] = _CacheEntry(result);
    return result;
  }

  /// List directory contents, returning a cached result when available.
  Future<List<Smb2DirEntry>> listDirectory(String path) async {
    final entry = _dirCache[path];
    if (entry != null && !entry.isExpired(ttl)) {
      return entry.value;
    }
    final result = await (_listDirDelegate ?? _pool!.listDirectory)(path);
    _dirCache[path] = _CacheEntry(result);
    return result;
  }

  // ─── Cache management ────────────────────────────────────────────────

  /// Remove cached entries for [path] from both stat and directory caches.
  void invalidate(String path) {
    _statCache.remove(path);
    _dirCache.remove(path);
  }

  /// Clear all cached data.
  void clearCache() {
    _statCache.clear();
    _dirCache.clear();
  }

  // ─── Direct delegation ───────────────────────────────────────────────

  /// List available shares on the connected server.
  Future<List<Smb2ShareInfo>> listShares({
    required String host,
    String? user,
    String? password,
    String? domain,
  }) =>
      _pool!.listShares(
        host: host,
        user: user,
        password: password,
        domain: domain,
      );

  /// Read an entire file into memory.
  Future<Uint8List> readFile(String path) => _pool!.readFile(path);

  /// Read [length] bytes from a file at [offset].
  Future<Uint8List> readFileRange(
    String path, {
    int offset = 0,
    required int length,
  }) =>
      _pool!.readFileRange(path, offset: offset, length: length);

  /// Get file size in bytes.
  Future<int> fileSize(String path) => _pool!.fileSize(path);

  /// Open a file for reading and return a handle tied to one worker.
  Future<Smb2PoolHandle> openFile(String path) => _pool!.openFile(path);

  /// Open a file and get its size in one call.
  Future<(Smb2PoolHandle, int)> openFileWithSize(String path) =>
      _pool!.openFileWithSize(path);

  /// Read [length] bytes at [offset] from an open handle.
  Future<Uint8List> readFromHandle(
    Smb2PoolHandle handle, {
    int offset = 0,
    required int length,
  }) =>
      _pool!.readFromHandle(handle, offset: offset, length: length);

  /// Close an open file handle.
  Future<void> closeHandle(Smb2PoolHandle handle) =>
      _pool!.closeHandle(handle);

  /// Stream a file in chunks without loading everything into RAM.
  Stream<Uint8List> streamFile(
    String path, {
    int chunkSize = 1024 * 1024,
  }) =>
      _pool!.streamFile(path, chunkSize: chunkSize);

  /// Disconnect all workers and release resources.
  ///
  /// Also clears the cache.
  Future<void> disconnect() async {
    clearCache();
    await _pool!.disconnect();
  }
}
