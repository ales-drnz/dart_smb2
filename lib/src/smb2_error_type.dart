// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Semantic error categories mapped from POSIX errno values.
///
/// SMB2 operations surface native errno codes that vary by platform.
/// This enum normalises them into actionable categories so callers can
/// decide whether to retry, re-authenticate, or surface the error.
enum Smb2ErrorType {
  /// Retriable transport errors (ENETRESET, ECONNRESET, ECONNABORTED, EPIPE,
  /// ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH).
  connection,

  /// The operation timed out (ETIMEDOUT).
  timeout,

  /// Authentication / logon failure (ECONNREFUSED from LOGON_FAILURE,
  /// EACCES from account restrictions).
  auth,

  /// The requested path does not exist (ENOENT).
  fileNotFound,

  /// Permission denied (EACCES from ACCESS_DENIED / NETWORK_ACCESS_DENIED).
  accessDenied,

  /// A path component is not a directory (ENOTDIR).
  notADirectory,

  /// The target already exists (EEXIST).
  alreadyExists,

  /// No space left on the remote share (ENOSPC).
  diskFull,

  /// Low-level I/O error (EIO).
  io,

  /// Invalid argument (EINVAL).
  invalidParam,

  /// Fallback for unmapped errno values.
  unknown;

  /// Whether this error indicates a transport-level failure that may be
  /// resolved by reconnecting.
  bool get isConnectionError =>
      this == Smb2ErrorType.connection || this == Smb2ErrorType.timeout;

  /// Maps a POSIX [errno] value to a semantic [Smb2ErrorType].
  ///
  /// Handles both Linux and macOS/iOS errno values since libsmb2 surfaces the
  /// platform-native codes.
  static Smb2ErrorType fromErrno(int errno) => switch (errno) {
        // ENOENT — Linux & macOS
        2 => Smb2ErrorType.fileNotFound,

        // EIO — Linux & macOS
        5 => Smb2ErrorType.io,

        // EACCES — Linux & macOS
        // Could stem from ACCESS_DENIED, NETWORK_ACCESS_DENIED, or account
        // restrictions.  Callers that need to distinguish auth from pure
        // access-denied can inspect the original SMB2 status code.
        13 => Smb2ErrorType.accessDenied,

        // EEXIST — Linux & macOS
        17 => Smb2ErrorType.alreadyExists,

        // ENOTDIR — Linux & macOS
        20 => Smb2ErrorType.notADirectory,

        // EINVAL — Linux & macOS
        22 => Smb2ErrorType.invalidParam,

        // ENOSPC — Linux & macOS
        28 => Smb2ErrorType.diskFull,

        // EPIPE — Linux & macOS
        32 => Smb2ErrorType.connection,

        // ENETDOWN — macOS/iOS
        50 => Smb2ErrorType.connection,

        // ENETUNREACH — macOS/iOS
        51 => Smb2ErrorType.connection,

        // ENETRESET — macOS/iOS
        52 => Smb2ErrorType.connection,

        // ECONNABORTED — macOS/iOS
        53 => Smb2ErrorType.connection,

        // ECONNRESET — macOS/iOS
        54 => Smb2ErrorType.connection,

        // ENOTCONN — macOS/iOS
        57 => Smb2ErrorType.connection,

        // ETIMEDOUT — macOS/iOS
        60 => Smb2ErrorType.timeout,

        // ECONNREFUSED — macOS/iOS (often LOGON_FAILURE)
        61 => Smb2ErrorType.auth,

        // EHOSTDOWN — macOS/iOS
        64 => Smb2ErrorType.connection,

        // EHOSTUNREACH — macOS/iOS
        65 => Smb2ErrorType.connection,

        // ENETDOWN — Linux
        100 => Smb2ErrorType.connection,

        // ENETUNREACH — Linux
        101 => Smb2ErrorType.connection,

        // ENETRESET — Linux
        102 => Smb2ErrorType.connection,

        // ECONNABORTED — Linux
        103 => Smb2ErrorType.connection,

        // ECONNRESET — Linux
        104 => Smb2ErrorType.connection,

        // ENOTCONN — Linux
        107 => Smb2ErrorType.connection,

        // ETIMEDOUT — Linux
        110 => Smb2ErrorType.timeout,

        // ECONNREFUSED — Linux (often LOGON_FAILURE)
        111 => Smb2ErrorType.auth,

        // EHOSTDOWN — Linux
        112 => Smb2ErrorType.connection,

        // EHOSTUNREACH — Linux
        113 => Smb2ErrorType.connection,

        _ => Smb2ErrorType.unknown,
      };
}
