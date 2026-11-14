// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// What a libsmb2 failure says, as an [Smb2Exception].
part of '../smb2_client.dart';

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

/// A reply that counts more bytes than the request asked for: the count
/// comes from the server, and past [want] it would reach beyond the buffer.
Smb2Exception _overrun(String what, int n, int want, String path) =>
    Smb2Exception(
      '$what returned $n bytes, $want were asked for',
      type: Smb2ErrorType.io,
      path: path,
    );

void _checkRange(int offset, int length, String path) {
  if (offset < 0) throw _invalid('offset must not be negative', path);
  if (length < 0) throw _invalid('length must not be negative', path);
}
