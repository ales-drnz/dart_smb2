String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (bytes < 1024.0 * 1024.0 * 1024.0 * 1024.0) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  return '${(bytes / (1024.0 * 1024.0 * 1024.0 * 1024.0)).toStringAsFixed(1)} TB';
}