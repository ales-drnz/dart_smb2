// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Synchronous SMB2/3 client over libsmb2's sync API.
///
/// The only Dart layer above the generated bindings
/// (`lib/src/ffi/libsmb2.g.dart`): the context lifecycle, path validation,
/// error classification, open flags and the read/write loops.
library;

import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'ffi/libsmb2.g.dart';
import 'ffi/poll.dart';
import 'libsmb2_release.dart';
import 'pool/pool.dart';
import 'smb2_error_type.dart';
import 'smb2_exception.dart';
import 'smb2_types.dart';

/// A file opened on a [Smb2Client].
///
/// Returned by [Smb2Client.openFile], [Smb2Client.openFileWithSize] and
/// [Smb2Client.openFileWrite], and passed back to the handle methods of
/// the same client. After [Smb2Client.closeHandle] or
/// [Smb2Client.disconnect] it is closed: closing it again does nothing, and
/// any other use throws a [Smb2Exception] of type [Smb2ErrorType.state].
///
/// {@category Synchronous client}
final class Smb2Handle {
  final Smb2Client _client;
  Pointer<smb2fh> _fh;

  /// The share-relative path the handle was opened for.
  final String path;

  Smb2Handle._(this._client, this._fh, this.path);

  /// Whether the handle has been closed.
  bool get isClosed => _fh == nullptr;
}

/// SMB2/3 client on libsmb2's synchronous API.
///
/// Every call blocks until the server answers, so run the client inside an
/// isolate of your own — or use [Smb2Pool], which runs clients in worker
/// isolates and is the recommended entry point.
///
/// ```dart
/// final client = Smb2Client()
///   ..connect(
///     host: '192.168.1.10',
///     share: 'Music',
///     user: 'alice',
///     password: 'secret',
///   );
/// try {
///   final entries = client.listDirectory('');
/// } finally {
///   client.disconnect();
/// }
/// ```
///
/// {@category Synchronous client}
final class Smb2Client implements Finalizable {
  Pointer<smb2_context> _ctx = nullptr;
  final Set<Smb2Handle> _handles = {};

  /// The request timeout in whole seconds, as libsmb2 counts it (0: none).
  int _timeoutSeconds = 0;

  /// The watchers by id, and the callback libsmb2 calls with their
  /// notifications: created by the first [watch], closed by [disconnect],
  /// after the context that may still call it is gone.
  final Map<int, Smb2Watcher> _watchers = {};
  NativeCallable<_NotifyCallback>? _notify;
  int _nextWatcher = 1;

