// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// SMB share type constants.
abstract class Smb2ShareType {
  static const int diskTree = 0;
  static const int printQueue = 1;
  static const int device = 2;
  static const int ipc = 3;
  static const int hidden = 0x80000000;
}

/// Information about an SMB share returned by [Smb2Client.listShares].
class Smb2ShareInfo {
  /// Share name (e.g. "Documents", "Music").
  final String name;

  /// Raw share type. Use [Smb2ShareType] constants to interpret.
  /// The low 2 bits indicate the type, upper bits are flags.
  final int type;

  const Smb2ShareInfo({required this.name, required this.type});

  /// The base type (disk, print, device, IPC).
  int get baseType => type & 0x03;

  /// Whether this is a disk/folder share.
  bool get isDisk => baseType == Smb2ShareType.diskTree;

  /// Whether this is a hidden share (e.g. `C$`, `IPC$`).
  bool get isHidden => (type & Smb2ShareType.hidden) != 0 || name.endsWith('\$');

  @override
  String toString() => 'Smb2ShareInfo(name: $name, type: $type)';
}

/// SMB2 file type.
enum Smb2FileType {
  /// Regular file.
  file,
  /// Directory.
  directory,
  /// Symbolic link.
  link,
}

/// File or directory metadata returned by [Smb2Client.stat] and
/// [Smb2Client.listDirectory].
class Smb2Stat {
  /// Whether this is a file, directory, or link.
  final Smb2FileType type;

  /// Size in bytes. Zero for directories.
  final int size;

  /// Last modification time.
  final DateTime modified;

  /// Creation (birth) time.
  final DateTime created;

  const Smb2Stat({
    required this.type,
    required this.size,
    required this.modified,
    required this.created,
  });

  /// True if this is a directory.
  bool get isDirectory => type == Smb2FileType.directory;

  /// True if this is a regular file.
  bool get isFile => type == Smb2FileType.file;

  @override
  String toString() =>
      'Smb2Stat(type: $type, size: $size, modified: $modified)';
}

/// A directory entry returned by [Smb2Client.listDirectory].
///
/// Contains the entry name and full stat metadata, including type, size,
/// and timestamps — no additional per-entry round-trips required.
class Smb2DirEntry {
  /// File or directory name (not a full path).
  final String name;

  /// Metadata for this entry.
  final Smb2Stat stat;

  const Smb2DirEntry({required this.name, required this.stat});

  /// True if this entry is a directory.
  bool get isDirectory => stat.isDirectory;

  /// True if this entry is a regular file.
  bool get isFile => stat.isFile;

  /// File size in bytes.
  int get size => stat.size;

  @override
  String toString() => 'Smb2DirEntry(name: $name, ${stat.type.name}, $size bytes)';
}
