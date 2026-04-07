// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'smb2_error_type.dart';
import 'smb2_exceptions.dart';
import 'smb2_types.dart';

typedef _GetErrnoC = Int32 Function(Pointer ctx);
typedef _GetErrnoDart = int Function(Pointer ctx);

// ─── Native function signatures ─────────────────────────────────────────────

typedef _ConnectC = Pointer Function(
  Pointer<Utf8> host, Pointer<Utf8> share, Pointer<Utf8> user,
  Pointer<Utf8> password, Pointer<Utf8> domain, Int32 timeout,
);
typedef _ConnectDart = Pointer Function(
  Pointer<Utf8> host, Pointer<Utf8> share, Pointer<Utf8> user,
  Pointer<Utf8> password, Pointer<Utf8> domain, int timeout,
);

typedef _VoidPtrC = Void Function(Pointer ctx);
typedef _VoidPtrDart = void Function(Pointer ctx);

typedef _ErrorC = Pointer<Utf8> Function(Pointer ctx);
typedef _ErrorDart = Pointer<Utf8> Function(Pointer ctx);

typedef _LastErrorC = Pointer<Utf8> Function();
typedef _LastErrorDart = Pointer<Utf8> Function();

typedef _ListdirC = Pointer Function(Pointer ctx, Pointer<Utf8> path);
typedef _ListdirDart = Pointer Function(Pointer ctx, Pointer<Utf8> path);

typedef _PreadC = Int32 Function(
  Pointer ctx, Pointer<Utf8> path, Pointer<Uint8> buf,
  Uint32 length, Uint64 offset,
);
typedef _PreadDart = int Function(
  Pointer ctx, Pointer<Utf8> path, Pointer<Uint8> buf,
  int length, int offset,
);

typedef _ReadFileC = Pointer<Uint8> Function(
  Pointer ctx, Pointer<Utf8> path, Pointer<Int64> outSize,
);
typedef _ReadFileDart = Pointer<Uint8> Function(
  Pointer ctx, Pointer<Utf8> path, Pointer<Int64> outSize,
);

typedef _StatC = Int32 Function(
  Pointer ctx, Pointer<Utf8> path,
  Pointer<Uint32> outType, Pointer<Uint64> outSize,
  Pointer<Uint64> outMtime, Pointer<Uint64> outBtime,
);
typedef _StatDart = int Function(
  Pointer ctx, Pointer<Utf8> path,
  Pointer<Uint32> outType, Pointer<Uint64> outSize,
  Pointer<Uint64> outMtime, Pointer<Uint64> outBtime,
);

typedef _FilesizeC = Int64 Function(Pointer ctx, Pointer<Utf8> path);
typedef _FilesizeDart = int Function(Pointer ctx, Pointer<Utf8> path);

// ─── File handle functions ──────────────────────────────────────────────────

typedef _OpenFileC = Pointer Function(Pointer ctx, Pointer<Utf8> path);
typedef _OpenFileDart = Pointer Function(Pointer ctx, Pointer<Utf8> path);

typedef _OpenFileWithSizeC = Pointer Function(
  Pointer ctx, Pointer<Utf8> path, Pointer<Int64> outSize,
);
typedef _OpenFileWithSizeDart = Pointer Function(
  Pointer ctx, Pointer<Utf8> path, Pointer<Int64> outSize,
);

typedef _PreadHandleC = Int32 Function(
  Pointer ctx, Pointer fh, Pointer<Uint8> buf,
  Uint32 length, Uint64 offset,
);
typedef _PreadHandleDart = int Function(
  Pointer ctx, Pointer fh, Pointer<Uint8> buf,
  int length, int offset,
);

typedef _CloseFileC = Void Function(Pointer ctx, Pointer fh);
typedef _CloseFileDart = void Function(Pointer ctx, Pointer fh);

typedef _ListSharesC = Pointer Function(
  Pointer<Utf8> host, Pointer<Utf8> user, Pointer<Utf8> password,
  Pointer<Utf8> domain, Int32 timeout,
);
typedef _ListSharesDart = Pointer Function(
  Pointer<Utf8> host, Pointer<Utf8> user, Pointer<Utf8> password,
  Pointer<Utf8> domain, int timeout,
);

typedef _SharelistFreeC = Void Function(Pointer list);
typedef _SharelistFreeDart = void Function(Pointer list);

