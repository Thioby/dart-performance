---
name: dart-zero-alloc
description: Refactoring Dart code to a zero-allocation style - typed data (Uint8List/Float64List/ByteData) instead of List<Object>, Struct-of-Arrays, extension types over indices, object pools and reusable buffers, writing JSON/text directly as bytes, byte-level protocol parsing without Strings, columnar tables for large JSON payloads. Use when allocations must be removed from a frame loop, parser, serializer or socket handler, or when a profile shows frequent scavenges/GC.
---

# dart-zero-alloc — recipes for allocation-free hot paths

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory. Self-contained: works in any Dart/Flutter project.

Goal: in the hot path, **zero** new objects on the Dart heap beyond what must leave the function. Every recipe has a 🐢 (idiomatic) and 🚀 (zero-alloc) variant with a reference gain (Dart 3.13, AOT, x64). Measure in your project before and after (skill `dart-benchmark`).

## VM rules that justify this

- A `List<T>` slot = a tagged word (8 B); a `double` in a generic context = a 16 B heap object; an `int` > 2^62 = a heap Mint.
- `Float64List`/`Int32List`/`Uint8List` = raw bytes, no boxing, no write barrier (you store bytes, not pointers).
- A new-space scavenge is stop-the-world: cost ∝ number of *live* young objects + the remembered set. 10k objects per frame = jank.
- A top-level/`static final` with an initializer = a lazy getter; **copy it to a local before the loop** (~2.3×).

## Recipe 1: Struct-of-Arrays instead of `List<Obj>` (~14×)

```dart
// 🐢
class P { double x, y, vx, vy; }
final ps = <P>[];
for (final p in ps) { p.x += p.vx * dt; }

// 🚀
final x = Float64List(n), vx = Float64List(n);   // fields as separate buffers
void step(Float64List x, Float64List vx, double dt) {
  for (var i = 0; i < x.length; i++) { x[i] += vx[i] * dt; }
}
```

Mixed types → `ByteData` with offsets and a constant `Endian.little` (lets the VM fold the byte-order branch):

```dart
const rec = 16;                                  // int32 id | f64 score | u8 flags | pad
final bd = ByteData(n * rec);
int id(int i) => bd.getInt32(i * rec, Endian.little);
double score(int i) => bd.getFloat64(i * rec + 4, Endian.little);
```

An "object-like" API without objects — `extension type` over the index (Dart 3.3+):

```dart
extension type const Particle(int i) {
  double get x => _x[i]; set x(double v) => _x[i] = v;
  void step(double dt) => x += _vx[i] * dt;      // compiles to: _x[i] += _vx[i] * dt
}
```

Columnar table for records from JSON/DB: typed columns for numbers and flags, strings kept as `(offset, length)` into the original byte buffer and decoded lazily only for the rows the UI shows:

```dart
class Table {
  final Uint8List raw;                      // original payload — source for lazy string decoding
  final Int32List id, nameOff, nameLen; final Float64List score; final Uint8List flags;
  int length = 0;
  String name(int i) => String.fromCharCodes(raw, nameOff[i], nameOff[i] + nameLen[i]); // ASCII fast path; utf8.decode otherwise
}
```

## Recipe 2: Preallocation instead of `add()` (5–11×)

```dart
// 🐢
final out = <double>[]; for (...) out.add(v);
// 🚀
final out = Float64List(count); var j = 0; for (...) out[j++] = v;
// unknown count: two passes (count, fill) — still faster than growable with boxing
```

## Recipe 3: `where().map().toList()` → a loop (~4.6×)

```dart
// 🐢
final r = data.where((v) => v.isEven).map((v) => v * 2).toList();
// 🚀
var c = 0; for (var i = 0; i < data.length; i++) { if (data[i].isEven) c++; }
final r = Int32List(c); var j = 0;
for (var i = 0; i < data.length; i++) { final v = data[i]; if (v.isEven) r[j++] = v * 2; }
```

Laziness pitfall: `final evens = data.where(...)` runs the filter again on every `length`/`first`/iteration — materialize once (`toList(growable: false)`) or write the loop.

## Recipe 4: Histogram / lookup / top-N → typed arrays (~10×)

```dart
// 🐢  final m = <int,int>{}; m[k] = (m[k] ?? 0) + 1;
// 🚀  final h = Int32List(range); h[k]++;
// top-N from a large set: a min-heap of size N in an Int32List of indices instead of sorting everything
```

## Recipe 5: A reusable output buffer (ByteWriter)

