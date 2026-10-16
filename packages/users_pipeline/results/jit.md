# users pipeline (JIT, Dart 3.13.5)

| Stage | Variant | median ms | min | max |
|---|---|---:|---:|---:|
| decode | 1 slow: String+jsonDecode+fromJson | 106.04 | 77.35 | 176.80 |
| decode | 2 fused+fromJson (objects) | 82.00 | 64.57 | 99.07 |
| decode | 3 tree -> columns | 113.16 | 80.49 | 249.38 |
| decode | 4 byte scanner -> columns | 11.86 | 11.60 | 16.43 |
| query+encode | 1 slow: where/sort/map/jsonEncode | 1.05 | 0.80 | 1.36 |
| query+encode | 2 loops + JsonUtf8Encoder | 1.17 | 0.79 | 1.61 |
| query+encode | 3 columns (from tree) | 0.18 | 0.16 | 0.30 |
| query+encode | 4 columns (from scanner) | 0.18 | 0.15 | 0.28 |
| end-to-end | 1 slow | 89.98 | 84.55 | 102.10 |
| end-to-end | 2 fused objects | 70.68 | 64.29 | 78.29 |
| end-to-end | 4 byte scanner | 18.63 | 12.56 | 28.01 |