  /// Frees the context of a client dropped without [disconnect]. No logoff
  /// is sent, so the server keeps the session until it times out.
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<smb2_context>)>>(
      smb2_destroy_context,
    ).cast(),
  );

  /// Creates a client that is not connected yet.
  Smb2Client();

  /// Whether the client is connected to a share.
  bool get isConnected => _ctx != nullptr;

  /// The largest read the server accepts in one request, negotiated at
  /// [connect]. Longer reads are split into several requests.
  int get maxReadSize {
    _ensureConnected();
    return smb2_get_max_read_size(_ctx);
  }

  /// The largest write the server accepts in one request, negotiated at
  /// [connect]. Longer writes are split into several requests.
  int get maxWriteSize {
    _ensureConnected();
    return smb2_get_max_write_size(_ctx);
  }

  // ─── Share enumeration ───────────────────────────────────────────────────

  /// Lists the shares of [host], over a connection of its own to `IPC$`
  /// that it closes before returning. Needs no connected client. The
  /// credentials work as in [connect].
  static List<Smb2ShareInfo> listShares({
    required String host,
    String? user,
    String? password,
    String? domain,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final ctx = _newContext(
      user: user,
      password: password,
      domain: domain,
      timeout: timeout,
    );
    try {
      _connectContext(ctx, host: host, share: r'IPC$', user: user);
      try {
        final reply = smb2_share_enum_sync(
          ctx,
          smb2_share_info_level.SMB2_SHARE_INFO_1,
        );
        if (reply == nullptr) {
          throw _error(ctx, 'Share enumeration failed');
        }
        try {
          final count = reply.ref.entries_read;
          final infos = reply.ref.share_info.info_1;
          if (count == 0 || infos == nullptr) return const [];
          return [
            for (var i = 0; i < count; i++)
              Smb2ShareInfo(
                name: _string(infos[i].netname),
                type: infos[i].type,
                remark: _string(infos[i].remark),
              ),
          ];
        } finally {
          smb2_free_data(ctx, reply.cast());
        }
      } finally {
        smb2_disconnect_share(ctx);
      }
    } finally {
      smb2_destroy_context(ctx);
    }
  }

  // ─── Connection ─────────────────────────────────────────────────────────

  /// Connects to [share] on [host], disconnecting first if connected.
  ///
  /// Paths in later calls are relative to the share root; `''` is the root
  /// itself. [timeout] bounds every request, this one included; a request
  /// that runs out of it fails with [Smb2ErrorType.timeout].
  ///
  /// Without a [user], or with a null [password], the logon is anonymous
  /// and the user name is not sent. For an account whose password is
  /// empty, pass `password: ''` with its [user].
  ///
  /// Throws [Smb2Exception] on failure.
  void connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    Duration timeout = const Duration(seconds: 30),
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
  }) {
    if (isConnected) disconnect();
    final ctx = _newContext(
      user: user,
      password: password,
      domain: domain,
      timeout: timeout,
    );
    try {
      if (seal) smb2_set_seal(ctx, 1);
      if (signing) smb2_set_sign(ctx, 1);
      if (version != Smb2Version.any) {
        smb2_set_version(ctx, smb2_negotiate_version.fromValue(version.value));
      }
      _connectContext(ctx, host: host, share: share, user: user);
    } catch (_) {
      smb2_destroy_context(ctx);
      rethrow;
    }
    _ctx = ctx;
    _timeoutSeconds = _seconds(timeout);
    _finalizer.attach(this, ctx.cast(), detach: this);
  }

  /// Closes every open handle, logs off and frees the connection. Does
  /// nothing when not connected.
  void disconnect() {
    if (_ctx == nullptr) return;
    for (final w in _watchers.values.toList()) {
      w.close();
    }
    for (final h in _handles) {
      smb2_close(_ctx, h._fh);
      h._fh = nullptr;
    }
    _handles.clear();
    _finalizer.detach(this);
    smb2_disconnect_share(_ctx);
    // Calls the callbacks of requests still pending, a watch's included:
    // the notify callback must outlive it.
    smb2_destroy_context(_ctx);
    _ctx = nullptr;
    _notify?.close();
    _notify = null;
  }

  /// Sends a keepalive echo. Returns when the connection is healthy;
  /// throws [Smb2Exception] when it is lost.
  void echo() {
    _ensureConnected();
    _check(smb2_echo(_ctx), 'Echo failed');
  }

  // ─── Directories ────────────────────────────────────────────────────────

  /// Lists the entries of the directory at [path], without `.` and `..`.
  /// Each entry carries its metadata, so no request per entry is needed.
  List<Smb2DirEntry> listDirectory(String path) => _list(path).$3;

  /// The listing of [path], with the file ids of its `.` and `..` entries
  /// (0 when the server lists none).
  (int, int, List<Smb2DirEntry>) _list(String path) {
    _ensureConnected();
    final dir = using((arena) {
      final d = smb2_opendir(_ctx, _path(path, arena));
      if (d == nullptr) throw _error(_ctx, 'Cannot list directory', path: path);
      return d;
    });
    try {
      final results = <Smb2DirEntry>[];
      var self = 0, up = 0;
      for (
        var ent = smb2_readdir(_ctx, dir);
        ent != nullptr;
        ent = smb2_readdir(_ctx, dir)
      ) {
        // The entry is recycled by the next readdir: copy it now.
        final name = _string(ent.ref.name);
        if (name == '.') {
          self = ent.ref.st.smb2_ino;
        } else if (name == '..') {
          up = ent.ref.st.smb2_ino;
        } else {
          results.add(Smb2DirEntry(name: name, stat: _stat(ent.ref.st)));
        }
      }
      return (self, up, results);
    } finally {
      smb2_closedir(_ctx, dir);
    }
  }

  /// Creates the directory [path].
  void mkdir(String path) {
    _ensureConnected();
    using((arena) {
      _check(smb2_mkdir(_ctx, _path(path, arena)), 'Mkdir failed', path: path);
    });
  }

  /// Removes the empty directory [path].
  void rmdir(String path) {
    _ensureConnected();
    using((arena) {
      _check(smb2_rmdir(_ctx, _path(path, arena)), 'Rmdir failed', path: path);
    });
  }

  // ─── Metadata ───────────────────────────────────────────────────────────

  /// The metadata of [path], in one compound request.
  Smb2Stat stat(String path) {
    _ensureConnected();
    return using((arena) {
      final out = arena<smb2_stat_64>();
      _check(
        smb2_stat(_ctx, _path(path, arena), out),
        'Stat failed',
        path: path,
      );
      return _stat(out.ref);
    });
  }

  /// The size of the file at [path], in bytes.
  int fileSize(String path) => stat(path).size;

  /// Whether [path] exists. Throws on any failure other than a missing
  /// path.
  bool exists(String path) {
    try {
      stat(path);
      return true;
    } on Smb2Exception catch (e) {
      if (e.isNotFound) return false;
      rethrow;
    }
  }

  /// Space statistics of the share that holds [path] (`''` for the root).
  Smb2StatVfs statvfs(String path) {
    _ensureConnected();
    return using((arena) {
      final out = arena<Smb2StatVfsNative>();
      _check(
        smb2_statvfs(_ctx, _path(path, arena), out),
        'Statvfs failed',
        path: path,
      );
      final s = out.ref;
      return Smb2StatVfs(
        blockSize: s.f_bsize,
        fragmentSize: s.f_frsize,
        totalBlocks: s.f_blocks,
        freeBlocks: s.f_bfree,
        availableBlocks: s.f_bavail,
        maxNameLength: s.f_namemax,
      );
    });
  }

  /// The target of the symbolic link at [path].
  String readlink(String path) {
    _ensureConnected();
    return using((arena) {
      // smb2_readlink copies with strncpy and reports no length: one zeroed
      // byte past the size it is given keeps the result terminated.
      final buf = arena<Uint8>(_readlinkBufferSize + 1);
      _check(
        smb2_readlink(
          _ctx,
          _path(path, arena),
          buf.cast(),
          _readlinkBufferSize,
        ),
        'Readlink failed',
        path: path,
      );
      return buf.cast<Utf8>().toDartString();
    });
  }

  /// Sets the last-modified and/or last-accessed time of [path].
  ///
  /// Fields left `null` are not changed. At least one must be given, after
  /// the Unix epoch (SMB reserves 0 for "leave unchanged"). Call it after
  /// the file's write handles are closed: the server refreshes the
  /// modified time on write and close.
  void setFileTimes(String path, {DateTime? modified, DateTime? accessed}) {
    _ensureConnected();
    if (modified == null && accessed == null) {
      throw _invalid('setFileTimes needs modified or accessed', path);
    }
    final mtime = modified?.microsecondsSinceEpoch ?? 0;
    final atime = accessed?.microsecondsSinceEpoch ?? 0;
    if ((modified != null && mtime <= 0) || (accessed != null && atime <= 0)) {
      throw _invalid('setFileTimes needs times after the Unix epoch', path);
    }
    using((arena) {
      _check(
        smb2_utimes(_ctx, _path(path, arena), atime, mtime),
        'Set file times failed',
        path: path,
      );
    });
  }

  // ─── Whole-file reads and writes ─────────────────────────────────────────

  /// Reads [length] bytes of [path] from [offset]: fewer only when the file
  /// ends first.
  Uint8List readFileRange(String path, {int offset = 0, required int length}) {
    _checkRange(offset, length, path);
    final handle = openFile(path);
    try {
      return readFromHandle(handle, offset: offset, length: length);
    } finally {
      closeHandle(handle);
    }
  }

  /// Reads the whole file at [path] into memory. For large files prefer
  /// [readFileChunked] or the pool's streaming helpers.
  Uint8List readFile(String path) {
    final (handle, size) = openFileWithSize(path);
    try {
      return readFromHandle(handle, length: size);
    } finally {
      closeHandle(handle);
    }
  }

  /// Reads [path] in chunks of up to [chunkSize] bytes, keeping one handle
  /// open for the whole read and only one chunk in memory at a time.
  Iterable<Uint8List> readFileChunked(
    String path, {
    int chunkSize = 1024 * 1024,
  }) sync* {
    if (chunkSize <= 0) throw _invalid('chunkSize must be positive', path);
    final (handle, size) = openFileWithSize(path);
    try {
      var offset = 0;
      while (offset < size) {
        final want = size - offset < chunkSize ? size - offset : chunkSize;
        final chunk = readFromHandle(handle, offset: offset, length: want);
        if (chunk.isEmpty) break; // The file shrank while it was read.
        offset += chunk.length;
        yield chunk;
      }
    } finally {
      closeHandle(handle);
    }
  }

  /// Writes [data] to [path] at [offset], creating the file if it does not
  /// exist. The rest of the file is left as it is.
  void writeFileRange(String path, Uint8List data, {int offset = 0}) {
    _checkRange(offset, data.length, path);
    final handle = openFileWrite(path);
    try {
      writeToHandle(handle, data, offset: offset);
    } finally {
      closeHandle(handle);
    }
  }

  /// Replaces the content of [path] with [data], creating the file if it
  /// does not exist.
  void writeFile(String path, Uint8List data) {
    final handle = openFileWrite(path, truncate: true);
    try {
      writeToHandle(handle, data);
    } finally {
      closeHandle(handle);
    }
  }

  /// Replaces the content of [path] with [chunks], written in order through
  /// one handle, so only one chunk is in memory at a time.
  void writeFileChunked(String path, Iterable<Uint8List> chunks) {
    final handle = openFileWrite(path, truncate: true);
    try {
      var offset = 0;
      for (final chunk in chunks) {
        writeToHandle(handle, chunk, offset: offset);
        offset += chunk.length;
      }
    } finally {
      closeHandle(handle);
    }
  }

  /// Deletes the file [path]; a directory, or a link to one, fails with
  /// [Smb2ErrorType.isADirectory] (remove it with [rmdir]).
  void deleteFile(String path) {
    _ensureConnected();
    using((arena) {
      _check(
        smb2_unlink(_ctx, _path(path, arena)),
        'Delete failed',
        path: path,
      );
    });
  }

  /// Renames or moves [oldPath] to [newPath].
  ///
  /// When [newPath] exists the rename fails with
  /// [Smb2ErrorType.alreadyExists], unless [overwrite] is set: then a file
  /// at [newPath] is replaced in the same step, so there is never a moment
  /// without one. A directory at [newPath], or a file another client holds
  /// open, is not replaced even then ([Smb2ErrorType.accessDenied] or
  /// [Smb2ErrorType.inUse]).
  void rename(String oldPath, String newPath, {bool overwrite = false}) {
    _ensureConnected();
    using((arena) {
      _check(
        smb2_rename2(
          _ctx,
          _path(oldPath, arena),
          _path(newPath, arena),
          overwrite ? SMB2_RENAME_REPLACE_IF_EXISTS : 0,
        ),
        'Rename failed',
        path: oldPath,
      );
    });
  }

  /// Creates [newPath] as a hard link to the file [existingPath]: one file
  /// under two names, on the same share. Fails with
  /// [Smb2ErrorType.alreadyExists] when [newPath] exists, and on a server
  /// or file system without hard links with [Smb2ErrorType.notSupported].
  void link(String existingPath, String newPath) {
    _ensureConnected();
    using((arena) {
      _check(
        smb2_link(_ctx, _path(existingPath, arena), _path(newPath, arena)),
        'Link failed',
        path: newPath,
      );
    });
  }

  /// Creates a symbolic link at [linkPath] that points at [target].
  ///
  /// [target] is stored as given: a path relative to the link's directory,
  /// or, when it starts with a separator or a drive letter, an absolute
  /// path on the server. Set [directory] for a link to a directory, which
  /// Windows types apart from a link to a file.
  ///
  /// Windows servers allow it only to accounts that may create symbolic
  /// links (administrators by default); Samba stores the link only on a
  /// share that allows it. Elsewhere it fails with
  /// [Smb2ErrorType.accessDenied] or [Smb2ErrorType.notSupported].
  void symlink(String target, String linkPath, {bool directory = false}) {
    _ensureConnected();
    if (target.isEmpty || target.contains('\u0000')) {
      throw _invalid('The link target is empty or contains NUL', linkPath);
    }
    using((arena) {
      _check(
        smb2_symlink(
          _ctx,
          target.toNativeUtf8(allocator: arena).cast(),
          _path(linkPath, arena),
          directory ? SMB2_SYMLINK_DIRECTORY : 0,
        ),
        'Symlink failed',
        path: linkPath,
      );
    });
  }

  /// Truncates (or extends with zeros) the file [path] to [length] bytes.
  void truncate(String path, int length) {
    _ensureConnected();
    if (length < 0) throw _invalid('length must not be negative', path);
    using((arena) {
      _check(
        smb2_truncate(_ctx, _path(path, arena), length),
        'Truncate failed',
        path: path,
      );
    });
  }

  // ─── Handles ────────────────────────────────────────────────────────────

  /// Opens [path] for reading. Read it with [readFromHandle], then
  /// [closeHandle]: one open and one close for any number of reads.
  Smb2Handle openFile(String path) => _open(path, _flags.rdonly);

  /// Opens [path] for reading and returns its size with the handle.
  (Smb2Handle, int) openFileWithSize(String path) {
    final handle = openFile(path);
    try {
      return (handle, _fstatSize(handle));
    } catch (_) {
      closeHandle(handle);
      rethrow;
    }
  }

  /// Opens [path] for writing, creating it if it does not exist, and
  /// emptying it first when [truncate] is set. Write with [writeToHandle],
  /// then [closeHandle].
  Smb2Handle openFileWrite(String path, {bool truncate = false}) =>
      _open(path, _flags.wronly | _flags.creat | (truncate ? _flags.trunc : 0));

  /// Reads [length] bytes from [handle] at [offset]: fewer only when the
  /// file ends first.
  Uint8List readFromHandle(
    Smb2Handle handle, {
    int offset = 0,
    required int length,
  }) {
    final (address, n) = readNative(handle, offset: offset, length: length);
    if (n == 0) return Uint8List(0);
    return Pointer<Uint8>.fromAddress(
      address,
    ).asTypedList(n, finalizer: malloc.nativeFree);
  }

  /// Writes [data] to [handle] at [offset], split into requests the server
  /// accepts.
  void writeToHandle(Smb2Handle handle, Uint8List data, {int offset = 0}) {
    _checkRange(offset, data.length, handle.path);
    if (data.isEmpty) return;
    final buf = malloc<Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      writeNative(handle, buf.address, data.length, offset: offset);
    } finally {
      malloc.free(buf);
    }
  }

  /// Flushes the writes on [handle] to the server's disk.
  void fsyncHandle(Smb2Handle handle) {
    final fh = _live(handle);
    _check(smb2_fsync(_ctx, fh), 'Fsync failed', path: handle.path);
  }

  /// Truncates (or extends with zeros) the file of [handle] to [length]
  /// bytes.
  void ftruncateHandle(Smb2Handle handle, int length) {
    final fh = _live(handle);
    if (length < 0) throw _invalid('length must not be negative', handle.path);
    _check(
      smb2_ftruncate(_ctx, fh, length),
      'Ftruncate failed',
      path: handle.path,
    );
  }

  /// Closes [handle]. Closing a closed handle does nothing.
  void closeHandle(Smb2Handle handle) {
    if (handle.isClosed) return;
    _owned(handle);
    final fh = handle._fh;
    handle._fh = nullptr;
    _handles.remove(handle);
    if (_ctx != nullptr) smb2_close(_ctx, fh);
  }

  // ─── Change notification ─────────────────────────────────────────────────

  /// Watches the directory [path] for changes, and returns the
  /// [Smb2Watcher] that reports them: call [Smb2Watcher.next] to wait for
  /// the next ones, and [Smb2Watcher.close] when done.
  ///
  /// The server reports the changes in [filter] (a mask of
  /// [Smb2ChangeFilter] bits) to the entries of [path], and with
  /// [recursive] to everything below it. Changes are kept from the moment
  /// the watch starts, so none is lost between two calls of
  /// [Smb2Watcher.next]; when the server keeps more than it can report it
  /// sends a [Smb2ChangeAction.overflow] event instead.
  ///
  /// The other calls of the client go on while it watches, and collect the
  /// notifications that arrive meanwhile. The directory stays open: it
  /// cannot be renamed or removed until the watcher is closed. Once a client
  /// has watched, only [disconnect] frees its connection, not the garbage
  /// collector.
  ///
  /// Fails with [Smb2ErrorType.notADirectory] for a file, and with
  /// [Smb2ErrorType.notFound] for a path that does not exist.
  Smb2Watcher watch(
    String path, {
    bool recursive = false,
    int filter = Smb2ChangeFilter.defaults,
  }) {
    _ensureConnected();
    if (filter <= 0 || filter > Smb2ChangeFilter.all) {
      throw _invalid('filter must be a mask of Smb2ChangeFilter bits', path);
    }
    final fh = using(
      (arena) => smb2_open(_ctx, _path(path, arena), _flags.directory),
    );
    if (fh == nullptr) throw _error(_ctx, 'Watch failed', path: path);
    final watcher = Smb2Watcher._(
      this,
      _nextWatcher++,
      fh,
      path,
      recursive ? SMB2_CHANGE_NOTIFY_WATCH_TREE : 0,
      filter,
    );
    _notify ??= NativeCallable<_NotifyCallback>.isolateLocal(_onNotify)
      ..keepIsolateAlive = false;
    _watchers[watcher._id] = watcher;
    try {
      _arm(watcher);
    } catch (_) {
      _watchers.remove(watcher._id);
      smb2_close(_ctx, fh);
      watcher._fh = nullptr;
      rethrow;
    }
    return watcher;
  }

  /// Sends a CHANGE_NOTIFY for [w]. The request waits on the server until
  /// something changes, so it is queued without libsmb2's timeout, which
  /// would otherwise end it; the other requests keep theirs.
  void _arm(Smb2Watcher w) {
    smb2_set_timeout(_ctx, 0);
    final int rc;
    try {
      rc = smb2_notify_change_filehandle_async(
        _ctx,
        w._fh,
        w._flags,
        w._filter,
        0,
        _notify!.nativeFunction,
        Pointer<Void>.fromAddress(w._id),
      );
    } finally {
      smb2_set_timeout(_ctx, _timeoutSeconds);
    }
    if (rc < 0) throw _error(_ctx, 'Watch failed', rc: rc, path: w.path);
  }

  /// libsmb2's callback for a CHANGE_NOTIFY reply. Runs inside
  /// smb2_service() or a sync call, on this isolate's thread. [status] is
  /// 0, or the NT status of a failed reply (positive for the informational
  /// NOTIFY_ENUM_DIR and NOTIFY_CLEANUP).
  void _onNotify(
    Pointer<smb2_context> ctx,
    int status,
    Pointer<Void> data,
    Pointer<Void> id,
  ) {
    final list = data.cast<smb2_file_notify_change_information>();
    final w = _watchers[id.address];
    try {
      if (w == null || w.isClosed) return;
      if (status == _statusNotifyEnumDir) {
        w._events.add(Smb2ChangeEvent(Smb2ChangeAction.overflow, w._base));
      } else if (status != 0 || list == nullptr) {
        w._failure = _notifyError(ctx, status, w.path);
        return;
      } else {
        for (var p = list; p != nullptr; p = p.ref.next) {
          final name = p.ref.name;
          w._events.add(
            name == nullptr
                // An empty reply: the server dropped what it had.
                ? Smb2ChangeEvent(Smb2ChangeAction.overflow, w._base)
                : Smb2ChangeEvent(
                    Smb2ChangeAction.fromValue(p.ref.action),
                    changePath(w._base, _string(name)),
                  ),
          );
        }
      }
      try {
        _arm(w);
      } on Smb2Exception catch (e) {
        w._failure = e;
      }
    } finally {
      if (list != nullptr) free_smb2_file_notify_change_information(ctx, list);
    }
  }

  // ─── Native buffers (for the pool's workers) ──────────────────────────────

  /// Reads up to [length] bytes of [handle] at [offset] into a buffer from
  /// `malloc`, and returns its address and the bytes read. The caller owns
  /// the buffer (null when nothing was read) and frees it with `malloc`.
  ///
  /// The pool's workers send the address to the main isolate, which wraps
  /// it without copying.
  @internal
  (int, int) readNative(
    Smb2Handle handle, {
    int offset = 0,
    required int length,
  }) {
    final fh = _live(handle);
    _checkRange(offset, length, handle.path);
    if (length == 0) return (0, 0);
    final Pointer<Uint8> buf;
    try {
      buf = malloc<Uint8>(length);
      // package:ffi reports a failed allocation as an ArgumentError.
      // ignore: avoid_catching_errors
    } on ArgumentError {
      throw _invalid('Cannot allocate $length bytes for the read', handle.path);
    }
    try {
      // The count is a uint32 and the result an int: ask for at most one
      // MaxReadSize per call, which libsmb2 would cap the request at anyway.
      final max = smb2_get_max_read_size(_ctx);
      final chunk = max > 0 ? max : _readChunkFallback;
      var done = 0;
      while (done < length) {
        final want = length - done < chunk ? length - done : chunk;
        final n = smb2_pread(_ctx, fh, buf + done, want, offset + done);
        if (n < 0) throw _error(_ctx, 'Read failed', rc: n, path: handle.path);
        if (n == 0) break; // End of file.
        done += n;
      }
      if (done == 0) {
        malloc.free(buf);
        return (0, 0);
      }
      return (buf.address, done);
    } catch (_) {
      malloc.free(buf);
      rethrow;
    }
  }

  /// Writes [length] bytes from the native buffer at [address] to [handle]
  /// at [offset]. The buffer stays the caller's.
  @internal
  void writeNative(
    Smb2Handle handle,
    int address,
    int length, {
    int offset = 0,
  }) {
    final fh = _live(handle);
    _checkRange(offset, length, handle.path);
    final buf = Pointer<Uint8>.fromAddress(address);
    final max = smb2_get_max_write_size(_ctx);
    final chunk = max > 0 ? max : _writeChunkFallback;
    var done = 0;
    while (done < length) {
      final want = length - done < chunk ? length - done : chunk;
      final n = smb2_pwrite(_ctx, fh, buf + done, want, offset + done);
      if (n < 0) throw _error(_ctx, 'Write failed', rc: n, path: handle.path);
      if (n == 0) {
        throw Smb2Exception(
          'Write made no progress at ${offset + done}',
          type: Smb2ErrorType.io,
          path: handle.path,
        );
      }
      done += n;
    }
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  void _ensureConnected() {
    if (_ctx == nullptr) {
      throw const Smb2Exception(
        'Not connected: call connect() first',
        type: Smb2ErrorType.state,
      );
    }
  }

  Smb2Handle _open(String path, int flags) {
    _ensureConnected();
    final fh = using((arena) => smb2_open(_ctx, _path(path, arena), flags));
    if (fh == nullptr) throw _error(_ctx, 'Open failed', path: path);
    final handle = Smb2Handle._(this, fh, path);
    _handles.add(handle);
    return handle;
  }

  int _fstatSize(Smb2Handle handle) {
    final fh = _live(handle);
    return using((arena) {
      final out = arena<smb2_stat_64>();
      _check(smb2_fstat(_ctx, fh, out), 'Fstat failed', path: handle.path);
      return out.ref.smb2_size;
    });
  }

  /// The native handle of an open [handle] of this client.
  Pointer<smb2fh> _live(Smb2Handle handle) {
    _owned(handle);
    if (handle.isClosed) {
      throw Smb2Exception(
        'The handle is closed',
        type: Smb2ErrorType.state,
        path: handle.path,
      );
    }
    _ensureConnected();
    return handle._fh;
  }

  void _owned(Smb2Handle handle) {
    if (!identical(handle._client, this)) {
      throw Smb2Exception(
        'The handle belongs to another client',
        type: Smb2ErrorType.state,
        path: handle.path,
      );
    }
  }

  void _check(int rc, String what, {String? path}) {
    if (rc < 0) throw _error(_ctx, what, rc: rc, path: path);
  }
}

