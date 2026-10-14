/// Sekcja 2 przewodnika: `dart:ffi` z minimalnym narzutem.
///
/// Każde wywołanie FFI "non-leaf" przełącza stan wątku VM (Dart -> native
/// transition: zapis stanu, możliwość safepointu dla GC) i wraca.
/// `isLeaf: true` mówi VM: "ta funkcja C jest krótka, nie woła z powrotem do
/// Darta, nie blokuje" — VM pomija przejście stanu wątku, co dla funkcji
/// trwających nanosekundy daje kilkukrotne przyspieszenie.
///
/// `Pointer<Double>.asTypedList(n)` tworzy `Float64List` będący widokiem na
/// pamięć natywną bez kopii; alternatywa (`List.generate` + `ptr[i]`) kopiuje
/// i boksuje.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../harness.dart';

typedef _AddC = Int64 Function(Int64, Int64);
typedef _AddDart = int Function(int, int);
typedef _DotC = Double Function(Pointer<Double>, Pointer<Double>, Int64);
typedef _DotDart = double Function(Pointer<Double>, Pointer<Double>, int);
typedef _FillC = Int64 Function(Pointer<Uint8>, Int64, Uint8);
typedef _FillDart = int Function(Pointer<Uint8>, int, int);

late final DynamicLibrary _lib;
late final _AddDart _addLeaf;
late final _AddDart _addNonLeaf;
late final _DotDart _dotLeaf;
late final _FillDart _fillLeaf;
late final _FillDart _fillNonLeaf;

const _n = 1024;
late final Pointer<Double> _pa;
late final Pointer<Double> _pb;
late final Pointer<Uint8> _pbuf;
late final Float64List _va;
late final Float64List _vb;

bool setupFfi() {
  final path = '${Directory.current.path}/native/libfastmath.so';
  if (!File(path).existsSync()) {
    stderr.writeln('[ffi] brak $path — uruchom tool/build_native.sh; pomijam');
    return false;
  }
  _lib = DynamicLibrary.open(path);
  _addLeaf = _lib.lookupFunction<_AddC, _AddDart>('add_i64', isLeaf: true);
  _addNonLeaf = _lib.lookupFunction<_AddC, _AddDart>('add_i64');
  _dotLeaf = _lib.lookupFunction<_DotC, _DotDart>('dot_f64', isLeaf: true);
  _fillLeaf = _lib.lookupFunction<_FillC, _FillDart>('fill_u8', isLeaf: true);
  _fillNonLeaf = _lib.lookupFunction<_FillC, _FillDart>('fill_u8');
  _pa = calloc<Double>(_n);
  _pb = calloc<Double>(_n);
  _pbuf = calloc<Uint8>(4096);
  _va = _pa.asTypedList(_n);
  _vb = _pb.asTypedList(_n);
  for (var i = 0; i < _n; i++) {
    _va[i] = i * 0.5;
    _vb[i] = 1.0 / (i + 1);
  }
  return true;
}

int _addPureDart(int a, int b) => a + b;

double _dotPureDart() {
  var s = 0.0;
  for (var i = 0; i < _n; i++) {
    s += _va[i] * _vb[i];
  }
  return s;
}

/// Kopiowanie z pamięci natywnej do Darta przez `ptr[i]` (wolno).
List<int> _readCopyIndexed() {
  final out = List<int>.filled(4096, 0);
  for (var i = 0; i < 4096; i++) {
    out[i] = _pbuf[i];
  }
  return out;
}

/// Widok bez kopii.
Uint8List _readView() => _pbuf.asTypedList(4096);

/// Kopia przez widok (gdy musimy mieć własny bufor): jedna memcpy.
Uint8List _readCopyView() => Uint8List.fromList(_pbuf.asTypedList(4096));

/// Alokacja natywna per wywołanie vs Arena vs reużywany bufor.
int _mallocPerCall() {
  final p = malloc<Uint8>(256);
  final s = _fillLeaf(p, 256, 7);
  malloc.free(p);
  return s;
}

int _arenaPerCall() {
  return using((Arena arena) {
    final p = arena<Uint8>(256);
    return _fillLeaf(p, 256, 7);
  });
}

int _reusedBuffer() => _fillLeaf(_pbuf, 256, 7);

List<Suite> suites() {
  final call = Suite('ffi/call add(a,b)')
    ..add('czysty Dart a+b (referencja)', () => blackHole(_addPureDart(3, 4)))
    ..add('FFI non-leaf', () => blackHole(_addNonLeaf(3, 4)))
    ..add('FFI isLeaf: true', () => blackHole(_addLeaf(3, 4)));

  final dot = Suite('ffi/dot product 1024 double')
    ..add('czysty Dart na Float64List (widok asTypedList)',
        () => blackHole(_dotPureDart()))
    ..add(
        'C dot_f64 przez FFI isLeaf', () => blackHole(_dotLeaf(_pa, _pb, _n)));

  final read = Suite('ffi/read 4 KB z Pointer<Uint8>')
    ..add('ptr[i] do List<int> (4096 wywołań)',
        () => blackHole(_readCopyIndexed()))
    ..add('Uint8List.fromList(asTypedList) (1 memcpy)',
        () => blackHole(_readCopyView()))
    ..add('asTypedList widok (zero-copy)', () => blackHole(_readView()));

  final alloc = Suite('ffi/fill 256 B: alokacja natywna')
    ..add('malloc + free per wywołanie', () => blackHole(_mallocPerCall()))
    ..add('Arena (using) per wywołanie', () => blackHole(_arenaPerCall()))
    ..add('reużywany bufor (zero-alloc)', () => blackHole(_reusedBuffer()))
    ..add('reużywany bufor, non-leaf',
        () => blackHole(_fillNonLeaf(_pbuf, 256, 7)));

  return [call, dot, read, alloc];
}
