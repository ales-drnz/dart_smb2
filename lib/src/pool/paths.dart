// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

/// Share-relative paths as the pool compares and joins them.
part of 'pool.dart';

/// [path] as the server compares it: leading slashes dropped, backslashes
/// as slashes, case folded.
String _pathKey(String path) => path
    .replaceAll(r'\', '/')
    .replaceAll(_slashes, '/')
    .replaceFirst(_edgeSlashes, '')
    .replaceFirst(_edgeSlashes, '')
    .toLowerCase();

final _slashes = RegExp('/{2,}');

/// [rel] below [root], either of them possibly ''.
String _under(String root, String rel) =>
    root.isEmpty ? rel : (rel.isEmpty ? root : '$root/$rel');

/// The non-empty segments of [path], `\` taken as `/`.
List<String> _segments(String path) => [
  for (final s in path.replaceAll(r'\', '/').split('/'))
    if (s.isNotEmpty) s,
];

final _edgeSlashes = RegExp(r'^/|/$');
