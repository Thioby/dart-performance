---
name: dart-perf-review
description: Performance audit of Dart/Flutter code focused on hot paths - allocations, boxing, typed data, JSON, buffers, async overhead, lazily initialized globals. Use when the user says "optimize", "slow", "jank", "lag", "GC", "memory usage", "performance" about Dart or Flutter code, or asks for a performance review. Produces a list of concrete findings with fixes and estimated gains; does not change architecture without asking.
---

# dart-perf-review — hot-path audit for Dart/Flutter

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory.

You are a performance reviewer. Your deliverable is a **list of findings** in the form:
`file:line — problem — fix (code) — expected gain — how to verify`.
Do not rewrite whole files. Do not change architecture (isolates, database, framework) without asking — propose it instead.

Full reasoning and numbers: `docs/en/dart-flutter-extreme-performance-guide.md` (sections 1, 2, 3, 5, 6). Benchmarks for verification: `benchmarks/` (`tool/run.sh`) and the end-to-end case study `packages/users_pipeline/` (10k users from JSON: 93.6 ms → 12.0 ms). If the repository you are working in does not have them, the rules below are self-contained.

## Step 1: find the hot path before you fix anything

Ask yourself (or the user) *what* runs often: per frame (`build`, `paint`, `Ticker`), per request/packet (`onData`, an HTTP handler), per row (parsers, loops over data). Optimize **only** that. Leave code that runs once at startup alone.

If unsure: ask for a profile (`dart run --observe` / DevTools `Performance` + `Memory → Allocation tracing`) or write a benchmark (skill `dart-benchmark`).

## Step 2: finding checklist (largest gain first)

### A. Allocations in loops (GC jank)

Look for, in hot paths: `new`/constructors, `[]`/`{}` literals, `.map(`, `.where(`, `.toList()`, `.toSet()`, `List.generate`, `String +`, `'$a'` interpolation, `.substring`, `.split`, `Offset(`, `Rect.fromLTWH(`, `Paint()`, `TextStyle(`, `EdgeInsets.` without `const`, closures capturing variables.

Fixes:
- immutable objects → `const` / `static final` built once;
- `map/where/toList` → one `for` loop with a preallocated result (4.6×);
- `List<double>`/`List<int>` built with `add()` → `Float64List(n)`/`Int32List(n)` (5–11×);
- `List<Model>` updated every frame → Struct-of-Arrays on typed lists (14×);
- `String +=` → `StringBuffer` (3.6×) or bytes into a `Uint8List` when the result goes to I/O (10×).

### B. Boxing and number representation

- `List<double>`, `Map<_, double>`, `num`/`Object`/`dynamic` fields holding doubles → each value is a 16 B object. Switch to `Float64List`/`Float32List` or fields with a static `double` type (AOT keeps them unboxed).
- `int` outside ±2^62 → Mint (an object). Compute hashes with `& 0x3fffffff` / in an `Int32List`.
- `Map<int,int>` as a histogram/lookup over a small key range → `Int32List(range)` (10.8×).

### C. Lazily initialized globals in loops

`final x = ...;` / `static final` / `late final` with an initializer, read in a loop → a getter with an "initialized?" check on every access (2.3× slower). Fix: `final local = x;` before the loop, or pass it as a parameter.

### D. I/O boundary: Strings where bytes should be

- `jsonEncode(x)` + `utf8.encode` → `JsonUtf8Encoder().convert(x)` held in a field/top-level (1.6×); `response.write(str)` → `response..contentLength = b.length..add(b)`.
- `jsonDecode(utf8.decode(bytes))` → `utf8.decoder.fuse(json.decoder).convert(bytes)` (1.2×); when you need 1–2 fields from a large JSON → a streaming parser or a binary format. Remember the case study: the fused decoder alone buys ~30 %; the tree and `fromJson` are the real cost (76 → 54 ms vs 12 ms with a byte scanner).
- Assembling chunks from a `Socket`/`Stream<List<int>>`: `List<int>.addAll` or a new `Uint8List` copy per chunk → `BytesBuilder(copy: false)` (100×) or a preallocated buffer + `Uint8List.sublistView` (400×).
- `utf8.decode` + `split` for protocol parsing → a byte scan over `Uint8List` with offsets (4×).
- Constant responses (errors, headers) → precomputed `Uint8List` in a top-level `final`.
- `DateTime.parse` ×N in `fromJson` when dates are never compared → keep epoch ms or an offset into the string.

### E. Async and isolates

- `async`/`await` in a function that never waits → a `Future` + microtask per call; drop `async` or return synchronously.
- `await for` with `.timeout()` per element → serializes the stream and allocates a `Timer`; use `listen` with a synchronous handler.
- `compute()`/`Isolate.run` for work < 1 ms → the spawn costs ~0.1–0.35 ms plus a payload copy; do it synchronously.
- `SendPort.send(List<Map>)` → 128× slower than a `Uint8List`; `Isolate.run` returning 10k model objects is slower than parsing on the main thread (103 vs 94 ms). Redesign the payload as flat bytes (skill `dart-isolates`).

### F. Database / FFI

- `execute(sql, args)` per row → a prepared statement with `persistent: true` + one transaction per batch (13×).
- `select()` → `ResultSet` and `row['col']` in a loop over thousands of rows → `stmt.raw` (`step()`, `columnInt64`, `columnBlobInto`) (4.7×).
- `lookupFunction` / `@Native` without `isLeaf` on short, pure C functions → `isLeaf: true` (4×), only if the function never calls back into Dart and never blocks (skill `dart-ffi-perf`).
- `ptr[i]` in a loop → `ptr.asTypedList(n)` (900×).

### G. Flutter (if the code is widget code)

`setState` high in the tree, missing `const`, allocations in `build`, `Opacity`/`ClipPath` on animations, `canvas.drawCircle` in a loop instead of `drawRawPoints`, no `RepaintBoundary` around independent animations, `ListView(children: ...)` instead of `.builder`. Details: skill `flutter-render-perf`.

## Step 3: report format

```
## Findings (sorted by gain)

1. lib/feed/parser.dart:42 — `utf8.decode(chunk).split('\n')` in `onData` per packet
   Fix: byte scan over Uint8List with offsets (example below)
   Gain: ~4× on parsing, zero String allocations per line
   Verify: benchmarks `--only buffers` / DevTools Allocation tracing on class _OneByteString

2. ...

## Deliberately left alone
- lib/app/bootstrap.dart — runs once, allocations irrelevant.

## Architectural proposals (need a decision)
- Move image decoding to an isolate with TransferableTypedData (~8 ms of work per image).
```

Every fix must show **code before and after**, not just a description. If the gain is uncertain, write "to be measured" and add a benchmark sketch instead of a number.

## What NOT to do

- Do not replace `List<int>` with typed data in code that runs once or in small collections (< 100 elements) — the gain is unmeasurable and readability drops.
- Do not sprinkle `@pragma('vm:prefer-inline')` everywhere; only on tiny accessors called in loops (as `flat_buffers.dart` does).
- Do not use `@pragma('vm:unsafe:no-bounds-checks')` or `vm:unsafe:no-interrupts` without explicit consent — the first removes memory safety, the second blocks GC.
- Do not promise numbers beyond the benchmarks; JIT and AOT differ (e.g. a `List<int>` sum is as fast as `Int32List` in JIT and 1.6× slower in AOT).
