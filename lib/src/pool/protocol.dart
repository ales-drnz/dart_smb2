// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Messages between the main isolate's [Worker] proxy and the worker
/// isolate (worker_main.dart). Package-private.
///
/// @docImport 'worker.dart';
library;

import 'dart:isolate';
import 'dart:typed_data';

import '../smb2_error_type.dart';
import '../smb2_exception.dart';
import '../smb2_types.dart';

/// What a worker can be asked to do, and the type of its answer, [T].
///
/// One class per request, with its arguments as fields: the worker
/// switches over them all, so a request it does not serve does not compile.
sealed class Request<T> {
  const Request();
}

/// A request that conflicts with a file still open on the server: it waits
/// for the closes of its [conflicts] that are still in flight.
abstract interface class Mutation {
  /// The paths the request changes.
  List<String> get conflicts;

  /// Whether the request also conflicts with the files below [conflicts]:
  /// the server refuses the rename or the removal of a directory while a
  /// file in it is open.
  bool get coversTree;
}

/// A request whose answer carries the id of a handle the worker opened,
/// which must be closed when nobody waits for the answer any more.
abstract interface class OpensHandle {}

/// A request that comes with a native buffer of [length] bytes to write.
/// The buffer travels beside the request ([Call.buffer]): it stays the
/// main isolate's, which makes one for each attempt.
abstract interface class Write {
  /// Bytes in the buffer.
  int get length;
}

/// A test-only fault injection, which the faults themselves do not touch.
abstract interface class Injection {}

/// Lists a directory.
final class ListDirectory extends Request<List<Smb2DirEntry>> {
  /// The directory.
  final String path;

  /// Lists [path].
  const ListDirectory(this.path);
}

/// Lists a directory with the file ids of its `.` and `..`.
final class ListDirectoryIds extends Request<(int, int, List<Smb2DirEntry>)> {
  /// The directory.
  final String path;

  /// Lists [path] with its ids.
  const ListDirectoryIds(this.path);
}

/// Stats a path.
final class Stat extends Request<Smb2Stat> {
  /// The path.
  final String path;

  /// Stats [path].
  const Stat(this.path);
}

/// Space statistics of the share that holds a path.
final class StatVfs extends Request<Smb2StatVfs> {
  /// The path.
  final String path;

  /// The space statistics for [path].
  const StatVfs(this.path);
}

/// Reads the target of a symbolic link.
final class Readlink extends Request<String> {
  /// The link.
  final String path;

  /// Reads the link [path].
  const Readlink(this.path);
}

/// Sends an echo.
final class Echo extends Request<void> {
  /// An echo.
  const Echo();
}

/// Reads a whole file.
final class ReadFile extends Request<Uint8List> {
  /// The file.
  final String path;

  /// Reads [path].
  const ReadFile(this.path);
}

/// Reads a range of a file.
final class ReadRange extends Request<Uint8List> {
  /// The file.
  final String path;

  /// Where the range starts.
  final int offset;

  /// Bytes to read.
  final int length;

  /// Reads [length] bytes of [path] from [offset].
  const ReadRange(this.path, this.offset, this.length);
}

/// Replaces the content of a file with the buffer.
final class WriteFile extends Request<void> implements Write, Mutation {
  /// The file.
  final String path;

  @override
  final int length;

  /// Replaces [path] with [length] bytes.
  const WriteFile(this.path, this.length);

  @override
  List<String> get conflicts => [path];

  @override
  bool get coversTree => false;
}

/// Writes the buffer to a range of a file.
final class WriteRange extends Request<void> implements Write, Mutation {
  /// The file.
  final String path;

  @override
  final int length;

  /// Where the range starts.
  final int offset;

  /// Writes [length] bytes to [path] at [offset].
  const WriteRange(this.path, this.length, this.offset);

  @override
  List<String> get conflicts => [path];

  @override
  bool get coversTree => false;
}

/// Creates a directory.
final class Mkdir extends Request<void> {
  /// The directory.
  final String path;

  /// Creates [path].
  const Mkdir(this.path);
}

/// Removes a directory.
final class Rmdir extends Request<void> implements Mutation {
  /// The directory.
  final String path;

  /// Removes [path].
  const Rmdir(this.path);

  @override
  List<String> get conflicts => [path];

  @override
  bool get coversTree => true;
}

/// Deletes a file.
final class DeleteFile extends Request<void> implements Mutation {
  /// The file.
  final String path;

