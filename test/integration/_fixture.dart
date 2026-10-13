// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Shared setup of the integration suites: the Samba container's settings
/// (from `.env.test`, or the defaults of `.env.test.example`), connected
/// clients and pools, and a scratch directory per suite on the share.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:dart_smb2/dart_smb2.dart';

/// The seed file `bootstrap.dart` keeps on the share: 1 MiB of zeros.
const seedFile = 'dart_smb2_seed.bin';

/// Size of [seedFile].
const seedSize = 1024 * 1024;

/// The Samba container's settings.
final class TestServer {
  final String host;
  final int port;
  final String share;
  final String user;
  final String password;

  const TestServer(this.host, this.port, this.share, this.user, this.password);

  /// Reads `test/integration/.env.test`, falling back to the example file.
  factory TestServer.load() {
    var file = File('test/integration/.env.test');
    if (!file.existsSync()) file = File('test/integration/.env.test.example');
    final env = <String, String>{};
    for (final line in file.readAsLinesSync()) {
      final t = line.trim();
      final eq = t.indexOf('=');
      if (t.isEmpty || t.startsWith('#') || eq <= 0) continue;
      env[t.substring(0, eq).trim()] = t.substring(eq + 1).trim();
    }
    final port = env['SMB2_HOST_PORT'] ?? '445';
    return TestServer(
      port == '445' ? '127.0.0.1' : '127.0.0.1:$port',
      int.parse(port),
      env['SMB2_SHARE'] ?? 'public',
      env['SMB2_USER'] ?? 'testuser',
      env['SMB2_PASS'] ?? 'testpass',
    );
  }
}

/// The server of this run.
final server = TestServer.load();

/// A connected sync client.
Smb2Client connectClient() => Smb2Client()
  ..connect(
    host: server.host,
    share: server.share,
    user: server.user,
    password: server.password,
  );

/// A connected pool, to the server or to [host] (a [TcpProxy]'s).
Future<Smb2Pool> connectPool({
  int workers = 2,
  Duration? timeout,
  String? host,
}) => Smb2Pool.connect(
  host: host ?? server.host,
  share: server.share,
  user: server.user,
  password: server.password,
  workers: workers,
  timeout: timeout ?? const Duration(seconds: 30),
);

/// A directory of its own on the share for one suite, so suites never see
/// each other's files. Created by [create], removed with everything in it
/// by [delete].
final class Scratch {
  /// Share-relative path of the directory.
  final String dir;

  Scratch(String suite)
    : dir =
          '$scratchPrefix${suite}_${Random().nextInt(1 << 32).toRadixString(16)}';

  /// [name] inside the directory.
  String path(String name) => '$dir/$name';

  /// Creates the directory.
  void create() {
    final c = connectClient();
    try {
      c.mkdir(dir);
    } finally {
      c.disconnect();
    }
  }

  /// Removes the directory and its content.
  void delete() {
    final c = connectClient();
    try {
      deleteTree(c, dir);
    } finally {
      c.disconnect();
    }
  }
}

/// The prefix of every [Scratch] directory.
const scratchPrefix = 'zz_';

/// Removes [dir] on the share and everything in it.
void deleteTree(Smb2Client c, String dir) {
  for (final e in c.listDirectory(dir)) {
    final p = '$dir/${e.name}';
    e.isDirectory ? deleteTree(c, p) : c.deleteFile(p);
  }
  c.rmdir(dir);
}

/// What a [TcpProxy] does with a new connection.
enum ProxyMode {
  /// Passes it through to the server.
  forward,

  /// Accepts it and closes it at once.
  refuse,

  /// Accepts it and never answers.
  blackhole,
}

/// A TCP proxy in front of the Samba container that a test can break:
/// cut its connections, freeze them, or refuse or swallow new ones. Pools
/// reach it at [host].
final class TcpProxy {
  final ServerSocket _server;
  final List<_Link> _links = [];
  final List<Socket> _swallowed = [];

  /// What happens to the next connections.
  ProxyMode mode = ProxyMode.forward;

  TcpProxy._(this._server);

  /// A proxy on a free port of the loopback.
  static Future<TcpProxy> start() async {
    final proxy = TcpProxy._(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    proxy._server.listen(proxy._accept);
    return proxy;
  }

  /// The host to connect a pool to.
  String get host => '127.0.0.1:${_server.port}';

  /// Connections passed through so far.
  int get forwarded => _links.length;

  Future<void> _accept(Socket client) async {
    switch (mode) {
      case ProxyMode.refuse:
        client.destroy();
      case ProxyMode.blackhole:
        _swallowed.add(client);
        client.done.ignore();
        client.listen((_) {}, onError: (Object _) {}, cancelOnError: true);
      case ProxyMode.forward:
        // ignore: close_sinks, the link closes it
        final Socket upstream;
        try {
          upstream = await Socket.connect('127.0.0.1', server.port);
        } on SocketException {
          client.destroy();
          return;
        }
        _links.add(_Link(client, upstream));
    }
  }

  /// Cuts connection [index] (in the order they were made), or every one.
  void drop([int? index]) {
    for (final l in index == null ? _links : [_links[index]]) {
      l.close();
    }
  }

  /// Stops passing data on the open connections, as a server that hangs.
  void freeze() {
    for (final l in _links) {
      l.pause();
    }
  }

  /// Passes data again after [freeze].
  void thaw() {
    for (final l in _links) {
      l.resume();
    }
  }

  /// Closes the proxy and every connection.
  Future<void> close() async {
    drop();
    for (final s in _swallowed) {
      s.destroy();
    }
    await _server.close();
  }
}

/// One proxied connection.
final class _Link {
  final Socket client;
  final Socket upstream;
  late final StreamSubscription<List<int>> _up;
  late final StreamSubscription<List<int>> _down;

  _Link(this.client, this.upstream) {
    // A cut connection fails its pending writes: nobody waits for them.
    client.done.ignore();
    upstream.done.ignore();
    _up = client.listen(
      (data) => _send(upstream, data),
      onDone: close,
      onError: (Object _) => close(),
    );
    _down = upstream.listen(
      (data) => _send(client, data),
      onDone: close,
      onError: (Object _) => close(),
    );
  }

  static void _send(Socket to, List<int> data) {
    try {
      to.add(data);
    } on Object {
      // Closed under us: the other side sees it on its own.
    }
  }

  void pause() {
    _up.pause();
    _down.pause();
  }

  void resume() {
    _up.resume();
    _down.resume();
  }

  void close() {
    client.destroy();
    upstream.destroy();
  }
}
