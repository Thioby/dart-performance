/// Guide section 1: `List<int>` / `List<double>` vs `dart:typed_data`
/// and the trap of lazily initialized global fields.
///
/// Why is `List<int>` slow? An element of a generic list is always a tagged
/// pointer (8 bytes). Small ints (Smi, 63-bit on x64) fit in the tag, but
/// `List<int>` still takes 8 B/element and every operation goes through a
/// tag check. `List<double>` is worse: every double is a separate heap object
/// (boxing) -> GC, cache misses.
/// `Float64List`/`Int32List`/`Uint8List` is a contiguous block of bytes with
/// no boxing; AOT/JIT reads/writes it with a single load/store instruction.
///
/// TRAP: a `final x = ...;` at library level (top-level) or `static` is
/// initialized lazily. Every read of `x` in a hot loop is a getter call with
/// an "already initialized?" check. Always copy such a reference into a local
/// variable before the loop (`final l = _f64;`).
library;

import 'dart:typed_data';

import '../harness.dart';

const _n = 1 << 16; // 65 536 elements

final List<int> _listInt = List<int>.generate(_n, (i) => i & 0xff);
final Uint8List _u8 = Uint8List.fromList(_listInt);
final Int32List _i32 = Int32List.fromList(_listInt);
final Int64List _i64 = Int64List.fromList(_listInt);
final List<double> _listDouble = List<double>.generate(_n, (i) => i * 0.5);
final Float64List _f64 = Float64List.fromList(_listDouble);

int _sumListInt(List<int> l) {
  var s = 0;
  for (var i = 0; i < l.length; i++) {
    s += l[i];
  }
  return s;
}

int _sumListIntForIn(List<int> l) {
  var s = 0;
  for (final v in l) {
    s += v;
  }
  return s;
}

int _sumU8(Uint8List l) {
  var s = 0;
  for (var i = 0; i < l.length; i++) {
    s += l[i];
  }
  return s;
}

int _sumI32(Int32List l) {
  var s = 0;
  for (var i = 0; i < l.length; i++) {
    s += l[i];
  }
  return s;
}

int _sumI64(Int64List l) {
  var s = 0;
  for (var i = 0; i < l.length; i++) {
    s += l[i];
  }
  return s;
}

double _sumListDouble(List<double> l) {
  var s = 0.0;
  for (var i = 0; i < l.length; i++) {
    s += l[i];
  }
  return s;
}

double _sumF64(Float64List l) {
  var s = 0.0;
  for (var i = 0; i < l.length; i++) {
    s += l[i];
  }
  return s;
}

/// Deliberately reads the top-level `_f64` on every iteration (lazy getter).
double _sumF64ViaGlobal() {
  var s = 0.0;
  for (var i = 0; i < _f64.length; i++) {
    s += _f64[i];
  }
  return s;
}

/// Building a list: growable `List<int>` with `add` vs a preallocated
/// `Int32List`.
List<int> _buildGrowable() {
  final out = <int>[];
  for (var i = 0; i < _n; i++) {
    out.add(i);
  }
  return out;
}

List<int> _buildFilled() {
  final out = List<int>.filled(_n, 0);
  for (var i = 0; i < _n; i++) {
    out[i] = i;
  }
  return out;
}

Int32List _buildTyped() {
  final out = Int32List(_n);
  for (var i = 0; i < _n; i++) {
    out[i] = i;
  }
  return out;
}

/// Boxing double: `List<double>.add` allocates a Double object per element.
List<double> _buildGrowableDouble() {
  final out = <double>[];
  for (var i = 0; i < _n; i++) {
    out.add(i * 0.25);
  }
  return out;
}

Float64List _buildTypedDouble() {
  final out = Float64List(_n);
  for (var i = 0; i < _n; i++) {
    out[i] = i * 0.25;
  }
  return out;
}

List<Suite> suites() {
  final sumInt = Suite('typed_lists/sum int (65k elements)')
    ..add('List<int> indexed loop', () => blackHole(_sumListInt(_listInt)))
    ..add('List<int> for-in', () => blackHole(_sumListIntForIn(_listInt)))
    ..add('Int64List indexed loop', () => blackHole(_sumI64(_i64)))
    ..add('Int32List indexed loop', () => blackHole(_sumI32(_i32)))
    ..add('Uint8List indexed loop', () => blackHole(_sumU8(_u8)));

  final sumDouble = Suite('typed_lists/sum double (65k elements)')
    ..add('List<double> indexed loop (boxed)',
        () => blackHole(_sumListDouble(_listDouble)))
    ..add('Float64List via top-level final (lazy getter in loop)',
        () => blackHole(_sumF64ViaGlobal()))
    ..add('Float64List passed as parameter/local',
        () => blackHole(_sumF64(_f64)));

  final build = Suite('typed_lists/build (65k elements)')
    ..add('List<int> growable add()', () => blackHole(_buildGrowable()))
    ..add('List<int>.filled preallocated', () => blackHole(_buildFilled()))
    ..add('Int32List preallocated', () => blackHole(_buildTyped()))
    ..add('List<double> growable add() (boxing)',
        () => blackHole(_buildGrowableDouble()))
    ..add('Float64List preallocated', () => blackHole(_buildTypedDouble()));

  return [sumInt, sumDouble, build];
}
