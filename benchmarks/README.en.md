> 🇬🇧 English version · [🇵🇱 Wersja polska](README.md)

# benchmarks — "slow vs fast" in Dart

Each group pairs idiomatic code (baseline) with zero-allocation / typed-data / FFI variants. The numbers feed the guide `docs/en/dart-flutter-extreme-performance-guide.md`.

## Running

```bash
dart pub get
tool/build_native.sh                      # libfastmath.so (gcc/clang) for the ffi group
dart run bin/run_all.dart                 # JIT, everything
dart run bin/run_all.dart --only json,ffi # selected groups
dart run bin/run_all.dart --json out.json --md out.md
tool/run.sh [groups]                      # JIT + AOT -> results/{jit,aot}.{md,json}
```

AOT: `dart build cli -o build/aot` (package `sqlite3` ≥ 3 has build hooks; `dart compile exe` does not support them). Binary: `build/aot/bundle/bin/run_all`.

## Groups (`--only`)

| Group | File | Question |
|---|---|---|
| `typed` | `lib/src/bench_typed_lists.dart` | `List<int>`/`List<double>` vs `Int32List`/`Uint8List`/`Float64List`: sum and build; the lazy top-level `final` pitfall |
| `soa` | `lib/src/bench_soa.dart` | `List<Particle>` (AoS, immutable map) vs Struct-of-Arrays vs flat stride — one physics frame for 10k particles |
| `json` | `lib/src/bench_json.dart` | `jsonEncode`+`utf8.encode` vs `JsonUtf8Encoder` vs hand-written `ByteWriter`; `jsonDecode(utf8.decode)` vs fused decoder |
| `strings` | `lib/src/bench_strings.dart` | `+=` vs `StringBuffer` vs bytes into `Uint8List` |
| `buffers` | `lib/src/bench_buffers.dart` | assembling socket chunks (4 ways); HTTP parsing: split/Map vs byte scan |
| `collections` | `lib/src/bench_collections.dart` | `where/map/toList` vs loops; `fold/reduce` vs loop; `Map<int,int>` vs `Int32List` |
| `ffi` | `lib/src/bench_ffi.dart` + `native/fastmath.c` | `isLeaf` vs non-leaf; dot product Dart vs C; `ptr[i]` vs `asTypedList`; malloc vs Arena vs reused buffer |
| `sqlite` | `lib/src/bench_sqlite.dart` | 10k INSERTs: autocommit vs prepared vs batches vs one transaction; `select()` vs `selectCursor()` vs `stmt.raw`; TEXT→String vs `CAST AS BLOB`+`columnBlobInto` |
| `isolates` | `lib/src/bench_isolates.dart` | `SendPort` with `List<Map>` vs `Uint8List` vs `TransferableTypedData` (120 KB and 16 MB); cost of `Isolate.run` |

## Harness (`lib/harness.dart`)

- 100 ms warm-up, iterations sized for ~`sampleMillis` (300 ms), `samples` (7) runs, reported **median** plus min/max,
- `blackHole(value)` with `@pragma('vm:never-inline')` protects results from dead-code elimination,
- `toMarkdown(results)` generates the tables for `RESULTS.md`, `BenchResult.toJson()` the raw data.

Suite and variant names printed by the runner (and used in `RESULTS.md`) are in English; the Polish guide quotes them verbatim.

## Adding a benchmark

See the skill `.claude/skills/dart-benchmark/SKILL.md` (template, rules, reading IL).
