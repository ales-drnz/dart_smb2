// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// Minimal Flutter shell whose sole purpose is to host the integration_test
// driver on every platform: it bundles libsmb2 through dart_smb2's build
// hook, as an app does. The user-facing demo is example/example.dart.

// Flutter 3.50 moves Material to package:material_ui and deprecates this
// library; the shell stays on it while the package supports Flutter 3.47.
// ignore: deprecated_member_use
import 'package:flutter/material.dart';

void main() {
  runApp(const _TestAppShell());
}

class _TestAppShell extends StatelessWidget {
  const _TestAppShell();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'dart_smb2 test harness',
      debugShowCheckedModeBanner: false,
      home: Scaffold(body: Center(child: Text('dart_smb2 test harness'))),
    );
  }
}
