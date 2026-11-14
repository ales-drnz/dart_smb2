// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Trees through a pool: recursive mkdir and rmdir, walks and copies.
part of 'pool.dart';

/// The calls of [Smb2Pool] that work on a whole tree.
mixin _PoolTrees on _PoolCore, _PoolCalls, _PoolTransfers {
  /// Creates the directory [path]. Not repeated after a network failure.
  ///
  /// With [recursive], also creates the directories above it that are
  /// missing, like `mkdir -p`: a directory that exists already is not an
  /// error, a file in the way fails with [Smb2ErrorType.notADirectory] or
  /// [Smb2ErrorType.alreadyExists]. As existing is not a failure, the
  /// recursive form is repeated after a network failure.
  Future<void> mkdir(
    String path, {
    bool recursive = false,
    Smb2CancelToken? cancelToken,
  }) async {
    if (!recursive) {
      return _run(
        Op.mkdir,
        [path],
        path: path,
        idempotent: false,
        cancelToken: cancelToken,
      );
    }
    final parts = _segments(path);
    // From the deepest existing directory down: usually one stat.
    var have = parts.length;
    while (have > 0) {
      final dir = parts.take(have).join('/');
      try {
        final st = await stat(dir, cancelToken: cancelToken);
        if (!st.isDirectory) {
          throw Smb2Exception(
            'Not a directory',
            type: Smb2ErrorType.notADirectory,
            path: dir,
          );
        }
        break;
      } on Smb2Exception catch (e) {
        if (!e.isNotFound) rethrow;
        have--;
      }
    }
    for (var i = have + 1; i <= parts.length; i++) {
      final dir = parts.take(i).join('/');
      try {
        await _run<void>(Op.mkdir, [dir], path: dir, cancelToken: cancelToken);
      } on Smb2Exception catch (e) {
        // Made meanwhile, by another client or by a repeat.
        if (e.type != Smb2ErrorType.alreadyExists ||
            !(await stat(dir, cancelToken: cancelToken)).isDirectory) {
          rethrow;
        }
      }
    }
  }

  /// Removes the empty directory [path]. Not repeated after a network
  /// failure.
  ///
  /// With [recursive], removes everything below it first, like `rm -r`:
  /// files, links (not what they point at) and directories, deepest first,
  /// as many at once as there are workers. The whole tree is listed before
  /// anything is removed. An entry that is gone already is skipped, so the
  /// removal is repeated after a network failure. At the first entry it
  /// cannot remove it stops, waits for the removals in flight and throws,
  /// leaving the rest; a file the server keeps open fails with
  /// [Smb2ErrorType.inUse] or [Smb2ErrorType.accessDenied]. The share root
  /// (`''`) is refused with an [ArgumentError].
  ///
  /// A link the server reports as one (a reparse point) is removed, never
  /// entered. Samba, with its default `follow symlinks = yes`, shows a
  /// symbolic link to a directory as that directory, and cannot remove it
  /// over SMB. The file ids of the listings tell such a link, unless it
  /// lies in the same directory as its target, which then cannot be told
  /// from it: a tree that holds one, or a [path] that is one or has one
  /// beside it, fails with [Smb2ErrorType.notSupported] before anything is
  /// removed. Remove those links on the server.
  Future<void> rmdir(
    String path, {
    bool recursive = false,
    Smb2CancelToken? cancelToken,
  }) async {
    if (!recursive) {
      return _run(
        Op.rmdir,
        [path],
        path: path,
        idempotent: false,
        cancelToken: cancelToken,
      );
    }
    final parts = _segments(path);
    if (parts.isEmpty) {
      throw ArgumentError.value(
        path,
        'path',
        'The share root cannot be removed',
      );
    }
    await _removeTree(parts.join('/'), cancelToken);
  }

  Future<void> _removeTree(String root, Smb2CancelToken? cancelToken) async {
    final slash = root.lastIndexOf('/');
    final parent = slash < 0 ? '' : root.substring(0, slash);
    final name = root.substring(slash + 1).toLowerCase();
    // The parent's listing, as a stat stops at a link made over SMB.
    var (parentId, _, siblings) = await _run<(int, int, List<Smb2DirEntry>)>(
      Op.listDirectoryIds,
      [parent],
      path: parent,
      cancelToken: cancelToken,
    );
    final top = siblings
        .where((e) => e.name.toLowerCase() == name)
        .firstOrNull
        ?.stat;
    if (top == null) {
      throw Smb2Exception(
        'No such directory',
        type: Smb2ErrorType.notFound,
        path: root,
      );
    }
    if (top.type == Smb2FileType.link) {
      return _removeEntry(root, cancelToken);
    }
    if (!top.isDirectory) {
      throw Smb2Exception(
        'Not a directory',
        type: Smb2ErrorType.notADirectory,
        path: root,
      );
    }
    if (parentId == 0) {
      parentId = (await stat(parent, cancelToken: cancelToken)).fileId;
    }
    // A link beside its target has the same id and the same `..`: which
    // one is the link cannot be told.
    if (top.fileId != 0 &&
        siblings.any(
          (e) => e.name.toLowerCase() != name && e.stat.fileId == top.fileId,
        )) {
      throw _followedLink(root);
    }
    final entries = <String>[];
    final dirs = <String>[];
    await for (final step in _walk(
      root,
      recursive: true,
      parentId: parentId,
      cancelToken: cancelToken,
    )) {
      final at = _under(root, step.name);
      if (step.stat case final st?) {
        if (!st.isDirectory) entries.add(at);
      } else if (step.link) {
        // Found before anything is removed.
        throw _followedLink(at);
      } else {
        dirs.add(at);
      }
    }
    await _each(entries, (e) => _removeEntry(e, cancelToken));
    // Deepest first, as many at once as there are workers per level.
    final byDepth = <int, List<String>>{};
    for (final d in dirs) {
      byDepth.putIfAbsent('/'.allMatches(d).length, () => []).add(d);
    }
    for (final depth in byDepth.keys.toList()..sort((a, b) => b - a)) {
      await _each(byDepth[depth]!, (d) => _gone(Op.rmdir, d, cancelToken));
    }
  }

  static Smb2Exception _followedLink(String path) => Smb2Exception(
    'A link the server shows as a directory, or its target beside it: '
    'remove the link on the server',
    type: Smb2ErrorType.notSupported,
    path: path,
  );

  /// Removes the file or link [path]; gone already is done.
  Future<void> _removeEntry(String path, Smb2CancelToken? cancelToken) async {
    try {
      await _run<void>(
        Op.deleteFile,
        [path],
        path: path,
        cancelToken: cancelToken,
      );
    } on Smb2Exception catch (err) {
      if (err.isNotFound) return;
      // A link to a directory goes with rmdir, which leaves its target.
      if (err.type != Smb2ErrorType.isADirectory) rethrow;
      await _gone(Op.rmdir, path, cancelToken);
    }
  }

  /// Runs [action] on each of [items], as many at once as there are
  /// workers. After the first failure it starts no more, waits for those
  /// in flight and throws that failure.
  Future<void> _each<T>(List<T> items, Future<void> Function(T) action) async {
    var next = 0;
    Object? error;
    StackTrace? trace;
    Future<void> lane() async {
      while (error == null && next < items.length) {
        final item = items[next++];
        try {
          await action(item);
        } catch (e, st) {
          error ??= e;
          trace ??= st;
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < min(workerCount, items.length); i++) lane(),
    ]);
    if (error case final e?) Error.throwWithStackTrace(e, trace!);
  }

  /// Runs [op] on [path], repeated after a network failure, and takes a
  /// missing path for done.
  Future<void> _gone(Op op, String path, Smb2CancelToken? cancelToken) async {
    try {
      await _run<void>(op, [path], path: path, cancelToken: cancelToken);
    } on Smb2Exception catch (e) {
      if (!e.isNotFound) rethrow;
    }
  }

  /// Copies the directory [source], with everything below it, to
  /// [destination] and returns the bytes copied.
  ///
  /// Lists the whole tree first, so [onProgress] gets the bytes copied so
  /// far and the total of all the files. Directories are created as needed
  /// and merge with existing ones; files are copied one at a time as
  /// [copy] does, and an existing file fails the copy unless [overwrite]
  /// is set. Symbolic links are skipped, and so are the links to a
  /// directory that Samba shows as the directory, when [streamDirectory]
  /// would not enter them. A failure stops the copy and leaves what was
  /// copied before it.
  Future<int> copyTree(
    String source,
    String destination, {
    bool overwrite = false,
    int chunkSize = Smb2Pool.defaultChunkSize,
    void Function(int copied, int total)? onProgress,
    Smb2CancelToken? cancelToken,
  }) async {
    final from = await stat(source, cancelToken: cancelToken);
    if (!from.isDirectory) {
      throw Smb2Exception(
        'Not a directory: copy it with copy',
        type: Smb2ErrorType.notADirectory,
        path: source,
      );
    }
    final src = _segments(source).join('/');
    final dst = _segments(destination).join('/');
    final steps = await _walk(
      src,
      recursive: true,
      cancelToken: cancelToken,
    ).toList();
    final total = steps.fold<int>(
      0,
      (sum, s) => sum + (s.stat?.isFile ?? false ? s.stat!.size : 0),
    );
    var done = 0;
    onProgress?.call(0, total);
    for (final step in steps) {
      final st = step.stat;
      if (st == null) {
        // A directory it enters; the links the server follows are skipped.
        if (!step.link) {
          await mkdir(
            _under(dst, step.name),
            recursive: true,
            cancelToken: cancelToken,
          );
        }
      } else if (st.isFile) {
        final before = done;
        done += await copy(
          _under(src, step.name),
          _under(dst, step.name),
          overwrite: overwrite,
          chunkSize: chunkSize,
          onProgress: onProgress == null
              ? null
              : (copied, _) => onProgress(before + copied, total),
          cancelToken: cancelToken,
        );
      }
    }
    return done;
  }

  /// The entries of the directory [path] as a stream, one listing request
  /// at a time; with [recursive], the entries of every directory below it
  /// too, each directory followed by its contents.
  ///
  /// Each entry's [Smb2DirEntry.name] is its path relative to [path]
  /// (`Album/01.flac`), with `/` separators. Links are listed but not
  /// followed. Samba, with its default `follow symlinks = yes`, shows a
  /// symbolic link to a directory as that directory: it is listed as one,
  /// but entered only when its target lies in the same directory and was
  /// not listed already, as the file ids of the listings tell; so a link
  /// never makes a loop. A tree deeper than 256 levels fails with
  /// [Smb2ErrorType.notSupported].
  ///
  /// The stream lists the next directory only when the listener asks for
  /// more, so pausing or cancelling the subscription stops it.
  Stream<Smb2DirEntry> streamDirectory(
    String path, {
    bool recursive = false,
    Smb2CancelToken? cancelToken,
  }) async* {
    await for (final step in _walk(
      _segments(path).join('/'),
      recursive: recursive,
      cancelToken: cancelToken,
    )) {
      if (step.stat case final st?) {
        yield Smb2DirEntry(name: step.name, stat: st);
      }
    }
  }

  /// Walks the tree at [root], depth first, one listing at a time.
  ///
  /// Yields each entry as listed, with its stat; and, without one, each
  /// directory it lists, before its contents ('' for [root]). A directory
  /// whose `..` is not the directory it was listed in ([parentId] for
  /// [root], when not 0), or whose id was listed already, is a link the
  /// server follows: it is yielded with `link` set and not entered.
  Stream<({String name, Smb2Stat? stat, bool link})> _walk(
    String root, {
    required bool recursive,
    int parentId = 0,
    Smb2CancelToken? cancelToken,
  }) async* {
    final seen = <int>{};
    // Directories still to list, with the id of the one they are in.
    final pending = <(String, int)>[('', parentId)];
    while (pending.isNotEmpty) {
      final (rel, parent) = pending.removeLast();
      if (rel.isNotEmpty && '/'.allMatches(rel).length >= _maxTreeDepth) {
        throw Smb2Exception(
          'More than $_maxTreeDepth levels: a link loop?',
          type: Smb2ErrorType.notSupported,
          path: _under(root, rel),
        );
      }
      final dir = _under(root, rel);
      final (self, up, entries) = await _run<(int, int, List<Smb2DirEntry>)>(
        Op.listDirectoryIds,
        [dir],
        path: dir,
        cancelToken: cancelToken,
      );
      if ((up != 0 && parent != 0 && up != parent) ||
          (self != 0 && !seen.add(self))) {
        yield (name: rel, stat: null, link: true);
        continue;
      }
      yield (name: rel, stat: null, link: false);
      final dirs = <(String, int)>[];
      for (final e in entries) {
        final name = rel.isEmpty ? e.name : '$rel/${e.name}';
        yield (name: name, stat: e.stat, link: false);
        if (recursive && e.isDirectory) dirs.add((name, self));
      }
      // Depth first, in listing order.
      pending.addAll(dirs.reversed);
    }
  }
}

/// The deepest a tree walk goes, against link loops the file ids miss.
const int _maxTreeDepth = 256;