/// The listing of [path] by [client], with the file ids of its `.` and
/// `..` entries, 0 when the server lists none. Samba gives `..` the id of
/// the real parent, so a directory whose `..` is not the directory it was
/// listed in is a link the server follows.
@internal
(int, int, List<Smb2DirEntry>) listDirectoryIds(
  Smb2Client client,
  String path,
) => client._list(path);

typedef _NotifyCallback =
    Void Function(Pointer<smb2_context>, Int, Pointer<Void>, Pointer<Void>);

/// STATUS_NOTIFY_ENUM_DIR: more changes than the reply could hold.
const int _statusNotifyEnumDir = 0x0000010C;

/// A watch on a directory, from [Smb2Client.watch].
///
/// Pull its changes with [next], on the isolate of its client, and [close]
/// it when done. [Smb2Pool.watch] runs one in an isolate of its own and
/// delivers its changes as a stream.
///
/// {@category Synchronous client}
final class Smb2Watcher {
  final Smb2Client _client;
  final int _id;
  Pointer<smb2fh> _fh;
  final int _flags;
  final int _filter;
  final List<Smb2ChangeEvent> _events = [];
  Smb2Exception? _failure;

  /// The share-relative path of the watched directory.
  final String path;

  Smb2Watcher._(
    this._client,
    this._id,
    this._fh,
    this.path,
    this._flags,
    this._filter,
  );

