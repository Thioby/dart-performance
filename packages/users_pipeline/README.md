# users_pipeline — realistyczny benchmark: 10k użytkowników z JSON

Scenariusz jak w prawdziwej aplikacji: pobierz listę 10 000 użytkowników jako JSON (3.3 MB), zdekoduj, odfiltruj aktywnych premium z PL w wieku 25–45 ze score ≥ 40 założonych po 2021, posortuj po score, weź top 100, policz aktywnych per kraj i zakoduj wynik do JSON. Najpierw „jak każdy”, potem w trzech stopniach optymalizacji.

```bash
cd packages/users_pipeline
dart pub get
dart run bin/generate.dart                      # data/users_10k.json (deterministyczny, seed 42)
dart run bin/users_bench.dart                   # pobiera z raw.githubusercontent.com, fallback: plik lokalny
dart run bin/users_bench.dart --url https://gist.githubusercontent.com/<you>/<id>/raw/users.json
dart run bin/users_bench.dart --file data/users_10k.json --md results/jit.md
dart compile exe bin/users_bench.dart -o build/users_bench && ./build/users_bench --md results/aot.md
dart test
```

## Warianty

| # | Decode | Query + encode | Pliki |
|---|---|---|---|
| 1 🐢 | `http.get().body` (String) → `jsonDecode` → `List<Map>` → `User.fromJson` (10k × ~10 obiektów, `DateTime.parse`) | `where(...).toList()`, `sort`, `take(100).map(fullName)`, `Map<String,int>` group-by, `jsonEncode(toJson)` + `utf8.encode` | `pipeline_slow.dart`, `model.dart` |
| 2 🚀 | `bodyBytes` → `utf8.decoder.fuse(json.decoder)` → `User.fromJson` (te same obiekty) | pętla `for`, porównanie epoch ms, `JsonUtf8Encoder` | `pipeline_fast.dart` (`decodeFused`, `queryObjects`) |
| 3 🚀 | drzewo JSON → `UserTable` (kolumny typed data; stringi przepisane do jednego bufora) | jak 4 | `pipeline_fast.dart` (`tableFromTree`) |
| 4 🚀🚀 | **skaner bajtowy** `parseUsersColumnar`: jeden przebieg po `Uint8List`, zero drzewa, stringi jako offsety do oryginału, kraj internowany, data ISO → epoch ms bez `DateTime` | filtr po `Uint8List`/`Float64List`, top-100 przez kopiec min (bez sortowania 10k), group-by `Int32List`, encode przez kopiowanie surowych bajtów JSON | `json_scanner.dart`, `columnar.dart`, `pipeline_fast.dart` (`queryColumnar`) |

Izolaty (`runIsolateBenchmark`): `Isolate.run` zwracający `List<User>` (deep copy 100k obiektów) vs `TransferableTypedData` ze spakowaną tabelą (`UserTable.packContiguous()` / `unpack` — kolumny jako widoki na jeden bufor, zero kopii).

## Wyniki

`results/jit.md`, `results/aot.md` (ten kontener, 4 vCPU). Skrót (AOT, mediany) — patrz `docs/dart-flutter-extreme-performance-guide.md` §6.

## Dlaczego wariant 2 prawie nic nie daje

Fused dekoder oszczędza tylko pośredni `String` (3.3 MB → 6.6 MB UTF-16); koszt siedzi w budowie drzewa `Map`/`List`/`String` (~150k obiektów) i w `fromJson` (`DateTime.parse` ×10k, `cast<String>()`, `Address`). Dopóki budujesz drzewo i obiekty, „szybszy dekoder” to kosmetyka. Wariant 3 pokazuje, że same obiekty `User` to ~połowa kosztu; wariant 4 — że drugą połową jest drzewo.

## Struktura

```
lib/src/model.dart          User/Address/UserQuery/PipelineResult (idiomatyczne)
lib/src/generator.dart      deterministyczny generator danych
lib/src/pipeline_slow.dart  wariant 1
lib/src/pipeline_fast.dart  warianty 2–4 (query), ByteWriter, kopiec top-N
lib/src/json_scanner.dart   parser bajtowy -> UserTable
lib/src/columnar.dart       UserTable (typed data, offsety stringów, pack/unpack)
lib/src/fetch.dart          http.get().body vs bodyBytes vs HttpClient+BytesBuilder
lib/src/bench.dart          pomiary (mediana), warianty w izolacie, assertVariantsAgree
bin/users_bench.dart        CLI; bin/generate.dart; test/pipeline_test.dart
```
