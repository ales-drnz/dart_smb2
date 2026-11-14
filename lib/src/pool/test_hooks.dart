// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Package-internal access to a pool's workers for the concurrency tests.
/// Not exported by `package:dart_smb2/dart_smb2.dart`.
library;

import 'package:meta/meta.dart';

import 'pool.dart';
import 'protocol.dart';
import 'worker.dart';

export 'protocol.dart' show Echo, Stat, WriteFile;
export 'worker.dart' show Worker;

/// The workers behind [pool], in slot order.
@internal
List<Worker> poolWorkers(Smb2Pool pool) => pool.workersForTest;

/// Test-only faults a worker can be told to simulate.
@internal
extension WorkerFaults on Worker {
  /// The next [count] requests fail with a connection error.
  Future<void> failNext(int count) => call(InjectFailures(count));

  /// The next request never gets a reply.
  Future<void> hangNext() => call(const InjectHang());

  /// The next handle read returns no bytes.
  Future<void> emptyReadNext() => call(const InjectEmptyRead());

  /// How many files the worker holds open.
  Future<int> handleCount() => call(const InjectHandleCount());

  /// The worker's isolate exits, as a crash would: the pool is not told.
  void crash() => post(const InjectExit());
}
