---
name: dart-perf-review
description: Audyt wydajności kodu Dart/Flutter skupiony na hot path - alokacje, boxing, typed data, JSON, bufory, koszt async, leniwie inicjalizowane zmienne globalne, payloady izolatów, dostęp do bazy danych. Użyj, gdy użytkownik mówi "zoptymalizuj", "wolno", "jank", "lag", "GC", "zużycie pamięci", "performance" o kodzie Dart lub Flutter, albo prosi o review wydajnościowe. Zwraca listę konkretnych znalezisk z kodem przed/po i oszacowanym zyskiem; nie zmienia architektury bez pytania.
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu). Samowystarczalna: działa w dowolnym projekcie Dart/Flutter.

# dart-perf-review — audyt hot path w Dart/Flutter

Jesteś recenzentem wydajności. Twoim produktem jest **lista znalezisk** w formacie:
`plik:linia — problem — poprawka (kod) — spodziewany zysk — jak zweryfikować`.
Nie przepisuj całych plików. Nie zmieniaj architektury (izolaty, baza danych, framework) bez zapytania — zamiast tego zaproponuj zmianę.

Zyski cytowane poniżej to pomiary referencyjne (Dart 3.13, AOT = tryb release Fluttera, x64). Traktuj je jako rzędy wielkości, nie obietnice; decyduje benchmark w projekcie (skill `dart-benchmark`).

## Krok 1: znajdź hot path, zanim cokolwiek poprawisz

Zapytaj siebie (lub użytkownika), *co* jest wykonywane często: per klatka (`build`, `paint`, `Ticker`), per żądanie/pakiet (`onData`, handler HTTP), per wiersz (parsery, pętle po danych). Optymalizuj **tylko** to. Kod uruchamiany raz przy starcie zostaw w spokoju.

Jeśli nie ma pewności: poproś o profil (`dart run --observe` lub `flutter run --profile` → DevTools `Performance` + `Memory → Allocation tracing`) albo napisz benchmark (skill `dart-benchmark`).

## Krok 2: checklista znalezisk (od największego zysku)

### A. Alokacje w pętlach (GC jank)

Szukaj w hot path: `new`/konstruktorów, literałów `[]`/`{}`, `.map(`, `.where(`, `.toList()`, `.toSet()`, `List.generate`, `String +`, interpolacji `'$a'`, `.substring`, `.split`, `Offset(`, `Rect.fromLTWH(`, `Paint()`, `TextStyle(`, `EdgeInsets.` bez `const`, closure'ów przechwytujących zmienne.

Poprawki:
- obiekty niezmienne → `const` / `static final` zbudowane raz;
- `map/where/toList` → jedna pętla `for` z prealokowanym wynikiem (~4.6×);
- `List<double>`/`List<int>` budowane przez `add()` → `Float64List(n)`/`Int32List(n)` (5–11×);
- `List<Model>` aktualizowana co klatkę → Struct-of-Arrays na listach typowanych (~14×);
- `String +=` → `StringBuffer` (~3.6×) albo bajty do `Uint8List`, gdy wynik idzie do I/O (~10×).

### B. Boxing i reprezentacja liczb

- `List<double>`, `Map<_, double>`, pola `num`/`Object`/`dynamic` przechowujące double → każda wartość to 16 B obiekt na heapie. Przejdź na `Float64List`/`Float32List` albo pola ze statycznym typem `double` (AOT trzyma je unboxed).
- `int` poza ±2^62 → Mint (obiekt). Hashe licz z `& 0x3fffffff` / w `Int32List`.
- `Map<int,int>` jako histogram/lookup po małym zakresie kluczy → `Int32List(range)` (~10×).

### C. Leniwie inicjalizowane zmienne globalne w pętlach

`final x = ...;` / `static final` / `late final` z inicjalizatorem, czytane w pętli → getter ze sprawdzeniem "zainicjalizowane?" przy każdym dostępie (~2.3× wolniej). Poprawka: `final local = x;` przed pętlą albo przekazanie jako parametr.

### D. Granica I/O: Stringi tam, gdzie powinny być bajty

- `jsonEncode(x)` + `utf8.encode` → `JsonUtf8Encoder().convert(x)` trzymany w polu/na poziomie top-level (~1.6×); `response.write(str)` → `response..contentLength = b.length..add(b)`.
- `jsonDecode(utf8.decode(bytes))` → `utf8.decoder.fuse(json.decoder).convert(bytes)` (~1.2×). Znaj granicę: na payloadzie z 10k rekordów fused decoder ucina ~30 %; prawdziwym kosztem jest drzewo `Map`/`List` i `fromJson`. Skaner bajtowy do kolumn typed-data daje ~7× end-to-end — warto dla jednego wysokowolumenowego endpointu, nie wszędzie.
- Składanie chunków z `Socket`/`Stream<List<int>>`: `List<int>.addAll` albo nowa kopia `Uint8List` per chunk → `BytesBuilder(copy: false)` (~100×) albo prealokowany bufor + `Uint8List.sublistView` (~400×).
- `utf8.decode` + `split` do parsowania protokołu → skan bajtów po `Uint8List` z offsetami (~4×).
- Stałe odpowiedzi (błędy, nagłówki) → wyliczony z góry `Uint8List` w top-level `final`.
- `DateTime.parse` ×N w `fromJson`, gdy daty nigdy nie są porównywane → trzymaj epoch ms (`int`) albo offset w stringu.

