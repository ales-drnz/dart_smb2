// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Fast, stable SMB2/3 client for Dart — powered by libsmb2.
///
/// Exposes three layers of abstraction:
/// - [Smb2Client] — synchronous FFI client for use inside your own isolates.
/// - [Smb2Pool] — async multi-worker pool with auto-reconnect and
///   scope-based file helpers ([Smb2Pool.withFile], [Smb2Pool.streamFile],
///   [Smb2Pool.downloadToFile]). The recommended entry point.
/// - [CachedSmb2Pool] — optional TTL cache over [Smb2Pool] for `stat`
///   and `listDirectory`.
library;

export 'src/smb2_cached_pool.dart';
export 'src/smb2_client.dart';
export 'src/smb2_error_type.dart';
export 'src/smb2_exceptions.dart';
export 'src/smb2_pool.dart';
export 'src/smb2_types.dart';
