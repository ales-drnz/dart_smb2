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
import 'dart:io';
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
  Duration poll = const Duration(milliseconds: 50),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > limit) fail('not within $limit');
    await Future<void>.delayed(poll);
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
        // Right as the old worker dies, while the new one connects.
        await eventually(
          () => old.isDead,
          poll: const Duration(milliseconds: 1),
        );
        expect(identical(poolWorkers(pool).single, old), isTrue);
        final waiting = pool.stat(seedFile);
        final dir = scratch.path('made_during_reconnect');
        final making = pool.mkdir(dir);
        expect((await failing).size, seedSize);
        expect((await waiting).size, seedSize);
        await making;
        expect(await pool.exists(dir), isTrue);
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
      final freed = Worker.debugBuffersFreed;
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
      expect(Worker.debugBuffersFreed - freed, 1);
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
        final freed = Worker.debugBuffersFreed;
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
        expect(Worker.debugBuffersFreed - freed, 4);
        proxy.thaw();
        await pool.disconnect();
      },
    );

    test('of writes the worker ran are freed on the reply', () async {
      final pool = await connectPool(workers: 1);
      try {
        final w = poolWorkers(pool).single;
        final freed = Worker.debugBuffersFreed;
        await pool.writeFile(scratch.path('replied.bin'), Uint8List(1024));
        await pool.writeFileRange(scratch.path('replied.bin'), Uint8List(8));
        expect(w.debugHeldBuffers, 0);
        expect(Worker.debugBuffersFreed - freed, 2);
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

  group('handles and reconnects', () {
    test('a handle closed while it is opened again is not used', () async {
      final pool = await connectPool(workers: 1);
      try {
        final a = await pool.openFileWrite(scratch.path('closed_a.bin'));
        // A reconnect makes a stale; the next call on it reopens it.
        await poolWorkers(pool).single.failNext(1);
        await pool.stat(seedFile);
        // A file on the new worker, likely under a's old id.
        final victimPath = scratch.path('victim.bin');
        await pool.writeFile(victimPath, Uint8List.fromList('VVVV'.codeUnits));
        final victim = await pool.openFileWrite(victimPath);
        final write = pool.writeToHandle(a, Uint8List.fromList('XX'.codeUnits));
        await pool.closeHandle(a);
        await expectLater(write, throwsType(Smb2ErrorType.state));
        await pool.closeHandle(victim);
        expect(String.fromCharCodes(await pool.readFile(victimPath)), 'VVVV');
      } finally {
        await pool.disconnect();
      }
    });

    test(
      'a worker that crashes is reconnected without a failed call',
      () async {
        final pool = await connectPool();
        try {
          final w = poolWorkers(pool).first;
          w.crash();
          await eventually(
            () =>
                !identical(poolWorkers(pool).first, w) &&
                poolWorkers(pool).every((x) => x.isUsable),
          );
        } finally {
          await pool.disconnect();
        }
      },
    );

    test(
      'a cancelled request that hits a network failure reconnects',
      () async {
        final pool = await connectPool(workers: 1);
        try {
          final w = poolWorkers(pool).single;
          await w.failNext(1);
          final token = Smb2CancelToken();
          final abandoned = pool.stat(seedFile, cancelToken: token);
          token.cancel();
          await expectLater(abandoned, throwsType(Smb2ErrorType.cancelled));
          await eventually(() => !identical(poolWorkers(pool).single, w));
        } finally {
          await pool.disconnect();
        }
      },
    );

    test('a call that finds no worker says why the reconnect failed', () async {
      final pool = await connectPool(workers: 1, host: proxy.host);
      try {
        proxy
          ..mode = ProxyMode.refuse
          ..drop();
        // The first call fails over the dropped connection; the second one
        // finds the slot's worker dead and tries to reconnect it itself.
        for (var i = 0; i < 2; i++) {
          await expectLater(
            pool.stat(seedFile),
            throwsA(
              isA<Smb2Exception>()
                  .having((e) => e.isNetworkFailure, 'isNetworkFailure', isTrue)
                  .having(
                    (e) => e.message,
                    'message',
                    isNot(contains('worker isolate is gone')),
                  ),
            ),
          );
        }
      } finally {
        proxy.mode = ProxyMode.forward;
        await pool.disconnect();
      }
    });

    test('a timeout below a second bounds a request', () async {
      final pool = await connectPool(
        workers: 1,
        host: proxy.host,
        timeout: const Duration(milliseconds: 500),
      );
      try {
        // The frozen request times out (500 ms rounds up to 1 s, not down
        // to none), and the repeat goes over a new connection.
        proxy.freeze();
        final watch = Stopwatch()..start();
        await pool.echo();
        expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
      } finally {
        proxy.thaw();
        await pool.disconnect();
      }
    });

    test('a worker that never answers fails the spawn with timeout', () async {
      Worker.debugNeverReady = true;
      Worker.debugSpawnMargin = const Duration(seconds: 1);
      try {
        await expectLater(
          connectPool(workers: 1, timeout: const Duration(seconds: 1)),
          throwsType(Smb2ErrorType.timeout),
        );
      } finally {
        Worker.debugNeverReady = false;
        Worker.debugSpawnMargin = const Duration(seconds: 15);
      }
    });
  });

  group('closing before a delete or rename', () {
    late Smb2Pool pool;
    // The rename or delete goes to another worker than the close: only the
    // close's reply orders them.
    setUp(() async => pool = await connectPool(workers: 4));
    tearDown(() => pool.disconnect());

    test('a stream left early does not hold up a delete or rename', () async {
      final path = scratch.path('left_early.bin');
      await pool.writeFile(path, Uint8List(16 << 20));
      for (var i = 0; i < 10; i++) {
        // Leaving closes without waiting: the close may queue behind the
        // read ahead, while the rename goes to another worker.
        await for (final _ in pool.streamFile(path)) {
          break;
        }
        await pool.rename(path, '$path.moved');
        await for (final _ in pool.streamFile('$path.moved')) {
          break;
        }
        await pool.rename('$path.moved', path);
      }
      await for (final _ in pool.streamFile(path)) {
        break;
      }
      await pool.deleteFile(path);
      expect(await pool.exists(path), isFalse);
    });

    test('a file closed by closeHandle, a stream or withFile can go', () async {
      for (var i = 0; i < 20; i++) {
        final path = scratch.path('close_then_delete_$i.bin');
        await pool.writeFile(path, Uint8List(256 * 1024));
        final h = await pool.openFile(path);
        await pool.closeHandle(h);
        await pool.rename(path, '$path.a');
        await pool.streamFile('$path.a', chunkSize: 64 * 1024).drain<void>();
        await pool.rename('$path.a', '$path.b');
        await pool.withFile('$path.b', (f) => f.read(length: 16));
        await pool.streamWrite('$path.c', Stream.value(Uint8List(16)));
        await pool.rename('$path.c', '$path.d');
        await pool.deleteFile('$path.b');
        await pool.deleteFile('$path.d');
      }
    });
  });

  group('retries in the background', () {
    tearDown(() {
      Worker.debugConnectFailure = null;
      Smb2Pool.debugRefusedRetry = const Duration(minutes: 5);
    });

    test('a refused reconnect is retried slowly, then recovers', () async {
      final pool = await connectPool();
      try {
        Smb2Pool.debugRefusedRetry = const Duration(seconds: 3);
        Worker.debugConnectFailure = const Smb2Exception(
          'Refused for the test',
          type: Smb2ErrorType.auth,
        );
        final spawns = Worker.debugSpawns;
        poolWorkers(pool).first.crash();
        await eventually(() => Worker.debugSpawns == spawns + 1);
        // No fast retries for a refusal: still one attempt 1.5 s later.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(Worker.debugSpawns, spawns + 1);
        // The other worker serves the calls meanwhile.
        expect((await pool.stat(seedFile)).size, seedSize);
        Worker.debugConnectFailure = null;
        await eventually(() => poolWorkers(pool).every((w) => w.isUsable));
      } finally {
        await pool.disconnect();
      }
    });

    test('a reconnect that fails on the network is retried soon', () async {
      final pool = await connectPool();
      try {
        Worker.debugConnectFailure = const Smb2Exception(
          'Network down for the test',
          type: Smb2ErrorType.connection,
        );
        final spawns = Worker.debugSpawns;
        poolWorkers(pool).first.crash();
        // The first attempt, then a retry 1 s later.
        await eventually(() => Worker.debugSpawns >= spawns + 2);
        Worker.debugConnectFailure = null;
        await eventually(() => poolWorkers(pool).every((w) => w.isUsable));
      } finally {
        await pool.disconnect();
      }
    });
  });

  group('abandoned requests', () {
    test('free the write buffer and the read buffer they get back', () async {
      final pool = await connectPool(workers: 1);
      try {
        final w = poolWorkers(pool).single;
        final writes = Worker.debugBuffersFreed;
        final reads = Worker.debugReadBuffersFreed;
        final t1 = Smb2CancelToken();
        final write = pool.writeFile(
          scratch.path('abandoned.bin'),
          Uint8List(1024),
          cancelToken: t1,
        );
        t1.cancel();
        await expectLater(write, throwsType(Smb2ErrorType.cancelled));
        final t2 = Smb2CancelToken();
        final read = pool.readFile(seedFile, cancelToken: t2);
        t2.cancel();
        await expectLater(read, throwsType(Smb2ErrorType.cancelled));
        // Answered after both: their replies have arrived by then.
        await w.handleCount();
        expect(Worker.debugBuffersFreed - writes, 1);
        expect(Worker.debugReadBuffersFreed - reads, 1);
        expect(w.debugHeldBuffers, 0);
      } finally {
        await pool.disconnect();
      }
    });
  });

  group('cancel on a stuck network', () {
    late Smb2Pool pool;
    setUp(
      () async => pool = await connectPool(
        workers: 1,
        host: proxy.host,
        timeout: const Duration(seconds: 8),
      ),
    );
    tearDown(() async {
      proxy.thaw();
      await pool.disconnect();
    });

    /// Freezes the network once [call] has received its first chunk, then
    /// cancels: the call must end within a second.
    Future<void> endsAtOnce(
      Future<Object?> Function(Smb2CancelToken token, void Function() first)
      call,
    ) async {
      final token = Smb2CancelToken();
      final sinceCancel = Stopwatch();
      var frozen = false;
      void first() {
        if (frozen) return;
        frozen = true;
        proxy.freeze();
        Timer(const Duration(milliseconds: 300), () {
          sinceCancel.start();
          token.cancel();
        });
      }

      await expectLater(
        call(token, first).whenComplete(sinceCancel.stop),
        throwsType(Smb2ErrorType.cancelled),
      );
      expect(sinceCancel.elapsed, lessThan(const Duration(seconds: 1)));
    }

    test('downloadToFile', () async {
      final dir = await Directory.systemTemp.createTemp('dart_smb2_');
      try {
        await endsAtOnce(
          (token, first) => pool.downloadToFile(
            seedFile,
            '${dir.path}/out.bin',
            chunkSize: 64 * 1024,
            cancelToken: token,
            onProgress: (_, _) => first(),
          ),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('streamFile', () async {
      await endsAtOnce(
        (token, first) => pool
            .streamFile(seedFile, chunkSize: 64 * 1024, cancelToken: token)
            .map((_) => first())
            .drain<void>(),
      );
    });

    test('cancelling a stream subscription', () async {
      final first = Completer<void>();
      final sub = pool.streamFile(seedFile, chunkSize: 64 * 1024).listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      proxy.freeze();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final watch = Stopwatch()..start();
      await sub.cancel();
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });

    test('withFile', () async {
      await endsAtOnce(
        (token, first) => pool.withFile(seedFile, (file) async {
          await file.read(length: 1024);
          first();
          return file.read(offset: 1024, length: 1024);
        }, cancelToken: token),
      );
    });
  });

  group('streamFile', () {
    late Smb2Pool pool;
    setUp(() async => pool = await connectPool(workers: 1));
    tearDown(() => pool.disconnect());

    test('cancelling the subscription stops the reads', () async {
      final w = poolWorkers(pool).single;
      final first = Completer<void>();
      final sub = pool.streamFile(seedFile, chunkSize: 64 * 1024).listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      final watch = Stopwatch()..start();
      await sub.cancel();
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      await w.handleCount();
      expect(await w.handleCount(), 0);
      expect(w.load, 0);
    });

    test(
      'isCanceled turning true while the listener works stops there',
      () async {
        var stop = false;
        var afterStop = 0;
        await expectLater(
          pool
              .streamFile(
                seedFile,
                chunkSize: 128 * 1024,
                // ignore: deprecated_member_use_from_same_package
                isCanceled: () => stop,
              )
              .asyncMap((c) async {
                if (stop) afterStop++;
                await Future<void>.delayed(const Duration(milliseconds: 100));
                stop = true;
                return c;
              })
              .drain<void>(),
          throwsType(Smb2ErrorType.cancelled),
        );
        expect(afterStop, 0);
      },
    );

    test(
      'a token cancelled while the listener is paused ends the stream',
      () async {
        final w = poolWorkers(pool).single;
        final token = Smb2CancelToken();
        final chunks = <int>[];
        final done = Completer<Object?>();
        late StreamSubscription<Uint8List> sub;
        sub = pool
            .streamFile(seedFile, chunkSize: 64 * 1024, cancelToken: token)
            .listen(
              (c) {
                chunks.add(c.length);
                if (chunks.length == 1) sub.pause();
              },
              onError: (Object e) {
                if (!done.isCompleted) done.complete(e);
              },
              onDone: () {
                if (!done.isCompleted) done.complete(null);
              },
            );
        await eventually(() => chunks.isNotEmpty);
        token.cancel();
        // The handle closes while the listener is still paused.
        await eventually(() => w.load == 0);
        await w.handleCount();
        expect(await w.handleCount(), 0);
        sub.resume();
        final end = await done.future;
        expect(
          end,
          isA<Smb2Exception>().having(
            (e) => e.isCancelled,
            'isCancelled',
            true,
          ),
        );
        expect(chunks.length, 1);
        await sub.cancel();
      },
    );

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
