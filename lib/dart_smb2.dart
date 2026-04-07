// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Fast, stable SMB2/3 client for Dart — powered by libsmb2.
///
/// Exposes four layers of abstraction:
/// - [Smb2Client] — synchronous FFI client for use inside isolates.
/// - [Smb2Isolate] — async isolate wrapper for single-connection use.
/// - [Smb2Pool] — multi-worker pool with round-robin dispatch and auto-reconnect.
/// - [CachedSmb2Pool] — TTL-based caching layer over [Smb2Pool].
library;

export 'src/smb2_cached_pool.dart';
export 'src/smb2_client.dart';
export 'src/smb2_error_type.dart';
export 'src/smb2_exceptions.dart';
export 'src/smb2_isolate.dart';
export 'src/smb2_pool.dart';
export 'src/smb2_types.dart';