  /// Deletes [path].
  const DeleteFile(this.path);

  @override
  List<String> get conflicts => [path];

  @override
  bool get coversTree => false;
}

/// Renames or moves a path.
final class Rename extends Request<void> implements Mutation {
  /// The path as it is.
  final String oldPath;

  /// The path it gets.
  final String newPath;

  /// Whether a file at [newPath] is replaced.
  final bool overwrite;

  /// Renames [oldPath] to [newPath].
  const Rename(this.oldPath, this.newPath, {required this.overwrite});

  @override
  List<String> get conflicts => [oldPath, newPath];

  @override
  bool get coversTree => true;
}

/// Creates a hard link.
final class Link extends Request<void> implements Mutation {
  /// The file the link names.
  final String existingPath;

  /// The link.
  final String newPath;

  /// Links [newPath] to [existingPath].
  const Link(this.existingPath, this.newPath);

  @override
  List<String> get conflicts => [newPath];

  @override
  bool get coversTree => false;
}

/// Creates a symbolic link.
final class Symlink extends Request<void> {
  /// What the link points at.
  final String target;

  /// The link.
  final String linkPath;

  /// Whether the target is a directory.
  final bool directory;

  /// Makes [linkPath] point at [target].
  const Symlink(this.target, this.linkPath, {required this.directory});
}

/// Truncates, or extends, a file.
final class Truncate extends Request<void> implements Mutation {
  /// The file.
  final String path;

  /// The length it gets.
  final int length;

  /// Sets [path] to [length] bytes.
  const Truncate(this.path, this.length);

  @override
  List<String> get conflicts => [path];

  @override
  bool get coversTree => false;
}

/// Sets the times of a path.
final class SetFileTimes extends Request<void> implements Mutation {
  /// The path.
  final String path;

  /// The modified time in microseconds since the epoch, or null to leave
  /// it.
  final int? modifiedUs;

  /// The accessed time in microseconds since the epoch, or null to leave
  /// it.
  final int? accessedUs;

  /// Sets the times of [path].
  const SetFileTimes(this.path, {this.modifiedUs, this.accessedUs});

  @override
  List<String> get conflicts => [path];

  @override
  bool get coversTree => false;
}

/// Opens a file for reading; answers the handle id.
final class Open extends Request<int> implements OpensHandle {
  /// The file.
  final String path;

  /// Opens [path].
  const Open(this.path);
}

/// Opens a file for reading; answers the handle id and the size.
final class OpenWithSize extends Request<(int, int)> implements OpensHandle {
  /// The file.
  final String path;

  /// Opens [path].
  const OpenWithSize(this.path);
}

/// Opens a file for writing; answers the handle id.
final class OpenWrite extends Request<int> implements OpensHandle, Mutation {
  /// The file.
  final String path;

  /// Whether the file is emptied first.
  final bool truncate;

  /// Whether the file is a temporary one of the pool's, which shares
  /// delete (see `openTemporaryWrite`).
  final bool temporary;

  /// Opens [path] for writing.
  const OpenWrite(this.path, {required this.truncate, required this.temporary});

  @override
  List<String> get conflicts => [path];

  @override
  bool get coversTree => false;
}

/// Reads a range of an open file.
final class ReadHandle extends Request<Uint8List> {
  /// The handle id.
  final int id;

  /// Where the range starts.
  final int offset;

  /// Bytes to read.
  final int length;

  /// Reads [length] bytes of handle [id] from [offset].
  const ReadHandle(this.id, this.offset, this.length);
}

/// Writes the buffer to a range of an open file.
final class WriteHandle extends Request<void> implements Write {
  /// The handle id.
  final int id;

  @override
  final int length;

  /// Where the range starts.
  final int offset;

  /// Writes [length] bytes to handle [id] at [offset].
  const WriteHandle(this.id, this.length, this.offset);
}

/// Flushes an open file to the server's disk.
final class FsyncHandle extends Request<void> {
  /// The handle id.
  final int id;

  /// Flushes handle [id].
  const FsyncHandle(this.id);
}

/// Truncates, or extends, an open file.
final class FtruncateHandle extends Request<void> {
  /// The handle id.
  final int id;

  /// The length it gets.
  final int length;

  /// Sets the file of handle [id] to [length] bytes.
  const FtruncateHandle(this.id, this.length);
}

/// Closes a handle.
final class CloseHandle extends Request<void> {
  /// The handle id.
  final int id;

  /// Closes handle [id].
  const CloseHandle(this.id);
}

