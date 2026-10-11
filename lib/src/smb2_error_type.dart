// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'smb2_exception.dart';

/// What went wrong, independent of the platform the error came from.
///
/// [Smb2Exception] carries one, so callers can decide whether to retry,
/// ask for credentials again, or report the error.
enum Smb2ErrorType {
  /// The connection failed or was lost: refused, reset, unreachable, or a
  /// session the server tore down.
  connection,

  /// The server did not answer within the timeout.
  timeout,

  /// The server rejected the credentials, or the account cannot log on.
  auth,

  /// The path, or the share, does not exist.
  notFound,

  /// The account has no permission for the operation.
  accessDenied,

  /// A path component, or the target of a directory operation, is not a
  /// directory.
  notADirectory,

  /// A file operation was asked of a directory.
  isADirectory,

  /// The target already exists.
  alreadyExists,

  /// The directory is not empty.
  notEmpty,

  /// Another client holds the file open or locked in a conflicting way.
  inUse,

  /// The share is out of space or over quota.
  diskFull,

  /// The server or the client failed to read or write the data.
  io,

  /// An argument was invalid: an empty or malformed path, a negative
  /// length, a timestamp out of range.
  invalidParam,

  /// The server does not support the operation.
  notSupported,

  /// The client, pool or handle is not in a state that allows the call:
  /// not connected, closed, or used after close.
  state,

  /// The caller cancelled the operation.
  cancelled,

  /// Anything not covered above.
  unknown;

  /// Whether the server could not be reached or stopped answering:
  /// [connection] or [timeout].
  bool get isNetworkFailure =>
      this == Smb2ErrorType.connection || this == Smb2ErrorType.timeout;

  /// Same as [isNetworkFailure].
  @Deprecated('Use isNetworkFailure. Will be removed in 0.3.0.')
  bool get isConnectionError => isNetworkFailure;

  /// The former name of [notFound].
  @Deprecated('Use notFound. Will be removed in 0.3.0.')
  static const Smb2ErrorType fileNotFound = Smb2ErrorType.notFound;

  /// The type of an NTSTATUS code, or [unknown] for one not listed.
  static Smb2ErrorType fromNtStatus(int status) =>
      _ntStatus[status & 0xFFFFFFFF] ?? Smb2ErrorType.unknown;

  /// The type of an errno value as the platform the binary was built for
  /// defines it ([os] defaults to the running one: `linux`, `android`,
  /// `macos`, `ios` or `windows`), or [unknown].
  static Smb2ErrorType fromErrno(int errno, {required String os}) {
    final table = switch (os) {
      'macos' || 'ios' => _darwinErrno,
      'windows' => _windowsErrno,
      _ => _linuxErrno,
    };
    return table[errno] ?? Smb2ErrorType.unknown;
  }

  /// The type of a libsmb2 error message, from the transport failures that
  /// libsmb2 reports without an NT status, or [unknown].
  ///
  /// Matched case-insensitively against the strings libsmb2's socket and
  /// sync layers pass to smb2_set_error().
  static Smb2ErrorType fromMessage(String message) {
    final m = message.toLowerCase();
    if (m.contains('timeout expired') || m.contains('timed out')) {
      return Smb2ErrorType.timeout;
    }
    for (final marker in _connectionMarkers) {
      if (m.contains(marker)) return Smb2ErrorType.connection;
    }
    return Smb2ErrorType.unknown;
  }

  /// Classifies a libsmb2 failure from everything it reported.
  ///
  /// In order, the first that gives a type wins:
  /// 1. a transport failure in [message] (libsmb2 reports those without
  ///    updating the NT status, which may still hold an earlier error);
  /// 2. [ntStatus], when the call set it ([ntStatusFresh]) or [message]
  ///    quotes it as `(0x........)`;
  /// 3. [errno], the negated return code of the failed call;
  /// 4. [unknown].
  static Smb2ErrorType classify({
    required String message,
    int? ntStatus,
    bool ntStatusFresh = false,
    int? errno,
    required String os,
  }) {
    final fromMsg = fromMessage(message);
    if (fromMsg != Smb2ErrorType.unknown) return fromMsg;
    final quoted = ntStatusInMessage(message);
    final status = quoted ?? (ntStatusFresh ? ntStatus : null);
    if (status != null) {
      final t = fromNtStatus(status);
      if (t != Smb2ErrorType.unknown) return t;
    }
    if (errno != null && errno > 0) return fromErrno(errno, os: os);
    return Smb2ErrorType.unknown;
  }

