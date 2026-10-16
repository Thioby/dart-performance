> 🇬🇧 English version · [🇵🇱 Wersja polska](README.md)

# users_pipeline — a realistic benchmark: 10k users from JSON

A scenario like in a real app: fetch a list of 10,000 users as JSON (3.3 MB), decode it, filter active premium users from PL aged 25–45 with score ≥ 40 who signed up after 2021, sort by score, take the top 100, count active users per country and encode the result back to JSON. First "the way everyone does it", then in three levels of optimization.

```bash
cd packages/users_pipeline
dart pub get
dart run bin/generate.dart                      # data/users_10k.json (deterministic, seed 42)
dart run bin/users_bench.dart                   # fetches from raw.githubusercontent.com, falls back to the local file
dart run bin/users_bench.dart --url https://gist.githubusercontent.com/<you>/<id>/raw/users.json
dart run bin/users_bench.dart --file data/users_10k.json --md results/jit.md
dart compile exe bin/users_bench.dart -o build/users_bench && ./build/users_bench --md results/aot.md
dart test
```

## Variants

| # | Decode | Query + encode | Files |
|---|---|---|---|
| 1 🐢 | `http.get().body` (String) → `jsonDecode` → `List<Map>` → `User.fromJson` (10k × ~10 objects, `DateTime.parse`) | `where(...).toList()`, `sort`, `take(100).map(fullName)`, `Map<String,int>` group-by, `jsonEncode(toJson)` + `utf8.encode` | `pipeline_slow.dart`, `model.dart` |
| 2 🚀 | `bodyBytes` → `utf8.decoder.fuse(json.decoder)` → `User.fromJson` (the same objects) | a `for` loop, epoch-ms comparison, `JsonUtf8Encoder` | `pipeline_fast.dart` (`decodeFused`, `queryObjects`) |
| 3 🚀 | JSON tree → `UserTable` (typed-data columns; strings copied into one buffer) | as in 4 | `pipeline_fast.dart` (`tableFromTree`) |
| 4 🚀🚀 | **byte scanner** `parseUsersColumnar`: one pass over the `Uint8List`, no tree, strings as offsets into the original, interned countries, ISO date → epoch ms without `DateTime` | filter over `Uint8List`/`Float64List`, top 100 via a min-heap (no 10k sort), group-by in an `Int32List`, encode by copying the raw JSON bytes | `json_scanner.dart`, `columnar.dart`, `pipeline_fast.dart` (`queryColumnar`) |

Isolates (`runIsolateBenchmark`): `Isolate.run` returning a `List<User>` (deep copy of 100k objects) vs a `TransferableTypedData` with the packed table (`UserTable.packContiguous()` / `unpack` — columns as views over one buffer, zero copies).

## Results

`results/jit.md`, `results/aot.md` (this container, 4 vCPU). Summary (AOT, medians): decode 76 → 12 ms, end-to-end 93.6 → 12.0 ms (7.8×), `Isolate.run` round trip 104 → 31 ms. See `docs/en/dart-flutter-extreme-performance-guide.md` §6.

## Why variant 2 buys almost nothing

The fused decoder only saves the intermediate `String` (3.3 MB → 6.6 MB of UTF-16); the cost sits in building the `Map`/`List`/`String` tree (~150k objects) and in `fromJson` (`DateTime.parse` ×10k, `cast<String>()`, `Address`). As long as you build the tree and the objects, a "faster decoder" is cosmetics. Variant 3 shows that the `User` objects themselves are ~half of the cost; variant 4 shows that the tree is the other half.

## Structure

```
lib/src/model.dart          User/Address/UserQuery/PipelineResult (idiomatic)
lib/src/generator.dart      deterministic data generator
lib/src/pipeline_slow.dart  variant 1
lib/src/pipeline_fast.dart  variants 2–4 (query), ByteWriter, top-N heap
lib/src/json_scanner.dart   byte parser -> UserTable
lib/src/columnar.dart       UserTable (typed data, string offsets, pack/unpack)
lib/src/fetch.dart          http.get().body vs bodyBytes vs HttpClient+BytesBuilder
lib/src/bench.dart          measurements (median), isolate variants, assertVariantsAgree
bin/users_bench.dart        CLI; bin/generate.dart; test/pipeline_test.dart
```
