---
name: dart-benchmark
description: Pisanie i uruchamianie wiarygodnych mikrobenchmarków i benchmarków end-to-end w Darcie w dowolnym projekcie - harness drop-in (warm-up, mediana z próbek, blackHole), JIT vs AOT (dart compile exe / dart build cli dla pakietów z native hooks), różnicowe testy poprawności, czytanie wyników i inspekcja wygenerowanego kodu (--print-flow-graph-optimized, --disassemble). Użyj, gdy coś trzeba zmierzyć ("czy to jest szybsze?"), dodać benchmark do projektu, zweryfikować optymalizację liczbami albo wyjaśnić zaskakujący wynik.
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu). Samowystarczalna: działa w dowolnym projekcie Dart/Flutter.

# dart-benchmark — zmierz, zanim uwierzysz

## 1. Harness drop-in

Wrzuć to do `tool/bench/harness.dart` (albo `benchmark/harness.dart`) w projekcie. Bez zależności.

```dart
import 'dart:io';
import 'dart:math' as math;

typedef BenchFn = void Function();

class BenchResult {
  final String suite, name; final double nsPerOp; final List<double> samples;
  BenchResult(this.suite, this.name, this.nsPerOp, this.samples);
}

class Suite {
  final String name; final int sampleMillis, samples; final _cases = <(String, BenchFn, BenchFn?)>[];
  Suite(this.name, {this.sampleMillis = 300, this.samples = 7});
  void add(String caseName, BenchFn fn, {BenchFn? setup}) => _cases.add((caseName, fn, setup));

  List<BenchResult> run() {
    stdout.writeln('\n== $name ==');
    final out = <BenchResult>[];
    for (final (caseName, fn, setup) in _cases) {
      setup?.call();
      final warm = Stopwatch()..start(); var warmIters = 0;
      while (warm.elapsedMilliseconds < 100) { fn(); warmIters++; }          // warm-up (JIT go potrzebuje; AOT wyrównuje cache)
      final nsPerWarmOp = warm.elapsedMicroseconds * 1000 / math.max(1, warmIters);
      final iters = (sampleMillis * 1e6 / math.max(1, nsPerWarmOp)).round().clamp(1, 1 << 30);
      final times = <double>[]; final sw = Stopwatch();
      for (var s = 0; s < samples; s++) {
        sw..reset()..start();
        for (var i = 0; i < iters; i++) { fn(); }
        sw.stop();
        times.add(sw.elapsedMicroseconds * 1000 / iters);
      }
      times.sort();
      final r = BenchResult(name, caseName, times[times.length ~/ 2], times);   // MEDIANA
      out.add(r);
      final base = out.first.nsPerOp / r.nsPerOp;
      stdout.writeln('  ${caseName.padRight(48)} ${_fmt(r.nsPerOp).padLeft(12)}  '
          '[min ${_fmt(times.first)}, max ${_fmt(times.last)}]  '
          '${identical(r, out.first) ? '(baseline)' : '${base.toStringAsFixed(2)}x ${base >= 1 ? 'faster' : 'SLOWER'}'}');
    }
    return out;
  }

  static String _fmt(double ns) => ns < 1e3 ? '${ns.toStringAsFixed(1)} ns'
      : ns < 1e6 ? '${(ns / 1e3).toStringAsFixed(2)} µs' : '${(ns / 1e6).toStringAsFixed(2)} ms';
}

/// Utrzymuje wynik przy życiu, żeby optymalizator nie mógł usunąć pracy (jak black_box w Ruście).
@pragma('vm:never-inline')
void blackHole(Object? value) { _sink = value; }
Object? _sink;
Object? get lastBlackHoleValue => _sink;
```

Alternatywa: `package:benchmark_harness` (`BenchmarkBase`, raportuje µs per `run()`); nie ma mediany/rozrzutu, więc dodaj własne powtórzenia.

## 2. Pisanie benchmarku

1. Jeden `Suite` = jedno pytanie. Pierwszy `add` to baseline (🐢), reszta to warianty (🚀). Nazwy mówią *co* i jaki rozmiar danych: `'json/encode feed (20 posts, ~2.6 KB)'`.
2. Każdy wynik przepuszczaj przez `blackHole(...)`, inaczej martwy kod zostanie wyeliminowany i nie zmierzysz nic.
3. Dane wejściowe twórz **raz**, poza mierzoną funkcją, i **kopiuj do zmiennej lokalnej/parametru** przed pętlą — top-level `final` to leniwy getter (~2.3× wolniej) i samo to może odwrócić wynik.
4. Sprawdź, że warianty liczą to samo (porównaj bajty/wyjścia w sanity checku w `main()` albo w teście) — szybsza funkcja z inną odpowiedzią to nie wynik.
5. Dla kodu async (izolaty, I/O) harness jest synchroniczny: mierz N `await`ów `Stopwatch`em, bierz medianę z kilku przebiegów.

