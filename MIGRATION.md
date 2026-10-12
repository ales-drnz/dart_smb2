# Migrating to 0.2.0

0.2.0 bundles libsmb2 through a build hook instead of a Flutter plugin,
rebuilds the error model on the server's NT status, and adds cancel
tokens and atomic downloads. Most apps need the first three sections.

## libsmb2 comes from a build hook

dart_smb2 is a plain Dart package. The Gradle task, the podspecs, the
SwiftPM manifests and the CMake files are gone: a Dart build hook
downloads the binary for each target, checks its SHA-256 and bundles it.

- The package needs Dart 3.10, and Flutter 3.38 in a Flutter app.
- The first build of each target needs network access, and so does the
  first build after `flutter clean`, which removes the download.
- The bundled files are `libdart_smb2.so` (Android, Linux),
  `dart_smb2.dll` (Windows) and `libdart_smb2.framework` (iOS, macOS).
  Scripts that looked for `libsmb2.so` or `libsmb2.framework` in the app
  bundle need the new names.
- After upgrading, run `flutter pub get`: the generated plugin registrants
  drop dart_smb2, and `pod install` removes its pod.

To build offline or with a libsmb2 of your own, point the hook at local
files in the app's `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    dart_smb2:
      libsmb2: path/to/libsmb2
```

This replaces libsmb2-scripts' `lib-local` / `lib-remote` switch.

## Errors

`Smb2Exception` takes named arguments, and its type now comes from the
NT status the server answered with, so it reads the same on every
platform (Windows errors were misclassified before).

| 0.1.x | 0.2.0 |
| --- | --- |
| `Smb2Exception(message, errno, type)` | `Smb2Exception(message, type: type, errno: errno)` |
| `e.errorCode` | `e.errno`, and `e.ntStatus` for the server's status |
| `e.isConnectionError` | `e.isNetworkFailure`, or `e.isTransient` to include a file in use |
| `Smb2ErrorType.fileNotFound` | `Smb2ErrorType.notFound`, or `e.isNotFound` |
| `e.type == Smb2ErrorType.auth` | `e.isAuthError` |

The old names still work and are deprecated. `Smb2ErrorType` has new
values, so an exhaustive `switch` needs cases (or a default) for
`notEmpty`, `isADirectory`, `inUse`, `notSupported`, `state` and
`cancelled`. Some failures change type:

- a closed pool, a closed handle and a client that is not connected
  report `state`, not `unknown`;
- `Smb2Pool.connect()` with wrong credentials reports `auth`, not
  `unknown` (the worker's own error, not "Worker failed to start");
- `rmdir` of a directory with entries reports `notEmpty`; it used to
  return without removing it;
- a stopped stream or download reports `cancelled`.

## Downloads and cancellation

`downloadToFile()` takes the destination as a path and writes it
atomically: a temporary file next to it, renamed once complete and
removed on failure. Drop your own `.part` and rename logic.

| 0.1.x | 0.2.0 |
| --- | --- |
| `pool.downloadToFile(path, File(dest))` | `pool.downloadToFile(path, dest)` |
| `isCanceled: () => stopped` | `cancelToken: token`, then `token.cancel()` |
| catching `Smb2Exception('Read canceled')` | `on Smb2Exception catch (e) { if (e.isCancelled) ... }` |

```dart
final token = Smb2CancelToken();
final download = pool.downloadToFile(remotePath, localPath, cancelToken: token);
// The user pressed stop:
token.cancel();
```

Every pool call takes a `cancelToken`, so a page can cancel its listings
and reads the same way it cancels dart_plex and dart_jellyfin calls.

## Calls that are not repeated

After a network failure the pool reconnects the worker and repeats the
call, as before, except for `mkdir`, `rmdir`, `deleteFile` and `rename`:
the server may have done them before the connection dropped. Their
network failure now reaches you; check the outcome (`exists`) or call
again if that suits your app.

## Timeouts

`timeout: Duration` replaces `timeoutSeconds: int` on `connect`,
`listSharesOn` and `Smb2Client.connect`. The old argument still works and
is deprecated.

```dart
final pool = await Smb2Pool.connect(
  host: host,
  share: share,
  timeout: const Duration(seconds: 10),
);
```

## The synchronous client

`Smb2Client`'s method names now match the pool's. The old ones still work
and are deprecated.

| 0.1.x | 0.2.0 |
| --- | --- |
| `Smb2Client.open()` | `Smb2Client()` |
| `client.listShares(host: ...)` | `Smb2Client.listShares(host: ...)`, static |
| `openFileHandle`, `openFileHandleWrite` | `openFile`, `openFileWrite` |
| `readHandle`, `writeHandle` | `readFromHandle`, `writeToHandle` |
| `fsync`, `ftruncate` | `fsyncHandle`, `ftruncateHandle` |
| `handle.isValid` | `!handle.isClosed` |

`readFileRange()` and `readFromHandle()` return the whole range asked for
(fewer bytes only at the end of the file); they used to stop at the
server's MaxReadSize. A closed handle can be closed again; any other use
throws a `state` error instead of reaching freed memory.

## Types

- `Smb2Stat` has `accessed`, `changed` and `attributes` (`isHidden`), and
  its times keep their microseconds. Code that builds an `Smb2Stat`
  passes `accessed` and `changed`.
- `Smb2ShareInfo` has `remark`.
- The public classes are `final`: wrap them instead of extending or
  implementing them.
- `Smb2PoolHandle` no longer exposes `worker`, `id` or `markClosed()`; it
  has `path`, `writable` and `isClosed`.
