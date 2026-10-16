# users pipeline (JIT, Dart 3.13.5)

| Etap | Wariant | mediana ms | min | max |
|---|---|---:|---:|---:|
| decode | 1 slow: String+jsonDecode+fromJson | 93.09 | 86.81 | 108.55 |
| decode | 2 fused+fromJson (obiekty) | 87.84 | 67.05 | 101.45 |
| decode | 3 tree -> kolumny | 120.71 | 90.02 | 155.73 |
| decode | 4 byte scanner -> kolumny | 11.61 | 11.38 | 20.82 |
| query+encode | 1 slow: where/sort/map/jsonEncode | 1.02 | 0.87 | 1.74 |
| query+encode | 2 pętle + JsonUtf8Encoder | 1.16 | 0.74 | 1.84 |
| query+encode | 3 kolumny (z drzewa) | 0.19 | 0.18 | 0.37 |
| query+encode | 4 kolumny (ze skanera) | 0.18 | 0.17 | 0.22 |
| end-to-end | 1 slow | 77.55 | 67.25 | 88.51 |
| end-to-end | 2 fused objects | 67.36 | 63.43 | 88.71 |
| end-to-end | 4 byte scanner | 12.22 | 11.14 | 20.61 |
