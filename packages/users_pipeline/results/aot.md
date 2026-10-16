# users pipeline (AOT, Dart 3.13.5)

| Etap | Wariant | mediana ms | min | max |
|---|---|---:|---:|---:|
| decode | 1 slow: String+jsonDecode+fromJson | 76.30 | 73.63 | 85.84 |
| decode | 2 fused+fromJson (obiekty) | 53.92 | 51.12 | 82.60 |
| decode | 3 tree -> kolumny | 139.09 | 79.97 | 150.55 |
| decode | 4 byte scanner -> kolumny | 12.16 | 11.68 | 15.07 |
| query+encode | 1 slow: where/sort/map/jsonEncode | 0.54 | 0.51 | 0.56 |
| query+encode | 2 pętle + JsonUtf8Encoder | 0.60 | 0.58 | 0.70 |
| query+encode | 3 kolumny (z drzewa) | 0.10 | 0.09 | 0.13 |
| query+encode | 4 kolumny (ze skanera) | 0.09 | 0.09 | 0.11 |
| end-to-end | 1 slow | 93.59 | 76.28 | 108.65 |
| end-to-end | 2 fused objects | 59.96 | 57.94 | 77.72 |
| end-to-end | 4 byte scanner | 12.03 | 11.81 | 14.01 |
| isolate rt | 1 Isolate.run -> List<User> | 103.63 | 86.14 | 130.31 |
| isolate rt | 2 Isolate.run -> List<User> (fused) | 93.77 | 83.82 | 103.73 |
| isolate rt | 4 Isolate.run -> Transferable(kolumny) | 30.72 | 20.88 | 31.74 |
