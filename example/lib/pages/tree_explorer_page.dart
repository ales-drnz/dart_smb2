import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dart_smb2/dart_smb2.dart';
import '../providers/connection_provider.dart';
import '../utils/format_utils.dart';
import '../widgets/app_sliver_page.dart';

class TreeExplorerPage extends ConsumerWidget {
  const TreeExplorerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(connectionProvider);

    return Scaffold(
      body: AppSliverPage(
        title: 'Browse',
        showEmptyState: !connection.isConnected,
        emptyIcon: Icons.link_off,
        emptyTitle: 'Not Connected',
        emptySubtitle: 'Go to the Servers tab and connect.',
        contentSliver: SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
          sliver: SliverToBoxAdapter(
            child: _TreeFolder(
              path: connection.config?.basePath ?? '',
              name: connection.config?.basePath.isNotEmpty == true
                  ? connection.config!.basePath
                  : (connection.config?.shareName ?? 'Share'),
            ),
          ),
        ),
      ),
    );
  }
}

class _TreeFolder extends ConsumerStatefulWidget {
  final String path;
  final String name;

  const _TreeFolder({required this.path, required this.name});

  @override
  ConsumerState<_TreeFolder> createState() => _TreeFolderState();
}

class _TreeFolderState extends ConsumerState<_TreeFolder> {
  bool _isExpanded = false;
  List<Smb2DirEntry>? _children;
  bool _loading = false;
  String? _error;

  Future<void> _toggle() async {
    setState(() {
      _isExpanded = !_isExpanded;
    });

    if (_isExpanded && _children == null) {
      await _fetch();
    }
  }

  Future<void> _fetch() async {
    final pool = ref.read(connectionProvider).pool;
    if (pool == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final list = await pool.listDirectory(widget.path);
      // Remove . and ..
      final filtered = list.where((e) => e.name != '.' && e.name != '..').toList();
      // Sort: folders first, then files
      filtered.sort((a, b) {
        if (a.isDirectory && !b.isDirectory) return -1;
        if (!a.isDirectory && b.isDirectory) return 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

      if (mounted) {
        setState(() {
          _children = filtered;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              children: [
                Icon(
                  _isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                  size: 20,
                  color: Colors.grey,
                ),
                const Icon(
                  Icons.folder_outlined,
                  size: 20,
                  color: Color(0xFF0D47A1),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.name,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_isExpanded)
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: _buildChildren(),
          ),
      ],
    );
  }

  Widget _buildChildren() {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(8.0),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 14),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Failed to load: $_error',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    if (_children != null) {
      if (_children!.isEmpty) {
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 4),
          child: Text('Empty folder', style: TextStyle(color: Colors.grey, fontSize: 12, fontStyle: FontStyle.italic)),
        );
      }

      return Column(
        children: _children!.map((e) {
          final childPath = widget.path.isEmpty ? e.name : '${widget.path}/${e.name}';
          if (e.isDirectory) {
            return _TreeFolder(path: childPath, name: e.name);
          } else {
            return _TreeFile(name: e.name, size: e.size);
          }
        }).toList(),
      );
    }

    return const SizedBox.shrink();
  }
}

class _TreeFile extends StatelessWidget {
  final String name;
  final int size;

  const _TreeFile({required this.name, required this.size});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Row(
        children: [
          const SizedBox(width: 20), // Placeholder for arrow
          const Icon(Icons.insert_drive_file_outlined, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              formatBytes(size),
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