// ─── Entry struct layout ────────────────────────────────────────────────────
// smb2w_entry: char[256] + uint32 type + pad(4) + uint64 size/mtime/btime
const _entrySize = 288;
const _entryTypeOffset = 256;
const _entrySizeOffset = 264;
const _entryMtimeOffset = 272;
const _entryBtimeOffset = 280;

// smb2w_share_entry: char[256] + uint32 type = 260 bytes
const _shareEntrySize = 260;
const _shareEntryTypeOffset = 256;

/// Wrap a native [malloc]'d buffer into a Dart [Uint8List] **without copying**.
///
/// The returned list owns the native memory — it will be freed automatically
/// when the Dart object is garbage-collected via [NativeFinalizer].
Uint8List _ownedTypedList(Pointer<Uint8> buf, int length) {
  return buf.asTypedList(length, finalizer: malloc.nativeFree);
}

/// SMB2/3 client powered by libsmb2 via a C wrapper and Dart FFI.
///
/// All operations are **synchronous** — run this client inside a
/// [Dart Isolate](https://api.dart.dev/stable/dart-isolate/Isolate-class.html)
/// to keep the UI responsive.
///
/// ```dart
/// final client = Smb2Client.open('/path/to/libsmb2.dylib');
/// client.connect(host: '192.168.1.1', share: 'Music', user: 'guest');
/// final entries = client.listDirectory('');
/// client.disconnect();
/// ```
class Smb2Client implements Finalizable {
  final DynamicLibrary _lib;
  Pointer _ctx = nullptr;
  late final NativeFinalizer _finalizer;

  late final _ConnectDart _connect;
  late final _VoidPtrDart _disconnect;
  late final _GetErrnoDart _getErrno;
  late final _ErrorDart _error;
  late final _LastErrorDart _lastError;
  late final _ListdirDart _listdir;
  late final _VoidPtrDart _dirlistFree;
  late final _VoidPtrDart _free;
  late final _PreadDart _pread;
  late final _ReadFileDart _readFile;
  late final _StatDart _stat;
  late final _FilesizeDart _filesize;
  late final _OpenFileDart _openFile;
  late final _OpenFileWithSizeDart _openFileWithSize;
  late final _PreadHandleDart _preadHandle;
  late final _CloseFileDart _closeFile;
  late final _ListSharesDart _listShares;
  late final _SharelistFreeDart _sharelistFree;

  Smb2Client._(this._lib) {
    _connect = _lib.lookupFunction<_ConnectC, _ConnectDart>('smb2w_connect');
    _disconnect = _lib.lookupFunction<_VoidPtrC, _VoidPtrDart>('smb2w_disconnect');
    _getErrno = _lib.lookupFunction<_GetErrnoC, _GetErrnoDart>('smb2w_get_errno');
    _finalizer = NativeFinalizer(
      _lib.lookup<NativeFunction<_VoidPtrC>>('smb2w_disconnect'),
    );
    _error = _lib.lookupFunction<_ErrorC, _ErrorDart>('smb2w_error');
    _lastError = _lib.lookupFunction<_LastErrorC, _LastErrorDart>('smb2w_get_last_error');
    _listdir = _lib.lookupFunction<_ListdirC, _ListdirDart>('smb2w_listdir');
    _dirlistFree = _lib.lookupFunction<_VoidPtrC, _VoidPtrDart>('smb2w_dirlist_free');
    _free = _lib.lookupFunction<_VoidPtrC, _VoidPtrDart>('smb2w_free');
    _pread = _lib.lookupFunction<_PreadC, _PreadDart>('smb2w_pread');
    _readFile = _lib.lookupFunction<_ReadFileC, _ReadFileDart>('smb2w_read_file');
    _stat = _lib.lookupFunction<_StatC, _StatDart>('smb2w_stat');
    _filesize = _lib.lookupFunction<_FilesizeC, _FilesizeDart>('smb2w_filesize');
    _openFile = _lib.lookupFunction<_OpenFileC, _OpenFileDart>('smb2w_open_file');
    _openFileWithSize = _lib.lookupFunction<_OpenFileWithSizeC, _OpenFileWithSizeDart>('smb2w_open_file_with_size');
    _preadHandle = _lib.lookupFunction<_PreadHandleC, _PreadHandleDart>('smb2w_pread_handle');
    _closeFile = _lib.lookupFunction<_CloseFileC, _CloseFileDart>('smb2w_close_file');
    _listShares = _lib.lookupFunction<_ListSharesC, _ListSharesDart>('smb2w_list_shares');
    _sharelistFree = _lib.lookupFunction<_SharelistFreeC, _SharelistFreeDart>('smb2w_sharelist_free');
  }

