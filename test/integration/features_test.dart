// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The 0.3.0 API against Samba: rename with overwrite, links, change
// notification, the tree helpers, copies, upload progress and AES-GCM.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

import '_fixture.dart';

Uint8List pattern(int length, [int seed = 0]) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + seed + (i >> 16)) & 0xff;
  }
  return out;
}

Matcher throwsType(Smb2ErrorType type) =>
    throwsA(isA<Smb2Exception>().having((e) => e.type, 'type', type));

/// The next events of [events] until [done] holds for what arrived.
Future<List<Smb2ChangeEvent>> collect(
  StreamIterator<Smb2ChangeEvent> events,
  bool Function(List<Smb2ChangeEvent> got) done,
) async {
  final got = <Smb2ChangeEvent>[];
  while (!done(got)) {
    if (!await events.moveNext().timeout(const Duration(seconds: 15))) break;
    got.add(events.current);
  }
  return got;
}

void main() {
  final scratch = Scratch('features');
  late Smb2Client client;
  late Smb2Pool pool;
  late Directory local;

  setUpAll(() async {
    scratch.create();
    client = connectClient();
    pool = await connectPool(workers: 3);
    local = await Directory.systemTemp.createTemp('dart_smb2_features');
  });
  tearDownAll(() async {
    client.disconnect();
    await pool.disconnect();
    await local.delete(recursive: true);
    scratch.delete();
  });

  group('rename with overwrite', () {
    test('the client replaces an existing file only when asked', () {
      final a = scratch.path('rn_a'), b = scratch.path('rn_b');
      client
        ..writeFile(a, pattern(10))
        ..writeFile(b, pattern(20));
      expect(
        () => client.rename(a, b),
        throwsType(Smb2ErrorType.alreadyExists),
      );
      client.rename(a, b, overwrite: true);
      expect(client.exists(a), isFalse);
      expect(client.readFile(b), pattern(10));
    });

    test('the pool replaces an existing file only when asked', () async {
      final a = scratch.path('prn_a'), b = scratch.path('prn_b');
      await pool.writeFile(a, pattern(5));
      await pool.writeFile(b, pattern(7));
      await expectLater(
        pool.rename(a, b),
        throwsType(Smb2ErrorType.alreadyExists),
      );
      await pool.rename(a, b, overwrite: true);
      expect(await pool.readFile(b), pattern(5));
    });

    test('a directory is never replaced', () async {
      final f = scratch.path('rn_file'), d = scratch.path('rn_dir');
      await pool.writeFile(f, pattern(3));
      await pool.mkdir(d);
      await expectLater(
        pool.rename(f, d, overwrite: true),
        throwsA(isA<Smb2Exception>()),
      );
      expect((await pool.stat(d)).isDirectory, isTrue);
    });

    test('overwrite to a free name is a plain rename', () async {
      final a = scratch.path('rn_free_a'), b = scratch.path('rn_free_b');
      await pool.writeFile(a, pattern(4));
      await pool.rename(a, b, overwrite: true);
      expect(await pool.readFile(b), pattern(4));
    });
  });

  group('links', () {
    test('a hard link shares the data', () async {
      final f = scratch.path('hl_src'), l = scratch.path('hl_link');
      await pool.writeFile(f, pattern(100));
      await pool.link(f, l);
      await pool.writeFileRange(f, Uint8List.fromList([9, 9]));
      expect((await pool.readFile(l)).sublist(0, 2), [9, 9]);
      await expectLater(
        pool.link(f, l),
        throwsType(Smb2ErrorType.alreadyExists),
      );
    });

    test('a symbolic link reads back its target', () async {
      final l = scratch.path('sl_link');
      await pool.writeFile(scratch.path('sl_target'), pattern(8));
      await pool.symlink('sl_target', l);
      expect(await pool.readlink(l), 'sl_target');
      final entry = (await pool.listDirectory(
        scratch.dir,
      )).firstWhere((e) => e.name == 'sl_link');
      expect(entry.stat.type, Smb2FileType.link);
      client.symlink('sl_target', scratch.path('sl_client'));
      expect(client.readlink(scratch.path('sl_client')), 'sl_target');
    });

    test('a symbolic link over an existing name fails', () async {
      final l = scratch.path('sl_taken');
      await pool.writeFile(l, pattern(1));
      await expectLater(
        pool.symlink('anything', l),
        throwsType(Smb2ErrorType.alreadyExists),
      );
    });
  });

  group('Smb2Client.watch', () {
    test('reports creates, renames and deletes in order', () {
      final dir = scratch.path('cw');
      client.mkdir(dir);
      final w = client.watch(dir);
      try {
        expect(w.next(timeout: const Duration(milliseconds: 200)), isEmpty);
        final other = connectClient();
        try {
          other
            ..writeFile('$dir/a', pattern(3))
            ..rename('$dir/a', '$dir/b')
            ..deleteFile('$dir/b');
        } finally {
          other.disconnect();
        }
        final got = <Smb2ChangeEvent>[];
        final clock = Stopwatch()..start();
        while (!got.any((e) => e.action == Smb2ChangeAction.removed) &&
            clock.elapsed < const Duration(seconds: 10)) {
          got.addAll(w.next(timeout: const Duration(seconds: 1)));
        }
        expect(
          got,
          containsAllInOrder([
            Smb2ChangeEvent(Smb2ChangeAction.added, '$dir/a'),
            Smb2ChangeEvent(Smb2ChangeAction.renamedFrom, '$dir/a'),
            Smb2ChangeEvent(Smb2ChangeAction.renamedTo, '$dir/b'),
            Smb2ChangeEvent(Smb2ChangeAction.removed, '$dir/b'),
          ]),
        );
      } finally {
        w.close();
      }
      expect(w.isClosed, isTrue);
      expect(w.next, throwsType(Smb2ErrorType.state));
      // The directory is free again.
      client.rmdir(dir);
    });

    test('keeps changes made while other calls run', () {
      final dir = scratch.path('cw_busy');
      client.mkdir(dir);
      final w = client.watch(dir);
      try {
        client.writeFile('$dir/x', pattern(1));
        // The reply may arrive during these calls; it is kept.
        client
          ..stat('$dir/x')
          ..listDirectory(dir);
        final got = <Smb2ChangeEvent>[];
        final clock = Stopwatch()..start();
        while (got.isEmpty && clock.elapsed < const Duration(seconds: 10)) {
          got.addAll(w.next(timeout: const Duration(seconds: 1)));
        }
        expect(got.first, Smb2ChangeEvent(Smb2ChangeAction.added, '$dir/x'));
      } finally {
        w.close();
      }
    });

    test('recursive watches report paths below the directory', () {
      final dir = scratch.path('cw_tree');
      client
        ..mkdir(dir)
        ..mkdir('$dir/sub');
      final w = client.watch(dir, recursive: true);
      try {
        client.writeFile('$dir/sub/deep', pattern(1));
        final got = <Smb2ChangeEvent>[];
        final clock = Stopwatch()..start();
        while (!got.any((e) => e.path == '$dir/sub/deep') &&
            clock.elapsed < const Duration(seconds: 10)) {
          got.addAll(w.next(timeout: const Duration(seconds: 1)));
        }
        expect(got.map((e) => e.path), contains('$dir/sub/deep'));
      } finally {
        w.close();
      }
    });

    test('a file or a missing path cannot be watched', () {
      client.writeFile(scratch.path('cw_file'), pattern(1));
      expect(
        () => client.watch(scratch.path('cw_file')),
        throwsType(Smb2ErrorType.notADirectory),
      );
      expect(
        () => client.watch(scratch.path('cw_missing')),
        throwsType(Smb2ErrorType.notFound),
      );
      expect(
        () => client.watch(scratch.dir, filter: 0),
        throwsType(Smb2ErrorType.invalidParam),
      );
    });

    test('disconnect closes the watchers', () {
      final c = connectClient();
      final w = c.watch(scratch.dir);
      c.disconnect();
      expect(w.isClosed, isTrue);
    });
  });

  group('Smb2Pool.watch', () {
    test('streams the pool\'s own changes', () async {
      final dir = scratch.path('pw');
      await pool.mkdir(dir);
      final events = StreamIterator(pool.watch(dir));
      // The first event proves the watch is up; keep writing until then.
      final writer = Timer.periodic(
        const Duration(milliseconds: 300),
        (_) => pool.writeFile('$dir/ping', pattern(1)).ignore(),
      );
      try {
        await collect(events, (got) => got.isNotEmpty);
      } finally {
        writer.cancel();
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await pool.writeFile('$dir/file', pattern(2));
      await pool.deleteFile('$dir/file');
      final got = await collect(
        events,
        (got) => got.contains(
          Smb2ChangeEvent(Smb2ChangeAction.removed, '$dir/file'),
        ),
      );
      expect(
        got,
        containsAllInOrder([
          Smb2ChangeEvent(Smb2ChangeAction.added, '$dir/file'),
          Smb2ChangeEvent(Smb2ChangeAction.removed, '$dir/file'),
        ]),
      );
      await events.cancel();
      // The watch's handle is closed: the directory can go.
      await pool.rmdir(dir, recursive: true);
    });

    test('a missing directory ends the stream with notFound', () async {
      await expectLater(
        pool.watch(scratch.path('pw_missing')).toList(),
        throwsType(Smb2ErrorType.notFound),
      );
    });

    test('the token ends the stream with cancelled', () async {
      final token = Smb2CancelToken();
      final done = pool.watch(scratch.dir, cancelToken: token).toList();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      token.cancel();
      await expectLater(done, throwsType(Smb2ErrorType.cancelled));
    });

    test('disconnect ends the stream', () async {
      final p = await connectPool(workers: 1);
      final done = p.watch(scratch.dir).toList();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await p.disconnect();
      expect(await done, isEmpty);
    });

    test('cancelling at once leaves no session behind', () async {
      // Its own user, so the sessions of the other tests do not count.
      final p = await Smb2Pool.connect(
        host: server.host,
        share: server.share,
        user: emptyPasswordUser,
        password: '',
        workers: 1,
      );
      final sub = p.watch(scratch.dir).listen((_) {});
      await sub.cancel();
      await p.disconnect();
      expect(await sessionsOf(emptyPasswordUser), 0);
      // Still none once a leaked isolate would have connected.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(await sessionsOf(emptyPasswordUser), 0);
    });

    test('cancelling while the server hangs stops the watch', () async {
      final proxy = await TcpProxy.start();
      final p = await connectPool(workers: 1, host: proxy.host);
      try {
        final events = StreamIterator(p.watch(scratch.dir));
        final writer = Timer.periodic(
          const Duration(milliseconds: 300),
          (_) => pool.writeFile(scratch.path('hang'), pattern(1)).ignore(),
        );
        try {
          await collect(events, (got) => got.isNotEmpty);
        } finally {
          writer.cancel();
        }
        proxy.freeze();
        final clock = Stopwatch()..start();
        await events.cancel();
        // The requests in flight time out, the isolate is not killed.
        expect(clock.elapsed, lessThan(const Duration(seconds: 25)));
      } finally {
        proxy.thaw();
        await p.disconnect();
        await proxy.close();
      }
    });

    test('a dropped connection reconnects and reports an overflow', () async {
      final proxy = await TcpProxy.start();
      final p = await connectPool(workers: 1, host: proxy.host);
      final dir = scratch.path('pw_drop');
      await pool.mkdir(dir);
      final events = StreamIterator(p.watch(dir));
      try {
        final writer = Timer.periodic(
          const Duration(milliseconds: 300),
          (_) => pool.writeFile('$dir/ping', pattern(1)).ignore(),
        );
        try {
          await collect(events, (got) => got.isNotEmpty);
        } finally {
          writer.cancel();
        }
        proxy.drop();
        final got = await collect(
          events,
          (got) => got.any((e) => e.action == Smb2ChangeAction.overflow),
        );
        expect(got.last, Smb2ChangeEvent(Smb2ChangeAction.overflow, dir));
        // And it watches again.
        await pool.writeFile('$dir/after', pattern(1));
        final later = await collect(
          events,
          (got) => got.any((e) => e.path == '$dir/after'),
        );
        expect(later.map((e) => e.path), contains('$dir/after'));
      } finally {
        await events.cancel();
        await p.disconnect();
        await proxy.close();
      }
    });
  });

  group('tree helpers', () {
    test(
      'mkdir -p creates the missing levels and accepts existing ones',
      () async {
        final deep = scratch.path('mk/a/b/c');
        await pool.mkdir(deep, recursive: true);
        expect((await pool.stat(deep)).isDirectory, isTrue);
        await pool.mkdir(deep, recursive: true);
        await pool.mkdir(scratch.path('mk/a'), recursive: true);
        await pool.writeFile(scratch.path('mk/file'), pattern(1));
        await expectLater(
          pool.mkdir(scratch.path('mk/file/below'), recursive: true),
          throwsType(Smb2ErrorType.notADirectory),
        );
      },
    );

    test('rmdir -r removes a tree with files, links and directories', () async {
      final root = scratch.path('rm');
      await pool.mkdir('$root/x/y', recursive: true);
      for (var i = 0; i < 7; i++) {
        await pool.writeFile('$root/x/f$i', pattern(i + 1));
      }
      await pool.writeFile('$root/x/y/z', pattern(3));
      await pool.symlink('f0', '$root/x/link');
      await pool.rmdir(root, recursive: true);
      expect(await pool.exists(root), isFalse);
      await expectLater(
        pool.rmdir(scratch.path('rm_missing'), recursive: true),
        throwsType(Smb2ErrorType.notFound),
      );
    });

    test('streamDirectory lists a tree depth first, relative names', () async {
      final root = scratch.path('ls');
      await pool.mkdir('$root/a/b', recursive: true);
      await pool.writeFile('$root/a/b/f', pattern(1));
      await pool.writeFile('$root/a/g', pattern(1));
      await pool.writeFile('$root/top', pattern(1));
      final flat = await pool.streamDirectory(root).map((e) => e.name).toList();
      expect(flat, unorderedEquals(['a', 'top']));
      final tree = await pool
          .streamDirectory(root, recursive: true)
          .map((e) => e.name)
          .toList();
      expect(tree, unorderedEquals(['a', 'a/b', 'a/b/f', 'a/g', 'top']));
      expect(tree.indexOf('a'), lessThan(tree.indexOf('a/b')));
      expect(tree.indexOf('a/b'), lessThan(tree.indexOf('a/b/f')));
      final first = await pool.streamDirectory(root, recursive: true).first;
      expect(first.name, isNotEmpty);
    });
  });

  group('copies', () {
    test('copy streams a file and reports its progress', () async {
      final src = scratch.path('cp_src'), dst = scratch.path('cp_dst');
      final data = pattern(3 * 1024 * 1024 + 17, 5);
      await pool.writeFile(src, data);
      final progress = <(int, int)>[];
      final n = await pool.copy(
        src,
        dst,
        chunkSize: 1024 * 1024,
        onProgress: (c, t) => progress.add((c, t)),
      );
      expect(n, data.length);
      expect(await pool.readFile(dst), data);
      expect(progress.length, 4);
      expect(progress.last, (data.length, data.length));
      await expectLater(
        pool.copy(src, dst),
        throwsType(Smb2ErrorType.alreadyExists),
      );
      await pool.writeFile(src, pattern(10, 9));
      await pool.copy(src, dst, overwrite: true);
      expect(await pool.readFile(dst), pattern(10, 9));
      final names = await pool.streamDirectory(scratch.dir).toList();
      expect(names.where((e) => e.name.contains('.part-')), isEmpty);
    });

    test('a cancelled copy leaves no temporary file', () async {
      final src = scratch.path('cpc_src'), dst = scratch.path('cpc_dst');
      await pool.writeFile(src, pattern(2 * 1024 * 1024));
      final token = Smb2CancelToken();
      await expectLater(
        pool.copy(
          src,
          dst,
          chunkSize: 256 * 1024,
          cancelToken: token,
          onProgress: (c, _) => token.cancel(),
        ),
        throwsType(Smb2ErrorType.cancelled),
      );
      expect(await pool.exists(dst), isFalse);
      final names = await pool.streamDirectory(scratch.dir).toList();
      expect(names.where((e) => e.name.startsWith('cpc_dst.part-')), isEmpty);
    });

    test('copyTree copies a tree with total progress', () async {
      final src = scratch.path('ct_src'), dst = scratch.path('ct_dst');
      await pool.mkdir('$src/d/e', recursive: true);
      await pool.writeFile('$src/a', pattern(1000));
      await pool.writeFile('$src/d/b', pattern(2000, 1));
      await pool.writeFile('$src/d/e/c', pattern(3000, 2));
      await pool.mkdir('$src/empty');
      var last = (0, 0);
      final n = await pool.copyTree(
        src,
        dst,
        onProgress: (c, t) => last = (c, t),
      );
      expect(n, 6000);
      expect(last, (6000, 6000));
      expect(await pool.readFile('$dst/d/e/c'), pattern(3000, 2));
      expect((await pool.stat('$dst/empty')).isDirectory, isTrue);
      await expectLater(
        pool.copyTree(src, dst),
        throwsType(Smb2ErrorType.alreadyExists),
      );
      expect(await pool.copyTree(src, dst, overwrite: true), 6000);
    });
  });

  group('upload progress', () {
    test('streamWrite reports the bytes the server took', () async {
      final progress = <(int, int)>[];
      final chunks = [pattern(1000), pattern(500), pattern(250)];
      final n = await pool.streamWrite(
        scratch.path('sw'),
        Stream.fromIterable(chunks),
        length: 1750,
        onProgress: (s, t) => progress.add((s, t)),
      );
      expect(n, 1750);
      expect(progress, [(1000, 1750), (1500, 1750), (1750, 1750)]);
      final unknown = <int>[];
      await pool.streamWrite(
        scratch.path('sw2'),
        Stream.fromIterable(chunks),
        onProgress: (_, t) => unknown.add(t),
      );
      expect(unknown, everyElement(-1));
    });

    test('uploadFile writes atomically with progress', () async {
      final file = File('${local.path}/up.bin');
      final data = pattern(5 * 1024 * 1024 + 3, 7);
      await file.writeAsBytes(data);
      final dst = scratch.path('up');
      await pool.writeFile(dst, pattern(4));
      final progress = <(int, int)>[];
      final n = await pool.uploadFile(
        file.path,
        dst,
        chunkSize: 2 * 1024 * 1024,
        onProgress: (s, t) => progress.add((s, t)),
      );
      expect(n, data.length);
      expect(progress.map((p) => p.$1), [
        2 * 1024 * 1024,
        4 * 1024 * 1024,
        data.length,
      ]);
      expect(progress.every((p) => p.$2 == data.length), isTrue);
      expect(await pool.readFile(dst), data);
      await expectLater(
        pool.uploadFile('${local.path}/missing', dst),
        throwsType(Smb2ErrorType.notFound),
      );
    });
  });

  group('encryption', () {
    test('a sealed session negotiates AES-GCM on SMB 3.1.1', () async {
      final p = await Smb2Pool.connect(
        host: server.host,
        share: server.share,
        user: server.user,
        password: server.password,
        workers: 1,
        seal: true,
      );
      try {
        await p.writeFile(scratch.path('sealed'), pattern(4096));
        expect(await p.readFile(scratch.path('sealed')), pattern(4096));
        final status = await Process.run('docker', [
          'exec',
          'dart-smb2-test',
          'smbstatus',
          '-b',
        ]);
        expect(
          status.stdout as String,
          matches(RegExp(r'SMB3_11\s+\S*\(AES-(128|256)-GCM\)')),
        );
      } finally {
        await p.disconnect();
      }
    });
  });
}
