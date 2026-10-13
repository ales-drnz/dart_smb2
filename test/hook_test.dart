// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The build hook's checks that need no download.
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as hook;

void main() {
  late Directory local;

  setUp(() async {
    local = await Directory.systemTemp.createTemp('dart_smb2_hook_');
    await File('${local.path}/libsmb2_android-arm64-v8a.so').writeAsBytes([0]);
  });
  tearDown(() => local.delete(recursive: true));

  PackageUserDefines definesFor(String path) => PackageUserDefines(
    workspacePubspec: PackageUserDefinesSource(
      defines: {'libsmb2': path},
      basePath: Directory.current.uri,
    ),
  );

  test('an Android app below API 24 fails before any download', () {
    expect(
      testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: OS.android,
        targetArchitecture: Architecture.arm64,
        targetAndroidNdkApi: 21,
        check: (_, _) {},
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('raise minSdk to 24'),
        ),
      ),
    );
  });

  test('a local build may target a lower Android API', () async {
    await testCodeBuildHook(
      mainMethod: hook.main,
      targetOS: OS.android,
      targetArchitecture: Architecture.arm64,
      targetAndroidNdkApi: 21,
      userDefines: definesFor(local.path),
      check: (_, output) {
        expect(output.assets.code.single.id, 'package:dart_smb2/libsmb2');
      },
    );
  });

  test('a user define that points nowhere names the define', () {
    expect(
      testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: OS.android,
        targetArchitecture: Architecture.arm64,
        targetAndroidNdkApi: 24,
        userDefines: definesFor('${local.path}/missing.so'),
        check: (_, _) {},
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('hooks.user_defines.dart_smb2.libsmb2'),
        ),
      ),
    );
  });
}
