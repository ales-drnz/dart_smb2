Connect a pool to a share, list the shares of a server and disconnect.

`Smb2Pool` is the entry point. It runs a few worker isolates, each with its own connection to the share and its own `Smb2Client`, the synchronous client over libsmb2. Your code calls the pool from any isolate. Each call goes to the least busy worker, and its result comes back without blocking the caller.

<img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/diagrams/architecture.png" width="100%" alt="Architecture: your code calls Smb2Pool, which sends each request to one of its worker isolates; each worker runs an Smb2Client over a libsmb2 context of its own and holds a connection to the SMB server">

<img src="https://raw.githubusercontent.com/ales-drnz/dart_smb2/main/imgs/diagrams/pool_lifecycle.png" width="100%" alt="Pool lifecycle: Smb2Pool.connect, calls, withFile and streamFile, disconnect">

## Connecting a pool

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

## Connection options

| Argument | Default | Description |
| :--- | :--- | :--- |
| `user`, `password`, `domain` | none | NTLM credentials. No user, or a null password, means an anonymous logon; `password: ''` logs on to an account without a password |
| `workers` | 4 | Isolates, each with its own connection |
| `timeout` | 30 s | Bounds every request, the connection included |
| `seal` | `false` | Require SMB3 encryption: AES-256-GCM or AES-128-GCM on SMB 3.1.1, AES-128-CCM on 3.0 |
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

## Encryption and signing

libsmb2 signs and encrypts through OpenSSL's libcrypto, which the bundled library carries. With `seal: true` on SMB 3.1.1 it offers AES-256-GCM, AES-128-GCM and AES-128-CCM, in that order, and the server picks one (Windows Server 2025 picks AES-256-GCM, Samba AES-128-GCM by default); SMB 3.0 and 3.0.2 always use AES-128-CCM. The order is libsmb2's: it has no setting for it, so neither has dart_smb2. Signing uses AES-CMAC on SMB 3, HMAC-SHA256 on SMB 2.

### Windows 11 24H2 and Windows Server 2025

From Windows 11 24H2 and Windows Server 2025 on, a Windows machine that shares folders requires every session to be signed, and its guest account is off:

- libsmb2 signs whenever the server asks for it, so these shares work without `signing: true`; set it to refuse servers that do not sign;
- a signed session needs a real logon: without a user (anonymous) or as guest there is no key to sign with, and the connection fails with `auth` or `accessDenied`. Pass an account of that machine, or a Microsoft account's email and password;
- the same versions also stop Windows itself, as a client, from logging on to other servers as guest ("insecure guest logons"). That rule is Windows' own: dart_smb2 can still reach a NAS share that allows guests, unless the NAS requires signing too.

## Listing the shares of a server

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

## Paths

Paths are relative to the share: `''` is its root, `Album/cover.jpg` a file in it. A leading slash is dropped and backslashes become slashes, so `/Album\cover.jpg` names the same file. A path with a NUL character fails with `invalidParam` before it reaches the server.

## Disconnecting

```dart
await pool.disconnect();
```

Each worker finishes the requests it has already been sent, closes its open files and logs off, and its isolate ends. A worker that does not finish within 5 seconds is killed. A reconnect in progress is aborted, and later calls fail with a `state` error.

When a connection drops while the pool is open, the pool reconnects on its own. See [Errors and cancellation](https://pub.dev/documentation/dart_smb2/latest/topics/Errors%20and%20cancellation-topic.html).
