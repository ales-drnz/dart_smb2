import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/server_config.dart';
import '../widgets/app_text_field.dart';
import '../widgets/disk_space_bar.dart';
import '../providers/connection_provider.dart';
import '../widgets/app_sliver_page.dart';

class ServersPage extends ConsumerWidget {
  final List<ServerConfig> servers;
  final VoidCallback onChanged;

  const ServersPage({
    super.key,
    required this.servers,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<Smb2ConnectionState>(connectionProvider, (previous, next) {
      if (next.error != null && previous?.error != next.error) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.error_outline, color: Colors.red),
                SizedBox(width: 8),
                Text('Connection Error'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    next.error ?? 'Unknown error',
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: next.error ?? ''));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Error copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 18),
                label: const Text('Copy'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    });

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(context, ref, null),
        elevation: 0,
        highlightElevation: 0,
        child: const Icon(Icons.add),
      ),
      body: SafeArea(
        child: AppSliverPage(
          title: 'Servers',
          showEmptyState: servers.isEmpty,
          emptyIcon: Icons.dns_outlined,
          emptyTitle: 'No Servers',
          emptySubtitle: 'Add SMB server to start testing.',
          contentSliver: SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            sliver: SliverList.separated(
              itemCount: servers.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (ctx, i) {
                return _ServerCard(
                  key: ValueKey(servers[i]),
                  config: servers[i],
                  onEdit: () => _openEditor(context, ref, i),
                  onDelete: () {
                    servers.removeAt(i);
                    onChanged();
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, WidgetRef ref, int? index) async {
    final existing = index != null ? servers[index] : null;
    final result = await Navigator.of(context).push<ServerConfig>(
      MaterialPageRoute(
        builder: (_) => _ServerEditorPage(config: existing?.copy()),
      ),
    );
    if (result == null) return;
    if (index != null) {
      final currentConfig = ref.read(connectionProvider).config;
      // Compare by address since the config object is the same in the list
      final isCurrent = currentConfig == servers[index];
      
      if (isCurrent) {
        // Must disconnect FIRST to clear the old state reference
        await ref.read(connectionProvider.notifier).disconnect();
      }
      servers[index] = result;
    } else {
      servers.add(result);
    }
    onChanged();
  }
}

// ─── Server editor ──────────────────────────────────────────────────────────

class _ServerEditorPage extends StatefulWidget {
  final ServerConfig? config;
  const _ServerEditorPage({this.config});

  @override
  State<_ServerEditorPage> createState() => _ServerEditorPageState();
}

class _ServerEditorPageState extends State<_ServerEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _share;
  late final TextEditingController _user;
  late final TextEditingController _password;
  late final TextEditingController _domain;
  late bool _seal;
  late bool _signing;
  late Smb2Version _version;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _name = TextEditingController(text: c?.name ?? '');
    _host = TextEditingController(text: c?.host ?? '');
    _share = TextEditingController(text: c?.share ?? '');
    _user = TextEditingController(text: c?.user ?? '');
    _password = TextEditingController(text: c?.password ?? '');
    _domain = TextEditingController(text: c?.domain ?? '');
    _seal = c?.seal ?? false;
    _signing = c?.signing ?? false;
    _version = c?.version ?? Smb2Version.any;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _share.dispose();
    _user.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  Widget _section(BuildContext context, {required IconData icon, required String title, required List<Widget> children}) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: cs.onSecondaryContainer),
                ),
                const SizedBox(width: 12),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _toggleTile(BuildContext context, {required String title, required String subtitle, required bool value, required ValueChanged<bool> onChanged}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13)),
                Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey[600])),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _dropdownTile(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonFormField<Smb2Version>(
        initialValue: _version,
        mouseCursor: SystemMouseCursors.click,
        decoration: const InputDecoration(labelText: 'Protocol version', border: InputBorder.none, isDense: true),
        style: const TextStyle(fontSize: 13, color: Colors.black87),
        items: Smb2Version.values.map((v) => DropdownMenuItem(value: v, child: Text(v.name))).toList(),
        onChanged: (v) => setState(() => _version = v!),
      ),
    );
  }

  void _save() {
    if (_host.text.isEmpty || _share.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Host and Share are required')),
      );
      return;
    }
    Navigator.of(context).pop(ServerConfig(
      name: _name.text,
      host: _host.text,
      share: _share.text,
      user: _user.text,
      password: _password.text,
      domain: _domain.text,
      seal: _seal,
      signing: _signing,
      version: _version,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(widget.config == null ? 'Add Server' : 'Edit Server',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        children: [
          _section(
            context,
            icon: Icons.dns_outlined,
            title: 'Info',
            children: [
              AppTextField(controller: _name, label: 'Name (optional)'),
              const SizedBox(height: 8),
              AppTextField(controller: _host, label: 'Host *'),
              const SizedBox(height: 8),
              AppTextField(controller: _share, label: 'Share * (e.g. Files or Files/Musica)'),
              const SizedBox(height: 8),
              AppTextField(controller: _user, label: 'User'),
              const SizedBox(height: 8),
              AppTextField(controller: _password, label: 'Password', obscureText: true),
              const SizedBox(height: 8),
              AppTextField(controller: _domain, label: 'Domain'),
            ],
          ),
          const SizedBox(height: 12),
          _section(
            context,
            icon: Icons.shield_outlined,
            title: 'Security',
            children: [
              _toggleTile(context, title: 'Encryption (seal)', subtitle: 'Requires SMB 3.0+', value: _seal, onChanged: (v) => setState(() => _seal = v)),
              const SizedBox(height: 8),
              _toggleTile(context, title: 'Signing', subtitle: 'Require message signing', value: _signing, onChanged: (v) => setState(() => _signing = v)),
            ],
          ),
          const SizedBox(height: 12),
          _section(
            context,
            icon: Icons.tune_outlined,
            title: 'Version',
            children: [
              _dropdownTile(context),
            ],
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _save,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF0D47A1),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                child: const Text('Save Server',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerCard extends ConsumerStatefulWidget {
  final ServerConfig config;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _ServerCard({
    super.key,
    required this.config,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  ConsumerState<_ServerCard> createState() => _ServerCardState();
}

class _ServerCardState extends ConsumerState<_ServerCard> with AutomaticKeepAliveClientMixin {
  bool _isChecking = true;
  bool _isOnline = false;
  int? _ping;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    if (!mounted) return;
    setState(() {
      _isChecking = true;
    });

    try {
      final watch = Stopwatch()..start();
      // Using Smb2Pool.connect partially just to check availability
      final pool = await Smb2Pool.connect(
        host: widget.config.host,
        share: widget.config.shareName,
        user: widget.config.user,
        password: widget.config.password,
        domain: widget.config.domain,
        workers: 1,
      );
      await pool.disconnect();
      watch.stop();

      if (mounted) {
        setState(() {
          _isOnline = true;
          _ping = watch.elapsedMilliseconds;
          _isChecking = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isOnline = false;
          _ping = null;
          _isChecking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = widget.config;
    final cs = Theme.of(context).colorScheme;

    final connection = ref.watch(connectionProvider);
    final isCurrent = connection.config == s;
    final isConnected = isCurrent && connection.isConnected;
    final isConnecting = isCurrent && connection.connecting;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.dns, size: 18, color: cs.onSecondaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.displayName, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(s.user.isNotEmpty ? s.user : 'No user', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                    ],
                  ),
                ),
                _StatusBadge(
                  isOnline: _isOnline,
                  isChecking: _isChecking,
                  ping: _ping,
                  onTap: _checkStatus,
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: isConnecting
                        ? null
                        : () async {
                            if (isConnected) {
                              ref.read(connectionProvider.notifier).disconnect();
                            } else {
                              await ref.read(connectionProvider.notifier).connect(s);
                              if (mounted) _checkStatus();
                            }
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0D47A1),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 36),
                      fixedSize: const Size.fromHeight(36),
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: isConnecting
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(isConnected ? Icons.link_off : Icons.link, size: 16),
                              const SizedBox(width: 8),
                              Text(isConnected ? 'Disconnect' : 'Connect', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.normal)),
                            ],
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: widget.onEdit,
                  icon: const Icon(Icons.edit, size: 16),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    minimumSize: const Size(36, 36),
                    fixedSize: const Size(36, 36),
                    padding: EdgeInsets.zero,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: widget.onDelete,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  style: IconButton.styleFrom(
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    minimumSize: const Size(36, 36),
                    fixedSize: const Size(36, 36),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            if (isConnected) DiskSpaceBar(config: s),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isOnline;
  final bool isChecking;
  final int? ping;
  final VoidCallback onTap;

  const _StatusBadge({
    required this.isOnline,
    required this.isChecking,
    this.ping,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isChecking ? Colors.grey : (isOnline ? Colors.green : Colors.red);
    return InkWell(
      onTap: isChecking ? null : onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              isChecking ? 'Checking...' : (isOnline ? (ping != null ? '${ping}ms' : 'Online') : 'Offline'),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.normal, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
