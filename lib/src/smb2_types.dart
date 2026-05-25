// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// SMB share type constants.
abstract class Smb2ShareType {
  /// Disk / folder share — the usual file-serving case.
  static const int diskTree = 0;
  /// Print-queue share.
  static const int printQueue = 1;
  /// Communication device share.
  static const int device = 2;
  /// Inter-process communication share (`IPC$`).
  static const int ipc = 3;
  /// Hidden-share flag, OR-ed with the base type (e.g. `C$`, `ADMIN$`).
  static const int hidden = 0x80000000;
}

/// Information about an SMB share returned by [Smb2Client.listShares].
class Smb2ShareInfo {
  /// Share name (e.g. "Documents", "Music").
  final String name;

  /// Raw share type. Use [Smb2ShareType] constants to interpret.
  /// The low 2 bits indicate the type, upper bits are flags.
  final int type;

  /// Build a [Smb2ShareInfo] with the raw values returned by the server.
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

/// SMB protocol version to negotiate during connection.
///
/// Controls which SMB dialect the client offers to the server.
/// Default is [any], which lets the server pick the highest mutually
/// supported version.
enum Smb2Version {
  /// Negotiate the highest version supported by both sides (default).
  any(0),
  /// Any SMB 2.x dialect (2.0.2, 2.1).
  any2(2),
  /// Any SMB 3.x dialect (3.0, 3.0.2, 3.1.1). Required for encryption.
  any3(3),
  /// SMB 2.0.2.
  v202(0x0202),
  /// SMB 2.1.
  v210(0x0210),
  /// SMB 3.0.
  v300(0x0300),
  /// SMB 3.0.2.
  v302(0x0302),
  /// SMB 3.1.1 (latest, most secure).
  v311(0x0311);

  /// The numeric value passed to libsmb2's `smb2_set_version`.
  final int value;
  const Smb2Version(this.value);
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

  /// Build a [Smb2Stat]. All fields are required; timestamps are in UTC.
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

  /// Build a [Smb2DirEntry] from a name and its pre-fetched [Smb2Stat].
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

/// Filesystem statistics returned by [Smb2Client.statvfs].
class Smb2StatVfs {
  /// Fundamental block size in bytes.
  final int blockSize;

  /// Fragment size in bytes.
  final int fragmentSize;

  /// Total data blocks on the filesystem.
  final int totalBlocks;

  /// Free blocks on the filesystem.
  final int freeBlocks;

  /// Free blocks available to non-privileged users.
  final int availableBlocks;

  /// Maximum filename length.
  final int maxNameLength;

  /// Build a [Smb2StatVfs] from raw libsmb2 statvfs fields.
  const Smb2StatVfs({
    required this.blockSize,
    required this.fragmentSize,
    required this.totalBlocks,
    required this.freeBlocks,
    required this.availableBlocks,
    required this.maxNameLength,
  });

  /// Total size of the filesystem in bytes.
  int get totalSize => totalBlocks * fragmentSize;

  /// Free space on the filesystem in bytes.
  int get freeSize => freeBlocks * fragmentSize;

  /// Available space for non-privileged users in bytes.
  int get availableSize => availableBlocks * fragmentSize;

  @override
  String toString() =>
      'Smb2StatVfs(total: $totalSize, free: $freeSize, available: $availableSize)';
}
