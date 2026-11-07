// Minimal dart_smb2 example
import 'package:dart_smb2/dart_smb2.dart';

Future<void> main() async {
  // Connect a pool of worker isolates to a share.
  final pool = await Smb2Pool.connect(
    host: '192.168.1.10',
    share: 'Music',
    user: 'alice',
    password: 'secret',
  );

  try {
    // List the share's root.
    for (final entry in await pool.listDirectory('')) {
      print(entry.isDirectory ? '${entry.name}/' : entry.name);
    }

    // Download a file to disk, atomically.
    await pool.downloadToFile('Album/01 - Intro.flac', '/tmp/intro.flac');

    // Watch a directory while files go in.
    final changes = pool
        .watch('Backup', recursive: true)
        .listen((e) => print('${e.action.name} ${e.path}'));

    // Create the missing directories, upload a file and copy it.
    await pool.mkdir('Backup/2026/11', recursive: true);
    await pool.uploadFile(
      '/tmp/intro.flac',
      'Backup/2026/11/intro.flac',
      onProgress: (sent, total) => print('$sent / $total'),
    );
    await pool.copy(
      'Backup/2026/11/intro.flac',
      'Backup/latest.flac',
      overwrite: true,
    );

    await Future<void>.delayed(const Duration(seconds: 1));
    await changes.cancel();
  } on Smb2Exception catch (e) {
    print('${e.type.name}: ${e.message}');
  } finally {
    await pool.disconnect();
  }
}
