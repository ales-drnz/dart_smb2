// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../smb2_cancel_token.dart';
import '../smb2_client.dart';
import '../smb2_error_type.dart';
import '../smb2_exception.dart';
import '../smb2_types.dart';
import 'handle.dart';
import 'protocol.dart';
import 'watch.dart';
import 'worker.dart';

export 'handle.dart' show Smb2File, Smb2PoolHandle;

part 'calls.dart';
part 'dispatcher.dart';
part 'paths.dart';
part 'transfers.dart';
part 'trees.dart';
part 'watch_stream.dart';

/// SMB2/3 client for async code: a pool of worker isolates, each with its
/// own connection to the share.
///
/// Every method is async and safe to call from the UI isolate. Calls go to
/// the least busy worker; a file handle stays on the worker that opened it.
/// When a worker's connection drops, the pool reconnects it and repeats the
/// call once, for every call that is safe to repeat (see [connect]).
///
/// ```dart
/// final pool = await Smb2Pool.connect(
///   host: '192.168.1.10',
///   share: 'Music',
///   user: 'user',
///   password: 'pass',
/// );
/// try {
///   final entries = await pool.listDirectory('');
///   final cover = await pool.readFile('Artist/cover.jpg');
/// } finally {
///   await pool.disconnect();
/// }
/// ```
///
/// {@category Connection}
final class Smb2Pool extends _PoolCore
    with _PoolCalls, _PoolTransfers, _PoolTrees, _PoolWatch {
  Smb2Pool._(super._slots, super._params);

  /// Connects [workers] worker isolates to [share] on [host], in parallel.
  ///
  /// [timeout] bounds every request a worker makes, the connection
  /// included; a request that runs out of it fails with
  /// [Smb2ErrorType.timeout] and the worker reconnects.
  ///
  /// After a network failure the pool reconnects the worker and repeats
  /// the call once, when repeating cannot change the outcome: reads,
  /// listings, metadata, writes at an offset, whole-file writes, truncates
  /// and timestamps. [mkdir], [rmdir], [deleteFile] and [rename] are not
  /// repeated — the server may have done them before the connection
  /// dropped — and their failure reaches the caller.
  ///
  /// When a reconnect fails, the slot's calls go to the other workers, and
  /// the slot tries again in the background, from 1 to 32 seconds apart,
  /// after a network failure. A refusal (credentials, the share) is kept for
  /// five minutes: reconnects fail with it at once, and one login is tried
  /// per interval for the whole pool.
  ///
  /// The credentials work as in [Smb2Client.connect]: without a [user], or
  /// with a null [password], the logon is anonymous; `password: ''` logs on
  /// to an account whose password is empty.
  ///
  /// Throws the first worker's [Smb2Exception] when one cannot connect
  /// (the others are closed): [Smb2ErrorType.auth] for bad credentials,
  /// [Smb2ErrorType.notFound] for a share that does not exist, a network
  /// failure for a host that does not answer. [workers] below 1 throws
  /// [Smb2ErrorType.invalidParam].
  static Future<Smb2Pool> connect({
    required String host,
    required String share,
    String? user,
    String? password,
    String? domain,
    int workers = 4,
    Duration timeout = const Duration(seconds: 30),
    bool seal = false,
    bool signing = false,
    Smb2Version version = Smb2Version.any,
  }) async {
    if (workers < 1) {
      throw const Smb2Exception(
        'A pool needs at least one worker',
        type: Smb2ErrorType.invalidParam,
      );
    }
    final params = ConnectParams(
      host: host,
      share: share,
      user: user,
      password: password,
      domain: domain,
      timeout: timeout,
      seal: seal,
      signing: signing,
      version: version,
    );
    final spawned = await Future.wait(
      List.generate(workers, (_) => _spawnResult(params)),
    );
    final failure = spawned.whereType<Smb2Exception>().firstOrNull;
    if (failure != null) {
      await Future.wait(spawned.whereType<Worker>().map((w) => w.close()));
      throw failure;
    }
    final pool = Smb2Pool._([
      for (final w in spawned) Slot(w as Worker),
    ], params);
    for (final slot in pool._slots) {
      pool._watch(slot, slot.worker);
    }
    return pool;
  }

  static Future<Object> _spawnResult(ConnectParams params) =>
      Worker.spawn(params).then<Object>(
        (w) => w,
        onError: (Object e) => e is Smb2Exception
            ? e
            : Smb2Exception('Cannot start a worker: $e', cause: e),
      );

  /// Lists the shares of [host] from a short-lived isolate, without a pool.
  static Future<List<Smb2ShareInfo>> listSharesOn({
    required String host,
    String? user,
    String? password,
    String? domain,
    Duration timeout = const Duration(seconds: 15),
  }) {
    return Isolate.run(
      () => Smb2Client.listShares(
        host: host,
        user: user,
        password: password,
        domain: domain,
        timeout: timeout,
      ),
      debugName: 'dart_smb2 listShares',
    );
  }

  /// Opens [path], runs [body] with the open [Smb2File], and closes it on
  /// every exit path.
  ///
  /// Pass [knownSize] when a listing or `stat` already gave the size: the
  /// open then skips the size request.
  ///
  /// ```dart
  /// final header = await pool.withFile('Music/song.flac', (file) {
  ///   return file.read(length: min(file.size, 64 * 1024));
  /// });
  /// ```
  Future<T> withFile<T>(
    String path,
    FutureOr<T> Function(Smb2File file) body, {
    int? knownSize,
    Smb2CancelToken? cancelToken,
  }) async {
    final Smb2PoolHandle handle;
    final int size;
    if (knownSize != null) {
      handle = await openFile(path, cancelToken: cancelToken);
      size = knownSize;
    } else {
      (handle, size) = await openFileWithSize(path, cancelToken: cancelToken);
    }
    final T result;
    try {
      result = await body(Smb2File(this, handle, size, cancelToken));
    } catch (_) {
      _closeLater(handle);
      rethrow;
    }
    await closeHandle(handle);
    return result;
  }

  /// Closes every worker: each closes its handles and logs off.
  ///
  /// Requests a worker has already been sent finish first (a worker that
  /// does not finish within 5 seconds is killed, and they fail with a
  /// [Smb2ErrorType.connection] error). Calls waiting for a reconnect, and
  /// calls made later, fail with a [Smb2ErrorType.state] error. A reconnect
  /// in progress is aborted. The watches end as [watch] describes.
  ///
  /// Every call returns the same future: a second one, made while the
  /// first is still closing, completes with it.
  Future<void> disconnect() => _disconnecting ??= _disconnect();

  Future<void> _disconnect() async {
    _closed = true;
    _closing.cancel();
    for (final slot in _slots) {
      slot.retry?.cancel();
      slot.retry = null;
    }
    _refusalRetry?.cancel();
    _refusalRetry = null;
    await Future.wait([for (final stop in _watches.toList()) stop()]);
    // Wait for the reconnects so nothing outlives this call.
    await Future.wait(_reconnects.toList());
    await Future.wait(_slots.map((s) => s.worker.close()));
  }

  /// How long a slot whose reconnect the server refused waits before it
  /// tries again. Shortened by tests.
  @visibleForTesting
  static Duration debugRefusedRetry = const Duration(minutes: 5);

  /// The default chunk of [streamFile] and [downloadToFile]: 4 MiB.
  static const int defaultChunkSize = 4 * 1024 * 1024;
}

void _noop() {}
