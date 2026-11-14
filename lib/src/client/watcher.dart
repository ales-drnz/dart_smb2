// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// [Smb2Watcher], and the reply of a CHANGE_NOTIFY that failed.
part of '../smb2_client.dart';

typedef _NotifyCallback =
    Void Function(Pointer<smb2_context>, Int, Pointer<Void>, Pointer<Void>);

/// STATUS_NOTIFY_ENUM_DIR: more changes than the reply could hold.
const int _statusNotifyEnumDir = 0x0000010C;

/// A watch on a directory, from [Smb2Client.watch].
///
/// Pull its changes with [next], on the isolate of its client, and [close]
/// it when done. [Smb2Pool.watch] runs one in an isolate of its own and
/// delivers its changes as a stream.
///
/// {@category Synchronous client}
final class Smb2Watcher {
  final Smb2Client _client;
  final int _id;
  Pointer<smb2fh> _fh;
  final int _flags;
  final int _filter;
  final List<Smb2ChangeEvent> _events = [];
  Smb2Exception? _failure;

  /// The share-relative path of the watched directory.
  final String path;

  Smb2Watcher._(
    this._client,
    this._id,
    this._fh,
    this.path,
    this._flags,
    this._filter,
  );

  String get _base => changePath(path, '');

  /// Whether [close] was called, or the watch failed.
  bool get isClosed => _fh == nullptr;

  /// The changes reported since the last call, in the order the server
  /// sent them; when there are none yet, waits for the next ones.
  ///
  /// With a [timeout] it waits at most that long and returns an empty list
  /// when nothing changed; without one it waits until something does. The
  /// wait does not count against the client's request timeout. Even
  /// [Duration.zero] reads what the socket holds already.
  ///
  /// Throws the failure that ended the watch (the directory was removed,
  /// the connection was lost: [Smb2Exception.isNetworkFailure]) once the
  /// changes before it are returned; the watcher is closed then. Throws
  /// [Smb2ErrorType.state] once closed.
  List<Smb2ChangeEvent> next({Duration? timeout}) {
    final clock = Stopwatch()..start();
    var last = false;
    while (true) {
      if (_events.isNotEmpty) {
        final out = List<Smb2ChangeEvent>.of(_events);
        _events.clear();
        return out;
      }
      final error = _failure;
      if (error != null) {
        close();
        throw error;
      }
      if (isClosed) {
        throw Smb2Exception(
          'The watcher is closed',
          type: Smb2ErrorType.state,
          path: path,
        );
      }
      if (last) return const [];
      _client._ensureConnected();
      var wait = -1;
      if (timeout != null) {
        final left = timeout - clock.elapsed;
        // One more pass once the time is up, which does not wait.
        if (left <= Duration.zero) {
          wait = 0;
          last = true;
        } else {
          wait = left.inMilliseconds + (left.inMicroseconds % 1000 > 0 ? 1 : 0);
        }
      }
      final ctx = _client._ctx;
      final revents = pollSocket(
        smb2_get_fd(ctx),
        smb2_which_events(ctx),
        wait,
      );
      if (revents > 0 && smb2_service(ctx, revents) < 0) {
        final e = _error(ctx, 'Watch failed', path: path);
        _failure = e.isNetworkFailure
            ? e
            : Smb2Exception(
                e.message,
                type: Smb2ErrorType.connection,
                path: path,
              );
      }
    }
  }

  /// Stops the watch and closes the directory. Closing it again does
  /// nothing.
  void close() {
    if (isClosed) return;
    final fh = _fh;
    _fh = nullptr;
    _client._watchers.remove(_id);
    // The server ends the pending CHANGE_NOTIFY with NOTIFY_CLEANUP when
    // the directory closes; its callback finds no watcher and drops it.
    if (_client._ctx != nullptr) smb2_close(_client._ctx, fh);
  }
}

/// The exception for a CHANGE_NOTIFY that failed with the NT [status].
Smb2Exception _notifyError(Pointer<smb2_context> ctx, int status, String path) {
  final nt = status & 0xFFFFFFFF;
  final errno = nterror_to_errno(nt);
  final type = Smb2ErrorType.fromNtStatus(nt);
  return Smb2Exception(
    'Watch failed: ${_string(nterror_to_str(nt))}',
    type: type == Smb2ErrorType.unknown && nt == 0
        ? Smb2ErrorType.connection
        : type,
    ntStatus: nt == 0 ? null : nt,
    errno: errno > 0 ? errno : null,
    path: path,
  );
}
