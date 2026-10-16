---
name: dart-benchmark
description: Pisanie i uruchamianie rzetelnych mikrobenchmarków Dart z harnessem z tego repo (benchmarks/lib/harness.dart) - rozgrzewka, mediana z prób, blackHole, JIT vs AOT (dart build cli dla pakietów z hookami natywnymi), odczyt wyników i zaglądanie w kod maszynowy (--print-flow-graph-optimized, --disassemble). Użyj, gdy trzeba zmierzyć "czy to jest szybsze", dodać nowy benchmark do benchmarks/, zweryfikować optymalizację liczbami, albo wyjaśnić zaskakujący wynik.
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu).

# dart-benchmark — mierz, zanim wierzysz

Harness: `benchmarks/lib/harness.dart` (`Suite`, `BenchResult`, `blackHole`, `toMarkdown`). Runner: `benchmarks/bin/run_all.dart`. Skrypt JIT+AOT: `benchmarks/tool/run.sh`. Wyniki referencyjne: `benchmarks/RESULTS.md`.

## 1. Dodanie benchmarku

1. Utwórz `benchmarks/lib/src/bench_<temat>.dart` z funkcją `List<Suite> suites()`.
2. Każdy `Suite` = jedno pytanie, pierwszy `add` = baseline (🐢), kolejne = warianty (🚀). Nazwy mówią *co* jest mierzone i rozmiar danych (`'json/encode feed (20 postów, ~2.6 KB)'`).
3. Wynik każdej funkcji przepuść przez `blackHole(...)` (`@pragma('vm:never-inline')`), inaczej optymalizator usunie martwy kod.
4. Dane wejściowe twórz **raz** na poziomie biblioteki i **kopiuj do lokalnej/parametru** przed pętlą (top-level `final` to leniwy getter, 2.3× wolniej — sam ten błąd potrafi odwrócić wynik).
5. Zarejestruj grupę w `_groups` w `bin/run_all.dart`.
6. Sprawdź, że warianty dają identyczny wynik (jak `bench_json.dart` porównuje bajty trzech encoderów) — benchmark czegoś, co liczy co innego, jest bezwartościowy.

Szablon:

```dart
import 'dart:typed_data';
import '../harness.dart';

const _n = 10_000;
final Int32List _data = Int32List.fromList(List.generate(_n, (i) => i));

int _slow(List<int> d) { var s = 0; for (final v in d) { s += v; } return s; }
int _fast(Int32List d) { var s = 0; for (var i = 0; i < d.length; i++) { s += d[i]; } return s; }

List<Suite> suites() => [
  Suite('temat/sum (10k)')
    ..add('List<int> for-in', () => blackHole(_slow(_data)))
    ..add('Int32List indexed', () => blackHole(_fast(_data))),
];
```

Dla kodu asynchronicznego (izolaty, I/O) harness jest synchroniczny — mierz ręcznie `Stopwatch` wokół N `await`, mediana z prób (wzór: `runIsolateSuite` w `bench_isolates.dart`).

## 2. Uruchamianie

```bash
cd benchmarks && dart pub get
tool/build_native.sh                          # tylko dla grupy ffi (gcc/clang)
dart run bin/run_all.dart --only temat        # JIT, szybko
tool/run.sh                                   # JIT + AOT -> results/jit.md, results/aot.md, *.json
tool/run.sh temat,json                        # wybrane grupy
```

AOT: pakiety z build hooks (`sqlite3` ≥ 3) nie działają z `dart compile exe` — skrypt używa `dart build cli -o build/aot` i uruchamia `build/aot/bundle/bin/run_all`. Flutter release = AOT, więc **AOT jest wynikiem, który się liczy** dla aplikacji mobilnych; JIT dla serwerów `dart run` i testów.

Harness: rozgrzewka 100 ms → dobór iteracji na ~300 ms próby → 7 prób → **mediana**, plus min/max. Pola `Suite(sampleMillis:, samples:)` zmniejsz dla wolnych operacji (SQLite insert 10k: `sampleMillis: 1, samples: 3`).

## 3. Czytanie wyników

- Porównuj **mediany**, patrz na rozrzut (min–max). Różnica < 10 % przy rozrzucie 20 % = szum, nie wynik.
- JIT ≠ AOT: JIT spekuluje typy (`List<int>` sum równie szybkie jak `Int32List`), AOT nie (1.6–2.3× różnicy). Jeśli optymalizacja pomaga tylko w jednym trybie, powiedz w którym.
- Zyski z typed data są największe w **budowaniu** (alokacja, boxing) i zapisie, nie w sekwencyjnym odczycie małych danych mieszczących się w cache.
- `rssDeltaBytes` w `BenchResult` jest orientacyjny (RSS rośnie też przez GC heap growth); do alokacji użyj DevTools.
- Zapisz do `RESULTS.md` tylko wyniki z `tool/run.sh` (oba tryby) z datą, wersją Darta, CPU.

## 4. Gdy wynik zaskakuje: zajrzyj w kod

Egorov („Microbenchmarks are experiments”): benchmark to eksperyment do interpretacji przez czytanie wygenerowanego kodu, nie wyrok.

```bash
# AOT, jedna funkcja:
dart compile exe bin/x.dart -o /tmp/x \
  --extra-gen-snapshot-options=--print-flow-graph-optimized \
  --extra-gen-snapshot-options=--print-flow-graph-filter=_fast \
  --extra-gen-snapshot-options=--disassemble
# JIT:
dart --print-flow-graph-optimized --print-flow-graph-filter=_fast --disassemble-optimized --no-background-compilation bin/x.dart
```

Czego szukać w IL: `CheckSmi`/`CheckClass` (spekulacja, deopt), `Box`/`Unbox` (boxing double/int), `StoreIndexed ... NoStoreBarrier` (brak bariery — dobrze), `CheckArrayBound` (bounds check niezhoistowany), `CheckStackOverflow` w nagłówku pętli (normalne), wywołania `InitStaticField`/getterów leniwych pól (pułapka z §1), `BinaryInt64Op` zamiast `BinarySmiOp` (unboxed int).

Pragmy diagnostyczne/sterujące (`runtime/docs/pragmas.md`): `@pragma('vm:prefer-inline')`, `vm:never-inline` (zawsze respektowane), `vm:align-loops`; **nie** używaj `vm:unsafe:*` w produkcji bez zgody.

## 5. Typowe błędy benchmarków

- Wynik nieużyty → kod usunięty → „0 ns”. Zawsze `blackHole`.
- Dane tworzone wewnątrz mierzonej funkcji → mierzysz alokację danych, nie algorytm (chyba że to celowo, jak `typed_lists/build`).
- Jedna próba, brak rozgrzewki (JIT), porównanie JIT z AOT.
- Pętla o stałej liczbie iteracji, którą kompilator częściowo wylicza w czasie kompilacji → użyj danych z `List.generate` z nietrywialną funkcją lub z pliku.
- Zmienione warunki między wariantami (różny rozmiar danych, różne wyjście).
- Porównanie `TransferableTypedData` bez uwzględnienia, że `fromList` kopiuje.
