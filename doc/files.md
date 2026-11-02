List directories, read metadata and manage files and directories on the share.

## Listing a directory

```dart
final entries = await pool.listDirectory('Album');
for (final e in entries) {
  print('${e.name} ${e.stat.modified} ${e.isFile ? e.size : '-'}');
}
```

The listing carries each entry's metadata, so no request per entry is needed. `.` and `..` are left out. `Smb2Stat.isHidden` reports the server's hidden attribute (Samba sets it on dot files by default).

## Stat, size and existence

```dart
final stat = await pool.stat('Album/01 - Intro.flac');
print('${stat.size} bytes, modified ${stat.modified}');

final size = await pool.fileSize('Album/01 - Intro.flac');
final there = await pool.exists('Album/booklet.pdf');
```

`Smb2Stat` holds the type, the size, the modified, created, accessed and changed times (UTC, to the microsecond) and the file attributes. `exists` returns `false` only for a missing path. Any other failure throws.

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

After a dropped connection, `mkdir`, `rmdir`, `deleteFile` and `rename` are not repeated. See [Errors and cancellation](https://pub.dev/documentation/dart_smb2/latest/topics/Errors%20and%20cancellation-topic.html).
