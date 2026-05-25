// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'smb2_error_type.dart';

/// Exception thrown when an SMB2 operation fails.
///
/// The [message] contains the error description from libsmb2.
/// The [type] classifies the error for programmatic handling.
class Smb2Exception implements Exception {
  /// Human-readable error description.
  final String message;

  /// Optional native errno code.
  final int? errorCode;

  /// Semantic error category.
  final Smb2ErrorType type;

  /// Build a [Smb2Exception] from a message, optional errno, and category.
  const Smb2Exception(this.message, [this.errorCode, this.type = Smb2ErrorType.unknown]);

  /// Whether this error indicates a broken or timed-out connection
  /// that may succeed on retry.
  bool get isConnectionError => type.isConnectionError;

  @override
  String toString() => errorCode != null
      ? 'Smb2Exception($type, errno=$errorCode): $message'
      : 'Smb2Exception($type): $message';
}
