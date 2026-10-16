> 🇬🇧 English version · [🇵🇱 Wersja polska](README.md)

# dart-performance

A workshop on "how to write extremely fast code": two guides (Rust and Dart/Flutter), a set of Claude Code skills for Dart/Flutter performance work, and a benchmark package of "slow vs fast" pairs so every technique can be measured (JIT and AOT).

## Contents

| Path | What it is |
|---|---|
| [`docs/en/rust-extreme-performance-guide.md`](docs/en/rust-extreme-performance-guide.md) ([PL](docs/rust-extreme-performance-guide.md)) | Guide to the winning code of the [Twelve Dollar Server Challenge](https://github.com/arjaythedev/twelve-dollar-server-challenge): `io_uring` vs Axum, group commit, zero allocation, `unsafe` and `Cargo.toml` audit, production cheat sheet, 3 katas |
| [`docs/en/dart-flutter-extreme-performance-guide.md`](docs/en/dart-flutter-extreme-performance-guide.md) ([PL](docs/dart-flutter-extreme-performance-guide.md)) | Dart/Flutter guide: Dart VM (Smi/boxing/GC/typed data), `dart:ffi` based on `sqlite3.dart`/Isar/ObjectBox, isolates without copying, Flutter (Impeller/RenderObject), cheat sheet + 3 katas. Numbers come from `benchmarks/` |
| [`benchmarks/`](benchmarks/) ([README EN](benchmarks/README.en.md)) | Dart package: harness + 9 benchmark groups (typed data, SoA, JSON, strings, buffers/HTTP, collections, FFI `isLeaf`/`asTypedList`, SQLite group commit and `stmt.raw`, isolates/`TransferableTypedData`). `tool/run.sh` runs JIT and AOT |
| [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) | Reference results (Dart 3.13.5, Linux x64, 4 vCPU) |
| [`packages/users_pipeline/`](packages/users_pipeline/) | **Case study**: 10k users from JSON (real fetch from raw GitHub/a gist, local fallback) → decode → filter/sort/group → encode, 4 variants from `jsonDecode`+`fromJson`+`where` to a byte scanner → columns; `Isolate.run` with `List<User>` vs `TransferableTypedData`. AOT: 93.6 ms → 12.0 ms (7.8×) |
| [`flutter_bench/`](flutter_bench/) | Flutter app with the same variants + a frame-jank counter (`addTimingsCallback`); `flutter test` drives every variant |
| [`.claude/skills/`](.claude/skills/) | Claude Code skills (English, Polish copies as `SKILL.pl.md`): `dart-perf-review`, `dart-zero-alloc`, `dart-ffi-perf`, `dart-isolates`, `flutter-render-perf`, `dart-benchmark` |

## Quick start

```bash
# Dart SDK >= 3.6 (tested on 3.13.5); gcc/clang for the FFI benchmark
cd benchmarks
dart pub get
tool/build_native.sh                 # native/libfastmath.so
dart run bin/run_all.dart --only json,typed,soa   # JIT, selected groups
tool/run.sh                          # full JIT + AOT run -> results/{jit,aot}.md
```

AOT is built with `dart build cli` (package `sqlite3` ≥ 3 uses native-asset build hooks, which `dart compile exe` does not support).

## Skills

Skills live in `.claude/skills/<name>/SKILL.md` (the active file, in English; a Polish reference copy sits next to it as `SKILL.pl.md`) and are picked up by Claude Code inside this repository (copy them to `~/.claude/skills/` to make them global).

| Skill | Triggers on | What it delivers |
|---|---|---|
| `dart-perf-review` | "optimize", "slow", "jank", performance review | A list of findings `file:line → fix → gain → how to verify` following checklist A–G |
| `dart-zero-alloc` | removing allocations from loops/parsers/serializers | 10 recipes 🐢→🚀 with numbers (SoA, preallocation, ByteWriter, BytesBuilder, byte-level parser…) |
| `dart-ffi-perf` | FFI bindings, native plugins, SQLite/Isar/ObjectBox | `@Native`/`isLeaf` (three-condition rule), `asTypedList`, `NativeFinalizer`, out-pointers, `stmt.raw`, `WriteBatcher` |
| `dart-isolates` | `compute`, `Isolate.spawn`, "move to background" | Cost table, flat payloads, `TransferableTypedData`, isolate groups |
| `flutter-render-perf` | jank, long frames, lists, animations | UI vs Raster diagnosis, rebuilds, `RepaintBoundary`, zero-alloc painter, `saveLayer`, DevTools |
| `dart-benchmark` | "is this faster?", a new benchmark | How to use the harness, JIT vs AOT, reading IL/disassembly, common mistakes |

## Headline numbers (AOT, medians)

| Technique | 🐢 → 🚀 | Gain |
|---|---|---:|
| `List<double>.add` ×65k → `Float64List(n)` | 6.05 ms → 0.72 ms | 8.4× |
| `List<Particle>.map().toList()` per frame → 4× `Float64List` (SoA) | 311 µs → 21 µs | 14× |
| `jsonEncode`+`utf8.encode` → `JsonUtf8Encoder` → ByteWriter into `Uint8List` | 60 µs → 38 µs → 6.5 µs | 1.6× / 9.3× |
| assembling 16 chunks: copy per chunk → `BytesBuilder(copy:false)` → preallocated buffer | 11.7 µs → 1.9 µs → 0.47 µs | 6× / 25× |
| FFI `add` non-leaf → `isLeaf: true` | 21.6 ns → 5.4 ns | 4× |
| `ptr[i]` ×4096 → `asTypedList` view | 10.6 µs → 12 ns | 900× |
| 10k INSERTs autocommit → one transaction | 230 ms → 17 ms | 13× |
| `select()` → `stmt.raw.step()/columnInt64()` | 4.16 ms → 0.89 ms | 4.7× |
| `SendPort.send(List<Map>)` → `Uint8List` | 9.2 ms → 72 µs | 128× |
| top-level `final Float64List` read in a loop → local variable | 194 µs → 84 µs | 2.3× |

Full tables and spread: `benchmarks/RESULTS.md`. Results depend on the machine; run `tool/run.sh` on yours.

## Sources analysed

- `arjaythedev/twelve-dollar-server-challenge`: PRs #19 (Rust io_uring, winner), #17 and #22 (Rust Axum), #32 (C++ io_uring), #25 (Zig), #46 (Dart raw socket)
- `simolus3/sqlite3.dart` v3.7.1: `lib/src/ffi/`, `RawPreparedStatement`
- `TechEmpower/FrameworkBenchmarks/frameworks/Dart`: `dart3`, `shelf`, `relic`, `dart_frog`, `angel3`
- `google/flatbuffers/dart`, `objectbox/flatbuffers-benchmark`, `objectbox/objectbox-dart`, `isar/isar` v4
- `dart-lang/sdk/runtime/docs`: "Introduction to Dart VM" (V. Egorov), `gc.md`, `glossary.md`, `pragmas.md`

License: MIT (code in `benchmarks/`); quoted fragments belong to their authors under the licenses of the source repositories.