  String get _base => changePath(path, '');

  /// Whether [close] was called, or the watch failed.
  bool get isClosed => _fh == nullptr;

  /// The changes reported since the last call, in the order the server
  /// sent them; when there are none yet, waits for the next ones.
  ///
  /// With a [timeout] it waits at most that long and returns an empty list
  /// when nothing changed; without one it waits until something does. The
  /// wait does not count against the client's request timeout. Even
  /// [Duration.zero] reads what the socket holds already.
  ///
  /// Throws the failure that ended the watch (the directory was removed,
  /// the connection was lost: [Smb2Exception.isNetworkFailure]) once the
  /// changes before it are returned; the watcher is closed then. Throws
  /// [Smb2ErrorType.state] once closed.
  List<Smb2ChangeEvent> next({Duration? timeout}) {
    final clock = Stopwatch()..start();
    var last = false;
    while (true) {
      if (_events.isNotEmpty) {
        final out = List<Smb2ChangeEvent>.of(_events);
        _events.clear();
        return out;
      }
      final error = _failure;
      if (error != null) {
        close();
        throw error;
      }
      if (isClosed) {
        throw Smb2Exception(
          'The watcher is closed',
          type: Smb2ErrorType.state,
          path: path,
        );
      }
      if (last) return const [];
      _client._ensureConnected();
      var wait = -1;
      if (timeout != null) {
        final left = timeout - clock.elapsed;
        // One more pass once the time is up, which does not wait.
        if (left <= Duration.zero) {
          wait = 0;
          last = true;
        } else {
          wait = left.inMilliseconds + (left.inMicroseconds % 1000 > 0 ? 1 : 0);
        }
      }
      final ctx = _client._ctx;
      final revents = pollSocket(
        smb2_get_fd(ctx),
        smb2_which_events(ctx),
        wait,
      );
      if (revents > 0 && smb2_service(ctx, revents) < 0) {
        final e = _error(ctx, 'Watch failed', path: path);
        _failure = e.isNetworkFailure
            ? e
            : Smb2Exception(
                e.message,
                type: Smb2ErrorType.connection,
                path: path,
              );
      }
    }
  }

