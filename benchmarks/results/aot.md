# Wyniki (AOT, Dart 3.13.5)

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
