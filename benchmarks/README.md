> 🇵🇱 Wersja polska · [🇬🇧 English version](README.en.md)

# benchmarks — „wolny vs szybki” w Dart

Każda grupa zestawia idiomatyczny kod (baseline) z wariantami zero-allocation / typed data / FFI. Liczby trafiają do przewodnika `docs/dart-flutter-extreme-performance-guide.md`.

## Uruchamianie

```bash
dart pub get
tool/build_native.sh                      # libfastmath.so (gcc/clang) dla grupy ffi
dart run bin/run_all.dart                 # JIT, wszystko
dart run bin/run_all.dart --only json,ffi # wybrane grupy
dart run bin/run_all.dart --json out.json --md out.md
tool/run.sh [grupy]                       # JIT + AOT -> results/{jit,aot}.{md,json}
```

AOT: `dart build cli -o build/aot` (pakiet `sqlite3` ≥ 3 ma build hooks; `dart compile exe` ich nie wspiera). Binarka: `build/aot/bundle/bin/run_all`.

## Grupy (`--only`)

| Grupa | Plik | Pytanie |
|---|---|---|
| `typed` | `lib/src/bench_typed_lists.dart` | `List<int>`/`List<double>` vs `Int32List`/`Uint8List`/`Float64List`: sum i build; pułapka leniwego top-level `final` |
| `soa` | `lib/src/bench_soa.dart` | `List<Particle>` (AoS, immutable map) vs Struct-of-Arrays vs flat stride — jedna klatka fizyki 10k cząstek |
| `json` | `lib/src/bench_json.dart` | `jsonEncode`+`utf8.encode` vs `JsonUtf8Encoder` vs ręczny `ByteWriter`; `jsonDecode(utf8.decode)` vs fused decoder |
| `strings` | `lib/src/bench_strings.dart` | `+=` vs `StringBuffer` vs bajty do `Uint8List` |
| `buffers` | `lib/src/bench_buffers.dart` | składanie fragmentów socketu (4 sposoby); parsowanie HTTP: split/Map vs skan bajtowy |
| `collections` | `lib/src/bench_collections.dart` | `where/map/toList` vs pętle; `fold/reduce` vs pętla; `Map<int,int>` vs `Int32List` |
| `ffi` | `lib/src/bench_ffi.dart` + `native/fastmath.c` | `isLeaf` vs non-leaf; dot product Dart vs C; `ptr[i]` vs `asTypedList`; malloc vs Arena vs reużywany bufor |
| `sqlite` | `lib/src/bench_sqlite.dart` | 10k INSERT: autocommit vs prepared vs paczki vs jedna transakcja; `select()` vs `selectCursor()` vs `stmt.raw`; TEXT→String vs `CAST AS BLOB`+`columnBlobInto` |
| `isolates` | `lib/src/bench_isolates.dart` | `SendPort` z `List<Map>` vs `Uint8List` vs `TransferableTypedData` (120 KB i 16 MB); koszt `Isolate.run` |

Nazwy suite'ów i wariantów drukowane przez runner (i używane w `RESULTS.md`) są po angielsku; kod benchmarków ma angielskie komentarze.

## Harness (`lib/harness.dart`)

- rozgrzewka 100 ms, iteracje dobrane na ~`sampleMillis` (300 ms), `samples` (7) prób, raportowana **mediana** + min/max,
- `blackHole(value)` z `@pragma('vm:never-inline')` chroni wyniki przed DCE,
- `toMarkdown(results)` generuje tabele do `RESULTS.md`, `BenchResult.toJson()` surowe dane.

## Dodawanie benchmarku

Zobacz skill `.claude/skills/dart-benchmark/SKILL.md` (szablon, zasady, czytanie IL).