  /// Stops the watch and closes the directory. Closing it again does
  /// nothing.
  void close() {
    if (isClosed) return;
    final fh = _fh;
    _fh = nullptr;
    _client._watchers.remove(_id);
    // The server ends the pending CHANGE_NOTIFY with NOTIFY_CLEANUP when
    // the directory closes; its callback finds no watcher and drops it.
    if (_client._ctx != nullptr) smb2_close(_client._ctx, fh);
  }
}

/// The exception for a CHANGE_NOTIFY that failed with the NT [status].
Smb2Exception _notifyError(Pointer<smb2_context> ctx, int status, String path) {
  final nt = status & 0xFFFFFFFF;
  final errno = nterror_to_errno(nt);
  final type = Smb2ErrorType.fromNtStatus(nt);
  return Smb2Exception(
    'Watch failed: ${_string(nterror_to_str(nt))}',
    type: type == Smb2ErrorType.unknown && nt == 0
        ? Smb2ErrorType.connection
        : type,
    ntStatus: nt == 0 ? null : nt,
    errno: errno > 0 ? errno : null,
    path: path,
  );
}

/// [timeout] in the whole seconds libsmb2 counts, rounded up so a short
/// timeout stays one; 0 for none.
int _seconds(Duration timeout) =>
    timeout > Duration.zero ? (timeout.inMilliseconds + 999) ~/ 1000 : 0;

