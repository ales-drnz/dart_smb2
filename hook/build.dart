// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Build hook: fetches the libsmb2 binary for the target from the
// libsmb2-<release> GitHub release, checks its SHA-256 and bundles it as the
// code asset `package:dart_smb2/libsmb2`, which lib/src/ffi/libsmb2.g.dart
// binds with @Native. One script for every platform and for plain Dart as
// well as Flutter.
//
// Offline builds and custom binaries: point the app at a local copy with
//
//   hooks:
//     user_defines:
//       dart_smb2:
//         libsmb2: path/to/libsmb2
//
// in the app's pubspec. A directory holds files named like the release
// assets (libsmb2_android-arm64-v8a.so, libsmb2_ios.xcframework.zip, ...),
// such as libsmb2-scripts' release_builds/, and each target takes its own.
// A single file is bundled for every target, so it only suits a build for
// one target and architecture. Local files are bundled as they are, without
// a checksum, and must be builds of the pinned libsmb2 release or of one
// with the same ABI (smb2_stat_64's layout, the context-list lock): an
// older libsmb2 loads, but reads stat fields wrong.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _release = 'libsmb2-r9';

/// The Android API level the release's libraries are built for.
const _androidMinApi = 24;
const _baseUrl =
    'https://github.com/ales-drnz/dart_smb2/releases/download/$_release';

/// SHA-256 of every release asset, from the release's manifest.json
/// (tool/update_libsmb2.sh writes this table).
const _sha256 = <String, String>{
  'libsmb2_android-arm64-v8a.so':
      '01085c749c28e81f0a2a60d61b33a11f850cc5bfaf6198f5b1ba5c728b1459b4',
  'libsmb2_android-armeabi-v7a.so':
      '1785e230135e62d68fc77cc5cd87e4318b9b205ff6c44af4c39b778a46ca8d10',
  'libsmb2_android-x86_64.so':
      'af5ec56e2e81e25f5e4c8215363d10eda05dc225a6172863bbcb0c3c93b42c38',
  'libsmb2_ios.xcframework.zip':
      'f279afda68a41ef8a7832aa8d38e61bae89e06eb9b29d70c05c6e046d0a849d1',
  'libsmb2_linux-aarch64.so':
      '5bad10a128bc59c9c7bfc62e4a418c31320b2231594df0351f600335752e1115',
  'libsmb2_linux-x86_64.so':
      '803ad14f1157ca5cd315504526c8c35a30b9ce6b2cd9725c58cd658773576af7',
  'libsmb2_macos.xcframework.zip':
      '246ce757fc0329c8d98d5290af7413319b4c52f091ff9ca1baf6b2431af20210',
  'libsmb2_windows-arm64.dll':
      'cba2172e6f06682add4152a3ba350092f40ff410e3b11959d095eb308dd574d2',
  'libsmb2_windows-x86_64.dll':
      '554fc6cf569bbecbf5948db6d092bd87cba04562e03720582abf2cca06b41364',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final target = _Target.of(code);
    final out = File.fromUri(input.outputDirectory.resolve(target.fileName));

    final local = input.userDefines.path('libsmb2');
    if (local != null &&
        !FileSystemEntity.isDirectorySync(local.toFilePath())) {
      // A single file is the finished library, bundled for every target.
      if (!File.fromUri(local).existsSync()) {
        throw StateError(
          'dart_smb2: hooks.user_defines.dart_smb2.libsmb2 points at '
          '${local.toFilePath()}, which does not exist',
        );
      }
      output.dependencies.add(local);
      await File.fromUri(local).copy(out.path);
    } else {
      if (local == null) _checkAndroidApi(code);
      final asset = local == null
          ? await _fetch(target.asset, input.outputDirectoryShared)
          : await _localAsset(local, target.asset);
      if (local != null) output.dependencies.add(asset.uri);
      if (target.appleSlice == null) {
        await asset.copy(out.path);
      } else {
        // A pinned download never changes, so its unpacked copy is kept
        // beside it; a local zip may, so it is unpacked again each build.
        final unpacked = local == null
            ? Directory('${asset.parent.path}/unzipped')
            : Directory.fromUri(input.outputDirectory.resolve('unzipped'));
        if (local != null && unpacked.existsSync()) {
          await unpacked.delete(recursive: true);
        }
        await _extractAppleSlice(
          asset,
          unpacked,
          target,
          code.targetArchitecture,
          out,
        );
      }
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'libsmb2',
        linkMode: DynamicLoadingBundled(),
        file: out.uri,
      ),
    );
  });
}

