// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The POSIX open flags of each platform's libc.
part of '../smb2_client.dart';

/// POSIX open flags as smb2_open() reads them: libsmb2 tests them against
/// the `<fcntl.h>` of the platform the binary was built for, so the values
/// are per platform. O_RDONLY / O_WRONLY / O_RDWR are 0 / 1 / 2 on all.
final class _OpenFlags {
  final int rdonly = 0;
  final int wronly = 1;
  final int creat;
  final int trunc;

  /// O_DIRECTORY, which makes smb2_open() ask for a directory.
  final int directory;

  const _OpenFlags({
    required this.creat,
    required this.trunc,
    required this.directory,
  });

  /// glibc and bionic on x86 and x86_64.
  static const _linux = _OpenFlags(
    creat: 0x40,
    trunc: 0x200,
    directory: 0x10000,
  );

  /// glibc and bionic on ARM, whose O_DIRECTORY differs.
  static const _linuxArm = _OpenFlags(
    creat: 0x40,
    trunc: 0x200,
    directory: 0x4000,
  );

  /// Apple's libc.
  static const _darwin = _OpenFlags(
    creat: 0x200,
    trunc: 0x400,
    directory: 0x100000,
  );

  /// The Windows UCRT, with the O_DIRECTORY libsmb2-scripts' config.h
  /// defines for it.
  static const _windows = _OpenFlags(
    creat: 0x100,
    trunc: 0x200,
    directory: 0x200000,
  );

  static _OpenFlags _resolve() {
    if (Platform.isLinux || Platform.isAndroid) {
      return switch (Abi.current()) {
        Abi.linuxArm ||
        Abi.linuxArm64 ||
        Abi.androidArm ||
        Abi.androidArm64 => _linuxArm,
        _ => _linux,
      };
    }
    if (Platform.isMacOS || Platform.isIOS) return _darwin;
    if (Platform.isWindows) return _windows;
    throw UnsupportedError(
      'dart_smb2: unsupported platform ${Platform.operatingSystem}',
    );
  }
}

final _OpenFlags _flags = _OpenFlags._resolve();
