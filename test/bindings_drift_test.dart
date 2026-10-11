// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:io';

import 'package:test/test.dart';

import '../tool/bindings_drift.dart';

void main() {
  test('the bindings and the hook match the pinned release', () {
    expect(bindingsDrift(Directory.current), isEmpty);
  });
}
