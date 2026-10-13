## [0.2.0] - 13-10-2026

A revision of the whole package. See [MIGRATION.md](MIGRATION.md) for the changes to make in an app.

### Breaking
- dart_smb2 is a plain Dart package: a build hook bundles libsmb2, and the Flutter plugin (Gradle, CocoaPods, SwiftPM, CMake) is gone. It needs Dart 3.10, Flutter 3.38 in an app, and `minSdk` 24 on Android, which the hook now checks.
- `Smb2Exception` takes named arguments (`type:`, `ntStatus:`, `errno:`, `path:`, `cause:`) and is `final`.
- `Smb2ErrorType` gains `notEmpty`, `isADirectory`, `inUse`, `notSupported`, `state` and `cancelled`, and `fileNotFound` becomes an alias of `notFound`: the values, their order and `toString()` change. A closed pool or handle and a client that is not connected report `state`, not `unknown`.
- `Smb2Exception.errno` and the deprecated `errorCode` are the errno of the failed call (for an open or a listing, of the server's status), and null for a transport failure: 0.1.x read whatever status an earlier call had left.
- `Smb2Pool.downloadToFile()` takes the destination as a `String` path and writes it atomically.
- `Smb2Client.listShares()` is static, and `Smb2Client` methods throw `state` on a closed or foreign handle.
- `mkdir`, `rmdir`, `deleteFile` and `rename` are not repeated after a network failure.
- `rmdir` of a file fails with `notADirectory` (it deleted the file), `deleteFile` of a directory, or of a link to one, with `isADirectory` (it deleted an empty one, and did nothing on one with entries), and `truncate` of a directory with `isADirectory` (it did nothing).
- `Smb2Pool.connect(workers: 0)` throws `invalidParam`.
- `Smb2Stat` requires `accessed` and `changed`, the public types are `final`, `Smb2PoolHandle` no longer exposes `worker`, `id` and `markClosed()`, and the `Smb2File` constructor is internal.

### Added
- `Smb2CancelToken`, taken by every call on a connected `Smb2Pool` except `closeHandle()`, `disconnect()` and the deprecated `listShares()`.
- `Smb2Exception.isNetworkFailure`, `isTransient`, `isNotFound`, `isCancelled`, `isAuthError`, `ntStatus` and `errno`.
- `Smb2ErrorType.fromFailure()`, which `classify()` now calls.
- `Smb2Stat.accessed`, `changed`, `attributes` and `isHidden`, and times to the microsecond.
- `Smb2ShareInfo.remark` and `Smb2ShareType.temporary`.
- `Smb2Client.maxReadSize` and `maxWriteSize`.
- `Smb2Pool.openFileWrite(truncate:)`, `isClosed` and `defaultChunkSize`.
- `hooks.user_defines.dart_smb2.libsmb2`, to bundle a local libsmb2.
- A `NOTICE` on the LGPL-2.1 libsmb2 that apps bundle.

### Changed
- The error type comes from the server's NT status and from per-platform errno tables: Windows errors were misread. A status counts only when the server answered this call with it.
- A host name that does not resolve and libsmb2's generic failures are `connection` errors; a server out of resources is `inUse`; a read-only share is `accessDenied`.
- `streamFile()` reads one chunk ahead, 4 MiB by default; `downloadToFile()` writes at the disk's pace.
- Calls go to the least busy worker, and the workers connect in parallel.
- When a reconnect fails, the slot's calls go to the other workers, and the slot tries again in the background.
- A cancelled call returns at once, also while it waits for a reconnect or a slot.
- `disconnect()` aborts a reconnect in progress instead of waiting for its connect.
- A stream, a download, `withFile()` or `streamWrite()` that fails or is cancelled closes its handle without waiting, so it never waits behind a read stuck on the network; one that completes waits for the close, so the file can be deleted or renamed next.
- A worker that dies without a call failing on it, or whose cancelled request hits a network failure, is reconnected at once; a slot that cannot reconnect retries after a network failure from 1 to 32 seconds apart; a refusal is kept for 5 minutes, with one login attempt per interval for the whole pool; and a call that finds no live worker reports why the reconnect failed.
- Reads reach the calling isolate in native buffers, without a copy.
- `streamWrite()` repeats a chunk after a reconnect.
- Paths drop leading slashes and take backslashes.
- `timeout: Duration` replaces `timeoutSeconds:`, which is deprecated.
- `Smb2ErrorType.fileNotFound` and `classify()`, `Smb2Exception.isConnectionError` and `errorCode`, and `Smb2PoolHandle.closed` and `refreshFinalizer()` are deprecated: use `notFound` and `fromFailure()`, `isNetworkFailure` and `errno`, and `isClosed`.
- `Smb2Client.open()`, `openFileHandle()`, `openFileHandleWrite()`, `readHandle()`, `writeHandle()`, `fsync()` and `ftruncate()` are deprecated: use `Smb2Client()`, `openFile()`, `openFileWrite()`, `readFromHandle()`, `writeToHandle()`, `fsyncHandle()` and `ftruncateHandle()`.
- `isCanceled:` on `streamFile()` and `downloadToFile()`, and the instance `Smb2Pool.listShares()`, are deprecated: use `cancelToken:` and `Smb2Pool.listSharesOn()`.
- The build hook gives a download 30 seconds to connect and 60 without data, in up to three attempts, and its errors name the user define to set.

### Fixed
- Closing a handle twice freed it twice and aborted the process.
- `readFileRange()` came back short, and `readFileChunked()` skipped data, for reads above the server's MaxReadSize; a read of 4 GiB or more failed.
- A handle on a worker replaced by a reconnect failed for good.
- `Smb2Pool.connect()` hung when a worker isolate died before connecting, and reported `unknown` for wrong credentials.
- `disconnect()` during a reconnect left a worker and its session alive, or threw an unhandled `RangeError`.
- `downloadToFile()` emptied the destination when the remote file was missing.
- A plain `dart test` ran the integration suites, which failed now and then.

### Build
- libsmb2 is upstream master of 11-10-2026 (e94eee9), with sealed-reply enforcement and receive caps, from release `libsmb2-r9`. Its `stat` asks for the reparse tag in one more request of the same compound, about 10% slower on a local network.
- libsmb2's context list takes a lock, so pools connecting and disconnecting at once no longer race on it.
- `rmdir` checks that its target is an empty directory, `unlink` and `truncate` that theirs is not a directory, and a request that times out before it is sent reports the timeout instead of hanging (or, for `fstat`, crashing).
- `rename` and `echo` record their NT status, so an earlier one cannot classify their failure.
- The Linux libraries need glibc 2.25 or later (they are built on 2.31) instead of 2.38, every binary is stripped and exports libsmb2's API only.
- The binaries are built and checked on GitHub's runners, with `manifest.json`, `SHA256SUMS` and the LGPL texts on each release.
- CI on GitHub: analysis on Dart 3.10 and stable, tests on Linux, macOS and Windows (and Dart 3.10 on Linux), the integration suites against Samba, through a proxy that cuts connections, app builds for every platform, and `test_app/`'s on-device suite on an Android emulator, the iOS simulator, Linux, macOS and Windows.
- The example is one Dart file instead of a Flutter app.

## [0.1.3] - 19-09-2026

### Contributions
- [@laurentiugh](https://github.com/laurentiugh): reported the crash on a timed-out open, traced it to the double free in the bundled libsmb2 and verified the fix against a locally patched build ([#3](https://github.com/ales-drnz/dart_smb2/issues/3)).

### Build
- Opening a file or listing a directory on a share that stopped answering no longer kills the app with a native abort, which Dart cannot catch. The call now throws `Smb2Exception` with `Smb2ErrorType.timeout` once `timeoutSeconds` elapses, and `Smb2Pool` reconnects as it does for any other connection error.
- Every file open no longer leaks a few bytes of native memory.
- Updated binaries to `libsmb2-r8` across all platforms.

## [0.1.2] - 24-08-2026

### Security
- Windows now draws the NTLMv2 client challenge, the SMB 3.1.1 preauth salt and the AES-CCM nonce from the system CSPRNG (CNG `BCryptGenRandom`) instead of `rand()`.

### Build
- Rebased the bundled libsmb2 to upstream master 2026-08-14, picking up the August 2026 security hardening series.
- Share enumeration now uses upstream's rewritten minimal DCE/RPC; the previous code's unaligned accesses were the prime suspect for the arm32 crash in [#2](https://github.com/ales-drnz/dart_smb2/issues/2).
- Updated binaries to `libsmb2-r7` across all platforms and regenerated the ffigen bindings against the r7 headers.
- The [`libsmb2-scripts`](https://github.com/ales-drnz/libsmb2-scripts) build infrastructure is now public and patch-based — the corresponding source for the LGPL-2.1 libsmb2 binaries ([#2](https://github.com/ales-drnz/dart_smb2/issues/2)).

## [0.1.1] - 19-07-2026

### Added
- `setFileTimes(path, {modified, accessed})` on both `Smb2Client` and `Smb2Pool` — set the remote last-modified and/or last-accessed time of a file or directory. Fields left `null` are unchanged on the server. Useful for file manager, backup, and sync apps that preserve local timestamps on upload ([#1](https://github.com/ales-drnz/dart_smb2/issues/1)).

### Build
- Patched libsmb2 with a new `smb2_utimes` / `smb2_utimes_async` API (compound CREATE + SET_INFO `FILE_BASIC_INFORMATION` + CLOSE, modeled on `smb2_truncate`). Timestamps travel as fixed-width microseconds-since-epoch scalars, so the FFI ABI is identical on every platform including 32-bit Android.
- Updated binaries to `libsmb2-r6` across all platforms.

## [0.1.0] - 28-05-2026

### Changed
- General refactor of the code.
- Rewrote the FFI layer with ffigen and simplified the internals; temporary native memory is now freed automatically.
- `Smb2Client.open()` no longer takes a path; the native library already loads automatically.

### Removed
- `CachedSmb2Pool` and built-in caching. The pool no longer caches `stat` / `listDirectory` — cache at your own layer if you need to.

### Fixed
- `listDirectory` and `listShares` now work correctly on 32-bit Android.
- `readlink` handles long symlink targets correctly.
- File paths containing NUL characters are rejected instead of being silently cut short.
- Pool operations no longer hang if a worker dies mid-request — they fail fast and reconnect.
- Interrupted downloads now raise an error instead of finishing short and silent.
- Several handle and reconnect edge cases under heavy concurrency are handled cleanly.

## [0.0.8] - 25-05-2026

### Fixed
- General minor fixes.

## [0.0.7] - 25-05-2026

### Docs
- Branding realignment with the rest of the libraries.

### Build
- Improvements to Swift Package Manager on both iOS and macOS.
- iOS and macOS now ship a dynamic xcframework.
- Bumped minimum deployment targets to iOS `15.0` and macOS `12.0`.
- Added Android `armeabi-v7a` (32-bit ARM), Linux `aarch64` and Windows `arm64` binaries.
- Updated libs to `libsmb2-r5` across all platforms.

## [0.0.6] - 24-04-2026

### Added
- `Smb2Pool.withFile(path, body, {knownSize})` and scoped `Smb2File` — opens a read handle, runs the callback, guarantees `closeHandle` on any exit (exception, early return, cancellation). Replaces the `openFileWithSize` + `readFromHandle` + `closeHandle` boilerplate at every call site.
- `Smb2Pool.downloadToFile(path, File destFile, {chunkSize, onProgress, isCanceled})` — one-call download of an SMB file to a local `File` streaming through a single persistent handle.
- `onProgress(received, total)` and `isCanceled()` callbacks to `Smb2Pool.streamFile`. Cancellation throws `Smb2Exception`; the handle is always closed.
- `Finalizer` on `Smb2PoolHandle` that best-effort-closes handles leaked by the caller. Safety net only — prefer explicit `closeHandle` or `withFile` for deterministic cleanup.

### Fixed
- `streamFile` was implemented on top of `readFileRange`, which does `open + pread + close` per chunk — a 50 MiB read in 1 MiB chunks meant 50 SMB2 Create/Close pairs on the wire. It now uses a single persistent handle (1 Create + N Reads + 1 Close) and chunks at libsmb2's server-negotiated `MaxReadSize`.
- `Smb2Pool.fsyncHandle` and `ftruncateHandle` now go through the auto-reconnect path. A disconnect mid-operation previously surfaced a raw worker-send failure instead of a clean reconnect + retry.
- `closeHandle` is idempotent; calling it twice on the same handle is a no-op (previously it would fail with "Invalid handle" on the second call).

### Removed
- `Smb2Isolate`. It duplicated `Smb2Pool(workers: 1)` with a divergent error format and no auto-reconnect. Use `Smb2Pool.connect(..., workers: 1)` instead.

### Docs
- Rewrote the README around `Smb2Pool` as the default entry point. New sections: Scoped File Access (`withFile`), Download to File, Low-Level File Handles.

### Example
- New demo cards in the example app for `withFile`, `downloadToFile`, `openFileWithSize`, `fsyncHandle`, and an Error Classification card that exercises `stat` / `exists` / `deleteFile` on missing paths and reports the resolved `Smb2ErrorType`. Wired `onProgress` into the `streamFile` card.

### Build
- Patched libsmb2's completion callbacks (`create_cb_1`, `fstat_cb_1`, `getinfo_cb_3`, `trunc_cb_3`, `rename_cb_3`, `ftrunc_cb_1`) to populate the NT error on the context via `smb2_set_nterror`. Previously `stat`/`exists`/`mkdir`/`rmdir`/`deleteFile`/`rename`/`truncate`/`ftruncate` silently surfaced as `Smb2ErrorType.unknown` with `errno=0` and an empty message on any failure — so `exists()` could not detect `fileNotFound` and `mkdir()` could not detect `alreadyExists`.
- Updated binaries to `libsmb2-r4`.


## [0.0.5] - 12-04-2026

### Fixed
- Incorrect lib version in `.podspec`.


## [0.0.4] - 12-04-2026

### Fixed
- Linux `libsmb2.so` was built as ARM64 (Docker default on Apple Silicon) and failed to load on x86_64 hosts; build now forces `--platform=linux/amd64`.
- Windows `libsmb2.dll` had unbundled MinGW runtime dependencies (`libgcc_s_seh-1.dll`, `libwinpthread-1.dll`); now statically linked with `-static -static-libgcc`.
- `Smb2Exception: Poll failed` on Android and Linux during connect — patched libsmb2 `sync.c` to retry `poll()` on `EINTR` (signals from ART/Dart VM were aborting the syscall).

### Build
- Updated binaries to `libsmb2-r3`.


## [0.0.3] - 12-04-2026

### Fixed
- Transport failures (`POLLHUP`, `POLLERR`, socket read/write errors, connect failures, lost tree-id after server-side idle teardown, …) now classify as `Smb2ErrorType.connection` instead of `unknown`.


## [0.0.2] - 09-04-2026

### Added
- Write operations, write handles, file management (`mkdir`, `rmdir`, `deleteFile`, `rename`, `truncate`), filesystem info (`statvfs`, `readlink`, `echo`, `fsync`, `ftruncate`, `exists`), security options (`seal`, `signing`, `version`), `Smb2Version` enum, `Smb2StatVfs` type.

### Fixed
- libsmb2 thread safety mutex, zero-copy isolate transfers, `Smb2Isolate.disconnect()` graceful shutdown, `streamWrite` no retry on failure, unified error encoding, write loop infinite hang, `fileSize()` now throws, `truncate()` negative length validation, allocator consistency, `listdir` capacity overflow, `TransferableTypedData` fresh per retry.

### Example
- Flutter app with server management, 12 read demo cards, 10 write demo cards.

### Build
- Updated binaries to `libsmb2-r2`.


## [0.0.1+2] - 08-04-2026

### Fixed
- AndroidManifest.xml.


## [0.0.1+1] - 08-04-2026

### Fixed
- Minor fixes.


## [0.0.1] - 07-04-2026

### Added
- Initial release.
