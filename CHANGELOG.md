## [0.0.6] - 24-04-2026

- **Core**: Added `Smb2Pool.withFile(path, body, {knownSize})` and scoped `Smb2File` — opens a read handle, runs the callback, guarantees `closeHandle` on any exit (exception, early return, cancellation). Replaces the `openFileWithSize` + `readFromHandle` + `closeHandle` boilerplate at every call site.
- **Core**: Added `Smb2Pool.downloadToFile(path, File destFile, {chunkSize, onProgress, isCanceled})` — one-call download of an SMB file to a local `File` streaming through a single persistent handle.
- **Core**: Added `onProgress(received, total)` and `isCanceled()` callbacks to `Smb2Pool.streamFile`. Cancellation throws `Smb2Exception`; the handle is always closed.
- **Core**: Added a `Finalizer` on `Smb2PoolHandle` that best-effort-closes handles leaked by the caller. Safety net only — prefer explicit `closeHandle` or `withFile` for deterministic cleanup.
- **Fixed**: `streamFile` was implemented on top of `readFileRange`, which does `open + pread + close` per chunk — a 50 MiB read in 1 MiB chunks meant 50 SMB2 Create/Close pairs on the wire. It now uses a single persistent handle (1 Create + N Reads + 1 Close) and chunks at libsmb2's server-negotiated `MaxReadSize`.
- **Fixed**: `Smb2Pool.fsyncHandle` and `ftruncateHandle` now go through the auto-reconnect path. A disconnect mid-operation previously surfaced a raw worker-send failure instead of a clean reconnect + retry.
- **Fixed**: `closeHandle` is idempotent; calling it twice on the same handle is a no-op (previously it would fail with "Invalid handle" on the second call).
- **Breaking**: Removed `Smb2Isolate`. It duplicated `Smb2Pool(workers: 1)` with a divergent error format and no auto-reconnect. Use `Smb2Pool.connect(..., workers: 1)` instead.
- **Example**: Added test cards for `withFile`, `downloadToFile`, `openFileWithSize`, `fsyncHandle`, and an Error Classification card that exercises `stat` / `exists` / `deleteFile` on missing paths and reports the resolved `Smb2ErrorType`. Wired `onProgress` into the `streamFile` card.
- **README**: Rewrote around `Smb2Pool` as the default entry point. New sections: Scoped File Access (`withFile`), Download to File, Low-Level File Handles.
- **Build**: Patched libsmb2's completion callbacks (`create_cb_1`, `fstat_cb_1`, `getinfo_cb_3`, `trunc_cb_3`, `rename_cb_3`, `ftrunc_cb_1`) to populate the NT error on the context via `smb2_set_nterror`. Previously `stat`/`exists`/`mkdir`/`rmdir`/`deleteFile`/`rename`/`truncate`/`ftruncate` silently surfaced as `Smb2ErrorType.unknown` with `errno=0` and an empty message on any failure — so `exists()` could not detect `fileNotFound` and `mkdir()` could not detect `alreadyExists`. 10 previously-failing integration tests now pass.
- **Build**: Updated binaries to `libsmb2-r4`.

## [0.0.5] - 12-04-2026

- **Fixed**: Incorrect lib version in `.podspec`.

## [0.0.4] - 12-04-2026

- **Fixed**: Linux `libsmb2.so` was built as ARM64 (Docker default on Apple Silicon) and failed to load on x86_64 hosts; build now forces `--platform=linux/amd64`.
- **Fixed**: Windows `libsmb2.dll` had unbundled MinGW runtime dependencies (`libgcc_s_seh-1.dll`, `libwinpthread-1.dll`); now statically linked with `-static -static-libgcc`.
- **Fixed**: `Smb2Exception: Poll failed` on Android and Linux during connect — patched libsmb2 `sync.c` to retry `poll()` on `EINTR` (signals from ART/Dart VM were aborting the syscall).
- **Build**: Updated binaries to `libsmb2-r3`.

## [0.0.3] - 12-04-2026

- **Fixed**: transport failures (`POLLHUP`, `POLLERR`, socket read/write errors, connect failures, lost tree-id after server-side idle teardown, …) now classify as `Smb2ErrorType.connection` instead of `unknown`.

## [0.0.2] - 09-04-2026

- **Core**: write operations, write handles, file management (`mkdir`, `rmdir`, `deleteFile`, `rename`, `truncate`), filesystem info (`statvfs`, `readlink`, `echo`, `fsync`, `ftruncate`, `exists`), security options (`seal`, `signing`, `version`), `Smb2Version` enum, `Smb2StatVfs` type, native binaries updated to `libsmb2-r2`.
- **Fixed**: libsmb2 thread safety mutex, zero-copy isolate transfers, `Smb2Isolate.disconnect()` graceful shutdown, `streamWrite` no retry on failure, unified error encoding, write loop infinite hang, `fileSize()` now throws, `truncate()` negative length validation, allocator consistency, `listdir` capacity overflow, `TransferableTypedData` fresh per retry.
- **Example**: Flutter app with server management, 12 read tests, 10 write tests.
- **Build**: Updated binaries to `libsmb2-r2`.

## [0.0.1+2] - 08-04-2026

- Fixed AndroidManifest.xml.

## [0.0.1+1] - 08-04-2026

- Minor fixes.

## [0.0.1] - 07-04-2026

- Initial release.
