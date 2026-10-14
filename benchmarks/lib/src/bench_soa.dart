/// Sekcja 1 przewodnika: Array-of-Structs (`List<Particle>`) vs
/// Struct-of-Arrays (`Float64List` x, y, vx, vy) — typowa pętla animacji
/// / symulacji fizyki wykonywana co klatkę (120 FPS = 8.3 ms budżetu).
///
/// AoS: każdy `Particle` to obiekt na stercie z 4 polami. W AOT pola `double`
/// są unboxowane wewnątrz obiektu, ale sam dostęp wymaga dereferencji
/// wskaźnika z listy -> losowy dostęp do pamięci, słaba lokalność cache.
/// SoA: 4 ciągłe bufory, pętla wektoryzowalna, zero wskaźników.
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

/// Jeden płaski bufor z "polami" pod stałymi offsetami (jak struct w C).
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

/// Najgorszy wariant: idiomatyczny, "immutable", alokuje nowy obiekt
/// na każdą cząstkę w każdej klatce (10k alokacji / klatkę -> GC jank).
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
  final s = Suite('soa/particles (10k cząstek, 1 klatka)')
    ..add('List<Particle> map().toList() (alokuje 10k obj/klatkę)', () {
      frame = _stepAoSImmutable(frame, 1 / 120);
      blackHole(frame);
    })
    ..add('List<Particle> mutacja w miejscu (AoS)', () => _stepAoS(1 / 120))
    ..add('4x Float64List (SoA)', () => _stepSoA(1 / 120), setup: _init)
    ..add('1x Float64List ze stride (flat struct)', () => _stepFlat(1 / 120));
  return [s];
}
