// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The build hook's checks that need no download: the asset each target
/// takes, and a libsmb2 of the app's own. test/hook_download_test.dart has
/// the download.
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

  group('target', () {
    // What the hook works from for a target, without running the rest of it.
    Future<({String asset, String fileName, String? appleSlice})> targetOf(
      OS os,
      Architecture arch, {
      IOSSdk sdk = IOSSdk.iPhoneOS,
    }) async {
      late ({String asset, String fileName, String? appleSlice}) target;
      await testCodeBuildHook(
        mainMethod: (args) => build(args, (input, _) async {
          target = hook.targetFor(input.config.code);
        }),
        targetOS: os,
        targetArchitecture: arch,
        targetIOSSdk: sdk,
        check: (_, _) {},
      );
      return target;
    }

    const elf = 'libdart_smb2.so';
    const dll = 'dart_smb2.dll';
    const apple = 'libdart_smb2';
    final targets = [
      (OS.android, Architecture.arm64, 'libsmb2_android-arm64-v8a.so', elf),
      (OS.android, Architecture.arm, 'libsmb2_android-armeabi-v7a.so', elf),
      (OS.android, Architecture.x64, 'libsmb2_android-x86_64.so', elf),
      (OS.linux, Architecture.arm64, 'libsmb2_linux-aarch64.so', elf),
      (OS.linux, Architecture.x64, 'libsmb2_linux-x86_64.so', elf),
      (OS.windows, Architecture.arm64, 'libsmb2_windows-arm64.dll', dll),
      (OS.windows, Architecture.x64, 'libsmb2_windows-x86_64.dll', dll),
      (OS.macOS, Architecture.arm64, 'libsmb2_macos.xcframework.zip', apple),
      (OS.macOS, Architecture.x64, 'libsmb2_macos.xcframework.zip', apple),
      (OS.iOS, Architecture.arm64, 'libsmb2_ios.xcframework.zip', apple),
    ];

    for (final (os, arch, asset, fileName) in targets) {
      test('$os $arch takes $asset as $fileName', () async {
        final target = await targetOf(os, arch);
        expect(target.asset, asset);
        expect(target.fileName, fileName);
        expect(target.appleSlice, switch (os) {
          OS.macOS => 'macos-arm64_x86_64',
          OS.iOS => 'ios-arm64',
          _ => isNull,
        });
      });
    }

    test('the hook pins a checksum for the asset of every target', () {
      final pinned = File('hook/build.dart').readAsStringSync();
      for (final asset in {for (final target in targets) target.$3}) {
        final entry = RegExp("'${RegExp.escape(asset)}':\\s*'[0-9a-f]{64}'");
        expect(entry.hasMatch(pinned), isTrue, reason: asset);
      }
    });

    for (final arch in [Architecture.arm64, Architecture.x64]) {
      test('the iOS simulator on $arch takes the simulator slice', () async {
        final target = await targetOf(
          OS.iOS,
          arch,
          sdk: IOSSdk.iPhoneSimulator,
        );
        expect(target.asset, 'libsmb2_ios.xcframework.zip');
        expect(target.appleSlice, 'ios-arm64_x86_64-simulator');
      });
    }

    for (final (os, arch) in [
      (OS.linux, Architecture.arm),
      (OS.linux, Architecture.ia32),
      (OS.linux, Architecture.riscv64),
      (OS.android, Architecture.ia32),
      (OS.windows, Architecture.ia32),
    ]) {
      test('$os $arch has no libsmb2', () {
        expect(
          targetOf(os, arch),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              allOf(contains('no libsmb2 for'), contains('$arch')),
            ),
          ),
        );
      });
    }
  });

  group('a libsmb2 of the app', () {
    // The targets the hook bundles by a plain copy; an Apple one needs
    // unzip and lipo on a real xcframework.
    final copied = [
      (OS.android, Architecture.arm64, 'libsmb2_android-arm64-v8a.so'),
      (OS.android, Architecture.arm, 'libsmb2_android-armeabi-v7a.so'),
      (OS.android, Architecture.x64, 'libsmb2_android-x86_64.so'),
      (OS.linux, Architecture.arm64, 'libsmb2_linux-aarch64.so'),
      (OS.linux, Architecture.x64, 'libsmb2_linux-x86_64.so'),
      (OS.windows, Architecture.arm64, 'libsmb2_windows-arm64.dll'),
      (OS.windows, Architecture.x64, 'libsmb2_windows-x86_64.dll'),
    ];

    // The bundled file's name and bytes, and what the hook depends on.
    Future<(String, List<int>, List<String>)> bundle(
      OS os,
      Architecture arch,
      String define,
    ) async {
      late (String, List<int>, List<String>) bundled;
      await testCodeBuildHook(
        mainMethod: hook.main,
        targetOS: os,
        targetArchitecture: arch,
        userDefines: definesFor(define),
        check: (_, output) {
          final asset = output.assets.code.single;
          expect(asset.id, 'package:dart_smb2/libsmb2');
          expect(asset.linkMode, isA<DynamicLoadingBundled>());
          final file = File.fromUri(asset.file!);
          bundled = (
            file.uri.pathSegments.last,
            file.readAsBytesSync(),
            [for (final d in output.dependencies) d.pathSegments.last],
          );
        },
      );
      return bundled;
    }

    setUp(() async {
      // Every asset holds its own index, so a mixed-up one shows.
      for (final (i, (_, _, asset)) in copied.indexed) {
        await File('${local.path}/$asset').writeAsBytes([i]);
      }
    });

    for (final (i, (os, arch, asset)) in copied.indexed) {
      test('a directory gives $os $arch its $asset', () async {
        final (name, bytes, dependencies) = await bundle(os, arch, local.path);
        expect(name, os == OS.windows ? 'dart_smb2.dll' : 'libdart_smb2.so');
        expect(bytes, [i]);
        expect(dependencies, [asset]);
      });
    }

    test('a directory is read with a trailing slash too', () async {
      final (_, bytes, _) = await bundle(
        OS.linux,
        Architecture.x64,
        '${local.path}/',
      );
      expect(bytes, [copied.indexWhere((t) => t.$3.contains('linux-x86_64'))]);
    });

    test('a single file is bundled for whichever target', () async {
      final file = File('${local.path}/mine.bin');
      await file.writeAsBytes([42]);
      for (final (os, arch) in [
        (OS.linux, Architecture.x64),
        (OS.windows, Architecture.arm64),
      ]) {
        final (name, bytes, dependencies) = await bundle(os, arch, file.path);
        expect(name, os == OS.windows ? 'dart_smb2.dll' : 'libdart_smb2.so');
        expect(bytes, [42]);
        expect(dependencies, ['mine.bin']);
      }
    });

    for (final (os, asset) in [
      (OS.linux, 'libsmb2_linux-aarch64.so'),
      (OS.macOS, 'libsmb2_macos.xcframework.zip'),
      (OS.iOS, 'libsmb2_ios.xcframework.zip'),
    ]) {
      test('a directory without the $os asset names it', () async {
        final empty = await Directory('${local.path}/empty').create();
        expect(
          bundle(os, Architecture.arm64, empty.path),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('hooks.user_defines.dart_smb2.libsmb2'),
                contains('which has no $asset'),
              ),
            ),
          ),
        );
      });
    }
  });
}
