// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// On-device smoke test for dart_smb2.
//
// Scope: the libsmb2 the build hook bundles (libdart_smb2.so on Android and
// Linux, dart_smb2.dll on Windows, libdart_smb2.framework on iOS and macOS)
// loads on the device, in the main isolate and in worker isolates, and the
// pool drives it end to end. The host suites in test/ cover the Dart side
// in depth; this one stays shallow and checks what changes per platform.
//
// The offline group runs everywhere. The server group runs when the test
// is given a server:
//
//   flutter test integration_test -d <device> \
//     --dart-define=SMB2_TEST_HOST=10.0.2.2 \
//     --dart-define=SMB2_TEST_SHARE=public \
//     --dart-define=SMB2_TEST_USER=testuser \
//     --dart-define=SMB2_TEST_PASS=testpass
//
// against the Samba container of test/integration (10.0.2.2 is the host's
// loopback from an Android emulator), or any share holding the 1 MiB seed
// file `dart_smb2_seed.bin` that the container's bootstrap writes.

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

const _host = String.fromEnvironment('SMB2_TEST_HOST');
const _share = String.fromEnvironment(
  'SMB2_TEST_SHARE',
  defaultValue: 'public',
);
const _user = String.fromEnvironment(
  'SMB2_TEST_USER',
  defaultValue: 'testuser',
);
const _pass = String.fromEnvironment(
  'SMB2_TEST_PASS',
  defaultValue: 'testpass',
);

const _seed = 'dart_smb2_seed.bin';
const _seedSize = 1024 * 1024;

Matcher _failsWith(bool Function(Smb2Exception e) test, String what) =>
    throwsA(isA<Smb2Exception>().having(test, what, isTrue));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('offline', () {
    testWidgets('libsmb2 loads and a client starts unconnected', (_) async {
      final client = Smb2Client();
      expect(client.isConnected, isFalse);
      expect(
        () => client.listDirectory(''),
        _failsWith((e) => e.type == Smb2ErrorType.state, 'state'),
      );
    });

    testWidgets('a connection refused is a network failure', (_) async {
      // Port 1 of the loopback: nothing listens there.
      expect(
        () => Smb2Client().connect(
          host: '127.0.0.1:1',
          share: 'x',
          timeout: const Duration(seconds: 5),
        ),
        _failsWith((e) => e.isNetworkFailure, 'isNetworkFailure'),
      );
    });

    testWidgets('worker isolates load libsmb2 in parallel', (_) async {
      // Each isolate creates and frees contexts at the same time, which
      // exercises the context-list lock of the bundled build.
      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          Isolate.run(() {
            for (var j = 0; j < 500; j++) {
              Smb2Client().disconnect();
            }
            try {
              Smb2Client().connect(
                host: '127.0.0.1:1',
                share: 'x',
                timeout: const Duration(seconds: 5),
              );
              return 'connected';
            } on Smb2Exception catch (e) {
              return e.isNetworkFailure ? 'network' : e.type.name;
            }
          }),
      ]);
      expect(results, everyElement('network'));
    });

    testWidgets('a pool that cannot connect fails and leaves nothing', (
      _,
    ) async {
      await expectLater(
        Smb2Pool.connect(
          host: '127.0.0.1:1',
          share: 'x',
          workers: 2,
          timeout: const Duration(seconds: 5),
        ),
        _failsWith((e) => e.isNetworkFailure, 'isNetworkFailure'),
      );
    });
  });

  group('server', () {
    late Smb2Pool pool;
    late String dir;

    setUpAll(() async {
      pool = await Smb2Pool.connect(
        host: _host,
        share: _share,
        user: _user,
        password: _pass,
        workers: 2,
        timeout: const Duration(seconds: 15),
      );
      dir = 'zz_device_${DateTime.now().microsecondsSinceEpoch}';
      await pool.mkdir(dir);
    });

    tearDownAll(() async {
      for (final e in await pool.listDirectory(dir)) {
        await pool.deleteFile('$dir/${e.name}');
      }
      await pool.rmdir(dir);
      await pool.disconnect();
    });

    testWidgets('lists the shares and the share', (_) async {
      final shares = await Smb2Pool.listSharesOn(
        host: _host,
        user: _user,
        password: _pass,
      );
      expect(shares.map((s) => s.name), contains(_share));
      final names = (await pool.listDirectory('')).map((e) => e.name);
      expect(names, contains(_seed));
    });

    testWidgets('reads, streams and downloads the seed', (_) async {
      expect((await pool.stat(_seed)).size, _seedSize);
      expect((await pool.readFile(_seed)).length, _seedSize);
      var streamed = 0;
      await for (final chunk in pool.streamFile(_seed, chunkSize: 256 << 10)) {
        streamed += chunk.length;
      }
      expect(streamed, _seedSize);
      final tmp = await getTemporaryDirectory();
      final target = '${tmp.path}/dart_smb2_seed_copy.bin';
      expect(await pool.downloadToFile(_seed, target), _seedSize);
      expect(File(target).lengthSync(), _seedSize);
      File(target).deleteSync();
    });

    testWidgets('writes, renames and deletes', (_) async {
      final data = Uint8List.fromList(List.generate(70000, (i) => i & 0xff));
      await pool.writeFile('$dir/a.bin', data);
      await pool.rename('$dir/a.bin', '$dir/b.bin');
      expect(await pool.readFile('$dir/b.bin'), data);
      await pool.streamWrite('$dir/c.bin', Stream.fromIterable([data, data]));
      expect((await pool.stat('$dir/c.bin')).size, data.length * 2);
      await pool.deleteFile('$dir/b.bin');
      expect(await pool.exists('$dir/b.bin'), isFalse);
    });

    testWidgets('a cancel token ends a read', (_) async {
      final token = Smb2CancelToken()..cancel();
      await expectLater(
        pool.readFile(_seed, cancelToken: token),
        _failsWith((e) => e.isCancelled, 'isCancelled'),
      );
      expect((await pool.stat(_seed)).size, _seedSize);
    });

    testWidgets('a missing path is notFound', (_) async {
      await expectLater(
        pool.stat('$dir/missing'),
        _failsWith((e) => e.isNotFound, 'isNotFound'),
      );
    });
  }, skip: _host.isEmpty ? 'no SMB2_TEST_HOST: offline only' : false);
}
