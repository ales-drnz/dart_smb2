# dart_smb2

#### SMB2/3 client for Dart & Flutter.

[![](https://img.shields.io/pub/v/dart_smb2.svg)](https://pub.dev/packages/dart_smb2)
[![](https://img.shields.io/badge/libsmb2-v6.1.0-orange.svg)](https://github.com/sahlberg/libsmb2)
[![](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![](https://img.shields.io/github/stars/ales-drnz/dart_smb2?style=flat&logo=github)](https://github.com/ales-drnz/dart_smb2)
[![](https://img.shields.io/discord/1491115396663869470?logo=discord&logoColor=white)](https://discord.gg/ejSw5M24C2)

<img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/dart_smb2.png" width="70" align="left" style="margin-right: 15px;" alt="logo" />`dart_smb2` is an SMB2/3 client for Dart powered by [libsmb2](https://github.com/sahlberg/libsmb2). It provides synchronous FFI bindings, async isolate wrappers, a worker pool with auto-reconnect, and an optional caching layer.
<br clear="left"/>

---

## Installation

Add `dart_smb2` to your `pubspec.yaml`:

```yaml
dependencies:
  dart_smb2: ^0.0.3
```

### Platform Requirements

*   **Android**: SDK 21 (Android 5.0) or above.
*   **iOS**: 12.0 or above.
*   **macOS**: 10.14 or above (Apple Silicon).
*   **Windows**: x86_64.
*   **Linux**: x86_64.

---

## Platforms

| Platform  | Architecture | Device | Emulator | libsmb2 version |
| :--- | :--- | :---: | :---: | :---: |
| **Android** | arm64-v8a, x86_64 | ✅ | ✅ | v6.1.0 |
| **iOS** | arm64, x86_64 | ✅ | ✅ | v6.1.0 |
| **macOS** | arm64 | ✅ | — | v6.1.0 |
| **Windows** | x86_64 | ✅ | — | v6.1.0 |
| **Linux** | x86_64 | ✅ | — | v6.1.0 |

---

## Reference

*   [Visuals](#visuals)
*   [Features](#features)
*   [Quick Start](#quick-start)
*   [Guide](#guide)
    *   [1. Connection & Lifecycle](#1-connection--lifecycle)
        *   [1.1 Sync Client](#11-sync-client)
        *   [1.2 Async Isolate](#12-async-isolate)
        *   [1.3 Worker Pool](#13-worker-pool)
        *   [1.4 Cached Pool](#14-cached-pool)
        *   [1.5 Disconnecting](#15-disconnecting)
        *   [1.6 Security Options](#16-security-options)
    *   [2. Path Format](#2-path-format)
    *   [3. Directory Listing](#3-directory-listing)
    *   [4. File Metadata](#4-file-metadata)
        *   [4.1 Stat](#41-stat)
        *   [4.2 File Size](#42-file-size)
        *   [4.3 Exists](#43-exists)
        *   [4.4 Filesystem Info (statvfs)](#44-filesystem-info-statvfs)
        *   [4.5 Read Symlink](#45-read-symlink)
        *   [4.6 Connection Health (echo)](#46-connection-health-echo)
    *   [5. Reading Files](#5-reading-files)
        *   [5.1 Read Entire File](#51-read-entire-file)
        *   [5.2 Partial Read (Byte Range)](#52-partial-read-byte-range)
        *   [5.3 Streaming (Chunked)](#53-streaming-chunked)
        *   [5.4 File Handles (Read)](#54-file-handles-read)
    *   [6. Writing Files](#6-writing-files)
        *   [6.1 Write Entire File](#61-write-entire-file)
        *   [6.2 Partial Write (Byte Range)](#62-partial-write-byte-range)
        *   [6.3 Streaming Write (Chunked)](#63-streaming-write-chunked)
        *   [6.4 File Handles (Write)](#64-file-handles-write)
        *   [6.5 Flush (fsync)](#65-flush-fsync)
        *   [6.6 Truncate Handle (ftruncate)](#66-truncate-handle-ftruncate)
    *   [7. File & Directory Management](#7-file--directory-management)
        *   [7.1 Create Directory](#71-create-directory)
        *   [7.2 Delete File](#72-delete-file)
        *   [7.3 Delete Directory](#73-delete-directory)
        *   [7.4 Rename / Move](#74-rename--move)
        *   [7.5 Truncate](#75-truncate)
    *   [8. Share Enumeration](#8-share-enumeration)
    *   [9. Caching](#9-caching)
    *   [10. Error Handling](#10-error-handling)
        *   [10.1 Smb2Exception](#101-smb2exception)
        *   [10.2 Error Types](#102-error-types)
*   [Types Reference](#types-reference)
*   [Testing](#testing)
*   [Permissions](#permissions)
*   [Funding](#funding)

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

- ⚡ **SMB2/3 Protocol** — supports SMB 2.02, 2.10, 3.0, 3.02, 3.1.1.
- 📂 **Directory Listing** — returns name, type, size, and timestamps per entry with no additional per-entry round-trips.
- 📄 **Partial File Reads** — read specific byte ranges with `pread` — ideal for reading partial content without downloading the full file.
- 📦 **Full File Reads** — download entire files into memory.
- 🔁 **Streaming** — chunked reads and writes via sync `Iterable` or async `Stream`.
- 🔓 **File Handles** — open once, read or write many times to minimize round-trips.
- ✏️ **File Writing** — write entire files or partial byte ranges with automatic chunking.
- 🔍 **Exists Check** — check if a file or directory exists without reading it.
- 🗂️ **File & Directory Management** — create directories, delete files/directories, rename/move, and truncate.
- 📊 **File Stat** — get size, type, and timestamps via SMB2 compound request (single round-trip).
- 💽 **Filesystem Info** — query total/free disk space via `statvfs`.
- 🔗 **Symlink Resolution** — read symbolic link targets with `readlink`.
- 🖲️ **Connection Health** — keepalive `echo` ping to detect disconnections early.
- 🔄 **Flush & Truncate** — `fsync` to persist writes and `ftruncate` on open handles.
- 🌐 **Share Enumeration** — list all shares on a server without an active connection.
- 🧵 **Isolate-Safe** — sync API designed for Dart isolates, with async wrappers for UI threads.
- 🏊 **Worker Pool** — multiple isolate workers with automatic reconnect on connection errors.
- 💾 **Caching Layer** — optional TTL-based cache for `stat` and `listDirectory` calls, with automatic invalidation on write operations.

---

## Quick Start

```dart
import 'dart:typed_data';
import 'package:dart_smb2/dart_smb2.dart';

void main() async {
  // Connect with the async isolate wrapper
  final smb = await Smb2Isolate.connect(
    libPath: '/path/to/libsmb2.dylib',
    host: '192.168.1.100',
    share: 'Files',
    user: 'user',
    password: 'pass',
  );

  // List a directory
  final entries = await smb.listDirectory('Documents/Projects');
  for (final entry in entries) {
    print('${entry.name} — ${entry.size} bytes');
  }

  // Read first 256 KB of a file
  final header = await smb.readFileRange(
    'Documents/report.pdf',
    length: 256 * 1024,
  );

  // Read entire file
  final bytes = await smb.readFile('Documents/image.jpg');

  // Write a file
  await smb.writeFile('Documents/notes.txt', Uint8List.fromList('Hello SMB!'.codeUnits));

  // Create a directory
  await smb.mkdir('Documents/NewFolder');

  // Get file info
  final info = await smb.stat('Documents/report.pdf');
  print('Size: ${info.size}, Modified: ${info.modified}');

  await smb.disconnect();
}
```

---

## Guide

### 1. Connection & Lifecycle

`dart_smb2` offers four layers of abstraction. Choose the one that fits your use case:

| Layer | Class | Best for |
| :--- | :--- | :--- |
| Sync FFI | `Smb2Client` | Scripts, background isolates, maximum control |
| Async Isolate | `Smb2Isolate` | Single-connection Flutter apps |
| Worker Pool | `Smb2Pool` | Concurrent access, auto-reconnect |
| Cached Pool | `CachedSmb2Pool` | Repeated `stat`/`listDirectory` calls with TTL |

#### 1.1 Sync Client

The core layer. All operations are blocking — run it in an isolate to avoid blocking the UI thread.

```dart
final client = Smb2Client.open(); // auto-loads bundled library

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

`Smb2Client.open()` loads the bundled native library automatically when used as a Flutter plugin. Pass a custom path for standalone Dart scripts:

```dart
final client = Smb2Client.open('/custom/path/libsmb2.dylib');
```

#### 1.2 Async Isolate

Spawns a dedicated isolate with its own `Smb2Client`. All operations return `Future`s.

```dart
final smb = await Smb2Isolate.connect(
  libPath: '/path/to/libsmb2.dylib',
  host: '192.168.1.100',
  share: 'Files',
  user: 'user',
  password: 'pass',
);

final entries = await smb.listDirectory('');
await smb.disconnect();
```

#### 1.3 Worker Pool

Spawns N isolate workers connected to the same share. Operations are dispatched round-robin. If a worker loses connection, it automatically reconnects and retries the operation.

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

#### 1.4 Cached Pool

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

#### 1.5 Disconnecting

Always disconnect when done. This releases the native SMB2 context and kills any spawned isolates.

```dart
client.disconnect();          // Smb2Client (sync)
await smb.disconnect();       // Smb2Isolate
await pool.disconnect();      // Smb2Pool
await cached.disconnect();    // CachedSmb2Pool
```

#### 1.6 Security Options

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

#### 5.3 Streaming (Chunked)

Reads a file in chunks, yielding each chunk as it arrives. Uses a sync `Iterable` on `Smb2Client` and an async `Stream` on `Smb2Pool` and `Smb2Isolate`.

**Sync (Smb2Client):**

```dart
for (final chunk in client.readFileChunked('data/large_file.bin', chunkSize: 1024 * 1024)) {
  sink.add(chunk);
}
```

**Async (Smb2Pool / Smb2Isolate):**

```dart
await for (final chunk in pool.streamFile('data/large_file.bin', chunkSize: 1024 * 1024)) {
  sink.add(chunk);
}
```

#### 5.4 File Handles (Read)

Open a file once and read from it multiple times without reopening. This minimizes round-trips for repeated reads on the same file.

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

final data = await pool.readFromHandle(handle, offset: 0, length: size);

await pool.closeHandle(handle);
```

If the connection drops during a read, the pool automatically reconnects the worker and reopens the file handle before retrying.

---

### 6. Writing Files

#### 6.1 Write Entire File

Creates or overwrites a file with the given data. The file is truncated before writing.

**Sync (Smb2Client):**

```dart
client.writeFile('Documents/notes.txt', Uint8List.fromList('Hello!'.codeUnits));
```

**Async (Smb2Pool / Smb2Isolate / CachedSmb2Pool):**

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

**Async (Smb2Pool / Smb2Isolate / CachedSmb2Pool):**

```dart
await pool.writeFileRange('data/file.bin', myBytes, offset: 100);
```

#### 6.3 Streaming Write (Chunked)

Writes data from chunks without loading the entire file into RAM. Uses a sync `Iterable` on `Smb2Client` and an async `Stream` on `Smb2Pool`, `Smb2Isolate`, and `CachedSmb2Pool`.

**Sync (Smb2Client):**

```dart
client.writeFileChunked('data/large_file.bin', generateChunks());
```

**Async (Smb2Pool / Smb2Isolate / CachedSmb2Pool):**

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

```dart
// Sync
client.ftruncate(handle, 1024);

// Pool
await pool.ftruncateHandle(handle, 1024);
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

**Isolate (on an existing connection):**

```dart
final shares = await smb.listShares();
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

> **Note:** `Smb2Pool` handles reconnection automatically. You only need manual retry logic with `Smb2Client` or `Smb2Isolate`.

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

## Testing

The test suite is split into unit tests (no server required) and integration tests (require a live SMB server).

### Unit tests

```bash
dart test test/smb2_error_type_test.dart
```

### Integration tests

Require a running SMB2/3 server. Set the following environment variables:

| Variable | Description |
| :--- | :--- |
| `SMB2_HOST` | Server IP or hostname |
| `SMB2_SHARE` | Share name |
| `SMB2_USER` | Username (optional) |
| `SMB2_PASS` | Password (optional) |
| `SMB2_LIB_PATH` | Path to the libsmb2 library |
| `SMB2_TEST_FILE` | Path to an existing file on the share (optional — auto-detected if unset) |

```bash
SMB2_HOST=192.168.1.1 \
SMB2_SHARE=Files \
SMB2_USER=user \
SMB2_PASS=pass \
SMB2_LIB_PATH=/path/to/libsmb2.dylib \
SMB2_TEST_FILE=Documents/report.pdf \
dart test test/smb2_client_test.dart test/smb2_pool_test.dart test/smb2_cached_pool_test.dart test/smb2_write_test.dart -r expanded
```

**`smb2_pool_test.dart`** covers `Smb2Pool` end-to-end: basic operations, file handles, streaming, round-robin distribution, disconnect behaviour, and performance benchmarks (sequential/parallel throughput, stat latency, handle cycle time).

**`smb2_client_test.dart`** covers the sync `Smb2Client` directly: directory listing, stat, file size, partial reads, and error paths.

**`smb2_cached_pool_test.dart`** covers `CachedSmb2Pool`: cache hits, TTL expiry, and invalidation.

**`smb2_write_test.dart`** covers all write operations on both `Smb2Client` and `Smb2Pool`: writeFile, writeFileRange, writeFileChunked/streamWrite, write handles, exists, mkdir, rmdir, deleteFile, rename, truncate, and concurrent writes. Requires **write access** to the share.

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

## Funding

If you find this library useful and want to support its development, consider becoming a supporter on **Patreon**:

[![](https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/ales_drnz)

---

*Developed by Alessandro Di Ronza*