  /// The NT status libsmb2 quotes in [message] as `(0x........)`, if any.
  static int? ntStatusInMessage(String message) {
    final match = _quotedStatus.firstMatch(message);
    return match == null ? null : int.parse(match.group(1)!, radix: 16);
  }
}

final _quotedStatus = RegExp(r'\(0x([0-9a-fA-F]{8})\)');

/// Substrings of libsmb2's transport-failure messages (socket.c, sync.c,
/// libsmb2.c, pdu.c).
const _connectionMarkers = <String>[
  'pollhup',
  'pollerr',
  'socket error',
  'read from socket failed',
  'error when writing to',
  'remote closed connection',
  'not connected',
  'socket connect failed',
  'failed to open smb2 socket',
  'connect failed with errno',
  'alreeady disconnected', // sic, upstream's spelling
  'already disconnected',
  'no connected tree-id',
  'no tree-id connected',
];

/// NTSTATUS codes ([MS-ERREF] 2.3.1) that SMB servers answer with.
const _ntStatus = <int, Smb2ErrorType>{
  // Not found
  0xC000000F: Smb2ErrorType.notFound, // NO_SUCH_FILE
  0xC0000034: Smb2ErrorType.notFound, // OBJECT_NAME_NOT_FOUND
  0xC0000039: Smb2ErrorType.notFound, // OBJECT_PATH_INVALID
  0xC000003A: Smb2ErrorType.notFound, // OBJECT_PATH_NOT_FOUND
  0xC0000056: Smb2ErrorType.notFound, // DELETE_PENDING
  0xC00000CC: Smb2ErrorType.notFound, // BAD_NETWORK_NAME (no such share)
  0xC0000225: Smb2ErrorType.notFound, // NOT_FOUND
  // Authentication
  0xC0000064: Smb2ErrorType.auth, // NO_SUCH_USER
  0xC000006A: Smb2ErrorType.auth, // WRONG_PASSWORD
  0xC000006D: Smb2ErrorType.auth, // LOGON_FAILURE
  0xC000006E: Smb2ErrorType.auth, // ACCOUNT_RESTRICTION
  0xC000006F: Smb2ErrorType.auth, // INVALID_LOGON_HOURS
  0xC0000070: Smb2ErrorType.auth, // INVALID_WORKSTATION
  0xC0000071: Smb2ErrorType.auth, // PASSWORD_EXPIRED
  0xC0000072: Smb2ErrorType.auth, // ACCOUNT_DISABLED
  0xC000015B: Smb2ErrorType.auth, // LOGON_TYPE_NOT_GRANTED
  0xC0000193: Smb2ErrorType.auth, // ACCOUNT_EXPIRED
  0xC0000224: Smb2ErrorType.auth, // PASSWORD_MUST_CHANGE
  0xC0000234: Smb2ErrorType.auth, // ACCOUNT_LOCKED_OUT
  // Permission
  0xC0000022: Smb2ErrorType.accessDenied, // ACCESS_DENIED
  0xC0000061: Smb2ErrorType.accessDenied, // PRIVILEGE_NOT_HELD
  0xC0000121: Smb2ErrorType.accessDenied, // CANNOT_DELETE
  0xC00000CA: Smb2ErrorType.accessDenied, // NETWORK_ACCESS_DENIED
  // Path shape
  0xC0000103: Smb2ErrorType.notADirectory, // NOT_A_DIRECTORY
  0xC00000BA: Smb2ErrorType.isADirectory, // FILE_IS_A_DIRECTORY
  0xC0000035: Smb2ErrorType.alreadyExists, // OBJECT_NAME_COLLISION
  0xC0000101: Smb2ErrorType.notEmpty, // DIRECTORY_NOT_EMPTY
  // Contention
  0xC0000043: Smb2ErrorType.inUse, // SHARING_VIOLATION
  0xC0000054: Smb2ErrorType.inUse, // FILE_LOCK_CONFLICT
  0xC0000055: Smb2ErrorType.inUse, // LOCK_NOT_GRANTED
  // Space
  0xC000007F: Smb2ErrorType.diskFull, // DISK_FULL
  0xC0000044: Smb2ErrorType.diskFull, // QUOTA_EXCEEDED
  // Arguments
  0xC000000D: Smb2ErrorType.invalidParam, // INVALID_PARAMETER
  0xC0000033: Smb2ErrorType.invalidParam, // OBJECT_NAME_INVALID
  0xC000003B: Smb2ErrorType.invalidParam, // OBJECT_PATH_SYNTAX_BAD
  0xC0000275: Smb2ErrorType.invalidParam, // NOT_A_REPARSE_POINT
  // Support
  0xC0000002: Smb2ErrorType.notSupported, // NOT_IMPLEMENTED
  0xC0000010: Smb2ErrorType.notSupported, // INVALID_DEVICE_REQUEST
  0xC00000BB: Smb2ErrorType.notSupported, // NOT_SUPPORTED
  // I/O
  0xC0000185: Smb2ErrorType.io, // IO_DEVICE_ERROR
  0xC000009C: Smb2ErrorType.io, // DEVICE_DATA_ERROR
  // Session or handle gone: a new connection and a reopen recover
  0xC0000008: Smb2ErrorType.connection, // INVALID_HANDLE
  0xC0000128: Smb2ErrorType.connection, // FILE_CLOSED
  0xC00000BC: Smb2ErrorType.connection, // REMOTE_NOT_LISTENING
  0xC00000BE: Smb2ErrorType.connection, // BAD_NETWORK_PATH
  0xC00000C9: Smb2ErrorType.connection, // NETWORK_NAME_DELETED
  0xC0000203: Smb2ErrorType.connection, // USER_SESSION_DELETED
  0xC000020C: Smb2ErrorType.connection, // CONNECTION_DISCONNECTED
  0xC000020D: Smb2ErrorType.connection, // CONNECTION_RESET
  0xC0000236: Smb2ErrorType.connection, // CONNECTION_REFUSED
  0xC000023C: Smb2ErrorType.connection, // NETWORK_UNREACHABLE
  0xC000023D: Smb2ErrorType.connection, // HOST_UNREACHABLE
  0xC000035C: Smb2ErrorType.connection, // NETWORK_SESSION_EXPIRED
  0xC00000B5: Smb2ErrorType.timeout, // IO_TIMEOUT
  0xC0000120: Smb2ErrorType.cancelled, // CANCELLED
};

