> 🇬🇧 English version · [🇵🇱 Wersja polska](../dart-flutter-extreme-performance-guide.md)

# How to Write Extremely Fast Code in Dart and Flutter (Low-Latency / Zero-Allocation Dart)

> A guide based on source-code analysis:
>
> | Source | What we took from it |
> |---|---|
> | `simolus3/sqlite3.dart` v3.7.1 (`sqlite3/lib/src/ffi/bindings.dart`, `libsqlite3.g.dart`, `memory.dart`, `lib/src/implementation/statement.dart`, `tool/generate_bindings.dart`) | `@Native`, `isLeaf`, `NativeFinalizer`, `asTypedList`, `RawPreparedStatement`, `columnBlobInto`, text binding with `malloc.nativeFree` |
> | `TechEmpower/FrameworkBenchmarks/frameworks/Dart` (`dart3/dart_aot/bin/server.dart`, `dart3/dart_native`, `shelf`, `relic`, `dart_frog`, `angel3`) | `JsonUtf8Encoder` + `response.add`, `shared: true`, isolate groups via `Isolate.spawnUri`, `defaultResponseHeaders.clear()` |
> | `google/flatbuffers/dart/lib/flat_buffers.dart`, `objectbox/flatbuffers-benchmark`, `objectbox/objectbox-dart` (`native/bindings/flatbuffers.dart`, `entity_definition.dart`, `bindings/helpers.dart`), `isar/isar` v4 (`isar_core.dart`, `native/bindings.dart`, `ffigen.yaml`) | `ByteData` + `Endian.little`, `const` readers, `@pragma('vm:prefer-inline')`, builder on `malloc` memory, reused out-pointers, `isLeaf` on every field read |
> | `dart-lang/sdk/runtime/docs` (`README.md` = "Introduction to Dart VM" by V. Egorov, `gc.md`, `glossary.md`, `types.md`, `pragmas.md`, `compressed-pointers.md`) | Smi/Mint, object header, TLAB, scavenger, write barriers, safepoints, TFA, pragmas |
> | `arjaythedev/twelve-dollar-server-challenge` PR #46 `dart-rawsocket-C-Hatton/bin/server.dart` | HTTP server on `ServerSocket` without `HttpServer`, `CAST(... AS BLOB)`, reused output buffer, precomputed error responses |
> | Our own benchmarks in `benchmarks/` of this repository (JIT and AOT, Dart 3.13.5, Linux x64) | Every number in this document, unless another source is given |
>
> Convention: 🐢 = typical code, 🚀 = optimized variant. Numbers are medians from `benchmarks/results/aot.md` (AOT mode, because that is how Flutter runs in release) — where JIT differs significantly, I say so.

---

## 1. The Dart VM under the hood: memory, GC and `dart:typed_data`

### 1.1 How the VM represents objects

From `runtime/docs/gc.md` and `glossary.md`:

* **Tagged pointers.** Every slot (an object field, a `List` element) is a machine word. If the lowest bit = 0, the word *is* the number — a **Smi** (small integer, 63-bit on x64, 31-bit on 32-bit / with `compressed-pointers`). If the bit = 1 — it is a pointer to a heap object. "A tag of 0 allows many operations to be performed on Smis without untagging and retagging".
* **Mint.** An `int` outside the Smi range is a heap object (**Mint**, 64-bit): allocation + pointer + GC. On 64-bit practically every `int` in an application is a Smi, but in generic containers (`List<int>`, `Map<int, …>`) it still takes a full 8 B per element, and every operation starts with a tag test.
* **`double` is always an object** in a generic context (`List<double>`, a field of type `Object`/`num`, a `dynamic` argument). 16 B (header + value) on the heap **per value**. In AOT the compiler keeps `double` *unboxed* in local variables, in class fields with static type `double` and in `Float64List` — but `List<double>.add(x)` has to box x.
* **Object header**: 1 word (class = *class id* 16/20-bit, size, GC flags: mark bit, remembered bit, "new or evacuation candidate"), on 64-bit + a 32-bit identity hash. So an object takes at least 16 B.
* **Age by address**: objects in *old space* are double-word aligned, in *new space* offset by one word — the scavenger distinguishes "old/new/Smi" with a single `and`+`branch`, without comparing against boundaries.
* **`List<T>`** is an object with a header, a length and an array of *tagged words*. **`Uint8List`/`Float64List`** is an object with a header, a length and raw bytes: 1 B/element for `Uint8List`, 8 B/element with no tag and no boxing for `Float64List`. Views (`Uint8List.view`, `sublistView`, `ByteData.view`) are a separate small object (`_TypedListView`) pointing at a shared `ByteBuffer`.

### 1.2 GC: where jank comes from

From `gc.md`:

> „The Dart VM has a generational garbage collector with two generations. The new generation is collected by a parallel, stop-the-world semispace scavenger. The old generation is collected by concurrent-mark-concurrent-sweep or by concurrent-mark-parallel-compact.”

* **Allocation** = bump pointer in a **TLAB** (thread-local allocation buffer) — a few instructions. That is why "allocation in Dart is cheap" is true… for a single allocation.
* **Scavenge** (new space) is **stop-the-world**: the mutator stops at a *safepoint*, the scavenger copies live objects into the other semispace (Cheney), dead ones disappear for free. Cost ∝ number of *live* objects in new space + scanning the *remembered set* (old objects pointing at new ones). Time: usually 0.5–5 ms, but with a large graph of young objects (e.g. 10 000 widgets just built) — more.
* **Write barrier.** Every pointer store into an object field (`obj.field = other`, `list[i] = other`) goes through a barrier: if `obj` is old and `other` is young → add `obj` to the remembered set; if marking is in progress → mark. The compiler removes the barrier for Smi, `bool`, constants ("Constants are always old") and stores right after allocation. **A store into `Float64List`/`Uint8List` has no barrier** — you store bytes, not pointers.
* **Safepoints** are in: allocation (slow path), stack-overflow checks at function entry and in loop headers (`CheckStackOverflow` — "VM relies on these checks for OOB message delivery and GC scheduling"), Dart ↔ native transitions.

