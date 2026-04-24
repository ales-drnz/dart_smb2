import 'dart:async';
import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server_config.dart';
import '../widgets/test_card.dart';
import '../providers/connection_provider.dart';
import '../utils/smb_test_page_mixin.dart';
import '../widgets/app_sliver_page.dart';

class WriteTestsPage extends ConsumerStatefulWidget {
  final List<ServerConfig> servers;
  const WriteTestsPage({super.key, required this.servers});

  @override
  ConsumerState<WriteTestsPage> createState() => _WriteTestsPageState();
}

class _WriteTestsPageState extends ConsumerState<WriteTestsPage> with SmbTestPageMixin<WriteTestsPage> {
  static const _testDir = '_dart_smb2_example';

  final Map<String, Map<String, String>> _params = {};

  @override
  Map<String, Map<String, String>> get paramsStore => _params;

  bool _isDirectoryNotEmpty(Smb2Exception e) => e.message.toLowerCase().contains('not empty');

  Future<void> _ensureDirectoryTree(Smb2Pool pool, String directoryPath) async {
    final normalized = directoryPath.replaceAll('\\', '/').trim();
    if (normalized.isEmpty) return;

    var current = '';
    for (final part in normalized.split('/').where((p) => p.isNotEmpty)) {
      current = current.isEmpty ? part : '$current/$part';
      try {
        await pool.mkdir(current);
      } on Smb2Exception catch (e) {
        // Directory may already exist — the NT status varies by server,
        // so check the error message rather than relying on a single errno.
        if (e.message.contains('COLLISION') ||
            e.type == Smb2ErrorType.alreadyExists) {
          continue;
        }
        rethrow;
      }
    }
  }

