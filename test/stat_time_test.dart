// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The times of a stat, from what libsmb2 makes of the server's FILETIME.
/// Needs no server.
library;

import 'package:dart_smb2/src/smb2_client.dart';
import 'package:test/test.dart';

void main() {
  final epoch = DateTime.fromMicrosecondsSinceEpoch(0, isUtc: true);

  test('seconds and nanoseconds make a UTC time to the microsecond', () {
    expect(
      statTime(1762560000, 123456789),
      DateTime.utc(2025, 11, 8, 0, 0, 0, 123, 456),
    );
  });

  test('a FILETIME of 0, which libsmb2 wraps, is the Unix epoch', () {
    // (2^64 - 116444736000000000) / 10^7, what smb2_win_to_timeval gives.
    expect(statTime(1833029933770, 955161), epoch);
  });

  test('a time before 1970, wrapped the same way, is the Unix epoch', () {
    expect(statTime(1833029933770 - 86400, 0), epoch);
    expect(statTime(-1, 0), epoch);
  });

  test('the last second of the year 9999 is kept', () {
    expect(statTime(253402300799, 0), DateTime.utc(9999, 12, 31, 23, 59, 59));
  });
}
