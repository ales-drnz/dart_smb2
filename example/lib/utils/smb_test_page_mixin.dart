import 'package:dart_smb2/dart_smb2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/connection_provider.dart';

mixin SmbTestPageMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  Map<String, Map<String, String>> get paramsStore;

  String param(String testKey, String paramKey, String defaultValue) {
    return paramsStore[testKey]?[paramKey] ?? defaultValue;
  }

  int paramInt(String testKey, String paramKey, int defaultValue) {
    return int.tryParse(param(testKey, paramKey, '$defaultValue')) ?? defaultValue;
  }

  Smb2Pool? get poolOrNull => ref.read(connectionProvider).pool;

  Smb2Pool get pool => poolOrNull!;

  String get basePath => ref.read(connectionProvider).config?.basePath ?? '';

  String resolvePath(String path, {bool emptyMeansBase = true}) {
    final normalized = path.replaceAll('\\', '/').trim();
    final trimmed = normalized.replaceAll(RegExp(r'^/+|/+$'), '');
    final base = basePath.replaceAll(RegExp(r'^/+|/+$'), '');

    if (base.isEmpty) return trimmed;
    if (trimmed.isEmpty) return emptyMeansBase ? base : '';
    if (trimmed == base || trimmed.startsWith('$base/')) return trimmed;
    return '$base/$trimmed';
  }

  String stripBasePath(String path) {
    final normalized = path.replaceAll('\\', '/').trim().replaceAll(RegExp(r'^/+'), '');
    final base = basePath.replaceAll(RegExp(r'^/+|/+$'), '');
    if (base.isEmpty) return normalized;
    if (normalized == base) return '';
    if (normalized.startsWith('$base/')) return normalized.substring(base.length + 1);
    return normalized;
  }

  Future<String> runConnected(Future<String> Function(Smb2Pool pool) run) async {
    final currentPool = poolOrNull;
    if (currentPool == null) return 'NOT CONNECTED';
    return run(currentPool);
  }

  Future<List<String>> listEntries(String parentPath) async {
    final currentPool = poolOrNull;
    if (currentPool == null) return [];
    final entries = await currentPool.listDirectory(resolvePath(parentPath));
    return entries.map((e) => e.name).toList();
  }

  Future<String?> firstEntryName() async {
    final entries = await pool.listDirectory(resolvePath(''));
    if (entries.isEmpty) return null;
    return stripBasePath(entries.first.name);
  }

  Future<String?> firstFileName({int? maxSizeBytes}) async {
    final entries = await pool.listDirectory(resolvePath(''));
    final file = entries.where((e) => e.isFile && (maxSizeBytes == null || e.size < maxSizeBytes)).firstOrNull;
    return file == null ? null : stripBasePath(file.name);
  }

  Future<String?> firstLinkName() async {
    final entries = await pool.listDirectory(resolvePath(''));
    final link = entries.where((e) => e.stat.type == Smb2FileType.link).firstOrNull;
    return link == null ? null : stripBasePath(link.name);
  }
}