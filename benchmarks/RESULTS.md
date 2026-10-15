# Benchmark results / Wyniki benchmarków

> 🇬🇧 **English summary.** Reference run of `tool/run.sh` (JIT via `dart run`, AOT via `dart build cli`). Method: 100 ms warm-up, ~300 ms per sample, 7 samples, **median**; isolates: 5 × 20 round-trips, median. Raw data: `results/jit.json`, `results/aot.json`. Suite and variant names below are printed by the benchmark runner in Polish; the English guide (`docs/en/dart-flutter-extreme-performance-guide.md`) uses the same numbers with English labels, and `benchmarks/README.en.md` lists what each group measures. `vs baseline` > 1 means the variant is faster. Numbers quoted in the guides come from an earlier run on the same machine and configuration; the differences are within the min–max spread of individual samples.

- Data: 2026-10-14
- Dart SDK: 3.13.5 (linux_x64)
- CPU: Intel(R) Xeon(R) Processor @ 2.80GHz, 4 vCPU (kontener współdzielony, bez pinowania)
- Komenda: `tool/run.sh` (JIT: `dart run`, AOT: `dart build cli`)
- Metoda: rozgrzewka 100 ms, ~300 ms na próbę, 7 prób, **mediana**; izolaty: 5 × 20 round-tripów, mediana
- Surowe dane: `results/jit.json`, `results/aot.json`

Liczby cytowane w `docs/dart-flutter-extreme-performance-guide.md` i w `README.md` pochodzą z wcześniejszego przebiegu na tej samej maszynie i tej samej konfiguracji; różnice względem poniższych tabel mieszczą się w rozrzucie min–max pojedynczych prób (patrz pliki JSON). `vs baseline` > 1 oznacza szybszy wariant.

## AOT (dart build cli) — tryb, w którym działa Flutter release

### typed_lists/sum int (65k elementów)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> indexed loop | 45.41 µs | 22021 | 1.00x |
| List<int> for-in | 55.59 µs | 17990 | 0.82x |
| Int64List indexed loop | 36.15 µs | 27666 | 1.26x |
| Int32List indexed loop | 43.39 µs | 23045 | 1.05x |
| Uint8List indexed loop | 43.31 µs | 23088 | 1.05x |

### typed_lists/sum double (65k elementów)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<double> indexed loop (boxed) | 88.30 µs | 11324 | 1.00x |
| Float64List przez top-level final (leniwy getter w pętli) | 204.40 µs | 4892 | 0.43x |
| Float64List przekazana jako parametr/lokalna | 82.90 µs | 12062 | 1.07x |

### typed_lists/build (65k elementów)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> growable add() | 3.86 ms | 259 | 1.00x |
| List<int>.filled prealokowana | 1.06 ms | 942 | 3.64x |
| Int32List prealokowana | 403.61 µs | 2478 | 9.56x |
| List<double> growable add() (boxing) | 6.10 ms | 164 | 0.63x |
| Float64List prealokowana | 664.75 µs | 1504 | 5.81x |

### soa/particles (10k cząstek, 1 klatka)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<Particle> map().toList() (alokuje 10k obj/klatkę) | 281.93 µs | 3547 | 1.00x |
| List<Particle> mutacja w miejscu (AoS) | 30.02 µs | 33307 | 9.39x |
| 4x Float64List (SoA) | 23.47 µs | 42608 | 12.01x |
| 1x Float64List ze stride (flat struct) | 26.97 µs | 37079 | 10.45x |

### json/encode feed (20 postów, ~2.6 KB)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| jsonEncode(map) + utf8.encode | 68.39 µs | 14623 | 1.00x |
| JsonUtf8Encoder().convert(map) | 42.18 µs | 23707 | 1.62x |
| ByteWriter: bajty prosto do Uint8List (zero-alloc) | 8.96 µs | 111653 | 7.64x |

### json/decode feed (~2.6 KB)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| jsonDecode(utf8.decode(bytes)) | 34.98 µs | 28589 | 1.00x |
| utf8.decoder.fuse(json.decoder).convert(bytes) | 29.76 µs | 33604 | 1.18x |

