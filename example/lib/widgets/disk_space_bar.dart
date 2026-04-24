import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter/material.dart';
import '../models/server_config.dart';
import '../utils/format_utils.dart';

class DiskSpaceBar extends StatefulWidget {
  final ServerConfig config;

  const DiskSpaceBar({
    super.key,
    required this.config,
  });

  @override
  State<DiskSpaceBar> createState() => DiskSpaceBarState();
}

class DiskSpaceBarState extends State<DiskSpaceBar> with AutomaticKeepAliveClientMixin {
  Smb2StatVfs? _vfs;
  bool _loading = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    if (!mounted || _loading) return;
    if (_vfs != null) return; // Don't refresh if we already have data
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final pool = await Smb2Pool.connect(
        host: widget.config.host,
        share: widget.config.shareName,
        user: widget.config.user.isNotEmpty ? widget.config.user : null,
        password: widget.config.password.isNotEmpty ? widget.config.password : null,
        domain: widget.config.domain.isNotEmpty ? widget.config.domain : null,
        seal: widget.config.seal,
        signing: widget.config.signing,
        version: widget.config.version,
      );

      final vfs = await pool.statvfs(widget.config.basePath);
      await pool.disconnect();

      if (mounted) {
        setState(() {
          _vfs = vfs;
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
    super.build(context);
    final cs = Theme.of(context).colorScheme;

    Widget content;
    if (_vfs == null && !_loading && _error == null) {
      return const SizedBox.shrink();
    }

    if (_error != null && _vfs == null) {
      content = Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: cs.onSurfaceVariant.withValues(alpha: 0.5)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Disk space unavailable',
              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withValues(alpha: 0.6)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 14),
            onPressed: refresh,
            visualDensity: VisualDensity.compact,
          ),
        ],
      );
    } else {
      final used = _vfs != null ? _vfs!.totalSize - _vfs!.freeSize : 0;
      final total = _vfs != null ? _vfs!.totalSize : 0;
      final percent = total > 0 ? used / total : 0.0;

      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _vfs != null && !_loading
                  ? '${formatBytes(used)} / ${formatBytes(total)}'
                    : 'Calculating space...',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[700],
                  fontWeight: FontWeight.w500,
                ),
              ),
              Row(
                children: [
                   Text(
                    _loading ? '...' : '${(percent * 100).toStringAsFixed(1)}%',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF0D47A1),
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: _loading ? null : refresh,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        Icons.refresh,
                        size: 14,
                        color: _loading
                            ? const Color(0xFF0D47A1).withValues(alpha: 0.3)
                            : const Color(0xFF0D47A1).withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _loading ? null : (_vfs != null ? percent : 0.0),
              minHeight: 6,
              backgroundColor: cs.surfaceContainerHighest,
              color: const Color(0xFF0D47A1),
            ),
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: content,
    );
  }
}
