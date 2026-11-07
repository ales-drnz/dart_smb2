// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Matchers and data shared by the unit and the integration suites.
library;

import 'dart:typed_data';

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

/// Throws an [Smb2Exception] of [type].
Matcher throwsType(Smb2ErrorType type) =>
    throwsA(isA<Smb2Exception>().having((e) => e.type, 'type', type));

/// [length] bytes that differ at every offset of a 64 KiB period, so a
/// chunk read at the wrong offset never matches by chance; [seed] shifts
/// them.
Uint8List pattern(int length, [int seed = 0]) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = (i * 31 + seed + (i >> 16)) & 0xff;
  }
  return out;
}

/// Whether [a] and [b] hold the same bytes; `expect(a, b)` on megabytes
/// spends seconds in the matcher.
bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
