// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'smb2_error_type.dart';
import 'smb2_exceptions.dart';
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

  /// Testing constructor that accepts delegate functions instead of a real
  /// [Smb2Pool]. Only `stat` / `listDirectory` / `exists` / `invalidate` /
  /// `clearCache` are usable — every other method requires a real pool and
  /// throws if called.
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

  /// Check whether a file or directory exists.
  ///
  /// Uses the stat cache when available.
  /// Returns `true` if the path exists, `false` if it does not.
  /// Throws [Smb2Exception] on connection or permission errors.
  Future<bool> exists(String path) async {
    try {
      await stat(path);
      return true;
    } on Smb2Exception catch (e) {
      if (e.type == Smb2ErrorType.fileNotFound) return false;
      rethrow;
    }
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

  /// Invalidate caches for [path] and its parent directory.
  void _invalidatePath(String path) {
    invalidate(path);
    _invalidateParent(path);
  }

  /// Invalidate the parent directory's listing cache.
  void _invalidateParent(String path) {
    final sep = path.lastIndexOf('/');
    final parent = sep > 0 ? path.substring(0, sep) : '';
    _dirCache.remove(parent);
  }

  // ─── Write operations (invalidate cache) ─────────────────────────────

  /// Write [data] to a file at [offset], creating it if it doesn't exist.
  Future<void> writeFileRange(
    String path,
    Uint8List data, {
    int offset = 0,
  }) async {
    await _pool!.writeFileRange(path, data, offset: offset);
    _invalidatePath(path);
  }

  /// Write [data] to a file, creating or truncating it.
  Future<void> writeFile(String path, Uint8List data) async {
    await _pool!.writeFile(path, data);
    _invalidatePath(path);
  }

  /// Delete a file.
  Future<void> deleteFile(String path) async {
    await _pool!.deleteFile(path);
    _invalidatePath(path);
  }

  /// Create a directory.
  Future<void> mkdir(String path) async {
    await _pool!.mkdir(path);
    _invalidateParent(path);
  }

  /// Delete an empty directory.
  Future<void> rmdir(String path) async {
    await _pool!.rmdir(path);
    _invalidatePath(path);
  }

  /// Rename or move a file or directory.
  Future<void> rename(String oldPath, String newPath) async {
    await _pool!.rename(oldPath, newPath);
    _invalidatePath(oldPath);
    _invalidatePath(newPath);
  }

  /// Truncate a file to [length] bytes.
  Future<void> truncate(String path, int length) async {
    await _pool!.truncate(path, length);
    _invalidatePath(path);
  }

  /// Send a keepalive echo to the server.
  Future<void> echo() => _pool!.echo();

  /// Get filesystem statistics (total/free space).
  Future<Smb2StatVfs> statvfs(String path) => _pool!.statvfs(path);

  /// Read the target path of a symbolic link.
  Future<String> readlink(String path) => _pool!.readlink(path);

  /// Flush all buffered writes on a file handle to the server.
  Future<void> fsyncHandle(Smb2PoolHandle handle) => _pool!.fsyncHandle(handle);

  /// Truncate an open file handle to [length] bytes.
  Future<void> ftruncateHandle(Smb2PoolHandle handle, int length) =>
      _pool!.ftruncateHandle(handle, length);

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

  /// Open a file for writing and return a handle tied to one worker.
  Future<Smb2PoolHandle> openFileWrite(String path) => _pool!.openFileWrite(path);

  /// Write [data] at [offset] to an open write handle.
  Future<void> writeToHandle(
    Smb2PoolHandle handle,
    Uint8List data, {
    int offset = 0,
  }) =>
      _pool!.writeToHandle(handle, data, offset: offset);

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

  /// Write data from a [Stream] to a file without loading everything into RAM.
  Future<void> streamWrite(String path, Stream<Uint8List> chunks) async {
    await _pool!.streamWrite(path, chunks);
    _invalidatePath(path);
  }

  /// Stream a file in chunks without loading everything into RAM.
  Stream<Uint8List> streamFile(
    String path, {
    int chunkSize = 1024 * 1024,
    void Function(int received, int total)? onProgress,
    bool Function()? isCanceled,
  }) =>
      _pool!.streamFile(
        path,
        chunkSize: chunkSize,
        onProgress: onProgress,
        isCanceled: isCanceled,
      );

  /// Download [path] to [destFile] with progress and cancel support.
  Future<int> downloadToFile(
    String path,
    File destFile, {
    int chunkSize = 1024 * 1024,
    void Function(int received, int total)? onProgress,
    bool Function()? isCanceled,
  }) =>
      _pool!.downloadToFile(
        path,
        destFile,
        chunkSize: chunkSize,
        onProgress: onProgress,
        isCanceled: isCanceled,
      );

  /// Open [path] for reading and run [body] with a scoped [Smb2File].
  Future<T> withFile<T>(
    String path,
    FutureOr<T> Function(Smb2File file) body, {
    int? knownSize,
  }) =>
      _pool!.withFile(path, body, knownSize: knownSize);

  /// Disconnect all workers and release resources.
  ///
  /// Also clears the cache.
  Future<void> disconnect() async {
    clearCache();
    await _pool!.disconnect();
  }
}
