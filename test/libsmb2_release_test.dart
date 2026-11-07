// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The release the package holds the loaded libsmb2 to. Needs no server.
library;

import 'dart:io';

import 'package:dart_smb2/src/libsmb2_release.dart';
import 'package:test/test.dart';

void main() {
  test('the pin is r11, as the hook pins it', () {
    expect(libsmb2Release, 'r11');
    expect(
      File('hook/build.dart').readAsStringSync(),
      contains("const _release = 'libsmb2-$libsmb2Release';"),
    );
  });

  test('a libsmb2 of the pinned release passes', () {
    expect(libsmb2Mismatch('r11'), isNull);
  });

  test('a libsmb2 of another release fails, naming both', () {
    expect(
      libsmb2Mismatch('r12'),
      'libsmb2 reports "r12", and this dart_smb2 runs on libsmb2-r11 only: '
      'bundle the libsmb2 of the libsmb2-r11 release, or a build of '
      'libsmb2-scripts at libsmb2-r11',
    );
    expect(libsmb2Mismatch('r10'), startsWith('libsmb2 reports "r10"'));
    expect(libsmb2Mismatch(''), startsWith('libsmb2 reports ""'));
    expect(libsmb2Mismatch('R11'), isNotNull);
    expect(libsmb2Mismatch(' r11'), isNotNull);
  });

  test('a libsmb2 without smb2_scripts_release fails', () {
    expect(
      libsmb2Mismatch(null),
      'libsmb2 reports "no release", and this dart_smb2 runs on libsmb2-r11 '
      'only: bundle the libsmb2 of the libsmb2-r11 release, or a build of '
      'libsmb2-scripts at libsmb2-r11',
    );
  });
}
