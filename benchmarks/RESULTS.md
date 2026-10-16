# Benchmark results / Wyniki benchmarków

> 🇬🇧 Reference run of `tool/run.sh` (JIT via `dart run`, AOT via `dart build cli`). Method: 100 ms warm-up, ~300 ms per sample, 7 samples, **median**; isolates: 5 × 20 round-trips, median. Raw data: `results/jit.json`, `results/aot.json`. Suite and variant names are the labels printed by the runner. `vs baseline` > 1 means the variant is faster. Numbers quoted in the guides come from earlier runs on the same machine and configuration; differences are within the min–max spread of individual samples.
>
> 🇵🇱 Przebieg referencyjny `tool/run.sh` (JIT: `dart run`, AOT: `dart build cli`). Metoda: rozgrzewka 100 ms, ~300 ms na próbę, 7 prób, **mediana**; izolaty: 5 × 20 round-tripów, mediana. Surowe dane: `results/*.json`. Nazwy suite'ów i wariantów to etykiety drukowane przez runner (po angielsku). `vs baseline` > 1 oznacza szybszy wariant. Liczby cytowane w przewodnikach pochodzą z wcześniejszych przebiegów na tej samej maszynie; różnice mieszczą się w rozrzucie min–max.

- Date / data: 2026-10-16
- Dart SDK: 3.13.5 (linux_x64)
- CPU: Intel(R) Xeon(R) Processor @ 2.10GHz, 4 vCPU (shared container, no pinning)

## AOT (dart build cli) — the mode Flutter release runs in

### typed_lists/sum int (65k elements)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> indexed loop | 77.37 µs | 12925 | 1.00x |
| List<int> for-in | 73.97 µs | 13519 | 1.05x |
| Int64List indexed loop | 48.71 µs | 20531 | 1.59x |
| Int32List indexed loop | 46.27 µs | 21612 | 1.67x |
| Uint8List indexed loop | 51.48 µs | 19426 | 1.50x |

### typed_lists/sum double (65k elements)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<double> indexed loop (boxed) | 51.02 µs | 19601 | 1.00x |
| Float64List via top-level final (lazy getter in loop) | 196.66 µs | 5085 | 0.26x |
| Float64List passed as parameter/local | 54.76 µs | 18263 | 0.93x |

### typed_lists/build (65k elements)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> growable add() | 2.50 ms | 400 | 1.00x |
| List<int>.filled preallocated | 720.10 µs | 1389 | 3.47x |
| Int32List preallocated | 318.09 µs | 3144 | 7.85x |
| List<double> growable add() (boxing) | 4.60 ms | 217 | 0.54x |
| Float64List preallocated | 627.90 µs | 1593 | 3.98x |

### soa/particles (10k particles, 1 frame)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<Particle> map().toList() (allocates 10k obj/frame) | 297.81 µs | 3358 | 1.00x |
| List<Particle> in-place mutation (AoS) | 27.17 µs | 36804 | 10.96x |
| 4x Float64List (SoA) | 19.39 µs | 51582 | 15.36x |
| 1x Float64List with stride (flat struct) | 23.09 µs | 43316 | 12.90x |

### json/encode feed (20 posts, ~2.6 KB)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| jsonEncode(map) + utf8.encode | 57.72 µs | 17326 | 1.00x |
| JsonUtf8Encoder().convert(map) | 42.09 µs | 23758 | 1.37x |
| ByteWriter: bytes straight into Uint8List (zero-alloc) | 7.11 µs | 140644 | 8.12x |

### json/decode feed (~2.6 KB)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| jsonDecode(utf8.decode(bytes)) | 30.13 µs | 33190 | 1.00x |
| utf8.decoder.fuse(json.decoder).convert(bytes) | 23.64 µs | 42299 | 1.27x |