**Jank at 120 FPS.** The frame budget is 8.3 ms. If your animation loop (or the parser in a socket's `onData`) allocates 10 000 objects per frame, then:

1. new space (a few MB by default) fills up every few dozen frames,
2. a scavenge stops the UI thread for 1–4 ms **at a random moment** of the frame,
3. objects that survived 1–2 scavenges (because you keep them in state) are *promoted* to old space, where freeing them requires mark-sweep and fragments the heap.

Measurement from `benchmarks/soa`: one frame of updating 10 000 particles as `list.map((p) => Particle(...)).toList()` costs **311 µs** and 10 000 allocations; the same work in place on a `Float64List` — **21 µs**, zero allocations. A 14× difference *before* we count GC.

### 1.3 Zero-allocation and buffer pooling: flat structures instead of `List<MyObject>`

🐢 **Array of Structs** — idiomatically:

```dart
class Particle { double x, y, vx, vy; Particle(this.x, this.y, this.vx, this.vy); }
final particles = <Particle>[];                       // 10k objects of 48 B each + a list of pointers
void step(double dt) {
  for (final p in particles) { p.x += p.vx * dt; p.y += p.vy * dt; }   // dereference per object, cache miss
}
```

🚀 **Struct of Arrays** — 4 buffers, zero pointers, a vectorizable loop:

```dart
// benchmarks/lib/src/bench_soa.dart
final Float64List _x = Float64List(_count), _y = Float64List(_count);
final Float64List _vx = Float64List(_count), _vy = Float64List(_count);

void _stepSoA(double dt) {
  final x = _x, y = _y, vx = _vx, vy = _vy;   // (!) copies to locals — see pitfall 1.6
  for (var i = 0; i < _count; i++) {
    x[i] += vx[i] * dt;
    var ny = y[i] + vy[i] * dt;
    if (ny < 0) { ny = 0; vy[i] = -vy[i]; }
    y[i] = ny;
  }
}
```

🚀 **Flat struct with stride** — one buffer, "fields" at constant offsets like a `struct` in C:

```dart
const _stride = 4;                                   // x, y, vx, vy
final Float64List _flat = Float64List(_count * _stride);
void _stepFlat(double dt) {
  final f = _flat;
  for (var i = 0; i < _count * _stride; i += _stride) {
    f[i] += f[i + 2] * dt;                           // x += vx*dt
    var ny = f[i + 1] + f[i + 3] * dt;
    if (ny < 0) { ny = 0; f[i + 3] = -f[i + 3]; }
    f[i + 1] = ny;
  }
}
```

| `soa/particles` (10k particles, 1 frame) | AOT | JIT |
|---|---:|---:|
| `map().toList()` (10k allocations/frame) | 311 µs | 210 µs |
| `List<Particle>` in-place mutation (AoS) | 29 µs | 33 µs |
| 4× `Float64List` (SoA) | **21 µs** | **16 µs** |
| 1× `Float64List` with stride | 29 µs | 21 µs |

SoA beats stride because the compiler hoists bounds checks for the index `i` more easily than for `i + k`.

When you need "records" of mixed types, use `ByteData` with explicit offsets (like FlatBuffers):

```dart
// record: int32 id | float64 score | uint8 flags  = 13 B -> align to 16
const _rec = 16;
final ByteData _db = ByteData(_n * _rec);
int id(int i) => _db.getInt32(i * _rec, Endian.little);
double score(int i) => _db.getFloat64(i * _rec + 4, Endian.little);
void setScore(int i, double v) => _db.setFloat64(i * _rec + 4, v, Endian.little);
```

Flat buffers don't have to mean an ugly API. An `extension type` (Dart 3.3+) gives you an "object" that at run time is a plain `int` index — zero allocations, full readability:

```dart
extension type const Particle._(int i) {
  Particle(this.i);
  double get x => _x[i];       set x(double v) => _x[i] = v;
  double get vx => _vx[i];     set vx(double v) => _vx[i] = v;
  void step(double dt) => x += vx * dt;           // compiles down to: _x[i] += _vx[i] * dt
}
for (var i = 0; i < _count; i++) { Particle(i).step(dt); }   // Particle(i) is just an int, nothing goes on the heap
```

When the objects cannot be flattened (e.g. they must go into a Flutter API), an **object pool** turns 10k allocations/frame into zero:

```dart
// 🐢 — a new object per event
void onPointer(double x, double y) => _events.add(TouchEvent(x, y));

// 🚀 — a pool: objects created once, reset() instead of new
class TouchEvent { double x = 0, y = 0; }
final _pool = List.generate(256, (_) => TouchEvent(), growable: false);
var _used = 0;
TouchEvent acquire() => _pool[_used++];              // throw/grow when _used == length
void endFrame() => _used = 0;                         // all the frame's objects "released" with a single assignment
```

The pool works the same for `Paint`, `Path` (`path.reset()`), `TextPainter`, `Uint8List` buffers (`Worker.pool` in the winning Rust entry is the same idea: at most 256 buffers ≤ 16 KB, returned after sending).

Always pass a **constant** `Endian.little` — from `flat_buffers.dart`: all accessors (`_getUint32`, `_getInt64`…) have `@pragma('vm:prefer-inline')` and a literal `Endian.little`, so the VM folds this into a single load instruction (`ByteData` without an endianness has a branch on host endianness).

### 1.4 Why `List<int>` is slow — and when it *isn't*

The `typed_lists` benchmark (65 536 elements):

| Operation | `List<int>` | `Int32List` | `Uint8List` | `List<double>` | `Float64List` |
|---|---:|---:|---:|---:|---:|
| **sum, AOT** | 72 µs | 45 µs | **31 µs** | 84 µs | 84 µs |
| **sum, JIT** | 59 µs | 67 µs | 65 µs | 88 µs | 85 µs |
| **build 65k, AOT** | 3 460 µs (`add`) / 900 µs (`filled`) | **402 µs** | — | 6 050 µs (`add`, boxing) | **718 µs** |

Three lessons:

1. **The biggest win is in building/allocation, not in reading.** `List<double>.add` × 65k = 65k `Double` objects + array reallocations: 6 ms. `Float64List(n)` + store: 0.7 ms (8.4×). This is the difference that makes jank.
2. **Sequential reading of Smis from a `List<int>` in JIT is just as fast as from a typed list** — the JIT speculates "this is always a Smi" and generates `add` without boxing. In AOT (= Flutter release) there is no speculation, so `List<int>` is 1.6–2.3× slower. **Measure in AOT.**
3. **Reading `List<double>` ≈ `Float64List`** — because dereferencing a boxed double is a single load, and 65k × 16 B still fits in L2. The typed data advantage returns when the data does not fit in cache (4× less memory for `Float32List`, 8–16× for `Uint8List`) or when you write.

### 1.5 JSON: `JsonUtf8Encoder` and decoder fusion

🐢 `jsonEncode(map)` → `String` (UTF-16, 2 B/char) → `utf8.encode` → `Uint8List`. Two full copies plus thousands of intermediate `String`s from keys and values.

🚀 `JsonUtf8Encoder` from `dart:convert` writes **UTF-8 bytes directly** into a growing buffer (`_JsonUtf8Stringifier` in the SDK), bypassing the `String` object. TechEmpower (`dart3/dart_native/bin/server.dart`):

```dart
final _jsonEncoder = JsonUtf8Encoder();                 // one instance per isolate
void _sendJson(HttpRequest request, Object response) => _sendResponse(
  request, HttpStatus.ok,
  type: ContentType.json,
  bytes: _jsonEncoder.convert(response),                // List<int> (Uint8List)
);
void _sendResponse(HttpRequest request, int statusCode, {ContentType? type, List<int> bytes = const []}) =>
  request.response
    ..statusCode = statusCode
    ..headers.contentType = type
    ..contentLength = bytes.length                      // explicit Content-Length = no chunked encoding
    ..add(bytes)                                        // add(bytes), NOT write(string)
    ..close();
```

🚀🚀 **Manual byte writer** — when you know the schema (API response, protocol), write the fields straight into a reused `Uint8List` (the pattern from `dart-rawsocket-C-Hatton` and the winning Rust entry):

```dart
// benchmarks/lib/src/bench_json.dart — the ByteWriter class
void jsonString(Uint8List s) {              // s = raw UTF-8 bytes (e.g. from SQLite via CAST AS BLOB)
  _grow(s.length * 6 + 2);
  final b = _buf; var n = _len;
  b[n++] = 0x22;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c >= 0x20 && c != 0x22 && c != 0x5c) { b[n++] = c; }          // 99 % of bytes: 1 load, 1 store
    else if (c == 0x22 || c == 0x5c) { b[n++] = 0x5c; b[n++] = c; }
    else { /* \u00XX */ }
  }
  b[n++] = 0x22;
  _len = n;
}
```

| `json/encode feed` (20 posts, 2.6 KB) | AOT | JIT |
|---|---:|---:|
| `jsonEncode(map)` + `utf8.encode` | 60.2 µs | 53.7 µs |
| `JsonUtf8Encoder().convert(map)` | 38.0 µs (1.6×) | 39.2 µs |
| `ByteWriter` into a reused `Uint8List` | **6.5 µs (9.3×)** | 8.2 µs |

Decoding — `utf8.decoder.fuse(json.decoder)` builds a single converter that decodes UTF-8 **in a streaming fashion** into the JSON parser (the SDK has a special path for this fusion, `_JsonUtf8Decoder`, which parses the bytes directly without creating a `String` of the whole document):

```dart
final _fused = utf8.decoder.fuse(json.decoder);          // once, at library level
Object? decode(Uint8List bytes) => _fused.convert(bytes); // 26 µs vs 32 µs for jsonDecode(utf8.decode()) (AOT)
```

The 20 % gain is modest, because a tree of `Map`/`List`/`String` is still created. The real win comes from **not building the tree**: a streaming parser that reads only the fields it needs (the equivalent of `BodySeed` from Rust), or a binary format (FlatBuffers, §4).

### 1.6 Pitfall: lazily initialized global fields

```dart
final Float64List _f64 = Float64List.fromList(...);   // top-level `final` with an initializer = LAZY getter

double sumBad() {
  var s = 0.0;
  for (var i = 0; i < _f64.length; i++) { s += _f64[i]; }   // 2x getter with "is it initialized?" per iteration
  return s;
}
double sumGood(Float64List l) { /* the same loop on the parameter */ }
```

| `typed_lists/sum double` | AOT |
|---|---:|
| `Float64List` via a top-level `final` in the loop | 194 µs |
| `Float64List` passed as a parameter/local | **84 µs (2.3×)** |

This applies to `static final`, top-level `final`/`var` with a non-trivial initializer, and `late final`. Rule: **before a hot loop, copy the reference into a local variable**. ObjectBox and Isar do this consistently (`final pointers = _store.readPointers();` before use).

### 1.7 Collections, strings, buffers — examples (AOT)

First the table, then each row as a code pair.

| Case | 🐢 | 🚀 | Gain |
|---|---|---|---:|
| filter+map 10k | `where().map().toList()` 183 µs | 2 loops + `Int32List(count)` 40 µs | 4.6× |
| sum of 10k | `fold()` 34 µs | `for` loop 22 µs | 1.5× |
| histogram of 10k values 0..999 | `Map<int,int>` 271 µs | `Int32List(1000)[v]++` 25 µs | 10.8× |
| 200 lines of text | `s += '...'` 106 µs | `StringBuffer` 30 µs / bytes into a `Uint8List` 10 µs | 3.6× / 10.5× |
| assembling 16 fragments of 512 B (`onData`) | `List<int>.addAll` 193 µs; `Uint8List` new copy per fragment 11.7 µs | `BytesBuilder(copy: false)` 1.9 µs; preallocated buffer + `sublistView` 0.47 µs | 100× / 410× |
| parsing an HTTP request | `utf8.decode` + `split` + `Map` 3.7 µs | byte scan, offsets 0.93 µs | 4× |

#### 1.7.1 `Iterable` chains → a loop

```dart
// 🐢 — 2 lazy Iterables, 2 iterators, 2 closures, a growable list with reallocations
final r = data.where((v) => v.isEven).map((v) => v * 2).toList();

// 🚀 — count, allocate once, fill
var c = 0;
for (var i = 0; i < data.length; i++) { if (data[i].isEven) c++; }
final r = Int32List(c);
var j = 0;
for (var i = 0; i < data.length; i++) { final v = data[i]; if (v.isEven) r[j++] = v * 2; }
```

Laziness pitfall: `final evens = data.where(...)` does **not** do the work — every `evens.length`, `evens.first`, `for (… in evens)` runs the filter again. If you use the result more than once, materialize it (`toList(growable: false)`) or write a loop.

```dart
// 🐢 — the filter is computed 3 times
final big = items.where((i) => i.size > 1000);
if (big.isNotEmpty) print('${big.length} items, first ${big.first}');
// 🚀
final big = items.where((i) => i.size > 1000).toList(growable: false);
```

#### 1.7.2 `fold`/`reduce` → a loop; `forEach` → `for`

```dart
// 🐢  final sum = data.fold<int>(0, (a, b) => a + b);     // closure call per element (AOT does not always inline it)
// 🚀  var sum = 0; for (var i = 0; i < data.length; i++) { sum += data[i]; }
// 🐢  list.forEach((e) => process(e));                   // closure + no break/continue
// 🚀  for (final e in list) { process(e); }
```

#### 1.7.3 Maps and sets → arrays, when the key is a small number

```dart
// 🐢  final hist = <int, int>{}; for (final v in data) { hist[v] = (hist[v] ?? 0) + 1; }   // hashing, value boxing, rehash
// 🚀  final hist = Int32List(1000); for (var i = 0; i < data.length; i++) { hist[data[i]]++; }

// 🐢  final allowed = {3, 7, 42, 100};  if (allowed.contains(code)) ...              // Set<int>: a hash per check
// 🚀  final allowed = Uint8List(256)..[3] = 1..[7] = 1..[42] = 1..[100] = 1;  if (allowed[code] != 0) ...   // 1 load
// 🚀  (large/sparse keys) a sorted Int32List + binary search instead of a Set

// 🐢  switch (name) { case 'GET': ... case 'POST': ... }        // String comparisons
// 🚀  switch (methodCode) { case 0: ... case 1: ... }            // an int determined once while parsing (e.g. first byte | length)
```

`Map<String, T>` with keys known at compile time → `enum` + `List<T>` indexed by `e.index` (zero hashing).

#### 1.7.4 Strings

```dart
// 🐢 — quadratic copying: every += creates a new String with all the content so far
var s = ''; for (var i = 0; i < n; i++) { s += 'line $i\n'; }
// 🚀 — amortized O(n)
final sb = StringBuffer(); for (var i = 0; i < n; i++) { sb..write('line ')..write(i)..write('\n'); }
// 🚀🚀 — when the result goes to a socket/file: bytes right away, no intermediate String
var k = 0; for (var i = 0; i < n; i++) { k = writeAscii(buf, k, 'line '); k = writeInt(buf, k, i); buf[k++] = 0x0a; }

// 🐢  final parts = line.split(',');  final a = parts[0]; final b = parts[1];   // N Strings + a list
// 🚀  final comma = line.indexOf(','); final a = line.substring(0, comma); ...   // only the substrings you need
// 🚀🚀 work on (start, end) offsets into the original; substring only at the end, if at all

// 🐢  if (header.toLowerCase() == 'content-length')               // allocates a new String
// 🚀  if (header.length == 14 && _ieq(header, 'content-length'))   // comparison via (c | 0x20), zero allocations

// 🐢  utf8.decode(bytes)                 // always the full decoder
// 🚀  isAscii(bytes) ? String.fromCharCodes(bytes) : utf8.decode(bytes)   // FlatBuffers `asciiOptimization`, Isar `is_ascii`
```

`String.substring` in the Dart VM **copies** (there are no sliced strings as in V8). Parsers keep `(start, end)` and decode lazily.

#### 1.7.5 Assembling fragments from a byte stream

```dart
// 🐢 a) List<int> + addAll: boxing every byte into a Smi in an array of pointers
final acc = <int>[]; stream.listen(acc.addAll);
// 🐢 b) Uint8List + a copy on every fragment (dart-rawsocket-C-Hatton): O(n²) for large bodies
var buf = Uint8List(0);
void onData(Uint8List d) { final nb = Uint8List(buf.length + d.length); nb.setRange(0, buf.length, buf); nb.setRange(buf.length, nb.length, d); buf = nb; }
// 🚀 c) BytesBuilder(copy: false): keeps a list of fragments, a single copy in takeBytes()
final bb = BytesBuilder(copy: false); stream.listen(bb.add, onDone: () => handle(bb.takeBytes()));
// 🚀🚀 d) preallocated buffer per connection + a counter; a view without a copy; memmove the remainder after a frame is parsed
final buf = Uint8List(64 * 1024); var n = 0;
void onData(Uint8List d) {
  buf.setRange(n, n + d.length, d); n += d.length;
  final used = parse(Uint8List.sublistView(buf, 0, n));          // returns the number of consumed bytes
  if (used > 0) { buf.setRange(0, n - used, buf, used); n -= used; }   // move the tail to the front (in place)
}
```

#### 1.7.6 Parsing a protocol byte by byte (excerpt from `_parseBytes`)

```dart
// 🐢
final text = utf8.decode(bytes);
final lines = text.split('\r\n');
final headers = <String, String>{};
for (final line in lines.skip(1)) { final i = line.indexOf(':'); if (i > 0) headers[line.substring(0, i).toLowerCase()] = line.substring(i + 1).trim(); }
final auth = headers['authorization'];

// 🚀 — no Strings: the header name is recognized by length + first byte + a case-insensitive comparison
bool _ieq(Uint8List b, int s, String name) {
  for (var k = 0; k < name.length; k++) { if ((b[s + k] | 0x20) != name.codeUnitAt(k)) return false; }
  return true;
}
// ... in the loop over lines, given ls (line start), c (position of ':'), vs/ve (value):
final nameLen = c - ls; final f = b[ls] | 0x20;
if (nameLen == 14 && f == 0x63 && _ieq(b, ls, 'content-length')) { contentLength = _parseIntBytes(b, vs, ve); }
else if (nameLen == 13 && f == 0x61 && _ieq(b, ls, 'authorization')) { authStart = vs; authEnd = ve; }   // offsets only
```

#### 1.7.7 Small things that stop being small in a loop

```dart
// 🐢  RegExp(r'^\d+$').hasMatch(s)            // regex compilation per call
// 🚀  static final _digits = RegExp(r'^\d+$'); // once; or a loop over codeUnitAt (like _parseId in the Dart submission)

// 🐢  DateTime.now().millisecondsSinceEpoch      // allocates a DateTime
// 🚀  final sw = Stopwatch()..start(); ... sw.elapsedMicroseconds   // no allocation; for "wall-clock time" cache it once per frame/ms

// 🐢  log('value=$x for $user');               // the interpolation ALWAYS runs, even when logging is off
// 🚀  if (log.isLoggable(Level.FINE)) log.fine('value=$x for $user');

// 🐢  final copy = [...list];  /  List.from(list)      // growable + possible type checks
// 🚀  final copy = List.of(list, growable: false);     // one allocation of the exact size; typed: Float64List.fromList / sublist

// 🐢  enum Op { add, sub }  final cost = {Op.add: 1, Op.sub: 2}[op]!;
// 🚀  const costs = [1, 2];  final cost = costs[op.index];

// 🐢  x.toString()  in a hot loop (int -> String -> bytes)
// 🚀  writeInt(buf, k, x)  — digits from the end straight into a Uint8List (see ByteWriter.integer)

// 🐢  final cb = () => handle(this, item);      // a closure capturing this and item, allocated per iteration
// 🚀  an instance method / top-level function passed as a tear-off (ObjectBox: "Static callback to avoid over-capturing")
```

---

## 2. Extreme `dart:ffi` — SQLite and native code (based on `sqlite3.dart`)

### 2.1 How `sqlite3.dart` binds C functions: `@Native` instead of `lookupFunction`

Since version 3 the package does not use `DynamicLibrary.open`/`lookupFunction`; all 94 symbols are `@Native` externs generated by ffigen into `lib/src/ffi/libsqlite3.g.dart`, and the library is shipped as a *native asset* via `hook/build.dart`:

```dart
// sqlite3/lib/src/ffi/libsqlite3.g.dart
@ffi.DefaultAsset('package:sqlite3/src/ffi/libsqlite3.g.dart')
library;

@ffi.Native<ffi.Int Function(ffi.Pointer<sqlite3_stmt>)>()
external int sqlite3_step(ffi.Pointer<sqlite3_stmt> pStmt);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<sqlite3>)>(isLeaf: true)
external int sqlite3_last_insert_rowid(ffi.Pointer<sqlite3> db);
```

`@Native` has two advantages over `lookupFunction`: the address is resolved once at load time (no `late final` and no initialization check on every call), and the AOT compiler can generate a direct `call` to the trampoline without an intermediate function object.

### 2.2 `isLeaf: true` — when and why

A "non-leaf" FFI call switches the thread state (`kThreadInGenerated` → `kThreadInNative`): it saves state, opens the possibility of a GC safepoint, and on return checks whether a GC is waiting. For a function that takes 5 ns, that is a 4–5× overhead. `isLeaf: true` tells the VM: "this function does not call back into Dart, does not block, does not need a safepoint" — and the transition disappears.

The `ffi/call add(a,b)` benchmark:

| Variant | AOT | JIT |
|---|---:|---:|
| pure Dart `a + b` | 2.4 ns | 5.4 ns |
| FFI non-leaf | 21.6 ns | 24.3 ns |
| FFI `isLeaf: true` | **5.4 ns (4×)** | **8.8 ns (2.8×)** |

But `sqlite3.dart` marks **only 10 functions** as leaf. The reason is in `tool/generate_bindings.dart`:

```dart
/// Note: Leaf functions must never call back into Dart.
///
/// Almost all SQLite functions could do that (e.g. due to an update hook, a
/// user-defined function, or a VFS). So we only enable this on a few trivial
/// functions to reduce their overhead.
const _leafFunctions = <String>{
  'sqlite3_last_insert_rowid', 'sqlite3_changes', 'sqlite3_get_autocommit',
  'sqlite3_update_hook', 'sqlite3_commit_hook', 'sqlite3_rollback_hook',
  'sqlite3_stmt_isexplain', 'sqlite3_stmt_readonly',
  'sqlite3_column_count', 'sqlite3_bind_parameter_count',
};
```

`sqlite3_step` **cannot** be leaf: it may call a user-defined function written in Dart (`createFunction`), a hook, or a Dart VFS — and calling back into Dart from a thread "in native state" without a safepoint is a crash. Isar v4 went the opposite way — its Rust core *never* calls Dart, so `ffigen.yaml` marks all `isar_read_*`, `isar_write_*`, `isar_filter_*` (58 functions) as leaf, and that makes "one FFI call per field" cheaper than parsing bytes in Dart.

**Rule:** `isLeaf: true` when the C function (1) does not invoke callbacks into Dart, (2) does not block (no I/O, mutexes, `sleep`), (3) is short. If it blocks, you block GC for the *whole* isolate group.

### 2.3 Native memory without overhead: `malloc`/`Arena`, `NativeFinalizer`, `asTypedList`

**Zero-copy from C to Dart.** `Pointer<Uint8>.asTypedList(n)` creates a `Uint8List` that is a **view** onto native memory (external typed data) — no copy:

| `ffi/read 4 KB z Pointer<Uint8>` | AOT |
|---|---:|
| `ptr[i]` in a loop into a `List<int>` | 10 580 ns |
| `Uint8List.fromList(ptr.asTypedList(n))` (1 memcpy) | 710 ns |
| `ptr.asTypedList(n)` view | **11.8 ns** |

ObjectBox (`entity_definition.dart`) reads objects from the database exactly this way:

```dart
T objectFromData(Store store, Pointer<Uint8> data, int size) {
  // There has been a performance improvement in the past using memcpy for
  // small buffers, but this is not longer faster than asTypedList.
  final uInt8List = data.asTypedList(size);
  final byteData = ByteData.view(uInt8List.buffer, uInt8List.offsetInBytes, size);
  return objectFromFB(store, byteData);          // FlatBuffers reads fields straight from native memory
}
```

The view is valid only as long as the memory underneath it. For a TEXT column `sqlite3.dart` does a view + `utf8.decode` (1 copy into a `String`), and for a BLOB it **always copies**, because SQLite invalidates the pointer at the next `step`/`reset`:

```dart
// sqlite3/lib/src/ffi/bindings.dart
void sqlite3_column_blob_into(int index, Uint8List target, int offset, int length) {
  if (length == 0) return;
  final source = libsqlite3.sqlite3_column_blob(stmt, index);
  target.setRange(offset, offset + length, source.cast<Uint8>().asTypedList(length));  // view -> a single memcpy into YOUR buffer
}
```

When the native buffer should live longer and you want the GC to free it: `ptr.asTypedList(len, finalizer: malloc.nativeFree)` (this is what `allocateBytesWithFinalizer` in `memory.dart` does) or `finalizer: sqlite3_free.cast()` (as in `sqlite3changeset_invert`).

**`NativeFinalizer`** — freeing a native resource when the Dart object gets collected, without any Dart code running at collection time:

```dart
// sqlite3/lib/src/ffi/bindings.dart
final statementFinalizer = NativeFinalizer(addresses.sqlite3_finalize.cast());

final class FfiStatement implements RawSqliteStatement, Finalizable {
  final Pointer<sqlite3_stmt> stmt;
  final Object _detachToken = Object();
  FfiStatement(this.stmt, {required bool borrowed}) {
    if (!borrowed) statementFinalizer.attach(this, stmt.cast(), detach: _detachToken);
  }
  void sqlite3_finalize() {
    libsqlite3.sqlite3_finalize(stmt);
    statementFinalizer.detach(_detachToken);     // explicit close -> detach, so it is not freed twice
  }
}
```

`implements Finalizable` is key: it guarantees the object will not be considered dead *during* an FFI call on its pointer (the compiler keeps it alive until the end of the scope). ObjectBox does the same: `NativeFinalizer(C.addresses.txn_close.cast())`, and notes that native finalizers fire in the order *the `NativeFinalizer` objects were created*, so it creates the transaction finalizer before the store finalizer.

**Native allocation in the hot path.** The `ffi/fill 256 B` benchmark:

| Variant | AOT |
|---|---:|
| `malloc` + `free` per call | 235 ns |
| `Arena` (`using((arena) => arena<Uint8>(256)))` | 290 ns |
| reused buffer | **172 ns** |

`Arena` is *not* a speed optimization for a single allocation — it is a correctness tool (it frees everything even on an exception) and a convenience for many temporary allocations. For the hot path do what Isar and ObjectBox do: **out-pointers allocated once and reused**:

```dart
// isar/packages/isar/lib/src/isar_core.dart
static Pointer<Pointer<NativeType>> ptrPtr = malloc<Pointer<NativeType>>();
static Pointer<Uint32> countPtr = malloc<Uint32>();
static Pointer<Bool> boolPtr = malloc<Bool>();
// objectbox-dart/objectbox/lib/src/native/store.dart
class ReadPointers { final Pointer<Pointer<Uint8>> dataPtrPtr = malloc(); final Pointer<Size> sizePtr = malloc(); }
```

How does `sqlite3.dart` pass text to `sqlite3_bind_text`? Not via `SQLITE_TRANSIENT` (that would make SQLite do a *second* copy):

```dart
int sqlite3_bind_text(int index, String value) {
  final bytes = utf8.encode(value);              // 1. Uint8List on the Dart heap
  final ptr = allocateBytes(bytes);              // 2. malloc + memcpy
  return libsqlite3.sqlite3_bind_text(stmt, index, ptr.cast(), bytes.length,
      allocate.nativeFree);                      // 3. SQLite frees it itself via free() — zero extra copies
}
```

So binding a `String` = 2 allocations. If you already have UTF-8 bytes (from the network, from a file), bind a `Uint8List` as a BLOB and save the `utf8.encode` — the package README: "Consider using a `Uint8List` when binding binary values for better performance".

### 2.4 Allocation-free reads: `RawPreparedStatement`

The high-level path (`lib/src/implementation/statement.dart::_selectResults`) allocates per `select()`: a `List<List<Object?>>`, per row a `List<Object?>`, per `ResultSet[i]` access a new `Row` **and** a `List.unmodifiable` (a copy!), per TEXT column a `String`, per BLOB a `Uint8List`. Since 3.5.0 there is `stmt.raw` — an `extension type RawPreparedStatement` that calls `sqlite3_*` without intermediaries:

```dart
// benchmarks/lib/src/bench_sqlite.dart
void _readRaw() {
  var s = 0;
  final raw = _selectAll.raw;                 // RawPreparedStatement — no allocation, it is an extension type
  while (raw.step()) {                        // sqlite3_step == SQLITE_ROW
    s += raw.columnInt64(0);                  // sqlite3_column_int64 -> Smi, no boxing
  }
  _selectAll.reset();
}
void _readTextAsBlobInto() {                  // SELECT ..., CAST(body AS BLOB) FROM t
  final raw = _selectBlob.raw;
  while (raw.step()) {
    n += raw.columnBlobInto(2, _blobScratch); // bytes straight into a reused Uint8List(4096)
  }
}
```

| `sqlite/select 10k wierszy` | AOT |
|---|---:|
| `select()` → `ResultSet` | 4.16 ms |
| `selectCursor()` | 4.48 ms |
| `stmt.raw`: `step()` + `columnInt64()` | **0.89 ms (4.7×)** |
| 10k TEXT: `raw.columnText()` → `String` | 1.68 ms |
| 10k `CAST AS BLOB` + `columnBlobInto(buffer)` | 1.47 ms |

The documentation warns: "calling raw methods on finalized statements is an unchecked use-after-free" — raw is a knife without a guard, to be used in a single, well-tested data access layer.

### 2.5 Group commit / write batching

Every `COMMIT` in SQLite is a full cycle: writing frames to the WAL, updating the WAL index, and with `synchronous=FULL` an `fsync`. 10 000 autocommits = 10 000 such cycles. The rule from `twelve-dollar-server`: **one transaction per batch of requests from a single event-loop iteration**.

🐢

```dart
for (final p in posts) {
  db.execute('INSERT INTO posts (user_id, body) VALUES (?, ?)', [p.userId, p.body]);  // prepare + bind + COMMIT per row
}
```

🚀

```dart
final insert = db.prepare('INSERT INTO posts (user_id, body) VALUES (?, ?)', persistent: true); // SQLITE_PREPARE_PERSISTENT
db.execute('BEGIN');
for (final p in posts) { insert.execute([p.userId, p.body]); }
db.execute('COMMIT');
```

| `sqlite/insert 10k` (WAL, `synchronous=NORMAL`) | AOT |
|---|---:|
| `execute(sql, args)` per row, autocommit | 230 ms |
| prepared statement, autocommit per row | 221 ms |
| prepared + batches of 100 | 34.6 ms |
| prepared + batches of 1000 | 19.6 ms |
| prepared + a single transaction | **17.2 ms (13×)** |

The prepared statement alone gives little (the SQL is short) — the COMMIT is the cost. Batches of 100 already give 85 % of the gain, so in a server/application you don't have to wait for "everything": it is enough to group what is **already waiting**. The "group commit per tick" pattern in Dart (the equivalent of `Worker::run` + `flush` from Rust and `work()` from Axum):

```dart
class WriteBatcher {
  final Database db;
  final _pending = <(void Function() apply, Completer<void> done)>[];
  bool _scheduled = false;
  WriteBatcher(this.db);

  Future<void> submit(void Function() apply) {
    final c = Completer<void>();
    _pending.add((apply, c));
    if (!_scheduled) {
      _scheduled = true;
      scheduleMicrotask(_flush);   // end of the CURRENT event-loop iteration: everything that arrived in this tick goes into one transaction
    }
    return c.future;               // send the 201 only after this future completes = after COMMIT
  }

  void _flush() {
    _scheduled = false;
    final batch = List.of(_pending); _pending.clear();
    try {
      db.execute('BEGIN IMMEDIATE');
      for (final (apply, _) in batch) { apply(); }
      db.execute('COMMIT');
      for (final (_, done) in batch) { done.complete(); }
    } catch (e, st) {
      db.execute('ROLLBACK');
      for (final (_, done) in batch) { done.completeError(e, st); }   // the whole batch = 500, like flush(false) in Rust
    }
  }
}
```

`scheduleMicrotask` instead of `Timer` = zero extra latency when there is a single request, and natural grouping when 50 packets arrived in one `epoll_wait` (Dart handles the 50 `onData` calls in one iteration, and the microtask runs after them). For Isar v4 the equivalent is `putAll` (`isar_insert` once → N × `serialize` + `isar_insert_save` → `isar_insert_finish`), for ObjectBox `box.putMany` in a single transaction with a reused `BuilderWithCBuffer`.

### 2.6 How ObjectBox writes FlatBuffers straight into native memory

`objectbox/lib/src/native/bindings/flatbuffers.dart` ("touch this file with caution, it's a hotspot") swaps the FlatBuffers Builder's allocator for `malloc`, so the serialized object **is already** in C memory when we call `obx_box_put_object4`:

```dart
class Allocator extends fb.Allocator {
  Pointer<Uint8>? _ptr; int _capacity = 0;
  ByteData get _view => ByteData.view(_ptr!.asTypedList(_capacity).buffer);   // Dart writes through a view into malloc memory
  @override ByteData allocate(int size) { _capacity = size; _ptr = malloc<Uint8>(size); return _view; }
  @override ByteData resize(ByteData oldData, int newSize, int inUseBack, int inUseFront) {
    final newPtr = malloc<Uint8>(newSize);
    if (inUseBack != 0) memcpy(newPtr + (newSize - inUseBack), _ptr! + (_capacity - inUseBack), inUseBack);
    ...
  }
}
// box.dart: one builder per Box, reset per put, reallocation only when > 64 KiB
_builder.fbb.reset();
final id = _entity.objectToFB(object, _builder.fbb);
C.box_put_object4(_cBoxChecked, _builder.bufPtr, _builder.fbb.size(), mode);
_builder.resetIfLarge();
```

The general lesson: **the output buffer lives as long as its owner object (Box, Connection, Isolate), not as long as a single call**.

---

## 3. Isolates and concurrency without copying

### 3.1 When an isolate is slower than work on the main thread

`SendPort.send(obj)` serializes the object graph (except immutable and `vm:deeply-immutable` objects) and deserializes it on the receiver's side — an allocation + a copy for every object. On top of that, `Isolate.spawn` is ~100–350 µs (AOT/JIT) even for an empty function, and `Isolate.run` adds a port and a future.

The `isolates` benchmark (10 000 records, one send to a worker + a small ack):

| Payload | AOT | JIT |
|---|---:|---:|
| `List<Map<String,Object>>` 10k objects (deep copy) | 9.2 ms | 22.5 ms |
| `Uint8List` 120 KB (a single memcpy) | **72 µs** | 140 µs |
| `TransferableTypedData` 120 KB | 124 µs | 316 µs |
| `Uint8List` 16 MB | 14.6 ms | 31.2 ms |
| `TransferableTypedData` 16 MB | **7.3 ms** | 13.4 ms |
| `Isolate.run(() => 1)` (spawn alone) | 343 µs | 358 µs |

Conclusions:

1. **Flat bytes instead of objects: 128×.** If a worker has to compute something over 10k records, send a `Float64List`/`ByteData`, not a `List<Model>`. Deserializing 10k `Map`s on the receiver's side is 10k+ allocations **on the UI thread** when the result comes back.
2. **An isolate pays off from ~1 ms of work.** Spawn + 2 sends is ≥ 0.4 ms; parsing 5 KB of JSON (30 µs) in an isolate is a pure loss. Flutter's `compute()` for small things *adds* jank.
3. **`TransferableTypedData` is not free**: `fromList` copies into a native buffer. The gain appears when (a) the buffer is large (16 MB: 2×), (b) the receiver does not have to materialize it immediately, (c) **the receiver's GC does not see a large object** — and at 120 FPS that matters more than the raw copy time.

### 3.2 Zero-copy via `TransferableTypedData`

```dart
// sender
final bytes = buildFrame();                               // Uint8List, e.g. 8 MB of a decoded image
port.send(TransferableTypedData.fromList([bytes]));       // copy into a native buffer; you can keep using `bytes`
// receiver
port.listen((msg) {
  final ttd = msg as TransferableTypedData;
  final data = ttd.materialize().asUint8List();           // O(1): ownership transfer, zero copies; ttd is now empty
});
```

ObjectBox (`native/query/query.dart`, result streaming) does exactly this: it collects a batch of `Uint8List`s and sends `TransferableTypedData.fromList(batch)` — instead of a list of objects per row. O(1) alternatives worth knowing:

* **Immutable objects** (`String`, `int`, `double`, `bool`, `const` collections, `Pointer`, classes marked `@pragma('vm:deeply-immutable')` — a `final` class, `final` fields of deeply-immutable types) are **shared, not copied** between isolates of the same group.
* **`Pointer<T>`** you send as an address (`ptr.address`, an int) — native memory is shared by the whole process; this is "shared memory" in Dart. The buffer's lifetime is your responsibility.
* **`Isolate.run`** (Dart 2.19+) moves the result without a copy if the isolate exits right after — the VM "transplants" the objects into the receiver (for large results this is a win over `compute`).

* **`Isolate.exit(port, message)`** — the cheapest way to hand back a large result: the isolate exits and *hands over* its heap together with the object (no serialization), so even a `List<Map>` comes back in O(1). This is exactly what `Isolate.run` does under the hood.

```dart
// worker started via Isolate.spawn(_work, replyPort)
void _work(SendPort reply) {
  final result = parseEverything();           // any object graph, even 100 MB
  Isolate.exit(reply, result);                // zero copies; the isolate dies, the objects "move house" to the receiver
}
```

A long-lived worker (when there are many tasks and a spawn per task would cost 0.1–0.35 ms each) — the pattern from `benchmarks/lib/src/bench_isolates.dart`:

```dart
late SendPort _worker;
late StreamIterator<Object?> _replies;

void _workerMain(SendPort reply) {
  final port = ReceivePort();
  reply.send(port.sendPort);                   // handshake: hand over your SendPort
  port.listen((msg) {
    if (msg is TransferableTypedData) { reply.send(process(msg.materialize().asUint8List())); }
    else if (msg == null) { port.close(); }   // shutdown signal; no open ports = the isolate exits on its own
  });
}

Future<void> start() async {
  final inbox = ReceivePort();
  await Isolate.spawn(_workerMain, inbox.sendPort);
  _replies = StreamIterator(inbox);
  await _replies.moveNext();
  _worker = _replies.current as SendPort;
}

Future<Object?> submit(Uint8List payload) async {   // requests in order: one in flight at a time
  _worker.send(TransferableTypedData.fromList([payload]));
  await _replies.moveNext();
  return _replies.current;
}
```

If you need many tasks in flight, add an `id` to the message and keep a `Map<int, Completer>` — but then the response payload should be flat too (a `Uint8List` with the `id` in the first 4 bytes), otherwise you are back to deep copy.

### 3.3 Server architecture: isolates and isolate groups

TechEmpower `dart3/dart_aot/bin/server.dart` — the only non-trivial trick there:

```dart
const _maxIsolatesfromEnvironment = int.fromEnvironment('MAX_ISOLATES');   // dart compile ... --define=MAX_ISOLATES=8
void main(List<String> arguments) async {
  ...
  if (!args.contains(_workerGroupTag)) {
    /// Each group serves as a container for multiple isolates,
    /// helping to bypass internal VM scaling bottlenecks.
    final workerGroups = Platform.numberOfProcessors ~/ maxIsolates - 1;
    for (var i = 0; i < workerGroups; i++) {
      await Isolate.spawnUri(Platform.script, [...args, _workerGroupTag], null);   // NEW isolate group = separate heap, separate GC
    }
  }
  for (var i = 1; i < maxIsolates; i++) { await Isolate.spawn(_startServer, args); }   // the same group
  await _startServer(args);
}
Future<void> _startServer(List<String> args) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080, shared: true);  // the kernel distributes accept() across isolates
  server..defaultResponseHeaders.clear()..serverHeader = 'dart_native';
  ...
}
```

`Isolate.spawn` creates an isolate **in the same group** — shared heap, shared safepoints (one isolate's GC stops all of them). `Isolate.spawnUri` starts a **new group**. On multi-core machines, splitting isolates into groups of ~8 limits "stop-the-world for everyone". On 1 vCPU (as in the $12 challenge) **a single isolate** is best: the Dart submission writes "extra isolates only add context switches and memory".

### 3.4 When you don't need an isolate at all

Dart is single-threaded, but its event loop is built on epoll — I/O **never** blocks. An isolate is needed only for **CPU-bound** work > ~1 ms that would break a frame. Before you add one, check three cheaper options: (1) do the work synchronously but without allocations (5 ms often turns into 0.3 ms), (2) split the work into steps of ≤ 2 ms and spread them across frames (`SchedulerBinding.scheduleTask`/`Future.delayed(Duration.zero)`), (3) move it to native code via FFI `isLeaf` (vectorized C/Rust is 5–50× faster than Dart on numeric loops; in our benchmark a simple `dot_f64` in C was 1.24× faster than Dart on a `Float64List` — Dart does not vectorize).

---

## 4. Flutter: Impeller, `RenderObject` and an allocation-free widget layer

> I write this section without benchmarks in this repo (no Flutter SDK in the container); it is based on the engine architecture and on rules that DevTools verifies (`Performance` → Frame chart, `Raster`/`UI` thread, `Track widget rebuilds`, `Track layouts`, `Track paints`).

### 4.1 The frame model and the three threads

One frame = **UI thread** (Dart: `build` → `layout` → `paint` → `compositing` → `Scene`) + **Raster thread** (Impeller: Scene → GPU commands) + GPU. Budget at 120 Hz: 8.3 ms *on each of them separately*. UI jank = too much Dart (build/layout/allocations/GC); Raster jank = too many shaders/layers/`saveLayer`/large textures.

Impeller (the default engine since Flutter 3.16 on iOS / 3.27 on Android) precompiles shaders, so "shader compilation jank" disappears, but it does not change the costs on the Dart side — GC and rebuilds are still yours.

### 4.2 Widgets: `const`, rebuild boundaries, no allocations in `build`

🐢

```dart
Widget build(BuildContext context) {
  final items = widget.data.map((d) => ItemTile(d)).toList();     // new list + N widgets per build
  return ListView(children: items, padding: EdgeInsets.all(8));     // new EdgeInsets per build
}
```

🚀

```dart
Widget build(BuildContext context) => ListView.builder(            // builds only what is visible
  padding: const EdgeInsets.all(8),                                // const = one object for the program's whole lifetime, in old space
  itemCount: widget.data.length,
  itemBuilder: (context, i) => ItemTile(widget.data[i]),           // ItemTile with a const constructor wherever possible
);
```

Rules that follow directly from §1:

* **`const` widgets are not rebuilt** — the framework compares `identical(oldWidget, newWidget)` and skips the subtree. `const` also means no allocation and no write barrier ("Constants are always old").
* **`setState` as low as possible.** Rebuilding a subtree = allocating all of its widgets (short-lived objects → scavenge). Split out a `StatefulWidget` so that as little as possible changes; for global state use `ValueListenableBuilder`/`ListenableBuilder` around the smallest fragment.
* **Don't allocate in `build` what you can compute once**: `TextStyle`, `BoxDecoration`, `EdgeInsets`, `Key`, closures without captures (class methods instead of lambdas).
* **`RepaintBoundary`** isolates a layer: an animation inside does not repaint its siblings; static, expensive siblings are not rasterized every frame. Too many boundaries = too many layers (GPU memory cost), so place them **around things that animate independently** (DevTools: `Highlight repaints`).

### 4.3 `CustomPainter`/`RenderObject`: a zero-alloc-style paint loop

🐢

```dart
@override
void paint(Canvas canvas, Size size) {
  for (final p in particles) {
    canvas.drawCircle(Offset(p.x, p.y), 2, Paint()..color = Colors.white);   // Paint + Offset per particle per frame
  }
}
@override
bool shouldRepaint(covariant CustomPainter old) => true;
```

🚀

```dart
class ParticlePainter extends CustomPainter {
  ParticlePainter(this.xy, this.repaint) : super(repaint: repaint);   // repaint: Listenable -> no setState/rebuild
  final Float32List xy;                                                 // [x0,y0,x1,y1,...] — SoA from §1.3
  final Listenable repaint;
  static final _paint = Paint()..color = const Color(0xFFFFFFFF)..strokeWidth = 2..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRawPoints(PointMode.points, xy, _paint);                 // ONE call, zero Offset objects
  }
  @override
  bool shouldRepaint(ParticlePainter old) => old.xy != xy;              // buffer identity
}
```

* `drawRawPoints`, `drawRawAtlas`, `drawVertices(Vertices.raw(...))` take a `Float32List` — this is an API designed for SoA. One call instead of 10 000.
* `CustomPainter(repaint: animation)` — the painter listens to a `Listenable` and marks *only* the `RenderCustomPaint` for repaint; there is no `setState`, no widget rebuild.
* For full control: your own `LeafRenderObjectWidget` + `RenderBox` with `markNeedsPaint()` — layout computed once (`sizedByParent = true`, `computeDryLayout`), paint every frame, state in typed data. This is the lowest layer at which you are still in Dart.

A complete `RenderBox` driven by a `Ticker` (no `setState`, no rebuild, layout once):

```dart
class ParticlesWidget extends LeafRenderObjectWidget {
  const ParticlesWidget(this.store, {super.key});
  final ParticleStore store;                                   // Float32List xy + Float32List v, updated in place
  @override RenderObject createRenderObject(BuildContext context) => _RenderParticles(store);
  @override void updateRenderObject(BuildContext context, _RenderParticles r) => r.store = store;
}

class _RenderParticles extends RenderBox {
  // In production: pass `vsync` from SingleTickerProviderStateMixin to respect TickerMode (pause when off-screen).
  _RenderParticles(this._store) { _ticker = Ticker(_tick)..start(); }
  ParticleStore _store; late final Ticker _ticker; Duration _last = Duration.zero;
  static final _paint = Paint()..strokeWidth = 2..strokeCap = StrokeCap.round..color = const Color(0xFFFFFFFF);

  set store(ParticleStore s) { if (!identical(s, _store)) { _store = s; markNeedsPaint(); } }

  void _tick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6; _last = now;
    _store.step(dt, size);                                     // a pure loop over a Float32List, zero allocations
    markNeedsPaint();                                          // paint only; layout untouched
  }

  @override bool get sizedByParent => true;                    // layout: size from the parent, computed once
  @override Size computeDryLayout(BoxConstraints c) => c.biggest;
  @override bool get isRepaintBoundary => true;                // its own layer: does not repaint siblings
  @override void paint(PaintingContext ctx, Offset offset) {
    ctx.canvas..save()..translate(offset.dx, offset.dy)
      ..drawRawPoints(PointMode.points, _store.xy, _paint)     // 1 call for N particles
      ..restore();
  }
  @override void detach() { _ticker.stop(); super.detach(); }
  @override void attach(PipelineOwner owner) { super.attach(owner); if (!_ticker.isActive) _ticker.start(); }
  @override void dispose() { _ticker.dispose(); super.dispose(); }
}
```

Sprites: `drawRawAtlas` draws thousands of fragments of a single texture in one call, and you pass the transforms as a `Float32List` of RSTransform (scos, ssin, tx, ty) — ideal for SoA:

```dart
final rst = Float32List(n * 4);   // [scos, ssin, tx, ty] per sprite — updated in place every frame
final rects = Float32List(n * 4); // [left, top, right, bottom] in the atlas — constant
// in paint():
canvas.drawRawAtlas(atlasImage, rst, rects, null /* colors */, null /* blendMode */, null /* cullRect */, _paint);
// sprite rotation + scale with no allocations: rst[i*4] = s*cos(a); rst[i*4+1] = s*sin(a); rst[i*4+2] = x - ...; rst[i*4+3] = y - ...;
```

Text in a `CustomPainter`: `TextPainter.layout()` is expensive; keep one painter per label and recompute only when the content or the width changes:

```dart
// 🐢 — in paint(): TextPainter(text: TextSpan(text: label))..layout()..paint(canvas, p)   // per frame
// 🚀
final _labels = <String, TextPainter>{};
TextPainter _label(String s) => _labels.putIfAbsent(s, () => TextPainter(text: TextSpan(text: s, style: _style), textDirection: TextDirection.ltr)..layout());
// in paint(): _label('FPS 120').paint(canvas, offset);           // layout computed once
```

### 4.4 Animations: `Ticker` instead of `setState` per frame

🐢 `AnimationController` + `addListener(() => setState(() {}))` at the top of the screen: a rebuild of the whole tree 120×/s.

🚀 `AnimatedBuilder`/`ListenableBuilder` with `child:` (the subtree is passed once, not rebuilt) or `Transform`/`Opacity` driven by an `Animation<double>` without a rebuild; cheapest of all — a `RenderObject` listening to a `Ticker` and calling `markNeedsPaint()`.

### 4.5 Lists, images, text

* `ListView.builder`/`SliverList` with `itemExtent`/`prototypeItem` (layout without measuring every child); `addAutomaticKeepAlives: false`, `addRepaintBoundaries: false` when the items are cheap (a boundary per item costs more than it gives).
* Images: `cacheWidth`/`cacheHeight` (decode to the display size; a decoded 4000×3000 JPEG is a 48 MB texture), `ImageCache` has a 100 MB limit — what counts is GPU memory, not the Dart heap.
* Text: `TextPainter` layout is expensive; cache the `TextPainter`/`Paragraph` for constant labels in a `CustomPainter`, `RichText` instead of many `Text`s in a `Row`.
* The `Opacity` widget = `saveLayer` (offscreen buffer) — use `Opacity` only on leaves, or `AnimatedOpacity`/`FadeTransition` on a `RepaintBoundary`; for a single image `Image(opacity: ...)`, for a color `Color.withOpacity` in the `Paint`.
* `ClipRRect`/`ClipPath` with `Clip.antiAlias` on animating elements → `saveLayer`; prefer `Clip.hardEdge` or a `DecoratedBox` with `borderRadius`.

### 4.6 Flutter profiling checklist

1. **Always `--profile`** on a device (debug has assertions and JIT; release has no DevTools).
2. DevTools → Performance: enable `Track widget rebuilds` → find widgets with hundreds of rebuilds/s; `Track paints`/`Track layouts` → find repaints outside a `RepaintBoundary`.
3. Memory → `Allocation tracing`: see *which classes* are allocated in the frame loop. The goal is a "flat line" of the heap during an animation — a sawtooth every few hundred ms is a scavenge.
4. Timeline → look for `GC` events on the UI thread right before a long frame.
5. `flutter run --profile --trace-skia` (Raster) when the UI thread is clean and the frame is still long.
6. Doubts are settled by `dart compile exe --extra-gen-snapshot-options=--print-flow-graph-optimized,--disassemble` (or `flutter build apk --extra-gen-snapshot-options=...`): you will see whether `double` is unboxed, whether there is a `CheckSmi`, whether the write barrier was removed (`NoStoreBarrier`).

---

## 5. Production Dart/Flutter: 80 % of the gain for 20 % of the effort

### 5.1 Five patterns to adopt right away

| # | Pattern | Where | Gain (AOT, our benchmarks) |
|---|---|---|---:|
| 1 | **Typed data instead of `List<num>` for numeric data; preallocation instead of `add()`** | chart models, animations, audio, network buffers, parsers | 5–11× on building, 2.3× on reading `Uint8List`, zero GC |
| 2 | **Bytes, not Strings, at the I/O boundary**: `JsonUtf8Encoder`/`utf8.decoder.fuse(json.decoder)`, `response.add(bytes)`, `BytesBuilder(copy: false)`, `sublistView` | servers (`dart:io`, shelf, relic), HTTP clients, files, sockets | 1.6× (encoder), 100× (fragment assembly) |
| 3 | **Group commit**: one transaction per tick (`scheduleMicrotask`), prepared statements `persistent: true`, `stmt.raw` + `columnBlobInto` in the data layer | SQLite (`sqlite3`, drift), Isar `putAll`, ObjectBox `putMany` | 13× on writes, 4.7× on reads |
| 4 | **FFI: `@Native(isLeaf: true)` for pure functions, `asTypedList` instead of `ptr[i]`, out-pointers allocated once, `NativeFinalizer` + `Finalizable`** | every native plugin, your own C/Rust code | 4× per call, 900× on reading a buffer |
| 5 | **Isolates only for > 1 ms of CPU, with flat payloads (`Uint8List`/`TransferableTypedData`)** | parsing large files, compression, image processing | 128× on transfer vs a list of maps |

Plus one cross-cutting rule: **copy top-level/`static final` into a local variable before the loop** (2.3×, §1.6) and measure in AOT.

### 5.2 Side by side: "typical Dart" vs "12-Dollar-Server style"

**Data model in the frame loop**

```dart
// 🐢
List<Offset> points = frames.map((f) => Offset(f.x, f.y)).toList();
// 🚀
final Float32List points = Float32List(frames * 2);   // once; update in place; canvas.drawRawPoints(...)
```

**HTTP response (dart:io)**

```dart
// 🐢
response.write(jsonEncode({'posts': posts.map((p) => p.toJson()).toList()}));
// 🚀 (TechEmpower dart3)
response..contentLength = bytes.length..add(_jsonEncoder.convert(payload));
// 🚀🚀 (12-dollar Dart): precomputed error bodies + ByteWriter for successes
final _notFound = _response(404, '{"error":"not found"}');  // top-level final, built once
```

**Reading from SQLite into JSON**

```dart
// 🐢
for (final row in db.select('SELECT id, body FROM posts')) { out.add({'id': row['id'], 'body': row['body']}); }
return jsonEncode(out);
// 🚀 (dart-rawsocket-C-Hatton)
final rows = stFeed.select();          // stFeed: prepared, persistent, SELECT ... CAST(p.body AS BLOB) ...
for (final r in rows) { o.ascii('{"id":'); o.integer(r.columnAt(0) as int); o.ascii(',"body":'); o.str(r.columnAt(1) as Uint8List); ... }
// 🚀🚀 (sqlite3 >= 3.7)
final raw = stFeed.raw;
while (raw.step()) { w.integer(raw.columnInt64(0)); final n = raw.columnBlobInto(1, scratch); w.jsonString(scratch, 0, n); }
```

**Writing 10k records**

```dart
// 🐢
for (final r in records) { await isar.writeTxn(() => isar.items.put(r)); }   // / db.execute(...) per record
// 🚀
await isar.writeTxn(() => isar.items.putAll(records));                      // / BEGIN; prepared.execute() × N; COMMIT
```

**Native call**

```dart
// 🐢
final add = lib.lookupFunction<Int64 Function(Int64, Int64), int Function(int, int)>('add_i64');
// 🚀
@Native<Int64 Function(Int64, Int64)>(isLeaf: true, symbol: 'add_i64') external int addI64(int a, int b);
```

**Background work**

```dart
// 🐢
final models = await compute(parseJsonToModels, jsonString);   // String copied there, List<Model> copied back
// 🚀
final ttd = await Isolate.run(() => TransferableTypedData.fromList([parseToColumnarBytes(bytes)]));
final table = ColumnarTable(ttd.materialize());               // Float64List/Int32List views over a single buffer
```

**List state in Flutter (10k rows, filtering on every keystroke)**

```dart
// 🐢 — a new list + new widgets + a rebuild of the whole screen on every character
setState(() => visible = all.where((p) => p.name.contains(query)).toList());

// 🚀 — indices in an Int32List, rebuild only the list via ValueNotifier, widgets with const constructors
final visibleIdx = ValueNotifier<Int32List>(Int32List(0));
void filter(String q) {
  var c = 0; for (var i = 0; i < all.length; i++) { if (all[i].name.contains(q)) c++; }
  final idx = Int32List(c); var j = 0;
  for (var i = 0; i < all.length; i++) { if (all[i].name.contains(q)) idx[j++] = i; }
  visibleIdx.value = idx;                                      // only the ValueListenableBuilder around ListView.builder rebuilds
}
```

**Event stream (sensors, websocket) → chart**

```dart
// 🐢
stream.map((e) => Sample(e.t, e.v)).listen((s) => setState(() => samples.add(s)));   // an object per sample, a rebuild per sample, the list grows without end
// 🚀 — a ring buffer in a Float64List, repaint via Listenable, no rebuild
class FrameTick extends ChangeNotifier { void fire() => notifyListeners(); }
final ring = Float64List(4096); var head = 0; final tick = FrameTick();
stream.listen((e) { ring[head] = e.v; head = (head + 1) & 4095; });
Ticker((_) => tick.fire()).start();                            // 1 repaint per frame, regardless of the number of samples
// CustomPainter(repaint: tick) draws `ring` via drawRawPoints / a Path built once per frame
```

**Serialization to a file/cache (e.g. writing 50k records)**

```dart
// 🐢
await File(p).writeAsString(jsonEncode(records.map((r) => r.toJson()).toList()));    // 50k Maps + one 10 MB String + utf8
// 🚀 — a binary format with a fixed-size record: ByteData, one write, reads via views with no parsing
final bd = ByteData(records.length * 16);
for (var i = 0; i < records.length; i++) { bd.setInt32(i * 16, records[i].id, Endian.little); bd.setFloat64(i * 16 + 4, records[i].score, Endian.little); }
await File(p).writeAsBytes(bd.buffer.asUint8List(), flush: true);
// read: final bd = ByteData.sublistView(await File(p).readAsBytes()); id(i) => bd.getInt32(i*16, Endian.little);  — zero parsing, zero objects
```

### 5.3 How to measure (the `benchmarks/` repo)

```bash
cd benchmarks
dart pub get
tool/build_native.sh                      # libfastmath.so for the FFI benchmark (gcc/clang)
dart run bin/run_all.dart --only json,ffi # JIT, selected groups
tool/run.sh                               # JIT + AOT (dart build cli), results in results/{jit,aot}.md
```

The harness (`lib/harness.dart`) does a 100 ms warm-up, picks the iteration count for a ~300 ms trial, takes the **median of 7 trials** and shows min/max. `blackHole()` (`@pragma('vm:never-inline')`) protects the result from being removed by the optimizer. Read the machine code when a result surprises you — as Egorov puts it in "Microbenchmarks are experiments": a benchmark is an experiment to interpret, not a verdict.

### 5.4 Three practical exercises (refactoring katas)

**Kata 1 — Allocation-free parser (`benchmarks/lib/src/bench_buffers.dart`)**

`_parseIdiomatic` returns a `ParsedString` with a `Map<String,String>`; `_parseBytes` returns offsets (0.93 µs vs 3.7 µs). Task: (a) add support for multiple requests in one buffer (pipelining) — a loop over `headerEnd + contentLength`, (b) replace `ParsedBytes` with an `Int32List(8)` (method/path/auth as offset pairs) and check whether AOT removed the bounds checks (`--disassemble`), (c) add a variant with `String.fromCharCodes` only for `path` and measure how much *one* String costs. Goal: < 1 µs per request with 8 headers, zero allocations apart from that one String.

**Kata 2 — "Per tick" group commit on top of `package:sqlite3` (`benchmarks/lib/src/bench_sqlite.dart`)**

Implement the `WriteBatcher` from §2.5 and write a benchmark that simulates 1000 "requests" arriving as 1000 calls to `Future.microtask(() => batcher.submit(...))` in a single loop iteration. Compare: (a) `await` on each one separately (autocommit), (b) the batcher with `scheduleMicrotask`, (c) the batcher with `Timer(Duration(milliseconds: 1))`. Measure the total time and the **latency of the first request** in each variant. Then replace `insert.execute([a, b])` with `insert.raw..bindInt64(1, a)..bindBlob(2, bytes)..step()` and `reset()` — how many allocations disappear? (Check with `dart run --observe` → Memory → Allocation tracing.)

**Kata 3 — From `List<Particle>` to `drawRawPoints` (a Flutter project)**

Take `bench_soa.dart` as the model: create a `CustomPainter` that draws 10 000 particles. Version A: `List<Particle>` + `canvas.drawCircle(Offset(...), r, paint)` in a loop, `setState` from a `Ticker`. Version B: `Float32List xy` + `drawRawPoints`, `CustomPainter(repaint: ticker)` without `setState`, a `RepaintBoundary` around the `CustomPaint`. In DevTools (`--profile`) compare: UI thread time per frame, the number of rebuilds, the heap chart (GC sawtooth). Goal: B below 1 ms of UI thread and a flat heap over 10 s of animation. Bonus: move the physics step to C via FFI `isLeaf` with the `Float32List` as a `Pointer<Float>` (`asTypedList` on a `malloc` buffer, so that the same buffer serves both C and `drawRawPoints`).

---

## Appendix — what exactly we read

| Repository / file | Lines, fragments |
|---|---|
| `sqlite3.dart/sqlite3/lib/src/ffi/libsqlite3.g.dart` | `@Native` externs, `isLeaf: true` on 10 functions, `addresses` for the finalizers |
| `sqlite3.dart/sqlite3/lib/src/ffi/bindings.dart` | `databaseFinalizer`, `statementFinalizer`, `FfiStatement(... borrowed)`, `sqlite3_bind_text` with `allocate.nativeFree`, `sqlite3_column_blob_into` |
| `sqlite3.dart/sqlite3/lib/src/ffi/memory.dart` | `nullPtr<T>()` with `vm:prefer-inline` (workaround for sdk#39488), `allocateBytes`, `allocateBytesWithFinalizer`, `readString` |
| `sqlite3.dart/sqlite3/lib/src/implementation/statement.dart` | `_selectResults`, `_readValue`, `_ActiveCursorIterator`, `hasNativeInts` |
| `sqlite3.dart/sqlite3/lib/src/statement.dart` | `extension type RawPreparedStatement`, `columnBlobInto` |
| `sqlite3.dart/sqlite3/tool/generate_bindings.dart` | `_leafFunctions` + the comment "Leaf functions must never call back into Dart" |
| `FrameworkBenchmarks/frameworks/Dart/dart3/dart_aot/bin/server.dart` | `MAX_ISOLATES`, `Isolate.spawnUri` as a new group, `shared: true`, `_sendResponse` |
| `FrameworkBenchmarks/frameworks/Dart/{shelf,relic,dart_frog,angel3}` | routing switch instead of `shelf_router`, `Body.fromData(bytes)`, anti-patterns (`Response.json`, 100 isolates × pool of 20) |
| `flatbuffers/dart/lib/flat_buffers.dart` | `BufferContext`, `_getUint32(offset) => _buffer.getUint32(offset, Endian.little)`, `Reader.vTableGet`, 88× `vm:prefer-inline`, `_tryWriteASCIIString` |
| `objectbox-dart/objectbox/lib/src/native/bindings/flatbuffers.dart` | `BuilderWithCBuffer`, `Allocator` on `malloc`, `resetIfLarge` |
| `objectbox-dart/objectbox/lib/src/modelinfo/entity_definition.dart` | `objectFromData` (`asTypedList` → `ByteData.view`) |
| `objectbox-dart/objectbox/lib/src/native/bindings/helpers.dart`, `store.dart` | `ReadPointers`, `CursorHelper.get` |
| `isar/packages/isar/lib/src/isar_core.dart`, `native/bindings.dart`, `ffigen.yaml` | `ptrPtr/countPtr/boolPtr`, `readString` with an ASCII flag, 58× `isLeaf`, `_nullInt/_nullLong` sentinel |
| `dart-lang/sdk/runtime/docs/{README,gc,glossary,types,pragmas,compressed-pointers}.md` | Smi/Mint, object header, new/old alignment, TLAB, scavenger, the write barrier and its elimination, safepoints, `vm:prefer-inline`, `vm:never-inline`, `vm:deeply-immutable`, `vm:unsafe:no-bounds-checks` |
| `twelve-dollar-server-challenge` PR #46 `dart-rawsocket-C-Hatton/bin/server.dart` | `_Conn.onData`, `_parseHead`, `_Out.str`, `_feed`, `_auth`, precomputed `_notFound`… |
