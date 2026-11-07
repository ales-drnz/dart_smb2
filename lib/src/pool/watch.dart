// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// The isolate behind [Smb2Pool.watch]: a connection of its own that waits
/// for change notifications, so the pool's workers stay free for calls.
library;

import 'dart:async';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../smb2_client.dart';
import '../smb2_exception.dart';
import '../smb2_types.dart';
import 'pool.dart';
import 'protocol.dart';

/// What a watch isolate watches, and where it reports.
@internal
final class WatchInit {
  /// Where the isolate sends its [SendPort], the changes (lists of
  /// [Smb2ChangeEvent]) and a [Failure] that ends the watch.
  final SendPort replies;

  /// The pool's connection settings.
  final ConnectParams params;

  /// The watched directory.
  final String path;

  /// Whether the watch covers the whole tree.
  final bool recursive;

  /// The [Smb2ChangeFilter] mask.
  final int filter;

  /// The settings of one watch.
  const WatchInit(
    this.replies,
    this.params, {
    required this.path,
    required this.recursive,
    required this.filter,
  });
}

/// How often an idle watch sends an echo, to notice a connection that died
/// without closing.
@visibleForTesting
Duration debugWatchEchoInterval = const Duration(seconds: 30);

/// The longest a watch's request may take: a stop waits for the one in
/// flight, since the isolate is never killed.
const Duration watchRequestTimeout = Duration(seconds: 5);

/// Entry point of a watch isolate.
///
/// Connects and starts the watch, then reports each batch of changes until
/// it is told to stop (any message on its port). A network failure is not
/// the end: it reconnects, 1 to 32 seconds apart, starts the watch again
/// and reports a [Smb2ChangeAction.overflow], since changes may have been
/// missed meanwhile. Any other failure, or one before the first watch
/// started, is sent as a [Failure] and ends the isolate.
///
/// Its requests time out after [watchRequestTimeout], or the pool's
/// timeout when shorter, so a stop is seen within a few seconds.
Future<void> watchMain(WatchInit init) async {
  final commands = ReceivePort();
  var stop = false;
  commands.listen((_) => stop = true);
  init.replies.send(commands.sendPort);
  final p = init.params;
  final timeout = p.timeout > Duration.zero && p.timeout < watchRequestTimeout
      ? p.timeout
      : watchRequestTimeout;
  // A stop sent before the isolate started arrives here.
  await Future<void>.delayed(Duration.zero);

  Smb2Client? client;
  Smb2Watcher? watcher;
  var started = false;
  var backoff = 1;
  final sinceEcho = Stopwatch();

  void drop() {
    try {
      watcher?.close();
    } on Object {
      // The connection is gone; disconnect frees what is left.
    }
    client?.disconnect();
    watcher = null;
    client = null;
  }

  try {
    while (!stop) {
      try {
        if (watcher == null) {
          final c = client = Smb2Client()
            ..connect(
              host: p.host,
              share: p.share,
              user: p.user,
              password: p.password,
              domain: p.domain,
              timeout: timeout,
              seal: p.seal,
              signing: p.signing,
              version: p.version,
            );
          watcher = c.watch(
            init.path,
            recursive: init.recursive,
            filter: init.filter,
          );
          sinceEcho
            ..reset()
            ..start();
          if (started) {
            init.replies.send([
              Smb2ChangeEvent(
                Smb2ChangeAction.overflow,
                changePath(init.path, ''),
              ),
            ]);
          }
          started = true;
          backoff = 1;
        }
        final events = watcher!.next(
          timeout: const Duration(milliseconds: 200),
        );
        if (events.isNotEmpty) init.replies.send(events);
        if (sinceEcho.elapsed >= debugWatchEchoInterval) {
          client!.echo();
          sinceEcho.reset();
        }
        // Lets the stop message in.
        await Future<void>.delayed(Duration.zero);
      } on Smb2Exception catch (e) {
        drop();
        if (!started || !e.isNetworkFailure) {
          init.replies.send(Failure(-1, e));
          return;
        }
        final until = DateTime.now().add(Duration(seconds: backoff));
        backoff = backoff >= 32 ? 32 : backoff * 2;
        while (!stop && DateTime.now().isBefore(until)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  } catch (e) {
    init.replies.send(
      Failure(
        -1,
        Smb2Exception('The watch failed: $e', path: init.path, cause: e),
      ),
    );
  } finally {
    drop();
    commands.close();
  }
}
