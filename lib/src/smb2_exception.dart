// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'pool/pool.dart';
import 'smb2_client.dart';
import 'smb2_error_type.dart';

/// Exception thrown by [Smb2Client] and [Smb2Pool] for any failed
/// operation.
///
/// The [message] is suitable for log lines but not for end users.
/// The [type] classifies the failure so callers can branch behaviour:
///
/// ```dart
/// try {
///   await pool.listDirectory('Music');
/// } on Smb2Exception catch (e) {
///   if (e.isAuthError) await askForCredentials();
///   else if (e.isTransient) scheduleRetry();
///   else if (!e.isCancelled) showError(e.message);
/// }
/// ```
final class Smb2Exception implements Exception {
  /// Human-readable description, with libsmb2's own message when there is
  /// one.
  final String message;

  /// Semantic category for programmatic handling.
  final Smb2ErrorType type;

  /// The NTSTATUS the server answered this call with (for example
  /// `0xC0000034`, OBJECT_NAME_NOT_FOUND), or null when the failure did not
  /// come from the server or its status could not be told apart from an
  /// earlier one.
  final int? ntStatus;

  /// The errno of the failure, in the numbering of the platform the binary
  /// runs on: the one the libsmb2 call returned, or for an open or a
  /// listing, which return none, the one of [ntStatus]. Null for transport
  /// failures and for libsmb2's generic failure.
  final int? errno;

  /// The share-relative path of the operation, when it has one.
  final String? path;

  /// The underlying error, if any (a `FileSystemException` while writing a
  /// download, the error of a dead worker isolate, ...).
  final Object? cause;

  /// The originating stack trace, when captured.
  final StackTrace? stackTrace;

  /// Builds an exception with a [message] and optional classification.
  const Smb2Exception(
    this.message, {
    this.type = Smb2ErrorType.unknown,
    this.ntStatus,
    this.errno,
    this.path,
    this.cause,
    this.stackTrace,
  });

  /// The connection, the session or a handle was lost, or the server did
  /// not answer in time. The server may be down or unreachable, and a
  /// reconnect may recover — not the same as an answer that says no.
  bool get isNetworkFailure => type.isNetworkFailure;

  /// A failure that may pass if the same call is made again later: a
  /// network failure, or a file or server that is busy
  /// ([Smb2ErrorType.inUse]). Not an auth error, a missing path, a
  /// cancellation or a misuse.
  bool get isTransient => isNetworkFailure || type == Smb2ErrorType.inUse;

  /// The path or share does not exist. For a read this is a confirmed
  /// absence, not a failure to answer.
  bool get isNotFound => type == Smb2ErrorType.notFound;

  /// The caller cancelled the operation. Not a failure: ignore it rather
  /// than reporting it.
  bool get isCancelled => type == Smb2ErrorType.cancelled;

  /// The server rejected the credentials. A server that maps unknown users
  /// to guest refuses them at the share instead, with
  /// [Smb2ErrorType.accessDenied].
  bool get isAuthError => type == Smb2ErrorType.auth;

  /// Same as [isNetworkFailure].
  @Deprecated('Use isNetworkFailure. Will be removed in 0.3.0.')
  bool get isConnectionError => isNetworkFailure;

  /// Same as [errno]. 0.1.x read it from the context's NT status after
  /// every failure; it is null where [errno] is.
  @Deprecated('Use errno. Will be removed in 0.3.0.')
  int? get errorCode => errno;

  @override
  String toString() {
    final parts = <String>['Smb2Exception(${type.name})'];
    if (ntStatus != null) {
      parts.add('status=0x${ntStatus!.toRadixString(16).padLeft(8, '0')}');
    }
    if (errno != null) parts.add('errno=$errno');
    if (path != null) parts.add('path=$path');
    parts.add(message);
    return parts.join(' ');
  }
}
