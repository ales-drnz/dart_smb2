import 'dart:io';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server_config.dart';
import '../widgets/test_card.dart';
import '../providers/connection_provider.dart';
import '../utils/smb_test_page_mixin.dart';
import '../widgets/app_sliver_page.dart';

class ReadTestsPage extends ConsumerStatefulWidget {
  final List<ServerConfig> servers;
  const ReadTestsPage({super.key, required this.servers});

  @override
  ConsumerState<ReadTestsPage> createState() => _ReadTestsPageState();
}

class _ReadTestsPageState extends ConsumerState<ReadTestsPage> with SmbTestPageMixin<ReadTestsPage> {
  final Map<String, Map<String, String>> _params = {};

  @override
  Map<String, Map<String, String>> get paramsStore => _params;

  Future<String> _withFirstEntry(String path, Future<String> Function(String value) run) async {
    var resolvedPath = path;
    if (resolvedPath.isEmpty) {
      final first = await firstEntryName();
      if (first == null) return 'No entries';
      resolvedPath = first;
    }
    return run(resolvePath(resolvedPath));
  }

  Future<String> _withFirstFile(
    String path,
    Future<String> Function(String value) run, {
    int? maxSizeBytes,
    String emptyMessage = 'No files',
  }) async {
    var resolvedPath = path;
    if (resolvedPath.isEmpty) {
      final first = await firstFileName(maxSizeBytes: maxSizeBytes);
      if (first == null) return emptyMessage;
      resolvedPath = first;
    }
    return run(resolvePath(resolvedPath));
  }

