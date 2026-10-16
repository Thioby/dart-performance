---
name: dart-benchmark
description: Writing and running reliable Dart microbenchmarks and end-to-end benchmarks in any project - a drop-in harness (warm-up, median of samples, blackHole), JIT vs AOT (dart compile exe / dart build cli for packages with native hooks), differential correctness checks, reading results and inspecting generated code (--print-flow-graph-optimized, --disassemble). Use when something must be measured ("is this faster?"), a benchmark must be added to a project, an optimization must be verified with numbers, or a surprising result must be explained.
---

# dart-benchmark — measure before you believe

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory. Self-contained: works in any Dart/Flutter project.

## 1. Drop-in harness

Put this in `tool/bench/harness.dart` (or `benchmark/harness.dart`) of the project. No dependencies.

```dart
import 'dart:io';
import 'dart:math' as math;

typedef BenchFn = void Function();

class BenchResult {
  final String suite, name; final double nsPerOp; final List<double> samples;
  BenchResult(this.suite, this.name, this.nsPerOp, this.samples);
}

class Suite {
  final String name; final int sampleMillis, samples; final _cases = <(String, BenchFn, BenchFn?)>[];
  Suite(this.name, {this.sampleMillis = 300, this.samples = 7});
  void add(String caseName, BenchFn fn, {BenchFn? setup}) => _cases.add((caseName, fn, setup));

  List<BenchResult> run() {
    stdout.writeln('\n== $name ==');
    final out = <BenchResult>[];
    for (final (caseName, fn, setup) in _cases) {
      setup?.call();
      final warm = Stopwatch()..start(); var warmIters = 0;
      while (warm.elapsedMilliseconds < 100) { fn(); warmIters++; }          // warm-up (JIT needs it; AOT levels caches)
      final nsPerWarmOp = warm.elapsedMicroseconds * 1000 / math.max(1, warmIters);
      final iters = (sampleMillis * 1e6 / math.max(1, nsPerWarmOp)).round().clamp(1, 1 << 30);
      final times = <double>[]; final sw = Stopwatch();
      for (var s = 0; s < samples; s++) {
        sw..reset()..start();
        for (var i = 0; i < iters; i++) { fn(); }
        sw.stop();
        times.add(sw.elapsedMicroseconds * 1000 / iters);
      }
      times.sort();
      final r = BenchResult(name, caseName, times[times.length ~/ 2], times);   // MEDIAN
      out.add(r);
      final base = out.first.nsPerOp / r.nsPerOp;
      stdout.writeln('  ${caseName.padRight(48)} ${_fmt(r.nsPerOp).padLeft(12)}  '
          '[min ${_fmt(times.first)}, max ${_fmt(times.last)}]  '
          '${identical(r, out.first) ? '(baseline)' : '${base.toStringAsFixed(2)}x ${base >= 1 ? 'faster' : 'SLOWER'}'}');
    }
    return out;
  }

  static String _fmt(double ns) => ns < 1e3 ? '${ns.toStringAsFixed(1)} ns'
      : ns < 1e6 ? '${(ns / 1e3).toStringAsFixed(2)} µs' : '${(ns / 1e6).toStringAsFixed(2)} ms';
}

/// Keeps a result alive so the optimizer cannot delete the work (like Rust's black_box).
@pragma('vm:never-inline')
void blackHole(Object? value) { _sink = value; }
Object? _sink;
Object? get lastBlackHoleValue => _sink;
```

Alternative: `package:benchmark_harness` (`BenchmarkBase`, reports µs per `run()`); it has no median/spread, so add your own repetition.

## 2. Writing a benchmark

1. One `Suite` = one question. The first `add` is the baseline (🐢), the rest are variants (🚀). Names say *what* and the data size: `'json/encode feed (20 posts, ~2.6 KB)'`.
2. Pass every result through `blackHole(...)`, otherwise dead code is eliminated and you measure nothing.
3. Create input data **once**, outside the measured function, and **copy it to a local/parameter** before the loop — a top-level `final` is a lazy getter (~2.3× slower) and this alone can flip a result.
4. Check that the variants compute the same thing (compare bytes/outputs in a `main()` sanity check or a test) — a faster function with a different answer is not a result.
5. For async code (isolates, I/O) the harness is synchronous: time N `await`s with a `Stopwatch`, take the median of several runs.

