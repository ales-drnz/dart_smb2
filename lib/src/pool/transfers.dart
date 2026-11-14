// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Streams, downloads, uploads and copies through a pool.
part of 'pool.dart';

/// The streaming and whole-file transfers of [Smb2Pool].
mixin _PoolTransfers on _PoolCore, _PoolCalls {
  /// Streams the file at [path] in chunks of [chunkSize] bytes, keeping
  /// one handle open for the whole read and the next chunk in flight while
  /// the listener handles the current one.
  ///
  /// The stream waits while its listener is paused, so at most two chunks
  /// are in memory. [onProgress] gets the bytes received so far and the
  /// file size after each chunk. Cancelling the subscription closes the
  /// handle, and its future completes without error; [cancelToken] also
  /// closes it, and ends the stream with a [Smb2ErrorType.cancelled]
  /// error.
  Stream<Uint8List> streamFile(
    String path, {
    int chunkSize = Smb2Pool.defaultChunkSize,
    void Function(int received, int total)? onProgress,
    Smb2CancelToken? cancelToken,
  }) {
    final controller = StreamController<Uint8List>();
    // The token of the stream's own requests, cancelled by [cancelToken]
    // and by the listener leaving.
    final reads = Smb2CancelToken();
    var unlink = _noop;
    var stopped = false;
    Completer<void>? resumed;
    Future<void>? pumping;

    Future<void> pump() async {
      Smb2PoolHandle? handle;
      Future<Uint8List>? next;
      try {
        if (chunkSize <= 0) {
          throw Smb2Exception(
            'chunkSize must be positive',
            type: Smb2ErrorType.invalidParam,
            path: path,
          );
        }
        if (cancelToken != null) {
          if (cancelToken.isCancelled) reads.cancel(cancelToken.reason);
          unlink = cancelToken.register(() => reads.cancel(cancelToken.reason));
        }
        final (opened, size) = await openFileWithSize(path, cancelToken: reads);
        handle = opened;
        // The read ahead may fail while the chunk before it waits for the
        // listener; mark it observed so the failure is not reported as
        // unhandled. The `await` below still receives it.
        Future<Uint8List> fetch(int offset) => readFromHandle(
          opened,
          offset: offset,
          length: min(chunkSize, size - offset),
          cancelToken: reads,
        )..ignore();
        var received = 0;
        if (size > 0 && !stopped) next = fetch(0);
        while (next != null) {
          final chunk = await next;
          next = null;
          if (stopped) return;
          if (chunk.isEmpty) {
            throw Smb2Exception(
              'The file shrank while it was read: $received of $size bytes',
              type: Smb2ErrorType.io,
              path: path,
            );
          }
          // One chunk waits here while the listener holds the one before:
          // two in memory at most.
          while (controller.isPaused && !stopped && !reads.isCancelled) {
            await Future.any([
              (resumed ??= Completer<void>()).future,
              reads.whenCancelled,
            ]);
          }
          if (stopped) return;
          reads.throwIfCancelled(path: path);
          received += chunk.length;
          if (received < size) next = fetch(received);
          onProgress?.call(received, size);
          controller.add(chunk);
        }
        // Read to the end: the stream is done once the file is closed, so
        // the listener can delete or rename it next.
        handle = null;
        await closeHandle(opened);
      } catch (e, st) {
        if (!stopped) controller.addError(e, st);
      } finally {
        unlink();
        // A read still in flight when the listener left: drop its result.
        next?.ignore();
        // Left early: the close may queue behind a read stuck on the network.
        if (handle != null) _closeLater(handle);
        if (!stopped) unawaited(controller.close());
      }
    }

    void wake() {
      resumed?.complete();
      resumed = null;
    }

    controller.onListen = () => pumping = pump();
    controller.onResume = wake;
    controller.onCancel = () {
      stopped = true;
      // Ends the requests in flight at once: their results are not wanted.
      reads.cancel();
      wake();
      return pumping;
    };
    return controller.stream;
  }

  /// Downloads [path] to the local file [destination] and returns the
  /// bytes written.
  ///
  /// The data goes to a temporary file next to [destination] as it
  /// arrives, at the pace the disk takes it, and is renamed to
  /// [destination] only once complete. A failure or a cancellation through
  /// [cancelToken] removes the temporary file and throws a
  /// [Smb2Exception] (of type [Smb2ErrorType.cancelled] for a
  /// cancellation); whatever was at [destination] before is left as it
  /// was. Two downloads to the same [destination] never share a temporary
  /// file.
  Future<int> downloadToFile(
    String path,
    String destination, {
    int chunkSize = Smb2Pool.defaultChunkSize,
    void Function(int received, int total)? onProgress,
    Smb2CancelToken? cancelToken,
  }) async {
    final File part;
    final RandomAccessFile out;
    try {
      part = await _createPart(destination);
      out = await part.open(mode: FileMode.writeOnly);
    } on FileSystemException catch (e, st) {
      throw Smb2Exception(
        'Cannot write $destination: ${e.message}',
        type: Smb2ErrorType.io,
        path: destination,
        cause: e,
        stackTrace: st,
      );
    }
    var written = 0;
    try {
      await for (final chunk in streamFile(
        path,
        chunkSize: chunkSize,
        onProgress: onProgress,
        cancelToken: cancelToken,
      )) {
        await out.writeFrom(chunk);
        written += chunk.length;
      }
      await out.close();
      cancelToken?.throwIfCancelled(path: path);
      await part.rename(destination);
      return written;
    } catch (e, st) {
      await out.close().catchError((Object _) => out);
      await part.delete().catchError((Object _) => part);
      if (e is Smb2Exception) rethrow;
      if (e is FileSystemException) {
        throw Smb2Exception(
          'Cannot write $destination: ${e.message}',
          type: Smb2ErrorType.io,
          path: destination,
          cause: e,
          stackTrace: st,
        );
      }
      rethrow;
    }
  }

  /// Replaces the content of [path] with [chunks], written in order through
  /// one handle, so only one chunk is in memory at a time, and returns the
  /// bytes written.
  ///
  /// Each chunk goes to its own offset, so after a network failure the pool
  /// reconnects, reopens the file (without emptying it again) and writes the
  /// chunk once more.
  ///
  /// [onProgress] gets the bytes the server has taken so far and [length],
  /// the total the caller expects (-1 when not given), after each chunk, as
  /// [streamFile] reports a download.
  Future<int> streamWrite(
    String path,
    Stream<Uint8List> chunks, {
    int? length,
    void Function(int sent, int total)? onProgress,
    Smb2CancelToken? cancelToken,
  }) => _streamWrite(
    path,
    chunks,
    length: length,
    onProgress: onProgress,
    cancelToken: cancelToken,
  );

  Future<int> _streamWrite(
    String path,
    Stream<Uint8List> chunks, {
    int? length,
    void Function(int sent, int total)? onProgress,
    Smb2CancelToken? cancelToken,
    bool temporary = false,
  }) async {
    final handle = await _openWrite(
      path,
      truncate: true,
      temporary: temporary,
      cancelToken: cancelToken,
    );
    var offset = 0;
    try {
      await for (final chunk in chunks) {
        cancelToken?.throwIfCancelled(path: path);
        if (chunk.isEmpty) continue;
        await writeToHandle(
          handle,
          chunk,
          offset: offset,
          cancelToken: cancelToken,
        );
        offset += chunk.length;
        onProgress?.call(offset, length ?? -1);
      }
    } catch (_) {
      _closeLater(handle);
      rethrow;
    }
    await closeHandle(handle);
    return offset;
  }

  /// Uploads the local file [source] to [path] and returns the bytes
  /// written: the counterpart of [downloadToFile].
  ///
  /// The file is read in chunks of [chunkSize] and written to a temporary
  /// file next to [path] (`<path>.part-<random>`), which replaces [path]
  /// only once complete (a rename with `overwrite`), so readers of [path]
  /// never see half a file. A failure or a cancellation through
  /// [cancelToken] removes the temporary file and throws; [path] is left as
  /// it was. [onProgress] gets the bytes the server has taken and the file
  /// size after each chunk.
  Future<int> uploadFile(
    String source,
    String path, {
    int chunkSize = Smb2Pool.defaultChunkSize,
    void Function(int sent, int total)? onProgress,
    Smb2CancelToken? cancelToken,
  }) async {
    if (chunkSize <= 0) {
      throw Smb2Exception(
        'chunkSize must be positive',
        type: Smb2ErrorType.invalidParam,
        path: path,
      );
    }
    final RandomAccessFile input;
    final int size;
    try {
      input = await File(source).open();
      size = await input.length();
    } on FileSystemException catch (e, st) {
      throw Smb2Exception(
        'Cannot read $source: ${e.message}',
        // A missing folder on the way is error 3 on Windows, not 2.
        type: e is PathNotFoundException
            ? Smb2ErrorType.notFound
            : Smb2ErrorType.io,
        path: source,
        cause: e,
        stackTrace: st,
      );
    }
    Stream<Uint8List> read() async* {
      while (true) {
        final chunk = await input.read(chunkSize);
        if (chunk.isEmpty) return;
        yield chunk;
      }
    }

    try {
      return await _viaPart(
        path,
        (part) => _streamWrite(
          part,
          read(),
          length: size,
          onProgress: onProgress,
          cancelToken: cancelToken,
          temporary: true,
        ),
        cancelToken,
      );
    } on FileSystemException catch (e, st) {
      throw Smb2Exception(
        'Cannot read $source: ${e.message}',
        type: Smb2ErrorType.io,
        path: source,
        cause: e,
        stackTrace: st,
      );
    } finally {
      await input.close().catchError((Object _) => input);
    }
  }

  /// Runs [write] on a new temporary path next to [path], then renames it
  /// over [path]; on any failure removes the temporary file, as far as the
  /// connection allows, and rethrows.
  Future<T> _viaPart<T>(
    String path,
    Future<T> Function(String part) write,
    Smb2CancelToken? cancelToken, {
    bool overwrite = true,
  }) async {
    final part = '$path.part-${_partSuffix()}';
    try {
      final result = await write(part);
      cancelToken?.throwIfCancelled(path: path);
      await rename(part, path, overwrite: overwrite);
      return result;
    } catch (_) {
      if (!_closed) {
        await _run<void>(
          Op.deleteFile,
          [part],
          path: part,
        ).catchError((Object _) {}, test: (e) => e is Smb2Exception);
      }
      rethrow;
    }
  }

  /// Copies the file [source] to [destination] on the share and returns
  /// the bytes copied.
  ///
  /// The data passes through this machine (SMB2 has no server-side copy
  /// that every server offers): [source] is streamed as [streamFile] reads
  /// it and written to a temporary file next to [destination], which takes
  /// its place once complete. Without [overwrite], an existing
  /// [destination] fails with [Smb2ErrorType.alreadyExists], before any data
  /// is read and again at the final rename. [onProgress] gets the bytes
  /// written so far and the size of [source]. A failure or a cancellation
  /// removes the temporary file and leaves [destination] as it was.
  Future<int> copy(
    String source,
    String destination, {
    bool overwrite = false,
    int chunkSize = Smb2Pool.defaultChunkSize,
    void Function(int copied, int total)? onProgress,
    Smb2CancelToken? cancelToken,
  }) async {
    final from = await stat(source, cancelToken: cancelToken);
    if (from.isDirectory) {
      throw Smb2Exception(
        'Is a directory: copy it with copyTree',
        type: Smb2ErrorType.isADirectory,
        path: source,
      );
    }
    if (!overwrite && await exists(destination, cancelToken: cancelToken)) {
      throw Smb2Exception(
        'The destination exists',
        type: Smb2ErrorType.alreadyExists,
        path: destination,
      );
    }
    return _viaPart(
      destination,
      (part) => _streamWrite(
        part,
        streamFile(source, chunkSize: chunkSize, cancelToken: cancelToken),
        length: from.size,
        onProgress: onProgress,
        cancelToken: cancelToken,
        temporary: true,
      ),
      cancelToken,
      overwrite: overwrite,
    );
  }
}

/// The random end of a temporary file's name: 16 hex digits, so two
/// transfers to the same path do not meet (the remote one is opened without
/// a check that it is new).
String _partSuffix() {
  final random = Random();
  String half() => random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return '${half()}${half()}';
}

/// A new, empty file next to [destination] for a download to fill.
Future<File> _createPart(String destination) async {
  for (var attempt = 0; ; attempt++) {
    final part = File('$destination.part-${_partSuffix()}');
    try {
      return await part.create(exclusive: true);
    } on FileSystemException {
      if (attempt >= 8) rethrow;
    }
  }
}
