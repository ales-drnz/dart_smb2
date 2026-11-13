// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The release the package holds the loaded libsmb2 to. Needs no server.
library;

import 'dart:io';

import 'package:dart_smb2/src/libsmb2_release.dart';
import 'package:test/test.dart';

void main() {
  // Whatever release tool/update_libsmb2.sh pinned: nothing here names it.
  const pin = libsmb2Release;
  final number = int.parse(pin.substring(1));
  final other = 'r${number + 1}';
  final older = 'r${number - 1}';

  test('the pin is a release name, as the hook pins it', () {
    expect(pin, matches(RegExp(r'^r[1-9][0-9]*$')));
    expect(
      File('hook/build.dart').readAsStringSync(),
      contains("const _release = 'libsmb2-$libsmb2Release';"),
    );
  });

  test('the README names the pinned release, and no other', () {
    final named = RegExp(r'libsmb2-(r[0-9]+)')
        .allMatches(File('README.md').readAsStringSync())
        .map((m) => m.group(1))
        .toSet();
    expect(named, {pin});
  });

  test('a libsmb2 of the pinned release passes', () {
    expect(libsmb2Mismatch(pin), isNull);
  });

  test('a libsmb2 of another release fails, naming both', () {
    expect(
      libsmb2Mismatch(other),
      'libsmb2 reports "$other", and this dart_smb2 runs on libsmb2-$pin '
      'only: bundle the libsmb2 of the libsmb2-$pin release, or a build of '
      'libsmb2-scripts at libsmb2-$pin',
    );
    expect(libsmb2Mismatch(older), startsWith('libsmb2 reports "$older"'));
    expect(libsmb2Mismatch(''), startsWith('libsmb2 reports ""'));
    expect(libsmb2Mismatch(pin.toUpperCase()), isNotNull);
    expect(libsmb2Mismatch(' $pin'), isNotNull);
  });

  test('a libsmb2 without smb2_scripts_release fails', () {
    expect(
      libsmb2Mismatch(null),
      'libsmb2 reports "no release", and this dart_smb2 runs on '
      'libsmb2-$pin only: bundle the libsmb2 of the libsmb2-$pin release, '
      'or a build of libsmb2-scripts at libsmb2-$pin',
    );
  });
}