```dart
import 'dart:typed_data';
import 'harness.dart';

const _n = 10_000;
final Int32List _data = Int32List.fromList(List.generate(_n, (i) => (i * 7919) % 1000));

int _slow(List<int> d) { var s = 0; for (final v in d) { s += v; } return s; }
int _fast(Int32List d) { var s = 0; for (var i = 0; i < d.length; i++) { s += d[i]; } return s; }

void main() {
  Suite('sum (10k)')
    ..add('List<int> for-in', () => blackHole(_slow(_data)))
    ..add('Int32List indexed', () => blackHole(_fast(_data)))
    ..run();
}
```

End-to-end benchmarks (fetch → decode → filter → encode) matter more than microbenchmarks for decisions: a fused JSON decoder is ~1.2× in isolation but trims only ~30 % on a 10k-record payload, because the object tree and `fromJson` dominate. Measure the fetch once and separately; the network's noise is not your code.

## 3. Running: JIT and AOT

```bash
dart run tool/bench/main.dart                 # JIT (servers run like this; needs warm-up)
dart compile exe tool/bench/main.dart -o build/bench && ./build/bench     # AOT = how Flutter release runs
dart build cli -o build/aot                   # AOT for packages with native-asset build hooks (e.g. sqlite3 >= 3)
```

**AOT is the number that counts** for mobile apps. JIT speculates on types (a `List<int>` sum is as fast as `Int32List`), AOT does not (~1.6–2.3× difference). If an optimization helps in only one mode, say which.

Reduce `Suite(sampleMillis:, samples:)` for slow operations (e.g. 10k database inserts: `sampleMillis: 1, samples: 3`). Run on a quiet machine; a shared CI runner adds ±10 % noise.

## 4. Reading results

- Compare **medians**, look at the spread (min–max). A < 10 % difference with a 20 % spread = noise, not a result.
- Typed-data gains are largest in **building** (allocation, boxing) and writing, not in sequential reads of small cache-resident data.
- RSS deltas are indicative only (GC heap growth); for allocations use DevTools Allocation tracing.
- Record results with the date, Dart version, CPU and mode (JIT/AOT), and keep the raw per-sample numbers.

## 5. When a result surprises you: read the code

A benchmark is an experiment to be interpreted by reading the generated code, not a verdict.

```bash
# AOT, one function:
dart compile exe bin/x.dart -o /tmp/x \
  --extra-gen-snapshot-options=--print-flow-graph-optimized \
  --extra-gen-snapshot-options=--print-flow-graph-filter=_fast \
  --extra-gen-snapshot-options=--disassemble
# JIT:
dart --print-flow-graph-optimized --print-flow-graph-filter=_fast --disassemble-optimized --no-background-compilation bin/x.dart
```

What to look for in the IL: `CheckSmi`/`CheckClass` (speculation, deopt), `Box`/`Unbox` (double/int boxing), `StoreIndexed ... NoStoreBarrier` (no barrier — good), `CheckArrayBound` (an unhoisted bounds check), `CheckStackOverflow` in the loop header (normal), `InitStaticField`/lazy-field getter calls (the pitfall from §2), `BinaryInt64Op` instead of `BinarySmiOp` (unboxed int).

Pragmas: `@pragma('vm:prefer-inline')`, `vm:never-inline` (always honored), `vm:align-loops`; **do not** use `vm:unsafe:*` in production without consent.

## 6. Common benchmark mistakes

- Result unused → code removed → "0 ns". Always `blackHole`.
- Data created inside the measured function → you measure data allocation, not the algorithm (unless deliberate).
- One sample, no warm-up (JIT), comparing JIT with AOT.
- A loop with a constant iteration count that the compiler partially evaluates → use generated or file data.
- Changed conditions between variants (different data size, different output).
- Comparing `TransferableTypedData` without accounting for the copy in `fromList`.
- Network or disk inside the measured section.

Background reading with runnable benchmarks: https://github.com/Thioby/dart-performance