// ─── Context setup ────────────────────────────────────────────────────────────

/// Why the libsmb2 this isolate loaded cannot serve the package, or `null`
/// when it is a build of [libsmb2Release]. Read once per isolate, before
/// its first context: the bindings hold the API of the pinned release only.
final Smb2Exception? _libsmb2Refusal = _checkLibsmb2();

Smb2Exception? _checkLibsmb2() {
  String? release;
  ArgumentError? cause;
  try {
    final p = smb2_scripts_release();
    if (p != nullptr) release = p.cast<Utf8>().toDartString();
    // @Native throws an ArgumentError when the symbol does not resolve: a
    // libsmb2 that is not a build of libsmb2-scripts, or one older than r11.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (e) {
    cause = e;
  }
  final why = libsmb2Mismatch(release);
  return why == null
      ? null
      : Smb2Exception(why, type: Smb2ErrorType.notSupported, cause: cause);
}

Pointer<smb2_context> _newContext({
  String? user,
  String? password,
  String? domain,
  required Duration timeout,
}) {
  if (_libsmb2Refusal case final refusal?) throw refusal;
  final ctx = smb2_init_context();
  if (ctx == nullptr) {
    throw const Smb2Exception('Cannot create an SMB2 context');
  }
  using((arena) {
    final hasUser = user != null && user.isNotEmpty;
    if (hasUser) {
      smb2_set_user(ctx, user.toNativeUtf8(allocator: arena).cast());
    }
    // libsmb2 logs on anonymously when it has no password, whatever the
    // user. An empty password is a real one for a named user: some servers
    // have accounts without a password and refuse an anonymous logon.
    // Without a user an empty password stays anonymous: a logon as user ""
    // is refused by servers, or mapped to guest.
    if (password != null && (password.isNotEmpty || hasUser)) {
      smb2_set_password(ctx, password.toNativeUtf8(allocator: arena).cast());
    }
    if (domain != null && domain.isNotEmpty) {
      smb2_set_domain(ctx, domain.toNativeUtf8(allocator: arena).cast());
    }
  });
  if (timeout > Duration.zero) smb2_set_timeout(ctx, _seconds(timeout));
  return ctx;
}