```dart
import 'dart:typed_data';
import 'harness.dart';

const _n = 10_000;
final Int32List _data = Int32List.fromList(List.generate(_n, (i) => (i * 7919) % 1000));

int _slow(List<int> d) { var s = 0; for (final v in d) { s += v; } return s; }
int _fast(Int32List d) { var s = 0; for (var i = 0; i < d.length; i++) { s += d[i]; } return s; }

void main() {
  Suite('sum (10k)')
    ..add('List<int> for-in', () => blackHole(_slow(_data)))
    ..add('Int32List indexed', () => blackHole(_fast(_data)))
    ..run();
}
```

Benchmarki end-to-end (fetch → decode → filter → encode) znaczą dla decyzji więcej niż mikrobenchmarki: fused decoder JSON daje ~1.2× w izolacji, ale ucina tylko ~30 % na payloadzie z 10k rekordów, bo dominuje drzewo obiektów i `fromJson`. Fetch mierz raz i osobno; szum sieci to nie twój kod.

## 3. Uruchamianie: JIT i AOT

```bash
dart run tool/bench/main.dart                 # JIT (tak działają serwery; potrzebuje warm-upu)
dart compile exe tool/bench/main.dart -o build/bench && ./build/bench     # AOT = tak działa Flutter release
dart build cli -o build/aot                   # AOT dla pakietów z build hookami native-asset (np. sqlite3 >= 3)
```

**AOT to liczba, która się liczy** dla aplikacji mobilnych. JIT spekuluje na typach (suma `List<int>` jest tak szybka jak `Int32List`), AOT nie (~1.6–2.3× różnicy). Jeśli optymalizacja pomaga tylko w jednym trybie, powiedz w którym.

Zmniejsz `Suite(sampleMillis:, samples:)` dla wolnych operacji (np. 10k insertów do bazy: `sampleMillis: 1, samples: 3`). Uruchamiaj na spokojnej maszynie; współdzielony runner CI dodaje ±10 % szumu.

## 4. Czytanie wyników

- Porównuj **mediany**, patrz na rozrzut (min–max). Różnica < 10 % przy rozrzucie 20 % = szum, nie wynik.
- Zyski z typed data są największe w **budowaniu** (alokacja, boxing) i zapisie, nie w sekwencyjnych odczytach małych danych mieszczących się w cache.
- Delty RSS są tylko orientacyjne (wzrost heapu GC); do alokacji używaj DevTools Allocation tracing.
- Zapisuj wyniki z datą, wersją Darta, CPU i trybem (JIT/AOT) i zachowuj surowe liczby per próbka.

## 5. Gdy wynik zaskakuje: czytaj kod

Benchmark to eksperyment do interpretacji przez czytanie wygenerowanego kodu, nie wyrok.

```bash
# AOT, jedna funkcja:
dart compile exe bin/x.dart -o /tmp/x \
  --extra-gen-snapshot-options=--print-flow-graph-optimized \
  --extra-gen-snapshot-options=--print-flow-graph-filter=_fast \
  --extra-gen-snapshot-options=--disassemble
# JIT:
dart --print-flow-graph-optimized --print-flow-graph-filter=_fast --disassemble-optimized --no-background-compilation bin/x.dart
```

Czego szukać w IL: `CheckSmi`/`CheckClass` (spekulacja, deopt), `Box`/`Unbox` (boxing double/int), `StoreIndexed ... NoStoreBarrier` (bez bariery — dobrze), `CheckArrayBound` (niewyniesione sprawdzenie zakresu), `CheckStackOverflow` w nagłówku pętli (normalne), `InitStaticField`/wywołania gettera leniwego pola (pułapka z §2), `BinaryInt64Op` zamiast `BinarySmiOp` (unboxed int).

Pragmy: `@pragma('vm:prefer-inline')`, `vm:never-inline` (zawsze honorowana), `vm:align-loops`; **nie** używaj `vm:unsafe:*` w produkcji bez zgody.

## 6. Typowe błędy w benchmarkach

- Wynik nieużyty → kod usunięty → "0 ns". Zawsze `blackHole`.
- Dane tworzone wewnątrz mierzonej funkcji → mierzysz alokację danych, nie algorytm (chyba że celowo).
- Jedna próbka, brak warm-upu (JIT), porównywanie JIT z AOT.
- Pętla ze stałą liczbą iteracji, którą kompilator częściowo wylicza → używaj danych generowanych albo z pliku.
- Zmienione warunki między wariantami (inny rozmiar danych, inne wyjście).
- Porównywanie `TransferableTypedData` bez uwzględnienia kopii w `fromList`.
- Sieć albo dysk wewnątrz mierzonej sekcji.

Lektura uzupełniająca z uruchamialnymi benchmarkami: https://github.com/Thioby/dart-performance