### strings/build 200 linii

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| String += (kwadratowe kopiowanie) | 128.02 µs | 7811 | 1.00x |
| StringBuffer.write | 36.89 µs | 27104 | 3.47x |
| StringBuffer + utf8.encode (do socketu) | 53.20 µs | 18798 | 2.41x |
| bajty prosto do reużywanego Uint8List | 7.58 µs | 131926 | 16.89x |

### buffers/assemble 16x512B fragmentów

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> addAll (boxing) | 188.02 µs | 5319 | 1.00x |
| Uint8List: nowa kopia na fragment | 14.42 µs | 69355 | 13.04x |
| BytesBuilder(copy:false).takeBytes() | 2.43 µs | 411291 | 77.33x |
| prealokowany Uint8List + sublistView (zero-copy) | 445.3 ns | 2245529 | 422.20x |

### http/parse request (~430 B, 8 nagłówków)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| utf8.decode + split + Map<String,String> | 4.01 µs | 249175 | 1.00x |
| skan bajtowy, offsety, 3 nagłówki (zero-alloc) | 954.0 ns | 1048195 | 4.21x |

### collections/filter+map 10k

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| where().map().toList() | 228.71 µs | 4372 | 1.00x |
| pętla for + List.add | 90.74 µs | 11020 | 2.52x |
| 2 pętle + Int32List (zero realokacji) | 52.31 µs | 19118 | 4.37x |

### collections/sum 10k

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| fold() | 32.03 µs | 31222 | 1.00x |
| reduce() | 36.29 µs | 27554 | 0.88x |
| pętla for | 23.50 µs | 42560 | 1.36x |

### collections/histogram 10k wartości 0..999

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| Map<int,int> | 259.09 µs | 3860 | 1.00x |
| Int32List[1000] jako tablica zliczeń | 23.00 µs | 43473 | 11.26x |

### ffi/call add(a,b)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| czysty Dart a+b (referencja) | 2.5 ns | 406283275 | 1.00x |
| FFI non-leaf | 22.1 ns | 45240181 | 0.11x |
| FFI isLeaf: true | 6.2 ns | 161141105 | 0.40x |

### ffi/dot product 1024 double

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| czysty Dart na Float64List (widok asTypedList) | 1.58 µs | 631109 | 1.00x |
| C dot_f64 przez FFI isLeaf | 1.28 µs | 782942 | 1.24x |

### ffi/read 4 KB z Pointer<Uint8>

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| ptr[i] do List<int> (4096 wywołań) | 11.49 µs | 87018 | 1.00x |
| Uint8List.fromList(asTypedList) (1 memcpy) | 812.3 ns | 1231146 | 14.15x |
| asTypedList widok (zero-copy) | 11.1 ns | 89790044 | 1031.85x |

### ffi/fill 256 B: alokacja natywna

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| malloc + free per wywołanie | 282.4 ns | 3540697 | 1.00x |
| Arena (using) per wywołanie | 406.2 ns | 2461758 | 0.70x |
| reużywany bufor (zero-alloc) | 164.4 ns | 6082544 | 1.72x |
| reużywany bufor, non-leaf | 176.6 ns | 5663855 | 1.60x |

### sqlite/insert 10k wierszy (WAL, synchronous=NORMAL)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| execute(sql, args) per wiersz, autocommit | 240.59 ms | 4 | 1.00x |
| prepared statement, autocommit per wiersz | 200.16 ms | 5 | 1.20x |
| prepared + paczki po 100 (BEGIN/COMMIT) | 28.16 ms | 36 | 8.54x |
| prepared + paczki po 1000 | 15.75 ms | 63 | 15.27x |
| prepared + jedna transakcja (group commit) | 17.03 ms | 59 | 14.13x |

### sqlite/select 10k wierszy

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| select() -> ResultSet (lista Row) | 5.11 ms | 196 | 1.00x |
| selectCursor() wiersz po wierszu | 3.62 ms | 276 | 1.41x |
| stmt.raw: step() + columnInt64() (zero-alloc) | 920.58 µs | 1086 | 5.55x |

