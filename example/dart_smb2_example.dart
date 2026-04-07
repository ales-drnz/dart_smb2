import 'package:dart_smb2/dart_smb2.dart';

/// Example: connect to an SMB share and list files.
///
/// Run with:
///   dart run example/dart_smb2_example.dart
void main() {
  final client = Smb2Client.open('path/to/libsmb2_wrapper.dylib');

  try {
    // Connect to a share
    client.connect(
      host: '192.168.1.100',
      share: 'Music',
      user: 'guest',
      password: '',
    );
    print('Connected!');

    // List root directory (use '' for root, not '/')
    final entries = client.listDirectory('');
    for (final entry in entries) {
      final icon = entry.isDirectory ? '[DIR] ' : '[FILE]';
      print('$icon ${entry.name}  (${entry.size} bytes)');
    }

    // Read first 256 KB of a file (e.g. audio metadata header)
    final header = client.readFileRange(
      'Artist/Album/01. Track.m4a',
      length: 256 * 1024,
    );
    print('Read ${header.length} bytes');

    // Read an entire file (e.g. a cover image)
    final image = client.readFile('Artist/Album/cover.jpg');
    print('Image: ${image.length} bytes');

    // Get file info without opening it
    final info = client.stat('Artist/Album/01. Track.m4a');
    print('Size: ${info.size}, Modified: ${info.modified}');
  } finally {
    client.disconnect();
  }
}
