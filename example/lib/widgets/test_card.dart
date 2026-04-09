import 'package:flutter/material.dart';

import 'app_text_field.dart';
import 'path_browser.dart';

class TestDef {
  final String key;
  final String name;
  final String description;
  final IconData icon;
  final Map<String, String> params;
  final Future<String> Function() run;
  const TestDef({required this.key, required this.name, required this.description, this.icon = Icons.science_outlined, required this.params, required this.run});
}

class TestResult {
  final String? result;
  final int ms;
  final bool isError;
  final bool running;
  const TestResult({this.result, this.ms = 0, this.isError = false, this.running = false});
}

class TestCard extends StatefulWidget {
  final TestDef def;
  final bool enabled;
  final Map<String, String> params;
  final ValueChanged<Map<String, String>> onParamsChanged;
  final PathLister? pathLister;
  final Widget? trailing;
  final Future<String> Function()? onCleanup;

  const TestCard({
    super.key,
    required this.def,
    required this.enabled,
    required this.params,
    required this.onParamsChanged,
    this.pathLister,
    this.trailing,
    this.onCleanup,
  });

  @override
  State<TestCard> createState() => _TestCardState();
}

class _TestCardState extends State<TestCard> with AutomaticKeepAliveClientMixin {
  bool _expanded = false;
  TestResult? _localResult;
  bool _cleanupRunning = false;
  final Map<String, TextEditingController> _controllers = {};

  static const _pathKeys = {'path', 'from', 'to'};
  bool _isPathParam(String key) => _pathKeys.contains(key);

  void _syncControllers() {
    final defaults = widget.def.params;
    final current = widget.params;
    for (final key in defaults.keys) {
      final value = current[key] ?? defaults[key] ?? '';
      if (!_controllers.containsKey(key)) {
        _controllers[key] = TextEditingController(text: value)
          ..addListener(() {
            final updated = {for (final e in _controllers.entries) e.key: e.value.text};
            widget.onParamsChanged(updated);
          });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _syncControllers();
  }

  @override
  void didUpdateWidget(TestCard old) {
    super.didUpdateWidget(old);
    _syncControllers();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _browsePath(TextEditingController controller) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => PathBrowserDialog(pathLister: widget.pathLister!),
    );
    if (result != null && mounted) {
      controller.text = result;
      setState(() {});
    }
  }

  Future<void> _runTest() async {
    setState(() {
      _localResult = const TestResult(running: true);
    });
    final sw = Stopwatch()..start();
    try {
      final result = await widget.def.run();
      sw.stop();
      if (mounted) {
        setState(() {
          _localResult = TestResult(result: result, ms: sw.elapsedMilliseconds);
        });
      }
    } catch (e) {
      sw.stop();
      if (mounted) {
        setState(() {
          _localResult = TestResult(
            result: 'ERROR: $e',
            ms: sw.elapsedMilliseconds,
            isError: true,
          );
        });
      }
    }
  }

  Future<void> _runCleanup() async {
    final cleanup = widget.onCleanup;
    if (cleanup == null) return;

    setState(() {
      _cleanupRunning = true;
    });

    final sw = Stopwatch()..start();

    try {
      final message = await cleanup();
      sw.stop();
      if (!mounted) return;
      setState(() {
        _localResult = TestResult(result: message, ms: sw.elapsedMilliseconds);
      });
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      setState(() {
        _localResult = TestResult(
          result: 'CLEANUP ERROR: $e',
          ms: sw.elapsedMilliseconds,
          isError: true,
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          _cleanupRunning = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    final r = _localResult;
    final hasParams = widget.def.params.isNotEmpty;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: hasParams ? () => setState(() => _expanded = !_expanded) : null,
                    child: MouseRegion(
                      cursor: hasParams ? SystemMouseCursors.click : SystemMouseCursors.basic,
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: cs.secondaryContainer,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(widget.def.icon, size: 18, color: cs.onSecondaryContainer),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(widget.def.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                                const SizedBox(height: 2),
                                Text(widget.def.description, style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                              ],
                            ),
                          ),
                          if (hasParams)
                            Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 22, color: Colors.grey[500]),
                          const SizedBox(width: 8),
                        ],
                      ),
                    ),
                  ),
                ),
                if (widget.trailing != null) ...[
                  const SizedBox(width: 8),
                  widget.trailing!,
                ],
                if (widget.onCleanup != null && _localResult != null) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 72,
                    height: 36,
                    child: FilledButton.tonal(
                      style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                      onPressed: (r != null && r.running) || _cleanupRunning || !widget.enabled ? null : _runCleanup,
                      child: _cleanupRunning
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.cleaning_services, size: 18),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                SizedBox(
                  width: 72,
                  height: 36,
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                    onPressed: (r != null && r.running) || !widget.enabled ? null : _runTest,
                    child: r != null && r.running
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Run'),
                  ),
                ),
              ],
            ),
          ),
          if (hasParams && _expanded)
            Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, (r != null && r.result != null) ? 8 : 14),
              child: Column(
                children: _controllers.entries.map((e) {
                  final isPath = _isPathParam(e.key);
                  final isLast = e.key == _controllers.keys.last;
                  return Padding(
                    padding: EdgeInsets.only(bottom: isLast ? 0 : 8),
                    child: AppTextField(
                      controller: e.value,
                      label: e.key,
                      onClear: () => setState(() {}),
                      suffixIcon: isPath && widget.pathLister != null
                          ? IconButton(
                              icon: const Icon(Icons.folder_open, size: 18),
                              onPressed: () => _browsePath(e.value),
                              visualDensity: VisualDensity.compact,
                            )
                          : null,
                    ),
                  );
                }).toList(),
              ),
            ),
          if (r != null && r.result != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: r.isError ? Colors.red.withValues(alpha: 0.05) : cs.surface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: r.isError ? Colors.red.withValues(alpha: 0.15) : Colors.green.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                r.isError ? Icons.error_outline : Icons.check_circle_outline,
                                size: 12,
                                color: r.isError ? Colors.red : Colors.green,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '${r.ms} ms',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: r.isError ? Colors.red : Colors.green[700],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: r.result!.split(',').map((s) {
                        final label = s.trim();
                        if (label.isEmpty) return const SizedBox.shrink();
                        return Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: r.isError ? Colors.red.withValues(alpha: 0.1) : cs.onSurface.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            label,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              color: r.isError ? Colors.red[700] : cs.onSurface,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