void _connectContext(
  Pointer<smb2_context> ctx, {
  required String host,
  required String share,
  String? user,
}) {
  using((arena) {
    final rc = smb2_connect_share(
      ctx,
      host.toNativeUtf8(allocator: arena).cast(),
      share.toNativeUtf8(allocator: arena).cast(),
      // Overrides libsmb2's default user, the local login name. Whether the
      // logon is anonymous depends on the password; see _newContext.
      (user ?? '').toNativeUtf8(allocator: arena).cast(),
    );
    if (rc < 0) {
      throw _error(ctx, 'Cannot connect to //$host/$share', rc: rc);
    }
  });
}

// ─── Errors ───────────────────────────────────────────────────────────────────

/// The exception for the failure libsmb2 just reported on [ctx]; see
/// [failureFacts].
Smb2Exception _error(
  Pointer<smb2_context> ctx,
  String what, {
  int? rc,
  String? path,
}) {
  final ptr = smb2_get_error(ctx);
  final facts = failureFacts(
    message: ptr == nullptr ? '' : _string(ptr).trim(),
    status: smb2_get_nterror(ctx) & 0xFFFFFFFF,
    rc: rc,
    errnoOf: nterror_to_errno,
    nameOf: (status) => _string(nterror_to_str(status)),
  );
  final message = facts.message;
  return Smb2Exception(
    message.isEmpty
        ? what
        : message.toLowerCase().startsWith(what.toLowerCase())
        ? message
        : '$what: $message',
    type: Smb2ErrorType.fromFailure(
      message: message,
      ntStatus: facts.ntStatus,
      errno: facts.errno,
    ),
    ntStatus: facts.ntStatus,
    errno: facts.errno,
    path: path,
  );
}

/// What a libsmb2 failure says about itself: its [message], the
/// context's NT [status], and [rc], the negative errno the call returned
/// when it returns one.
///
/// libsmb2 resets neither its message nor its status between calls, so
/// both may still describe an earlier failure. The status counts only when
/// it agrees with [rc], or, without an errno from the call, when the
/// message names it (quoted as `(0x........)` or by name): a pointer
/// result, or an [rc] of -1, which is both libsmb2's generic failure and
/// EPERM. A message that names a status [rc] disagrees with is stale and
/// is left out. A transport failure carries neither status nor errno.
///
/// [errnoOf] and [nameOf] are libsmb2's nterror_to_errno and
/// nterror_to_str.
@internal
({String message, int? ntStatus, int? errno}) failureFacts({
  required String message,
  required int status,
  int? rc,
  required int Function(int status) errnoOf,
  required String Function(int status) nameOf,
}) {
  if (Smb2ErrorType.fromMessage(message) != Smb2ErrorType.unknown) {
    return (message: message, ntStatus: null, errno: null);
  }
  final quoted = Smb2ErrorType.ntStatusInMessage(message);
  final named = status != 0 && _names(message, nameOf(status));
  final rcErrno = rc != null && rc < -1 ? -rc : null;
  if (rcErrno != null) {
    final cited = quoted ?? (named ? status : null);
    if (cited != null) {
      return errnoOf(cited) == rcErrno
          ? (message: message, ntStatus: cited, errno: rcErrno)
          : (message: '', ntStatus: null, errno: rcErrno);
    }
    final agrees = status != 0 && errnoOf(status) == rcErrno;
    return (message: message, ntStatus: agrees ? status : null, errno: rcErrno);
  }
  final current = quoted != null ? quoted == status : named;
  if (!current) return (message: message, ntStatus: null, errno: null);
  final derived = errnoOf(status);
  return (
    message: message,
    ntStatus: status,
    errno: derived > 0 ? derived : null,
  );
}

