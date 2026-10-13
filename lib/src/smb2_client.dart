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
final class Smb2Handle {
  final Smb2Client _client;
  Pointer<smb2fh> _fh;

  /// The share-relative path the handle was opened for.
  final String path;

  Smb2Handle._(this._client, this._fh, this.path);

  /// Whether the handle has been closed.
  bool get isClosed => _fh == nullptr;

  /// Whether the handle is still open.
  @Deprecated('Use !isClosed. Will be removed in 0.3.0.')
  bool get isValid => !isClosed;
}

/// SMB2/3 client on libsmb2's synchronous API.
///
/// Every call blocks until the server answers, so run the client inside an
/// isolate of your own — or use [Smb2Pool], which runs clients in worker
/// isolates and is the recommended entry point.
///
/// ```dart
/// final client = Smb2Client()
///   ..connect(host: '192.168.1.10', share: 'Music', user: 'guest');
/// try {
///   final entries = client.listDirectory('');
/// } finally {
///   client.disconnect();
/// }
/// ```
final class Smb2Client implements Finalizable {
  Pointer<smb2_context> _ctx = nullptr;
  final Set<Smb2Handle> _handles = {};

  /// Frees the context of a client dropped without [disconnect]. No logoff
  /// is sent, so the server keeps the session until it times out.
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<smb2_context>)>>(
      smb2_destroy_context,
    ).cast(),
  );

  /// Creates a client that is not connected yet.
  Smb2Client();

  /// Same as [Smb2Client.new].
  @Deprecated('Use Smb2Client(). Will be removed in 0.3.0.')
  factory Smb2Client.open() => Smb2Client();

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
  /// that it closes before returning. Needs no connected client.
  static List<Smb2ShareInfo> listShares({
    required String host,
    String? user,
    String? password,
    String? domain,
    Duration timeout = const Duration(seconds: 30),
    @Deprecated('Use timeout. Will be removed in 0.3.0.') int? timeoutSeconds,
  }) {
    final ctx = _newContext(
      user: user,
      password: password,
      domain: domain,
      timeout: timeoutSeconds != null
          ? Duration(seconds: timeoutSeconds)
          : timeout,
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
  /// Throws [Smb2Exception] on failure.
  void connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    Duration timeout = const Duration(seconds: 30),
    @Deprecated('Use timeout. Will be removed in 0.3.0.') int? timeoutSeconds,
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
  }) {
    if (isConnected) disconnect();
    final ctx = _newContext(
      user: user,
      password: password,
      domain: domain,
      timeout: timeoutSeconds != null
          ? Duration(seconds: timeoutSeconds)
          : timeout,
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
    _finalizer.attach(this, ctx.cast(), detach: this);
  }

  /// Closes every open handle, logs off and frees the connection. Does
  /// nothing when not connected.
  void disconnect() {
    if (_ctx == nullptr) return;
    for (final h in _handles) {
      smb2_close(_ctx, h._fh);
      h._fh = nullptr;
    }
    _handles.clear();
    _finalizer.detach(this);
    smb2_disconnect_share(_ctx);
    smb2_destroy_context(_ctx);
    _ctx = nullptr;
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
  List<Smb2DirEntry> listDirectory(String path) {
    _ensureConnected();
    final dir = using((arena) {
      final d = smb2_opendir(_ctx, _path(path, arena));
      if (d == nullptr) throw _error(_ctx, 'Cannot list directory', path: path);
      return d;
    });
    try {
      final results = <Smb2DirEntry>[];
      for (
        var ent = smb2_readdir(_ctx, dir);
        ent != nullptr;
        ent = smb2_readdir(_ctx, dir)
      ) {
        // The entry is recycled by the next readdir: copy it now.
        final name = _string(ent.ref.name);
        if (name == '.' || name == '..') continue;
        results.add(Smb2DirEntry(name: name, stat: _stat(ent.ref.st)));
      }
      return results;
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

  /// Deletes the file [path].
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
  void rename(String oldPath, String newPath) {
    _ensureConnected();
    using((arena) {
      _check(
        smb2_rename(_ctx, _path(oldPath, arena), _path(newPath, arena)),
        'Rename failed',
        path: oldPath,
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

  /// Same as [openFile].
  @Deprecated('Use openFile. Will be removed in 0.3.0.')
  Smb2Handle openFileHandle(String path) => openFile(path);

  /// Same as [openFileWrite].
  @Deprecated('Use openFileWrite. Will be removed in 0.3.0.')
  Smb2Handle openFileHandleWrite(String path) => openFileWrite(path);

  /// Same as [readFromHandle].
  @Deprecated('Use readFromHandle. Will be removed in 0.3.0.')
  Uint8List readHandle(
    Smb2Handle handle, {
    int offset = 0,
    required int length,
  }) => readFromHandle(handle, offset: offset, length: length);

  /// Same as [writeToHandle].
  @Deprecated('Use writeToHandle. Will be removed in 0.3.0.')
  void writeHandle(Smb2Handle handle, Uint8List data, {int offset = 0}) =>
      writeToHandle(handle, data, offset: offset);

  /// Same as [fsyncHandle].
  @Deprecated('Use fsyncHandle. Will be removed in 0.3.0.')
  void fsync(Smb2Handle handle) => fsyncHandle(handle);

  /// Same as [ftruncateHandle].
  @Deprecated('Use ftruncateHandle. Will be removed in 0.3.0.')
  void ftruncate(Smb2Handle handle, int length) =>
      ftruncateHandle(handle, length);

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
    final buf = malloc<Uint8>(length);
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

// ─── Context setup ────────────────────────────────────────────────────────────

Pointer<smb2_context> _newContext({
  String? user,
  String? password,
  String? domain,
  required Duration timeout,
}) {
  final ctx = smb2_init_context();
  if (ctx == nullptr) {
    throw const Smb2Exception('Cannot create an SMB2 context');
  }
  using((arena) {
    if (user != null && user.isNotEmpty) {
      smb2_set_user(ctx, user.toNativeUtf8(allocator: arena).cast());
    }
    if (password != null && password.isNotEmpty) {
      smb2_set_password(ctx, password.toNativeUtf8(allocator: arena).cast());
    }
    if (domain != null && domain.isNotEmpty) {
      smb2_set_domain(ctx, domain.toNativeUtf8(allocator: arena).cast());
    }
  });
  if (timeout > Duration.zero) {
    // libsmb2 counts whole seconds; round up so a short timeout stays one.
    smb2_set_timeout(ctx, (timeout.inMilliseconds + 999) ~/ 1000);
  }
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
      // libsmb2 treats an empty user as guest.
      (user ?? '').toNativeUtf8(allocator: arena).cast(),
    );
    if (rc < 0) {
      final e = _error(ctx, 'Cannot connect to //$host/$share', rc: rc);
      // A server that maps unknown users to guest refuses them at the tree
      // connect with ACCESS_DENIED: for the caller, the credentials failed.
      if (e.type != Smb2ErrorType.accessDenied) throw e;
      throw Smb2Exception(
        e.message,
        type: Smb2ErrorType.auth,
        ntStatus: e.ntStatus,
        errno: e.errno,
      );
    }
  });
}

// ─── Errors ───────────────────────────────────────────────────────────────────

/// The exception for the failure libsmb2 just reported on [ctx].
///
/// [rc] is the negative errno the call returned, when it returns one.
/// libsmb2 resets neither its message nor its NT status between calls, so
/// both may still describe an earlier failure:
/// - a status counts only when it agrees with [rc], or, for the calls that
///   return a pointer and no errno, when the message quotes it;
/// - a message that quotes a status [rc] disagrees with is stale, and is
///   left out.
///
/// An [rc] of -1 is libsmb2's generic failure (a poll or a reply that broke
/// the session) as well as EPERM: it counts as an errno only through a
/// status the message quotes.
Smb2Exception _error(
  Pointer<smb2_context> ctx,
  String what, {
  int? rc,
  String? path,
}) {
  final ptr = smb2_get_error(ctx);
  var message = ptr == nullptr ? '' : _string(ptr).trim();
  final status = smb2_get_nterror(ctx) & 0xFFFFFFFF;
  final rcErrno = rc != null && rc < -1 ? -rc : null;
  final quoted = Smb2ErrorType.ntStatusInMessage(message);
  final transport = Smb2ErrorType.fromMessage(message) != Smb2ErrorType.unknown;
  int? ntStatus;
  int? errno = rcErrno;
  if (!transport) {
    if (rcErrno != null) {
      if (quoted != null) {
        if (nterror_to_errno(quoted) == rcErrno) {
          ntStatus = quoted;
        } else {
          message = '';
        }
      } else if (status != 0 && nterror_to_errno(status) == rcErrno) {
        ntStatus = status;
      }
    } else if (quoted != null && quoted == status) {
      // No errno from the call: a pointer result, or rc -1, which is both
      // libsmb2's generic failure and EPERM. The quoted, current status
      // tells them apart.
      ntStatus = status;
      final derived = nterror_to_errno(status);
      if (derived > 0) errno = derived;
    } else if (rc == -1 &&
        quoted == null &&
        status != 0 &&
        nterror_to_errno(status) == 1) {
      // An unquoted status that libsmb2 maps to EPERM, which rc -1 is.
      ntStatus = status;
      errno = 1;
    }
  }
  return Smb2Exception(
    message.isEmpty
        ? what
        : message.toLowerCase().startsWith(what.toLowerCase())
        ? message
        : '$what: $message',
    type: Smb2ErrorType.fromFailure(
      message: message,
      ntStatus: ntStatus,
      errno: errno,
    ),
    ntStatus: ntStatus,
    errno: errno,
    path: path,
  );
}

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

  const _OpenFlags({required this.creat, required this.trunc});

  /// glibc and bionic.
  static const _linux = _OpenFlags(creat: 0x40, trunc: 0x200);

  /// Apple's libc.
  static const _darwin = _OpenFlags(creat: 0x200, trunc: 0x400);

  /// The Windows UCRT.
  static const _windows = _OpenFlags(creat: 0x100, trunc: 0x200);

  static _OpenFlags _resolve() {
    if (Platform.isLinux || Platform.isAndroid) return _linux;
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
