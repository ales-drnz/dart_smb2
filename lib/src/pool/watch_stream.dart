// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The stream of a watch on a pool, fed by the isolate of watch.dart.
part of 'pool.dart';

/// [Smb2Pool.watch].
mixin _PoolWatch on _PoolCore {
  /// Watches the directory [path] for changes, and with [recursive]
  /// everything below it, as a stream of [Smb2ChangeEvent]s.
  ///
  /// [filter] is a mask of [Smb2ChangeFilter] bits. The watch has a
  /// connection of its own, in an isolate of its own, so it takes no
  /// worker. After a network failure it reconnects, 1 to 32 seconds apart,
  /// and sends a [Smb2ChangeAction.overflow] event, since changes may have
  /// been missed: list the directory again then. Any other failure (the
  /// directory was removed, the server refuses the watch) ends the stream
  /// with an error, and so does [cancelToken], with a
  /// [Smb2ErrorType.cancelled] one. Cancelling the subscription, or
  /// [Smb2Pool.disconnect], ends the watch.
  ///
  /// A paused subscription, as `await for` and [StreamIterator] make
  /// between events, keeps the changes that arrive meanwhile in memory, as
  /// any stream does. Do not leave one paused for long on a busy directory:
  /// cancel it, and watch again when needed.
  ///
  /// Ending the watch waits for its connection to finish the request in
  /// flight and log off. The watch's requests time out after 5 seconds (or
  /// the pool's timeout, when shorter), so when the server stops answering
  /// this takes up to about 15 seconds; the isolate is never killed in a
  /// native call.
  ///
  /// While watched, the directory itself cannot be renamed or removed. The
  /// changes the pool's own calls make are reported like anyone else's.
  ///
  /// ```dart
  /// final sub = pool.watch('Inbox').listen((e) {
  ///   if (e.action == Smb2ChangeAction.overflow) refresh();
  ///   else print('${e.action.name} ${e.path}');
  /// });
  /// ```
  Stream<Smb2ChangeEvent> watch(
    String path, {
    bool recursive = false,
    int filter = Smb2ChangeFilter.defaults,
    Smb2CancelToken? cancelToken,
  }) {
    late final StreamController<Smb2ChangeEvent> controller;
    RawReceivePort? port;
    SendPort? commands;
    var stopping = false;
    final exited = Completer<void>();
    var unlink = _noop;

    void finish([Object? error]) {
      unlink();
      if (controller.isClosed) return;
      if (error != null) controller.addError(error);
      unawaited(controller.close());
    }

    late final Future<void> Function() stop;

    void gone() {
      port?.close();
      _watches.remove(stop);
      if (!exited.isCompleted) exited.complete();
    }

    // The isolate is never killed: one killed in a native call crashes the
    // VM when libsmb2 then calls the notify callback. It stops at its next
    // turn of the loop, once it has the stop message; until then the port
    // stays open, so a stop sent before its SendPort arrived still reaches
    // it.
    stop = () async {
      if (!stopping) {
        stopping = true;
        _watches.remove(stop);
        if (port == null) gone();
        commands?.send(null);
      }
      await exited.future;
      finish();
    };

    controller = StreamController<Smb2ChangeEvent>(
      onListen: () async {
        if (_closed) {
          finish(
            Smb2Exception(
              'The pool is closed',
              type: Smb2ErrorType.state,
              path: path,
            ),
          );
          return;
        }
        if (filter <= 0 || filter > Smb2ChangeFilter.all) {
          finish(
            Smb2Exception(
              'filter must be a mask of Smb2ChangeFilter bits',
              type: Smb2ErrorType.invalidParam,
              path: path,
            ),
          );
          return;
        }
        if (cancelToken != null) {
          if (cancelToken.isCancelled) {
            finish(cancelToken.cancelledException(path: path));
            return;
          }
          unlink = cancelToken.register(() {
            finish(cancelToken.cancelledException(path: path));
            unawaited(stop());
          });
        }
        _watches.add(stop);
        port = RawReceivePort((Object? m) {
          switch (m) {
            case SendPort():
              commands = m;
              if (stopping) m.send(null);
            case List<Smb2ChangeEvent>():
              if (!controller.isClosed) m.forEach(controller.add);
            case Failure():
              finish(m.toException());
            case null:
              // onExit.
              gone();
              finish();
            case List<Object?>(:final first):
              // onError: [error, stack]; onExit follows.
              finish(
                Smb2Exception(
                  'The watch isolate failed: $first',
                  type: Smb2ErrorType.connection,
                  path: path,
                  cause: first,
                ),
              );
          }
        }, 'dart_smb2 watch');
        try {
          await Isolate.spawn(
            watchMain,
            WatchInit(
              port!.sendPort,
              _params,
              path: path,
              recursive: recursive,
              filter: filter,
            ),
            onExit: port!.sendPort,
            onError: port!.sendPort,
            debugName: 'dart_smb2 watch',
          );
        } catch (e) {
          gone();
          finish(
            Smb2Exception(
              'Cannot spawn the watch isolate: $e',
              type: Smb2ErrorType.state,
              path: path,
              cause: e,
            ),
          );
        }
      },
      onCancel: stop,
    );
    return controller.stream;
  }
}
