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
