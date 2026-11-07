// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// `poll()` on one socket, for the event loop that serves change
/// notifications (libsmb2's sync API has its own loop, which only waits for
/// the reply of the call in progress).
///
/// POSIX `poll` from the process (Linux, Android, macOS, iOS) and `WSAPoll`
/// from ws2_32 on Windows. The event bits are passed through untouched:
/// they come from `smb2_which_events` and go back to `smb2_service`, both
/// compiled against the same platform headers.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

final class _PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

final class _WsaPollFd extends Struct {
  @IntPtr()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

/// `nfds_t`: unsigned long on glibc, unsigned int on bionic and Darwin.
@AbiSpecificIntegerMapping({
  Abi.androidArm: Uint32(),
  Abi.androidArm64: Uint32(),
  Abi.androidIA32: Uint32(),
  Abi.androidX64: Uint32(),
  Abi.androidRiscv64: Uint32(),
  Abi.iosArm: Uint32(),
  Abi.iosArm64: Uint32(),
  Abi.iosX64: Uint32(),
  Abi.macosArm64: Uint32(),
  Abi.macosX64: Uint32(),
  Abi.linuxArm: Uint32(),
  Abi.linuxIA32: Uint32(),
  Abi.linuxRiscv32: Uint32(),
  Abi.linuxArm64: Uint64(),
  Abi.linuxX64: Uint64(),
  Abi.linuxRiscv64: Uint64(),
})
final class _NfdsT extends AbiSpecificInteger {
  const _NfdsT();
}

typedef _PosixPollC = Int Function(Pointer<_PollFd>, _NfdsT, Int);
typedef _PosixPoll = int Function(Pointer<_PollFd>, int, int);
typedef _WsaPollC = Int Function(Pointer<_WsaPollFd>, Uint32, Int);
typedef _WsaPoll = int Function(Pointer<_WsaPollFd>, int, int);

final _PosixPoll? _posixPoll = Platform.isWindows
    ? null
    : DynamicLibrary.process().lookupFunction<_PosixPollC, _PosixPoll>('poll');

final _WsaPoll? _wsaPoll = Platform.isWindows
    ? DynamicLibrary.open(
        'ws2_32.dll',
      ).lookupFunction<_WsaPollC, _WsaPoll>('WSAPoll')
    : null;

/// Waits up to [timeoutMs] milliseconds (-1: no limit) for [events] on the
/// socket [fd], and returns the events that happened: 0 when the time ran
/// out, -1 when poll failed (EINTR included; the caller polls again).
int pollSocket(int fd, int events, int timeoutMs) {
  if (_wsaPoll case final wsaPoll?) {
    final pfd = calloc<_WsaPollFd>();
    try {
      pfd.ref
        ..fd = fd
        ..events = events;
      final rc = wsaPoll(pfd, 1, timeoutMs);
      return rc < 0 ? -1 : (rc == 0 ? 0 : pfd.ref.revents & 0xFFFF);
    } finally {
      calloc.free(pfd);
    }
  }
  final pfd = calloc<_PollFd>();
  try {
    pfd.ref
      ..fd = fd
      ..events = events;
    final rc = _posixPoll!(pfd, 1, timeoutMs);
    return rc < 0 ? -1 : (rc == 0 ? 0 : pfd.ref.revents & 0xFFFF);
  } finally {
    calloc.free(pfd);
  }
}