  /// Create a client, loading the native library automatically.
  ///
  /// The library is resolved using Flutter's FFI plugin mechanism.
  /// You can also pass a custom [path] to load from a specific location.
  factory Smb2Client.open([String? path]) {
    final lib = path != null
        ? DynamicLibrary.open(path)
        : _openDefault();
    return Smb2Client._(lib);
  }

  /// Create a client from an already-loaded [DynamicLibrary].
  factory Smb2Client(DynamicLibrary lib) => Smb2Client._(lib);

  static DynamicLibrary _openDefault() {
    if (Platform.isMacOS) {
      // Resolve the dylib relative to the host app bundle:
      // .../App.app/Contents/MacOS/ → .../App.app/Contents/Frameworks/dart_smb2.framework/Versions/A/
      final exe = Platform.resolvedExecutable;
      final macOS = exe.substring(0, exe.lastIndexOf('/'));
      final dylib = '$macOS/../Frameworks/dart_smb2.framework/Versions/A/libsmb2.dylib';
      return DynamicLibrary.open(dylib);
    } else if (Platform.isIOS) {
      return DynamicLibrary.process();
    } else if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libsmb2.so');
    } else if (Platform.isWindows) {
      return DynamicLibrary.open('libsmb2.dll');
    }
    throw const Smb2Exception('Unsupported platform');
  }

  /// Whether this client is connected to a share.
  bool get isConnected => _ctx != nullptr;

  // ─── Share enumeration ───────────────────────────────────────────────────

  /// List available shares on a server.
  ///
  /// This does **not** require an existing connection — it connects to `IPC$`
  /// internally, enumerates shares, and disconnects.
  ///
  /// Returns a list of [Smb2ShareInfo] with name and type.
  List<Smb2ShareInfo> listShares({
    required String host,
    String? user,
    String? password,
    String? domain,
    int timeoutSeconds = 30,
  }) {
    final pHost = host.toNativeUtf8();
    final pUser = (user ?? '').toNativeUtf8();
    final pPass = (password ?? '').toNativeUtf8();
    final pDomain = (domain ?? '').toNativeUtf8();

    final sharelist = _listShares(pHost, pUser, pPass, pDomain, timeoutSeconds);

    calloc.free(pHost);
    calloc.free(pUser);
    calloc.free(pPass);
    calloc.free(pDomain);

    if (sharelist == nullptr) {
      throw _makeLastError('Failed to list shares');
    }

    try {
      final entriesPtr = sharelist.cast<Pointer>().value;
      final count = Pointer<Int32>.fromAddress(sharelist.address + 8).value;

      final results = <Smb2ShareInfo>[];
      for (var i = 0; i < count; i++) {
        final addr = entriesPtr.address + i * _shareEntrySize;
        final name = Pointer<Utf8>.fromAddress(addr).toDartString();
        final type = Pointer<Uint32>.fromAddress(addr + _shareEntryTypeOffset).value;
        results.add(Smb2ShareInfo(name: name, type: type));
      }
      return results;
    } finally {
      _sharelistFree(sharelist);
    }
  }

  // ─── Connection ─────────────────────────────────────────────────────────

  /// Connect to an SMB share.
  ///
  /// Paths in subsequent calls are **relative to the share root**.
  /// Use `''` (empty string) to refer to the share root — not `/`.
  ///
  /// Throws [Smb2Exception] on failure.
  void connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    int timeoutSeconds = 30,
  }) {
    if (isConnected) disconnect();

    final pHost = host.toNativeUtf8();
    final pShare = share.toNativeUtf8();
    final pUser = (user ?? '').toNativeUtf8();
    final pPass = (password ?? '').toNativeUtf8();
    final pDomain = (domain ?? '').toNativeUtf8();

    _ctx = _connect(pHost, pShare, pUser, pPass, pDomain, timeoutSeconds);

    calloc.free(pHost);
    calloc.free(pShare);
    calloc.free(pUser);
    calloc.free(pPass);
    calloc.free(pDomain);

    if (_ctx == nullptr) {
      throw Smb2Exception(_lastError().toDartString());
    }
    _finalizer.attach(this, _ctx.cast(), detach: this);
  }

  /// Disconnect from the share and release all resources.
  void disconnect() {
    if (_ctx == nullptr) return;
    _finalizer.detach(this);
    _disconnect(_ctx);
    _ctx = nullptr;
  }

  // ─── Directory listing ──────────────────────────────────────────────────

  /// List all entries in a directory.
  ///
  /// [path] is relative to the share root. Use `''` for the root directory.
  /// Returns entries with name, type, size, and timestamps — no additional
  /// per-entry round-trips required.
  ///
  /// Throws [Smb2Exception] if the directory cannot be opened.
  List<Smb2DirEntry> listDirectory(String path) {
    _ensureConnected();

    final pPath = path.toNativeUtf8();
    final dirlist = _listdir(_ctx, pPath);
    calloc.free(pPath);

    if (dirlist == nullptr) {
      throw _makeError('Failed to list directory');
    }

    try {
      final entriesPtr = dirlist.cast<Pointer>().value;
      final count = Pointer<Int32>.fromAddress(dirlist.address + 8).value;

      final results = <Smb2DirEntry>[];
      for (var i = 0; i < count; i++) {
        final addr = entriesPtr.address + i * _entrySize;
        final name = Pointer<Utf8>.fromAddress(addr).toDartString();
        final type = Pointer<Uint32>.fromAddress(addr + _entryTypeOffset).value;
        final size = Pointer<Uint64>.fromAddress(addr + _entrySizeOffset).value;
        final mtime = Pointer<Uint64>.fromAddress(addr + _entryMtimeOffset).value;
        final btime = Pointer<Uint64>.fromAddress(addr + _entryBtimeOffset).value;

        results.add(Smb2DirEntry(
          name: name,
          stat: Smb2Stat(
            type: _parseType(type),
            size: size,
            modified: DateTime.fromMillisecondsSinceEpoch(mtime * 1000),
            created: DateTime.fromMillisecondsSinceEpoch(btime * 1000),
          ),
        ));
      }
      return results;
    } finally {
      _dirlistFree(dirlist);
    }
  }

  // ─── File reading ───────────────────────────────────────────────────────

  /// Read [length] bytes from a file at [offset].
  ///
  /// Ideal for reading partial content without downloading the entire file.
  ///
  /// Throws [Smb2Exception] on read failure.
  Uint8List readFileRange(String path, {int offset = 0, required int length}) {
    _ensureConnected();

    final pPath = path.toNativeUtf8();
    final buf = malloc<Uint8>(length);

    final n = _pread(_ctx, pPath, buf, length, offset);

    calloc.free(pPath);

    if (n < 0) {
      malloc.free(buf);
      throw _makeError('Read failed');
    }

    // Zero-copy: Dart GC owns the native buffer via NativeFinalizer.
    return _ownedTypedList(buf, n);
  }

  /// Read an entire file into memory.
  ///
  /// Loads the entire file into a [Uint8List]. For large files prefer
  /// [readFileRange] to read only the bytes you need.
  ///
  /// Throws [Smb2Exception] on failure.
  Uint8List readFile(String path) {
    _ensureConnected();

    final pPath = path.toNativeUtf8();
    final pSize = calloc<Int64>();

    final buf = _readFile(_ctx, pPath, pSize);
    calloc.free(pPath);

    if (buf == nullptr) {
      calloc.free(pSize);
      throw _makeError('Read file failed');
    }

    final size = pSize.value;
    calloc.free(pSize);

    // The buffer was malloc'd by the C wrapper (msvcrt on Windows).
    // Do NOT transfer ownership to Dart GC using malloc.nativeFree!
    // Instead, copy to a Dart Uint8List and free the native buffer immediately.
    try {
      final dartList = Uint8List(size);
      dartList.setAll(0, buf.asTypedList(size));
      return dartList;
    } finally {
      _free(buf);
    }
  }

  // ─── File info ──────────────────────────────────────────────────────────

  /// Get file or directory metadata without opening the file.
  ///
  /// Uses an SMB2 compound request internally (Create + QueryInfo + Close)
  /// so it completes in a single network round-trip.
  ///
  /// Throws [Smb2Exception] on failure.
  Smb2Stat stat(String path) {
    _ensureConnected();

    final pPath = path.toNativeUtf8();
    final pType = calloc<Uint32>();
    final pSize = calloc<Uint64>();
    final pMtime = calloc<Uint64>();
    final pBtime = calloc<Uint64>();

    final rc = _stat(_ctx, pPath, pType, pSize, pMtime, pBtime);

    calloc.free(pPath);

    if (rc < 0) {
      calloc.free(pType); calloc.free(pSize);
      calloc.free(pMtime); calloc.free(pBtime);
      throw _makeError('Stat failed');
    }

    final result = Smb2Stat(
      type: _parseType(pType.value),
      size: pSize.value,
      modified: DateTime.fromMillisecondsSinceEpoch(pMtime.value * 1000),
      created: DateTime.fromMillisecondsSinceEpoch(pBtime.value * 1000),
    );

    calloc.free(pType); calloc.free(pSize);
    calloc.free(pMtime); calloc.free(pBtime);
    return result;
  }

  /// Get the size of a file in bytes without opening it.
  ///
  /// Returns -1 if the file does not exist or an error occurs.
  int fileSize(String path) {
    _ensureConnected();

    final pPath = path.toNativeUtf8();
    final size = _filesize(_ctx, pPath);
    calloc.free(pPath);
    return size;
  }

  // ─── File handles (open once, read many, close once) ─────────────────

  /// Open a file for reading and return a reusable handle.
  ///
  /// Use [readHandle] to read from the handle, then [closeHandle] when done.
  /// This avoids repeated open/close network round-trips when reading
  /// multiple ranges from the same file.
  ///
  /// Throws [Smb2Exception] if the file cannot be opened.
  Pointer openFileHandle(String path) {
    _ensureConnected();
    final pPath = path.toNativeUtf8();
    final fh = _openFile(_ctx, pPath);
    calloc.free(pPath);
    if (fh == nullptr) {
      throw _makeError('Open failed');
    }
    return fh;
  }

  /// Open a file and get its size in one call.
  ///
  /// Saves a round-trip compared to calling [fileSize] + [openFileHandle]
  /// separately. Returns `(handle, fileSize)`.
  ///
  /// Throws [Smb2Exception] on failure.
  (Pointer handle, int size) openFileWithSize(String path) {
    _ensureConnected();
    final pPath = path.toNativeUtf8();
    final pSize = calloc<Int64>();
    final fh = _openFileWithSize(_ctx, pPath, pSize);
    calloc.free(pPath);
    final size = pSize.value;
    calloc.free(pSize);
    if (fh == nullptr) {
      throw _makeError('Open failed');
    }
    return (fh, size);
  }

  /// Read [length] bytes at [offset] from an open file handle.
  ///
  /// The handle must have been obtained from [openFileHandle] or [openFileWithSize].
  Uint8List readHandle(Pointer handle, {int offset = 0, required int length}) {
    _ensureConnected();
    final buf = malloc<Uint8>(length);
    final n = _preadHandle(_ctx, handle, buf, length, offset);
    if (n < 0) {
      malloc.free(buf);
      throw _makeError('Handle read failed');
    }
    return _ownedTypedList(buf, n);
  }

  /// Close a file handle opened with [openFileHandle] or [openFileWithSize].
  void closeHandle(Pointer handle) {
    if (_ctx == nullptr || handle == nullptr) return;
    _closeFile(_ctx, handle);
  }

  // ─── Streaming ──────────────────────────────────────────────────────

  /// Read a file in chunks without loading everything into RAM.
  ///
  /// Yields [Uint8List] chunks of up to [chunkSize] bytes.
  /// Uses a file handle internally — opens once, reads sequentially, closes.
  Iterable<Uint8List> readFileChunked(
    String path, {
    int chunkSize = 1024 * 1024,
  }) sync* {
    final (handle, size) = openFileWithSize(path);
    try {
      int offset = 0;
      while (offset < size) {
        final toRead = (size - offset).clamp(0, chunkSize);
        yield readHandle(handle, offset: offset, length: toRead);
        offset += toRead;
      }
    } finally {
      closeHandle(handle);
    }
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

  void _ensureConnected() {
    if (_ctx == nullptr) {
      throw const Smb2Exception('Not connected. Call connect() first.');
    }
  }

  /// Build a typed [Smb2Exception] from the current context error.
  Smb2Exception _makeError(String prefix) {
    final msg = _error(_ctx).toDartString();
    final errno = _getErrno(_ctx);
    return Smb2Exception(
      '$prefix: $msg',
      errno,
      Smb2ErrorType.fromErrno(errno),
    );
  }

  /// Build a typed [Smb2Exception] from the thread-local last error.
  Smb2Exception _makeLastError(String prefix) {
    final msg = _lastError().toDartString();
    return Smb2Exception('$prefix: $msg');
  }

  static Smb2FileType _parseType(int type) => switch (type) {
    1 => Smb2FileType.directory,
    2 => Smb2FileType.link,
    _ => Smb2FileType.file,
  };
}
