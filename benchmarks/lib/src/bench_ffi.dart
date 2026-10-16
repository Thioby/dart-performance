/// Guide section 2: `dart:ffi` with minimal overhead.
///
/// Every "non-leaf" FFI call switches the VM thread state (Dart -> native
/// transition: saving state, a possible GC safepoint) and back.
/// `isLeaf: true` tells the VM: "this C function is short, does not call back
/// into Dart, does not block" — the VM skips the thread state transition,
/// which for functions taking nanoseconds yields a severalfold speedup.
///
/// `Pointer<Double>.asTypedList(n)` creates a `Float64List` that is a view
/// over native memory with no copy; the alternative (`List.generate` +
/// `ptr[i]`) copies and boxes.
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
    stderr.writeln('[ffi] missing $path — run tool/build_native.sh; skipping');
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

/// Copying from native memory into Dart via `ptr[i]` (slow).
List<int> _readCopyIndexed() {
  final out = List<int>.filled(4096, 0);
  for (var i = 0; i < 4096; i++) {
    out[i] = _pbuf[i];
  }
  return out;
}

/// A view with no copy.
Uint8List _readView() => _pbuf.asTypedList(4096);

/// A copy via the view (when we need our own buffer): a single memcpy.
Uint8List _readCopyView() => Uint8List.fromList(_pbuf.asTypedList(4096));

/// Native allocation per call vs Arena vs a reused buffer.
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
    ..add('pure Dart a+b (reference)', () => blackHole(_addPureDart(3, 4)))
    ..add('FFI non-leaf', () => blackHole(_addNonLeaf(3, 4)))
    ..add('FFI isLeaf: true', () => blackHole(_addLeaf(3, 4)));

  final dot = Suite('ffi/dot product 1024 double')
    ..add('pure Dart on Float64List (asTypedList view)',
        () => blackHole(_dotPureDart()))
    ..add('C dot_f64 via FFI isLeaf', () => blackHole(_dotLeaf(_pa, _pb, _n)));

  final read = Suite('ffi/read 4 KB from Pointer<Uint8>')
    ..add('ptr[i] into List<int> (4096 calls)',
        () => blackHole(_readCopyIndexed()))
    ..add('Uint8List.fromList(asTypedList) (1 memcpy)',
        () => blackHole(_readCopyView()))
    ..add('asTypedList view (zero-copy)', () => blackHole(_readView()));

  final alloc = Suite('ffi/fill 256 B: native allocation')
    ..add('malloc + free per call', () => blackHole(_mallocPerCall()))
    ..add('Arena (using) per call', () => blackHole(_arenaPerCall()))
    ..add('reused buffer (zero-alloc)', () => blackHole(_reusedBuffer()))
    ..add('reused buffer, non-leaf',
        () => blackHole(_fillNonLeaf(_pbuf, 256, 7)));

  return [call, dot, read, alloc];
}
