// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The libsmb2-scripts release the build hook bundles (`libsmb2-<release>`
/// in hook/build.dart), as libsmb2's `smb2_scripts_release()` returns it.
/// tool/bindings_drift.dart checks that the hook pins the same release, and
/// tool/update_libsmb2.sh rewrites both.
const String libsmb2Release = 'r11';

/// Why the package cannot run on a libsmb2 that reports [release] (`null`
/// when it has no `smb2_scripts_release()`, as upstream libsmb2), or `null`
/// when it is a build of [libsmb2Release].
///
/// Each version of the package drives the libsmb2 of its pin and no other:
/// the patched-in calls, the struct layout and the errors it maps are those
/// of that release. A libsmb2 the app bundles itself through the hook's
/// `user_defines` is held to the same release.
String? libsmb2Mismatch(String? release) {
  if (release == libsmb2Release) return null;
  return 'libsmb2 reports "${release ?? 'no release'}", and this '
      'dart_smb2 runs on libsmb2-$libsmb2Release only: bundle the '
      'libsmb2 of the libsmb2-$libsmb2Release release, or a build of '
      'libsmb2-scripts at libsmb2-$libsmb2Release';
}
