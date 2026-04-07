# dart_smb2

#### SMB2/3 client for Dart & Flutter.

[![](https://img.shields.io/pub/v/dart_smb2.svg)](https://pub.dev/packages/dart_smb2)
[![](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](LICENSE)
[![](https://img.shields.io/badge/libsmb2-LGPL--2.1-orange.svg)](https://github.com/sahlberg/libsmb2)
[![](https://img.shields.io/github/stars/ales-drnz/dart_smb2?style=flat&logo=github)](https://github.com/ales-drnz/dart_smb2)
[![](https://img.shields.io/discord/1491115396663869470?logo=discord&logoColor=white)](https://discord.gg/ejSw5M24C2)

<img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/samba.png" width="70" align="left" style="margin-right: 15px;" alt="logo" />`dart_smb2` is an SMB2/3 client for Dart powered by [libsmb2](https://github.com/sahlberg/libsmb2). It provides synchronous FFI bindings, async isolate wrappers, a worker pool with auto-reconnect, and an optional caching layer. No external dependencies, no Kerberos required.
<br clear="left"/>

---

## Installation

Add `dart_smb2` to your `pubspec.yaml`:

```yaml
dependencies:
  dart_smb2: ^0.0.1
```

### Platform Requirements

*   **Android**: minSdk 21 (Android 5.0), compileSdk 33, NDK 25.1.
*   **iOS**: 12.0 or above.
*   **macOS**: 10.14 or above.
*   **Windows**: CMake 3.10+.
*   **Linux**: CMake 3.10+.

---

## Platforms

| Platform  | Architecture | Device | Emulator | libsmb2 version |
| :--- | :--- | :---: | :---: | :---: |
| **Android** | arm64-v8a, x86_64 | ✅ | ✅ | v6.1.0 |
| **iOS** | arm64, x86_64 | ✅ | ✅ | v6.1.0 |
| **macOS** | arm64, x86_64 | ✅ | — | v6.1.0 |
| **Windows** | x86_64 | ✅ | — | v6.1.0 |
| **Linux** | x86_64 | ✅ | — | v6.1.0 |

---

## Reference

*   [Features](#features)
*   [Quick Start](#quick-start)
*   [Guide](#guide)
    *   [1. Connection & Lifecycle](#1-connection--lifecycle)
        *   [1.1 Sync Client](#11-sync-client)
        *   [1.2 Async Isolate](#12-async-isolate)
        *   [1.3 Worker Pool](#13-worker-pool)
        *   [1.4 Cached Pool](#14-cached-pool)
        *   [1.5 Disconnecting](#15-disconnecting)
    *   [2. Share Enumeration](#2-share-enumeration)
    *   [3. Directory Listing](#3-directory-listing)
    *   [4. Reading Files](#4-reading-files)
        *   [4.1 Read Entire File](#41-read-entire-file)
        *   [4.2 Partial Read (Byte Range)](#42-partial-read-byte-range)
        *   [4.3 Streaming (Chunked)](#43-streaming-chunked)
        *   [4.4 File Handles](#44-file-handles)
    *   [5. File Metadata](#5-file-metadata)
        *   [5.1 Stat](#51-stat)
        *   [5.2 File Size](#52-file-size)
    *   [6. Error Handling](#6-error-handling)
        *   [6.1 Smb2Exception](#61-smb2exception)
        *   [6.2 Error Types](#62-error-types)
    *   [7. Path Format](#7-path-format)
    *   [8. Caching](#8-caching)
*   [Types Reference](#types-reference)
*   [Testing](#testing)
*   [Funding](#funding)
*   [License](#license)

---

## Features

- ⚡ **SMB2/3 Protocol** — supports SMB 2.02, 2.10, 3.0, 3.02, 3.1.1.
- 📂 **Directory Listing** — returns name, type, size, and timestamps per entry with no additional per-entry round-trips.
- 📄 **Partial File Reads** — read specific byte ranges with `pread` — ideal for reading partial content without downloading the full file.
- 📦 **Full File Reads** — download entire files into memory.
- 🔁 **Streaming** — chunked reads via sync `Iterable` or async `Stream`.
- 🔓 **File Handles** — open once, read many times to minimize round-trips.
- 📊 **File Stat** — get size, type, and timestamps via SMB2 compound request (single round-trip).
- 🌐 **Share Enumeration** — list all shares on a server without an active connection.
- 🧵 **Isolate-Safe** — sync API designed for Dart isolates, with async wrappers for UI threads.
- 🏊 **Worker Pool** — multiple isolate workers with automatic reconnect on connection errors.
- 💾 **Caching Layer** — optional TTL-based cache for `stat` and `listDirectory` calls.

---

## Quick Start

```dart
import 'package:dart_smb2/dart_smb2.dart';

void main() async {
  // Connect with the async isolate wrapper
  final smb = await Smb2Isolate.connect(
    libPath: '/path/to/libdart_smb2.dylib',
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
final client = Smb2Client.open('/custom/path/libdart_smb2.dylib');
```

#### 1.2 Async Isolate

Spawns a dedicated isolate with its own `Smb2Client`. All operations return `Future`s.

```dart
final smb = await Smb2Isolate.connect(
  libPath: '/path/to/libdart_smb2.dylib',
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

---

### 2. Share Enumeration

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

### 4. Reading Files

#### 4.1 Read Entire File

Loads the entire file into memory.

```dart
final bytes = await pool.readFile('Documents/report.pdf');
```

#### 4.2 Partial Read (Byte Range)

Reads N bytes starting at an offset. Ideal for reading partial content without downloading the entire file.

```dart
// Read first 256 KB of a file
final header = await pool.readFileRange(
  'Documents/report.pdf',
  offset: 0,           // default: 0
  length: 256 * 1024,
);
```

#### 4.3 Streaming (Chunked)

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

#### 4.4 File Handles

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

### 5. File Metadata

#### 5.1 Stat

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

#### 5.2 File Size

Shortcut to get just the file size.

```dart
final size = await pool.fileSize('Documents/report.pdf');
print('$size bytes');
```

---

### 6. Error Handling

#### 6.1 Smb2Exception

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

#### 6.2 Error Types

`Smb2ErrorType` maps native errno values to semantic categories:

| Type | Meaning | errno examples |
| :--- | :--- | :--- |
| `connection` | Network disconnected, pipe broken | ENETRESET, ECONNRESET, ECONNABORTED, EPIPE, ENOTCONN, ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH |
| `timeout` | Operation timed out | ETIMEDOUT |
| `auth` | Authentication failed | ECONNREFUSED, EACCES (logon) |
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

### 7. Path Format

Paths are **relative to the share root**. Use an empty string `''` for the root directory — not `/`.

```dart
pool.listDirectory('');                    // share root
pool.listDirectory('Documents');           // subfolder
pool.listDirectory('Documents/Projects'); // nested subfolder
pool.stat('Documents/report.pdf');         // file in subfolder
```

---

### 8. Caching

`CachedSmb2Pool` wraps an `Smb2Pool` with a TTL-based in-memory cache. Only `stat` and `listDirectory` results are cached — all other operations always hit the network.

```dart
final cached = CachedSmb2Pool(pool, ttl: Duration(seconds: 30));
```

| Method | Cached |
| :--- | :---: |
| `stat()` | ✅ |
| `listDirectory()` | ✅ |
| `readFile()` | ❌ |
| `readFileRange()` | ❌ |
| `streamFile()` | ❌ |
| `fileSize()` | ❌ |
| `openFile()` / `openFileWithSize()` | ❌ |
| `readFromHandle()` / `closeHandle()` | ❌ |
| `listShares()` | ❌ |

**Invalidation:**

```dart
cached.invalidate('Documents/Projects');  // remove one path from cache
cached.clearCache();                 // clear all cached data
```

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

### Smb2ShareInfo

| Property | Type | Description |
| :--- | :--- | :--- |
| `name` | `String` | Share name |
| `type` | `int` | Raw share type |
| `isDisk` | `bool` | True if disk/folder share |
| `isHidden` | `bool` | True if hidden share |

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

Covers `Smb2ErrorType.fromErrno` mappings (macOS, Linux, Windows errno values) and `Smb2Exception` behaviour.

### Integration tests

Require a running SMB2/3 server. Set the following environment variables:

| Variable | Description |
| :--- | :--- |
| `SMB2_HOST` | Server IP or hostname |
| `SMB2_SHARE` | Share name |
| `SMB2_USER` | Username (optional) |
| `SMB2_PASS` | Password (optional) |
| `SMB2_LIB_PATH` | Path to the compiled shared library |
| `SMB2_TEST_FILE` | Path to an existing file on the share (optional — auto-detected if unset) |

```bash
SMB2_HOST=192.168.1.1 \
SMB2_SHARE=Files \
SMB2_USER=user \
SMB2_PASS=pass \
SMB2_LIB_PATH=macos/libs/libdart_smb2.dylib \
SMB2_TEST_FILE=Documents/report.pdf \
dart test test/smb2_client_test.dart test/smb2_pool_test.dart test/smb2_cached_pool_test.dart -r expanded
```

**`smb2_pool_test.dart`** covers `Smb2Pool` end-to-end: basic operations, file handles, streaming, round-robin distribution, disconnect behaviour, and performance benchmarks (sequential/parallel throughput, stat latency, handle cycle time).

**`smb2_client_test.dart`** covers the sync `Smb2Client` directly: directory listing, stat, file size, partial reads, and error paths.

**`smb2_cached_pool_test.dart`** covers `CachedSmb2Pool`: cache hits, TTL expiry, and invalidation.

---

## Funding

If you find this library useful and want to support its development, consider becoming a supporter on **Patreon**. For questions and discussion, join the **Discord** server:

[![](https://img.shields.io/badge/Patreon-F96854?style=for-the-badge&logo=patreon&logoColor=white)](https://www.patreon.com/cw/ales_drnz)
[![](https://img.shields.io/discord/1491115396663869470?style=for-the-badge&logo=discord&logoColor=white&label=Discord&color=5865F2)](https://discord.gg/ejSw5M24C2)

---

## License

This package is licensed under the **BSD 3-Clause License**.

libsmb2 is licensed under **LGPL v2.1**. It is statically linked into the wrapper library. See the [libsmb2 license](https://github.com/sahlberg/libsmb2/blob/master/COPYING) for details.
