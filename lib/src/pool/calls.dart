// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The calls of a pool that are one request to a worker, and its handles.
part of 'pool.dart';

/// The single-request calls and the handles of [Smb2Pool].
mixin _PoolCalls on _PoolCore {
  /// Lists the entries of the directory at [path] (`''` for the share
  /// root), without `.` and `..`.
  Future<List<Smb2DirEntry>> listDirectory(
    String path, {
    Smb2CancelToken? cancelToken,
  }) => _run(ListDirectory(path), path: path, cancelToken: cancelToken);

  /// The metadata of [path].
  Future<Smb2Stat> stat(String path, {Smb2CancelToken? cancelToken}) =>
      _run(Stat(path), path: path, cancelToken: cancelToken);

  /// The size of the file at [path], in bytes.
  Future<int> fileSize(String path, {Smb2CancelToken? cancelToken}) async =>
      (await stat(path, cancelToken: cancelToken)).size;

  /// Whether [path] exists. Throws on any failure other than a missing
  /// path.
  Future<bool> exists(String path, {Smb2CancelToken? cancelToken}) async {
    try {
      await stat(path, cancelToken: cancelToken);
      return true;
    } on Smb2Exception catch (e) {
      if (e.isNotFound) return false;
      rethrow;
    }
  }

  /// Space statistics of the share that holds [path] (`''` for the root).
  Future<Smb2StatVfs> statvfs(String path, {Smb2CancelToken? cancelToken}) =>
      _run(StatVfs(path), path: path, cancelToken: cancelToken);

  /// The target of the symbolic link at [path].
  Future<String> readlink(String path, {Smb2CancelToken? cancelToken}) =>
      _run(Readlink(path), path: path, cancelToken: cancelToken);

  /// Sends a keepalive echo on one worker. Completes when its connection is
  /// healthy, reconnecting it first when it is not.
  Future<void> echo({Smb2CancelToken? cancelToken}) =>
      _run<void>(const Echo(), cancelToken: cancelToken);

  /// Deletes the file [path]; a directory, or a link to one, fails with
  /// [Smb2ErrorType.isADirectory] (remove it with [Smb2Pool.rmdir]). Not repeated
  /// after a network failure.
  Future<void> deleteFile(String path, {Smb2CancelToken? cancelToken}) => _run(
    DeleteFile(path),
    path: path,
    idempotent: false,
    cancelToken: cancelToken,
  );

  /// Renames or moves [oldPath] to [newPath]. Not repeated after a network
  /// failure.
  ///
  /// When [newPath] exists the rename fails with
  /// [Smb2ErrorType.alreadyExists], unless [overwrite] is set: then a file
  /// at [newPath] is replaced in the same step, with no moment without one.
  /// A directory at [newPath], or a file another client holds open, is not
  /// replaced even then; see [Smb2Client.rename].
  Future<void> rename(
    String oldPath,
    String newPath, {
    bool overwrite = false,
    Smb2CancelToken? cancelToken,
  }) => _run(
    Rename(oldPath, newPath, overwrite: overwrite),
    path: oldPath,
    idempotent: false,
    cancelToken: cancelToken,
  );

  /// Creates [newPath] as a hard link to the file [existingPath]; see
  /// [Smb2Client.link]. Not repeated after a network failure.
  Future<void> link(
    String existingPath,
    String newPath, {
    Smb2CancelToken? cancelToken,
  }) => _run(
    Link(existingPath, newPath),
    path: newPath,
    idempotent: false,
    cancelToken: cancelToken,
  );

  /// Creates a symbolic link at [linkPath] that points at [target]; see
  /// [Smb2Client.symlink]. Not repeated after a network failure.
  Future<void> symlink(
    String target,
    String linkPath, {
    bool directory = false,
    Smb2CancelToken? cancelToken,
  }) => _run(
    Symlink(target, linkPath, directory: directory),
    path: linkPath,
    idempotent: false,
    cancelToken: cancelToken,
  );

  /// Truncates (or extends with zeros) the file [path] to [length] bytes.
  Future<void> truncate(
    String path,
    int length, {
    Smb2CancelToken? cancelToken,
  }) => _run(Truncate(path, length), path: path, cancelToken: cancelToken);

  /// Sets the last-modified and/or last-accessed time of [path]; see
  /// [Smb2Client.setFileTimes].
  Future<void> setFileTimes(
    String path, {
    DateTime? modified,
    DateTime? accessed,
    Smb2CancelToken? cancelToken,
  }) => _run(
    SetFileTimes(
      path,
      modifiedUs: modified?.microsecondsSinceEpoch,
      accessedUs: accessed?.microsecondsSinceEpoch,
    ),
    path: path,
    cancelToken: cancelToken,
  );

  /// Reads the whole file at [path] into memory. For large files prefer
  /// [Smb2Pool.streamFile] or [Smb2Pool.downloadToFile].
  Future<Uint8List> readFile(String path, {Smb2CancelToken? cancelToken}) =>
      _run(ReadFile(path), path: path, cancelToken: cancelToken);

  /// Reads [length] bytes of [path] from [offset]: fewer only when the file
  /// ends first.
  Future<Uint8List> readFileRange(
    String path, {
    int offset = 0,
    required int length,
    Smb2CancelToken? cancelToken,
  }) => _run(
    ReadRange(path, offset, length),
    path: path,
    cancelToken: cancelToken,
  );

  /// Replaces the content of [path] with [data], creating the file if it
  /// does not exist.
  ///
  /// [data] is copied into a native buffer in the calling isolate, at
  /// memory speed; for large writes from the UI isolate prefer
  /// [Smb2Pool.streamWrite] with chunks of a few MiB.
  Future<void> writeFile(
    String path,
    Uint8List data, {
    Smb2CancelToken? cancelToken,
  }) => _run(
    WriteFile(path, data.length),
    buffer: () => _native(data),
    path: path,
    cancelToken: cancelToken,
  );

  /// Writes [data] to [path] at [offset], creating the file if it does not
  /// exist. The rest of the file is left as it is. [data] is copied in the
  /// calling isolate, as for [writeFile].
  Future<void> writeFileRange(
    String path,
    Uint8List data, {
    int offset = 0,
    Smb2CancelToken? cancelToken,
  }) => _run(
    WriteRange(path, data.length, offset),
    buffer: () => _native(data),
    path: path,
    cancelToken: cancelToken,
  );

  /// Opens [path] for reading on one worker. Read it with
  /// [readFromHandle], then [closeHandle] — or use [Smb2Pool.withFile].
  Future<Smb2PoolHandle> openFile(String path, {Smb2CancelToken? cancelToken}) {
    return _dispatch<int, Smb2PoolHandle>(
      Open(path),
      (slot, id) =>
          Smb2PoolHandleInternal.create(slot, id, path, writable: false),
      path: path,
      cancelToken: cancelToken,
    );
  }

  /// Opens [path] for reading and returns its size with the handle.
  Future<(Smb2PoolHandle, int)> openFileWithSize(
    String path, {
    Smb2CancelToken? cancelToken,
  }) {
    return _dispatch<(int, int), (Smb2PoolHandle, int)>(
      OpenWithSize(path),
      (slot, opened) => (
        Smb2PoolHandleInternal.create(slot, opened.$1, path, writable: false),
        opened.$2,
      ),
      path: path,
      cancelToken: cancelToken,
    );
  }

  /// Opens [path] for writing on one worker, creating it if it does not
  /// exist and emptying it first when [truncate] is set. Write with
  /// [writeToHandle], then [closeHandle].
  Future<Smb2PoolHandle> openFileWrite(
    String path, {
    bool truncate = false,
    Smb2CancelToken? cancelToken,
  }) => _openWrite(path, truncate: truncate, cancelToken: cancelToken);

  /// Opens [path] for writing. A [temporary] file is one the pool writes
  /// and then renames into place: it is opened so that it can be renamed or
  /// removed while a handle is open, which a handle the server keeps for a
  /// connection that died would otherwise refuse.
  Future<Smb2PoolHandle> _openWrite(
    String path, {
    required bool truncate,
    bool temporary = false,
    Smb2CancelToken? cancelToken,
  }) {
    return _dispatch<int, Smb2PoolHandle>(
      OpenWrite(path, truncate: truncate, temporary: temporary),
      (slot, id) => Smb2PoolHandleInternal.create(
        slot,
        id,
        path,
        writable: true,
        temporary: temporary,
      ),
      path: path,
      cancelToken: cancelToken,
    );
  }

  /// Reads [length] bytes from [handle] at [offset]: fewer only when the
  /// file ends first.
  Future<Uint8List> readFromHandle(
    Smb2PoolHandle handle, {
    int offset = 0,
    required int length,
    Smb2CancelToken? cancelToken,
  }) => _onHandle(
    handle,
    (id) => ReadHandle(id, offset, length),
    cancelToken: cancelToken,
  );

  /// Writes [data] to [handle] at [offset]. [data] is copied in the calling
  /// isolate, as for [writeFile].
  Future<void> writeToHandle(
    Smb2PoolHandle handle,
    Uint8List data, {
    int offset = 0,
    Smb2CancelToken? cancelToken,
  }) => _onHandle(
    handle,
    (id) => WriteHandle(id, data.length, offset),
    buffer: () => _native(data),
    cancelToken: cancelToken,
  );

  /// Flushes the writes on [handle] to the server's disk.
  Future<void> fsyncHandle(
    Smb2PoolHandle handle, {
    Smb2CancelToken? cancelToken,
  }) => _onHandle(handle, FsyncHandle.new, cancelToken: cancelToken);

  /// Truncates (or extends with zeros) the file of [handle] to [length]
  /// bytes.
  Future<void> ftruncateHandle(
    Smb2PoolHandle handle,
    int length, {
    Smb2CancelToken? cancelToken,
  }) => _onHandle(
    handle,
    (id) => FtruncateHandle(id, length),
    cancelToken: cancelToken,
  );

  /// Closes [handle], and completes once the server has closed the file, so
  /// a delete or rename of it can follow. Closing a closed handle does
  /// nothing, and a close that fails is not reported: the server drops the
  /// handle with the connection anyway.
  Future<void> closeHandle(Smb2PoolHandle handle) async {
    final target = handle.markClosed();
    if (target == null) return;
    final (worker, id) = target;
    final done = worker
        .call(CloseHandle(id))
        // The worker is gone or reconnecting; its handles went with it.
        .catchError((Object _) {}, test: (e) => e is Smb2Exception);
    final key = _pathKey(handle.path);
    final before = _pendingCloses[key];
    final pending = before == null
        ? done
        : Future.wait([before, done]).then((_) {});
    _pendingCloses[key] = pending;
    unawaited(
      pending.whenComplete(() {
        if (identical(_pendingCloses[key], pending)) {
          _pendingCloses.remove(key)?.ignore();
        }
      }),
    );
    await done;
  }

  /// Closes [handle] without waiting: for a call that failed or was
  /// cancelled, whose close may queue behind a read stuck on the network. A
  /// later delete, rename or write of the same path waits for the close.
  void _closeLater(Smb2PoolHandle handle) => unawaited(closeHandle(handle));
}

/// A copy of [data] in a `malloc` buffer for a write request. The copy is
/// made in the calling isolate, at memory speed (about 9 ms for 64 MiB);
/// [Worker] frees the buffer once the request is done or never sent.
int _native(Uint8List data) {
  final buf = malloc<Uint8>(max(data.length, 1));
  buf.asTypedList(data.length).setAll(0, data);
  return buf.address;
}
