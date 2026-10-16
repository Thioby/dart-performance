/// Guide section 1: building text and conversions.
///
///  * `+=` on String: O(n^2) copying, every concatenation is a new String.
///  * `StringBuffer`: amortized O(n), one String at the end.
///  * Interpolation: the compiler turns it into a single `String._interpolate`
///    (faster than `+`, still allocates).
///  * Bytes: writing `codeUnitAt` into a `Uint8List` skips the String object
///    entirely; when the result goes to a socket/file, that is the final
///    format anyway.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../harness.dart';

const _lines = 200;

String _concat() {
  var s = '';
  for (var i = 0; i < _lines; i++) {
    s += 'line $i: value=${i * 3}\n';
  }
  return s;
}

String _stringBuffer() {
  final sb = StringBuffer();
  for (var i = 0; i < _lines; i++) {
    sb
      ..write('line ')
      ..write(i)
      ..write(': value=')
      ..write(i * 3)
      ..write('\n');
  }
  return sb.toString();
}

Uint8List _stringBufferToUtf8() => utf8.encode(_stringBuffer());

final Uint8List _buf = Uint8List(16 * 1024);

int _writeAscii(Uint8List b, int n, String s) {
  for (var i = 0; i < s.length; i++) {
    b[n++] = s.codeUnitAt(i);
  }
  return n;
}

int _writeInt(Uint8List b, int n, int v) {
  if (v == 0) {
    b[n++] = 0x30;
    return n;
  }
  var digits = 0;
  var t = v;
  while (t > 0) {
    t ~/= 10;
    digits++;
  }
  var p = n + digits - 1;
  while (v > 0) {
    b[p--] = 0x30 + v % 10;
    v ~/= 10;
  }
  return n + digits;
}

Uint8List _bytesDirect() {
  var n = 0;
  final b = _buf;
  for (var i = 0; i < _lines; i++) {
    n = _writeAscii(b, n, 'line ');
    n = _writeInt(b, n, i);
    n = _writeAscii(b, n, ': value=');
    n = _writeInt(b, n, i * 3);
    b[n++] = 0x0a;
  }
  return Uint8List.sublistView(b, 0, n);
}

List<Suite> suites() {
  final s = Suite('strings/build 200 lines')
    ..add('String += (quadratic copying)', () => blackHole(_concat()))
    ..add('StringBuffer.write', () => blackHole(_stringBuffer()))
    ..add('StringBuffer + utf8.encode (to socket)',
        () => blackHole(_stringBufferToUtf8()))
    ..add('bytes straight into a reused Uint8List',
        () => blackHole(_bytesDirect()));
  return [s];
}
