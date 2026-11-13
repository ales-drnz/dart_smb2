// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The build hook's download, against a server of the test's own: the
/// cache, the checksum and the retries.
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as hook;

const _asset = 'libsmb2_test.so';
const _body = [1, 2, 3, 4, 5, 6, 7, 8];
final _sha = '${sha256.convert(_body)}';

void main() {
  late Directory cache;
  late HttpServer server;
  late int requests;

  /// What the server does with each request, by its number from 1.
  late FutureOr<void> Function(HttpRequest request, int n) answer;

  Future<void> ok(HttpRequest request, [List<int> body = _body]) {
    request.response.add(body);
    return request.response.close();
  }

  Future<void> status(HttpRequest request, int code) {
    request.response.statusCode = code;
    return request.response.close();
  }

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('dart_smb2_fetch_');
    requests = 0;
    answer = (request, _) => ok(request);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      expect(request.uri.path, '/release/$_asset');
      try {
        await answer(request, ++requests);
      } on Exception {
        // A connection the test cut on purpose.
      }
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await cache.delete(recursive: true);
  });

  Future<File> fetch({Map<String, String>? checksums}) => hook.fetchAsset(
    _asset,
    cache.uri,
    baseUrl: 'http://127.0.0.1:${server.port}/release',
    checksums: checksums ?? {_asset: _sha},
    retryDelay: const Duration(milliseconds: 10),
  );

  /// Every file under the cache, relative to it.
  List<String> cached() => [
    for (final e in cache.listSync(recursive: true))
      if (e is File) e.path.substring(cache.path.length + 1),
  ];

  final cachedName = '$_sha${Platform.pathSeparator}$_asset';

  test('a download lands under its checksum', () async {
    final file = await fetch();
    expect(file.readAsBytesSync(), _body);
    expect(requests, 1);
    expect(cached(), [cachedName]);
  });

  test('a second build takes the cached file', () async {
    await fetch();
    final file = await fetch();
    expect(file.readAsBytesSync(), _body);
    expect(requests, 1);
  });

  test('a cached file with other bytes is downloaded again', () async {
    final stale = File('${cache.path}/$cachedName');
    await stale.create(recursive: true);
    await stale.writeAsBytes([0]);
    final file = await fetch();
    expect(file.readAsBytesSync(), _body);
    expect(requests, 1);
    expect(cached(), [cachedName]);
  });

  test('a download with another checksum fails and caches nothing', () async {
    answer = (request, _) => ok(request, [9, 9, 9]);
    await expectLater(
      fetch(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('SHA-256 mismatch'), contains(_asset)),
        ),
      ),
    );
    // A wrong file is not a network failure: it is not asked for again.
    expect(requests, 1);
    expect(cached(), isEmpty);
  });

  test('an asset without a pinned checksum is not asked for', () async {
    for (final checksums in [
      <String, String>{},
      {_asset: ''},
    ]) {
      await expectLater(
        fetch(checksums: checksums),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('no SHA-256 pinned for $_asset'),
          ),
        ),
      );
    }
    expect(requests, 0);
  });

  for (final code in [500, 503, 408, 429]) {
    test('a $code is tried again', () async {
      answer = (request, n) => n == 1 ? status(request, code) : ok(request);
      final file = await fetch();
      expect(file.readAsBytesSync(), _body);
      expect(requests, 2);
    });
  }

  test('a transfer cut half way is tried again from the start', () async {
    answer = (request, n) async {
      if (n > 1) return ok(request);
      // The answer by hand: three of the eight bytes it announces.
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.write(
        'HTTP/1.1 200 OK\r\ncontent-length: ${_body.length}\r\n\r\n',
      );
      socket.add(_body.sublist(0, 3));
      await socket.flush();
      socket.destroy();
    };
    final file = await fetch();
    expect(file.readAsBytesSync(), _body);
    expect(requests, 2);
    expect(cached(), [cachedName]);
  });

  test('a 404 is not tried again and names the user define', () async {
    answer = (request, _) => status(request, 404);
    await expectLater(
      fetch(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('cannot download $_asset'),
            contains('HTTP 404'),
            contains('hooks.user_defines.dart_smb2.libsmb2'),
          ),
        ),
      ),
    );
    expect(requests, 1);
    expect(cached(), isEmpty);
  });

  test('a server that keeps failing ends the build at the third try', () async {
    answer = (request, _) => status(request, 502);
    await expectLater(
      fetch(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('HTTP 502'),
        ),
      ),
    );
    expect(requests, 3);
    expect(cached(), isEmpty);
  });
}
