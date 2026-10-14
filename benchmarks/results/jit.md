# Wyniki (JIT, Dart 3.13.5)

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
