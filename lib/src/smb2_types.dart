// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'package:meta/meta.dart';

import 'pool/pool.dart';
import 'smb2_client.dart';

/// SMB share type constants (MS-SRVS 2.2.2.4), for [Smb2ShareInfo.type].
abstract final class Smb2ShareType {
  /// Disk / folder share — the usual file-serving case.
  static const int diskTree = 0;

  /// Print-queue share.
  static const int printQueue = 1;

  /// Communication device share.
  static const int device = 2;

  /// Inter-process communication share (`IPC$`).
  static const int ipc = 3;

  /// Temporary-share flag, OR-ed with the base type.
  static const int temporary = 0x40000000;

  /// Hidden-share flag, OR-ed with the base type (e.g. `C$`, `ADMIN$`).
  static const int hidden = 0x80000000;
}

/// A share on a server, from [Smb2Pool.listSharesOn] or
/// [Smb2Client.listShares].
@immutable
final class Smb2ShareInfo {
  /// Share name (e.g. "Documents", "Music").
  final String name;

  /// Raw share type. The low 2 bits are the base type ([Smb2ShareType]),
  /// the upper bits are flags.
  final int type;

  /// The description the server gives the share, often empty.
  final String remark;

  /// Builds a [Smb2ShareInfo] with the values the server returned.
  const Smb2ShareInfo({
    required this.name,
    required this.type,
    this.remark = '',
  });

  /// The base type: [Smb2ShareType.diskTree], [Smb2ShareType.printQueue],
  /// [Smb2ShareType.device] or [Smb2ShareType.ipc].
  int get baseType => type & 0x03;

  /// Whether this is a disk/folder share.
  bool get isDisk => baseType == Smb2ShareType.diskTree;

  /// Whether this is a hidden share (e.g. `C$`, `IPC$`).
  bool get isHidden =>
      (type & Smb2ShareType.hidden) != 0 || name.endsWith(r'$');

  @override
  bool operator ==(Object other) =>
      other is Smb2ShareInfo &&
      other.name == name &&
      other.type == type &&
      other.remark == remark;

  @override
  int get hashCode => Object.hash(name, type, remark);

  @override
  String toString() => 'Smb2ShareInfo(name: $name, type: $type)';
}

/// SMB protocol version to negotiate during connection.
///
/// Default is [any], which lets the server pick the highest version both
/// sides support.
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

  /// The value passed to libsmb2's `smb2_set_version`.
  final int value;
  const Smb2Version(this.value);
}

/// What a directory entry is.
enum Smb2FileType {
  /// Regular file.
  file,

  /// Directory.
  directory,

  /// Symbolic link or other reparse point.
  link,
}

/// File or directory metadata, from [Smb2Client.stat] and the entries of a
/// directory listing. Timestamps are UTC, to the microsecond.
@immutable
final class Smb2Stat {
  /// Whether this is a file, directory, or link.
  final Smb2FileType type;

  /// Size in bytes. Zero for directories.
  final int size;

  /// Last modification of the content.
  final DateTime modified;

  /// Creation (birth) time.
  final DateTime created;

  /// Last access, as far as the server keeps track of it.
  final DateTime accessed;

  /// Last change of the content or the metadata.
  final DateTime changed;

  /// The FILE_ATTRIBUTE_* flags of the entry (MS-FSCC 2.6).
  final int attributes;

  /// Builds a [Smb2Stat].
  const Smb2Stat({
    required this.type,
    required this.size,
    required this.modified,
    required this.created,
    required this.accessed,
    required this.changed,
    this.attributes = 0,
  });

  /// True if this is a directory.
  bool get isDirectory => type == Smb2FileType.directory;

  /// True if this is a regular file.
  bool get isFile => type == Smb2FileType.file;

  /// True if the server marks the entry hidden (FILE_ATTRIBUTE_HIDDEN).
  /// Dot files are not hidden by this flag; check the name for those.
  bool get isHidden => attributes & 0x2 != 0;

  @override
  bool operator ==(Object other) =>
      other is Smb2Stat &&
      other.type == type &&
      other.size == size &&
      other.modified == modified &&
      other.created == created &&
      other.accessed == accessed &&
      other.changed == changed &&
      other.attributes == attributes;

  @override
  int get hashCode =>
      Object.hash(type, size, modified, created, accessed, changed, attributes);

  @override
  String toString() =>
      'Smb2Stat(type: ${type.name}, size: $size, modified: $modified)';
}

/// A directory entry: its name and its metadata, which the listing returns
/// without a request per entry.
@immutable
final class Smb2DirEntry {
  /// File or directory name (not a full path).
  final String name;

  /// Metadata for this entry.
  final Smb2Stat stat;

  /// Builds a [Smb2DirEntry] from a name and its [Smb2Stat].
  const Smb2DirEntry({required this.name, required this.stat});

  /// True if this entry is a directory.
  bool get isDirectory => stat.isDirectory;

  /// True if this entry is a regular file.
  bool get isFile => stat.isFile;

  /// File size in bytes.
  int get size => stat.size;

  @override
  bool operator ==(Object other) =>
      other is Smb2DirEntry && other.name == name && other.stat == stat;

  @override
  int get hashCode => Object.hash(name, stat);

  @override
  String toString() =>
      'Smb2DirEntry(name: $name, ${stat.type.name}, $size bytes)';
}

/// Filesystem statistics of a share, from [Smb2Client.statvfs].
@immutable
final class Smb2StatVfs {
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

  /// Builds a [Smb2StatVfs] from the statvfs fields.
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
  bool operator ==(Object other) =>
      other is Smb2StatVfs &&
      other.blockSize == blockSize &&
      other.fragmentSize == fragmentSize &&
      other.totalBlocks == totalBlocks &&
      other.freeBlocks == freeBlocks &&
      other.availableBlocks == availableBlocks &&
      other.maxNameLength == maxNameLength;

  @override
  int get hashCode => Object.hash(
    blockSize,
    fragmentSize,
    totalBlocks,
    freeBlocks,
    availableBlocks,
    maxNameLength,
  );

  @override
  String toString() =>
      'Smb2StatVfs(total: $totalSize, free: $freeSize, available: $availableSize)';
}
