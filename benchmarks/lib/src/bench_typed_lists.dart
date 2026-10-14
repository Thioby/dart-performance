/// Sekcja 1 przewodnika: `List<int>` / `List<double>` vs `dart:typed_data`
/// oraz pułapka leniwie inicjalizowanych pól globalnych.
///
/// Dlaczego `List<int>` jest wolne? Element listy generycznej to zawsze
/// tagowany wskaźnik (8 bajtów). Małe inty (Smi, 63-bit na x64) mieszczą się
/// w tagu, ale `List<int>` i tak zajmuje 8 B/element i każda operacja
/// przechodzi przez sprawdzenie tagu. `List<double>` jest gorsze:
/// każdy double to osobny obiekt na stercie (boxing) -> GC, cache misses.
/// `Float64List`/`Int32List`/`Uint8List` to ciągły blok bajtów bez boxingu;
/// AOT/JIT czyta/zapisuje je jedną instrukcją load/store.
///
/// PUŁAPKA: `final x = ...;` na poziomie biblioteki (top-level) lub `static`
/// jest inicjalizowane leniwie. Każdy odczyt `x` w gorącej pętli to wywołanie
/// gettera ze sprawdzeniem "czy już zainicjalizowane". Zawsze kopiuj taką
/// referencję do zmiennej lokalnej przed pętlą (`final l = _f64;`).
library;

import 'dart:typed_data';

import '../harness.dart';

const _n = 1 << 16; // 65 536 elementów

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

/// Celowo czyta top-level `_f64` w każdej iteracji (leniwy getter).
double _sumF64ViaGlobal() {
  var s = 0.0;
  for (var i = 0; i < _f64.length; i++) {
    s += _f64[i];
  }
  return s;
}

/// Budowanie listy: growable `List<int>` z `add` vs prealokowany `Int32List`.
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

/// Boxing double: `List<double>.add` alokuje obiekt Double na każdy element.
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
  final sumInt = Suite('typed_lists/sum int (65k elementów)')
    ..add('List<int> indexed loop', () => blackHole(_sumListInt(_listInt)))
    ..add('List<int> for-in', () => blackHole(_sumListIntForIn(_listInt)))
    ..add('Int64List indexed loop', () => blackHole(_sumI64(_i64)))
    ..add('Int32List indexed loop', () => blackHole(_sumI32(_i32)))
    ..add('Uint8List indexed loop', () => blackHole(_sumU8(_u8)));

  final sumDouble = Suite('typed_lists/sum double (65k elementów)')
    ..add('List<double> indexed loop (boxed)',
        () => blackHole(_sumListDouble(_listDouble)))
    ..add('Float64List przez top-level final (leniwy getter w pętli)',
        () => blackHole(_sumF64ViaGlobal()))
    ..add('Float64List przekazana jako parametr/lokalna',
        () => blackHole(_sumF64(_f64)));

  final build = Suite('typed_lists/build (65k elementów)')
    ..add('List<int> growable add()', () => blackHole(_buildGrowable()))
    ..add('List<int>.filled prealokowana', () => blackHole(_buildFilled()))
    ..add('Int32List prealokowana', () => blackHole(_buildTyped()))
    ..add('List<double> growable add() (boxing)',
        () => blackHole(_buildGrowableDouble()))
    ..add('Float64List prealokowana', () => blackHole(_buildTypedDouble()));

  return [sumInt, sumDouble, build];
}