### strings/build 200 lines

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| String += (quadratic copying) | 62.77 µs | 15930 | 1.00x |
| StringBuffer.write | 28.02 µs | 35689 | 2.24x |
| StringBuffer + utf8.encode (to socket) | 42.79 µs | 23369 | 1.47x |
| bytes straight into a reused Uint8List | 6.93 µs | 144321 | 9.06x |

### buffers/assemble 16x512B chunks

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> addAll (boxing) | 150.38 µs | 6650 | 1.00x |
| Uint8List: new copy per chunk | 5.18 µs | 192986 | 29.02x |
| BytesBuilder(copy:false).takeBytes() | 1.15 µs | 870457 | 130.90x |
| preallocated Uint8List + sublistView (zero-copy) | 447.3 ns | 2235764 | 336.22x |

### http/parse request (~430 B, 8 headers)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| utf8.decode + split + Map<String,String> | 3.75 µs | 266602 | 1.00x |
| byte scan, offsets, 3 headers (zero-alloc) | 873.7 ns | 1144555 | 4.29x |

### collections/filter+map 10k

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| where().map().toList() | 181.85 µs | 5499 | 1.00x |
| for loop + List.add | 68.22 µs | 14659 | 2.67x |
| 2 loops + Int32List (zero reallocation) | 43.69 µs | 22886 | 4.16x |

### collections/sum 10k

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| fold() | 35.53 µs | 28142 | 1.00x |
| reduce() | 35.94 µs | 27825 | 0.99x |
| for loop | 17.22 µs | 58073 | 2.06x |

### collections/histogram 10k values 0..999

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| Map<int,int> | 246.06 µs | 4064 | 1.00x |
| Int32List[1000] as a count table | 19.77 µs | 50577 | 12.45x |

### ffi/call add(a,b)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| pure Dart a+b (reference) | 2.8 ns | 360509684 | 1.00x |
| FFI non-leaf | 23.9 ns | 41887720 | 0.12x |
| FFI isLeaf: true | 7.8 ns | 127396790 | 0.35x |

### ffi/dot product 1024 double

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| pure Dart on Float64List (asTypedList view) | 1.67 µs | 599064 | 1.00x |
| C dot_f64 via FFI isLeaf | 733.2 ns | 1363832 | 2.28x |

### ffi/read 4 KB from Pointer<Uint8>

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| ptr[i] into List<int> (4096 calls) | 7.97 µs | 125540 | 1.00x |
| Uint8List.fromList(asTypedList) (1 memcpy) | 260.6 ns | 3837843 | 30.57x |
| asTypedList view (zero-copy) | 9.6 ns | 103994490 | 828.38x |

### ffi/fill 256 B: native allocation

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| malloc + free per call | 211.5 ns | 4728495 | 1.00x |
| Arena (using) per call | 300.1 ns | 3332152 | 0.70x |
| reused buffer (zero-alloc) | 130.2 ns | 7677848 | 1.62x |
| reused buffer, non-leaf | 121.8 ns | 8210394 | 1.74x |

### sqlite/insert 10k rows (WAL, synchronous=NORMAL)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| execute(sql, args) per row, autocommit | 213.69 ms | 5 | 1.00x |
| prepared statement, autocommit per row | 148.41 ms | 7 | 1.44x |
| prepared + batches of 100 (BEGIN/COMMIT) | 15.72 ms | 64 | 13.60x |
| prepared + batches of 1000 | 14.21 ms | 70 | 15.04x |
| prepared + one transaction (group commit) | 13.15 ms | 76 | 16.25x |

### sqlite/select 10k rows

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| select() -> ResultSet (list of Row) | 3.43 ms | 292 | 1.00x |
| selectCursor() row by row | 3.32 ms | 301 | 1.03x |
| stmt.raw: step() + columnInt64() (zero-alloc) | 788.59 µs | 1268 | 4.35x |

### sqlite/read 10k TEXT columns

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| raw.columnText() -> String per row | 1.55 ms | 646 | 1.00x |
| CAST AS BLOB + raw.columnBlobInto(buffer) (zero-alloc) | 1.27 ms | 785 | 1.21x |

