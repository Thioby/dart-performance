/// Guide sections 1 and 3: byte buffer management and HTTP parsing.
///
/// 1. Assembling incoming chunks (`Socket.listen(onData)`):
///    * `List<int>` + `addAll` (boxing / growable),
///    * `Uint8List` + a copy on every chunk (this is what
///      `dart-rawsocket-C-Hatton` does: `nb = Uint8List(buf.length + data.length)`),
///    * `BytesBuilder(copy: false)` (a list of chunks, one copy at the end),
///    * a reusable, preallocated `Uint8List` + counter (zero allocations).
/// 2. Parsing HTTP headers:
///    * idiomatically: `utf8.decode` + `split('\r\n')` + `split(':')` + `Map`,
///    * byte-wise: a scan over `Uint8List`, only the 3 headers we need, no
///      Strings except the Authorization value (pattern from `_parseHead` in
///      the Dart submission).
library;

import 'dart:convert';
import 'dart:typed_data';

import '../harness.dart';

final Uint8List _request = Uint8List.fromList(utf8.encode(
  'POST /posts/123456/like HTTP/1.1\r\n'
  'Host: 127.0.0.1:3000\r\n'
  'User-Agent: k6/0.50.0 (https://k6.io/)\r\n'
  'Accept: */*\r\n'
  'Accept-Encoding: gzip\r\n'
  'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
  'eyJzdWIiOiIxMjMiLCJ1c2VybmFtZSI6InVzZXJfMTIzIiwiaWF0IjoxNzAwMDAwMDAwLCJleHAiOjIwMDAwMDAwMDB9.'
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTU\r\n'
  'Content-Type: application/json\r\n'
  'Content-Length: 0\r\n'
  '\r\n',
));

// ---------- 1. assembling chunks ----------

const _chunk = 512;
final List<Uint8List> _chunks = [
  for (var i = 0; i < 16; i++) Uint8List(_chunk)..fillRange(0, _chunk, i),
];

List<int> _assembleListInt() {
  final out = <int>[];
  for (final c in _chunks) {
    out.addAll(c);
  }
  return out;
}

Uint8List _assembleCopyEach() {
  var buf = Uint8List(0);
  for (final data in _chunks) {
    final nb = Uint8List(buf.length + data.length);
    nb.setRange(0, buf.length, buf);
    nb.setRange(buf.length, nb.length, data);
    buf = nb;
  }
  return buf;
}

Uint8List _assembleBytesBuilder() {
  final b = BytesBuilder(copy: false);
  for (final c in _chunks) {
    b.add(c);
  }
  return b.takeBytes();
}

final Uint8List _pooled = Uint8List(64 * 1024);

Uint8List _assemblePooled() {
  var n = 0;
  for (final c in _chunks) {
    _pooled.setRange(n, n + c.length, c);
    n += c.length;
  }
  return Uint8List.sublistView(_pooled, 0, n); // a view, no copy
}

// ---------- 2. HTTP parsing ----------

class ParsedString {
  final String method;
  final String path;
  final Map<String, String> headers;
  ParsedString(this.method, this.path, this.headers);
}

ParsedString _parseIdiomatic(Uint8List bytes) {
  final text = utf8.decode(bytes);
  final lines = text.split('\r\n');
  final first = lines[0].split(' ');
  final headers = <String, String>{};
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) break;
    final idx = line.indexOf(':');
    headers[line.substring(0, idx).toLowerCase()] =
        line.substring(idx + 1).trim();
  }
  return ParsedString(first[0], first[1], headers);
}

/// Parse result with no Map and no Strings for the method/path:
/// only offsets into the buffer. A reused object => zero allocations.
class ParsedBytes {
  int methodStart = 0, methodEnd = 0;
  int pathStart = 0, pathEnd = 0;
  int authStart = -1, authEnd = -1;
  int contentLength = 0;
  bool close = false;
  int headerEnd = -1;
}

final _parsed = ParsedBytes();

bool _ieq(Uint8List b, int s, String name) {
  for (var k = 0; k < name.length; k++) {
    if ((b[s + k] | 0x20) != name.codeUnitAt(k)) return false;
  }
  return true;
}

int _findCrlfCrlf(Uint8List b, int start) {
  final n = b.length - 3;
  for (var i = start; i < n; i++) {
    if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
      return i;
    }
  }
  return -1;
}

ParsedBytes? _parseBytes(Uint8List b, ParsedBytes out) {
  final end = _findCrlfCrlf(b, 0);
  if (end < 0) return null;
  var i = 0;
  while (i < end && b[i] != 32) {
    i++;
  }
  out.methodStart = 0;
  out.methodEnd = i;
  final ps = ++i;
  while (i < end && b[i] != 32 && b[i] != 63) {
    i++;
  }
  out.pathStart = ps;
  out.pathEnd = i;
  while (i < end && b[i] != 13) {
    i++;
  }
  i += 2;
  out.authStart = -1;
  out.contentLength = 0;
  out.close = false;
  while (i < end) {
    final ls = i;
    while (i < end && b[i] != 13) {
      i++;
    }
    final le = i;
    i += 2;
    var c = ls;
    while (c < le && b[c] != 58) {
      c++;
    }
    if (c >= le) continue;
    final nameLen = c - ls;
    var vs = c + 1;
    while (vs < le && (b[vs] == 32 || b[vs] == 9)) {
      vs++;
    }
    var ve = le;
    while (ve > vs && (b[ve - 1] == 32 || b[ve - 1] == 9)) {
      ve--;
    }
    final f = b[ls] | 0x20;
    if (nameLen == 14 && f == 0x63 && _ieq(b, ls, 'content-length')) {
      var cl = 0;
      for (var k = vs; k < ve; k++) {
        cl = cl * 10 + (b[k] - 48);
      }
      out.contentLength = cl;
    } else if (nameLen == 13 && f == 0x61 && _ieq(b, ls, 'authorization')) {
      out.authStart = vs;
      out.authEnd = ve;
    } else if (nameLen == 10 && f == 0x63 && _ieq(b, ls, 'connection')) {
      out.close = (ve - vs == 5) && _ieq(b, vs, 'close');
    }
  }
  out.headerEnd = end + 4;
  return out;
}

List<Suite> suites() {
  final asm = Suite('buffers/assemble 16x512B chunks')
    ..add('List<int> addAll (boxing)', () => blackHole(_assembleListInt()))
    ..add('Uint8List: new copy per chunk', () => blackHole(_assembleCopyEach()))
    ..add('BytesBuilder(copy:false).takeBytes()',
        () => blackHole(_assembleBytesBuilder()))
    ..add('preallocated Uint8List + sublistView (zero-copy)',
        () => blackHole(_assemblePooled()));

  final http = Suite('http/parse request (~430 B, 8 headers)')
    ..add('utf8.decode + split + Map<String,String>',
        () => blackHole(_parseIdiomatic(_request)))
    ..add('byte scan, offsets, 3 headers (zero-alloc)',
        () => blackHole(_parseBytes(_request, _parsed)));

  return [asm, http];
}
