// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Messages between the main isolate's [Worker] proxy and the worker
/// isolate (worker_main.dart). Package-private.
library;

import 'dart:isolate';

import '../smb2_error_type.dart';
import '../smb2_exception.dart';
import '../smb2_types.dart';
import 'worker.dart';

/// What a worker can be asked to do.
enum Op {
  /// Lists a directory: `[path]`.
  listDirectory,

  /// Stats a path: `[path]`.
  stat,

  /// Space statistics: `[path]`.
  statvfs,

  /// Reads a symlink: `[path]`.
  readlink,

  /// Sends an echo.
  echo,

  /// Reads a whole file: `[path]`.
  readFile,

  /// Reads a range: `[path, offset, length]`.
  readRange,

  /// Replaces a file: `[path, buffer, length, 0]`.
  writeFile,

  /// Writes a range: `[path, buffer, length, offset]`.
  writeRange,

  /// Creates a directory: `[path]`.
  mkdir,

  /// Removes a directory: `[path]`.
  rmdir,

  /// Deletes a file: `[path]`.
  deleteFile,

  /// Renames: `[oldPath, newPath]`.
  rename,

  /// Truncates: `[path, length]`.
  truncate,

  /// Sets times: `[path, modifiedUs?, accessedUs?]`.
  setFileTimes,

  /// Opens for reading: `[path]`, replies the handle id.
  open,

  /// Opens for reading: `[path]`, replies `(id, size)`.
  openWithSize,

  /// Opens for writing: `[path, truncate]`, replies the id.
  openWrite,

  /// Reads a handle: `[id, offset, length]`.
  readHandle,

  /// Writes a handle: `[id, buffer, length, offset]`.
  writeHandle,

  /// Flushes a handle: `[id]`.
  fsyncHandle,

  /// Truncates a handle: `[id, length]`.
  ftruncateHandle,

  /// Closes a handle: `[id]`.
  closeHandle,

  /// Closes every handle and logs off.
  close,

  /// Test only: the next `args[0]` requests fail with a connection error.
  injectFailures,

  /// Test only: the next request never gets a reply.
  injectHang,

  /// Test only: the next readHandle returns no bytes.
  injectEmptyRead,

  /// Test only: replies how many files the worker holds open.
  injectHandleCount,

  /// Test only: the worker's isolate exits, as a crash would.
  injectExit;

  /// Whether a successful reply carries a handle id the worker opened,
  /// which must be closed when nobody waits for it any more.
  bool get opensHandle =>
      this == open || this == openWithSize || this == openWrite;

  /// Whether the request carries a native buffer in `args[1]`.
  bool get carriesBuffer =>
      this == writeFile || this == writeRange || this == writeHandle;

  /// Whether the op is a test-only fault injection.
  bool get isInjection => _injections.contains(this);
}

/// The connection settings, kept by the pool for every (re)spawn.
final class ConnectParams {
  /// Server host name or IP.
  final String host;

  /// Share to connect to.
  final String share;

  /// User name; empty or null for an anonymous logon.
  final String? user;

  /// Password; null for an anonymous logon, `''` for an account without
  /// one.
  final String? password;

  /// NT domain or workgroup.
  final String? domain;

  /// Timeout of every request.
  final Duration timeout;

  /// Whether to require SMB3 encryption.
  final bool seal;

  /// Whether to require signing.
  final bool signing;

  /// Dialect to negotiate.
  final Smb2Version version;

  /// The settings of one pool.
  const ConnectParams({
    required this.host,
    required this.share,
    this.user,
    this.password,
    this.domain,
    required this.timeout,
    this.seal = false,
    this.signing = false,
    this.version = Smb2Version.any,
  });
}

/// The worker isolate's argument.
final class Init {
  /// Where the worker sends [Ready] and its replies.
  final SendPort replies;

  /// What to connect to.
  final ConnectParams params;

  /// Test only: the worker exits before connecting.
  final bool exitBeforeConnect;

  /// Test only: the worker never answers.
  final bool neverReady;

  /// The argument of a worker for [params].
  const Init(
    this.replies,
    this.params, {
    this.exitBeforeConnect = false,
    this.neverReady = false,
  });
}

/// The worker's first message once connected.
final class Ready {
  /// Where the main isolate sends [Request]s.
  final SendPort commands;

  /// The connected worker's first message.
  const Ready(this.commands);
}

/// A request. [id] 0 asks for no reply.
final class Request {
  /// Matches the reply to the request.
  final int id;

  /// What to do.
  final Op op;

  /// The operation's arguments (see [Op]).
  final List<Object?> args;

  /// A request [id] for [op].
  const Request(this.id, this.op, this.args);
}

/// A successful reply.
final class Reply {
  /// The [Request.id] answered.
  final int id;

  /// The result.
  final Object? value;

  /// The result [value] of request [id].
  const Reply(this.id, this.value);
}

/// A failed reply, or (with [id] -1) a failed start.
final class Failure {
  /// The [Request.id] answered, or -1 for the start.
  final int id;

  /// [Smb2Exception.message].
  final String message;

  /// The index of [Smb2Exception.type].
  final int type;

  /// [Smb2Exception.ntStatus].
  final int? ntStatus;

  /// [Smb2Exception.errno].
  final int? errno;

  /// [Smb2Exception.path].
  final String? path;

  /// The failure [e] of request [id].
  Failure(this.id, Smb2Exception e)
    : message = e.message,
      type = e.type.index,
      ntStatus = e.ntStatus,
      errno = e.errno,
      path = e.path;

  /// The exception again, on the receiving side.
  Smb2Exception toException() => Smb2Exception(
    message,
    type: Smb2ErrorType.values[type],
    ntStatus: ntStatus,
    errno: errno,
    path: path,
  );
}

/// Bytes in a `malloc` buffer the worker filled: the receiver owns it.
final class NativeBytes {
  /// The buffer's address; 0 when [length] is 0.
  final int address;

  /// Bytes in the buffer.
  final int length;

  /// [length] bytes at [address].
  const NativeBytes(this.address, this.length);
}

const _injections = {
  Op.injectFailures,
  Op.injectHang,
  Op.injectEmptyRead,
  Op.injectHandleCount,
  Op.injectExit,
};