### isolates/round-trip 10k records

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<Map> 10k objects (deep copy via port) | 6.15 ms | 163 | 1.00x |
| Uint8List 120 KB (copy via port) | 40.85 µs | 24480 | 150.55x |
| TransferableTypedData 120 KB (fromList copy + move) | 88.70 µs | 11274 | 69.33x |
| Uint8List 16 MB (copy via port) | 12.14 ms | 82 | 0.51x |
| TransferableTypedData 16 MB (fromList copy + move) | 5.57 ms | 180 | 1.10x |
| Isolate.run(() => trivial) — spawn cost | 121.40 µs | 8237 | 50.66x |

## JIT (dart run)

### typed_lists/sum int (65k elements)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> indexed loop | 69.24 µs | 14443 | 1.00x |
| List<int> for-in | 50.76 µs | 19701 | 1.36x |
| Int64List indexed loop | 75.71 µs | 13208 | 0.91x |
| Int32List indexed loop | 51.99 µs | 19234 | 1.33x |
| Uint8List indexed loop | 63.42 µs | 15767 | 1.09x |

### typed_lists/sum double (65k elements)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<double> indexed loop (boxed) | 116.21 µs | 8605 | 1.00x |
| Float64List via top-level final (lazy getter in loop) | 190.76 µs | 5242 | 0.61x |
| Float64List passed as parameter/local | 47.04 µs | 21258 | 2.47x |

### typed_lists/build (65k elements)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> growable add() | 2.63 ms | 380 | 1.00x |
| List<int>.filled preallocated | 1.08 ms | 929 | 2.45x |
| Int32List preallocated | 357.72 µs | 2796 | 7.36x |
| List<double> growable add() (boxing) | 4.90 ms | 204 | 0.54x |
| Float64List preallocated | 565.63 µs | 1768 | 4.65x |

### soa/particles (10k particles, 1 frame)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<Particle> map().toList() (allocates 10k obj/frame) | 165.92 µs | 6027 | 1.00x |
| List<Particle> in-place mutation (AoS) | 29.39 µs | 34021 | 5.64x |
| 4x Float64List (SoA) | 17.23 µs | 58048 | 9.63x |
| 1x Float64List with stride (flat struct) | 21.99 µs | 45466 | 7.54x |

### json/encode feed (20 posts, ~2.6 KB)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| jsonEncode(map) + utf8.encode | 46.79 µs | 21371 | 1.00x |
| JsonUtf8Encoder().convert(map) | 34.36 µs | 29101 | 1.36x |
| ByteWriter: bytes straight into Uint8List (zero-alloc) | 8.80 µs | 113575 | 5.31x |

### json/decode feed (~2.6 KB)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| jsonDecode(utf8.decode(bytes)) | 30.69 µs | 32586 | 1.00x |
| utf8.decoder.fuse(json.decoder).convert(bytes) | 27.98 µs | 35743 | 1.10x |

### strings/build 200 lines

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| String += (quadratic copying) | 54.41 µs | 18380 | 1.00x |
| StringBuffer.write | 31.44 µs | 31803 | 1.73x |
| StringBuffer + utf8.encode (to socket) | 37.52 µs | 26652 | 1.45x |
| bytes straight into a reused Uint8List | 9.28 µs | 107746 | 5.86x |

### buffers/assemble 16x512B chunks

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<int> addAll (boxing) | 76.90 µs | 13004 | 1.00x |
| Uint8List: new copy per chunk | 3.94 µs | 253743 | 19.51x |
| BytesBuilder(copy:false).takeBytes() | 879.8 ns | 1136633 | 87.41x |
| preallocated Uint8List + sublistView (zero-copy) | 485.5 ns | 2059587 | 158.39x |

### http/parse request (~430 B, 8 headers)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| utf8.decode + split + Map<String,String> | 4.04 µs | 247503 | 1.00x |
| byte scan, offsets, 3 headers (zero-alloc) | 963.8 ns | 1037559 | 4.19x |