/// errno values of glibc and bionic (Linux, Android).
const _linuxErrno = <int, Smb2ErrorType>{
  1: Smb2ErrorType.accessDenied, // EPERM
  2: Smb2ErrorType.notFound, // ENOENT
  5: Smb2ErrorType.io, // EIO
  9: Smb2ErrorType.connection, // EBADF (stale handle)
  13: Smb2ErrorType.accessDenied, // EACCES
  17: Smb2ErrorType.alreadyExists, // EEXIST
  20: Smb2ErrorType.notADirectory, // ENOTDIR
  21: Smb2ErrorType.isADirectory, // EISDIR
  22: Smb2ErrorType.invalidParam, // EINVAL
  26: Smb2ErrorType.inUse, // ETXTBSY
  28: Smb2ErrorType.diskFull, // ENOSPC
  32: Smb2ErrorType.connection, // EPIPE
  35: Smb2ErrorType.inUse, // EDEADLK
  39: Smb2ErrorType.notEmpty, // ENOTEMPTY
  95: Smb2ErrorType.notSupported, // EOPNOTSUPP
  100: Smb2ErrorType.connection, // ENETDOWN
  101: Smb2ErrorType.connection, // ENETUNREACH
  102: Smb2ErrorType.connection, // ENETRESET
  103: Smb2ErrorType.connection, // ECONNABORTED
  104: Smb2ErrorType.connection, // ECONNRESET
  107: Smb2ErrorType.connection, // ENOTCONN
  110: Smb2ErrorType.timeout, // ETIMEDOUT
  111: Smb2ErrorType.auth, // ECONNREFUSED: libsmb2's LOGON_FAILURE
  112: Smb2ErrorType.connection, // EHOSTDOWN
  113: Smb2ErrorType.connection, // EHOSTUNREACH
  125: Smb2ErrorType.cancelled, // ECANCELED
};

