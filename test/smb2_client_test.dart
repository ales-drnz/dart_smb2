// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_smb2/dart_smb2.dart';

/// Integration tests for Smb2Client.
///
/// These tests require a running SMB server. Set the environment variables:
///   SMB2_HOST, SMB2_SHARE, SMB2_USER, SMB2_PASS, SMB2_LIB_PATH
///
/// Run with:
///   SMB2_HOST=192.168.1.1 SMB2_SHARE=Files SMB2_USER=user SMB2_PASS=pass \
///   SMB2_LIB_PATH=scripts/output/macos/lib/libsmb2_wrapper.dylib \
///   dart test
void main() {
  final host = Platform.environment['SMB2_HOST'];
  final share = Platform.environment['SMB2_SHARE'];
  final user = Platform.environment['SMB2_USER'];
  final pass = Platform.environment['SMB2_PASS'];
  final libPath = Platform.environment['SMB2_LIB_PATH'];

  if (host == null || share == null || libPath == null) {
    print('Skipping integration tests — set SMB2_HOST, SMB2_SHARE, SMB2_LIB_PATH');
    return;
  }

  late Smb2Client client;

  setUp(() {
    client = Smb2Client.open(libPath);
    client.connect(
      host: host,
      share: share,
      user: user,
      password: pass,
    );
  });

  tearDown(() => client.disconnect());

  test('listDirectory returns entries with metadata', () {
    final entries = client.listDirectory('');
    expect(entries, isNotEmpty);
    for (final e in entries) {
      expect(e.name, isNotEmpty);
      expect(e.stat.type, isNotNull);
    }
  });

  test('stat returns file info', () {
    final entries = client.listDirectory('');
    final first = entries.first;
    final info = client.stat(first.name);
    expect(info.type, equals(first.stat.type));
    expect(info.size, equals(first.stat.size));
  });

  test('readFileRange reads partial file', () {
    final entries = client.listDirectory('');
    final file = entries.firstWhere((e) => e.isFile, orElse: () => throw 'No files');
    final bytes = client.readFileRange(file.name, length: 1024);
    expect(bytes.length, greaterThan(0));
    expect(bytes.length, lessThanOrEqualTo(1024));
  });

  test('fileSize returns correct size', () {
    final entries = client.listDirectory('');
    final file = entries.firstWhere((e) => e.isFile, orElse: () => throw 'No files');
    final size = client.fileSize(file.name);
    expect(size, equals(file.size));
  });

  test('throws on invalid path', () {
    expect(
      () => client.listDirectory('nonexistent_path_12345'),
      throwsA(isA<Smb2Exception>()),
    );
  });

  test('throws when not connected', () {
    final disconnected = Smb2Client.open(libPath);
    expect(
      () => disconnected.listDirectory(''),
      throwsA(isA<Smb2Exception>()),
    );
  });
}