### collections/filter+map 10k

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| where().map().toList() | 118.98 µs | 8405 | 1.00x |
| for loop + List.add | 39.28 µs | 25460 | 3.03x |
| 2 loops + Int32List (zero reallocation) | 40.62 µs | 24620 | 2.93x |

### collections/sum 10k

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| fold() | 34.48 µs | 29002 | 1.00x |
| reduce() | 31.33 µs | 31919 | 1.10x |
| for loop | 25.50 µs | 39222 | 1.35x |

### collections/histogram 10k values 0..999

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| Map<int,int> | 299.33 µs | 3341 | 1.00x |
| Int32List[1000] as a count table | 25.20 µs | 39688 | 11.88x |

### ffi/call add(a,b)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| pure Dart a+b (reference) | 3.4 ns | 293872206 | 1.00x |
| FFI non-leaf | 30.0 ns | 33317240 | 0.11x |
| FFI isLeaf: true | 8.1 ns | 123334100 | 0.42x |

### ffi/dot product 1024 double

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| pure Dart on Float64List (asTypedList view) | 2.22 µs | 449548 | 1.00x |
| C dot_f64 via FFI isLeaf | 710.8 ns | 1406856 | 3.13x |

### ffi/read 4 KB from Pointer<Uint8>

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| ptr[i] into List<int> (4096 calls) | 17.45 µs | 57322 | 1.00x |
| Uint8List.fromList(asTypedList) (1 memcpy) | 261.8 ns | 3819350 | 66.63x |
| asTypedList view (zero-copy) | 8.0 ns | 124348111 | 2169.30x |

### ffi/fill 256 B: native allocation

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| malloc + free per call | 215.9 ns | 4632729 | 1.00x |
| Arena (using) per call | 277.4 ns | 3605295 | 0.78x |
| reused buffer (zero-alloc) | 123.7 ns | 8086870 | 1.75x |
| reused buffer, non-leaf | 122.6 ns | 8155117 | 1.76x |

### sqlite/insert 10k rows (WAL, synchronous=NORMAL)

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| execute(sql, args) per row, autocommit | 184.43 ms | 5 | 1.00x |
| prepared statement, autocommit per row | 156.76 ms | 6 | 1.18x |
| prepared + batches of 100 (BEGIN/COMMIT) | 14.56 ms | 69 | 12.66x |
| prepared + batches of 1000 | 13.33 ms | 75 | 13.83x |
| prepared + one transaction (group commit) | 12.50 ms | 80 | 14.75x |

### sqlite/select 10k rows

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| select() -> ResultSet (list of Row) | 3.70 ms | 270 | 1.00x |
| selectCursor() row by row | 3.57 ms | 280 | 1.04x |
| stmt.raw: step() + columnInt64() (zero-alloc) | 780.68 µs | 1281 | 4.74x |

### sqlite/read 10k TEXT columns

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| raw.columnText() -> String per row | 1.60 ms | 625 | 1.00x |
| CAST AS BLOB + raw.columnBlobInto(buffer) (zero-alloc) | 1.40 ms | 712 | 1.14x |

### isolates/round-trip 10k records

| Variant | ns/op | ops/s | vs baseline |
|---|---:|---:|---:|
| List<Map> 10k objects (deep copy via port) | 6.57 ms | 152 | 1.00x |
| Uint8List 120 KB (copy via port) | 59.40 µs | 16835 | 110.67x |
| TransferableTypedData 120 KB (fromList copy + move) | 118.10 µs | 8467 | 55.66x |
| Uint8List 16 MB (copy via port) | 12.95 ms | 77 | 0.51x |
| TransferableTypedData 16 MB (fromList copy + move) | 6.07 ms | 165 | 1.08x |
| Isolate.run(() => trivial) — spawn cost | 302.60 µs | 3305 | 21.72x |
