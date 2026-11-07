// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'package:meta/meta.dart';

import 'pool/pool.dart';
import 'smb2_client.dart';

/// SMB share type constants (MS-SRVS 2.2.2.4), for [Smb2ShareInfo.type].
///
/// {@category Connection}
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
///
/// {@category Connection}
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
///
/// {@category Connection}
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
///
/// {@category Files and directories}
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
///
/// {@category Files and directories}
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

  /// The server's id of the file (its IndexNumber, MS-FSCC 2.4.20), the
  /// same for every name of it; 0 when the server gives none.
  final int fileId;

  /// Builds a [Smb2Stat].
  const Smb2Stat({
    required this.type,
    required this.size,
    required this.modified,
    required this.created,
    required this.accessed,
    required this.changed,
    this.attributes = 0,
    this.fileId = 0,
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
      other.attributes == attributes &&
      other.fileId == fileId;

  @override
  int get hashCode => Object.hash(
    type,
    size,
    modified,
    created,
    accessed,
    changed,
    attributes,
    fileId,
  );

  @override
  String toString() =>
      'Smb2Stat(type: ${type.name}, size: $size, modified: $modified)';
}

/// A directory entry: its name and its metadata, which the listing returns
/// without a request per entry.
///
/// {@category Files and directories}
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
///
/// {@category Files and directories}
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

/// What a change notification watches for, as a bit mask
/// (`CompletionFilter`, MS-SMB2 2.2.35), for [Smb2Pool.watch] and
/// [Smb2Client.watch].
///
/// {@category Files and directories}
abstract final class Smb2ChangeFilter {
  /// A file is created, removed or renamed.
  static const int fileName = 0x001;

  /// A directory is created, removed or renamed.
  static const int dirName = 0x002;

  /// The attributes of an entry change.
  static const int attributes = 0x004;

  /// The size of a file changes.
  static const int size = 0x008;

  /// The last-write time of an entry changes.
  static const int lastWrite = 0x010;

  /// The last-access time of an entry changes.
  static const int lastAccess = 0x020;

  /// The creation time of an entry changes.
  static const int creation = 0x040;

  /// The security descriptor of an entry changes.
  static const int security = 0x100;

  /// Names, sizes and writes: what a file browser needs to stay current.
  static const int defaults = fileName | dirName | size | lastWrite;

  /// Every change the filter can name, alternate data streams included.
  static const int all = 0xFFF;
}

/// What happened to an entry, in a [Smb2ChangeEvent].
///
/// {@category Files and directories}
enum Smb2ChangeAction {
  /// The entry was created, or moved into the directory.
  added(1),

  /// The entry was removed, or moved out of the directory.
  removed(2),

  /// The entry's data or metadata changed.
  modified(3),

  /// The entry was renamed: this is its old name. A [renamedTo] event with
  /// the new name follows.
  renamedFrom(4),

  /// The entry was renamed: this is its new name.
  renamedTo(5),

  /// An alternate data stream of the entry was created.
  streamAdded(6),

  /// An alternate data stream of the entry was removed.
  streamRemoved(7),

  /// An alternate data stream of the entry changed.
  streamModified(8),

  /// Changes were lost: the server had more than it could report, or the
  /// watch reconnected. List the directory again to catch up.
  overflow(0);

  /// The `Action` value of `FILE_NOTIFY_INFORMATION` (MS-FSCC 2.7.1).
  final int value;

  const Smb2ChangeAction(this.value);

  /// The action of a `FILE_NOTIFY_INFORMATION` value; [overflow] for one
  /// that is not listed.
  static Smb2ChangeAction fromValue(int value) => switch (value) {
    1 => added,
    2 => removed,
    3 => modified,
    4 => renamedFrom,
    5 => renamedTo,
    6 => streamAdded,
    7 => streamRemoved,
    8 => streamModified,
    _ => overflow,
  };
}

/// A change in a watched directory, from [Smb2Pool.watch] or
/// [Smb2Watcher.next].
///
/// {@category Files and directories}
@immutable
final class Smb2ChangeEvent {
  /// What happened.
  final Smb2ChangeAction action;

  /// The share-relative path of the entry, with `/` separators. For
  /// [Smb2ChangeAction.overflow], the watched directory.
  final String path;

  /// A change of [action] at [path].
  const Smb2ChangeEvent(this.action, this.path);

  @override
  bool operator ==(Object other) =>
      other is Smb2ChangeEvent && other.action == action && other.path == path;

  @override
  int get hashCode => Object.hash(action, path);

  @override
  String toString() => 'Smb2ChangeEvent(${action.name}, $path)';
}

/// The share-relative path of [name], an entry a change notification
/// reports relative to the watched directory [dir] (with `\` separators
/// for a recursive watch).
@internal
String changePath(String dir, String name) {
  final base = dir
      .replaceAll(r'\', '/')
      .replaceFirst(RegExp('^/+'), '')
      .replaceFirst(RegExp(r'/+$'), '');
  final rel = name.replaceAll(r'\', '/');
  if (rel.isEmpty) return base;
  return base.isEmpty ? rel : '$base/$rel';
}
