---
name: dart-zero-alloc
description: Refactoring Dart code to a zero-allocation style - typed data (Uint8List/Float64List/ByteData) instead of List<Object>, Struct-of-Arrays, pools and reusable buffers, writing JSON/text directly as bytes, byte-level protocol parsing without Strings. Use when allocations must be removed from a frame loop, parser, serializer or socket handler, or when a profile shows frequent scavenges/GC.
---

# dart-zero-alloc — recipes for allocation-free hot paths

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory.

Goal: in the hot path, **zero** new objects on the Dart heap beyond what must leave the function. Every recipe has a 🐢 (idiomatic) and 🚀 (zero-alloc) variant, measured in `benchmarks/` (AOT, Dart 3.13). Theory: `docs/en/dart-flutter-extreme-performance-guide.md` §1. A complete worked example (10k users from JSON, 7.8× end-to-end): `packages/users_pipeline/`.

## VM rules that justify this

- A `List<T>` slot = a tagged word (8 B); a `double` in a generic context = a 16 B heap object; an `int` > 2^62 = a heap Mint.
- `Float64List`/`Int32List`/`Uint8List` = raw bytes, no boxing, no write barrier (you store bytes, not pointers).
- A new-space scavenge is stop-the-world: cost ∝ number of *live* young objects + the remembered set. 10k objects per frame = jank.
- A top-level/`static final` with an initializer = a lazy getter; **copy it to a local before the loop**.

## Recipe 1: Struct-of-Arrays instead of `List<Obj>` (14×)

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

Mixed types → `ByteData` with offsets and a constant `Endian.little`:

```dart
const rec = 16;                                  // int32 id | f64 score | u8 flags | pad
final bd = ByteData(n * rec);
int id(int i) => bd.getInt32(i * rec, Endian.little);
double score(int i) => bd.getFloat64(i * rec + 4, Endian.little);
```

When you want an "object-like" API, use an `extension type` over the index (zero allocation, readable code):

```dart
extension type const Particle(int i) {
  double get x => _x[i]; set x(double v) => _x[i] = v;
}
```

Columnar table for records from JSON/DB (`packages/users_pipeline/lib/src/columnar.dart`): typed columns for numbers/flags, strings as `(offset, length)` into the original byte buffer, decoded lazily only for the rows the UI shows.

## Recipe 2: Preallocation instead of `add()` (5–11×)

```dart
// 🐢
final out = <double>[]; for (...) out.add(v);
// 🚀
final out = Float64List(count); var j = 0; for (...) out[j++] = v;
// unknown count: two passes (count, fill) — still faster than growable with boxing
```

## Recipe 3: `where().map().toList()` → a loop (4.6×)

```dart
// 🐢
final r = data.where((v) => v.isEven).map((v) => v * 2).toList();
// 🚀
var c = 0; for (var i = 0; i < data.length; i++) { if (data[i].isEven) c++; }
final r = Int32List(c); var j = 0;
for (var i = 0; i < data.length; i++) { final v = data[i]; if (v.isEven) r[j++] = v * 2; }
```

## Recipe 4: Histogram / lookup → typed array (10.8×)

```dart
// 🐢  final m = <int,int>{}; m[k] = (m[k] ?? 0) + 1;
// 🚀  final h = Int32List(range); h[k]++;
```

Top-N from a large set: a min-heap of size N in an `Int32List` instead of sorting everything (`queryColumnar` in `pipeline_fast.dart`).

## Recipe 5: A reusable output buffer (ByteWriter)

```dart
class ByteWriter {
  Uint8List _buf = Uint8List(1 << 16); int _len = 0;
  void reset() => _len = 0;
  void _grow(int extra) { if (_len + extra <= _buf.length) return;
    final nb = Uint8List((_len + extra) * 2); nb.setRange(0, _len, _buf); _buf = nb; }
  void ascii(String s) { _grow(s.length); for (var i = 0; i < s.length; i++) _buf[_len++] = s.codeUnitAt(i); }
  void byte(int c) { _grow(1); _buf[_len++] = c; }
  void integer(int v) { /* digits from the end, no toString — see benchmarks/lib/src/bench_json.dart */ }
  void jsonString(Uint8List utf8) { /* escape only " \ and < 0x20; copy the rest byte by byte */ }
  Uint8List view() => Uint8List.sublistView(_buf, 0, _len);   // valid until reset()
}
```

