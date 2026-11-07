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
// a checksum, and must be builds of libsmb2-scripts at the release pinned
// below (libsmb2Release in lib/src/libsmb2_release.dart, which
// tool/bindings_drift.dart holds to _release): with any other, or upstream
// libsmb2, connecting fails with an Smb2Exception of type notSupported.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

const _release = 'libsmb2-r11';

/// The Android API level the release's libraries are built for.
const _androidMinApi = 24;
const _baseUrl =
    'https://github.com/ales-drnz/dart_smb2/releases/download/$_release';

/// SHA-256 of every release asset, from the release's manifest.json
/// (tool/update_libsmb2.sh writes this table). An empty entry is a release
/// not published yet: the hook then needs hooks.user_defines.dart_smb2.libsmb2.
const _sha256 = <String, String>{
  'libsmb2_android-arm64-v8a.so':
      '87c9c87b86d8284104dac2549c6448cabb98934b1af5413f48b3f33e018844ec',
  'libsmb2_android-armeabi-v7a.so':
      '013be97c7dff8c217da5342d0260b2e8357188c6b780c92d0eceb746593ce6e9',
  'libsmb2_android-x86_64.so':
      '63d92f00576b1b15232730f67d91082a25fdd4f5da2c29d7b8d41f7665d8f795',
  'libsmb2_ios.xcframework.zip':
      'd25f815936687a47c13fdb01164df0312edec1b82ab3c69329374678ef144c6c',
  'libsmb2_linux-aarch64.so':
      'd2407f3bc4bbe5db045231a8046059f31ff4b1bffc4cbd990d7855a3ca7d98be',
  'libsmb2_linux-x86_64.so':
      '0ecafeb72f8b62e54e295442ae18d1c30ed25c7afc779c22b6747fcee7dedbb0',
  'libsmb2_macos.xcframework.zip':
      'ea2439a4ccec1285673bad8d3f0f72b93f4f55f68071d6292c9b79066012d8ef',
  'libsmb2_windows-arm64.dll':
      '57c9d9a238053fb30d505fbb37ab0e4d52142d282880a3fe114c409b94ab1a0a',
  'libsmb2_windows-x86_64.dll':
      '8a626d762f4b132d134618a1fcc0ca1951dd50382c30068c9d50256f0505088f',
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
