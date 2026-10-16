/// Guide section 1: Array-of-Structs (`List<Particle>`) vs
/// Struct-of-Arrays (`Float64List` x, y, vx, vy) — a typical animation /
/// physics simulation loop executed every frame (120 FPS = 8.3 ms budget).
///
/// AoS: every `Particle` is a heap object with 4 fields. In AOT the `double`
/// fields are unboxed inside the object, but the access itself requires
/// dereferencing a pointer from the list -> random memory access, poor cache
/// locality.
/// SoA: 4 contiguous buffers, a vectorizable loop, zero pointers.
library;

import 'dart:typed_data';

import '../harness.dart';

const _count = 10_000;

class Particle {
  double x, y, vx, vy;
  Particle(this.x, this.y, this.vx, this.vy);
}

final List<Particle> _aos = List.generate(
  _count,
  (i) => Particle(i.toDouble(), i * 2.0, 0.5, -0.25),
);

final Float64List _x = Float64List(_count);
final Float64List _y = Float64List(_count);
final Float64List _vx = Float64List(_count);
final Float64List _vy = Float64List(_count);

/// One flat buffer with "fields" at fixed offsets (like a C struct).
const _stride = 4;
final Float64List _flat = Float64List(_count * _stride);

void _init() {
  for (var i = 0; i < _count; i++) {
    _x[i] = i.toDouble();
    _y[i] = i * 2.0;
    _vx[i] = 0.5;
    _vy[i] = -0.25;
    _flat[i * _stride + 0] = i.toDouble();
    _flat[i * _stride + 1] = i * 2.0;
    _flat[i * _stride + 2] = 0.5;
    _flat[i * _stride + 3] = -0.25;
  }
}

void _stepAoS(double dt) {
  for (var i = 0; i < _aos.length; i++) {
    final p = _aos[i];
    p.x += p.vx * dt;
    p.y += p.vy * dt;
    if (p.y < 0) {
      p.y = 0;
      p.vy = -p.vy;
    }
  }
}

/// Worst variant: idiomatic, "immutable", allocates a new object
/// per particle every frame (10k allocations / frame -> GC jank).
List<Particle> _stepAoSImmutable(List<Particle> src, double dt) {
  return src
      .map((p) => Particle(p.x + p.vx * dt, p.y + p.vy * dt, p.vx, p.vy))
      .toList(growable: false);
}

void _stepSoA(double dt) {
  final x = _x, y = _y, vx = _vx, vy = _vy;
  for (var i = 0; i < _count; i++) {
    x[i] += vx[i] * dt;
    var ny = y[i] + vy[i] * dt;
    if (ny < 0) {
      ny = 0;
      vy[i] = -vy[i];
    }
    y[i] = ny;
  }
}

void _stepFlat(double dt) {
  final f = _flat;
  for (var i = 0; i < _count * _stride; i += _stride) {
    f[i] += f[i + 2] * dt;
    var ny = f[i + 1] + f[i + 3] * dt;
    if (ny < 0) {
      ny = 0;
      f[i + 3] = -f[i + 3];
    }
    f[i + 1] = ny;
  }
}

List<Suite> suites() {
  var frame = _aos;
  final s = Suite('soa/particles (10k particles, 1 frame)')
    ..add('List<Particle> map().toList() (allocates 10k obj/frame)', () {
      frame = _stepAoSImmutable(frame, 1 / 120);
      blackHole(frame);
    })
    ..add('List<Particle> in-place mutation (AoS)', () => _stepAoS(1 / 120))
    ..add('4x Float64List (SoA)', () => _stepSoA(1 / 120), setup: _init)
    ..add('1x Float64List with stride (flat struct)', () => _stepFlat(1 / 120));
  return [s];
}
