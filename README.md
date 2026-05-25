# dart_smb2

#### SMB2/3 client for Dart & Flutter.

[![](https://img.shields.io/pub/v/dart_smb2.svg?style=for-the-badge&logo=dart&logoColor=white)](https://pub.dev/packages/dart_smb2)
[![](https://img.shields.io/badge/libsmb2-v6.1.0-orange.svg?style=for-the-badge)](https://github.com/sahlberg/libsmb2)
[![](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg?style=for-the-badge)](LICENSE)
[![](https://img.shields.io/github/stars/ales-drnz/dart_smb2?style=for-the-badge&logo=github&logoColor=white)](https://github.com/ales-drnz/dart_smb2)
[![](https://img.shields.io/discord/1491115396663869470?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/g2Qf4Mq9MP)
[![](https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/ales_drnz)
[![](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/ales.drnz)

<table>
<tr>
<td valign="middle" width="90"><img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/dart_smb2.png" width="70" alt="logo"></td>
<td valign="middle"><code>dart_smb2</code> is a Dart client for SMB2/3 file shares built on libsmb2 <code>v6.1.0</code>. It provides a streaming API for reading, writing and managing files over the network across desktop and mobile.</td>
</tr>
</table>

---

## Installation

Add `dart_smb2` to your `pubspec.yaml`:

```yaml
dependencies:
  dart_smb2: ^0.0.8
```

---

## Platforms

| Platform  | Minimum | Architecture | Device | Emulator |
| :--- | :--- | :--- | :---: | :---:
| **Android** | 7.0 (SDK 24) | arm64-v8a, armeabi-v7a, x86_64 | ✅ | ✅ |
| **iOS** | 15.0 | arm64, x86_64 | ✅ | ✅ |
| **macOS** | 12.0 | arm64, x86_64 | ✅ | – |
| **Windows**| 10 | arm64, x86_64 | ✅ | – |
| **Linux** | Ubuntu 24.04 | aarch64, x86_64 | ✅ | – |

---

## Contents

*   [Visuals](#visuals)
*   [Features](#features)
*   [Quick Start](#quick-start)
*   [Guide](#guide)
    <details>
    <summary><a href="#1-connection--lifecycle"><b>1. Connection & Lifecycle</b></a></summary>

    * [1.1 Sync Client](#11-sync-client)
    * [1.2 Worker Pool](#12-worker-pool)
    * [1.3 Cached Pool](#13-cached-pool)
    * [1.4 Disconnecting](#14-disconnecting)
    * [1.5 Security Options](#15-security-options)

    </details>

    <details>
    <summary><a href="#2-path-format"><b>2. Path Format</b></a></summary>
    </details>

    <details>
    <summary><a href="#3-directory-listing"><b>3. Directory Listing</b></a></summary>
    </details>

    <details>
    <summary><a href="#4-file-metadata"><b>4. File Metadata</b></a></summary>

    * [4.1 Stat](#41-stat)
    * [4.2 File Size](#42-file-size)
    * [4.3 Exists](#43-exists)
    * [4.4 Filesystem Info (statvfs)](#44-filesystem-info-statvfs)
    * [4.5 Read Symlink](#45-read-symlink)
    * [4.6 Connection Health (echo)](#46-connection-health-echo)

    </details>

    <details>
    <summary><a href="#5-reading-files"><b>5. Reading Files</b></a></summary>

    * [5.1 Read Entire File](#51-read-entire-file)
    * [5.2 Partial Read (Byte Range)](#52-partial-read-byte-range)
    * [5.3 Scoped File Access (withFile)](#53-scoped-file-access-withfile)
    * [5.4 Streaming (Chunked)](#54-streaming-chunked)
    * [5.5 Download to File](#55-download-to-file)
    * [5.6 Low-Level File Handles](#56-low-level-file-handles)

    </details>

    <details>
    <summary><a href="#6-writing-files"><b>6. Writing Files</b></a></summary>

    * [6.1 Write Entire File](#61-write-entire-file)
    * [6.2 Partial Write (Byte Range)](#62-partial-write-byte-range)
    * [6.3 Streaming Write (Chunked)](#63-streaming-write-chunked)
    * [6.4 File Handles (Write)](#64-file-handles-write)
    * [6.5 Flush (fsync)](#65-flush-fsync)
    * [6.6 Truncate Handle (ftruncate)](#66-truncate-handle-ftruncate)

    </details>

    <details>
    <summary><a href="#7-file--directory-management"><b>7. File & Directory Management</b></a></summary>

    * [7.1 Create Directory](#71-create-directory)
    * [7.2 Delete File](#72-delete-file)
    * [7.3 Delete Directory](#73-delete-directory)
    * [7.4 Rename / Move](#74-rename--move)
    * [7.5 Truncate](#75-truncate)

    </details>

    <details>
    <summary><a href="#8-share-enumeration"><b>8. Share Enumeration</b></a></summary>
    </details>

    <details>
    <summary><a href="#9-caching"><b>9. Caching</b></a></summary>
    </details>

    <details>
    <summary><a href="#10-error-handling"><b>10. Error Handling</b></a></summary>

    * [10.1 Smb2Exception](#101-smb2exception)
    * [10.2 Error Types](#102-error-types)

    </details>

*   [Types Reference](#types-reference)
*   [Permissions](#permissions)
*   [Project background](#project-background)

---

## Visuals

The following images demonstrate the example app included in the `example/` directory. This application serves as a reference client for testing the various features and capabilities of dart_smb2.

<table width="100%">
  <tr>
    <td width="25%"><img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/mobile_servers.png" width="100%"></td>
    <td width="25%" align="left"><b>Servers</b><br>Manage saved connections</td>
    <td width="25%"><img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/mobile_browse.png" width="100%"></td>
    <td width="25%" align="left"><b>Browse</b><br>Tree explorer</td>
  </tr>
  <tr>
    <td width="25%"><img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/mobile_read.png" width="100%"></td>
    <td width="25%" align="left"><b>Read</b><br>Reading performance test</td>
    <td width="25%"><img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/mobile_write.png" width="100%"></td>
    <td width="25%" align="left"><b>Write</b><br>Writing performance test</td>
  </tr>
</table>

---

## Features

<table>
<tr>
<td valign="middle" width="48"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/package.png" width="32"></td>
<td valign="middle" width="45%"><b>Pure Dart FFI</b><br>synchronous bindings to libsmb2 via <code>dart:ffi</code>, with native binaries bundled for every supported platform.</td>
<td valign="middle" width="48"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/globe.png" width="32"></td>
<td valign="middle" width="45%"><b>Cross-platform</b><br>runs on macOS, Windows, Linux, iOS and Android — same API on every host.</td>
</tr>
<tr>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/file-code.png" width="32"></td>
<td valign="middle"><b>SMB 2.02 → 3.1.1</b><br>full protocol coverage including encryption (<code>seal</code>), signing and version pinning via <code>Smb2Version</code>.</td>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/wrench.png" width="32"></td>
<td valign="middle"><b>Worker pool</b><br><code>Smb2Pool</code> spreads requests across N isolate workers and reconnects transparently when a connection drops.</td>
</tr>
<tr>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/folder.png" width="32"></td>
<td valign="middle"><b>File & directory ops</b><br><code>listDirectory</code>, <code>stat</code>, <code>exists</code>, <code>mkdir</code>, <code>rmdir</code>, <code>rename</code>, <code>deleteFile</code>, <code>truncate</code> and symlink resolution.</td>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/download.png" width="32"></td>
<td valign="middle"><b>Streaming reads & writes</b><br>chunked I/O via sync <code>Iterable</code> or async <code>Stream</code>, with <code>onProgress</code> + <code>isCanceled</code> callbacks and a single persistent handle.</td>
</tr>
<tr>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/shield-check.png" width="32"></td>
<td valign="middle"><b>Safe handles</b><br><code>withFile(path, body)</code> opens a handle, runs your callback and guarantees <code>closeHandle</code> on any exit path. A <code>Finalizer</code> closes leaked handles as a safety net.</td>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/hard-drive.png" width="32"></td>
<td valign="middle"><b>Filesystem info</b><br><code>statvfs</code> for free/total disk space, <code>listShares</code> for share enumeration, <code>echo</code> for keepalive ping.</td>
</tr>
<tr>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/layers.png" width="32"></td>
<td valign="middle"><b>Cached reads</b><br><code>CachedSmb2Pool</code> wraps the pool with a TTL cache for <code>stat</code> and <code>listDirectory</code> calls, with automatic invalidation on writes.</td>
<td valign="middle"><img src="https://raw.githubusercontent.com/ales-drnz/svg-icons/main/png/triangle-alert.png" width="32"></td>
<td valign="middle"><b>Semantic errors</b><br>one <code>Smb2Exception</code> hierarchy with <code>Smb2ErrorType</code> enum (<code>auth</code>, <code>fileNotFound</code>, <code>connection</code>, <code>alreadyExists</code>, …), never raw NTSTATUS codes in your code.</td>
</tr>
</table>

---

## Quick Start

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:dart_smb2/dart_smb2.dart';

void main() async {
  // Connect the worker pool (auto-reconnect on connection errors)
  final pool = await Smb2Pool.connect(
    host: '192.168.1.100',
    share: 'Files',
    user: 'user',
    password: 'pass',
  );

  // List a directory
  final entries = await pool.listDirectory('Documents/Projects');
  for (final entry in entries) {
    print('${entry.name} — ${entry.size} bytes');
  }

  // Read the first 256 KB of a file
  final header = await pool.readFileRange(
    'Documents/report.pdf',
    length: 256 * 1024,
  );

  // Download a file to disk with progress + cancel
  await pool.downloadToFile(
    'Music/song.flac',
    File('/tmp/song.flac'),
    onProgress: (received, total) =>
        print('${(received / total * 100).toStringAsFixed(1)}%'),
  );

  // Read on-demand with a scoped handle (auto-closed)
  final tags = await pool.withFile('Music/song.flac', (file) async {
    final header = await file.read(length: 64 * 1024);
    return parseTags(header); // your code
  });

  // Write a file
  await pool.writeFile(
    'Documents/notes.txt',
    Uint8List.fromList('Hello SMB!'.codeUnits),
  );

  // Create a directory
  await pool.mkdir('Documents/NewFolder');

  // Get file info
  final info = await pool.stat('Documents/report.pdf');
  print('Size: ${info.size}, Modified: ${info.modified}');

  await pool.disconnect();
}
```

---

## Guide

### 1. Connection & Lifecycle

`dart_smb2` offers three layers of abstraction. Pick the highest one that fits your use case — `Smb2Pool` is the recommended default.

| Layer | Class | Best for |
| :--- | :--- | :--- |
| Sync FFI | `Smb2Client` | Scripts, background isolates, maximum control |
| Worker Pool | `Smb2Pool` | **Default**. Async, multi-worker, auto-reconnect, scope-based file helpers |
| Cached Pool | `CachedSmb2Pool` | Repeated `stat`/`listDirectory` calls with TTL |

#### 1.1 Sync Client

The core layer. All operations are blocking — run it in an isolate to avoid blocking the UI thread. The bundled native library loads automatically on every supported platform — no path configuration required.

```dart
final client = Smb2Client.open();

client.connect(
  host: '192.168.1.100',
  share: 'Files',
  user: 'user',
  password: 'pass',
  domain: 'WORKGROUP',      // optional, defaults to empty
  timeoutSeconds: 30,       // optional, defaults to 30
);

// ... use the client ...

client.disconnect();
```

#### 1.2 Worker Pool

Spawns N isolate workers connected to the same share. Operations are dispatched round-robin. If a worker loses connection, it automatically reconnects and retries the operation.

For single-connection use cases (the old `Smb2Isolate`), set `workers: 1` — you get the same single-connection semantics plus automatic reconnect.

```dart
final pool = await Smb2Pool.connect(
  host: '192.168.1.100',
  share: 'Files',
  user: 'user',
  password: 'pass',
  workers: 4,              // default: 4
  timeoutSeconds: 30,
);

print('Active workers: ${pool.workerCount}');

final entries = await pool.listDirectory('');
await pool.disconnect();
```

#### 1.3 Cached Pool

Wraps an `Smb2Pool` with an in-memory TTL cache for `stat` and `listDirectory`. All other operations pass through directly.

```dart
final pool = await Smb2Pool.connect(
  host: '192.168.1.100',
  share: 'Files',
  user: 'user',
  password: 'pass',
);

final cached = CachedSmb2Pool(pool, ttl: Duration(seconds: 30));

// First call hits the network
final entries = await cached.listDirectory('Documents/Projects');

// Second call within 30s returns from cache
final same = await cached.listDirectory('Documents/Projects');

// Manually invalidate
cached.invalidate('Documents/Projects');

// Clear everything
cached.clearCache();

await cached.disconnect();
```

#### 1.4 Disconnecting

Always disconnect when done. This releases the native SMB2 context and kills any spawned isolates.

```dart
client.disconnect();          // Smb2Client (sync)
await pool.disconnect();      // Smb2Pool
await cached.disconnect();    // CachedSmb2Pool
```

#### 1.5 Security Options

All `connect` methods accept optional security parameters:

```dart
final pool = await Smb2Pool.connect(
  host: '192.168.1.100',
  share: 'Files',
  user: 'user',
  password: 'pass',
  seal: true,                    // encrypt all traffic (SMB 3.0+)
  signing: true,                 // require message signing
  version: Smb2Version.any3,     // only accept SMB 3.x
);
```

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `seal` | `false` | Enable SMB3 encryption. All traffic is encrypted on the wire. Requires SMB 3.0 or later — the connection fails if the server only supports SMB 2.x. |
| `signing` | `false` | Require message signing. Prevents tampering. Works with all SMB versions. The client will always sign if the server requires it, regardless of this setting. |
| `version` | `Smb2Version.any` | Protocol version to negotiate. Default lets the server pick the highest mutually supported version. Use `any3` to enforce SMB 3.x (required for encryption). |

**Available versions:**

| `Smb2Version` | Protocol | Encryption support |
| :--- | :--- | :---: |
| `any` | Best available (default) | Depends on negotiated version |
| `any2` | Any SMB 2.x | No |
| `any3` | Any SMB 3.x | Yes |
| `v202` | SMB 2.0.2 | No |
| `v210` | SMB 2.1 | No |
| `v300` | SMB 3.0 | Yes |
| `v302` | SMB 3.0.2 | Yes |
| `v311` | SMB 3.1.1 (most secure) | Yes |

> **Note:** When `seal: true` is set, the connection will fail if the server does not support SMB 3.0+. This is by design — silent fallback to unencrypted would be a security violation.

---

### 2. Path Format

Paths are **relative to the share root**. Use an empty string `''` for the root directory — not `/`.

```dart
pool.listDirectory('');                          // share root
pool.listDirectory('Documents');                 // subfolder
pool.listDirectory('Documents/Projects');        // nested subfolder
pool.stat('Documents/report.pdf');               // file in subfolder
pool.writeFile('Documents/notes.txt', data);     // write to subfolder
pool.mkdir('Documents/NewFolder');               // create in subfolder
pool.rename('Documents/a.txt', 'Archive/a.txt'); // move between folders
```

---

### 3. Directory Listing

Returns all entries in a directory with full metadata (name, type, size, timestamps) — no additional per-entry round-trips. The `.` and `..` entries are automatically filtered out.

```dart
final entries = await pool.listDirectory('Documents/Projects');

for (final entry in entries) {
  final icon = entry.isDirectory ? '📁' : '📄';
  print('$icon ${entry.name}  ${entry.size} bytes  ${entry.stat.modified}');
}
```

Each entry is an `Smb2DirEntry`:

| Property | Type | Description |
| :--- | :--- | :--- |
| `name` | `String` | Entry name (not full path) |
| `stat` | `Smb2Stat` | Full metadata (type, size, modified, created) |
| `isDirectory` | `bool` | Shorthand for `stat.type == directory` |
| `isFile` | `bool` | Shorthand for `stat.type == file` |
| `size` | `int` | Shorthand for `stat.size` |

---

### 4. File Metadata

#### 4.1 Stat

Returns file metadata via an SMB2 compound request (Create + QueryInfo + Close in a single round-trip).

```dart
final info = await pool.stat('Documents/report.pdf');

print('Type: ${info.type}');          // Smb2FileType.file
print('Size: ${info.size}');          // bytes
print('Modified: ${info.modified}');  // DateTime
print('Created: ${info.created}');    // DateTime
print('Is file: ${info.isFile}');     // bool
print('Is dir: ${info.isDirectory}'); // bool
```

#### 4.2 File Size

Shortcut to get just the file size.

```dart
final size = await pool.fileSize('Documents/report.pdf');
print('$size bytes');
```

#### 4.3 Exists

Check whether a file or directory exists without reading it. Returns `false` for non-existent paths; throws on connection or permission errors.

```dart
// Sync
if (client.exists('Documents/report.pdf')) {
  print('File exists');
}

// Async
if (await pool.exists('Documents/report.pdf')) {
  print('File exists');
}
```

#### 4.4 Filesystem Info (statvfs)

Query total and free disk space on the share.

```dart
// Sync
final vfs = client.statvfs('');
print('Total: ${vfs.totalSize} bytes');
print('Free: ${vfs.freeSize} bytes');
print('Available: ${vfs.availableSize} bytes');

// Async
final vfs = await pool.statvfs('');
```

Returns an `Smb2StatVfs` with convenience getters `totalSize`, `freeSize`, and `availableSize` (in bytes).

#### 4.5 Read Symlink

Read the target path of a symbolic link.

```dart
// Sync
final target = client.readlink('Documents/shortcut');

// Async
final target = await pool.readlink('Documents/shortcut');
```

Throws `Smb2Exception` if the path is not a symlink.

#### 4.6 Connection Health (echo)

Send a keepalive ping to the server. Returns normally if the connection is alive; throws on failure.

```dart
// Sync
client.echo();

// Async
await pool.echo();
```

Useful for detecting disconnections early during idle periods.

---

### 5. Reading Files

#### 5.1 Read Entire File

Loads the entire file into memory.

```dart
final bytes = await pool.readFile('Documents/report.pdf');
```

#### 5.2 Partial Read (Byte Range)

Reads N bytes starting at an offset. Ideal for reading partial content without downloading the entire file.

```dart
// Read first 256 KB of a file
final header = await pool.readFileRange(
  'Documents/report.pdf',
  offset: 0,           // default: 0
  length: 256 * 1024,
);
```

#### 5.3 Scoped File Access (withFile)

Opens a file for reading, runs your callback with a scoped [`Smb2File`], and **guarantees the handle is closed** on any exit path — including exceptions, early returns, and cancellation.

This is the recommended way to read a file when you need more than a single one-shot read (e.g. parsing metadata that may need ranged fallback reads).

```dart
final tags = await pool.withFile('Music/song.flac', (file) async {
  print('File is ${file.size} bytes');

  // Initial header read — typically enough for most tag formats.
  final header = await file.read(length: 64 * 1024);

  // Some tag formats need bytes beyond the header (e.g. Vorbis comments
  // stored at arbitrary offsets). Expose `file.read` as a fallback reader
  // and only fetch more bytes when the parser actually needs them.
  return parseVorbisComments(
    header,
    fileSize: file.size,
    fallbackRead: (offset, length) => file.read(offset: offset, length: length),
  );
});
```

If you already know the file size from a prior `stat` or directory listing, pass it via `knownSize` to skip the `fstat` round-trip:

```dart
final stat = await pool.stat('Music/song.flac');
await pool.withFile(
  'Music/song.flac',
  (file) async { /* … */ },
  knownSize: stat.size,
);
```

#### 5.4 Streaming (Chunked)

Reads a file in chunks via a **single persistent handle** (one `Create` + N `Read` + one `Close` on the wire), with optional progress and cancellation callbacks.

**Sync (Smb2Client):**

```dart
for (final chunk in client.readFileChunked('data/large_file.bin', chunkSize: 1024 * 1024)) {
  sink.add(chunk);
}
```

**Async (Smb2Pool / CachedSmb2Pool):**

```dart
bool canceled = false;

await for (final chunk in pool.streamFile(
  'data/large_file.bin',
  chunkSize: 1024 * 1024,
  onProgress: (received, total) {
    print('${(received / total * 100).toStringAsFixed(1)}% '
          '($received / $total bytes)');
  },
  isCanceled: () => canceled,
)) {
  sink.add(chunk);
}
```

| Parameter | Default | Description |
| :--- | :--- | :--- |
| `chunkSize` | `1 MiB` | Dart-side buffer per iteration. Network-level chunking is automatic (libsmb2 splits into server-negotiated `MaxReadSize` packets, typically 1 MiB). |
| `onProgress` | — | Called after each chunk with `(received, total)` byte counts. |
| `isCanceled` | — | Polled after each chunk. Returning `true` aborts the stream with `Smb2Exception`. |

The handle is closed automatically when the stream completes, errors, or the listener cancels its subscription.

#### 5.5 Download to File

One-call convenience that streams an SMB file to a local `File` via [`streamFile`]. Equivalent to streaming and piping to `File.openWrite()`, with `onProgress` and `isCanceled` wired through.

```dart
import 'dart:io';

await pool.downloadToFile(
  'Music/song.flac',
  File('/tmp/song.flac'),
  onProgress: (received, total) {
    print('${(received / total * 100).toStringAsFixed(1)}%');
  },
  isCanceled: () => userHitCancelButton,
);
```

> **Atomicity:** if the download is canceled or errors, the destination file is left as-is (truncated or partially written). For safe replacement of an existing file, write to `dest.part` and rename on success.

#### 5.6 Low-Level File Handles

When you need finer control than `withFile` provides — e.g. a handle that outlives a single scope, or reusing a handle across multiple independent reads — the raw open/close primitives are still available.

> **Prefer `withFile`, `streamFile`, or `downloadToFile`** whenever you can. They are safer (guaranteed cleanup) and more efficient (persistent handle). Reach for the raw API only when those don't fit.

**Sync (Smb2Client):**

```dart
final handle = client.openFileHandle('data/file.bin');

final start = client.readHandle(handle, offset: 0, length: 4096);
final mid   = client.readHandle(handle, offset: 100000, length: 4096);

client.closeHandle(handle);
```

**With size (Smb2Client):**

```dart
final (handle, size) = client.openFileWithSize('data/file.bin');
print('File is $size bytes');

// ... read from handle ...

client.closeHandle(handle);
```

**Pool (auto-reconnect on failure):**

```dart
final (handle, size) = await pool.openFileWithSize('data/file.bin');

try {
  final data = await pool.readFromHandle(handle, offset: 0, length: size);
  // ...
} finally {
  await pool.closeHandle(handle);
}
```

If the connection drops during a read, the pool automatically reconnects the worker and reopens the file handle before retrying.

> **Safety net:** if an `Smb2PoolHandle` is garbage-collected without `closeHandle` being called, a `closeHandle` command is sent to the worker from the finalizer as a best-effort cleanup. **Do not rely on this** — always close explicitly (or use `withFile`) for deterministic, prompt cleanup.

---

### 6. Writing Files

#### 6.1 Write Entire File

Creates or overwrites a file with the given data. The file is truncated before writing.

**Sync (Smb2Client):**

```dart
client.writeFile('Documents/notes.txt', Uint8List.fromList('Hello!'.codeUnits));
```

**Async (Smb2Pool / CachedSmb2Pool):**

```dart
await pool.writeFile('Documents/notes.txt', Uint8List.fromList('Hello!'.codeUnits));
```

#### 6.2 Partial Write (Byte Range)

Writes data at a specific offset without truncating the file. Creates the file if it doesn't exist.

**Sync (Smb2Client):**

```dart
// Overwrite bytes 100–199 of an existing file
client.writeFileRange('data/file.bin', myBytes, offset: 100);
```

**Async (Smb2Pool / CachedSmb2Pool):**

```dart
await pool.writeFileRange('data/file.bin', myBytes, offset: 100);
```

#### 6.3 Streaming Write (Chunked)

Writes data from chunks without loading the entire file into RAM. Uses a sync `Iterable` on `Smb2Client` and an async `Stream` on `Smb2Pool` and `CachedSmb2Pool`.

**Sync (Smb2Client):**

```dart
client.writeFileChunked('data/large_file.bin', generateChunks());
```

**Async (Smb2Pool / CachedSmb2Pool):**

```dart
final fileStream = File('local_file.bin').openRead().cast<Uint8List>();
await pool.streamWrite('data/large_file.bin', fileStream);
```

#### 6.4 File Handles (Write)

Open a file once for writing and write to it multiple times without reopening. This minimizes round-trips for repeated writes on the same file.

**Sync (Smb2Client):**

```dart
final handle = client.openFileHandleWrite('data/output.bin');

client.writeHandle(handle, chunk1, offset: 0);
client.writeHandle(handle, chunk2, offset: chunk1.length);

client.closeHandle(handle);
```

**Pool (auto-reconnect on failure):**

```dart
final handle = await pool.openFileWrite('data/output.bin');

await pool.writeToHandle(handle, chunk1, offset: 0);
await pool.writeToHandle(handle, chunk2, offset: chunk1.length);

await pool.closeHandle(handle);
```

> **Note:** Write handles use the same `closeHandle()` method as read handles.

#### 6.5 Flush (fsync)

Flush all buffered writes on an open file handle to the server, ensuring data is persisted.

**Sync (Smb2Client):**

```dart
final handle = client.openFileHandleWrite('data/important.bin');
client.writeHandle(handle, data);
client.fsync(handle);  // ensure data is on disk
client.closeHandle(handle);
```

**Pool:**

```dart
final handle = await pool.openFileWrite('data/important.bin');
await pool.writeToHandle(handle, data);
await pool.fsyncHandle(handle);
await pool.closeHandle(handle);
```

#### 6.6 Truncate Handle (ftruncate)

Truncate an open file handle to a specific size. More efficient than path-based `truncate()` when the file is already open.

**Sync (Smb2Client):**

```dart
final handle = client.openFileHandleWrite('data/file.bin');
client.ftruncate(handle, 1024);
client.closeHandle(handle);
```

**Pool:**

```dart
final handle = await pool.openFileWrite('data/file.bin');
try {
  await pool.ftruncateHandle(handle, 1024);
} finally {
  await pool.closeHandle(handle);
}
```

---

### 7. File & Directory Management

#### 7.1 Create Directory

```dart
// Sync
client.mkdir('Documents/NewFolder');

// Async
await pool.mkdir('Documents/NewFolder');
```

#### 7.2 Delete File

```dart
// Sync
client.deleteFile('Documents/old_report.pdf');

// Async
await pool.deleteFile('Documents/old_report.pdf');
```

#### 7.3 Delete Directory

Removes an empty directory. Throws `Smb2Exception` if the directory is not empty.

```dart
// Sync
client.rmdir('Documents/EmptyFolder');

// Async
await pool.rmdir('Documents/EmptyFolder');
```

#### 7.4 Rename / Move

Renames or moves a file or directory within the same share.

```dart
// Sync
client.rename('Documents/old_name.txt', 'Documents/new_name.txt');

// Async — also works for moving between directories
await pool.rename('Documents/report.pdf', 'Archive/report.pdf');
```

#### 7.5 Truncate

Truncates a file to a specific size in bytes.

```dart
// Sync
client.truncate('Documents/logfile.txt', 0); // empty the file

// Async
await pool.truncate('Documents/logfile.txt', 1024); // keep first 1 KB
```

---

### 8. Share Enumeration

List all shares available on a server. This does not require an active connection — it connects to IPC$ internally.

**Sync:**

```dart
final shares = client.listShares(
  host: '192.168.1.100',
  user: 'user',
  password: 'pass',
);

for (final share in shares) {
  print('${share.name} — disk: ${share.isDisk}, hidden: ${share.isHidden}');
}
```

**Pool (static method, no active connection needed):**

```dart
final shares = await Smb2Pool.listSharesOn(
  host: '192.168.1.100',
  user: 'user',
  password: 'pass',
);
```

**CachedSmb2Pool (delegates to the underlying pool, not cached):**

```dart
final shares = await cached.listShares(
  host: '192.168.1.100',
  user: 'user',
  password: 'pass',
);
```

Each share is an `Smb2ShareInfo` with:

| Property | Type | Description |
| :--- | :--- | :--- |
| `name` | `String` | Share name |
| `type` | `int` | Raw share type |
| `isDisk` | `bool` | True if disk/folder share |
| `isHidden` | `bool` | True if hidden share |

---

### 9. Caching

`CachedSmb2Pool` wraps an `Smb2Pool` with a TTL-based in-memory cache. Only `stat` and `listDirectory` results are cached — all other operations always hit the network. Write operations automatically invalidate the cache for the affected path and its parent directory.

```dart
final cached = CachedSmb2Pool(pool, ttl: Duration(seconds: 30));
```

| Method | Cached | Auto-invalidates |
| :--- | :---: | :---: |
| `stat()` | ✅ | — |
| `listDirectory()` | ✅ | — |
| `readFile()` | ❌ | — |
| `readFileRange()` | ❌ | — |
| `streamFile()` | ❌ | — |
| `withFile()` | ❌ | — |
| `downloadToFile()` | ❌ | — |
| `fileSize()` | ❌ | — |
| `openFile()` / `openFileWithSize()` | ❌ | — |
| `readFromHandle()` / `closeHandle()` | ❌ | — |
| `exists()` | ✅ (via stat) | — |
| `listShares()` | ❌ | — |
| `writeFile()` | ❌ | ✅ path + parent |
| `writeFileRange()` | ❌ | ✅ path + parent |
| `deleteFile()` | ❌ | ✅ path + parent |
| `mkdir()` | ❌ | ✅ parent |
| `rmdir()` | ❌ | ✅ path + parent |
| `rename()` | ❌ | ✅ old + new paths |
| `truncate()` | ❌ | ✅ path + parent |
| `streamWrite()` | ❌ | ✅ path + parent |
| `openFileWrite()` / `writeToHandle()` | ❌ | — |
| `echo()` | ❌ | — |
| `statvfs()` | ❌ | — |
| `readlink()` | ❌ | — |
| `fsyncHandle()` / `ftruncateHandle()` | ❌ | — |

**Invalidation:**

```dart
cached.invalidate('Documents/Projects');  // remove one path from cache
cached.clearCache();                      // clear all cached data
```

---

### 10. Error Handling

#### 10.1 Smb2Exception

All errors throw `Smb2Exception` with a message, an optional POSIX errno, and a semantic error type.

```dart
try {
  await pool.readFile('nonexistent/path.txt');
} on Smb2Exception catch (e) {
  print(e.message);              // Human-readable error from libsmb2
  print(e.errorCode);            // POSIX errno (nullable)
  print(e.type);                 // Smb2ErrorType
  print(e.isConnectionError);    // true for retriable errors
}
```

#### 10.2 Error Types

`Smb2ErrorType` maps native errno values to semantic categories:

| Type | Meaning | errno examples |
| :--- | :--- | :--- |
| `connection` | Network disconnected, pipe broken | ENETRESET, ECONNRESET, ECONNABORTED, EPIPE, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH |
| `timeout` | Operation timed out | ETIMEDOUT |
| `auth` | Authentication failed | ECONNREFUSED |
| `fileNotFound` | File or path not found | ENOENT |
| `accessDenied` | Permission denied | EACCES |
| `notADirectory` | Path is not a directory | ENOTDIR |
| `alreadyExists` | Target already exists | EEXIST |
| `diskFull` | No space left on device | ENOSPC |
| `io` | I/O error | EIO |
| `invalidParam` | Invalid argument | EINVAL |
| `unknown` | Unmapped error code | — |

Use `isConnectionError` to decide whether to retry:

```dart
on Smb2Exception catch (e) {
  if (e.isConnectionError) {
    // Safe to retry — connection or timeout issue
  }
}
```

> **Note:** `Smb2Pool` handles reconnection automatically. You only need manual retry logic with `Smb2Client`.

---

## Types Reference

### Smb2Stat

| Property | Type | Description |
| :--- | :--- | :--- |
| `type` | `Smb2FileType` | `file`, `directory`, or `link` |
| `size` | `int` | Size in bytes |
| `modified` | `DateTime` | Last modification time |
| `created` | `DateTime` | Creation time |
| `isFile` | `bool` | `true` if regular file |
| `isDirectory` | `bool` | `true` if directory |

### Smb2DirEntry

| Property | Type | Description |
| :--- | :--- | :--- |
| `name` | `String` | Entry name (not full path) |
| `stat` | `Smb2Stat` | Full metadata |
| `isDirectory` | `bool` | Shorthand |
| `isFile` | `bool` | Shorthand |
| `size` | `int` | Shorthand for `stat.size` |

### Smb2StatVfs

| Property | Type | Description |
| :--- | :--- | :--- |
| `blockSize` | `int` | Fundamental block size |
| `fragmentSize` | `int` | Fragment size |
| `totalBlocks` | `int` | Total data blocks |
| `freeBlocks` | `int` | Free blocks |
| `availableBlocks` | `int` | Available blocks for non-root |
| `maxNameLength` | `int` | Max filename length |
| `totalSize` | `int` | Total size in bytes (computed) |
| `freeSize` | `int` | Free space in bytes (computed) |
| `availableSize` | `int` | Available space in bytes (computed) |

### Smb2ShareInfo

| Property | Type | Description |
| :--- | :--- | :--- |
| `name` | `String` | Share name |
| `type` | `int` | Raw share type |
| `isDisk` | `bool` | True if disk/folder share |
| `isHidden` | `bool` | True if hidden share |

### Smb2Version

| Value | Protocol |
| :--- | :--- |
| `any` | Best available (default) |
| `any2` | Any SMB 2.x |
| `any3` | Any SMB 3.x |
| `v202` | SMB 2.0.2 |
| `v210` | SMB 2.1 |
| `v300` | SMB 3.0 |
| `v302` | SMB 3.0.2 |
| `v311` | SMB 3.1.1 |

### Smb2FileType

| Value | Description |
| :--- | :--- |
| `file` | Regular file |
| `directory` | Directory |
| `link` | Symbolic link |

### Smb2ErrorType

| Value | Description |
| :--- | :--- |
| `connection` | Network disconnected |
| `timeout` | Operation timed out |
| `auth` | Authentication failed |
| `fileNotFound` | File or path not found |
| `accessDenied` | Permission denied |
| `notADirectory` | Path is not a directory |
| `alreadyExists` | Target already exists |
| `diskFull` | No space left |
| `io` | I/O error |
| `invalidParam` | Invalid argument |
| `unknown` | Unmapped error |

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

All the native bindings, FFI wrappers, and isolate logic were implemented through the use of Claude Code.

---

*Developed by Alessandro Di Ronza*
