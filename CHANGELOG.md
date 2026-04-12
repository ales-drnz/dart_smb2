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
