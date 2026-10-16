---
name: dart-perf-review
description: Audyt wydajności kodu Dart/Flutter pod kątem hot path - alokacje, boxing, typed data, JSON, bufory, async, leniwe pola globalne. Użyj, gdy użytkownik mówi "zoptymalizuj", "wolno", "jank", "lag", "GC", "zużycie pamięci", "performance" o kodzie Dart lub Flutter, albo prosi o review wydajnościowe. Zwraca listę konkretnych znalezisk z poprawkami i oszacowanym zyskiem; nie dotyka architektury bez pytania.
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu).

# dart-perf-review — audyt hot path w Dart/Flutter

Jesteś recenzentem wydajności. Twoim produktem jest **lista znalezisk** w formacie:
`plik:linia — problem — poprawka (kod) — spodziewany zysk — jak zweryfikować`.
Nie przepisuj całego pliku. Nie zmieniaj architektury (izolaty, baza, framework) bez zapytania — zaproponuj.

Pełne uzasadnienia i liczby: `docs/dart-flutter-extreme-performance-guide.md` (sekcje 1, 2, 3, 5). Benchmarki do weryfikacji: `benchmarks/` (`tool/run.sh`). Jeśli repozytorium, w którym pracujesz, ich nie ma — zasady poniżej są samowystarczalne.

## Krok 1: znajdź hot path, zanim cokolwiek poprawisz

Zapytaj siebie (lub użytkownika), *co* jest wywoływane często: per klatka (`build`, `paint`, `Ticker`), per żądanie/pakiet (`onData`, handler HTTP), per wiersz (parsery, pętle po danych). Optymalizuj **tylko** to. Kod uruchamiany raz przy starcie zostaw.

Jeśli nie ma pewności: poproś o profil (`dart run --observe` / DevTools `Performance` + `Memory → Allocation tracing`) albo napisz benchmark (skill `dart-benchmark`).

## Krok 2: checklista znalezisk (od największego zysku)

### A. Alokacje w pętli (GC jank)

Szukaj w hot path: `new`/konstruktorów, literałów `[]`/`{}`, `.map(`, `.where(`, `.toList()`, `.toSet()`, `List.generate`, `String +`, interpolacji `'$a'`, `.substring`, `.split`, `Offset(`, `Rect.fromLTWH(`, `Paint()`, `TextStyle(`, `EdgeInsets.` bez `const`, closure'ów przechwytujących zmienne.

Poprawki:
- obiekty niezmienne → `const` / `static final` zbudowane raz;
- `map/where/toList` → jedna pętla `for` z prealokowanym wynikiem (4.6×);
- `List<double>`/`List<int>` budowane `add()` → `Float64List(n)`/`Int32List(n)` (5–11×);
- `List<Model>` aktualizowane co klatkę → Struct-of-Arrays na typed listach (14×);
- `String +=` → `StringBuffer` (3.6×) lub bajty do `Uint8List`, gdy wynik idzie do I/O (10×).

### B. Boxing i reprezentacja liczb

- `List<double>`, `Map<_, double>`, pola `num`/`Object`/`dynamic` trzymające double → każda wartość to obiekt 16 B. Zamień na `Float64List`/`Float32List` albo pola o statycznym typie `double` (AOT trzyma je unboxed).
- `int` spoza ±2^62 → Mint (obiekt). Hash-e licz z `& 0x3fffffff` / w `Int32List`.
- `Map<int,int>` jako histogram/lookup z małym zakresem kluczy → `Int32List(range)` (10.8×).

### C. Leniwe pola globalne w pętli

`final x = ...;` / `static final` / `late final` z inicjalizatorem, czytane w pętli → getter ze sprawdzeniem inicjalizacji przy każdym dostępie (2.3× wolniej). Poprawka: `final local = x;` przed pętlą, albo przekaż jako parametr.

### D. Granica I/O: Stringi tam, gdzie powinny być bajty

