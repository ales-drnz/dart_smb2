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
// a checksum.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _release = 'libsmb2-r9';
const _baseUrl =
    'https://github.com/ales-drnz/dart_smb2/releases/download/$_release';

/// SHA-256 of every release asset, from the release's manifest.json
/// (tool/update_libsmb2.sh writes this table).
const _sha256 = <String, String>{
  'libsmb2_android-arm64-v8a.so':
      'a372124dbb0e7eaf22e6f2c070f143d09d22d67590081cf3ce789dfa9aa950bf',
  'libsmb2_android-armeabi-v7a.so':
      '694bdc99975e4b5f7a7b9508e5ae0b47d7be8a4803fd3966be6ef3ff47d7b0d2',
  'libsmb2_android-x86_64.so':
      '4ba62d04dfd9901b7c9796a375e89041d864a70297cdc7443e6f2500765b28bb',
  'libsmb2_ios.xcframework.zip':
      '05fc23db3ae852335b0cb448048b9ef9651ef3c8b852dfac7384bdd74b3a53a7',
  'libsmb2_linux-aarch64.so':
      'a384ea1c297c05e4b2bd74f8c8f8359dbe62b737dd22279b1485ff48bc1e95f3',
  'libsmb2_linux-x86_64.so':
      '4a0a43f89eb00aeb43e7a9b034e238852578b1cfa96083d69af9e4d714a96a81',
  'libsmb2_macos.xcframework.zip':
      'd4f01d340c58bcbe938055cbed3d48ce350ba0f5e1deca24867945e5b9002c94',
  'libsmb2_windows-arm64.dll':
      '4ea893bc6ba44f0570b0c48933cfac59259b68b89293ed7b6c7c9c97b026b736',
  'libsmb2_windows-x86_64.dll':
      'deefee925d3b9b998127288125ce63b8e45bfc1799ccbb6907f9c10f308d951d',
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
      output.dependencies.add(local);
      await File.fromUri(local).copy(out.path);
    } else {
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

/// The release [asset] in the user-defined directory [dir].
Future<File> _localAsset(Uri dir, String asset) async {
  // Resolve inside the directory even when the path has no trailing slash.
  final base = dir.path.endsWith('/') ? dir : dir.replace(path: '${dir.path}/');
  final file = File.fromUri(base.resolve(asset));
  if (!file.existsSync()) {
    throw StateError(
      'dart_smb2: the libsmb2 user define points at ${dir.toFilePath()}, '
      'which has no $asset',
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
    await _download('$_baseUrl/$asset', partial);
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

Future<void> _download(String url, File target) async {
  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('dart_smb2: HTTP ${response.statusCode} for $url');
    }
    await response.pipe(target.openWrite());
  } finally {
    client.close();
  }
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
