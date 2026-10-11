// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Generates lib/src/ffi/libsmb2.g.dart: @Native bindings resolved against
// the code asset package:dart_smb2/libsmb2, which hook/build.dart bundles.
//
//   (cd ../libsmb2-scripts && ./build sources)   # patched headers of the pin
//   dart run tool/ffigen.dart
//
// The headers are libsmb2-scripts' PATCHED tree (patch_utimes.py adds
// smb2_utimes to libsmb2.h), and the functions bound are exactly those in
// its verify/symbols.txt, the list every release binary is checked to
// export. tool/bindings_drift.dart checks the generated file against that
// list and against a release's manifest.json.

import 'dart:io';

import 'package:ffigen/ffigen.dart';

/// Calls that never touch the network, bound as leaf calls.
const _leaf = {
  'smb2_init_context',
  'smb2_set_user',
  'smb2_set_password',
  'smb2_set_domain',
  'smb2_set_seal',
  'smb2_set_sign',
  'smb2_set_version',
  'smb2_set_timeout',
  'smb2_get_max_read_size',
  'smb2_get_max_write_size',
  'smb2_get_error',
  'smb2_get_nterror',
  'nterror_to_errno',
  'smb2_closedir',
  'smb2_free_data',
};

/// The builtin headers (stddef.h, ...) of the clang on PATH, for a
/// libclang that does not find its own resource directory.
List<String> _clangResourceIncludes() {
  try {
    final result = Process.runSync('clang', ['-print-resource-dir']);
    final dir = (result.stdout as String).trim();
    if (result.exitCode == 0 && dir.isNotEmpty) {
      return ['-isystem', '$dir/include'];
    }
  } on ProcessException {
    // No clang on PATH: rely on libclang's defaults.
  }
  return const [];
}

const _structs = {
  'smb2_context',
  'smb2_stat_64',
  'smb2_statvfs',
  'smb2dirent',
  'smb2dir',
  'smb2fh',
  'smb2_share_enum_reply',
  'smb2_share_info_1',
};

Future<void> main() async {
  final root = Platform.script.resolve('../');
  final scripts = root.resolve('../libsmb2-scripts/');
  final include = scripts.resolve('sources/libsmb2-src/include/');
  final smb2 = include.resolve('smb2/');
  if (!File.fromUri(smb2.resolve('libsmb2.h')).existsSync()) {
    stderr.writeln(
      'No patched headers at ${smb2.toFilePath()}: '
      'run `./build sources` in ../libsmb2-scripts first.',
    );
    exit(1);
  }
  final functions = File.fromUri(scripts.resolve('verify/symbols.txt'))
      .readAsLinesSync()
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toSet();

  const headers = {
    'libsmb2.h',
    'smb2.h',
    'libsmb2-share-enum.h',
    // smb2_free_data, which releases the share enumeration reply.
    'libsmb2-raw.h',
  };

  await FfiGenerator(
    input: Input(
      entryPoints: [for (final h in headers) smb2.resolve(h)],
      include: (header) => headers.any((h) => header.path.endsWith('/smb2/$h')),
      // The headers use fixed-width types and smb2.h declarations without
      // including them themselves.
      compilerOptions: [
        ..._clangResourceIncludes(),
        '-I${include.toFilePath()}',
        '-include',
        'stdint.h',
        '-include',
        'stddef.h',
        '-include',
        'sys/types.h',
        '-include',
        smb2.resolve('smb2.h').toFilePath(),
        '-include',
        smb2.resolve('libsmb2.h').toFilePath(),
        '-D_GNU_SOURCE=1',
      ],
      appendCompilerOptions: true,
    ),
    output: Output(
      dart: DartOutput(path: root.resolve('lib/src/ffi/libsmb2.g.dart')),
      style: const NativeExternalBindings(assetId: 'package:dart_smb2/libsmb2'),
      commentType: const CommentType(CommentStyle.any, CommentLength.brief),
      preamble: '''
// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can
// be found in the LICENSE file.
//
// GENERATED FILE — do not edit by hand. Regenerate with
// `dart run tool/ffigen.dart` after a libsmb2 bump.
// ignore_for_file: type=lint
''',
    ),
    visitors: [
      Visitor(
        func: (node) {
          if (functions.contains(node.originalName)) {
            node.isIncluded = true;
            node.isLeaf = _leaf.contains(node.originalName);
          }
        },
        struct: (node) {
          if (_structs.contains(node.originalName)) node.isIncluded = true;
          // libsmb2.h declares both `struct smb2_statvfs` and the function
          // smb2_statvfs(); renaming the struct keeps the function's name.
          if (node.originalName == 'smb2_statvfs') {
            node.name = 'Smb2StatVfsNative';
          }
        },
        // The anonymous union in smb2_share_enum_reply.
        union: (node) {
          if (node.name.startsWith('Unnamed')) node.name = 'Smb2ShareInfoUnion';
        },
        enumClass: (node) {
          if (node.originalName == 'smb2_negotiate_version' ||
              node.originalName == 'smb2_share_info_level') {
            node.isIncluded = true;
            node.silenceWarning = true;
          }
        },
        macroConstant: (node) {
          if (node.originalName.startsWith('SMB2_TYPE_') ||
              node.originalName.startsWith('SMB2_SHARE_TYPE_')) {
            node.isIncluded = true;
          }
        },
      ),
    ],
  ).generate();
}
