// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

import '_fixture.dart';

void main() {
  final scratch = Scratch('pool');
  late Smb2Pool pool;
  late Directory local;

  setUpAll(() async {
    scratch.create();
    pool = await connectPool(workers: 3);
    local = await Directory.systemTemp.createTemp('dart_smb2_test');
  });
  tearDownAll(() async {
    await pool.disconnect();
    await local.delete(recursive: true);
    scratch.delete();
  });

  group('connect', () {
    test('connects the requested workers', () {
      expect(pool.workerCount, 3);
      expect(pool.isClosed, isFalse);
    });

    test('a wrong password fails with auth through the pool', () async {
      await expectLater(
        Smb2Pool.connect(
          host: server.host,
          share: server.share,
          user: server.user,
          password: 'wrong',
          workers: 2,
        ),
        throwsA(
          isA<Smb2Exception>()
              .having((e) => e.isAuthError, 'isAuthError', isTrue)
              .having((e) => e.ntStatus, 'ntStatus', 0xC000006D),
        ),
      );
    });

    test('a share that does not exist fails with notFound', () async {
      await expectLater(
        Smb2Pool.connect(
          host: server.host,
          share: 'no_such_share',
          user: server.user,
          password: server.password,
          workers: 1,
        ),
        throwsType(Smb2ErrorType.notFound),
      );
    });

    test('a user with an empty password connects every worker', () async {
      final p = await Smb2Pool.connect(
        host: server.host,
        share: server.share,
        user: emptyPasswordUser,
        password: '',
        workers: 2,
      );
      try {
        expect(await p.exists(seedFile), isTrue);
      } finally {
        await p.disconnect();
      }
    });

    test('zero workers is an invalid argument', () async {
      await expectLater(
        Smb2Pool.connect(host: server.host, share: server.share, workers: 0),
        throwsType(Smb2ErrorType.invalidParam),
      );
    });

    test('listSharesOn lists the share', () async {
      final shares = await Smb2Pool.listSharesOn(
        host: server.host,
        user: server.user,
        password: server.password,
      );
      expect(shares.map((s) => s.name), contains(server.share));
    });

    test('a closed pool refuses calls with state', () async {
      final p = await connectPool(workers: 1);
      await p.disconnect();
      await p.disconnect();
      expect(p.isClosed, isTrue);
      await expectLater(p.stat(seedFile), throwsType(Smb2ErrorType.state));
    });

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

  group('reads and metadata', () {
    test('readFile, readFileRange, stat, fileSize and exists', () async {
      expect((await pool.readFile(seedFile)).length, seedSize);
      expect(
        (await pool.readFileRange(seedFile, offset: 10, length: 20)).length,
        20,
      );
      expect((await pool.stat(seedFile)).size, seedSize);
      expect(await pool.fileSize(seedFile), seedSize);
      expect(await pool.exists(seedFile), isTrue);
      expect(await pool.exists('no_such_file'), isFalse);
      await expectLater(
        pool.stat('no/such'),
        throwsType(Smb2ErrorType.notFound),
      );
    });

    test('listDirectory, statvfs, echo and readlink', () async {
      final root = await pool.listDirectory('');
      expect(root.map((e) => e.name), contains(seedFile));
      expect((await pool.statvfs('')).totalSize, greaterThan(0));
      await pool.echo();
      await expectLater(pool.readlink(seedFile), throwsA(isA<Smb2Exception>()));
    });

    test('200 parallel stats spread over the workers', () async {
      final stats = await Future.wait([
        for (var i = 0; i < 200; i++) pool.stat(seedFile),
      ]);
      expect(stats.every((s) => s.size == seedSize), isTrue);
    });

    test('a large file reads back whole through readFile', () async {
      final data = pattern(20 * 1024 * 1024 + 3);
      final path = scratch.path('large.bin');
      await pool.writeFile(path, data);
      expect(sameBytes(await pool.readFile(path), data), isTrue);
    });
  });

  group('handles', () {
    test('openFileWithSize, readFromHandle and closeHandle', () async {
      final (h, size) = await pool.openFileWithSize(seedFile);
      expect(size, seedSize);
      expect((await pool.readFromHandle(h, offset: 5, length: 10)).length, 10);
      await pool.closeHandle(h);
      await pool.closeHandle(h);
      expect(h.isClosed, isTrue);
      await expectLater(
        pool.readFromHandle(h, length: 1),
        throwsType(Smb2ErrorType.state),
      );
    });

    test('write handle: write, fsync, ftruncate', () async {
      final path = scratch.path('wh.bin');
      final h = await pool.openFileWrite(path, truncate: true);
      expect(h.writable, isTrue);
      await pool.writeToHandle(h, Uint8List.fromList([1, 2, 3, 4]));
      await pool.fsyncHandle(h);
      await pool.ftruncateHandle(h, 3);
      await pool.closeHandle(h);
      expect(await pool.readFile(path), [1, 2, 3]);
    });

    test('withFile closes on success and on error', () async {
      final size = await pool.withFile(seedFile, (f) async {
        expect((await f.read(length: 8)).length, 8);
        expect(f.path, seedFile);
        return f.size;
      });
      expect(size, seedSize);
      await expectLater(
        pool.withFile(seedFile, (_) => throw StateError('boom')),
        throwsStateError,
      );
      final known = await pool.withFile(seedFile, (f) => f.size, knownSize: 7);
      expect(known, 7);
    });
  });

  group('streaming', () {
    late Uint8List data;
    late String path;

    setUpAll(() async {
      data = pattern(9 * 1024 * 1024 + 17);
      path = scratch.path('stream.bin');
      await pool.writeFile(path, data);
    });

    for (final chunk in [64 * 1024, 1024 * 1024, 16 * 1024 * 1024]) {
      test(
        'streamFile with $chunk-byte chunks yields every byte in order',
        () async {
          final progress = <int>[];
          final chunks = await pool
              .streamFile(
                path,
                chunkSize: chunk,
                onProgress: (r, t) {
                  expect(t, data.length);
                  progress.add(r);
                },
              )
              .toList();
          expect(chunks.every((c) => c.length <= chunk), isTrue);
          expect(sameBytes([for (final c in chunks) ...c], data), isTrue);
          expect(progress.last, data.length);
        },
      );
    }

    test('streamFile of an empty file yields nothing', () async {
      final empty = scratch.path('empty.bin');
      await pool.writeFile(empty, Uint8List(0));
      expect(await pool.streamFile(empty).toList(), isEmpty);
    });

    test('cancelling the subscription closes the handle', () async {
      final first = await pool.streamFile(path, chunkSize: 1024 * 1024).first;
      expect(first.length, 1024 * 1024);
      // The read-ahead chunk is dropped; the pool stays usable.
      expect((await pool.stat(path)).size, data.length);
    });

    test('downloadToFile writes the file atomically', () async {
      final dest = '${local.path}/download.bin';
      var last = 0;
      final n = await pool.downloadToFile(
        path,
        dest,
        onProgress: (r, t) => last = r,
      );
      expect(n, data.length);
      expect(last, data.length);
      expect(sameBytes(await File(dest).readAsBytes(), data), isTrue);
      expect(
        local.listSync().map((e) => e.path).where((p) => p.contains('.part-')),
        isEmpty,
      );
    });

    test('a failed download leaves the destination as it was', () async {
      final dest = '${local.path}/kept.txt';
      await File(dest).writeAsString('old');
      await expectLater(
        pool.downloadToFile('no_such_file', dest),
        throwsType(Smb2ErrorType.notFound),
      );
      expect(await File(dest).readAsString(), 'old');
      expect(local.listSync().where((e) => e.path.contains('.part-')), isEmpty);
    });

    test(
      'a cancelled download throws cancelled and removes its part file',
      () async {
        final dest = '${local.path}/cancelled.bin';
        final token = Smb2CancelToken();
        final future = pool.downloadToFile(
          path,
          dest,
          chunkSize: 256 * 1024,
          cancelToken: token,
          onProgress: (r, _) {
            if (r >= 1024 * 1024) token.cancel('stop');
          },
        );
        await expectLater(
          future,
          throwsA(
            isA<Smb2Exception>().having(
              (e) => e.isCancelled,
              'isCancelled',
              isTrue,
            ),
          ),
        );
        expect(File(dest).existsSync(), isFalse);
        expect(
          local.listSync().where((e) => e.path.contains('.part-')),
          isEmpty,
        );
        expect(token.listenerCount, 0);
      },
    );

    test('streamWrite writes a stream through one handle', () async {
      final out = scratch.path('streamed.bin');
      await pool.streamWrite(
        out,
        Stream.fromIterable([
          for (var o = 0; o < data.length; o += 1024 * 1024)
            Uint8List.sublistView(
              data,
              o,
              o + 1024 * 1024 > data.length ? data.length : o + 1024 * 1024,
            ),
        ]),
      );
      expect(sameBytes(await pool.readFile(out), data), isTrue);
    });
  });

  group('cancellation', () {
    test('a cancelled token fails calls at once', () async {
      final token = Smb2CancelToken()..cancel();
      await expectLater(
        pool.listDirectory('', cancelToken: token),
        throwsType(Smb2ErrorType.cancelled),
      );
      await expectLater(
        pool.openFile(seedFile, cancelToken: token),
        throwsType(Smb2ErrorType.cancelled),
      );
    });

    test('cancelling an open in flight closes the file it opened', () async {
      final token = Smb2CancelToken();
      final future = pool.openFile(seedFile, cancelToken: token);
      token.cancel();
      await expectLater(future, throwsType(Smb2ErrorType.cancelled));
      // The worker's late reply is disposed of; the pool keeps working.
      await pool.echo();
      expect((await pool.stat(seedFile)).size, seedSize);
    });
  });

  group('writes and management', () {
    test('writeFile, writeFileRange, truncate, setFileTimes', () async {
      final path = scratch.path('w.bin');
      await pool.writeFile(path, Uint8List.fromList([1, 2, 3]));
      await pool.writeFileRange(path, Uint8List.fromList([9]), offset: 4);
      expect(await pool.readFile(path), [1, 2, 3, 0, 9]);
      await pool.truncate(path, 2);
      expect(await pool.fileSize(path), 2);
      final when = DateTime.utc(2021, 3, 4, 5, 6, 7);
      await pool.setFileTimes(path, modified: when);
      expect((await pool.stat(path)).modified, when);
    });

    test('mkdir, rename, deleteFile, rmdir with typed failures', () async {
      final dir = scratch.path('m');
      await pool.mkdir(dir);
      await expectLater(
        pool.mkdir(dir),
        throwsType(Smb2ErrorType.alreadyExists),
      );
      await pool.writeFile('$dir/a', Uint8List(1));
      await expectLater(pool.rmdir(dir), throwsType(Smb2ErrorType.notEmpty));
      await pool.rename('$dir/a', '$dir/b');
      await pool.deleteFile('$dir/b');
      await pool.rmdir(dir);
      expect(await pool.exists(dir), isFalse);
    });

    test('parallel writes from every worker', () async {
      await Future.wait([
        for (var i = 0; i < 12; i++)
          pool.writeFile(scratch.path('p$i.bin'), Uint8List.fromList([i])),
      ]);
      for (var i = 0; i < 12; i++) {
        expect(await pool.readFile(scratch.path('p$i.bin')), [i]);
      }
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
      final client = connectClient();
      try {
        client.symlink('sl_target', scratch.path('sl_client'));
        expect(client.readlink(scratch.path('sl_client')), 'sl_target');
      } finally {
        client.disconnect();
      }
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

  group('watch', () {
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
  });

  group('trees', () {
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

    test('rmdir -r refuses the share root', () async {
      for (final root in ['', '/', r'\', '//']) {
        expect(() => pool.rmdir(root, recursive: true), throwsArgumentError);
      }
      expect(await pool.exists(seedFile), isTrue);
    });

    test('rmdir -r removes a link made over SMB, not its target', () async {
      final target = scratch.path('rml_target');
      await pool.mkdir(target);
      await pool.writeFile('$target/keep', pattern(1));
      final link = scratch.path('rml_link');
      // Samba refuses a directory link over SMB; a file link to a
      // directory is a reparse point all the same.
      await pool.symlink('rml_target', link);
      await pool.rmdir(link, recursive: true);
      expect(await pool.exists(link), isFalse);
      expect(await pool.readFile('$target/keep'), pattern(1));
    });

    test('rmdir -r does not go through a link Samba follows', () async {
      final out = scratch.path('rmf_out');
      await pool.mkdir(out);
      await pool.writeFile('$out/keep', pattern(1));
      final tree = scratch.path('rmf_tree');
      await pool.mkdir(tree);
      await pool.writeFile('$tree/file', pattern(1));
      Link(hostPath('$tree/out')).createSync('../rmf_out');
      Link(hostPath(scratch.path('rmf_link'))).createSync('rmf_out');
      // Samba shows both links as directories and cannot remove them;
      // nothing is removed.
      for (final path in [tree, scratch.path('rmf_link'), out]) {
        await expectLater(
          pool.rmdir(path, recursive: true),
          throwsType(Smb2ErrorType.notSupported),
        );
      }
      expect(await pool.readFile('$out/keep'), pattern(1));
      expect(await pool.readFile('$tree/file'), pattern(1));
      Link(hostPath('$tree/out')).deleteSync();
      Link(hostPath(scratch.path('rmf_link'))).deleteSync();
      await pool.rmdir(tree, recursive: true);
      expect(await pool.exists(tree), isFalse);
    });

    test('rmdir -r stops at the first failure', () async {
      final root = scratch.path('rm_stop');
      await pool.mkdir('$root/sub', recursive: true);
      for (var i = 0; i < 30; i++) {
        await pool.writeFile('$root/f$i', pattern(1));
      }
      await pool.writeFile('$root/sub/locked', pattern(1));
      // Another client holds it open, which Samba takes as in use.
      final holder = connectClient();
      final handle = holder.openFile('$root/sub/locked');
      try {
        await expectLater(
          pool.rmdir(root, recursive: true),
          throwsA(isA<Smb2Exception>()),
        );
        final left = await pool.streamDirectory(root, recursive: true).length;
        await Future<void>.delayed(const Duration(seconds: 1));
        // Nothing went on after the failure.
        expect(await pool.streamDirectory(root, recursive: true).length, left);
        expect(await pool.exists('$root/sub'), isTrue);
      } finally {
        holder
          ..closeHandle(handle)
          ..disconnect();
      }
      await pool.rmdir(root, recursive: true);
    });

    test('streamDirectory and copyTree do not loop through links', () async {
      final root = scratch.path('loop');
      await pool.mkdir('$root/a', recursive: true);
      await pool.writeFile('$root/a/f', pattern(10));
      Link(hostPath('$root/a/up')).createSync('..');
      Link(hostPath('$root/a/out')).createSync('../../rml_none');
      Directory(hostPath(scratch.path('rml_none'))).createSync();
      File(hostPath(scratch.path('rml_none/x'))).writeAsBytesSync([1]);
      try {
        final names = await pool
            .streamDirectory(root, recursive: true)
            .map((e) => e.name)
            .toList();
        expect(names, unorderedEquals(['a', 'a/f', 'a/up', 'a/out']));
        final copied = scratch.path('loop_copy');
        expect(await pool.copyTree(root, copied), 10);
        expect(
          await pool
              .streamDirectory(copied, recursive: true)
              .map((e) => e.name)
              .toList(),
          unorderedEquals(['a', 'a/f']),
        );
      } finally {
        Link(hostPath('$root/a/up')).deleteSync();
        Link(hostPath('$root/a/out')).deleteSync();
      }
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

  group('uploads', () {
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
        throwsA(
          isA<Smb2Exception>()
              .having((e) => e.type, 'type', Smb2ErrorType.notFound)
              .having((e) => e.path, 'path', '${local.path}/missing'),
        ),
      );
    });
  });
}
