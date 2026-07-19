// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

@Tags(['integration'])

/// Concurrency / fault-tolerance regression tests for the Smb2Pool
/// internals. These exercise the bugs called out as H2 / H3 / M2 / M4
/// in the 0.1.0 code review, using the worker's `__inject_*` fault
/// injection knobs to make the failure modes deterministic instead of
/// relying on real-network flakiness.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
// ignore: implementation_imports — needs poolWorkers() to drive
// fault injection and the @internal Worker.killForTest hook.
import 'package:dart_smb2/src/pool/test_hooks.dart';
import 'package:test/test.dart';

import '_fixture.dart';

void main() {
  Future<Smb2Pool> connect({int workers = 1}) =>
      poolFromCache(workers: workers);

  group('H3 — single-flight reconnect under parallel failures', () {
    test('5 parallel ops failing together reconnect the worker once', () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      final initialWorker = poolWorkers(pool).single;

      // Set the worker up to reject the next 5 commands with a connection
      // error. The pool's _sendWithRetry will then trigger reconnect for
      // each; with the H3 fix it must coalesce into a single Worker.spawn.
      await initialWorker.send<bool>(
        '__inject_fail_next_n',
        const {'count': 5},
      );

      final futures = List.generate(5, (_) => pool.echo());
      final results = await Future.wait(futures);
      // All 5 echoes must have succeeded after the retry.
      expect(results, everyElement(equals(true)));

      // The worker list still has exactly 1 worker, and it is NOT the
      // original one (the reconnect replaced it). H3 without the fix
      // would have left the slot pointing at a worker that some callers
      // never observed, and leaked N-1 isolates.
      final liveWorkers = poolWorkers(pool);
      expect(liveWorkers.length, 1);
      expect(
        identical(liveWorkers.single, initialWorker),
        isFalse,
        reason: 'Reconnect should have replaced the failing worker',
      );
      // The original worker is fully closed.
      expect(initialWorker.isDead, isTrue);
    });
  });

  group('M2 — streamFile distinguishes EOF from mid-stream shrink', () {
    test('throws Smb2Exception(io) when readHandle returns 0 mid-stream',
        () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      final worker = poolWorkers(pool).single;
      final path = bootstrapCache.testFile;

      // Park the injection on the worker so the SECOND `readHandle` of
      // the stream (the one for the second chunk) returns an empty
      // buffer. The first read (offset=0) succeeds normally, advancing
      // `offset` past 0; then the zero-byte reply triggers the M2 guard.
      // The stream picks workers via _nextWorker round-robin; with a
      // single-worker pool there's no ambiguity about which worker
      // services the next read.
      const chunkSize = 64 * 1024;
      final fileSize = await pool.fileSize(path);
      expect(
        fileSize,
        greaterThan(2 * chunkSize),
        reason: 'Bootstrap seed must be large enough for two chunks',
      );

      // First chunk: real read. After it lands, install the injection
      // before we pull the second chunk.
      final iterator =
          StreamIterator(pool.streamFile(path, chunkSize: chunkSize));
      try {
        expect(await iterator.moveNext(), isTrue);
        expect(iterator.current.length, equals(chunkSize));

        await worker.send<bool>('__inject_readhandle_zero_next', const {});

        await expectLater(
          iterator.moveNext(),
          throwsA(
            isA<Smb2Exception>().having(
              (e) => e.type,
              'type',
              Smb2ErrorType.io,
            ),
          ),
        );
      } finally {
        await iterator.cancel();
      }
    });
  });

  group('M4 — closeHandle wins races against auto-reopen', () {
    test('closeHandle during a failing readFromHandle aborts the reopen',
        () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      final worker = poolWorkers(pool).single;
      final path = bootstrapCache.testFile;

      final handle = await pool.openFile(path);

      // Park a connection-error injection on the worker so the next
      // readFromHandle triggers the auto-reopen retry path.
      await worker.send<bool>(
        '__inject_fail_next_n',
        const {'count': 1},
      );

      // Fire a read; it will receive the injected error and enter the
      // `_reopenHandle` flow inside the pool. The microtask below flips
      // `closed = true` before _reopenHandle finishes its
      // worker-respawn dance — both `_throwIfClosed` observation points
      // (entry and after-reconnect) catch it. With the M4 fix the
      // reopen surfaces a connection-typed exception; without it, the
      // reopen would have completed and silently reattached a new
      // server-side handle that nothing owns.
      final readFuture = pool.readFromHandle(handle, length: 256);

      // Microtask runs after this synchronous block but BEFORE any
      // long-running awaits inside `_reopenHandle` settle, so we beat
      // the worker respawn deterministically. Manually flipping
      // `closed` bypasses `closeHandle`'s race with the in-flight retry
      // — exactly the order we want to exercise here.
      scheduleMicrotask(() {
        handle.closed = true;
      });

      await expectLater(
        readFuture,
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.type,
            'type',
            Smb2ErrorType.connection,
          ),
        ),
      );
    });
  });

  group('H2 — worker death does not hang pending sends', () {
    test('killForTest unblocks an in-flight hung send', () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      final worker = poolWorkers(pool).single;

      // Park the next normal command in the worker so it never replies.
      await worker.send<bool>('__inject_hang', const {});

      // Fire an echo that the worker will swallow. Without H2 fix this
      // Future would hang forever; with the fix, killing the isolate
      // completes it with a connection-typed exception.
      final pending = pool.echo();

      // Give the worker a moment to receive + swallow the echo.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      worker.killForTest();

      // The pool may attempt one reconnect+retry; either it succeeds
      // (and the echo returns), or it fails with another connection
      // error. The H2 fix is about NOT hanging — so all we assert is
      // that the Future settles within a generous window.
      final settled = await pending
          .then<Object?>((_) => 'ok')
          .catchError((e) => e as Object)
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => 'HUNG',
          );
      expect(
        settled,
        isNot(equals('HUNG')),
        reason: 'Pending send hung past the H2 timeout window',
      );
    });

    test('killForTest unblocks parallel in-flight sends', () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      final worker = poolWorkers(pool).single;

      // Hang only the first command; the others would normally succeed
      // — but we kill the worker before any of them complete, so we're
      // checking that every parked Completer gets the error.
      await worker.send<bool>('__inject_hang', const {});

      // Fire 5 echoes; the first hangs in the worker, the others queue
      // up behind it on the cmdPort listener.
      final futures = List.generate(5, (_) => pool.echo());

      await Future<void>.delayed(const Duration(milliseconds: 50));
      worker.killForTest();

      // None should hang. We collect them all and verify they settled.
      final outcomes = await Future.wait(
        futures.map(
          (f) => f
              .then<Object?>((_) => 'ok')
              .catchError((e) => e as Object)
              .timeout(
                const Duration(seconds: 3),
                onTimeout: () => 'HUNG',
              ),
        ),
      );
      for (final o in outcomes) {
        expect(o, isNot(equals('HUNG')));
      }
    });
  });

  // Auto-reconnect: inject a single connection error, then assert that each
  // retry-wrapped public operation transparently reconnects the worker and
  // succeeds. This exercises the happy-path recovery branches in
  // _sendWithRetry / _sendWriteWithRetry / openFile / openFileWrite and the
  // handle reopen paths (_reopenHandle / _reopenWriteHandle +
  // refreshFinalizer) that the H3/M4 tests above only touch on their failure
  // edges.
  group('auto-reconnect recovery for retry-wrapped operations', () {
    final seed = bootstrapCache.testFile;
    final data = Uint8List.fromList(const [1, 2, 3, 4, 5, 6]);

    Future<void> failNext(Smb2Pool pool) => poolWorkers(pool).single.send<bool>(
          '__inject_fail_next_n',
          const {'count': 1},
        );

    test('stat recovers via _sendWithRetry', () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      await failNext(pool);
      final info = await pool.stat(seed);
      expect(info.size, greaterThan(0));
    });

    test('listDirectory recovers via _sendWithRetry', () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      await failNext(pool);
      expect(await pool.listDirectory(''), isNotEmpty);
    });

    test('writeFile recovers via _sendWriteWithRetry', () async {
      final pool = await connect();
      const path = 'reconnect_writefile.bin';
      addTearDown(() async {
        try {
          await pool.deleteFile(path);
        } catch (_) {}
        await pool.disconnect();
      });
      await failNext(pool);
      await pool.writeFile(path, data);
      expect(await pool.readFile(path), orderedEquals(data));
    });

    test('openFile recovers on its retry path', () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      await failNext(pool);
      final handle = await pool.openFile(seed);
      addTearDown(() => pool.closeHandle(handle));
      final bytes = await pool.readFromHandle(handle, length: 128);
      expect(bytes.length, 128);
    });

    test('readFromHandle recovers by reopening the handle', () async {
      final pool = await connect();
      addTearDown(pool.disconnect);
      final handle = await pool.openFile(seed); // open first, THEN inject
      addTearDown(() => pool.closeHandle(handle));
      await failNext(pool);
      final bytes = await pool.readFromHandle(handle, length: 256);
      expect(bytes.length, 256);
    });

    test('openFileWrite + writeToHandle recover by reopening', () async {
      final pool = await connect();
      const path = 'reconnect_writehandle.bin';
      addTearDown(() async {
        try {
          await pool.deleteFile(path);
        } catch (_) {}
        await pool.disconnect();
      });
      final handle = await pool.openFileWrite(path); // open first
      await failNext(pool);
      await pool.writeToHandle(handle, data); // reopens + retries
      await pool.closeHandle(handle);
      expect(await pool.readFile(path), orderedEquals(data));
    });

    test('fsyncHandle recovers by reopening the handle', () async {
      final pool = await connect();
      const path = 'reconnect_fsync.bin';
      addTearDown(() async {
        try {
          await pool.deleteFile(path);
        } catch (_) {}
        await pool.disconnect();
      });
      final handle = await pool.openFileWrite(path);
      await pool.writeToHandle(handle, data);
      await failNext(pool);
      await pool.fsyncHandle(handle); // must reopen + retry without throwing
      await pool.closeHandle(handle);
    });

    test('ftruncateHandle recovers by reopening the handle', () async {
      final pool = await connect();
      const path = 'reconnect_ftruncate.bin';
      addTearDown(() async {
        try {
          await pool.deleteFile(path);
        } catch (_) {}
        await pool.disconnect();
      });
      final handle = await pool.openFileWrite(path);
      await pool.writeToHandle(handle, data);
      await failNext(pool);
      await pool.ftruncateHandle(handle, 3); // reopen + retry
      await pool.closeHandle(handle);
      expect(await pool.fileSize(path), 3);
    });

    test('setFileTimes recovers via _sendWithRetry', () async {
      final pool = await connect();
      const path = 'reconnect_utimes.bin';
      addTearDown(() async {
        try {
          await pool.deleteFile(path);
        } catch (_) {}
        await pool.disconnect();
      });
      await pool.writeFile(path, data);
      final target = DateTime.utc(2016, 8, 9, 10, 11, 12);
      await failNext(pool);
      await pool.setFileTimes(path, modified: target);
      final info = await pool.stat(path);
      expect(info.modified, target);
    });
  });
}
