Use `Smb2Client`, the blocking client each worker runs, from an isolate of your own.

## The synchronous client

`Smb2Client` is the client each worker runs. Every call blocks until the server answers, so use it from an isolate of your own.

```dart
final summary = await Isolate.run(() {
  final client = Smb2Client()
    ..connect(host: 'nas.local', share: 'Music', user: 'alice', password: 'secret');
  try {
    final entries = client.listDirectory('');
    return '${entries.length} entries, ${client.maxReadSize} B per read';
  } finally {
    client.disconnect();
  }
});
```

It has the pool's methods, without the `Future`s and the cancel tokens: `openFile`, `readFromHandle`, `writeToHandle`, `closeHandle` and so on, plus `readFileChunked` and `writeFileChunked` over iterables. `Smb2Client.listShares` is static and needs no connection. A client dropped without `disconnect()` frees its connection when it is garbage collected, without a logoff.

## Watching a directory

`Smb2Client.watch` returns an `Smb2Watcher`, which you ask for the changes with `next`. Without a timeout `next` blocks until something changes; with one it returns an empty list when nothing did, and `Duration.zero` takes what has arrived without waiting. Changes are kept from the moment the watch starts, so none is lost between two calls, and the client's other calls go on meanwhile.

```dart
final watcher = client.watch('Inbox');
try {
  while (running) {
    for (final e in watcher.next(timeout: const Duration(seconds: 1))) {
      print('${e.action.name} ${e.path}');
    }
  }
} finally {
  watcher.close();
}
```

The wait does not count against the client's `timeout`. A client that has watched frees its connection only with `disconnect()`: not when it is garbage collected, and not when its isolate ends, so call it before the isolate exits. `Smb2Pool.watch` runs a watcher like this one in an isolate of its own and hands you its changes as a stream.

## Requests in flight

A call cannot be stopped once sent: the client waits in libsmb2 for the reply, on the isolate's only thread, so nothing can send the SMB2 CANCEL meanwhile. The pool's cancel tokens stop waiting for the reply instead, and the worker drops it when it comes.
