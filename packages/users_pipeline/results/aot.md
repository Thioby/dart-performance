# users pipeline (AOT, Dart 3.13.5)

| Stage | Variant | median ms | min | max |
|---|---|---:|---:|---:|
| decode | 1 slow: String+jsonDecode+fromJson | 73.97 | 60.40 | 85.54 |
| decode | 2 fused+fromJson (objects) | 53.71 | 49.64 | 72.77 |
| decode | 3 tree -> columns | 91.12 | 86.66 | 116.45 |
| decode | 4 byte scanner -> columns | 12.35 | 11.96 | 16.08 |
| query+encode | 1 slow: where/sort/map/jsonEncode | 0.58 | 0.54 | 0.85 |
| query+encode | 2 loops + JsonUtf8Encoder | 0.69 | 0.61 | 0.82 |
| query+encode | 3 columns (from tree) | 0.08 | 0.07 | 0.12 |
| query+encode | 4 columns (from scanner) | 0.07 | 0.07 | 0.10 |
| end-to-end | 1 slow | 84.87 | 77.63 | 109.71 |
| end-to-end | 2 fused objects | 62.00 | 56.99 | 74.90 |
| end-to-end | 4 byte scanner | 12.20 | 11.96 | 13.95 |
| isolate rt | 1 Isolate.run -> List<User> | 97.76 | 81.59 | 214.04 |
| isolate rt | 2 Isolate.run -> List<User> (fused) | 70.75 | 66.47 | 89.13 |
| isolate rt | 4 Isolate.run -> Transferable(columns) | 22.07 | 19.87 | 30.21 |
