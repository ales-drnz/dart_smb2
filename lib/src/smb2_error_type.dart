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

  /// Classify a libsmb2 error message string.
  ///
  /// libsmb2's transport-level failure paths (`POLLHUP`, `POLLERR`,
  /// `Read from socket failed`, `Failed to open smb2 socket`, etc.) call
  /// `smb2_set_error()` without updating the context's NT status. As a result
  /// `smb2w_get_errno()` returns 0 — or worse, a *stale* errno from an earlier
  /// operation — and pure errno-based classification misses these as
  /// connection failures, breaking auto-reconnect.
  ///
  /// This classifier inspects the freshest signal — the message libsmb2 just
  /// produced — and recognises the substrings emitted by the C library's
  /// socket layer. Returns [unknown] when no marker matches; callers should
  /// fall through to [fromErrno] in that case.
  ///
  /// Substrings are matched case-insensitively. The list is intentionally
  /// derived from a static audit of libsmb2's `smb2_set_error()` call sites
  /// in `socket.c`, `libsmb2.c`, `sync.c`, and `pdu.c`.
  static Smb2ErrorType fromMessage(String message) {
    if (message.isEmpty) return Smb2ErrorType.unknown;
    final m = message.toLowerCase();

    // Timeout — libsmb2's wait loops ('Timeout expired …') and the strerror
    // form of ETIMEDOUT ('… timed out') for the rare case where libsmb2
    // formats errno-derived text into a smb2_set_error() call.
    if (m.contains('timeout expired') || m.contains('timed out')) {
      return Smb2ErrorType.timeout;
    }

    // Transport / socket failures.  Each substring corresponds to a known
    // libsmb2 error message that is emitted via `smb2_set_error()` (which
    // does not update the NT status), so errno-based classification cannot
    // catch them.
    const connectionMarkers = <String>[
      'pollhup',                       // socket.c POLLHUP path
      'pollerr',                       // socket.c POLLERR path
      'socket error',                  // socket.c smb2_service variants
      'read from socket failed',       // socket.c read paths (both variants)
      'error when writing to',         // socket.c write path
      'remote closed connection',      // socket.c read EOF
      'not connected',                 // socket.c / sync.c "Not Connected to Server"
      'socket connect failed',         // libsmb2.c connect path
      'failed to open smb2 socket',    // socket.c socket() failure
      'connect failed with errno',     // socket.c connect() failure
      'alreeady disconnected',         // libsmb2.c (sic — upstream typo, kept verbatim)
      'already disconnected',          // future-proof if upstream fixes the typo
      'no connected tree-id',          // pdu.c — server tore down the session (idle teardown)
      'no tree-id connected',          // pdu.c — same condition, different code path
    ];
    for (final marker in connectionMarkers) {
      if (m.contains(marker)) return Smb2ErrorType.connection;
    }

    return Smb2ErrorType.unknown;
  }

  /// Combined classifier — prefers the message (which reflects the current
  /// failure) and falls back to the errno mapping.
  ///
  /// This is the right entry point for code that has both a libsmb2 message
  /// and an errno value. The message is consulted first because libsmb2's
  /// `nterror` field is *not reset* between operations — a stale errno from
  /// a prior call can otherwise misclassify a fresh transport failure.
  static Smb2ErrorType classify(String message, int errno) {
    final fromMsg = fromMessage(message);
    if (fromMsg != Smb2ErrorType.unknown) return fromMsg;
    return fromErrno(errno);
  }
}
