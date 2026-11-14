// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Paths, strings, times and stats between Dart and libsmb2.
part of '../smb2_client.dart';

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

DateTime _time(int seconds, int nanoseconds) => statTime(seconds, nanoseconds);

/// The time of a stat field, from libsmb2's seconds since the Unix epoch
/// and nanoseconds.
///
/// libsmb2 subtracts the epoch from the server's FILETIME as an unsigned
/// number, so a time the server does not keep (a FILETIME of 0) or one
/// before 1970 wraps to a count of seconds far past the year 9999. Those
/// are given as the Unix epoch.
@internal
DateTime statTime(int seconds, int nanoseconds) {
  if (seconds < 0 || seconds > _lastSecond) {
    return DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true);
  }
  return DateTime.fromMicrosecondsSinceEpoch(
    seconds * 1000000 + nanoseconds ~/ 1000,
    isUtc: true,
  );
}

/// 9999-12-31T23:59:59Z, the last second a stat time is taken at its word.
const int _lastSecond = 253402300799;

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
