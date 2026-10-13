# Migrating to 0.2.0

0.2.0 bundles libsmb2 through a build hook instead of a Flutter plugin,
rebuilds the error model on the server's NT status, and adds cancel
tokens and atomic downloads. Most apps need the first three sections.

## libsmb2 comes from a build hook

dart_smb2 is a plain Dart package. The Gradle task, the podspecs, the
SwiftPM manifests and the CMake files are gone: a Dart build hook
downloads the binary for each target, checks its SHA-256 and bundles it.

- The package needs Dart 3.10, and Flutter 3.38 in a Flutter app.
- An Android app needs `minSdk` 24, which the binaries are built for: the
  hook fails the build below it.
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
| `Smb2ErrorType.classify(message, errno)` | `Smb2ErrorType.fromFailure(message: message, errno: errno)` |

The old names still work and are deprecated, except the positional
constructor of `Smb2Exception`. `Smb2ErrorType.fromErrno(errno)` keeps
working and now reads the errno as the running platform numbers it (pass
`os:` for another one).

`Smb2ErrorType.fileNotFound` is an alias of `notFound`, not a value of its
own: `type.name` is `notFound`, and `Smb2ErrorType.values` does not list
it. The values, their order and `toString()` changed, so do not persist an
error type by index or by name across versions. `Smb2ErrorType` has new
values, so an exhaustive `switch` needs cases (or a default) for
`notEmpty`, `isADirectory`, `inUse`, `notSupported`, `state` and
`cancelled`.

`errno` (and `errorCode`) is the errno of the failed call, or, for an open
or a listing, which return none, the errno of the server's status. It is
null for a transport failure, where 0.1.x read whatever status an earlier
call had left. Check `isNetworkFailure` or `isNotFound` rather than errno
values.

Some failures change type:

- a closed pool, a closed handle and a client that is not connected
  report `state`, not `unknown`;
- `Smb2Pool.connect()` with wrong credentials reports `auth`, not
  `unknown` (the worker's own error, not "Worker failed to start");
- `Smb2Pool.connect()` and `Smb2Client.connect()` with a user the server
  does not know report `auth`, or `accessDenied` from a server that maps
  unknown users to guest and refuses the guest at the tree connect (the
  same answer as for a known user without access to the share);
- a host name that does not resolve reports `connection`, not `io`;
- `truncate` of a directory reports `isADirectory`; it used to return
  without doing anything;
- `rmdir` of a directory with entries reports `notEmpty`, and `rmdir` of a
  file `notADirectory`; they used to return without removing the
  directory, and to delete the file;
- `deleteFile` of a directory reports `isADirectory`; it used to delete an
  empty one and to return without doing anything on one with entries;
- a server out of resources (too many open files, no memory) reports
  `inUse`, which `isTransient` covers, and a read-only share
  `accessDenied`;
- a stopped stream or download reports `cancelled`;
- `Smb2Pool.connect(workers: 0)` throws `invalidParam`; it used to make a
  pool without workers.

## Downloads and cancellation

`downloadToFile()` takes the destination as a path and writes it
atomically: a temporary file next to it, renamed once complete and
removed on failure. Drop your own `.part` and rename logic.

| 0.1.x | 0.2.0 |
| --- | --- |
| `pool.downloadToFile(path, File(dest))` | `pool.downloadToFile(path, dest)` |
| `isCanceled: () => stopped` | `cancelToken: token`, then `token.cancel()` |
| catching `Smb2Exception('Read canceled')` | `on Smb2Exception catch (e) { if (e.isCancelled) ... }` |

`isCanceled` still works on `streamFile` and `downloadToFile`, and is
deprecated: it is asked before each chunk, as before, but it cannot stop a
read in progress, which a token does.

```dart
final token = Smb2CancelToken();
final download = pool.downloadToFile(remotePath, localPath, cancelToken: token);
// The user pressed stop:
token.cancel();
```

Every call on a connected pool takes a `cancelToken`, except
`closeHandle`, `disconnect` and the deprecated `listShares`, so a page can cancel its listings and
reads the same way it cancels dart_plex and dart_jellyfin calls.

## Calls that are not repeated

After a network failure the pool reconnects the worker and repeats the
call, as before, except for `mkdir`, `rmdir`, `deleteFile` and `rename`:
the server may have done them before the connection dropped. Their
network failure now reaches you; check the outcome (`exists`) or call
again if that suits your app.

## Timeouts

`timeout: Duration` replaces `timeoutSeconds: int` on `connect`,
`listSharesOn`, `Smb2Client.connect` and `Smb2Client.listShares`. The old
argument still works and is deprecated.

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
  has `path`, `writable` and `isClosed`. `closed` (now read-only) and
  `refreshFinalizer()` (which does nothing now) still work and are
  deprecated.
- `Smb2File` is made by `Smb2Pool.withFile`; its constructor is internal.