- `jsonEncode(x)` + `utf8.encode` → `JsonUtf8Encoder().convert(x)` trzymany w polu/top-level (1.6×); `response.write(str)` → `response..contentLength = b.length..add(b)`.
- `jsonDecode(utf8.decode(bytes))` → `utf8.decoder.fuse(json.decoder).convert(bytes)` (1.2×); gdy potrzebne 1–2 pola z dużego JSON → parser strumieniowy lub format binarny.
- Składanie fragmentów z `Socket`/`Stream<List<int>>`: `List<int>.addAll` lub `Uint8List` nowa kopia per fragment → `BytesBuilder(copy: false)` (100×) albo prealokowany bufor + `Uint8List.sublistView` (400×).
- `utf8.decode` + `split` do parsowania protokołu → skan po `Uint8List` z offsetami (4×).
- Stałe odpowiedzi (błędy, nagłówki) → prekomputowane `Uint8List` w `final` top-level.

### E. Async i izolaty

- `async`/`await` w funkcji, która nigdy nie czeka → `Future` + mikrotask per wywołanie; usuń `async` lub zwróć wartość synchronicznie.
- `await for` z `.timeout()` per element → serializuje strumień i alokuje `Timer`; użyj `listen` z synchronicznym handlerem.
- `compute()`/`Isolate.run` dla pracy < 1 ms → spawn kosztuje ~0.1–0.35 ms + kopia payloadu; zrób synchronicznie.
- `SendPort.send(List<Map>)` → 128× wolniej niż `Uint8List`; przeprojektuj payload na płaskie bajty (skill `dart-isolates`).

### F. Baza danych / FFI

- `execute(sql, args)` per wiersz → prepared statement `persistent: true` + jedna transakcja na paczkę (13×).
- `select()` → `ResultSet` i `row['col']` w pętli po tysiącach wierszy → `stmt.raw` (`step()`, `columnInt64`, `columnBlobInto`) (4.7×).
- `lookupFunction` / `@Native` bez `isLeaf` na krótkich, czystych funkcjach C → `isLeaf: true` (4×), tylko jeśli funkcja nie woła Darta i nie blokuje (skill `dart-ffi-perf`).
- `ptr[i]` w pętli → `ptr.asTypedList(n)` (900×).

### G. Flutter (jeśli kod jest widgetowy)

`setState` wysoko w drzewie, brak `const`, alokacje w `build`, `Opacity`/`ClipPath` na animacjach, `canvas.drawCircle` w pętli zamiast `drawRawPoints`, brak `RepaintBoundary` wokół niezależnych animacji, `ListView(children: ...)` zamiast `.builder`. Szczegóły: skill `flutter-render-perf`.

## Krok 3: format raportu

```
## Znaleziska (posortowane wg zysku)

1. lib/feed/parser.dart:42 — `utf8.decode(chunk).split('\n')` w `onData` per pakiet
   Poprawka: skan po Uint8List z offsetami (przykład poniżej)
   Zysk: ~4× na parsowaniu, zero alokacji String per linia
   Weryfikacja: benchmarks `--only buffers` / DevTools Allocation tracing na klasie _OneByteString

2. ...

## Nie ruszane (świadomie)
- lib/app/bootstrap.dart — wykonuje się raz, alokacje nieistotne.

## Propozycje architektoniczne (wymagają decyzji)
- Przenieść dekodowanie obrazów do izolatu z TransferableTypedData (praca ~8 ms/obraz).
```

Każda poprawka ma pokazać **kod przed i po**, nie tylko opis. Jeśli zysk jest niepewny, napisz „do zmierzenia” i dodaj szkic benchmarku zamiast liczby.

## Czego NIE robić

- Nie zamieniaj `List<int>` na typed data w kodzie wykonywanym raz ani w małych kolekcjach (< 100 elementów) — zysk niemierzalny, czytelność spada.
- Nie dodawaj `@pragma('vm:prefer-inline')` hurtowo; tylko na maleńkich akcesorach wołanych w pętli (jak `flat_buffers.dart`).
- Nie używaj `@pragma('vm:unsafe:no-bounds-checks')` ani `vm:unsafe:no-interrupts` bez wyraźnej zgody — pierwsze usuwa bezpieczeństwo pamięci, drugie blokuje GC.
- Nie obiecuj liczb spoza benchmarków; JIT i AOT różnią się (np. `List<int>` sum jest w JIT tak szybkie jak `Int32List`, w AOT 1.6× wolniejsze).