### sqlite/read 10k kolumn TEXT

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| raw.columnText() -> String per wiersz | 1.82 ms | 550 | 1.00x |
| CAST AS BLOB + raw.columnBlobInto(bufor) (zero-alloc) | 1.60 ms | 626 | 1.14x |

### isolates/round-trip 10k rekordów

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<Map> 10k obiektów (deep copy przez port) | 8.03 ms | 125 | 1.00x |
| Uint8List 120 KB (kopia przez port) | 43.95 µs | 22753 | 182.76x |
| TransferableTypedData 120 KB (fromList kopia + move) | 102.65 µs | 9742 | 78.25x |
| Uint8List 16 MB (kopia przez port) | 12.89 ms | 78 | 0.62x |
| TransferableTypedData 16 MB (fromList kopia + move) | 4.67 ms | 214 | 1.72x |
| Isolate.run(() => trivial) — koszt spawn | 105.70 µs | 9461 | 75.99x |

## JIT (dart run)

### typed_lists/sum int (65k elementów)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> indexed loop | 56.42 µs | 17723 | 1.00x |
| List<int> for-in | 49.18 µs | 20335 | 1.15x |
| Int64List indexed loop | 114.73 µs | 8716 | 0.49x |
| Int32List indexed loop | 63.96 µs | 15635 | 0.88x |
| Uint8List indexed loop | 66.27 µs | 15090 | 0.85x |

### typed_lists/sum double (65k elementów)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<double> indexed loop (boxed) | 90.97 µs | 10993 | 1.00x |
| Float64List przez top-level final (leniwy getter w pętli) | 216.60 µs | 4617 | 0.42x |
| Float64List przekazana jako parametr/lokalna | 82.16 µs | 12172 | 1.11x |

### typed_lists/build (65k elementów)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> growable add() | 4.01 ms | 249 | 1.00x |
| List<int>.filled prealokowana | 1.02 ms | 978 | 3.93x |
| Int32List prealokowana | 405.50 µs | 2466 | 9.90x |
| List<double> growable add() (boxing) | 6.54 ms | 153 | 0.61x |
| Float64List prealokowana | 719.55 µs | 1390 | 5.58x |

### soa/particles (10k cząstek, 1 klatka)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<Particle> map().toList() (alokuje 10k obj/klatkę) | 237.85 µs | 4204 | 1.00x |
| List<Particle> mutacja w miejscu (AoS) | 33.65 µs | 29715 | 7.07x |
| 4x Float64List (SoA) | 27.15 µs | 36838 | 8.76x |
| 1x Float64List ze stride (flat struct) | 18.41 µs | 54328 | 12.92x |

### json/encode feed (20 postów, ~2.6 KB)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| jsonEncode(map) + utf8.encode | 60.44 µs | 16546 | 1.00x |
| JsonUtf8Encoder().convert(map) | 39.03 µs | 25620 | 1.55x |
| ByteWriter: bajty prosto do Uint8List (zero-alloc) | 8.43 µs | 118674 | 7.17x |

### json/decode feed (~2.6 KB)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| jsonDecode(utf8.decode(bytes)) | 38.50 µs | 25975 | 1.00x |
| utf8.decoder.fuse(json.decoder).convert(bytes) | 34.48 µs | 29000 | 1.12x |

### strings/build 200 linii

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| String += (kwadratowe kopiowanie) | 108.04 µs | 9256 | 1.00x |
| StringBuffer.write | 28.63 µs | 34923 | 3.77x |
| StringBuffer + utf8.encode (do socketu) | 39.88 µs | 25075 | 2.71x |
| bajty prosto do reużywanego Uint8List | 8.83 µs | 113211 | 12.23x |

### buffers/assemble 16x512B fragmentów

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> addAll (boxing) | 104.53 µs | 9566 | 1.00x |
| Uint8List: nowa kopia na fragment | 14.00 µs | 71431 | 7.47x |
| BytesBuilder(copy:false).takeBytes() | 2.06 µs | 486101 | 50.81x |
| prealokowany Uint8List + sublistView (zero-copy) | 594.2 ns | 1682923 | 175.92x |