One instance per isolate/connection/painter. Send `view()` to the socket / `canvas` / FFI; copy (`Uint8List.fromList(view())`) only when it must outlive `reset()`. Benchmark: a 20-post feed → 6.5 µs vs 60 µs for `jsonEncode`+`utf8.encode` (9.3×). If the strings came in as JSON, they are already escaped: copy the raw bytes verbatim (`rawString` in `pipeline_fast.dart`).

## Recipe 6: JSON as bytes without your own writer (1.6×)

```dart
final _enc = JsonUtf8Encoder();                   // once
final Uint8List bytes = _enc.convert(obj) as Uint8List;
final _dec = utf8.decoder.fuse(json.decoder);     // once
final v = _dec.convert(bytes);
```

Know the limit: on 10k users the fused decoder gives 76 → 54 ms; the tree and `fromJson` cost the rest. For one high-volume endpoint, a byte scanner into columns (`json_scanner.dart`) gives 12 ms.

## Recipe 7: Assembling chunks from a stream (100–400×)

```dart
// 🐢  buf = Uint8List(buf.length + data.length)..setRange(...)   // a copy per chunk, O(n^2)
// 🚀 a) unknown size:
final bb = BytesBuilder(copy: false); stream.listen(bb.add); final all = bb.takeBytes();
// 🚀 b) known upper bound (framed protocol): preallocated buffer + offset
final buf = Uint8List(1 << 16); var n = 0;
void onData(Uint8List d) { buf.setRange(n, n + d.length, d); n += d.length; parse(Uint8List.sublistView(buf, 0, n)); }
```

After parsing a frame, shift the remainder with `buf.setRange(0, n - used, buf, used)` (an in-place memmove) instead of creating a new buffer.

## Recipe 8: Byte-level protocol parser (4×)

Do not decode to a `String`. Compare header names by length and first byte, then `_ieq` (case-insensitive via `| 0x20`). The result is offsets in a reused object/`Int32List`, not a `Map<String,String>`. Templates: `_parseBytes` in `benchmarks/lib/src/bench_buffers.dart`, `keyCode` in `packages/users_pipeline/lib/src/json_scanner.dart`, `_parseHead` in `dart-rawsocket-C-Hatton/bin/server.dart`.

```dart
if (nameLen == 14 && (b[ls] | 0x20) == 0x63 /* c */ && _ieq(b, ls, 'content-length')) { ... }
```

## Recipe 9: Strings

- `s += x` in a loop → `StringBuffer` (3.6×). When the result goes to I/O → bytes right away (10×).
- `substring` copies (the Dart VM has no sliced strings) — keep offsets into the original.
- ASCII from bytes: `String.fromCharCodes(bytes, start, end)` beats `utf8.decode` for pure ASCII (check `(c & ~0x7F) == 0` like FlatBuffers' `_tryWriteASCIIString`).

## Recipe 10: Constants and `const`

Everything constant for the program's lifetime — `const` (zero allocation, old space, no write barrier). Error responses, headers, `EdgeInsets`, `TextStyle`, empty lists `const []`. Readers/converters as `const` objects (FlatBuffers: "read speed up by about 10 % … `const` constructors of FB readers").

## Verification

1. `dart run --observe` → DevTools → Memory → Allocation tracing: the class you removed should disappear from the list.
2. A benchmark with `benchmarks/lib/harness.dart` (`Suite`, `blackHole`) — before/after, JIT **and** AOT (`tool/run.sh`).
3. To be sure a double is unboxed / there is no `CheckSmi`: `dart compile exe --extra-gen-snapshot-options=--print-flow-graph-optimized,--disassemble --extra-gen-snapshot-options=--print-flow-graph-filter=functionName`.

## When NOT to apply this

One-off code, collections < ~100 elements, UI layers outside the frame loop, tests. Zero-alloc costs readability — limit it to measured hot paths and enclose it in one well-named class (`ByteWriter`, `FrameBuffer`, `ParticleStore`, `UserTable`).
