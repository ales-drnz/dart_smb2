List directories, read metadata and manage files and directories on the share.

## Listing a directory

```dart
final entries = await pool.listDirectory('Album');
for (final e in entries) {
  print('${e.name} ${e.stat.modified} ${e.isFile ? e.size : '-'}');
}
```

The listing carries each entry's metadata, so no request per entry is needed. `.` and `..` are left out. `Smb2Stat.isHidden` reports the server's hidden attribute (Samba sets it on dot files by default).

### Streaming a listing, or a whole tree

```dart
await for (final e in pool.streamDirectory('Album', recursive: true)) {
  print('${e.name} ${e.size}'); // 'CD1/01 - Intro.flac' ...
}
```

`streamDirectory` lists one directory per request, and the next one only when the listener asks for more, so pausing or cancelling the subscription stops it. With `recursive`, each directory is followed by its contents, and each entry's `name` is its path relative to the directory asked for. Links are listed, not followed, and a link never makes a loop: see Trees below for the links Samba follows. A tree deeper than 256 levels fails with `notSupported`.

## Stat, size and existence

```dart
final stat = await pool.stat('Album/01 - Intro.flac');
print('${stat.size} bytes, modified ${stat.modified}');

final size = await pool.fileSize('Album/01 - Intro.flac');
final there = await pool.exists('Album/booklet.pdf');
```

`Smb2Stat` holds the type, the size, the modified, created, accessed and changed times (UTC, to the microsecond), the file attributes and `fileId`, the server's id of the file, the same for every name of it. `exists` returns `false` only for a missing path. Any other failure throws.

## Space on the share

```dart
final vfs = await pool.statvfs('');
print('${vfs.availableSize} of ${vfs.totalSize} bytes free');
```

## Managing files and directories

```dart
await pool.mkdir('Backup/2026');
await pool.rename('Backup/log.bin', 'Backup/2026/log.bin');
await pool.truncate('Backup/2026/log.bin', 2);
await pool.setFileTimes(
  'Backup/2026/log.bin',
  modified: DateTime.utc(2026, 1, 1),
);
await pool.deleteFile('Backup/2026/log.bin');
await pool.rmdir('Backup/2026');
```

`rmdir` fails with `notEmpty` while the directory has entries and with `notADirectory` on a file. `deleteFile` fails with `isADirectory` on a directory, or a link to one, which `rmdir` removes. Set times after the file's write handles are closed: the server refreshes the modified time on write and close.

After a dropped connection, `mkdir`, `rmdir`, `deleteFile`, `rename`, `link` and `symlink` are not repeated. See [Errors and cancellation](https://pub.dev/documentation/dart_smb2/latest/topics/Errors%20and%20cancellation-topic.html).

### Renaming over an existing file

```dart
await pool.rename('Notes/todo.txt.new', 'Notes/todo.txt', overwrite: true);
```

`rename` fails with `alreadyExists` when the new name is taken. With `overwrite: true` an existing file is replaced in the same request, so readers find either the old file or the new one, never none: write to a temporary name, then rename over the real one. A directory is never replaced, and a file another client holds open is not replaced either (`accessDenied` or `inUse`).

### Trees

```dart
await pool.mkdir('Backup/2026/11', recursive: true);
await pool.rmdir('Backup/2025', recursive: true);
```

`mkdir(recursive: true)` creates the missing directories above the path too, and takes an existing directory as done, like `mkdir -p`. `rmdir(recursive: true)` lists the whole tree, then removes everything below the directory, like `rm -r`: files, links (never what they point at) and directories, as many at once as the pool has workers. At the first entry it cannot remove it starts no more removals, waits for those in flight and throws, leaving the rest. It refuses the share root (`''` or `/`) with an `ArgumentError`. Both are repeated after a dropped connection, since an entry already made, or already gone, is not a failure.

Samba follows symbolic links by default (`follow symlinks = yes`): a link to a directory, made on the server, looks like that directory, and SMB cannot remove it. The file ids of the listings (`Smb2Stat.fileId`) tell such a link apart, unless it lies in the same directory as its target. `streamDirectory` and `copyTree` list it, but enter it only when its target lies in the same directory and was not listed already. `rmdir(recursive: true)` fails with `notSupported` before removing anything when the tree holds such a link, or the path is one or has one beside it: remove those links on the server.

### Links

```dart
await pool.link('Music/a.flac', 'Favourites/a.flac');   // a hard link
await pool.symlink('../Music', 'Shortcuts/Music', directory: true);
final target = await pool.readlink('Shortcuts/Music');
```

A hard link is a second name for the same file, on the same share. A symbolic link stores its target as given: relative to the link's directory, or absolute when it starts with a separator or a drive letter. Pass `directory: true` for a link to a directory, which Windows types apart. Windows lets only administrators create symbolic links by default, and Samba keeps one only on a share that allows it; elsewhere `symlink` fails with `accessDenied` or `notSupported`.

## Copying

```dart
await pool.copy('Album/01.flac', 'Backup/01.flac',
    onProgress: (copied, total) => print('$copied / $total'));
await pool.copyTree('Album', 'Backup/Album', overwrite: true);
```

SMB2 has no copy that every server offers, so the data passes through your machine: `copy` streams the file as `streamFile` reads it and writes it to a temporary file next to the destination, which takes the destination's place once complete. Without `overwrite`, an existing destination fails with `alreadyExists` before any data is read. A failure or a cancellation removes the temporary file. `copyTree` lists the whole tree first, so its progress counts the bytes of every file, then creates the directories and copies the files one at a time. Symbolic links are skipped, and so are the links Samba follows that `streamDirectory` does not enter.

## Watching a directory

```dart
final sub = pool.watch('Inbox', recursive: true).listen((e) {
  if (e.action == Smb2ChangeAction.overflow) {
    reload(); // changes were lost: list again
  } else {
    print('${e.action.name} ${e.path}');
  }
});
// Later:
await sub.cancel();
```

The server reports each change to the directory (and with `recursive` to everything below it) as it happens: created, removed, modified, and renamed, as a `renamedFrom` then a `renamedTo` event. `filter` picks what counts as a change, as a mask of `Smb2ChangeFilter` bits (names, sizes and writes by default). Each event's `path` is share-relative.

The watch runs on a connection of its own, in an isolate of its own, so it takes no worker. After a dropped connection it reconnects by itself and sends an `overflow` event, since changes may have been missed; the server sends one too when changes come faster than it can report them. Any other failure ends the stream with an error: `notFound` for a missing directory, `notADirectory` for a file. Cancelling the subscription, the `cancelToken` or `disconnect` ends the watch. It waits for the request in flight and the logoff, which time out after 5 seconds each: up to about 15 seconds when the server stops answering. A paused subscription, as `await for` makes while its body runs, keeps the changes that arrive meanwhile in memory. While watched, the directory itself cannot be renamed or removed.
