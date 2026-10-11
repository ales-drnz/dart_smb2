// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Fails when the bindings, the build hook and the pinned libsmb2 release
/// have drifted apart.
///
/// ```sh
/// dart run tool/bindings_drift.dart [path/to/libsmb2-scripts]
/// ```
///
/// Checks, against `tool/libsmb2_manifest.json` (the manifest of the
/// release the hook pins, copied by `tool/update_libsmb2.sh`):
///
/// - the functions `lib/src/ffi/libsmb2.g.dart` binds are exactly the
///   ones every binary of the release is verified to export;
/// - `hook/build.dart` pins that release and its SHA-256s.
///
/// With a libsmb2-scripts checkout (default: the sibling one, when
/// present), also that its `verify/symbols.txt` lists the same functions.
library;

import 'dart:convert';
import 'dart:io';

/// The problems found, empty when nothing drifted. [root] is the package
/// root; [scripts] a libsmb2-scripts checkout, or null.
List<String> bindingsDrift(Directory root, {Directory? scripts}) {
  String read(String path) => File('${root.path}/$path').readAsStringSync();
  final problems = <String>[];
  final manifest =
      jsonDecode(read('tool/libsmb2_manifest.json')) as Map<String, Object?>;
  final released = {...(manifest['symbols']! as List<Object?>).cast<String>()};

  final bindings = read('lib/src/ffi/libsmb2.g.dart');
  final bound = {
    for (final m in RegExp(
      r"@ffi\.Native<[^@]*?>\((?:[^)]*symbol: '(\w+)')?[^)]*\)\s*external [^(]+? (\w+)\(",
      dotAll: true,
    ).allMatches(bindings))
      m.group(1) ?? m.group(2)!,
  };
  for (final s in bound.difference(released)) {
    problems.add('$s is bound but not verified in the release');
  }
  for (final s in released.difference(bound)) {
    problems.add('$s is verified in the release but not bound');
  }

  final hook = read('hook/build.dart');
  final release = 'libsmb2-${manifest['release']}';
  if (!hook.contains("const _release = '$release';")) {
    problems.add('hook/build.dart does not pin $release');
  }
  final assets = (manifest['assets']! as Map<String, Object?>)
      .cast<String, String>();
  for (final MapEntry(key: name, value: sha) in assets.entries) {
    if (!RegExp("'${RegExp.escape(name)}':\\s*'$sha'").hasMatch(hook)) {
      problems.add('hook/build.dart: $name is not pinned to $sha');
    }
  }

  if (scripts != null) {
    final listed = File('${scripts.path}/verify/symbols.txt')
        .readAsLinesSync()
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toSet();
    if (listed.length != released.length || !listed.containsAll(released)) {
      problems.add(
        '${scripts.path}/verify/symbols.txt differs from the release: '
        'regenerate after `tool/update_libsmb2.sh`',
      );
    }
  }
  return problems;
}

void main(List<String> args) {
  final root = Directory.fromUri(Platform.script.resolve('..'));
  final scriptsPath = args.isNotEmpty
      ? args.first
      : '${root.path}/../libsmb2-scripts';
  final scripts = Directory(scriptsPath);
  final problems = bindingsDrift(
    root,
    scripts: scripts.existsSync() ? scripts : null,
  );
  if (problems.isEmpty) {
    stdout.writeln('No drift between the bindings, the hook and the release.');
    return;
  }
  problems.forEach(stderr.writeln);
  exitCode = 1;
}