  List<TestDef> get _tests => [
    TestDef(key: 'listDirectory', name: 'List Directory', description: 'Lists all entries in a directory.', icon: Icons.folder_outlined, params: {'path': ''},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('listDirectory', 'path', ''));
        final entries = await pool.listDirectory(path);
        return '${entries.length} entries: ${entries.map((e) => e.name).join(', ')}';
      })),
    TestDef(key: 'stat', name: 'Stat', description: 'Gets type, size and timestamps for a path.', icon: Icons.info_outlined, params: {'path': ''},
      run: () => runConnected((pool) async {
        final path = param('stat', 'path', '');
        return _withFirstEntry(path, (resolvedPath) async {
          final info = await pool.stat(resolvedPath);
          return '$resolvedPath: ${info.type.name}, ${info.size} bytes, modified: ${info.modified}';
        });
      })),
    TestDef(key: 'fileSize', name: 'File Size', description: 'Gets the size of a file.', icon: Icons.straighten, params: {'path': ''},
      run: () => runConnected((pool) async {
        final path = param('fileSize', 'path', '');
        return _withFirstFile(path, (resolvedPath) async {
          return '$resolvedPath: ${await pool.fileSize(resolvedPath)} bytes';
        });
      })),
    TestDef(key: 'exists', name: 'Exists', description: 'Checks if a path exists.', icon: Icons.help_outline, params: {'path': '__nonexistent_12345__'},
      run: () => runConnected((pool) async {
        final path = resolvePath(param('exists', 'path', '__nonexistent_12345__'));
        return '"$path": ${await pool.exists(path)}';
      })),
    TestDef(key: 'readFileRange', name: 'Read File Range', description: 'Reads N bytes at an offset.', icon: Icons.content_cut, params: {'path': '', 'offset': '0', 'length': '1024'},
      run: () => runConnected((pool) async {
        final path = param('readFileRange', 'path', '');
        final offset = paramInt('readFileRange', 'offset', 0);
        final length = paramInt('readFileRange', 'length', 1024);
        return _withFirstFile(path, (resolvedPath) async {
          final bytes = await pool.readFileRange(resolvedPath, offset: offset, length: length);
          return '$resolvedPath: read ${bytes.length} bytes at offset $offset';
        });
      })),
    TestDef(key: 'readFile', name: 'Read File', description: 'Reads an entire file into memory.', icon: Icons.file_download_outlined, params: {'path': ''},
      run: () => runConnected((pool) async {
        final path = param('readFile', 'path', '');
        return _withFirstFile(path, (resolvedPath) async {
          return '$resolvedPath: ${(await pool.readFile(resolvedPath)).length} bytes';
        }, maxSizeBytes: 5 * 1024 * 1024, emptyMessage: 'No small file (< 5 MB)');
      })),
    TestDef(key: 'streamFile', name: 'Stream File', description: 'Streams a file with progress and cancel support.', icon: Icons.stream, params: {'path': '', 'chunkSize': '65536'},
      run: () => runConnected((pool) async {
        final path = param('streamFile', 'path', '');
        final chunkSize = paramInt('streamFile', 'chunkSize', 65536);
        return _withFirstFile(path, (resolvedPath) async {
          int total = 0, chunks = 0, lastPct = -1;
          await for (final c in pool.streamFile(
            resolvedPath,
            chunkSize: chunkSize,
            onProgress: (received, size) {
              final pct = (received * 100 ~/ size);
              if (pct != lastPct) lastPct = pct;
            },
          )) {
            total += c.length;
            chunks++;
          }
          return '$resolvedPath: $total bytes in $chunks chunks (reached $lastPct%)';
        }, maxSizeBytes: 5 * 1024 * 1024, emptyMessage: 'No small file (< 5 MB)');
      })),
    TestDef(key: 'withFile', name: 'With File (scoped)', description: 'Opens a scoped handle with auto-close and reads a header.', icon: Icons.folder_open, params: {'path': '', 'length': '4096'},
      run: () => runConnected((pool) async {
        final path = param('withFile', 'path', '');
        final length = paramInt('withFile', 'length', 4096);
        return _withFirstFile(path, (resolvedPath) async {
          return pool.withFile(resolvedPath, (file) async {
            final head = await file.read(length: length.clamp(0, file.size));
            return '$resolvedPath: ${head.length} bytes read (size: ${file.size}, auto-closed)';
          });
        });
      })),
    TestDef(key: 'downloadToFile', name: 'Download To File', description: 'Downloads an SMB file to a local temp file.', icon: Icons.download, params: {'path': ''},
      run: () => runConnected((pool) async {
        final path = param('downloadToFile', 'path', '');
        return _withFirstFile(path, (resolvedPath) async {
          final dest = File(
            '${Directory.systemTemp.path}/dart_smb2_download_${DateTime.now().millisecondsSinceEpoch}.bin',
          );
          int lastPct = 0;
          try {
            final bytes = await pool.downloadToFile(
              resolvedPath,
              dest,
              onProgress: (received, size) {
                lastPct = received * 100 ~/ size;
              },
            );
            return 'Wrote $bytes bytes to ${dest.path} (peak $lastPct%)';
          } finally {
            if (await dest.exists()) await dest.delete();
          }
        }, maxSizeBytes: 5 * 1024 * 1024, emptyMessage: 'No small file (< 5 MB)');
      })),
    TestDef(key: 'openFileWithSize', name: 'Open File With Size', description: 'Opens a handle and returns (handle, size) in one round-trip.', icon: Icons.open_with, params: {'path': ''},
      run: () => runConnected((pool) async {
        final path = param('openFileWithSize', 'path', '');
        return _withFirstFile(path, (resolvedPath) async {
          final (handle, size) = await pool.openFileWithSize(resolvedPath);
          try {
            return '$resolvedPath: size=$size bytes, handle opened + closed in 2 RTTs';
          } finally {
            await pool.closeHandle(handle);
          }
        });
      })),
    TestDef(key: 'errorTypes', name: 'Error Classification', description: 'Runs stat / exists / deleteFile on bad paths and reports classified Smb2ErrorType.', icon: Icons.report_problem_outlined, params: {},
      run: () => runConnected((pool) async {
        final results = <String>[];
        final badPath = resolvePath('__dart_smb2_nonexistent_${DateTime.now().millisecondsSinceEpoch}__');

        // stat on missing → expect fileNotFound
        try {
          await pool.stat(badPath);
          results.add('stat: unexpectedly succeeded');
        } on Smb2Exception catch (e) {
          results.add('stat(missing) → ${e.type.name} (errno=${e.errorCode})');
        }

        // exists on missing → expect false (no throw)
        try {
          final r = await pool.exists(badPath);
          results.add('exists(missing) → $r');
        } on Smb2Exception catch (e) {
          results.add('exists(missing) THREW → ${e.type.name}');
        }

        // deleteFile on missing → expect fileNotFound
        try {
          await pool.deleteFile(badPath);
          results.add('deleteFile: unexpectedly succeeded');
        } on Smb2Exception catch (e) {
          results.add('deleteFile(missing) → ${e.type.name} (errno=${e.errorCode})');
        }

        return results.join('\n');
      })),
    TestDef(key: 'readHandle', name: 'Read Handle', description: 'Opens a handle, reads N bytes, closes — prefer withFile.', icon: Icons.open_in_new, params: {'path': '', 'length': '1024'},
      run: () => runConnected((pool) async {
        final path = param('readHandle', 'path', '');
        final length = paramInt('readHandle', 'length', 1024);
        return _withFirstFile(path, (resolvedPath) async {
          final (handle, size) = await pool.openFileWithSize(resolvedPath);
          try {
            final head = await pool.readFromHandle(handle, length: size.clamp(0, length));
            return '$resolvedPath: ${head.length} bytes via handle (size: $size)';
          } finally {
            await pool.closeHandle(handle);
          }
        });
      })),
    TestDef(key: 'statvfs', name: 'Disk Space', description: 'Queries total and free space.', icon: Icons.storage_outlined, params: {'path': ''},
      run: () => runConnected((pool) async {
        final vfs = await pool.statvfs(resolvePath(param('statvfs', 'path', '')));
        return 'Total: ${vfs.totalSize ~/ (1024 * 1024)} MB, Free: ${vfs.freeSize ~/ (1024 * 1024)} MB';
      })),
    TestDef(key: 'echo', name: 'Echo', description: 'Sends a keepalive ping.', icon: Icons.wifi_tethering, params: {},
      run: () => runConnected((pool) async { await pool.echo(); return 'Server responded'; })),
    TestDef(key: 'readlink', name: 'Read Symlink', description: 'Reads the target of a symbolic link.', icon: Icons.link, params: {'path': ''},
      run: () => runConnected((pool) async {
        var path = param('readlink', 'path', '');
        if (path.isEmpty) {
          final link = await firstLinkName();
          if (link == null) return 'No symlinks in root';
          path = link;
        }
        path = resolvePath(path);
        return '$path -> ${await pool.readlink(path)}';
      })),
    TestDef(key: 'listShares', name: 'List Shares', description: 'Enumerates all shares on the server.', icon: Icons.share_outlined, params: {},
      run: () => runConnected((_) async {
        final config = ref.read(connectionProvider).config;
        if (config == null) return 'No server configuration found';
        final shares = await Smb2Pool.listSharesOn(
          host: config.host,
          user: config.user.isNotEmpty ? config.user : null,
          password: config.password.isNotEmpty ? config.password : null,
          domain: config.domain.isNotEmpty ? config.domain : null,
        );
        return '${shares.length} shares (${shares.where((s) => s.isDisk).length} disk): ${shares.where((s) => !s.isHidden).map((s) => s.name).join(', ')}';
      })),
  ];

  @override
  Widget build(BuildContext context) {
    final connection = ref.watch(connectionProvider);
    final pool = connection.pool;

    return AppSliverPage(
      title: 'Read',
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
              key: ValueKey('read-test-${t.key}'),
              def: t,
              enabled: true,
              params: _params[t.key] ?? {},
              onParamsChanged: (p) => setState(() => _params[t.key] = p),
              pathLister: listEntries,
            );
          },
        ),
      ),
    );
  }
}
