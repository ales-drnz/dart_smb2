// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The libsmb2 context of a connection: the release check, the credentials
/// and the connect.
part of '../smb2_client.dart';

/// [timeout] in the whole seconds libsmb2 counts, rounded up so a short
/// timeout stays one; 0 for none.
int _seconds(Duration timeout) =>
    timeout > Duration.zero ? (timeout.inMilliseconds + 999) ~/ 1000 : 0;

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