/// Which release asset a target needs, and the file name it is bundled
/// under. The name is the package's own, never `libsmb2`, so it cannot
/// collide with another package's copy of libsmb2 on disk or in the loader
/// (bionic matches a dlopen by name against the libraries already loaded,
/// and the release binaries carry no SONAME). On Apple the file becomes
/// `libdart_smb2.framework/libdart_smb2`.
class _Target {
  const _Target(this.asset, this.fileName, {this.appleSlice});

  final String asset;
  final String fileName;

  /// The xcframework directory holding the slice, on Apple.
  final String? appleSlice;

  static _Target of(CodeConfig code) {
    final arch = code.targetArchitecture;
    Never unsupported() => throw UnsupportedError(
      'dart_smb2: no libsmb2 for ${code.targetOS} $arch in $_release',
    );
    return switch (code.targetOS) {
      OS.linux => _Target(
        'libsmb2_linux-${switch (arch) {
          Architecture.x64 => 'x86_64',
          Architecture.arm64 => 'aarch64',
          _ => unsupported(),
        }}.so',
        'libdart_smb2.so',
      ),
      OS.android => _Target(
        'libsmb2_android-${switch (arch) {
          Architecture.arm64 => 'arm64-v8a',
          Architecture.arm => 'armeabi-v7a',
          Architecture.x64 => 'x86_64',
          _ => unsupported(),
        }}.so',
        'libdart_smb2.so',
      ),
      OS.windows => _Target(
        'libsmb2_windows-${switch (arch) {
          Architecture.x64 => 'x86_64',
          Architecture.arm64 => 'arm64',
          _ => unsupported(),
        }}.dll',
        'dart_smb2.dll',
      ),
      OS.macOS => const _Target(
        'libsmb2_macos.xcframework.zip',
        'libdart_smb2',
        appleSlice: 'macos-arm64_x86_64',
      ),
      OS.iOS => _Target(
        'libsmb2_ios.xcframework.zip',
        'libdart_smb2',
        appleSlice: code.iOS.targetSdk == IOSSdk.iPhoneSimulator
            ? 'ios-arm64_x86_64-simulator'
            : 'ios-arm64',
      ),
      _ => unsupported(),
    };
  }
}

/// Fails the build of an Android app below the API level the release's
/// libraries are built for; a local build may target a lower one.
void _checkAndroidApi(CodeConfig code) {
  if (code.targetOS != OS.android) return;
  final api = code.android.targetNdkApi;
  if (api < _androidMinApi) {
    throw UnsupportedError(
      'dart_smb2: libsmb2 is built for Android API $_androidMinApi, the app '
      'targets $api: raise minSdk to $_androidMinApi, or build libsmb2 for '
      'API $api and point hooks.user_defines.dart_smb2.libsmb2 at it',
    );
  }
}

/// The release [asset] in the user-defined directory [dir].
Future<File> _localAsset(Uri dir, String asset) async {
  // Resolve inside the directory even when the path has no trailing slash.
  final base = dir.path.endsWith('/') ? dir : dir.replace(path: '${dir.path}/');
  final file = File.fromUri(base.resolve(asset));
  if (!file.existsSync()) {
    throw StateError(
      'dart_smb2: hooks.user_defines.dart_smb2.libsmb2 points at '
      '${dir.toFilePath()}, which has no $asset',
    );
  }
  return file;
}

