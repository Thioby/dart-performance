# Results (AOT, Dart 3.13.5)

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
