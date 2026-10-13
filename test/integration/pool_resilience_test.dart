// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Reconnects, repeats and worker deaths, driven by the workers' test-only
/// fault injection (lib/src/pool/test_hooks.dart).
@Tags(['integration'])
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
// ignore: implementation_imports, the fault injection is package-internal
import 'package:dart_smb2/src/pool/test_hooks.dart';
import 'package:test/test.dart';

import '_fixture.dart';

Matcher throwsType(Smb2ErrorType type) =>
    throwsA(isA<Smb2Exception>().having((e) => e.type, 'type', type));

void main() {
  final scratch = Scratch('resilience');
  late Smb2Pool pool;

  setUpAll(scratch.create);
  tearDownAll(scratch.delete);
  setUp(() async => pool = await connectPool(workers: 1));
  tearDown(() => pool.disconnect());

  group('repeat after reconnect', () {
    final cases = <String, Future<Object?> Function(Smb2Pool)>{
      'stat': (p) => p.stat(seedFile),
      'listDirectory': (p) => p.listDirectory(''),
      'readFile': (p) => p.readFile(seedFile),
      'readFileRange': (p) => p.readFileRange(seedFile, length: 10),
      'writeFile': (p) => p.writeFile(scratch.path('r.bin'), Uint8List(4)),
      'setFileTimes': (p) =>
          p.setFileTimes(seedFile, accessed: DateTime.utc(2022)),
      'openFile': (p) => p.openFile(seedFile).then(p.closeHandle),
    };
    for (final MapEntry(key: name, value: call) in cases.entries) {
      test('$name reconnects the worker and succeeds', () async {
        final before = poolWorkers(pool).single;
        await before.failNext(1);
        await call(pool);
        expect(identical(poolWorkers(pool).single, before), isFalse);
        expect(before.isDead, isTrue);
      });
    }

    test(
      'mkdir is not repeated: it fails and the worker is replaced',
      () async {
        final before = poolWorkers(pool).single;
        await before.failNext(1);
        final dir = scratch.path('not_repeated');
        await expectLater(
          pool.mkdir(dir),
          throwsType(Smb2ErrorType.connection),
        );
        expect(identical(poolWorkers(pool).single, before), isFalse);
        expect(await pool.exists(dir), isFalse);
      },
    );

    test('parallel failures on one worker reconnect it once', () async {
      final alive = Worker.debugAlive;
      final before = poolWorkers(pool).single;
      await before.failNext(5);
      await Future.wait([for (var i = 0; i < 5; i++) pool.stat(seedFile)]);
      final after = poolWorkers(pool).single;
      expect(identical(after, before), isFalse);
      await pool.stat(seedFile);
      expect(identical(poolWorkers(pool).single, after), isTrue);
      // One replacement, no orphan workers.
      expect(Worker.debugAlive, alive);
    });
  });

  group('handles across reconnects', () {
    test('a read handle survives a reconnect another call caused', () async {
      // Two handles, so the reopened one gets an id other than its old one.
      final other = await pool.openFile(seedFile);
      final h = await pool.openFile(seedFile);
      await poolWorkers(pool).single.failNext(1);
      await pool.stat(seedFile); // reconnects the only worker
      expect((await pool.readFromHandle(h, length: 16)).length, 16);
      expect((await pool.readFromHandle(h, offset: 8, length: 8)).length, 8);
      await pool.closeHandle(h);
      await pool.closeHandle(other);
    });

    test('a failing handle read reopens and repeats', () async {
      final h = await pool.openFile(seedFile);
      await poolWorkers(pool).single.failNext(1);
      expect((await pool.readFromHandle(h, length: 4)).length, 4);
      await pool.closeHandle(h);
    });

    test(
      'a write handle reopens without truncating what was written',
      () async {
        final path = scratch.path('reopen.bin');
        final h = await pool.openFileWrite(path, truncate: true);
        await pool.writeToHandle(h, Uint8List.fromList([1, 2, 3]));
        await poolWorkers(pool).single.failNext(1);
        await pool.writeToHandle(h, Uint8List.fromList([4]), offset: 3);
        await pool.fsyncHandle(h);
        await pool.closeHandle(h);
        expect(await pool.readFile(path), [1, 2, 3, 4]);
      },
    );

    test('closeHandle during a failing read stops the reopen', () async {
      final h = await pool.openFile(seedFile);
      await poolWorkers(pool).single.failNext(1);
      final read = expectLater(
        pool.readFromHandle(h, length: 4),
        throwsA(isA<Smb2Exception>()),
      );
      await pool.closeHandle(h);
      await read;
      expect(h.isClosed, isTrue);
      await pool.stat(seedFile);
    });

    test(
      'a read of no bytes before the end fails the stream with io',
      () async {
        final stream = pool.streamFile(seedFile, chunkSize: 64 * 1024);
        await poolWorkers(pool).single.emptyReadNext();
        await expectLater(stream.drain<void>(), throwsType(Smb2ErrorType.io));
      },
    );
  });

  group('worker death', () {
    test(
      'a killed worker fails its pending calls instead of hanging',
      () async {
        final worker = poolWorkers(pool).single;
        await worker.hangNext();
        final pending = worker.call<Object?>(Op.echo, const []);
        final parallel = [
          for (var i = 0; i < 3; i++) worker.call<Object?>(Op.echo, const []),
        ];
        worker.killForTest();
        await expectLater(pending, throwsType(Smb2ErrorType.connection));
        for (final p in parallel) {
          await expectLater(p, throwsType(Smb2ErrorType.connection));
        }
        // The next pool call replaces the dead worker.
        expect((await pool.stat(seedFile)).size, seedSize);
      },
    );

    test('disconnect while a reconnect runs leaves no worker alive', () async {
      final alive = Worker.debugAlive;
      for (final delay in [0, 1, 20, 60]) {
        final p = await connectPool();
        final first = poolWorkers(p).first;
        await first.failNext(10);
        final op = p
            .stat(seedFile)
            .then<Object?>((v) => v, onError: (Object e) => e);
        await Future<void>.delayed(Duration(milliseconds: delay));
        await p.disconnect();
        // Nothing still spawning or alive once disconnect returns.
        expect(Worker.debugAlive, alive, reason: 'delay $delay');
        final outcome = await op;
        expect(
          outcome,
          anyOf(isA<Smb2Stat>(), isA<Smb2Exception>()),
          reason: 'delay $delay',
        );
        expect(
          poolWorkers(p).every((w) => w.isDead),
          isTrue,
          reason: 'delay $delay',
        );
        expect(Worker.debugAlive, alive, reason: 'delay $delay');
      }
    });

    test('a host that never answers times out instead of hanging', () async {
      // TEST-NET-1 (RFC 5737): routed nowhere.
      await expectLater(
        Smb2Pool.connect(
          host: '192.0.2.1',
          share: 'x',
          workers: 1,
          timeout: const Duration(seconds: 2),
        ).timeout(const Duration(seconds: 30)),
        throwsA(
          isA<Smb2Exception>().having(
            (e) => e.isNetworkFailure,
            'isNetworkFailure',
            isTrue,
          ),
        ),
      );
    });
  });
}
