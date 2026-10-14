/// Sekcja 1 i 5 przewodnika: idiomatyczne łańcuchy kolekcji vs pętle.
///
/// `list.where(...).map(...).toList()` tworzy 2 leniwe iterable, 2 iteratory,
/// closure'y i rosnącą listę wynikową. Jedna pętla `for` z prealokowaną listą
/// robi to samo bez obiektów pośrednich. Podobnie `fold`/`reduce` vs pętla,
/// `List.from` vs `toList(growable:false)`, `Map` z kluczem String vs
/// `Int32List` jako tablica przeglądowa.
library;

import 'dart:typed_data';

import '../harness.dart';

const _n = 10_000;
final List<int> _data = List.generate(_n, (i) => (i * 7919) % 1000);

List<int> _chain() => _data.where((v) => v.isEven).map((v) => v * 2).toList();

List<int> _loop() {
  final out = <int>[];
  for (var i = 0; i < _data.length; i++) {
    final v = _data[i];
    if (v.isEven) out.add(v * 2);
  }
  return out;
}

Int32List _loopTyped() {
  // Dwa przebiegi: policz, potem wypełnij (brak realokacji, brak boxingu).
  var count = 0;
  for (var i = 0; i < _data.length; i++) {
    if (_data[i].isEven) count++;
  }
  final out = Int32List(count);
  var j = 0;
  for (var i = 0; i < _data.length; i++) {
    final v = _data[i];
    if (v.isEven) out[j++] = v * 2;
  }
  return out;
}

int _foldSum() => _data.fold<int>(0, (a, b) => a + b);
int _reduceSum() => _data.reduce((a, b) => a + b);
int _loopSum() {
  var s = 0;
  for (var i = 0; i < _data.length; i++) {
    s += _data[i];
  }
  return s;
}

// Zliczanie wystąpień: Map<int,int> vs Int32List jako histogram.
Map<int, int> _histMap() {
  final m = <int, int>{};
  for (var i = 0; i < _data.length; i++) {
    m[_data[i]] = (m[_data[i]] ?? 0) + 1;
  }
  return m;
}

Int32List _histTyped() {
  final h = Int32List(1000);
  for (var i = 0; i < _data.length; i++) {
    h[_data[i]]++;
  }
  return h;
}

List<Suite> suites() {
  final filter = Suite('collections/filter+map 10k')
    ..add('where().map().toList()', () => blackHole(_chain()))
    ..add('pętla for + List.add', () => blackHole(_loop()))
    ..add(
        '2 pętle + Int32List (zero realokacji)', () => blackHole(_loopTyped()));

  final sum = Suite('collections/sum 10k')
    ..add('fold()', () => blackHole(_foldSum()))
    ..add('reduce()', () => blackHole(_reduceSum()))
    ..add('pętla for', () => blackHole(_loopSum()));

  final hist = Suite('collections/histogram 10k wartości 0..999')
    ..add('Map<int,int>', () => blackHole(_histMap()))
    ..add(
        'Int32List[1000] jako tablica zliczeń', () => blackHole(_histTyped()));

  return [filter, sum, hist];
}