### http/parse request (~430 B, 8 nagłówków)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| utf8.decode + split + Map<String,String> | 4.74 µs | 211170 | 1.00x |
| skan bajtowy, offsety, 3 nagłówki (zero-alloc) | 914.7 ns | 1093242 | 5.18x |

### collections/filter+map 10k

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| where().map().toList() | 200.30 µs | 4992 | 1.00x |
| pętla for + List.add | 61.65 µs | 16220 | 3.25x |
| 2 pętle + Int32List (zero realokacji) | 40.24 µs | 24850 | 4.98x |

### collections/sum 10k

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| fold() | 42.79 µs | 23371 | 1.00x |
| reduce() | 37.39 µs | 26745 | 1.14x |
| pętla for | 23.70 µs | 42195 | 1.81x |

### collections/histogram 10k wartości 0..999

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| Map<int,int> | 329.98 µs | 3030 | 1.00x |
| Int32List[1000] jako tablica zliczeń | 22.64 µs | 44176 | 14.58x |

### ffi/call add(a,b)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| czysty Dart a+b (referencja) | 5.4 ns | 184222257 | 1.00x |
| FFI non-leaf | 25.5 ns | 39214894 | 0.21x |
| FFI isLeaf: true | 14.3 ns | 70164422 | 0.38x |

### ffi/dot product 1024 double

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| czysty Dart na Float64List (widok asTypedList) | 1.96 µs | 509303 | 1.00x |
| C dot_f64 przez FFI isLeaf | 1.25 µs | 801175 | 1.57x |

### ffi/read 4 KB z Pointer<Uint8>

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| ptr[i] do List<int> (4096 wywołań) | 19.69 µs | 50783 | 1.00x |
| Uint8List.fromList(asTypedList) (1 memcpy) | 902.1 ns | 1108505 | 21.83x |
| asTypedList widok (zero-copy) | 23.7 ns | 42179761 | 830.59x |

### ffi/fill 256 B: alokacja natywna

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| malloc + free per wywołanie | 240.2 ns | 4163122 | 1.00x |
| Arena (using) per wywołanie | 323.5 ns | 3091309 | 0.74x |
| reużywany bufor (zero-alloc) | 161.3 ns | 6201445 | 1.49x |
| reużywany bufor, non-leaf | 166.7 ns | 5998533 | 1.44x |

### sqlite/insert 10k wierszy (WAL, synchronous=NORMAL)

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| execute(sql, args) per wiersz, autocommit | 315.38 ms | 3 | 1.00x |
| prepared statement, autocommit per wiersz | 264.11 ms | 4 | 1.19x |
| prepared + paczki po 100 (BEGIN/COMMIT) | 29.86 ms | 33 | 10.56x |
| prepared + paczki po 1000 | 19.68 ms | 51 | 16.03x |
| prepared + jedna transakcja (group commit) | 24.77 ms | 40 | 12.73x |

### sqlite/select 10k wierszy

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| select() -> ResultSet (lista Row) | 4.90 ms | 204 | 1.00x |
| selectCursor() wiersz po wierszu | 8.11 ms | 123 | 0.60x |
| stmt.raw: step() + columnInt64() (zero-alloc) | 1.08 ms | 922 | 4.52x |

### sqlite/read 10k kolumn TEXT

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| raw.columnText() -> String per wiersz | 3.18 ms | 314 | 1.00x |
| CAST AS BLOB + raw.columnBlobInto(bufor) (zero-alloc) | 1.58 ms | 632 | 2.01x |

### isolates/round-trip 10k rekordów

| Wariant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<Map> 10k obiektów (deep copy przez port) | 9.91 ms | 101 | 1.00x |
| Uint8List 120 KB (kopia przez port) | 91.90 µs | 10881 | 107.80x |
| TransferableTypedData 120 KB (fromList kopia + move) | 156.05 µs | 6408 | 63.48x |
| Uint8List 16 MB (kopia przez port) | 17.22 ms | 58 | 0.58x |
| TransferableTypedData 16 MB (fromList kopia + move) | 8.68 ms | 115 | 1.14x |
| Isolate.run(() => trivial) — koszt spawn | 367.65 µs | 2720 | 26.95x |
