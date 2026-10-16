---
name: dart-benchmark
description: Writing and running reliable Dart microbenchmarks with this repo's harness (benchmarks/lib/harness.dart) and end-to-end benchmarks (packages/users_pipeline) - warm-up, median of samples, blackHole, JIT vs AOT (dart build cli for packages with native hooks), reading results and inspecting generated code (--print-flow-graph-optimized, --disassemble). Use when something must be measured ("is this faster?"), a new benchmark must be added to benchmarks/, an optimization must be verified with numbers, or a surprising result must be explained.
---

# dart-benchmark — measure before you believe

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory.

Harness: `benchmarks/lib/harness.dart` (`Suite`, `BenchResult`, `blackHole`, `toMarkdown`). Runner: `benchmarks/bin/run_all.dart`. JIT+AOT script: `benchmarks/tool/run.sh`. Reference results: `benchmarks/RESULTS.md`. End-to-end benchmark with real fetch: `packages/users_pipeline/bin/users_bench.dart` (`measure`, `runUsersBenchmark`, `assertVariantsAgree`).

## 1. Adding a benchmark

1. Create `benchmarks/lib/src/bench_<topic>.dart` with a function `List<Suite> suites()`.
2. Each `Suite` = one question, the first `add` = the baseline (🐢), the following ones = variants (🚀). Names say *what* is measured and the data size (`'json/encode feed (20 posts, ~2.6 KB)'`).
3. Pass every function's result through `blackHole(...)` (`@pragma('vm:never-inline')`), otherwise the optimizer removes dead code.
4. Create input data **once** at library level and **copy it to a local/parameter** before the loop (a top-level `final` is a lazy getter, 2.3× slower — this mistake alone can flip a result).
5. Register the group in `_groups` in `bin/run_all.dart`.
6. Check that the variants produce identical results (as `bench_json.dart` compares the bytes of three encoders and `assertVariantsAgree` compares pipeline outputs) — a benchmark of something that computes something else is worthless.

Template:

```dart
import 'dart:typed_data';
import '../harness.dart';

const _n = 10_000;
final Int32List _data = Int32List.fromList(List.generate(_n, (i) => i));

int _slow(List<int> d) { var s = 0; for (final v in d) { s += v; } return s; }
int _fast(Int32List d) { var s = 0; for (var i = 0; i < d.length; i++) { s += d[i]; } return s; }

List<Suite> suites() => [
  Suite('topic/sum (10k)')
    ..add('List<int> for-in', () => blackHole(_slow(_data)))
    ..add('Int32List indexed', () => blackHole(_fast(_data))),
];
```

For asynchronous code (isolates, I/O) the harness is synchronous — time N `await`s manually with a `Stopwatch`, median of samples (template: `runIsolateSuite` in `bench_isolates.dart`, `runIsolateBenchmark` in `users_pipeline/lib/src/bench.dart`).

## 2. Running

```bash
cd benchmarks && dart pub get
tool/build_native.sh                          # only for the ffi group (gcc/clang)
dart run bin/run_all.dart --only topic        # JIT, quick
tool/run.sh                                   # JIT + AOT -> results/jit.md, results/aot.md, *.json
tool/run.sh topic,json                        # selected groups

cd packages/users_pipeline
dart run bin/users_bench.dart --file data/users_10k.json --md results/jit.md     # end-to-end, local data
dart compile exe bin/users_bench.dart -o build/users_bench && ./build/users_bench --md results/aot.md
```

AOT: packages with build hooks (`sqlite3` ≥ 3) do not work with `dart compile exe` — the script uses `dart build cli -o build/aot` and runs `build/aot/bundle/bin/run_all`. Flutter release = AOT, so **AOT is the number that counts** for mobile apps; JIT for `dart run` servers and tests.

Harness: 100 ms warm-up → iterations sized for a ~300 ms sample → 7 samples → **median**, plus min/max. Reduce `Suite(sampleMillis:, samples:)` for slow operations (SQLite 10k inserts: `sampleMillis: 1, samples: 3`).

## 3. Reading results

- Compare **medians**, look at the spread (min–max). A < 10 % difference with a 20 % spread = noise, not a result.
- JIT ≠ AOT: JIT speculates on types (a `List<int>` sum as fast as `Int32List`), AOT does not (1.6–2.3× difference). If an optimization helps in only one mode, say which.
- Typed-data gains are largest in **building** (allocation, boxing) and writing, not in sequential reads of small cache-resident data.
- End-to-end beats microbenchmarks for decisions: the fused JSON decoder is 1.2× in isolation but only trims 76 → 54 ms on 10k users, because the tree and `fromJson` dominate.
- `rssDeltaBytes` in `BenchResult` is indicative only (RSS also grows through GC heap growth); use DevTools for allocations.
- Record in `RESULTS.md` only results from `tool/run.sh` (both modes) with the date, Dart version and CPU.

## 4. When a result surprises you: read the code

Egorov ("Microbenchmarks are experiments"): a benchmark is an experiment to be interpreted by reading the generated code, not a verdict.

```bash
# AOT, one function:
dart compile exe bin/x.dart -o /tmp/x \
  --extra-gen-snapshot-options=--print-flow-graph-optimized \
  --extra-gen-snapshot-options=--print-flow-graph-filter=_fast \
  --extra-gen-snapshot-options=--disassemble
# JIT:
dart --print-flow-graph-optimized --print-flow-graph-filter=_fast --disassemble-optimized --no-background-compilation bin/x.dart
```

What to look for in the IL: `CheckSmi`/`CheckClass` (speculation, deopt), `Box`/`Unbox` (double/int boxing), `StoreIndexed ... NoStoreBarrier` (no barrier — good), `CheckArrayBound` (an unhoisted bounds check), `CheckStackOverflow` in the loop header (normal), `InitStaticField`/lazy-field getter calls (the pitfall from §1), `BinaryInt64Op` instead of `BinarySmiOp` (unboxed int).

Diagnostic/steering pragmas (`runtime/docs/pragmas.md`): `@pragma('vm:prefer-inline')`, `vm:never-inline` (always honored), `vm:align-loops`; **do not** use `vm:unsafe:*` in production without consent.

## 5. Common benchmark mistakes

- Result unused → code removed → "0 ns". Always `blackHole`.
- Data created inside the measured function → you measure data allocation, not the algorithm (unless deliberate, as in `typed_lists/build`).
- One sample, no warm-up (JIT), comparing JIT with AOT.
- A loop with a constant iteration count that the compiler partially evaluates at compile time → use data from `List.generate` with a non-trivial function or from a file.
- Changed conditions between variants (different data size, different output).
- Comparing `TransferableTypedData` without accounting for the copy in `fromList`.
- Network in the measured section: measure the fetch once and separately (`users_bench.dart` prints fetch times apart from the CPU benchmark).
