# dart_smb2

#### SMB2/3 client for Dart and Flutter.

[![](https://img.shields.io/pub/v/dart_smb2.svg?style=for-the-badge&logo=dart&logoColor=white)](https://pub.dev/packages/dart_smb2)
[![](https://img.shields.io/badge/libsmb2-r9-orange.svg?style=for-the-badge)](https://github.com/ales-drnz/libsmb2-scripts)
[![](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg?style=for-the-badge)](LICENSE)
[![](https://img.shields.io/github/stars/ales-drnz/dart_smb2?style=for-the-badge&logo=github&logoColor=white)](https://github.com/ales-drnz/dart_smb2)
[![](https://img.shields.io/discord/1485588004029333516?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/g2Qf4Mq9MP)
[![](https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/ales_drnz)
[![](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/ales.drnz)

<table>
<tr>
<td valign="middle" width="90"><img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/dart_smb2.png" width="70" alt="logo"></td>
<td valign="middle"><code>dart_smb2</code> is a Dart client for SMB2 and SMB3 file shares, built on libsmb2. It lists, reads, streams, downloads and writes files on Samba, Windows and NAS shares from worker isolates that reconnect on their own.</td>
</tr>
</table>

---

## Installation

Add `dart_smb2` to your `pubspec.yaml`:

```yaml
dependencies:
  dart_smb2: ^0.2.3
```

## Platform requirements

| Platform  | Minimum | Architecture | Size | Device | Emulator |
| :--- | :--- | :--- | :---: | :---: | :---:
| Android | 7.0 (SDK 24) | arm64-v8a, armeabi-v7a, x86_64 | 246, 233, 253 KB | Yes | Yes |
| iOS | 13.0 | arm64, x86_64 | 271, 235 KB | Yes | Yes |
| macOS | 10.15 | arm64, x86_64 | 257, 239 KB | Yes | - |
| Windows | 10 | arm64, x86_64 | 238, 256 KB | Yes | - |
| Linux | glibc 2.31 (Ubuntu 20.04, Debian 11) | aarch64, x86_64 | 259, 268 KB | Yes | - |

The package needs Dart 3.10, and Flutter 3.47 in a Flutter app. It is a plain Dart package: command-line tools and servers use it as well.

---

## Contents

*   [Features](#features)
*   [Quick start](#quick-start)
*   [Guide](#guide)
    <details>
    <summary><a href="#1-connection-and-lifecycle"><b>1. Connection and lifecycle</b></a></summary>

    * [1.1 Connecting a pool](#11-connecting-a-pool)
    * [1.2 Connection options](#12-connection-options)
    * [1.3 Listing the shares of a server](#13-listing-the-shares-of-a-server)
    * [1.4 Disconnecting](#14-disconnecting)

    </details>

    <details>
    <summary><a href="#2-paths"><b>2. Paths</b></a></summary>

    </details>

    <details>
    <summary><a href="#3-directories-and-metadata"><b>3. Directories and metadata</b></a></summary>

    * [3.1 Listing a directory](#31-listing-a-directory)
    * [3.2 Stat, size and existence](#32-stat-size-and-existence)
    * [3.3 Space on the share](#33-space-on-the-share)

    </details>

    <details>
    <summary><a href="#4-reading-files"><b>4. Reading files</b></a></summary>

    * [4.1 Whole files and ranges](#41-whole-files-and-ranges)
    * [4.2 A file open for several reads](#42-a-file-open-for-several-reads)
    * [4.3 Handles](#43-handles)

    </details>

    <details>
    <summary><a href="#5-streaming-and-downloads"><b>5. Streaming and downloads</b></a></summary>

    * [5.1 Streaming a file](#51-streaming-a-file)
    * [5.2 Downloading to disk](#52-downloading-to-disk)

    </details>

    <details>
    <summary><a href="#6-writing-files"><b>6. Writing files</b></a></summary>

    * [6.1 Whole files and ranges](#61-whole-files-and-ranges)
    * [6.2 Streaming a write](#62-streaming-a-write)
    * [6.3 Write handles](#63-write-handles)

    </details>

    <details>
    <summary><a href="#7-managing-files-and-directories"><b>7. Managing files and directories</b></a></summary>

    </details>

    <details>
    <summary><a href="#8-cancellation"><b>8. Cancellation</b></a></summary>

    </details>

    <details>
    <summary><a href="#9-errors-and-reconnects"><b>9. Errors and reconnects</b></a></summary>

    * [9.1 Error types](#91-error-types)
    * [9.2 Reconnects](#92-reconnects)

    </details>

    <details>
    <summary><a href="#10-the-synchronous-client"><b>10. The synchronous client</b></a></summary>

    </details>

*   [Permissions](#permissions)
*   [Project background](#project-background)

---

## Features

<table>
<tr>
<td valign="middle" width="48"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/package.png" width="32"></td>
<td valign="middle" width="45%"><b>Pure Dart</b><br>no Flutter plugin: a build hook bundles libsmb2 for Android, iOS, Linux, macOS and Windows, checked against pinned SHA-256s.</td>
<td valign="middle" width="48"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/layers.png" width="32"></td>
<td valign="middle" width="45%"><b>Worker isolates</b><br><a href="#11-connecting-a-pool"><code>Smb2Pool</code></a> runs one connection per isolate and sends each call to the least busy one; the UI isolate never waits on the network.</td>
</tr>
<tr>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/activity.png" width="32"></td>
<td valign="middle"><b>Reconnects</b><br>a dropped connection is <a href="#92-reconnects">reconnected once</a> for every caller, the call repeated when that is safe, and open files reopened.</td>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/download.png" width="32"></td>
<td valign="middle"><b>Streaming and downloads</b><br><a href="#51-streaming-a-file"><code>streamFile()</code></a> reads one chunk ahead; <a href="#52-downloading-to-disk"><code>downloadToFile()</code></a> writes at the disk's pace and renames into place only when complete.</td>
</tr>
<tr>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/zap.png" width="32"></td>
<td valign="middle"><b>Cancellation</b><br>every call on a connected pool but the closing ones takes an <a href="#8-cancellation"><code>Smb2CancelToken</code></a>, the same as dart_plex's and dart_jellyfin's.</td>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/triangle-alert.png" width="32"></td>
<td valign="middle"><b>Typed errors</b><br>every failure is a <a href="#91-error-types"><code>Smb2Exception</code></a> classified from the server's NT status: auth, not found, network, transient, cancelled.</td>
</tr>
<tr>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/cpu.png" width="32"></td>
<td valign="middle"><b>No extra copies</b><br>reads land in native buffers that reach your isolate without a copy.</td>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/key-round.png" width="32"></td>
<td valign="middle"><b>SMB3 security</b><br>NTLM sign-in, <a href="#12-connection-options">encryption and signing</a>, and the dialect you choose, up to SMB 3.1.1.</td>
</tr>
<tr>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/folder.png" width="32"></td>
<td valign="middle"><b>Files and directories</b><br>listings with metadata, ranges, handles, writes, renames, timestamps, share space and share enumeration.</td>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/terminal.png" width="32"></td>
<td valign="middle"><b>Synchronous client</b><br><a href="#10-the-synchronous-client"><code>Smb2Client</code></a>, the client the workers run, for code that manages its own isolates.</td>
</tr>
</table>

---

## Quick start

```dart
import 'package:dart_smb2/dart_smb2.dart';

Future<void> main() async {
  final pool = await Smb2Pool.connect(
    host: '192.168.1.10',
    share: 'Music',
    user: 'alice',
    password: 'secret',
  );
  try {
    // List the share's root.
    for (final entry in await pool.listDirectory('')) {
      print('${entry.name}  ${entry.isDirectory ? 'dir' : '${entry.size} B'}');
    }

    // Read a small file whole.
    final cover = await pool.readFile('Album/cover.jpg');
    print('cover: ${cover.length} bytes');

    // Download a large one to disk.
    final bytes = await pool.downloadToFile(
      'Album/01 - Intro.flac',
      '/tmp/intro.flac',
      onProgress: (received, total) => print('$received / $total'),
    );
    print('downloaded $bytes bytes');
  } on Smb2Exception catch (e) {
    print('SMB error: ${e.type.name}: ${e.message}');
  } finally {
    await pool.disconnect();
  }
}
```

---

## Guide

`Smb2Pool` is the entry point. It runs a few worker isolates, each with its own connection to the share and its own `Smb2Client`, the synchronous client over libsmb2. Your code calls the pool from any isolate; each call goes to the least busy worker and its result comes back without blocking the caller.

<img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/diagrams/architecture.png" width="100%" alt="Architecture: your code calls Smb2Pool, which sends each request to one of its worker isolates; each worker runs an Smb2Client over a libsmb2 context of its own and holds a connection to the SMB server">

### 1. Connection and lifecycle

<img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/diagrams/pool_lifecycle.png" width="100%" alt="Pool lifecycle: Smb2Pool.connect, calls, withFile and streamFile, disconnect">

#### 1.1 Connecting a pool

```dart
final pool = await Smb2Pool.connect(
  host: 'nas.local',
  share: 'Music',
  user: 'alice',
  password: 'secret',
  workers: 4,
);
```

The workers connect in parallel. When one of them cannot, the others are closed and `connect` throws that worker's `Smb2Exception`: `auth` for wrong credentials, `notFound` for a share that does not exist, a network failure for a host that does not answer.

#### 1.2 Connection options

| Argument | Default | Description |
| :--- | :--- | :--- |
| `user`, `password`, `domain` | none | NTLM credentials. No user, or a null password, means an anonymous logon; `password: ''` logs on to an account without a password |
| `workers` | 4 | Isolates, each with its own connection |
| `timeout` | 30 s | Bounds every request, the connection included |
| `seal` | `false` | Require SMB3 encryption |
| `signing` | `false` | Require signed messages |
| `version` | `Smb2Version.any` | The dialect to negotiate, from `v202` to `v311` |

```dart
final secure = await Smb2Pool.connect(
  host: 'nas.local',
  share: 'Private',
  user: 'alice',
  password: 'secret',
  seal: true,
  version: Smb2Version.v311,
  timeout: const Duration(seconds: 10),
);
```

#### 1.3 Listing the shares of a server

`listSharesOn` needs no pool: it connects to `IPC$` from a short-lived isolate, lists the shares and disconnects.

```dart
final shares = await Smb2Pool.listSharesOn(
  host: 'nas.local',
  user: 'alice',
  password: 'secret',
);
for (final share in shares.where((s) => s.isDisk && !s.isHidden)) {
  print('${share.name}  ${share.remark}');
}
```

#### 1.4 Disconnecting

```dart
await pool.disconnect();
```

Each worker finishes the requests it has already been sent, closes its open files and logs off, and its isolate ends; a worker that does not finish within 5 seconds is killed. A reconnect in progress is aborted, and later calls fail with a `state` error.

### 2. Paths

Paths are relative to the share: `''` is its root, `Album/cover.jpg` a file in it. A leading slash is dropped and backslashes become slashes, so `/Album\cover.jpg` names the same file. A path with a NUL character fails with `invalidParam` before it reaches the server.

### 3. Directories and metadata

#### 3.1 Listing a directory

```dart
final entries = await pool.listDirectory('Album');
for (final e in entries) {
  print('${e.name} ${e.stat.modified} ${e.isFile ? e.size : '-'}');
}
```

The listing carries each entry's metadata, so no request per entry is needed. `.` and `..` are left out. `Smb2Stat.isHidden` reports the server's hidden attribute (Samba sets it on dot files by default).

#### 3.2 Stat, size and existence

```dart
final stat = await pool.stat('Album/01 - Intro.flac');
print('${stat.size} bytes, modified ${stat.modified}');

final size = await pool.fileSize('Album/01 - Intro.flac');
final there = await pool.exists('Album/booklet.pdf');
```

`Smb2Stat` holds the type, the size, the modified, created, accessed and changed times (UTC, to the microsecond) and the file attributes. `exists` returns `false` only for a missing path; any other failure throws.

#### 3.3 Space on the share

```dart
final vfs = await pool.statvfs('');
print('${vfs.availableSize} of ${vfs.totalSize} bytes free');
```

### 4. Reading files

#### 4.1 Whole files and ranges

```dart
final cover = await pool.readFile('Album/cover.jpg');
final header = await pool.readFileRange(
  'Album/01 - Intro.flac',
  length: 64 * 1024,
);
```

A range returns fewer bytes than asked only when the file ends first. Reads larger than what the server accepts in one request are split for you.

#### 4.2 A file open for several reads

`withFile` opens a file once, hands it to your callback and closes it on every exit path.

```dart
final tag = await pool.withFile('Album/01 - Intro.flac', (file) async {
  final head = await file.read(length: 10);
  final tail = await file.read(offset: file.size - 128, length: 128);
  return (head, tail);
});
```

Pass `knownSize` when a listing already gave the size: the open then skips the size request.

#### 4.3 Handles

For files that stay open across calls, open a handle and close it yourself.

```dart
final (handle, size) = await pool.openFileWithSize('Album/01 - Intro.flac');
try {
  final first = await pool.readFromHandle(handle, length: 4096);
  final last = await pool.readFromHandle(handle, offset: size - 4096, length: 4096);
} finally {
  await pool.closeHandle(handle);
}
```

A handle stays on the worker that opened it. If that worker reconnects, the handle is opened again before its next call. Closing a handle twice does nothing; any other use of a closed handle throws a `state` error. A handle dropped without being closed is closed when it is garbage collected.

### 5. Streaming and downloads

<img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/diagrams/streaming.png" width="100%" alt="Streaming: the worker reads the next chunk while your isolate writes the current one to a part file, which is renamed to the destination at the end">

#### 5.1 Streaming a file

```dart
final stream = pool.streamFile(
  'Album/01 - Intro.flac',
  onProgress: (received, total) => print('$received / $total'),
);
await for (final chunk in stream) {
  print('${chunk.length} bytes');
}
```

The stream keeps one file handle open and reads the next chunk while you handle the current one. It waits while its listener is paused, so at most two chunks (4 MiB each by default, see `chunkSize`) are in memory. Cancelling the subscription or the token closes the handle.

#### 5.2 Downloading to disk

```dart
final written = await pool.downloadToFile(
  'Album/01 - Intro.flac',
  '/storage/music/01 - Intro.flac',
  onProgress: (received, total) => print('${received * 100 ~/ total}%'),
);
```

The data goes to a temporary file next to the destination as it arrives, at the pace the disk takes it, and is renamed to the destination only once complete. A failure or a cancellation removes the temporary file and leaves the destination as it was.

### 6. Writing files

#### 6.1 Whole files and ranges

```dart
await pool.writeFile('Notes/todo.txt', utf8.encode('buy milk\n'));
await pool.writeFileRange('Notes/todo.txt', utf8.encode('eggs\n'), offset: 9);
```

`writeFile` replaces the file, creating it if needed; `writeFileRange` writes at an offset and leaves the rest of the file as it is. The data is copied into a native buffer in the calling isolate: for large writes from the UI isolate, prefer `streamWrite`.

#### 6.2 Streaming a write

```dart
final upload = File('/storage/music/01 - Intro.flac')
    .openRead()
    .map(Uint8List.fromList);
await pool.streamWrite('Backup/01 - Intro.flac', upload);
```

The chunks go through one handle, each at its own offset, so only one is in memory at a time and a reconnect repeats just the chunk that failed.

#### 6.3 Write handles

```dart
final out = await pool.openFileWrite('Backup/log.bin', truncate: true);
try {
  await pool.writeToHandle(out, Uint8List.fromList([1, 2, 3]));
  await pool.writeToHandle(out, Uint8List.fromList([4]), offset: 3);
  await pool.fsyncHandle(out);
} finally {
  await pool.closeHandle(out);
}
```

`ftruncateHandle` cuts or extends the file of a handle.

### 7. Managing files and directories

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

`rmdir` fails with `notEmpty` while the directory has entries and with `notADirectory` on a file; `deleteFile` fails with `isADirectory` on a directory, or a link to one, which `rmdir` removes. Set times after the file's write handles are closed: the server refreshes the modified time on write and close.

### 8. Cancellation

Every call on a connected pool takes an `Smb2CancelToken`, except `closeHandle` and `disconnect`. A cancelled call throws an `Smb2Exception` of type `cancelled` at once, also while it waits for a reconnect; a request the worker already sent finishes on the server and its result is dropped, and a file it opened is closed.

```dart
final token = Smb2CancelToken();
final download = pool.downloadToFile(
  'Album/01 - Intro.flac',
  '/tmp/intro.flac',
  cancelToken: token,
);

// The user pressed stop:
token.cancel();

try {
  await download;
} on Smb2Exception catch (e) {
  if (!e.isCancelled) rethrow;
}
```

One token cancels any number of calls, once. Make a new token for the next page, folder or download.

### 9. Errors and reconnects

#### 9.1 Error types

Every failure is an `Smb2Exception`. Its `type` comes from the NT status the server answered with, from the errno libsmb2 reported, or from a transport failure, and reads the same on every platform.

| Type | Meaning |
| :--- | :--- |
| `connection` | The connection failed or was lost, the host name does not resolve, or the server dropped the session or a handle |
| `timeout` | The server did not answer within the timeout |
| `auth` | Wrong credentials, or the account cannot log on |
| `notFound` | The path or the share does not exist |
| `accessDenied` | No permission for the operation |
| `notADirectory`, `isADirectory` | A file where a directory was expected, or the opposite |
| `alreadyExists`, `notEmpty` | The target exists; the directory has entries |
| `inUse` | Another client holds the file open or locked, or the server is out of resources for the moment |
| `diskFull` | Out of space or over quota |
| `io`, `invalidParam`, `notSupported` | Read/write failure, bad argument, unsupported operation |
| `state` | Closed pool, closed handle, client not connected |
| `cancelled` | Cancelled through an `Smb2CancelToken` |
| `unknown` | Anything else |

The predicates group them the way dart_plex and dart_jellyfin do:

```dart
try {
  await pool.listDirectory('Album');
} on Smb2Exception catch (e) {
  if (e.isAuthError) {
    print('ask for the password again');
  } else if (e.isNotFound) {
    print('gone');
  } else if (e.isTransient) {
    print('try again later');
  } else if (!e.isCancelled) {
    print('${e.type.name}: ${e.message}');
  }
}
```

`isNetworkFailure` covers `connection` and `timeout`; `isTransient` adds `inUse`. `ntStatus` and `errno` keep the raw codes.

#### 9.2 Reconnects

<img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/diagrams/reconnect.png" width="100%" alt="A reconnect: the worker loses the connection, the pool spawns and connects a new worker and sends the call again, and the result reaches your code">

When a call fails with a network failure, the pool replaces the worker with a new connection — once, however many calls saw it fail — and repeats the call when repeating cannot change the outcome: reads, listings, metadata, writes at an offset, whole-file writes, truncates and timestamps. `mkdir`, `rmdir`, `deleteFile` and `rename` are not repeated, because the server may have done them before the connection dropped; their error reaches you and the next call uses the new connection. Open handles are reopened on the new worker before their next call. While a worker cannot reconnect, the others take its calls and it keeps trying in the background; after a refused login, once every 5 minutes.

### 10. The synchronous client

`Smb2Client` is the client each worker runs. Every call blocks until the server answers, so use it from an isolate of your own.

```dart
final summary = await Isolate.run(() {
  final client = Smb2Client()
    ..connect(host: 'nas.local', share: 'Music', user: 'alice', password: 'secret');
  try {
    final entries = client.listDirectory('');
    return '${entries.length} entries, ${client.maxReadSize} B per read';
  } finally {
    client.disconnect();
  }
});
```

It has the pool's methods, without the `Future`s and the cancel tokens: `openFile`, `readFromHandle`, `writeToHandle`, `closeHandle` and so on, plus `readFileChunked` and `writeFileChunked` over iterables. `Smb2Client.listShares` is static and needs no connection. A client dropped without `disconnect()` frees its connection when it is garbage collected, without a logoff.

---

## Permissions

### Android

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

### macOS

Add to `DebugProfile.entitlements` and `Release.entitlements`:

```xml
<key>com.apple.security.network.client</key>
<true/>
```

---

## Project background

I wrote the bindings, the client, the pool and the build hook with Claude Code. The native library is [libsmb2](https://github.com/sahlberg/libsmb2) by Ronnie Sahlberg, licensed under the LGPL-2.1: see [NOTICE](NOTICE) for what an app that bundles it should include.

Samba is a trademark of the Software Freedom Conservancy, and Windows a trademark of Microsoft. dart_smb2 is not affiliated with either.

---

*Developed by Alessandro Di Ronza*