/// errno values of Apple's libc (macOS, iOS).
const _darwinErrno = <int, Smb2ErrorType>{
  1: Smb2ErrorType.accessDenied, // EPERM
  2: Smb2ErrorType.notFound, // ENOENT
  5: Smb2ErrorType.io, // EIO
  9: Smb2ErrorType.connection, // EBADF
  11: Smb2ErrorType.inUse, // EDEADLK
  13: Smb2ErrorType.accessDenied, // EACCES
  17: Smb2ErrorType.alreadyExists, // EEXIST
  20: Smb2ErrorType.notADirectory, // ENOTDIR
  21: Smb2ErrorType.isADirectory, // EISDIR
  22: Smb2ErrorType.invalidParam, // EINVAL
  26: Smb2ErrorType.inUse, // ETXTBSY
  28: Smb2ErrorType.diskFull, // ENOSPC
  32: Smb2ErrorType.connection, // EPIPE
  45: Smb2ErrorType.notSupported, // ENOTSUP
  50: Smb2ErrorType.connection, // ENETDOWN
  51: Smb2ErrorType.connection, // ENETUNREACH
  52: Smb2ErrorType.connection, // ENETRESET
  53: Smb2ErrorType.connection, // ECONNABORTED
  54: Smb2ErrorType.connection, // ECONNRESET
  57: Smb2ErrorType.connection, // ENOTCONN
  60: Smb2ErrorType.timeout, // ETIMEDOUT
  61: Smb2ErrorType.auth, // ECONNREFUSED: libsmb2's LOGON_FAILURE
  64: Smb2ErrorType.connection, // EHOSTDOWN
  65: Smb2ErrorType.connection, // EHOSTUNREACH
  66: Smb2ErrorType.notEmpty, // ENOTEMPTY
  89: Smb2ErrorType.cancelled, // ECANCELED
};

/// errno values of the Windows UCRT, which the DLLs are built against.
const _windowsErrno = <int, Smb2ErrorType>{
  1: Smb2ErrorType.accessDenied, // EPERM
  2: Smb2ErrorType.notFound, // ENOENT
  5: Smb2ErrorType.io, // EIO
  9: Smb2ErrorType.connection, // EBADF
  13: Smb2ErrorType.accessDenied, // EACCES
  17: Smb2ErrorType.alreadyExists, // EEXIST
  20: Smb2ErrorType.notADirectory, // ENOTDIR
  21: Smb2ErrorType.isADirectory, // EISDIR
  22: Smb2ErrorType.invalidParam, // EINVAL
  28: Smb2ErrorType.diskFull, // ENOSPC
  32: Smb2ErrorType.connection, // EPIPE
  36: Smb2ErrorType.inUse, // EDEADLK
  41: Smb2ErrorType.notEmpty, // ENOTEMPTY
  105: Smb2ErrorType.cancelled, // ECANCELED
  106: Smb2ErrorType.connection, // ECONNABORTED
  107: Smb2ErrorType.auth, // ECONNREFUSED: libsmb2's LOGON_FAILURE
  108: Smb2ErrorType.connection, // ECONNRESET
  110: Smb2ErrorType.connection, // EHOSTUNREACH
  116: Smb2ErrorType.connection, // ENETDOWN
  117: Smb2ErrorType.connection, // ENETRESET
  118: Smb2ErrorType.connection, // ENETUNREACH
  126: Smb2ErrorType.connection, // ENOTCONN
  129: Smb2ErrorType.notSupported, // ENOTSUP
  138: Smb2ErrorType.timeout, // ETIMEDOUT
  139: Smb2ErrorType.inUse, // ETXTBSY
};