/// Whether [message] names the status called [name] by nterror_to_str.
bool _names(String message, String name) =>
    name.contains('STATUS_') &&
    RegExp(
      '(^|[^A-Z0-9_])${RegExp.escape(name)}(\$|[^A-Z0-9_])',
    ).hasMatch(message);

Smb2Exception _invalid(String message, String? path) =>
    Smb2Exception(message, type: Smb2ErrorType.invalidParam, path: path);

void _checkRange(int offset, int length, String path) {
  if (offset < 0) throw _invalid('offset must not be negative', path);
  if (length < 0) throw _invalid('length must not be negative', path);
}

// ─── Paths, strings and stats ─────────────────────────────────────────────────

/// [path] as a C string in [arena]. Leading slashes are dropped (paths are
/// relative to the share), backslashes become slashes, and an embedded NUL,
/// which would cut the path short on the wire, is rejected.
Pointer<Char> _path(String path, Arena arena) {
  if (path.contains('\u0000')) throw _invalid('The path contains NUL', path);
  var normalized = path;
  if (normalized.contains(r'\')) normalized = normalized.replaceAll(r'\', '/');
  if (normalized.startsWith('/')) {
    normalized = normalized.replaceFirst(_leadingSlashes, '');
  }
  return normalized.toNativeUtf8(allocator: arena).cast();
}

final _leadingSlashes = RegExp('^/+');

String _string(Pointer<Char> p) =>
    p == nullptr ? '' : p.cast<Utf8>().toDartString();

DateTime _time(int seconds, int nanoseconds) =>
    DateTime.fromMicrosecondsSinceEpoch(
      seconds * 1000000 + nanoseconds ~/ 1000,
      isUtc: true,
    );

Smb2Stat _stat(smb2_stat_64 st) => Smb2Stat(
  type: switch (st.smb2_type) {
    SMB2_TYPE_DIRECTORY => Smb2FileType.directory,
    SMB2_TYPE_LINK => Smb2FileType.link,
    _ => Smb2FileType.file,
  },
  size: st.smb2_size,
  modified: _time(st.smb2_mtime, st.smb2_mtime_nsec),
  created: _time(st.smb2_btime, st.smb2_btime_nsec),
  accessed: _time(st.smb2_atime, st.smb2_atime_nsec),
  changed: _time(st.smb2_ctime, st.smb2_ctime_nsec),
  attributes: st.smb2_attributes,
  fileId: st.smb2_ino,
);

// ─── Open flags ───────────────────────────────────────────────────────────────

/// POSIX open flags as smb2_open() reads them: libsmb2 tests them against
/// the `<fcntl.h>` of the platform the binary was built for, so the values
/// are per platform. O_RDONLY / O_WRONLY / O_RDWR are 0 / 1 / 2 on all.
final class _OpenFlags {
  final int rdonly = 0;
  final int wronly = 1;
  final int creat;
  final int trunc;

  /// O_DIRECTORY, which makes smb2_open() ask for a directory.
  final int directory;

  const _OpenFlags({
    required this.creat,
    required this.trunc,
    required this.directory,
  });

  /// glibc and bionic on x86 and x86_64.
  static const _linux = _OpenFlags(
    creat: 0x40,
    trunc: 0x200,
    directory: 0x10000,
  );

  /// glibc and bionic on ARM, whose O_DIRECTORY differs.
  static const _linuxArm = _OpenFlags(
    creat: 0x40,
    trunc: 0x200,
    directory: 0x4000,
  );

  /// Apple's libc.
  static const _darwin = _OpenFlags(
    creat: 0x200,
    trunc: 0x400,
    directory: 0x100000,
  );

  /// The Windows UCRT, with the O_DIRECTORY libsmb2-scripts' config.h
  /// defines for it.
  static const _windows = _OpenFlags(
    creat: 0x100,
    trunc: 0x200,
    directory: 0x200000,
  );

  static _OpenFlags _resolve() {
    if (Platform.isLinux || Platform.isAndroid) {
      return switch (Abi.current()) {
        Abi.linuxArm ||
        Abi.linuxArm64 ||
        Abi.androidArm ||
        Abi.androidArm64 => _linuxArm,
        _ => _linux,
      };
    }
    if (Platform.isMacOS || Platform.isIOS) return _darwin;
    if (Platform.isWindows) return _windows;
    throw UnsupportedError(
      'dart_smb2: unsupported platform ${Platform.operatingSystem}',
    );
  }
}

final _OpenFlags _flags = _OpenFlags._resolve();

/// Longest symlink target read; Linux's PATH_MAX.
const int _readlinkBufferSize = 4096;

/// Read size when the server reports no MaxReadSize.
const int _readChunkFallback = 1024 * 1024;

/// Write size when the server reports no MaxWriteSize.
const int _writeChunkFallback = 1024 * 1024;
