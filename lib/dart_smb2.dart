// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// SMB2/3 client for Dart, built on libsmb2.
///
/// - [Smb2Pool]: async, safe on the UI isolate, with worker isolates that
///   reconnect on their own, streaming, atomic downloads and cancellation.
///   The recommended entry point.
/// - [Smb2Client]: the synchronous client the workers run, for code that
///   manages its own isolates.
library;

import 'src/pool/pool.dart';
import 'src/smb2_client.dart';

export 'src/pool/pool.dart';
export 'src/smb2_cancel_token.dart';
export 'src/smb2_client.dart' show Smb2Client, Smb2Handle;
export 'src/smb2_error_type.dart';
export 'src/smb2_exception.dart';
export 'src/smb2_types.dart';
