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