/// The release [asset], downloaded once into [cacheDir] and reused by every
/// build that asks for the same checksum.
Future<File> _fetch(String asset, Uri cacheDir) async {
  final expected = _sha256[asset];
  if (expected == null || expected.isEmpty) {
    throw StateError('dart_smb2: no SHA-256 pinned for $asset');
  }
  final cached = File.fromUri(cacheDir.resolve('$expected/$asset'));
  if (await _matches(cached, expected)) return cached;

  await cached.parent.create(recursive: true);
  // One partial file per build: Flutter can run the hook for two
  // architectures at once, and both would download the same asset.
  final partial = File('${cached.path}.$pid.part');
  try {
    await _download('$_baseUrl/$asset', partial, asset);
    if (!await _matches(partial, expected)) {
      throw StateError('dart_smb2: SHA-256 mismatch for $asset from $_baseUrl');
    }
    return await partial.rename(cached.path);
  } finally {
    if (partial.existsSync()) await partial.delete();
  }
}

/// Copies the libsmb2 binary of the xcframework slice, unpacked from [zip]
/// into [dir], into [out], thinned to [arch] when the slice is universal:
/// Flutter runs the hook once per architecture and merges the results
/// itself.
Future<void> _extractAppleSlice(
  File zip,
  Directory dir,
  _Target target,
  Architecture arch,
  File out,
) async {
  final framework =
      '${dir.path}/libsmb2.xcframework/${target.appleSlice}/libsmb2.framework';
  if (!dir.existsSync()) {
    // Unpack beside it and rename into place, so an interrupted unzip
    // never leaves a half directory that a later build would trust.
    await dir.parent.create(recursive: true);
    final staging = await dir.parent.createTemp('unzip-');
    await _run('unzip', ['-q', zip.path, '-d', staging.path]);
    try {
      await staging.rename(dir.path);
    } on FileSystemException {
      // Another build unpacked the same zip first; its copy is identical.
      await staging.delete(recursive: true);
    }
  }
  // A macOS framework keeps its binary under Versions/; follow the link.
  final binary = await File('$framework/libsmb2').resolveSymbolicLinks();
  final lipoArch = switch (arch) {
    Architecture.arm64 => 'arm64',
    Architecture.x64 => 'x86_64',
    _ => throw UnsupportedError('dart_smb2: no Apple slice for $arch'),
  };
  final archs = (await _run('lipo', ['-archs', binary])).trim().split(' ');
  if (archs.length == 1) {
    if (archs.single != lipoArch) {
      throw StateError(
        'dart_smb2: $binary is ${archs.single}, the build wants $lipoArch',
      );
    }
    await File(binary).copy(out.path);
  } else {
    await _run('lipo', [binary, '-thin', lipoArch, '-output', out.path]);
  }
}

Future<bool> _matches(File file, String sha256Hex) async {
  if (!file.existsSync()) return false;
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString() == sha256Hex;
}

/// Downloads [url] to [target], in up to three attempts, 2 and 4 seconds
/// apart. Each attempt gets 60 seconds to connect and get an answer (a
/// proxy tunnel included) and 60 seconds without data in the transfer, so a
/// network that answers nothing fails the build instead of hanging it. A
/// client error other than 408 and 429 is not retried.
Future<void> _download(String url, File target, String asset) async {
  const step = Duration(seconds: 60);
  Object? lastError;
  for (var attempt = 1; attempt <= 3; attempt++) {
    if (attempt > 1) {
      await Future<void>.delayed(Duration(seconds: 1 << (attempt - 1)));
    }
    final client = HttpClient()
      ..findProxy = HttpClient.findProxyFromEnvironment
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final response = await client
          .getUrl(Uri.parse(url))
          .then((request) => request.close())
          .timeout(step);
      final status = response.statusCode;
      if (status != HttpStatus.ok) {
        lastError = HttpException('HTTP $status for $url');
        final retry = status >= 500 || status == 408 || status == 429;
        if (!retry) break;
        continue;
      }
      await response.timeout(step).pipe(target.openWrite());
      return;
    } on Exception catch (e) {
      lastError = e;
    } finally {
      client.close(force: true);
    }
  }
  throw StateError(
    'dart_smb2: cannot download $asset from $url ($lastError). To build '
    'offline, point hooks.user_defines.dart_smb2.libsmb2 at a local copy '
    '(see the package README).',
  );
}

Future<String> _run(String executable, List<String> arguments) async {
  final result = await Process.run(executable, arguments);
  if (result.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${result.stderr}',
      result.exitCode,
    );
  }
  return result.stdout as String;
}