  Future<void> _ensureParentDirectory(Smb2Pool pool, String filePath) async {
    final normalized = filePath.replaceAll('\\', '/').trim();
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) return;
    await _ensureDirectoryTree(pool, normalized.substring(0, lastSlash));
  }

  String _normalizePath(String path) => path.replaceAll('\\', '/').trim();

  String _parentPath(String path) {
    final normalized = _normalizePath(path);
    final lastSlash = normalized.lastIndexOf('/');
    if (lastSlash <= 0) return '';
    return normalized.substring(0, lastSlash);
  }

  Future<({List<String> info, List<String> errors})> _cleanupFileAndParents(Smb2Pool pool, String filePath) async {
    final info = <String>[];
    final errors = <String>[];
    final normalized = _normalizePath(filePath);
    if (normalized.isEmpty) return (info: info, errors: errors);

    try {
      await pool.deleteFile(normalized);
      info.add('deleted: $normalized');
    } on Smb2Exception catch (e) {
      if (e.type == Smb2ErrorType.fileNotFound) {
        info.add('already missing: $normalized');
      } else {
        errors.add('delete failed ($normalized): ${e.message}');
      }
    }

    var parent = _parentPath(normalized);
    while (parent.isNotEmpty) {
      try {
        await pool.rmdir(parent);
        info.add('removed dir: $parent');
      } on Smb2Exception catch (e) {
        if (e.type == Smb2ErrorType.fileNotFound) {
          info.add('dir already missing: $parent');
        } else if (_isDirectoryNotEmpty(e)) {
          info.add('stop at non-empty dir: $parent');
        } else {
          errors.add('rmdir failed ($parent): ${e.message}');
        }
        break;
      }
      parent = _parentPath(parent);
    }

    return (info: info, errors: errors);
  }

  Future<({List<String> info, List<String> errors})> _cleanupDirectoryAndParents(Smb2Pool pool, String directoryPath) async {
    final info = <String>[];
    final errors = <String>[];
    var current = _normalizePath(directoryPath);
    if (current.isEmpty) return (info: info, errors: errors);

    while (current.isNotEmpty) {
      try {
        await pool.rmdir(current);
        info.add('removed dir: $current');
      } on Smb2Exception catch (e) {
        if (e.type == Smb2ErrorType.fileNotFound) {
          info.add('dir already missing: $current');
        } else if (_isDirectoryNotEmpty(e)) {
          info.add('stop at non-empty dir: $current');
        } else {
          errors.add('rmdir failed ($current): ${e.message}');
        }
        break;
      }
      current = _parentPath(current);
    }

    return (info: info, errors: errors);
  }

  Future<String> _cleanupForTest(String testKey) => runConnected((pool) async {
    final messages = <String>[];
    final errors = <String>[];
    switch (testKey) {
      case 'writeFile':
        final out = await _cleanupFileAndParents(pool, resolvePath(param('writeFile', 'path', '$_testDir/test.txt')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'writeFileRange':
        final out = await _cleanupFileAndParents(pool, resolvePath(param('writeFileRange', 'path', '$_testDir/range.bin')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'streamWrite':
        final out = await _cleanupFileAndParents(pool, resolvePath(param('streamWrite', 'path', '$_testDir/stream.bin')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'writeHandle':
        final out = await _cleanupFileAndParents(pool, resolvePath(param('writeHandle', 'path', '$_testDir/handle.bin')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'mkdir':
        final out = await _cleanupDirectoryAndParents(pool, resolvePath(param('mkdir', 'path', '$_testDir/subdir')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'rmdir':
        final out = await _cleanupDirectoryAndParents(pool, resolvePath(param('rmdir', 'path', '$_testDir/subdir')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'deleteFile':
        final out = await _cleanupFileAndParents(pool, resolvePath(param('deleteFile', 'path', '$_testDir/test.txt')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'rename':
        final fromOut = await _cleanupFileAndParents(pool, resolvePath(param('rename', 'from', '$_testDir/test.txt')));
        messages.addAll(fromOut.info);
        errors.addAll(fromOut.errors);
        final toOut = await _cleanupFileAndParents(pool, resolvePath(param('rename', 'to', '$_testDir/renamed.txt')));
        messages.addAll(toOut.info);
        errors.addAll(toOut.errors);
        break;
      case 'truncate':
        final out = await _cleanupFileAndParents(pool, resolvePath(param('truncate', 'path', '$_testDir/truncated.txt')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'ftruncate':
        final out = await _cleanupFileAndParents(pool, resolvePath(param('ftruncate', 'path', '$_testDir/truncated.txt')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      case 'fsync':
        final out = await _cleanupFileAndParents(pool, resolvePath(param('fsync', 'path', '$_testDir/fsync.bin')));
        messages.addAll(out.info);
        errors.addAll(out.errors);
        break;
      default:
        return 'Nothing to clean for this test';
    }

    if (errors.isNotEmpty) {
      throw Smb2Exception(errors.join(', '), 0, Smb2ErrorType.unknown);
    }

    return messages.isEmpty ? 'Nothing removed' : messages.join(', ');
  });

  List<TestDef> get _tests => [
    TestDef(key: 'writeFile', name: 'Write File', description: 'Creates parent directory if needed, writes data, then reads it back.', icon: Icons.file_upload_outlined, params: {'path': '$_testDir/test.txt', 'content': 'Hello from dart_smb2!'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('writeFile', 'path', '$_testDir/test.txt'));
        final content = param('writeFile', 'content', 'Hello from dart_smb2!');
        final data = Uint8List.fromList(content.codeUnits);
        await _ensureParentDirectory(pool, path);
        await pool.writeFile(path, data);
        final read = await pool.readFile(path);
        return 'Wrote ${data.length} B, read ${read.length} B, match: ${String.fromCharCodes(read) == content}';
      })),
    TestDef(key: 'writeFileRange', name: 'Write File Range', description: 'Writes at an offset without truncating.', icon: Icons.content_paste, params: {'path': '$_testDir/range.bin', 'base': 'AAAAAAAAAA', 'patch': 'BBB', 'offset': '3'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('writeFileRange', 'path', '$_testDir/range.bin'));
        final base = param('writeFileRange', 'base', 'AAAAAAAAAA');
        final patch = param('writeFileRange', 'patch', 'BBB');
        final offset = paramInt('writeFileRange', 'offset', 3);
        await _ensureParentDirectory(pool, path);
        await pool.writeFile(path, Uint8List.fromList(base.codeUnits));
        await pool.writeFileRange(path, Uint8List.fromList(patch.codeUnits), offset: offset);
        final read = await pool.readFile(path);
        return '"${String.fromCharCodes(read)}"';
      })),
    TestDef(key: 'streamWrite', name: 'Stream Write', description: 'Writes multiple chunks from an async stream.', icon: Icons.stream, params: {'path': '$_testDir/stream.bin', 'content': 'Stream write test!'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('streamWrite', 'path', '$_testDir/stream.bin'));
        final content = param('streamWrite', 'content', 'Stream write test!');
        final third = (content.length / 3).ceil();
        final parts = <Uint8List>[];
        for (var i = 0; i < content.length; i += third) {
          parts.add(Uint8List.fromList(content.substring(i, (i + third).clamp(0, content.length)).codeUnits));
        }
        await _ensureParentDirectory(pool, path);
        await pool.streamWrite(path, Stream.fromIterable(parts));
        final read = await pool.readFile(path);
        return '"${String.fromCharCodes(read)}" (${parts.length} chunks)';
      })),
    TestDef(key: 'writeHandle', name: 'Write Handle', description: 'Opens a write handle, writes chunks, flushes, closes.', icon: Icons.open_in_new, params: {'path': '$_testDir/handle.bin', 'chunk1': 'AB', 'chunk2': 'CD'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('writeHandle', 'path', '$_testDir/handle.bin'));
        final c1 = param('writeHandle', 'chunk1', 'AB');
        final c2 = param('writeHandle', 'chunk2', 'CD');
        await _ensureParentDirectory(pool, path);
        final handle = await pool.openFileWrite(path);
        await pool.writeToHandle(handle, Uint8List.fromList(c1.codeUnits), offset: 0);
        await pool.writeToHandle(handle, Uint8List.fromList(c2.codeUnits), offset: c1.length);
        await pool.fsyncHandle(handle);
        await pool.closeHandle(handle);
        final read = await pool.readFile(path);
        return '"${String.fromCharCodes(read)}"';
      })),
    TestDef(key: 'mkdir', name: 'Create Directory', description: 'Creates a directory and verifies with stat.', icon: Icons.create_new_folder_outlined, params: {'path': '$_testDir/subdir'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('mkdir', 'path', '$_testDir/subdir'));
        try { await pool.rmdir(path); } catch (_) {}
        await _ensureParentDirectory(pool, path);
        await pool.mkdir(path);
        return 'Created, isDirectory: ${(await pool.stat(path)).isDirectory}';
      })),
    TestDef(key: 'rmdir', name: 'Remove Directory', description: 'Removes a directory and verifies.', icon: Icons.folder_delete_outlined, params: {'path': '$_testDir/subdir'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('rmdir', 'path', '$_testDir/subdir'));
        await _ensureParentDirectory(pool, path);
        try { await pool.mkdir(path); } catch (_) {}
        await pool.rmdir(path);
        return 'Removed, exists: ${await pool.exists(path)}';
      })),
    TestDef(key: 'deleteFile', name: 'Delete File', description: 'Creates a file, deletes it, verifies.', icon: Icons.delete_outline, params: {'path': '$_testDir/test.txt'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('deleteFile', 'path', '$_testDir/test.txt'));
        await _ensureParentDirectory(pool, path);
        await pool.writeFile(path, Uint8List.fromList('x'.codeUnits));
        await pool.deleteFile(path);
        return 'Deleted, exists: ${await pool.exists(path)}';
      })),
    TestDef(key: 'rename', name: 'Rename / Move', description: 'Renames a file and verifies.', icon: Icons.drive_file_rename_outline, params: {'from': '$_testDir/test.txt', 'to': '$_testDir/renamed.txt'},
      run: () => runConnected((pool) async {
        final from = resolvePath(param('rename', 'from', '$_testDir/test.txt'));
        final to = resolvePath(param('rename', 'to', '$_testDir/renamed.txt'));
        await _ensureParentDirectory(pool, from);
        await _ensureParentDirectory(pool, to);
        await pool.writeFile(from, Uint8List.fromList('move me'.codeUnits));
        await pool.rename(from, to);
        final read = await pool.readFile(to);
        return 'Old exists: ${await pool.exists(from)}, content: "${String.fromCharCodes(read)}"';
      })),
    TestDef(key: 'truncate', name: 'Truncate', description: 'Truncates a file to N bytes.', icon: Icons.content_cut, params: {'path': '$_testDir/truncated.txt', 'content': '1234567890', 'length': '5'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('truncate', 'path', '$_testDir/truncated.txt'));
        final content = param('truncate', 'content', '1234567890');
        final length = paramInt('truncate', 'length', 5);
        await _ensureParentDirectory(pool, path);
        await pool.writeFile(path, Uint8List.fromList(content.codeUnits));
        await pool.truncate(path, length);
        final read = await pool.readFile(path);
        return '"${String.fromCharCodes(read)}"';
      })),
    TestDef(key: 'fsync', name: 'Fsync Handle', description: 'Writes via a handle and flushes to disk with fsync before close.', icon: Icons.save_alt, params: {'path': '$_testDir/fsync.bin', 'content': 'flush me'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('fsync', 'path', '$_testDir/fsync.bin'));
        final content = param('fsync', 'content', 'flush me');
        await _ensureParentDirectory(pool, path);
        final handle = await pool.openFileWrite(path);
        try {
          await pool.writeToHandle(handle, Uint8List.fromList(content.codeUnits), offset: 0);
          await pool.fsyncHandle(handle);
        } finally {
          await pool.closeHandle(handle);
        }
        final read = await pool.readFile(path);
        return 'Wrote "${String.fromCharCodes(read)}", fsync confirmed ${read.length} bytes persisted';
      })),
    TestDef(key: 'ftruncate', name: 'Truncate Handle', description: 'Truncates via an open file handle.', icon: Icons.compress, params: {'path': '$_testDir/truncated.txt', 'content': 'ABCDEFGHIJ', 'length': '3'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('ftruncate', 'path', '$_testDir/truncated.txt'));
        final content = param('ftruncate', 'content', 'ABCDEFGHIJ');
        final length = paramInt('ftruncate', 'length', 3);
        await _ensureParentDirectory(pool, path);
        await pool.writeFile(path, Uint8List.fromList(content.codeUnits));
        final handle = await pool.openFileWrite(path);
        await pool.ftruncateHandle(handle, length);
        await pool.closeHandle(handle);
        final read = await pool.readFile(path);
        return '"${String.fromCharCodes(read)}"';
      })),
  ];

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    final pool = connection.pool;

    return AppSliverPage(
      title: 'Write',
      showEmptyState: pool == null,
      emptyIcon: Icons.link_off,
      emptyTitle: 'Not Connected',
      emptySubtitle: 'Go to the Servers tab and connect.',
      contentSliver: SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        sliver: SliverList.separated(
          itemCount: _tests.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (ctx, i) {
            final t = _tests[i];
            return TestCard(
              key: ValueKey('write-test-${t.key}'),
              def: t,
              enabled: true,
              params: _params[t.key] ?? {},
              onParamsChanged: (p) => setState(() => _params[t.key] = p),
              pathLister: listEntries,
              onCleanup: () => _cleanupForTest(t.key),
              trailing: null,
            );
          },
        ),
      ),
    );
  }
}
