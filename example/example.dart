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
  } on Smb2Exception catch (e) {
    print('${e.type.name}: ${e.message}');
  } finally {
    await pool.disconnect();
  }
}
