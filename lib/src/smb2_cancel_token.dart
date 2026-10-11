// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:async';

import 'package:meta/meta.dart';

import 'pool/pool.dart';
import 'smb2_error_type.dart';
import 'smb2_exception.dart';

/// Cancels pool operations that are still running.
///
/// Pass one to any [Smb2Pool] call that takes a `cancelToken`. A cancelled
/// call throws a [Smb2Exception] of type [Smb2ErrorType.cancelled] — not a
/// failure, so it is safe to ignore. The call returns at once: a request
/// the worker already sent to the server finishes there and its result is
/// dropped, and a file it opened is closed.
///
/// One token can cancel any number of calls, but only once: after
/// [cancel], every call that uses it fails immediately. Make a new token
/// for the next page, folder or download.
///
/// ```dart
/// final token = Smb2CancelToken();
/// final download = pool.downloadToFile(
///   'Music/album.flac',
///   '/tmp/album.flac',
///   cancelToken: token,
/// );
/// // The user pressed stop:
/// token.cancel();
/// ```
final class Smb2CancelToken {
  final Completer<void> _cancelled = Completer<void>();
  final Set<_Listener> _listeners = {};
  Object? _reason;

  /// Creates a token that has not been cancelled yet.
  Smb2CancelToken();

  /// Whether [cancel] has been called.
  bool get isCancelled => _cancelled.isCompleted;

  /// The value passed to [cancel], if any.
  Object? get reason => _reason;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _cancelled.future;

  /// Cancels every call using this token. Later calls do nothing.
  void cancel([Object? reason]) {
    if (_cancelled.isCompleted) return;
    _reason = reason;
    _cancelled.complete();
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final l in listeners) {
      l.callback();
    }
  }

  /// Throws the cancellation if [cancel] has been called.
  void throwIfCancelled({String? path}) {
    if (isCancelled) throw cancelledException(path: path);
  }

  /// The exception a call cancelled through this token throws.
  @internal
  Smb2Exception cancelledException({String? path}) => Smb2Exception(
    _reason == null ? 'Cancelled' : 'Cancelled: $_reason',
    type: Smb2ErrorType.cancelled,
    path: path,
  );

  /// Calls [callback] once when this token is cancelled, synchronously
  /// inside [cancel]. Returns a function that removes the callback.
  ///
  /// A call registers here while it runs and unregisters when it ends, so a
  /// long-lived token does not keep a closure per finished call. Does
  /// nothing — and returns a no-op — when the token is already cancelled;
  /// check [isCancelled] first.
  @internal
  void Function() register(void Function() callback) {
    if (isCancelled) return _noop;
    final listener = _Listener(callback);
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// How many callbacks are registered. For tests.
  @visibleForTesting
  int get listenerCount => _listeners.length;
}

void _noop() {}

/// Wraps a callback so two registrations of the same closure stay distinct.
final class _Listener {
  final void Function() callback;
  _Listener(this.callback);
}
