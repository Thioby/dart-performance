> 🇵🇱 Wersja polska · [🇬🇧 English version](README.en.md)

# dart-performance

Warsztat „Jak pisać ekstremalnie szybki kod” — dwa przewodniki (Rust i Dart/Flutter), zestaw skilli Claude Code do optymalizacji wydajności w Dart/Flutter oraz pakiet benchmarków „wolny vs szybki”, na którym każdą technikę można zmierzyć (JIT i AOT).

## Zawartość

| Ścieżka | Co to jest |
|---|---|
| [`docs/rust-extreme-performance-guide.md`](docs/rust-extreme-performance-guide.md) | Przewodnik po zwycięskim kodzie [Twelve Dollar Server Challenge](https://github.com/arjaythedev/twelve-dollar-server-challenge): `io_uring` vs Axum, group commit, zero-allocation, analiza `unsafe` i `Cargo.toml`, ściąga produkcyjna, 3 katy |
| [`docs/dart-flutter-extreme-performance-guide.md`](docs/dart-flutter-extreme-performance-guide.md) | Przewodnik Dart/Flutter: Dart VM (Smi/boxing/GC/typed data), `dart:ffi` na bazie `sqlite3.dart`/Isar/ObjectBox, izolaty bez kopiowania, Flutter (Impeller/RenderObject), ściąga + 3 katy. Liczby z `benchmarks/` |
| [`benchmarks/`](benchmarks/) | Pakiet Dart: harness + 12 grup benchmarków (typed data, SoA, JSON, stringi, bufory/HTTP, kolekcje, FFI `isLeaf`/`asTypedList`, SQLite group commit i `stmt.raw`, izolaty/`TransferableTypedData`). `tool/run.sh` uruchamia JIT i AOT |
| [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md) | Wyniki referencyjne (Dart 3.13.5, Linux x64, 4 vCPU) |
| [`packages/users_pipeline/`](packages/users_pipeline/) | **Studium przypadku**: 10k użytkowników z JSON (realny fetch z raw GitHub/gista, fallback lokalny) → decode → filtr/sort/group → encode, 4 warianty od `jsonDecode`+`fromJson`+`where` do skanera bajtowego → kolumny; `Isolate.run` z `List<User>` vs `TransferableTypedData`. AOT: 93.6 ms → 12.0 ms (7.8×) |
| [`flutter_bench/`](flutter_bench/) | Aplikacja Flutter z tymi samymi wariantami + licznik janku klatek (`addTimingsCallback`); `flutter test` przepuszcza wszystkie warianty |
| [`.claude/skills/`](.claude/skills/) | Skille Claude Code: `dart-perf-review`, `dart-zero-alloc`, `dart-ffi-perf`, `dart-isolates`, `flutter-render-perf`, `dart-benchmark` |

## Szybki start

```bash
# Dart SDK >= 3.6 (testowane na 3.13.5); gcc/clang dla benchmarku FFI
cd benchmarks
dart pub get
tool/build_native.sh                 # native/libfastmath.so
dart run bin/run_all.dart --only json,typed,soa   # JIT, wybrane grupy
tool/run.sh                          # pełny przebieg JIT + AOT -> results/{jit,aot}.md
```

AOT budowany jest przez `dart build cli` (pakiet `sqlite3` ≥ 3 używa native-asset hooks, których `dart compile exe` nie wspiera).

## Skille

Skille leżą w `.claude/skills/<nazwa>/SKILL.md` (aktywny plik, po angielsku — angielskie opisy trafniej wyzwalają skill; polska wersja referencyjna obok jako `SKILL.pl.md`) i są wykrywane przez Claude Code w tym repozytorium (można je skopiować do `~/.claude/skills/`, by działały globalnie).

| Skill | Kiedy się włącza | Co daje |
|---|---|---|
| `dart-perf-review` | „zoptymalizuj”, „wolno”, „jank”, review wydajnościowe | Lista znalezisk `plik:linia → poprawka → zysk → weryfikacja` wg checklisty A–G |
| `dart-zero-alloc` | usuwanie alokacji z pętli/parsera/serializatora | 10 przepisów 🐢→🚀 z liczbami (SoA, prealokacja, ByteWriter, BytesBuilder, parser bajtowy…) |
| `dart-ffi-perf` | bindingi FFI, pluginy natywne, SQLite/Isar/ObjectBox | `@Native`/`isLeaf` (reguła 3 warunków), `asTypedList`, `NativeFinalizer`, out-pointery, `stmt.raw`, `WriteBatcher` |
| `dart-isolates` | `compute`, `Isolate.spawn`, „przenieś do tła” | Tabela kosztów, płaskie payloady, `TransferableTypedData`, grupy izolatów |
| `flutter-render-perf` | jank, długie klatki, listy, animacje | Diagnoza UI vs Raster, rebuildy, `RepaintBoundary`, painter zero-alloc, `saveLayer`, DevTools |
| `dart-benchmark` | „czy to jest szybsze?”, nowy benchmark | Jak użyć harnessu, JIT vs AOT, czytanie IL/disassembly, typowe błędy |

## Najważniejsze liczby (AOT, mediany)

| Technika | 🐢 → 🚀 | Zysk |
|---|---|---:|
| `List<double>.add` ×65k → `Float64List(n)` | 6.05 ms → 0.72 ms | 8.4× |
| `List<Particle>.map().toList()` per klatka → 4× `Float64List` (SoA) | 311 µs → 21 µs | 14× |
| `jsonEncode`+`utf8.encode` → `JsonUtf8Encoder` → ByteWriter do `Uint8List` | 60 µs → 38 µs → 6.5 µs | 1.6× / 9.3× |
| składanie 16 fragmentów: kopia per fragment → `BytesBuilder(copy:false)` → prealokowany bufor | 11.7 µs → 1.9 µs → 0.47 µs | 6× / 25× |
| FFI `add` non-leaf → `isLeaf: true` | 21.6 ns → 5.4 ns | 4× |
| `ptr[i]` ×4096 → `asTypedList` widok | 10.6 µs → 12 ns | 900× |
| 10k INSERT autocommit → jedna transakcja | 230 ms → 17 ms | 13× |
| `select()` → `stmt.raw.step()/columnInt64()` | 4.16 ms → 0.89 ms | 4.7× |
| `SendPort.send(List<Map>)` → `Uint8List` | 9.2 ms → 72 µs | 128× |
| top-level `final Float64List` w pętli → lokalna | 194 µs → 84 µs | 2.3× |

Pełne tabele i rozrzut: `benchmarks/RESULTS.md`. Wyniki zależą od maszyny — uruchom `tool/run.sh` u siebie.

## Źródła analizowane przy pisaniu

- `arjaythedev/twelve-dollar-server-challenge` — PR-y #19 (Rust io_uring, zwycięzca), #17 i #22 (Rust Axum), #32 (C++ io_uring), #25 (Zig), #46 (Dart raw socket)
- `simolus3/sqlite3.dart` v3.7.1 — `lib/src/ffi/`, `RawPreparedStatement`
- `TechEmpower/FrameworkBenchmarks/frameworks/Dart` — `dart3`, `shelf`, `relic`, `dart_frog`, `angel3`
- `google/flatbuffers/dart`, `objectbox/flatbuffers-benchmark`, `objectbox/objectbox-dart`, `isar/isar` v4
- `dart-lang/sdk/runtime/docs` — „Introduction to Dart VM” (V. Egorov), `gc.md`, `glossary.md`, `pragmas.md`

Licencja: MIT (kod w `benchmarks/`); cytowane fragmenty należą do ich autorów na licencjach źródłowych repozytoriów.
