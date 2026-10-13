// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

import 'package:dart_smb2/dart_smb2.dart';
import 'package:test/test.dart';

void main() {
  test('starts uncancelled', () {
    final t = Smb2CancelToken();
    expect(t.isCancelled, isFalse);
    expect(t.reason, isNull);
    expect(t.throwIfCancelled, returnsNormally);
  });

  test('cancel runs the listeners once, with the reason', () async {
    final t = Smb2CancelToken();
    var calls = 0;
    t.register(() => calls++);
    t.cancel('left the page');
    t.cancel('again');
    expect(calls, 1);
    expect(t.isCancelled, isTrue);
    expect(t.reason, 'left the page');
    await t.whenCancelled;
    expect(t.listenerCount, 0);
  });

  test('throwIfCancelled throws a cancelled Smb2Exception with the path', () {
    final t = Smb2CancelToken()..cancel();
    expect(
      () => t.throwIfCancelled(path: 'a.flac'),
      throwsA(
        isA<Smb2Exception>()
            .having((e) => e.isCancelled, 'isCancelled', isTrue)
            .having((e) => e.path, 'path', 'a.flac'),
      ),
    );
  });

  test('unregistering removes the listener; registering late is a no-op', () {
    final t = Smb2CancelToken();
    var calls = 0;
    final remove = t.register(() => calls++);
    expect(t.listenerCount, 1);
    remove();
    expect(t.listenerCount, 0);
    t.cancel();
    expect(calls, 0);
    t.register(() => calls++)();
    expect(calls, 0);
  });

  test('the same closure registered twice runs twice', () {
    final t = Smb2CancelToken();
    var calls = 0;
    void cb() => calls++;
    t
      ..register(cb)
      ..register(cb)
      ..cancel();
    expect(calls, 2);
  });
}
