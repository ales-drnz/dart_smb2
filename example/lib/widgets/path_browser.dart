import 'package:flutter/material.dart';

typedef PathLister = Future<List<String>> Function(String parentPath);

class PathBrowserDialog extends StatefulWidget {
  final PathLister pathLister;
  const PathBrowserDialog({super.key, required this.pathLister});

  @override
  State<PathBrowserDialog> createState() => _PathBrowserDialogState();
}

class _PathBrowserDialogState extends State<PathBrowserDialog> {
  String _currentPath = '';
  List<String> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String path) async {
    setState(() { _loading = true; _error = null; });
    try {
      final entries = await widget.pathLister(path);
      setState(() { _currentPath = path; _entries = entries; _loading = false; });
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _enter(String name) async {
    final child = _currentPath.isEmpty ? name : '$_currentPath/$name';
    try {
      final entries = await widget.pathLister(child);
      if (entries.isEmpty) {
        if (mounted) Navigator.pop(context, child);
        return;
      }
      setState(() { _currentPath = child; _entries = entries; });
    } catch (_) {
      if (mounted) Navigator.pop(context, child);
    }
  }

  void _goUp() {
    if (_currentPath.isEmpty) return;
    final sep = _currentPath.lastIndexOf('/');
    _load(sep > 0 ? _currentPath.substring(0, sep) : '');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 20),
                    onPressed: _currentPath.isNotEmpty ? _goUp : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '/${_currentPath.isEmpty ? '' : _currentPath}',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(),
            Flexible(
              child: _loading
                  ? const Center(child: Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()))
                  : _error != null
                      ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!, style: TextStyle(color: Colors.red[700], fontSize: 13))))
                      : _entries.isEmpty
                          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Empty directory')))
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: _entries.length,
                              itemBuilder: (ctx, i) => ListTile(
                                dense: true,
                                leading: const Icon(Icons.folder_outlined, size: 20),
                                title: Text(_entries[i], style: const TextStyle(fontSize: 13)),
                                onTap: () => _enter(_entries[i]),
                              ),
                            ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: () => Navigator.pop(context, _currentPath), child: const Text('Select')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
