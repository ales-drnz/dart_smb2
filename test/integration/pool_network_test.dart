// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The pool against real network faults, through a TCP proxy that cuts,
/// freezes and refuses connections, and the races around reconnects,
/// cancellation and native buffers.
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
// ignore: implementation_imports, the fault injection is package-internal
import 'package:dart_smb2/src/pool/test_hooks.dart';
import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import '_fixture.dart';

Matcher throwsType(Smb2ErrorType type) =>
    throwsA(isA<Smb2Exception>().having((e) => e.type, 'type', type));

/// A write request's native buffer of [n] bytes, as the pool makes one.
int nativeBuffer(int n) => malloc<Uint8>(n).address;

/// Waits until [condition] holds, for up to [limit].
Future<void> eventually(
  bool Function() condition, {
  Duration limit = const Duration(seconds: 15),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > limit) fail('not within $limit');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final scratch = Scratch('network');
  late TcpProxy proxy;
  int alive = 0;

  setUpAll(scratch.create);
  tearDownAll(scratch.delete);
  setUp(() async {
    proxy = await TcpProxy.start();
    alive = Worker.debugAlive;
  });
  tearDown(() async {
    await proxy.close();
    // Nothing a test started outlives it.
    await eventually(() => Worker.debugAlive == alive);
  });

  group('a dropped connection', () {
    late Smb2Pool pool;
    setUp(() async => pool = await connectPool(workers: 1, host: proxy.host));
    tearDown(() => pool.disconnect());

    test('is reconnected and the call repeated', () async {
      proxy.drop();
      expect((await pool.stat(seedFile)).size, seedSize);
      expect(proxy.forwarded, 2);
    });

    test('keeps a read handle usable', () async {
      final handle = await pool.openFile(seedFile);
      proxy.drop();
      final data = await pool.readFromHandle(handle, length: 16);
      expect(data.length, 16);
      await pool.closeHandle(handle);
    });

    test('is not repeated for mkdir, which fails', () async {
      final dir = scratch.path('dropped_mkdir');
      proxy.drop();
      await expectLater(pool.mkdir(dir), throwsType(Smb2ErrorType.connection));
      expect(await pool.exists(dir), isFalse);
    });

    test('mid-stream still delivers the whole file', () async {
      var chunks = 0;
      final bytes = await pool
          .streamFile(seedFile, chunkSize: 64 * 1024)
          .map((c) {
            if (++chunks == 2) proxy.drop();
            return c.length;
          })
          .fold<int>(0, (a, b) => a + b);
      expect(bytes, seedSize);
    });
  });

  group('cancellation', () {
    test('ends a call waiting for a reconnect at once', () async {
      final pool = await connectPool(
        workers: 1,
        host: proxy.host,
        timeout: const Duration(seconds: 2),
      );
      try {
        proxy
          ..mode = ProxyMode.blackhole
          ..freeze();
        // Times out, then waits for a reconnect that cannot connect.
        final first = pool.stat(seedFile)..ignore();
        await eventually(() => poolWorkers(pool).single.isDead);
        final token = Smb2CancelToken();
        final second = pool.stat(seedFile, cancelToken: token);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final watch = Stopwatch()..start();
        token.cancel();
        await expectLater(second, throwsType(Smb2ErrorType.cancelled));
        expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
        await first.then<void>((_) {}, onError: (Object _) {});
      } finally {
        proxy
          ..mode = ProxyMode.forward
          ..thaw();
        await pool.disconnect();
      }
    });

    test('of one caller does not fail the others sharing a reopen', () async {
      final pool = await connectPool(workers: 1);
      try {
        final handle = await pool.openFile(seedFile);
        // A reconnect makes the handle stale: the next calls reopen it.
        await poolWorkers(pool).single.failNext(1);
        await pool.stat(seedFile);
        final token = Smb2CancelToken();
        final a = pool.readFromHandle(handle, length: 8, cancelToken: token);
        final b = pool.readFromHandle(handle, length: 8);
        token.cancel();
        await expectLater(a, throwsType(Smb2ErrorType.cancelled));
        expect((await b).length, 8);
        await pool.closeHandle(handle);
      } finally {
        await pool.disconnect();
      }
    });

    test('of a request leaves it in the worker\'s load', () async {
      final pool = await connectPool();
      try {
        final w = poolWorkers(pool).first;
        await w.hangNext();
        final token = Smb2CancelToken();
        final hung = w.call<Object?>(Op.stat, [seedFile], cancelToken: token);
        token.cancel();
        await expectLater(hung, throwsType(Smb2ErrorType.cancelled));
        // The worker never answers it: it still counts.
        expect(w.load, 1);
      } finally {
        await pool.disconnect();
      }
    });

    test('works on echo', () async {
      final pool = await connectPool(workers: 1);
      try {
        final token = Smb2CancelToken()..cancel();
        await expectLater(
          pool.echo(cancelToken: token),
          throwsType(Smb2ErrorType.cancelled),
        );
        await pool.echo();
      } finally {
        await pool.disconnect();
      }
    });
  });

  group('cleanup after cancel', () {
    test('opens cancelled in flight leave no handle open', () async {
      final pool = await connectPool(workers: 1);
      try {
        final w = poolWorkers(pool).single;
        final calls = <Future<Object?>>[];
        for (var i = 0; i < 20; i++) {
          final token = Smb2CancelToken();
          calls
            ..add(pool.openFile(seedFile, cancelToken: token))
            ..add(pool.openFileWithSize(seedFile, cancelToken: token));
          token.cancel();
        }
        for (final c in calls) {
          await expectLater(c, throwsType(Smb2ErrorType.cancelled));
        }
        // The first count is answered after every open: by then each
        // abandoned reply has arrived and sent its close, which the worker
        // runs before the second count.
        await w.handleCount();
        expect(await w.handleCount(), 0);
      } finally {
        await pool.disconnect();
      }
    });

    test('reads cancelled in flight free their buffers', () async {
      final pool = await connectPool(workers: 1);
      try {
        final w = poolWorkers(pool).single;
        for (var i = 0; i < 20; i++) {
          final token = Smb2CancelToken();
          final read = pool.readFile(seedFile, cancelToken: token);
          token.cancel();
          await expectLater(read, throwsType(Smb2ErrorType.cancelled));
        }
        await w.handleCount();
        expect(w.debugHeldBuffers, 0);
        expect(w.load, 0);
      } finally {
        await pool.disconnect();
      }
    });
  });

  group('reconnect', () {
    test('a call made during a reconnect waits for it', () async {
      final pool = await connectPool(workers: 1);
      try {
        final old = poolWorkers(pool).single;
        await old.failNext(1);
        final failing = pool.stat(seedFile);
        await eventually(() => old.isDead);
        final waiting = pool.stat(seedFile);
        expect((await failing).size, seedSize);
        expect((await waiting).size, seedSize);
        expect(identical(poolWorkers(pool).single, old), isFalse);
      } finally {
        await pool.disconnect();
      }
    });

    test(
      'a failure seen after the reconnect does not replace the new worker',
      () async {
        final pool = await connectPool(workers: 1);
        try {
          final old = poolWorkers(pool).single;
          // A hangs on the old worker; B fails and replaces it. A then fails
          // when the old worker is killed, and is repeated on the new one.
          await old.hangNext();
          final a = pool.stat(seedFile);
          await old.failNext(1);
          await pool.stat(seedFile);
          final fresh = poolWorkers(pool).single;
          expect(identical(fresh, old), isFalse);
          expect((await a).size, seedSize);
          expect(identical(poolWorkers(pool).single, fresh), isTrue);
        } finally {
          await pool.disconnect();
        }
      },
    );
  });

  group('a slot that cannot reconnect', () {
    test('hands its calls to the other workers, and recovers', () async {
      final pool = await connectPool(host: proxy.host);
      try {
        proxy
          ..drop(0)
          ..mode = ProxyMode.refuse;
        for (var i = 0; i < 10; i++) {
          expect((await pool.stat(seedFile)).size, seedSize);
        }
        // The failed slot keeps retrying in the background.
        proxy.mode = ProxyMode.forward;
        await eventually(
          () => poolWorkers(pool).every((w) => w.isUsable),
          limit: const Duration(seconds: 20),
        );
      } finally {
        await pool.disconnect();
      }
    });

    test('does not hold up disconnect while it connects', () async {
      final pool = await connectPool(
        workers: 1,
        host: proxy.host,
        timeout: const Duration(seconds: 10),
      );
      proxy
        ..mode = ProxyMode.blackhole
        ..drop();
      final call = pool.stat(seedFile)..ignore();
      await eventually(() => poolWorkers(pool).single.isDead);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final watch = Stopwatch()..start();
      await pool.disconnect();
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      await expectLater(call, throwsA(isA<Smb2Exception>()));
    });
  });

  group('native buffers', () {
    test('of writes sent to a closing worker are freed at once', () async {
      final pool = await connectPool(workers: 1);
      final w = poolWorkers(pool).single;
      final closing = w.close();
      await expectLater(
        w.call<void>(Op.writeFile, [
          scratch.path('closing.bin'),
          nativeBuffer(4),
          4,
          0,
        ]),
        throwsType(Smb2ErrorType.connection),
      );
      expect(w.debugHeldBuffers, 0);
      await closing;
      await pool.disconnect();
    });

    test(
      'of writes a killed worker never ran are freed once it exits',
      () async {
        final pool = await connectPool(
          workers: 1,
          host: proxy.host,
          timeout: const Duration(seconds: 2),
        );
        final w = poolWorkers(pool).single;
        proxy.freeze();
        final writes = [
          for (var i = 0; i < 4; i++)
            w.call<void>(Op.writeFile, [
              scratch.path('killed_$i.bin'),
              nativeBuffer(1 << 20),
              1 << 20,
              0,
            ]),
        ];
        await Future<void>.delayed(const Duration(milliseconds: 200));
        w.killForTest();
        for (final write in writes) {
          await expectLater(write, throwsType(Smb2ErrorType.connection));
        }
        // The worker may still be in the frozen write; once its timeout lets
        // it return, the isolate exits and every buffer is freed.
        await eventually(() => w.debugHeldBuffers == 0);
        proxy.thaw();
        await pool.disconnect();
      },
    );

    test('of writes the worker ran are freed on the reply', () async {
      final pool = await connectPool(workers: 1);
      try {
        final w = poolWorkers(pool).single;
        await pool.writeFile(scratch.path('replied.bin'), Uint8List(1024));
        expect(w.debugHeldBuffers, 0);
      } finally {
        await pool.disconnect();
      }
    });
  });

  test('connect fails at once when a worker exits before connecting', () async {
    Worker.debugExitBeforeConnect = true;
    try {
      final watch = Stopwatch()..start();
      await expectLater(connectPool(), throwsType(Smb2ErrorType.connection));
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    } finally {
      Worker.debugExitBeforeConnect = false;
    }
  });

  group('streamFile', () {
    late Smb2Pool pool;
    setUp(() async => pool = await connectPool(workers: 1));
    tearDown(() => pool.disconnect());

    test('isCanceled true from the start delivers nothing', () async {
      final chunks = <int>[];
      await expectLater(
        pool
            .streamFile(
              seedFile,
              chunkSize: 256 * 1024,
              // ignore: deprecated_member_use_from_same_package
              isCanceled: () => true,
            )
            .map((c) => chunks.add(c.length))
            .drain<void>(),
        throwsType(Smb2ErrorType.cancelled),
      );
      expect(chunks, isEmpty);
    });

    test('isCanceled turning true after the last chunk completes', () async {
      var delivered = 0;
      final bytes = await pool
          .streamFile(
            seedFile,
            chunkSize: 256 * 1024,
            // ignore: deprecated_member_use_from_same_package
            isCanceled: () => delivered == seedSize,
          )
          .map((c) => delivered += c.length)
          .last;
      expect(bytes, seedSize);
    });

    test(
      'a cancelled subscription ends quietly when the read ahead fails',
      () async {
        final errors = <Object>[];
        await runZonedGuarded(() async {
          final first = Completer<void>();
          final sub = pool.streamFile(seedFile, chunkSize: 64 * 1024).listen((
            _,
          ) {
            if (!first.isCompleted) first.complete();
          });
          await first.future;
          // The read ahead in flight fails with the worker.
          poolWorkers(pool).single.killForTest();
          await sub.cancel();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }, (e, _) => errors.add(e));
        expect(errors, isEmpty);
      },
    );
  });
}