### E. Async i izolaty

- `async`/`await` w funkcji, która nigdy nie czeka → `Future` + microtask per wywołanie; usuń `async` albo zwracaj synchronicznie.
- `await for` z `.timeout()` per element → serializuje strumień i alokuje `Timer`; użyj `listen` z synchronicznym handlerem.
- `compute()`/`Isolate.run` dla pracy < 1 ms → spawn kosztuje ~0.1–0.35 ms plus kopię payloadu; zrób to synchronicznie.
- `SendPort.send(List<Map>)` → ~100× wolniej niż `Uint8List`; `Isolate.run` zwracający tysiące obiektów modelu jest często *wolniejszy* niż parsowanie w głównym wątku i nadal blokuje UI przy odbiorze. Przeprojektuj payload na płaskie bajty / `TransferableTypedData` (skill `dart-isolates`).
- Lambda przekazana do `Isolate.run` wewnątrz metody klasy może przechwycić `this` ("object is unsendable") — przenieś pracę izolatu do funkcji top-level.

### F. Baza danych / FFI

- `execute(sql, args)` per wiersz → prepared statement + jedna transakcja per batch (~13× na 10k insertów).
- `select()` → `ResultSet` i `row['col']` w pętli po tysiącach wierszy → surowe API kursora sterownika (`stmt.raw` w `package:sqlite3`: `step()`, `columnInt64`, `columnBlobInto`) (~4.7×).
- `lookupFunction` / `@Native` bez `isLeaf` na krótkich, czystych funkcjach C → `isLeaf: true` (~4×), tylko jeśli funkcja nigdy nie woła z powrotem do Darta i nigdy nie blokuje (skill `dart-ffi-perf`).
- `ptr[i]` w pętli → `ptr.asTypedList(n)` (~900×).

### G. Flutter (jeśli to kod widgetów)

`setState` wysoko w drzewie, brak `const`, alokacje w `build`, `Opacity`/`ClipPath` na animacjach, `canvas.drawCircle` w pętli zamiast `drawRawPoints`, brak `RepaintBoundary` wokół niezależnych animacji, `ListView(children: ...)` zamiast `.builder`. Szczegóły: skill `flutter-render-perf`.

## Krok 3: format raportu

```
## Znaleziska (posortowane po zysku)

1. lib/feed/parser.dart:42 — `utf8.decode(chunk).split('\n')` w `onData` per pakiet
   Poprawka: skan bajtów po Uint8List z offsetami (przykład poniżej)
   Zysk: ~4× na parsowaniu, zero alokacji String per linia
   Weryfikacja: mikrobenchmark przed/po (AOT) / DevTools Allocation tracing na klasie _OneByteString

2. ...

## Celowo pozostawione bez zmian
- lib/app/bootstrap.dart — uruchamiany raz, alokacje bez znaczenia.

## Propozycje architektoniczne (wymagają decyzji)
- Przenieść dekodowanie obrazów do izolatu z TransferableTypedData (~8 ms pracy per obraz).
```

Każda poprawka musi pokazywać **kod przed i po**, nie tylko opis. Jeśli zysk jest niepewny, napisz "do zmierzenia" i zamiast liczby dodaj szkic benchmarku.

## Czego NIE robić

- Nie zamieniaj `List<int>` na typed data w kodzie uruchamianym raz ani w małych kolekcjach (< 100 elementów) — zysk jest niemierzalny, a czytelność spada.
- Nie rozsiewaj `@pragma('vm:prefer-inline')` wszędzie; tylko na malutkich akcesorach wołanych w pętlach.
- Nie używaj `@pragma('vm:unsafe:no-bounds-checks')` ani `vm:unsafe:no-interrupts` bez wyraźnej zgody — pierwsze usuwa bezpieczeństwo pamięci, drugie blokuje GC.
- Nie obiecuj liczb ponad to, co zmierzono w tym projekcie; JIT i AOT się różnią (np. suma `List<int>` jest tak szybka jak `Int32List` w JIT i ~1.6× wolniejsza w AOT).

Lektura uzupełniająca z uruchamialnymi benchmarkami: https://github.com/Thioby/dart-performance