```dart
class ByteWriter {
  Uint8List _buf = Uint8List(1 << 16); int _len = 0;
  void reset() => _len = 0;
  void _grow(int extra) { if (_len + extra <= _buf.length) return;
    final nb = Uint8List((_len + extra) * 2); nb.setRange(0, _len, _buf); _buf = nb; }
  void byte(int c) { _grow(1); _buf[_len++] = c; }
  void ascii(String s) { _grow(s.length); for (var i = 0; i < s.length; i++) { _buf[_len++] = s.codeUnitAt(i); } }
  void integer(int v) {                                   // digits from the end, no toString
    if (v == 0) { byte(0x30); return; }
    if (v < 0) { byte(0x2d); v = -v; }
    var digits = 0; for (var t = v; t > 0; t ~/= 10) { digits++; }
    _grow(digits); var p = _len + digits - 1;
    while (v > 0) { _buf[p--] = 0x30 + v % 10; v ~/= 10; }
    _len += digits;
  }
  void jsonString(Uint8List s) {                          // escape only " \ and < 0x20
    _grow(s.length * 6 + 2); final b = _buf; var n = _len; b[n++] = 0x22;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c >= 0x20 && c != 0x22 && c != 0x5c) { b[n++] = c; }
      else if (c == 0x22 || c == 0x5c) { b[n++] = 0x5c; b[n++] = c; }
      else { const hex = '0123456789abcdef'; b[n++] = 0x5c; b[n++] = 0x75; b[n++] = 0x30; b[n++] = 0x30;
             b[n++] = hex.codeUnitAt(c >> 4); b[n++] = hex.codeUnitAt(c & 15); }
    }
    b[n++] = 0x22; _len = n;
  }
  Uint8List view() => Uint8List.sublistView(_buf, 0, _len);   // valid until reset()
}
```

One instance per isolate/connection/painter. Send `view()` to the socket / `canvas` / FFI; copy only when it must outlive `reset()`. Reference: a 20-record JSON response → ~6.5 µs vs ~60 µs for `jsonEncode`+`utf8.encode` (~9×). If the strings came in as JSON, they are already escaped — copy the raw bytes verbatim.

## Recipe 6: JSON as bytes without your own writer (~1.6×)

```dart
final _enc = JsonUtf8Encoder();                   // once
final Uint8List bytes = _enc.convert(obj) as Uint8List;
final _dec = utf8.decoder.fuse(json.decoder);     // once
final v = _dec.convert(bytes);
```

Know the limit: on a 10k-record payload the fused decoder gives ~30 %; the tree and `fromJson` cost the rest. For one high-volume endpoint, a byte scanner straight into a columnar table (recipe 1) gives ~7× end-to-end: recognize keys by length + first byte, parse numbers/dates by hand, store strings as offsets, `skipValue()` for unknown fields, validate against `jsonDecode` with a differential test.

## Recipe 7: Assembling chunks from a stream (100–400×)

```dart
// 🐢  buf = Uint8List(buf.length + data.length)..setRange(...)   // a copy per chunk, O(n^2)
// 🚀 a) unknown size:
final bb = BytesBuilder(copy: false); stream.listen(bb.add); final all = bb.takeBytes();
// 🚀 b) known upper bound (framed protocol): preallocated buffer + offset
final buf = Uint8List(1 << 16); var n = 0;
void onData(Uint8List d) {
  buf.setRange(n, n + d.length, d); n += d.length;
  final used = parse(Uint8List.sublistView(buf, 0, n));            // consumed bytes
  if (used > 0) { buf.setRange(0, n - used, buf, used); n -= used; }  // memmove the tail, in place
}
```

## Recipe 8: Byte-level protocol parser (~4×)

Do not decode to a `String`. Compare header/key names by length and first byte, then a case-insensitive byte compare via `| 0x20`. The result is offsets in a reused object/`Int32List`, not a `Map<String,String>`.

```dart
bool _ieq(Uint8List b, int s, String name) {
  for (var k = 0; k < name.length; k++) { if ((b[s + k] | 0x20) != name.codeUnitAt(k)) return false; }
  return true;
}
if (nameLen == 14 && (b[ls] | 0x20) == 0x63 /* c */ && _ieq(b, ls, 'content-length')) { ... }
```

## Recipe 9: Strings

- `s += x` in a loop → `StringBuffer` (~3.6×). When the result goes to I/O → bytes right away (~10×).
- `substring` copies (the Dart VM has no sliced strings) — keep offsets into the original.
- ASCII from bytes: `String.fromCharCodes(bytes, start, end)` beats `utf8.decode` for pure ASCII (check `(c & ~0x7F) == 0` first).
- `toLowerCase()` for comparison allocates — compare via `| 0x20`.

## Recipe 10: Constants and `const`

Everything constant for the program's lifetime — `const` (zero allocation, old space, no write barrier). Error responses, headers, `EdgeInsets`, `TextStyle`, empty lists `const []`. Readers/converters as `const` objects.

## Recipe 11: Object pool when objects cannot be flattened

```dart
class TouchEvent { double x = 0, y = 0; }
final _pool = List.generate(256, (_) => TouchEvent(), growable: false);
var _used = 0;
TouchEvent acquire() => _pool[_used++];              // grow/throw when _used == length
void endFrame() => _used = 0;                         // "release" everything with one assignment
```

Works the same for `Paint`, `Path` (`path.reset()`), `TextPainter`, `Uint8List` buffers.

## Verification

1. `dart run --observe` / `flutter run --profile` → DevTools → Memory → Allocation tracing: the class you removed should disappear from the list.
2. A microbenchmark before/after, JIT **and** AOT (skill `dart-benchmark`).
3. To be sure a double is unboxed / there is no `CheckSmi`: `dart compile exe --extra-gen-snapshot-options=--print-flow-graph-optimized,--disassemble --extra-gen-snapshot-options=--print-flow-graph-filter=functionName`.

## When NOT to apply this

One-off code, collections < ~100 elements, UI layers outside the frame loop, tests. Zero-alloc costs readability — limit it to measured hot paths and enclose it in one well-named class (`ByteWriter`, `FrameBuffer`, `ParticleStore`, `UserTable`).

Background reading with runnable benchmarks: https://github.com/Thioby/dart-performance