/// Closes every handle and logs off.
final class Close extends Request<void> {
  /// The end of the worker.
  const Close();
}

/// Test only: the next requests fail with a connection error.
final class InjectFailures extends Request<void> implements Injection {
  /// How many requests fail.
  final int count;

  /// Fails the next [count] requests.
  const InjectFailures(this.count);
}

/// Test only: the next request never gets a reply.
final class InjectHang extends Request<void> implements Injection {
  /// Hangs the next request.
  const InjectHang();
}

/// Test only: the next [ReadHandle] returns no bytes.
final class InjectEmptyRead extends Request<void> implements Injection {
  /// Empties the next handle read.
  const InjectEmptyRead();
}

/// Test only: answers how many files the worker holds open.
final class InjectHandleCount extends Request<int> implements Injection {
  /// Counts the open handles.
  const InjectHandleCount();
}

/// Test only: the worker's isolate exits, as a crash would.
final class InjectExit extends Request<void> implements Injection {
  /// Ends the isolate.
  const InjectExit();
}

/// The connection settings, kept by the pool for every (re)spawn.
final class ConnectParams {
  /// Server host name or IP.
  final String host;

  /// Share to connect to.
  final String share;

  /// User name; empty or null for an anonymous logon.
  final String? user;

  /// Password; null for an anonymous logon, `''` for an account without
  /// one.
  final String? password;

  /// NT domain or workgroup.
  final String? domain;

  /// Timeout of every request.
  final Duration timeout;

  /// Whether to require SMB3 encryption.
  final bool seal;

  /// Whether to require signing.
  final bool signing;

  /// Dialect to negotiate.
  final Smb2Version version;

  /// The settings of one pool.
  const ConnectParams({
    required this.host,
    required this.share,
    this.user,
    this.password,
    this.domain,
    required this.timeout,
    this.seal = false,
    this.signing = false,
    this.version = Smb2Version.any,
  });
}

/// The worker isolate's argument.
final class Init {
  /// Where the worker sends [Ready] and its replies.
  final SendPort replies;

  /// What to connect to.
  final ConnectParams params;

  /// Test only: the worker exits before connecting.
  final bool exitBeforeConnect;

  /// Test only: the worker never answers.
  final bool neverReady;

  /// The argument of a worker for [params].
  const Init(
    this.replies,
    this.params, {
    this.exitBeforeConnect = false,
    this.neverReady = false,
  });
}

/// The worker's first message once connected.
final class Ready {
  /// Where the main isolate sends [Request]s.
  final SendPort commands;

  /// The connected worker's first message.
  const Ready(this.commands);
}

/// A request on its way to the worker. [id] 0 asks for no reply.
final class Call {
  /// Matches the reply to the request.
  final int id;

  /// What to do.
  final Request<Object?> request;

  /// The address of the native buffer of a [Write], which the worker reads
  /// and the main isolate frees.
  final int? buffer;

  /// The request [id], [request], with its [buffer] if it writes.
  const Call(this.id, this.request, [this.buffer]);
}

/// A successful reply.
final class Reply {
  /// The [Call.id] answered.
  final int id;

  /// The result.
  final Object? value;

  /// The result [value] of request [id].
  const Reply(this.id, this.value);
}

/// A failed reply, or (with [id] -1) a failed start.
final class Failure {
  /// The [Call.id] answered, or -1 for the start.
  final int id;

  /// [Smb2Exception.message].
  final String message;

  /// The index of [Smb2Exception.type].
  final int type;

  /// [Smb2Exception.ntStatus].
  final int? ntStatus;

  /// [Smb2Exception.errno].
  final int? errno;

  /// [Smb2Exception.path].
  final String? path;

  /// The failure [e] of request [id].
  Failure(this.id, Smb2Exception e)
    : message = e.message,
      type = e.type.index,
      ntStatus = e.ntStatus,
      errno = e.errno,
      path = e.path;

  /// The exception again, on the receiving side.
  Smb2Exception toException() => Smb2Exception(
    message,
    type: Smb2ErrorType.values[type],
    ntStatus: ntStatus,
    errno: errno,
    path: path,
  );
}

/// Bytes in a `malloc` buffer the worker filled: the receiver owns it.
final class NativeBytes {
  /// The buffer's address; 0 when [length] is 0.
  final int address;

  /// Bytes in the buffer.
  final int length;

  /// [length] bytes at [address].
  const NativeBytes(this.address, this.length);
}
