> 🇵🇱 Wersja polska · [🇬🇧 English version](en/dart-flutter-extreme-performance-guide.md)

# Jak pisać ekstremalnie szybki kod w Dart i Flutter (Low-Latency / Zero-Allocation Dart)

> Przewodnik oparty na analizie kodu źródłowego:
>
> | Źródło | Co z niego wzięliśmy |
> |---|---|
> | `simolus3/sqlite3.dart` v3.7.1 (`sqlite3/lib/src/ffi/bindings.dart`, `libsqlite3.g.dart`, `memory.dart`, `lib/src/implementation/statement.dart`, `tool/generate_bindings.dart`) | `@Native`, `isLeaf`, `NativeFinalizer`, `asTypedList`, `RawPreparedStatement`, `columnBlobInto`, bind tekstu z `malloc.nativeFree` |
> | `TechEmpower/FrameworkBenchmarks/frameworks/Dart` (`dart3/dart_aot/bin/server.dart`, `dart3/dart_native`, `shelf`, `relic`, `dart_frog`, `angel3`) | `JsonUtf8Encoder` + `response.add`, `shared: true`, grupy izolatów przez `Isolate.spawnUri`, `defaultResponseHeaders.clear()` |
> | `google/flatbuffers/dart/lib/flat_buffers.dart`, `objectbox/flatbuffers-benchmark`, `objectbox/objectbox-dart` (`native/bindings/flatbuffers.dart`, `entity_definition.dart`, `bindings/helpers.dart`), `isar/isar` v4 (`isar_core.dart`, `native/bindings.dart`, `ffigen.yaml`) | `ByteData` + `Endian.little`, `const` readery, `@pragma('vm:prefer-inline')`, builder na pamięci `malloc`, reużywane out-pointery, `isLeaf` na każdym odczycie pola |
> | `dart-lang/sdk/runtime/docs` (`README.md` = „Introduction to Dart VM” V. Egorova, `gc.md`, `glossary.md`, `types.md`, `pragmas.md`, `compressed-pointers.md`) | Smi/Mint, nagłówek obiektu, TLAB, scavenger, bariery zapisu, safepointy, TFA, pragmy |
> | `arjaythedev/twelve-dollar-server-challenge` PR #46 `dart-rawsocket-C-Hatton/bin/server.dart` | serwer HTTP na `ServerSocket` bez `HttpServer`, `CAST(... AS BLOB)`, reużywany bufor wyjściowy, prekomputowane odpowiedzi błędów |
> | Własne benchmarki w `benchmarks/` tego repozytorium (JIT i AOT, Dart 3.13.5, Linux x64) | Każda liczba w tym dokumencie, jeśli nie podano innego źródła |
>
> Konwencja: 🐢 = typowy kod, 🚀 = wariant zoptymalizowany. Liczby to mediany z `benchmarks/results/aot.md` (tryb AOT, bo tak działa Flutter w release) — jeśli JIT różni się istotnie, piszę o tym.

---

## 1. Dart VM pod maską: pamięć, GC i `dart:typed_data`

### 1.1 Jak VM reprezentuje obiekty

Z `runtime/docs/gc.md` i `glossary.md`:

* **Wskaźniki tagowane.** Każdy slot (pole obiektu, element `List`) to słowo maszynowe. Jeśli najniższy bit = 0, słowo *jest* liczbą — **Smi** (small integer, 63-bitowy na x64, 31-bitowy na 32-bit / z `compressed-pointers`). Jeśli bit = 1 — to wskaźnik na obiekt sterty. „A tag of 0 allows many operations to be performed on Smis without untagging and retagging”.
* **Mint.** `int` spoza zakresu Smi to obiekt na stercie (**Mint**, 64-bit): alokacja + wskaźnik + GC. Na 64-bit praktycznie każdy `int` w aplikacji jest Smi, ale w kontenerach generycznych (`List<int>`, `Map<int, …>`) nadal zajmuje pełne 8 B na element i każda operacja zaczyna się od testu tagu.
* **`double` jest zawsze obiektem** w kontekście generycznym (`List<double>`, pole typu `Object`/`num`, argument `dynamic`). 16 B (nagłówek + wartość) na stercie **per wartość**. W AOT kompilator trzyma `double` *unboxed* w lokalnych zmiennych, polach klas o statycznym typie `double` i w `Float64List` — ale `List<double>.add(x)` musi x zaboksować.
* **Nagłówek obiektu**: 1 słowo (klasa = *class id* 16/20-bit, rozmiar, flagi GC: mark bit, remembered bit, „new or evacuation candidate”), na 64-bit + 32-bit identity hash. Obiekt zajmuje więc minimum 16 B.
* **Wiek po adresie**: obiekty w *old space* są wyrównane do podwójnego słowa, w *new space* przesunięte o słowo — scavenger rozpoznaje „stary/nowy/Smi” jednym `and`+`branch`, bez porównywania z granicami.
* **`List<T>`** to obiekt z nagłówkiem, długością i tablicą *tagowanych słów*. **`Uint8List`/`Float64List`** to obiekt z nagłówkiem, długością i surowymi bajtami: 1 B/element dla `Uint8List`, 8 B/element bez tagu i bez boxingu dla `Float64List`. Widoki (`Uint8List.view`, `sublistView`, `ByteData.view`) to osobny mały obiekt (`_TypedListView`) wskazujący na wspólny `ByteBuffer`.

### 1.2 GC: skąd bierze się jank

Z `gc.md`:

> „The Dart VM has a generational garbage collector with two generations. The new generation is collected by a parallel, stop-the-world semispace scavenger. The old generation is collected by concurrent-mark-concurrent-sweep or by concurrent-mark-parallel-compact.”

* **Alokacja** = bump pointer w **TLAB** (thread-local allocation buffer) — kilka instrukcji. Dlatego „alokacja w Darcie jest tania” jest prawdą… dla pojedynczej alokacji.
* **Scavenge** (new space) jest **stop-the-world**: mutator staje w *safepoincie*, scavenger kopiuje żywe obiekty do drugiej półprzestrzeni (Cheney), martwe znikają za darmo. Koszt ∝ liczba *żywych* obiektów w new space + skanowanie *remembered set* (stare obiekty wskazujące na nowe). Czas: zwykle 0.5–5 ms, ale przy dużym grafie młodych obiektów (np. 10 000 widgetów właśnie zbudowanych) — więcej.
* **Bariera zapisu.** Każdy zapis wskaźnika do pola obiektu (`obj.field = other`, `list[i] = other`) przechodzi przez barierę: jeśli `obj` jest stary, a `other` młody → dodaj `obj` do remembered set; jeśli trwa marking → oznacz. Kompilator usuwa barierę dla Smi, `bool`, stałych („Constants are always old”) i zapisów tuż po alokacji. **Zapis do `Float64List`/`Uint8List` nie ma bariery** — zapisujesz bajty, nie wskaźniki.
* **Safepointy** są w: alokacji (slow path), sprawdzeniach przepełnienia stosu na wejściu do funkcji i w nagłówkach pętli (`CheckStackOverflow` — „VM relies on these checks for OOB message delivery and GC scheduling”), przejściach Dart ↔ native.

**Jank w 120 FPS.** Budżet klatki to 8.3 ms. Jeśli Twoja pętla animacji (albo parser w `onData` socketu) alokuje 10 000 obiektów na klatkę, to:

1. new space (domyślnie kilka MB) zapełnia się co kilkadziesiąt klatek,
2. scavenge zatrzymuje wątek UI na 1–4 ms **w losowym momencie** klatki,
3. obiekty, które przeżyły 1–2 scavenge (bo trzymasz je w stanie), są *promowane* do old space, gdzie ich zwolnienie wymaga mark-sweep i fragmentuje sterty.

Pomiar z `benchmarks/soa`: jedna klatka aktualizacji 10 000 cząstek jako `list.map((p) => Particle(...)).toList()` kosztuje **311 µs** i 10 000 alokacji; ta sama praca w miejscu na `Float64List` — **21 µs**, zero alokacji. 14× różnicy *zanim* policzymy GC.

### 1.3 Zero-allocation i buffer pooling: płaskie struktury zamiast `List<MyObject>`

🐢 **Array of Structs** — idiomatycznie:

```dart
class Particle { double x, y, vx, vy; Particle(this.x, this.y, this.vx, this.vy); }
final particles = <Particle>[];                       // 10k obiektów po 48 B + lista wskaźników
void step(double dt) {
  for (final p in particles) { p.x += p.vx * dt; p.y += p.vy * dt; }   // dereferencja per obiekt, cache miss
}
```

🚀 **Struct of Arrays** — 4 bufory, zero wskaźników, pętla wektoryzowalna:

```dart
// benchmarks/lib/src/bench_soa.dart
final Float64List _x = Float64List(_count), _y = Float64List(_count);
final Float64List _vx = Float64List(_count), _vy = Float64List(_count);

void _stepSoA(double dt) {
  final x = _x, y = _y, vx = _vx, vy = _vy;   // (!) kopie do lokalnych — patrz pułapka 1.6
  for (var i = 0; i < _count; i++) {
    x[i] += vx[i] * dt;
    var ny = y[i] + vy[i] * dt;
    if (ny < 0) { ny = 0; vy[i] = -vy[i]; }
    y[i] = ny;
  }
}
```

🚀 **Flat struct ze stride** — jeden bufor, „pola” pod stałymi offsetami jak `struct` w C:

```dart
const _stride = 4;                                   // x, y, vx, vy
final Float64List _flat = Float64List(_count * _stride);
void _stepFlat(double dt) {
  final f = _flat;
  for (var i = 0; i < _count * _stride; i += _stride) {
    f[i] += f[i + 2] * dt;                           // x += vx*dt
    var ny = f[i + 1] + f[i + 3] * dt;
    if (ny < 0) { ny = 0; f[i + 3] = -f[i + 3]; }
    f[i + 1] = ny;
  }
}
```

| `soa/particles` (10k cząstek, 1 klatka) | AOT | JIT |
|---|---:|---:|
| `map().toList()` (10k alokacji/klatkę) | 311 µs | 210 µs |
| `List<Particle>` mutacja w miejscu (AoS) | 29 µs | 33 µs |
| 4× `Float64List` (SoA) | **21 µs** | **16 µs** |
| 1× `Float64List` ze stride | 29 µs | 21 µs |

SoA wygrywa ze stride, bo kompilator łatwiej hoistuje sprawdzenia zakresu dla indeksu `i` niż dla `i + k`.

Gdy potrzebujesz „rekordów” o mieszanych typach, użyj `ByteData` z jawnymi offsetami (jak FlatBuffers):

```dart
// rekord: int32 id | float64 score | uint8 flags  = 13 B -> wyrównaj do 16
const _rec = 16;
final ByteData _db = ByteData(_n * _rec);
int id(int i) => _db.getInt32(i * _rec, Endian.little);
double score(int i) => _db.getFloat64(i * _rec + 4, Endian.little);
void setScore(int i, double v) => _db.setFloat64(i * _rec + 4, v, Endian.little);
```

Płaskie bufory nie muszą oznaczać brzydkiego API. `extension type` (Dart 3.3+) daje „obiekt” będący w czasie wykonania zwykłym `int`-em indeksu — zero alokacji, pełna czytelność:

```dart
extension type const Particle._(int i) {
  Particle(this.i);
  double get x => _x[i];       set x(double v) => _x[i] = v;
  double get vx => _vx[i];     set vx(double v) => _vx[i] = v;
  void step(double dt) => x += vx * dt;           // kompiluje się do: _x[i] += _vx[i] * dt
}
for (var i = 0; i < _count; i++) { Particle(i).step(dt); }   // Particle(i) to tylko int, nic nie trafia na stertę
```

Gdy obiektów nie da się spłaszczyć (np. muszą trafić do API Fluttera), **pula obiektów** zamienia 10k alokacji/klatkę na zero:

```dart
// 🐢 — nowy obiekt per zdarzenie
void onPointer(double x, double y) => _events.add(TouchEvent(x, y));

// 🚀 — pula: obiekty tworzone raz, reset() zamiast new
class TouchEvent { double x = 0, y = 0; }
final _pool = List.generate(256, (_) => TouchEvent(), growable: false);
var _used = 0;
TouchEvent acquire() => _pool[_used++];              // rzuć/rozszerz, gdy _used == length
void endFrame() => _used = 0;                         // wszystkie obiekty z klatki „zwolnione” jednym przypisaniem
```

Pula działa tak samo dla `Paint`, `Path` (`path.reset()`), `TextPainter`, buforów `Uint8List` (`Worker.pool` w zwycięskim Ruście to ta sama idea: max 256 buforów ≤ 16 KB, zwracanych po wysyłce).

Zawsze podawaj **stałe** `Endian.little` — z `flat_buffers.dart`: wszystkie akcesory (`_getUint32`, `_getInt64`…) mają `@pragma('vm:prefer-inline')` i literalny `Endian.little`, dzięki czemu VM składa to do jednej instrukcji load (`ByteData` bez endianness ma gałąź na host-endian).

### 1.4 Dlaczego `List<int>` jest wolne — i kiedy *nie* jest

Benchmark `typed_lists` (65 536 elementów):

| Operacja | `List<int>` | `Int32List` | `Uint8List` | `List<double>` | `Float64List` |
|---|---:|---:|---:|---:|---:|
| **sum, AOT** | 72 µs | 45 µs | **31 µs** | 84 µs | 84 µs |
| **sum, JIT** | 59 µs | 67 µs | 65 µs | 88 µs | 85 µs |
| **build 65k, AOT** | 3 460 µs (`add`) / 900 µs (`filled`) | **402 µs** | — | 6 050 µs (`add`, boxing) | **718 µs** |

Trzy lekcje:

1. **Największy zysk jest w budowaniu/alokacji, nie w czytaniu.** `List<double>.add` × 65k = 65k obiektów `Double` + realokacje tablicy: 6 ms. `Float64List(n)` + zapis: 0.7 ms (8.4×). To jest ta różnica, która robi jank.
2. **Sekwencyjny odczyt Smi z `List<int>` w JIT jest tak samo szybki jak z typed list** — JIT spekuluje „to zawsze Smi” i generuje `add` bez boxingu. W AOT (= Flutter release) nie ma spekulacji, więc `List<int>` jest 1.6–2.3× wolniejsze. **Mierz w AOT.**
3. **Odczyt `List<double>` ≈ `Float64List`** — bo dereferencja boxowanego double to jeden load, a 65k × 16 B wciąż mieści się w L2. Przewaga typed data wraca, gdy dane nie mieszczą się w cache (4× mniej pamięci dla `Float32List`, 8–16× dla `Uint8List`) lub gdy zapisujesz.

### 1.5 JSON: `JsonUtf8Encoder` i fuzja dekoderów

🐢 `jsonEncode(map)` → `String` (UTF-16, 2 B/znak) → `utf8.encode` → `Uint8List`. Dwie pełne kopie plus tysiące pośrednich `String` z kluczy i wartości.

🚀 `JsonUtf8Encoder` z `dart:convert` pisze **bezpośrednio bajty UTF-8** do rosnącego bufora (`_JsonUtf8Stringifier` w SDK), omijając obiekt `String`. TechEmpower (`dart3/dart_native/bin/server.dart`):

```dart
final _jsonEncoder = JsonUtf8Encoder();                 // jedna instancja na izolat
void _sendJson(HttpRequest request, Object response) => _sendResponse(
  request, HttpStatus.ok,
  type: ContentType.json,
  bytes: _jsonEncoder.convert(response),                // List<int> (Uint8List)
);
void _sendResponse(HttpRequest request, int statusCode, {ContentType? type, List<int> bytes = const []}) =>
  request.response
    ..statusCode = statusCode
    ..headers.contentType = type
    ..contentLength = bytes.length                      // jawny Content-Length = bez chunked encoding
    ..add(bytes)                                        // add(bytes), NIE write(string)
    ..close();
```

🚀🚀 **Ręczny writer bajtowy** — gdy znasz schemat (odpowiedź API, protokół), pisz pola prosto do reużywanego `Uint8List` (wzorzec z `dart-rawsocket-C-Hatton` i zwycięskiego Rusta):

```dart
// benchmarks/lib/src/bench_json.dart — klasa ByteWriter
void jsonString(Uint8List s) {              // s = surowe bajty UTF-8 (np. z SQLite przez CAST AS BLOB)
  _grow(s.length * 6 + 2);
  final b = _buf; var n = _len;
  b[n++] = 0x22;
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (c >= 0x20 && c != 0x22 && c != 0x5c) { b[n++] = c; }          // 99 % bajtów: 1 load, 1 store
    else if (c == 0x22 || c == 0x5c) { b[n++] = 0x5c; b[n++] = c; }
    else { /* \u00XX */ }
  }
  b[n++] = 0x22;
  _len = n;
}
```

| `json/encode feed` (20 postów, 2.6 KB) | AOT | JIT |
|---|---:|---:|
| `jsonEncode(map)` + `utf8.encode` | 60.2 µs | 53.7 µs |
| `JsonUtf8Encoder().convert(map)` | 38.0 µs (1.6×) | 39.2 µs |
| `ByteWriter` do reużywanego `Uint8List` | **6.5 µs (9.3×)** | 8.2 µs |

Dekodowanie — `utf8.decoder.fuse(json.decoder)` buduje jeden konwerter, który dekoduje UTF-8 **strumieniowo** do parsera JSON (SDK ma dla tej fuzji specjalną ścieżkę `_JsonUtf8Decoder` parsującą bezpośrednio bajty, bez tworzenia `String` całego dokumentu):

```dart
final _fused = utf8.decoder.fuse(json.decoder);          // raz, na poziomie biblioteki
Object? decode(Uint8List bytes) => _fused.convert(bytes); // 26 µs vs 32 µs dla jsonDecode(utf8.decode()) (AOT)
```

Zysk 20 % jest skromny, bo i tak powstaje drzewo `Map`/`List`/`String`. Prawdziwy zysk daje **nie budowanie drzewa**: parser strumieniowy, który czyta tylko potrzebne pola (odpowiednik `BodySeed` z Rusta), albo format binarny (FlatBuffers, §4).

### 1.6 Pułapka: leniwie inicjalizowane pola globalne

```dart
final Float64List _f64 = Float64List.fromList(...);   // top-level `final` z inicjalizatorem = LENIWY getter

double sumBad() {
  var s = 0.0;
  for (var i = 0; i < _f64.length; i++) { s += _f64[i]; }   // 2x getter z "czy zainicjalizowane?" per iteracja
  return s;
}
double sumGood(Float64List l) { /* ta sama pętla na parametrze */ }
```

| `typed_lists/sum double` | AOT |
|---|---:|
| `Float64List` przez top-level `final` w pętli | 194 µs |
| `Float64List` przekazana jako parametr/lokalna | **84 µs (2.3×)** |

Dotyczy `static final`, top-level `final`/`var` z nietrywialnym inicjalizatorem oraz `late final`. Zasada: **przed gorącą pętlą skopiuj referencję do lokalnej zmiennej**. ObjectBox i Isar robią to konsekwentnie (`final pointers = _store.readPointers();` przed użyciem).

### 1.7 Kolekcje, stringi, bufory — przykłady (AOT)

Najpierw tabela, potem każdy wiersz jako para kodu.

| Przypadek | 🐢 | 🚀 | Zysk |
|---|---|---|---:|
| filter+map 10k | `where().map().toList()` 183 µs | 2 pętle + `Int32List(count)` 40 µs | 4.6× |
| suma 10k | `fold()` 34 µs | pętla `for` 22 µs | 1.5× |
| histogram 10k wartości 0..999 | `Map<int,int>` 271 µs | `Int32List(1000)[v]++` 25 µs | 10.8× |
| 200 linii tekstu | `s += '...'` 106 µs | `StringBuffer` 30 µs / bajty do `Uint8List` 10 µs | 3.6× / 10.5× |
| składanie 16 fragmentów po 512 B (`onData`) | `List<int>.addAll` 193 µs; `Uint8List` nowa kopia per fragment 11.7 µs | `BytesBuilder(copy: false)` 1.9 µs; prealokowany bufor + `sublistView` 0.47 µs | 100× / 410× |
| parsowanie żądania HTTP | `utf8.decode` + `split` + `Map` 3.7 µs | skan bajtowy, offsety 0.93 µs | 4× |

#### 1.7.1 Łańcuchy `Iterable` → pętla

```dart
// 🐢 — 2 leniwe Iterable, 2 iteratory, 2 closure'y, growable lista z realokacjami
final r = data.where((v) => v.isEven).map((v) => v * 2).toList();

// 🚀 — policz, zaalokuj raz, wypełnij
var c = 0;
for (var i = 0; i < data.length; i++) { if (data[i].isEven) c++; }
final r = Int32List(c);
var j = 0;
for (var i = 0; i < data.length; i++) { final v = data[i]; if (v.isEven) r[j++] = v * 2; }
```

Pułapka leniwości: `final evens = data.where(...)` **nie** wykonuje pracy — każde `evens.length`, `evens.first`, `for (… in evens)` wykonuje filtr od nowa. Jeśli używasz wyniku więcej niż raz, zmaterializuj go (`toList(growable: false)`) albo napisz pętlę.

```dart
// 🐢 — filtr liczony 3 razy
final big = items.where((i) => i.size > 1000);
if (big.isNotEmpty) print('${big.length} items, first ${big.first}');
// 🚀
final big = items.where((i) => i.size > 1000).toList(growable: false);
```

#### 1.7.2 `fold`/`reduce` → pętla; `forEach` → `for`

```dart
// 🐢  final sum = data.fold<int>(0, (a, b) => a + b);     // closure call per element (AOT nie zawsze inline'uje)
// 🚀  var sum = 0; for (var i = 0; i < data.length; i++) { sum += data[i]; }
// 🐢  list.forEach((e) => process(e));                   // closure + brak break/continue
// 🚀  for (final e in list) { process(e); }
```

#### 1.7.3 Mapy i zbiory → tablice, gdy klucz jest małą liczbą

```dart
// 🐢  final hist = <int, int>{}; for (final v in data) { hist[v] = (hist[v] ?? 0) + 1; }   // hash, boxing wartości, rehash
// 🚀  final hist = Int32List(1000); for (var i = 0; i < data.length; i++) { hist[data[i]]++; }

// 🐢  final allowed = {3, 7, 42, 100};  if (allowed.contains(code)) ...              // Set<int>: hash per sprawdzenie
// 🚀  final allowed = Uint8List(256)..[3] = 1..[7] = 1..[42] = 1..[100] = 1;  if (allowed[code] != 0) ...   // 1 load
// 🚀  (klucze duże/rzadkie) posortowany Int32List + wyszukiwanie binarne zamiast Set

// 🐢  switch (name) { case 'GET': ... case 'POST': ... }        // porównania Stringów
// 🚀  switch (methodCode) { case 0: ... case 1: ... }            // int ustalony raz przy parsowaniu (np. pierwszy bajt | długość)
```

`Map<String, T>` z kluczami znanymi w czasie kompilacji → `enum` + `List<T>` indeksowany `e.index` (zero hashowania).

#### 1.7.4 Stringi

```dart
// 🐢 — kwadratowe kopiowanie: każdy += tworzy nowy String z całą dotychczasową treścią
var s = ''; for (var i = 0; i < n; i++) { s += 'line $i\n'; }
// 🚀 — amortyzowane O(n)
final sb = StringBuffer(); for (var i = 0; i < n; i++) { sb..write('line ')..write(i)..write('\n'); }
// 🚀🚀 — gdy wynik idzie do socketu/pliku: bajty od razu, bez Stringa pośredniego
var k = 0; for (var i = 0; i < n; i++) { k = writeAscii(buf, k, 'line '); k = writeInt(buf, k, i); buf[k++] = 0x0a; }

// 🐢  final parts = line.split(',');  final a = parts[0]; final b = parts[1];   // N Stringów + lista
// 🚀  final comma = line.indexOf(','); final a = line.substring(0, comma); ...   // tylko potrzebne substringi
// 🚀🚀 pracuj na offsetach (start, end) do oryginału; substring tylko na końcu, jeśli w ogóle

// 🐢  if (header.toLowerCase() == 'content-length')               // alokuje nowy String
// 🚀  if (header.length == 14 && _ieq(header, 'content-length'))   // porównanie po (c | 0x20), zero alokacji

// 🐢  utf8.decode(bytes)                 // zawsze pełny dekoder
// 🚀  isAscii(bytes) ? String.fromCharCodes(bytes) : utf8.decode(bytes)   // FlatBuffers `asciiOptimization`, Isar `is_ascii`
```

`String.substring` w Dart VM **kopiuje** (nie ma sliced strings jak w V8). Parsery utrzymują `(start, end)` i dekodują leniwie.

#### 1.7.5 Składanie fragmentów ze strumienia bajtów

```dart
// 🐢 a) List<int> + addAll: boxing każdego bajtu do Smi w tablicy wskaźników
final acc = <int>[]; stream.listen(acc.addAll);
// 🐢 b) Uint8List + kopia przy każdym fragmencie (dart-rawsocket-C-Hatton): O(n²) dla dużych body
var buf = Uint8List(0);
void onData(Uint8List d) { final nb = Uint8List(buf.length + d.length); nb.setRange(0, buf.length, buf); nb.setRange(buf.length, nb.length, d); buf = nb; }
// 🚀 c) BytesBuilder(copy: false): trzyma listę fragmentów, jedna kopia w takeBytes()
final bb = BytesBuilder(copy: false); stream.listen(bb.add, onDone: () => handle(bb.takeBytes()));
// 🚀🚀 d) prealokowany bufor per połączenie + licznik; widok bez kopii; memmove resztki po sparsowaniu ramki
final buf = Uint8List(64 * 1024); var n = 0;
void onData(Uint8List d) {
  buf.setRange(n, n + d.length, d); n += d.length;
  final used = parse(Uint8List.sublistView(buf, 0, n));          // zwraca liczbę skonsumowanych bajtów
  if (used > 0) { buf.setRange(0, n - used, buf, used); n -= used; }   // przesuń ogon na początek (w miejscu)
}
```

#### 1.7.6 Parsowanie protokołu po bajtach (wyciąg z `_parseBytes`)

```dart
// 🐢
final text = utf8.decode(bytes);
final lines = text.split('\r\n');
final headers = <String, String>{};
for (final line in lines.skip(1)) { final i = line.indexOf(':'); if (i > 0) headers[line.substring(0, i).toLowerCase()] = line.substring(i + 1).trim(); }
final auth = headers['authorization'];

// 🚀 — bez Stringów: nazwa nagłówka rozpoznawana po długości + pierwszym bajcie + porównaniu case-insensitive
bool _ieq(Uint8List b, int s, String name) {
  for (var k = 0; k < name.length; k++) { if ((b[s + k] | 0x20) != name.codeUnitAt(k)) return false; }
  return true;
}
// ... w pętli po liniach, mając ls (start linii), c (pozycja ':'), vs/ve (wartość):
final nameLen = c - ls; final f = b[ls] | 0x20;
if (nameLen == 14 && f == 0x63 && _ieq(b, ls, 'content-length')) { contentLength = _parseIntBytes(b, vs, ve); }
else if (nameLen == 13 && f == 0x61 && _ieq(b, ls, 'authorization')) { authStart = vs; authEnd = ve; }   // tylko offsety
```

#### 1.7.7 Drobiazgi, które w pętli przestają być drobiazgami

```dart
// 🐢  RegExp(r'^\d+$').hasMatch(s)            // kompilacja regexa per wywołanie
// 🚀  static final _digits = RegExp(r'^\d+$'); // raz; albo pętla po codeUnitAt (jak _parseId w Dart submission)

// 🐢  DateTime.now().millisecondsSinceEpoch      // alokuje DateTime
// 🚀  final sw = Stopwatch()..start(); ... sw.elapsedMicroseconds   // brak alokacji; dla "czasu ściennego" cache'uj co klatkę/ms

// 🐢  log('value=$x for $user');               // interpolacja ZAWSZE się wykonuje, nawet gdy log wyłączony
// 🚀  if (log.isLoggable(Level.FINE)) log.fine('value=$x for $user');

// 🐢  final copy = [...list];  /  List.from(list)      // growable + ewentualne sprawdzanie typów
// 🚀  final copy = List.of(list, growable: false);     // jedna alokacja dokładnego rozmiaru; typed: Float64List.fromList / sublist

// 🐢  enum Op { add, sub }  final cost = {Op.add: 1, Op.sub: 2}[op]!;
// 🚀  const costs = [1, 2];  final cost = costs[op.index];

// 🐢  x.toString()  w gorącej pętli (int -> String -> bajty)
// 🚀  writeInt(buf, k, x)  — cyfry od końca prosto do Uint8List (zob. ByteWriter.integer)

// 🐢  final cb = () => handle(this, item);      // closure przechwytująca this i item, alokowana per iteracja
// 🚀  metoda instancji / funkcja top-level przekazana jako tear-off (ObjectBox: "Static callback to avoid over-capturing")
```

---

## 2. Ekstremalne `dart:ffi` — SQLite i kod natywny (na bazie `sqlite3.dart`)

### 2.1 Jak `sqlite3.dart` wiąże funkcje C: `@Native` zamiast `lookupFunction`

Od wersji 3 pakiet nie używa `DynamicLibrary.open`/`lookupFunction`; wszystkie 94 symbole to `@Native` externy generowane przez ffigen do `lib/src/ffi/libsqlite3.g.dart`, a biblioteka jest dostarczana jako *native asset* przez `hook/build.dart`:

```dart
// sqlite3/lib/src/ffi/libsqlite3.g.dart
@ffi.DefaultAsset('package:sqlite3/src/ffi/libsqlite3.g.dart')
library;

@ffi.Native<ffi.Int Function(ffi.Pointer<sqlite3_stmt>)>()
external int sqlite3_step(ffi.Pointer<sqlite3_stmt> pStmt);

@ffi.Native<ffi.Int64 Function(ffi.Pointer<sqlite3>)>(isLeaf: true)
external int sqlite3_last_insert_rowid(ffi.Pointer<sqlite3> db);
```

`@Native` ma dwie przewagi nad `lookupFunction`: adres jest rozwiązywany raz przy ładowaniu (bez `late final` i sprawdzenia inicjalizacji przy każdym wywołaniu) i kompilator AOT może wygenerować bezpośrednie `call` do trampoliny bez pośredniego obiektu funkcji.

### 2.2 `isLeaf: true` — kiedy i dlaczego

Wywołanie FFI „non-leaf” przełącza stan wątku (`kThreadInGenerated` → `kThreadInNative`): zapisuje stan, odblokowuje możliwość safepointu dla GC, a po powrocie sprawdza, czy GC nie czeka. Dla funkcji trwającej 5 ns to narzut 4–5×. `isLeaf: true` mówi VM: „funkcja nie woła z powrotem do Darta, nie blokuje, nie potrzebuje safepointu” — i przejście znika.

Benchmark `ffi/call add(a,b)`:

| Wariant | AOT | JIT |
|---|---:|---:|
| czysty Dart `a + b` | 2.4 ns | 5.4 ns |
| FFI non-leaf | 21.6 ns | 24.3 ns |
| FFI `isLeaf: true` | **5.4 ns (4×)** | **8.8 ns (2.8×)** |

Ale `sqlite3.dart` oznacza jako leaf **tylko 10 funkcji**. Powód w `tool/generate_bindings.dart`:

```dart
/// Note: Leaf functions must never call back into Dart.
///
/// Almost all SQLite functions could do that (e.g. due to an update hook, a
/// user-defined function, or a VFS). So we only enable this on a few trivial
/// functions to reduce their overhead.
const _leafFunctions = <String>{
  'sqlite3_last_insert_rowid', 'sqlite3_changes', 'sqlite3_get_autocommit',
  'sqlite3_update_hook', 'sqlite3_commit_hook', 'sqlite3_rollback_hook',
  'sqlite3_stmt_isexplain', 'sqlite3_stmt_readonly',
  'sqlite3_column_count', 'sqlite3_bind_parameter_count',
};
```

`sqlite3_step` **nie może** być leaf: może wywołać funkcję użytkownika zdefiniowaną w Darcie (`createFunction`), hook albo Dart-owy VFS — a wywołanie z powrotem do Darta z wątku „w stanie native” bez safepointu to crash. Isar v4 poszedł przeciwną drogą — jego rdzeń w Ruście *nigdy* nie woła Darta, więc `ffigen.yaml` oznacza jako leaf wszystkie `isar_read_*`, `isar_write_*`, `isar_filter_*` (58 funkcji) i to czyni „jedno wywołanie FFI per pole” tańszym niż parsowanie bajtów w Darcie.

**Reguła:** `isLeaf: true` gdy funkcja C (1) nie woła callbacków do Darta, (2) nie blokuje (brak I/O, mutexów, `sleep`), (3) jest krótka. Jeśli blokuje, zablokujesz GC dla *całej* grupy izolatów.

### 2.3 Pamięć natywna bez narzutu: `malloc`/`Arena`, `NativeFinalizer`, `asTypedList`

**Zero-copy z C do Darta.** `Pointer<Uint8>.asTypedList(n)` tworzy `Uint8List` będący **widokiem** na pamięć natywną (external typed data) — bez kopii:

| `ffi/read 4 KB z Pointer<Uint8>` | AOT |
|---|---:|
| `ptr[i]` w pętli do `List<int>` | 10 580 ns |
| `Uint8List.fromList(ptr.asTypedList(n))` (1 memcpy) | 710 ns |
| `ptr.asTypedList(n)` widok | **11.8 ns** |

ObjectBox (`entity_definition.dart`) czyta obiekty z bazy właśnie tak:

```dart
T objectFromData(Store store, Pointer<Uint8> data, int size) {
  // There has been a performance improvement in the past using memcpy for
  // small buffers, but this is not longer faster than asTypedList.
  final uInt8List = data.asTypedList(size);
  final byteData = ByteData.view(uInt8List.buffer, uInt8List.offsetInBytes, size);
  return objectFromFB(store, byteData);          // FlatBuffers czyta pola prosto z pamięci natywnej
}
```

Widok jest ważny tylko tak długo, jak pamięć pod nim. `sqlite3.dart` dla kolumny TEXT robi widok + `utf8.decode` (1 kopia do `String`), a dla BLOB **zawsze kopiuje**, bo SQLite unieważnia wskaźnik przy następnym `step`/`reset`:

```dart
// sqlite3/lib/src/ffi/bindings.dart
void sqlite3_column_blob_into(int index, Uint8List target, int offset, int length) {
  if (length == 0) return;
  final source = libsqlite3.sqlite3_column_blob(stmt, index);
  target.setRange(offset, offset + length, source.cast<Uint8>().asTypedList(length));  // widok -> jedna memcpy do TWOJEGO bufora
}
```

Gdy natywny bufor ma żyć dłużej i chcesz, by zwolnił go GC: `ptr.asTypedList(len, finalizer: malloc.nativeFree)` (tak robi `allocateBytesWithFinalizer` w `memory.dart`) albo `finalizer: sqlite3_free.cast()` (jak w `sqlite3changeset_invert`).

**`NativeFinalizer`** — zwolnienie zasobu natywnego, gdy obiekt Dart zostanie zebrany, bez żadnego kodu Darta w momencie zbierania:

```dart
// sqlite3/lib/src/ffi/bindings.dart
final statementFinalizer = NativeFinalizer(addresses.sqlite3_finalize.cast());

final class FfiStatement implements RawSqliteStatement, Finalizable {
  final Pointer<sqlite3_stmt> stmt;
  final Object _detachToken = Object();
  FfiStatement(this.stmt, {required bool borrowed}) {
    if (!borrowed) statementFinalizer.attach(this, stmt.cast(), detach: _detachToken);
  }
  void sqlite3_finalize() {
    libsqlite3.sqlite3_finalize(stmt);
    statementFinalizer.detach(_detachToken);     // jawne zamknięcie -> odczep, żeby nie zwolnić dwa razy
  }
}
```

`implements Finalizable` jest kluczowe: gwarantuje, że obiekt nie zostanie uznany za martwy *w trakcie* wywołania FFI na jego wskaźniku (kompilator trzyma go żywym do końca scope'u). ObjectBox robi to samo: `NativeFinalizer(C.addresses.txn_close.cast())` i zauważa, że finalizery natywne odpalają w kolejności *utworzenia obiektów `NativeFinalizer`*, więc tworzy finalizer transakcji przed finalizerem store'a.

**Alokacja natywna w hot path.** Benchmark `ffi/fill 256 B`:

| Wariant | AOT |
|---|---:|
| `malloc` + `free` per wywołanie | 235 ns |
| `Arena` (`using((arena) => arena<Uint8>(256)))` | 290 ns |
| reużywany bufor | **172 ns** |

`Arena` *nie* jest optymalizacją szybkości dla jednej alokacji — to narzędzie poprawności (zwolni wszystko także przy wyjątku) i wygody przy wielu tymczasowych alokacjach. Dla hot path rób jak Isar i ObjectBox: **out-pointery alokowane raz i reużywane**:

```dart
// isar/packages/isar/lib/src/isar_core.dart
static Pointer<Pointer<NativeType>> ptrPtr = malloc<Pointer<NativeType>>();
static Pointer<Uint32> countPtr = malloc<Uint32>();
static Pointer<Bool> boolPtr = malloc<Bool>();
// objectbox-dart/objectbox/lib/src/native/store.dart
class ReadPointers { final Pointer<Pointer<Uint8>> dataPtrPtr = malloc(); final Pointer<Size> sizePtr = malloc(); }
```

Jak `sqlite3.dart` przekazuje tekst do `sqlite3_bind_text`? Nie przez `SQLITE_TRANSIENT` (to kazałoby SQLite zrobić *drugą* kopię):

```dart
int sqlite3_bind_text(int index, String value) {
  final bytes = utf8.encode(value);              // 1. Uint8List na stercie Darta
  final ptr = allocateBytes(bytes);              // 2. malloc + memcpy
  return libsqlite3.sqlite3_bind_text(stmt, index, ptr.cast(), bytes.length,
      allocate.nativeFree);                      // 3. SQLite sam zwolni przez free() — zero dodatkowych kopii
}
```

Czyli bind `String` = 2 alokacje. Jeśli masz już bajty UTF-8 (z sieci, z pliku), bindujesz `Uint8List` jako BLOB i oszczędzasz `utf8.encode` — README pakietu: „Consider using a `Uint8List` when binding binary values for better performance”.

### 2.4 Odczyt bez alokacji: `RawPreparedStatement`

Ścieżka wysokopoziomowa (`lib/src/implementation/statement.dart::_selectResults`) alokuje per `select()`: `List<List<Object?>>`, per wiersz `List<Object?>`, per dostęp `ResultSet[i]` nowy `Row` **i** `List.unmodifiable` (kopia!), per kolumna TEXT `String`, per BLOB `Uint8List`. Od 3.5.0 jest `stmt.raw` — `extension type RawPreparedStatement`, które woła `sqlite3_*` bez pośredników:

```dart
// benchmarks/lib/src/bench_sqlite.dart
void _readRaw() {
  var s = 0;
  final raw = _selectAll.raw;                 // RawPreparedStatement — brak alokacji, to extension type
  while (raw.step()) {                        // sqlite3_step == SQLITE_ROW
    s += raw.columnInt64(0);                  // sqlite3_column_int64 -> Smi, bez boxingu
  }
  _selectAll.reset();
}
void _readTextAsBlobInto() {                  // SELECT ..., CAST(body AS BLOB) FROM t
  final raw = _selectBlob.raw;
  while (raw.step()) {
    n += raw.columnBlobInto(2, _blobScratch); // bajty prosto do reużywanego Uint8List(4096)
  }
}
```

| `sqlite/select 10k wierszy` | AOT |
|---|---:|
| `select()` → `ResultSet` | 4.16 ms |
| `selectCursor()` | 4.48 ms |
| `stmt.raw`: `step()` + `columnInt64()` | **0.89 ms (4.7×)** |
| 10k TEXT: `raw.columnText()` → `String` | 1.68 ms |
| 10k `CAST AS BLOB` + `columnBlobInto(bufor)` | 1.47 ms |

Dokumentacja ostrzega: „calling raw methods on finalized statements is an unchecked use-after-free” — raw to nóż bez osłony, do użycia w jednej, dobrze przetestowanej warstwie dostępu do danych.

### 2.5 Group Commit / batching zapisów

Każdy `COMMIT` w SQLite to pełny cykl: zapis ramek do WAL, aktualizacja indeksu WAL, przy `synchronous=FULL` `fsync`. 10 000 autocommitów = 10 000 takich cykli. Zasada z `twelve-dollar-server`: **jedna transakcja na paczkę żądań z jednej iteracji pętli zdarzeń**.

🐢

```dart
for (final p in posts) {
  db.execute('INSERT INTO posts (user_id, body) VALUES (?, ?)', [p.userId, p.body]);  // prepare + bind + COMMIT per wiersz
}
```

🚀

```dart
final insert = db.prepare('INSERT INTO posts (user_id, body) VALUES (?, ?)', persistent: true); // SQLITE_PREPARE_PERSISTENT
db.execute('BEGIN');
for (final p in posts) { insert.execute([p.userId, p.body]); }
db.execute('COMMIT');
```

| `sqlite/insert 10k` (WAL, `synchronous=NORMAL`) | AOT |
|---|---:|
| `execute(sql, args)` per wiersz, autocommit | 230 ms |
| prepared statement, autocommit per wiersz | 221 ms |
| prepared + paczki po 100 | 34.6 ms |
| prepared + paczki po 1000 | 19.6 ms |
| prepared + jedna transakcja | **17.2 ms (13×)** |

Prepared statement sam daje mało (SQL jest krótki) — to COMMIT jest kosztem. Paczki po 100 dają już 85 % zysku, więc w serwerze/aplikacji nie trzeba czekać na „wszystko”: wystarczy grupować to, co **już czeka**. Wzorzec „group commit per tick” w Darcie (odpowiednik `Worker::run` + `flush` z Rusta i `work()` z Axuma):

```dart
class WriteBatcher {
  final Database db;
  final _pending = <(void Function() apply, Completer<void> done)>[];
  bool _scheduled = false;
  WriteBatcher(this.db);

  Future<void> submit(void Function() apply) {
    final c = Completer<void>();
    _pending.add((apply, c));
    if (!_scheduled) {
      _scheduled = true;
      scheduleMicrotask(_flush);   // koniec BIEŻĄCEJ iteracji pętli zdarzeń: wszystko, co dotarło w tym ticku, trafi do jednej transakcji
    }
    return c.future;               // 201 wysyłasz dopiero po zakończeniu tego future = po COMMIT
  }

  void _flush() {
    _scheduled = false;
    final batch = List.of(_pending); _pending.clear();
    try {
      db.execute('BEGIN IMMEDIATE');
      for (final (apply, _) in batch) { apply(); }
      db.execute('COMMIT');
      for (final (_, done) in batch) { done.complete(); }
    } catch (e, st) {
      db.execute('ROLLBACK');
      for (final (_, done) in batch) { done.completeError(e, st); }   // cała paczka = 500, jak flush(false) w Ruście
    }
  }
}
```

`scheduleMicrotask` zamiast `Timer` = zero dodatkowej latencji, gdy jest jedno żądanie, i naturalne grupowanie, gdy w jednym `epoll_wait` przyszło 50 pakietów (Dart obsłuży 50 `onData` w jednej iteracji, a mikrotask wykona się po nich). Dla Isar v4 odpowiednikiem jest `putAll` (`isar_insert` raz → N × `serialize` + `isar_insert_save` → `isar_insert_finish`), dla ObjectBox `box.putMany` w jednej transakcji z reużywanym `BuilderWithCBuffer`.

### 2.6 Jak ObjectBox pisze FlatBuffers prosto do pamięci natywnej

`objectbox/lib/src/native/bindings/flatbuffers.dart` („touch this file with caution, it's a hotspot”) podmienia alokator Buildera FlatBuffers na `malloc`, więc zserializowany obiekt **już jest** w pamięci C, gdy wołamy `obx_box_put_object4`:

```dart
class Allocator extends fb.Allocator {
  Pointer<Uint8>? _ptr; int _capacity = 0;
  ByteData get _view => ByteData.view(_ptr!.asTypedList(_capacity).buffer);   // Dart pisze przez widok do malloc
  @override ByteData allocate(int size) { _capacity = size; _ptr = malloc<Uint8>(size); return _view; }
  @override ByteData resize(ByteData oldData, int newSize, int inUseBack, int inUseFront) {
    final newPtr = malloc<Uint8>(newSize);
    if (inUseBack != 0) memcpy(newPtr + (newSize - inUseBack), _ptr! + (_capacity - inUseBack), inUseBack);
    ...
  }
}
// box.dart: jeden builder na Box, reset per put, realokacja tylko gdy > 64 KiB
_builder.fbb.reset();
final id = _entity.objectToFB(object, _builder.fbb);
C.box_put_object4(_cBoxChecked, _builder.bufPtr, _builder.fbb.size(), mode);
_builder.resetIfLarge();
```

Lekcja ogólna: **bufor wyjściowy żyje tyle, co obiekt-właściciel (Box, Connection, Isolate), nie tyle, co jedno wywołanie**.

---

## 3. Izolaty i współbieżność bez kopiowania

### 3.1 Kiedy izolat jest wolniejszy niż praca na głównym wątku

`SendPort.send(obj)` serializuje graf obiektów (poza niezmiennymi i `vm:deeply-immutable`) i deserializuje po stronie odbiorcy — dla każdego obiektu alokacja + kopia. Do tego `Isolate.spawn` to ~100–350 µs (AOT/JIT) nawet dla pustej funkcji, a `Isolate.run` dokłada port i future.

Benchmark `isolates` (10 000 rekordów, jedno przesłanie do workera + mały ack):

| Payload | AOT | JIT |
|---|---:|---:|
| `List<Map<String,Object>>` 10k obiektów (deep copy) | 9.2 ms | 22.5 ms |
| `Uint8List` 120 KB (jedna memcpy) | **72 µs** | 140 µs |
| `TransferableTypedData` 120 KB | 124 µs | 316 µs |
| `Uint8List` 16 MB | 14.6 ms | 31.2 ms |
| `TransferableTypedData` 16 MB | **7.3 ms** | 13.4 ms |
| `Isolate.run(() => 1)` (sam spawn) | 343 µs | 358 µs |

Wnioski:

1. **Płaskie bajty zamiast obiektów: 128×.** Jeśli worker ma policzyć coś na 10k rekordów, wyślij `Float64List`/`ByteData`, nie `List<Model>`. Deserializacja 10k `Map` po stronie odbiorcy to 10k+ alokacji **na wątku UI**, gdy wynik wraca.
2. **Izolat opłaca się od ~1 ms pracy.** Spawn + 2 przesłania to ≥ 0.4 ms; parsowanie 5 KB JSON (30 µs) w izolacie to czysta strata. Flutter-owe `compute()` dla małych rzeczy *dodaje* jank.
3. **`TransferableTypedData` nie jest darmowe**: `fromList` kopiuje do bufora natywnego. Zysk pojawia się, gdy (a) bufor jest duży (16 MB: 2×), (b) odbiorca nie musi od razu materializować, (c) **GC odbiorcy nie widzi dużego obiektu** — a to przy 120 FPS ważniejsze od czystego czasu kopiowania.

### 3.2 Zero-copy przez `TransferableTypedData`

```dart
// nadawca
final bytes = buildFrame();                               // Uint8List, np. 8 MB zdekodowanego obrazu
port.send(TransferableTypedData.fromList([bytes]));       // kopia do bufora natywnego; `bytes` możesz nadal używać
// odbiorca
port.listen((msg) {
  final ttd = msg as TransferableTypedData;
  final data = ttd.materialize().asUint8List();           // O(1): przejęcie własności, zero kopii; ttd jest teraz puste
});
```

ObjectBox (`native/query/query.dart`, strumieniowanie wyników) robi dokładnie to: zbiera paczkę `Uint8List` i wysyła `TransferableTypedData.fromList(batch)` — zamiast listy obiektów per wiersz. Alternatywy O(1), których warto znać:

* **Obiekty niezmienne** (`String`, `int`, `double`, `bool`, `const` kolekcje, `Pointer`, klasy oznaczone `@pragma('vm:deeply-immutable')` — `final` klasa, pola `final` typów deeply-immutable) są **współdzielone, nie kopiowane** między izolatami tej samej grupy.
* **`Pointer<T>`** przesyłasz jako adres (`ptr.address`, int) — pamięć natywna jest wspólna dla całego procesu; to jest „shared memory” w Darcie. Odpowiedzialność za życie bufora po Twojej stronie.
* **`Isolate.run`** (Dart 2.19+) przenosi wynik bez kopii, jeśli izolat kończy się tuż po — VM „przeszczepia” obiekty do odbiorcy (dla dużych wyników to wygrana nad `compute`).

* **`Isolate.exit(port, message)`** — najtańszy sposób oddania dużego wyniku: izolat kończy się i *przekazuje* swoją stertę razem z obiektem (bez serializacji), więc nawet `List<Map>` wraca w O(1). To właśnie robi `Isolate.run` pod spodem.

```dart
// worker uruchomiony przez Isolate.spawn(_work, replyPort)
void _work(SendPort reply) {
  final result = parseEverything();           // dowolny graf obiektów, nawet 100 MB
  Isolate.exit(reply, result);                // zero kopii; izolat umiera, obiekty "przeprowadzają się" do odbiorcy
}
```

Długożyjący worker (gdy zadań jest wiele, a spawn per zadanie kosztowałby 0.1–0.35 ms każde) — wzór z `benchmarks/lib/src/bench_isolates.dart`:

```dart
late SendPort _worker;
late StreamIterator<Object?> _replies;

void _workerMain(SendPort reply) {
  final port = ReceivePort();
  reply.send(port.sendPort);                   // handshake: oddaj swój SendPort
  port.listen((msg) {
    if (msg is TransferableTypedData) { reply.send(process(msg.materialize().asUint8List())); }
    else if (msg == null) { port.close(); }   // sygnał zakończenia; brak otwartych portów = izolat kończy się sam
  });
}

Future<void> start() async {
  final inbox = ReceivePort();
  await Isolate.spawn(_workerMain, inbox.sendPort);
  _replies = StreamIterator(inbox);
  await _replies.moveNext();
  _worker = _replies.current as SendPort;
}

Future<Object?> submit(Uint8List payload) async {   // żądania w kolejności: jedno w locie na raz
  _worker.send(TransferableTypedData.fromList([payload]));
  await _replies.moveNext();
  return _replies.current;
}
```

Jeśli potrzebujesz wielu zadań w locie, dodaj do wiadomości `id` i trzymaj `Map<int, Completer>` — ale wtedy payload odpowiedzi też powinien być płaski (`Uint8List` z `id` w pierwszych 4 bajtach), inaczej wracasz do deep copy.

### 3.3 Architektura serwerowa: izolaty i grupy izolatów

TechEmpower `dart3/dart_aot/bin/server.dart` — jedyny tam niebanalny trik:

```dart
const _maxIsolatesfromEnvironment = int.fromEnvironment('MAX_ISOLATES');   // dart compile ... --define=MAX_ISOLATES=8
void main(List<String> arguments) async {
  ...
  if (!args.contains(_workerGroupTag)) {
    /// Each group serves as a container for multiple isolates,
    /// helping to bypass internal VM scaling bottlenecks.
    final workerGroups = Platform.numberOfProcessors ~/ maxIsolates - 1;
    for (var i = 0; i < workerGroups; i++) {
      await Isolate.spawnUri(Platform.script, [...args, _workerGroupTag], null);   // NOWA grupa izolatów = osobna sterta, osobny GC
    }
  }
  for (var i = 1; i < maxIsolates; i++) { await Isolate.spawn(_startServer, args); }   // ta sama grupa
  await _startServer(args);
}
Future<void> _startServer(List<String> args) async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, 8080, shared: true);  // jądro rozdziela accept() między izolaty
  server..defaultResponseHeaders.clear()..serverHeader = 'dart_native';
  ...
}
```

`Isolate.spawn` tworzy izolat **w tej samej grupie** — wspólna sterta, wspólne safepointy (GC jednego zatrzymuje wszystkie). `Isolate.spawnUri` startuje **nową grupę**. Na maszynach wielordzeniowych dzielenie izolatów na grupy po ~8 ogranicza „stop-the-world dla wszystkich”. Na 1 vCPU (jak w $12 challenge) najlepszy jest **jeden izolat**: Dart submission pisze „extra isolates only add context switches and memory”.

### 3.4 Kiedy w ogóle nie potrzebujesz izolatu

Dart jest jednowątkowy, ale jego pętla zdarzeń jest zbudowana na epoll — I/O **nigdy** nie blokuje. Izolat jest potrzebny tylko dla **CPU-bound** pracy > ~1 ms, która zepsułaby klatkę. Zanim go dodasz, sprawdź trzy tańsze opcje: (1) zrób pracę synchronicznie, ale bez alokacji (często z 5 ms robi się 0.3 ms), (2) podziel pracę na kroki po ≤ 2 ms i rozdziel między klatki (`SchedulerBinding.scheduleTask`/`Future.delayed(Duration.zero)`), (3) przenieś do kodu natywnego przez FFI `isLeaf` (wektoryzowany C/Rust jest 5–50× szybszy od Darta na pętlach numerycznych; w naszym benchmarku prosty `dot_f64` w C był 1.24× szybszy od Darta na `Float64List` — Dart nie wektoryzuje).

---

## 4. Flutter: Impeller, `RenderObject` i warstwa widgetów bez alokacji

> Tę sekcję piszę bez benchmarków w tym repo (brak Flutter SDK w kontenerze); opiera się na architekturze silnika i regułach, które weryfikuje DevTools (`Performance` → Frame chart, `Raster`/`UI` thread, `Track widget rebuilds`, `Track layouts`, `Track paints`).

### 4.1 Model klatki i trzy wątki

Jedna klatka = **UI thread** (Dart: `build` → `layout` → `paint` → `compositing` → `Scene`) + **Raster thread** (Impeller: Scene → komendy GPU) + GPU. Budżet 120 Hz: 8.3 ms *na każdym z nich osobno*. Jank UI = za dużo Darta (build/layout/alokacje/GC); jank Raster = za dużo shaderów/warstw/`saveLayer`/dużych tekstur.

Impeller (domyślny silnik od Flutter 3.16 iOS / 3.27 Android) prekompiluje shadery, więc znikają „shader compilation jank”, ale nie zmienia on kosztów po stronie Darta — GC i rebuildy nadal są Twoje.

### 4.2 Widgety: `const`, granice rebuildu, brak alokacji w `build`

🐢

```dart
Widget build(BuildContext context) {
  final items = widget.data.map((d) => ItemTile(d)).toList();     // nowa lista + N widgetów per build
  return ListView(children: items, padding: EdgeInsets.all(8));     // nowy EdgeInsets per build
}
```

🚀

```dart
Widget build(BuildContext context) => ListView.builder(            // buduje tylko widoczne
  padding: const EdgeInsets.all(8),                                // const = jeden obiekt na całe życie programu, w old space
  itemCount: widget.data.length,
  itemBuilder: (context, i) => ItemTile(widget.data[i]),           // ItemTile z const konstruktorem, gdzie się da
);
```

Zasady, które wynikają bezpośrednio z §1:

* **`const` widgety nie są rebuildowane** — framework porównuje `identical(oldWidget, newWidget)` i pomija poddrzewo. `const` to także brak alokacji i brak bariery zapisu („Constants are always old”).
* **`setState` jak najniżej.** Rebuild poddrzewa = alokacja wszystkich jego widgetów (obiekty krótkożyjące → scavenge). Wydziel `StatefulWidget` tak, by zmieniało się jak najmniej; dla stanu globalnego użyj `ValueListenableBuilder`/`ListenableBuilder` wokół najmniejszego fragmentu.
* **Nie alokuj w `build` tego, co możesz policzyć raz**: `TextStyle`, `BoxDecoration`, `EdgeInsets`, `Key`, closure'y bez przechwyceń (metody klasy zamiast lambd).
* **`RepaintBoundary`** izoluje warstwę: animacja wewnątrz nie przerysowuje rodzeństwa; statyczne, kosztowne rodzeństwo nie jest rasteryzowane co klatkę. Zbyt wiele granic = zbyt wiele warstw (koszt pamięci GPU), więc zakładaj je **wokół rzeczy, które animują się niezależnie** (DevTools: `Highlight repaints`).

### 4.3 `CustomPainter`/`RenderObject`: pętla rysowania w stylu zero-alloc

🐢

```dart
@override
void paint(Canvas canvas, Size size) {
  for (final p in particles) {
    canvas.drawCircle(Offset(p.x, p.y), 2, Paint()..color = Colors.white);   // Paint + Offset per cząstka per klatka
  }
}
@override
bool shouldRepaint(covariant CustomPainter old) => true;
```

🚀

```dart
class ParticlePainter extends CustomPainter {
  ParticlePainter(this.xy, this.repaint) : super(repaint: repaint);   // repaint: Listenable -> brak setState/rebuild
  final Float32List xy;                                                 // [x0,y0,x1,y1,...] — SoA z §1.3
  final Listenable repaint;
  static final _paint = Paint()..color = const Color(0xFFFFFFFF)..strokeWidth = 2..strokeCap = StrokeCap.round;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRawPoints(PointMode.points, xy, _paint);                 // JEDNO wywołanie, zero obiektów Offset
  }
  @override
  bool shouldRepaint(ParticlePainter old) => old.xy != xy;              // identyczność bufora
}
```

* `drawRawPoints`, `drawRawAtlas`, `drawVertices(Vertices.raw(...))` przyjmują `Float32List` — to jest API zaprojektowane pod SoA. Jedno wywołanie zamiast 10 000.
* `CustomPainter(repaint: animation)` — painter nasłuchuje `Listenable` i oznacza *tylko* `RenderCustomPaint` do przerysowania; nie ma `setState`, nie ma rebuildu widgetów.
* Dla pełnej kontroli: własny `LeafRenderObjectWidget` + `RenderBox` z `markNeedsPaint()` — layout liczony raz (`sizedByParent = true`, `computeDryLayout`), paint co klatkę, stan w typed data. To jest najniższa warstwa, w której wciąż jesteś w Darcie.

Kompletny `RenderBox` sterowany `Ticker`-em (bez `setState`, bez rebuildu, layout raz):

```dart
class ParticlesWidget extends LeafRenderObjectWidget {
  const ParticlesWidget(this.store, {super.key});
  final ParticleStore store;                                   // Float32List xy + Float32List v, aktualizowany w miejscu
  @override RenderObject createRenderObject(BuildContext context) => _RenderParticles(store);
  @override void updateRenderObject(BuildContext context, _RenderParticles r) => r.store = store;
}

class _RenderParticles extends RenderBox {
  // Produkcyjnie: przekaż `vsync` z SingleTickerProviderStateMixin, by respektować TickerMode (pauza poza ekranem).
  _RenderParticles(this._store) { _ticker = Ticker(_tick)..start(); }
  ParticleStore _store; late final Ticker _ticker; Duration _last = Duration.zero;
  static final _paint = Paint()..strokeWidth = 2..strokeCap = StrokeCap.round..color = const Color(0xFFFFFFFF);

  set store(ParticleStore s) { if (!identical(s, _store)) { _store = s; markNeedsPaint(); } }

  void _tick(Duration now) {
    final dt = (now - _last).inMicroseconds / 1e6; _last = now;
    _store.step(dt, size);                                     // czysta pętla po Float32List, zero alokacji
    markNeedsPaint();                                          // tylko paint; layout nietknięty
  }

  @override bool get sizedByParent => true;                    // layout: rozmiar od rodzica, liczony raz
  @override Size computeDryLayout(BoxConstraints c) => c.biggest;
  @override bool get isRepaintBoundary => true;                // własna warstwa: nie przerysowuje rodzeństwa
  @override void paint(PaintingContext ctx, Offset offset) {
    ctx.canvas..save()..translate(offset.dx, offset.dy)
      ..drawRawPoints(PointMode.points, _store.xy, _paint)     // 1 wywołanie dla N cząstek
      ..restore();
  }
  @override void detach() { _ticker.stop(); super.detach(); }
  @override void attach(PipelineOwner owner) { super.attach(owner); if (!_ticker.isActive) _ticker.start(); }
  @override void dispose() { _ticker.dispose(); super.dispose(); }
}
```

Sprite'y: `drawRawAtlas` rysuje tysiące fragmentów jednej tekstury jednym wywołaniem, a transformacje podajesz jako `Float32List` RSTransform (scos, ssin, tx, ty) — idealne pod SoA:

```dart
final rst = Float32List(n * 4);   // [scos, ssin, tx, ty] per sprite — aktualizowane w miejscu co klatkę
final rects = Float32List(n * 4); // [left, top, right, bottom] w atlasie — stałe
// w paint():
canvas.drawRawAtlas(atlasImage, rst, rects, null /* colors */, null /* blendMode */, null /* cullRect */, _paint);
// obrót + skala sprite'a i bez alokacji: rst[i*4] = s*cos(a); rst[i*4+1] = s*sin(a); rst[i*4+2] = x - ...; rst[i*4+3] = y - ...;
```

Tekst w `CustomPainter`: `TextPainter.layout()` jest kosztowny; trzymaj painter per napis i przelicz tylko przy zmianie treści lub szerokości:

```dart
// 🐢 — w paint(): TextPainter(text: TextSpan(text: label))..layout()..paint(canvas, p)   // per klatka
// 🚀
final _labels = <String, TextPainter>{};
TextPainter _label(String s) => _labels.putIfAbsent(s, () => TextPainter(text: TextSpan(text: s, style: _style), textDirection: TextDirection.ltr)..layout());
// w paint(): _label('FPS 120').paint(canvas, offset);           // layout policzony raz
```

### 4.4 Animacje: `Ticker` zamiast `setState` per klatka

🐢 `AnimationController` + `addListener(() => setState(() {}))` na szczycie ekranu: rebuild całego drzewa 120×/s.

🚀 `AnimatedBuilder`/`ListenableBuilder` z `child:` (poddrzewo przekazane raz, nie rebuildowane) albo `Transform`/`Opacity` sterowane przez `Animation<double>` bez rebuildu; najtaniej — `RenderObject` nasłuchujący `Ticker` i robiący `markNeedsPaint()`.

### 4.5 Listy, obrazy, tekst

* `ListView.builder`/`SliverList` z `itemExtent`/`prototypeItem` (layout bez mierzenia każdego dziecka); `addAutomaticKeepAlives: false`, `addRepaintBoundaries: false` gdy elementy są tanie (granica per element kosztuje więcej, niż daje).
* Obrazy: `cacheWidth`/`cacheHeight` (dekoduj do rozmiaru wyświetlania; 4000×3000 JPEG zdekodowany to 48 MB tekstury), `ImageCache` ma limit 100 MB — liczy się pamięć GPU, nie sterta Darta.
* Tekst: `TextPainter` layout jest drogi; cache'uj `TextPainter`/`Paragraph` dla stałych napisów w `CustomPainter`, `RichText` zamiast wielu `Text` w `Row`.
* `Opacity` widget = `saveLayer` (offscreen buffer) — użyj `Opacity` tylko na liściach albo `AnimatedOpacity`/`FadeTransition` na `RepaintBoundary`; dla pojedynczego obrazu `Image(opacity: ...)`, dla koloru `Color.withOpacity` w `Paint`.
* `ClipRRect`/`ClipPath` z `Clip.antiAlias` na animujących się elementach → `saveLayer`; preferuj `Clip.hardEdge` lub `DecoratedBox` z `borderRadius`.

### 4.6 Checklista profilowania Fluttera

1. **Zawsze `--profile`** na urządzeniu (debug ma asercje i JIT; release nie ma DevTools).
2. DevTools → Performance: włącz `Track widget rebuilds` → znajdź widgety z setkami rebuildów/s; `Track paints`/`Track layouts` → znajdź przerysowania poza `RepaintBoundary`.
3. Memory → `Allocation tracing`: zobacz, *które klasy* są alokowane w pętli klatki. Celem jest „płaska linia” sterty podczas animacji — zęby piły co kilkaset ms to scavenge.
4. Timeline → szukaj `GC` eventów na UI thread tuż przed długą klatką.
5. `flutter run --profile --trace-skia` (Raster) gdy UI thread jest czysty, a klatka i tak długa.
6. Wątpliwości rozstrzyga `dart compile exe --extra-gen-snapshot-options=--print-flow-graph-optimized,--disassemble` (albo `flutter build apk --extra-gen-snapshot-options=...`): zobaczysz, czy `double` jest unboxed, czy jest `CheckSmi`, czy bariera zapisu została usunięta (`NoStoreBarrier`).

---

## 5. Produkcyjny Dart/Flutter: 80 % zysku przy 20 % wysiłku

### 5.1 Pięć wzorców do wdrożenia od ręki

| # | Wzorzec | Gdzie | Zysk (AOT, nasze benchmarki) |
|---|---|---|---:|
| 1 | **Typed data zamiast `List<num>` dla danych liczbowych; prealokacja zamiast `add()`** | modele wykresów, animacje, audio, bufory sieciowe, parsery | 5–11× na budowaniu, 2.3× na odczycie `Uint8List`, zero GC |
| 2 | **Bajty, nie Stringi, na granicy I/O**: `JsonUtf8Encoder`/`utf8.decoder.fuse(json.decoder)`, `response.add(bytes)`, `BytesBuilder(copy: false)`, `sublistView` | serwery (`dart:io`, shelf, relic), klienci HTTP, pliki, sockety | 1.6× (encoder), 100× (składanie fragmentów) |
| 3 | **Group commit**: jedna transakcja na tick (`scheduleMicrotask`), prepared statements `persistent: true`, `stmt.raw` + `columnBlobInto` w warstwie danych | SQLite (`sqlite3`, drift), Isar `putAll`, ObjectBox `putMany` | 13× na zapisach, 4.7× na odczytach |
| 4 | **FFI: `@Native(isLeaf: true)` dla czystych funkcji, `asTypedList` zamiast `ptr[i]`, out-pointery alokowane raz, `NativeFinalizer` + `Finalizable`** | każdy plugin natywny, własny kod C/Rust | 4× per wywołanie, 900× na odczycie bufora |
| 5 | **Izolaty tylko dla > 1 ms CPU, z płaskimi payloadami (`Uint8List`/`TransferableTypedData`)** | parsowanie dużych plików, kompresja, obróbka obrazu | 128× na transferze vs lista map |

Plus jedna zasada przekrojowa: **kopiuj top-level/`static final` do lokalnej zmiennej przed pętlą** (2.3×, §1.6) i mierz w AOT.

### 5.2 Zestawienie „typowy Dart” vs „styl 12-Dollar-Server”

**Model danych w pętli klatki**

```dart
// 🐢
List<Offset> points = frames.map((f) => Offset(f.x, f.y)).toList();
// 🚀
final Float32List points = Float32List(frames * 2);   // raz; aktualizuj w miejscu; canvas.drawRawPoints(...)
```

**Odpowiedź HTTP (dart:io)**

```dart
// 🐢
response.write(jsonEncode({'posts': posts.map((p) => p.toJson()).toList()}));
// 🚀 (TechEmpower dart3)
response..contentLength = bytes.length..add(_jsonEncoder.convert(payload));
// 🚀🚀 (12-dollar Dart): precomputed error bodies + ByteWriter dla sukcesów
final _notFound = _response(404, '{"error":"not found"}');  // final top-level, zbudowane raz
```

**Odczyt z SQLite do JSON**

```dart
// 🐢
for (final row in db.select('SELECT id, body FROM posts')) { out.add({'id': row['id'], 'body': row['body']}); }
return jsonEncode(out);
// 🚀 (dart-rawsocket-C-Hatton)
final rows = stFeed.select();          // stFeed: prepared, persistent, SELECT ... CAST(p.body AS BLOB) ...
for (final r in rows) { o.ascii('{"id":'); o.integer(r.columnAt(0) as int); o.ascii(',"body":'); o.str(r.columnAt(1) as Uint8List); ... }
// 🚀🚀 (sqlite3 >= 3.7)
final raw = stFeed.raw;
while (raw.step()) { w.integer(raw.columnInt64(0)); final n = raw.columnBlobInto(1, scratch); w.jsonString(scratch, 0, n); }
```

**Zapis 10k rekordów**

```dart
// 🐢
for (final r in records) { await isar.writeTxn(() => isar.items.put(r)); }   // / db.execute(...) per rekord
// 🚀
await isar.writeTxn(() => isar.items.putAll(records));                      // / BEGIN; prepared.execute() × N; COMMIT
```

**Wywołanie natywne**

```dart
// 🐢
final add = lib.lookupFunction<Int64 Function(Int64, Int64), int Function(int, int)>('add_i64');
// 🚀
@Native<Int64 Function(Int64, Int64)>(isLeaf: true, symbol: 'add_i64') external int addI64(int a, int b);
```

**Praca w tle**

```dart
// 🐢
final models = await compute(parseJsonToModels, jsonString);   // String kopiowany tam, List<Model> kopiowana z powrotem
// 🚀
final ttd = await Isolate.run(() => TransferableTypedData.fromList([parseToColumnarBytes(bytes)]));
final table = ColumnarTable(ttd.materialize());               // widoki Float64List/Int32List na jednym buforze
```

**Stan listy w Flutterze (10k wierszy, filtr przy każdym naciśnięciu klawisza)**

```dart
// 🐢 — nowa lista + nowe widgety + rebuild całego ekranu przy każdym znaku
setState(() => visible = all.where((p) => p.name.contains(query)).toList());

// 🚀 — indeksy w Int32List, rebuild tylko listy przez ValueNotifier, widgety z const konstruktorami
final visibleIdx = ValueNotifier<Int32List>(Int32List(0));
void filter(String q) {
  var c = 0; for (var i = 0; i < all.length; i++) { if (all[i].name.contains(q)) c++; }
  final idx = Int32List(c); var j = 0;
  for (var i = 0; i < all.length; i++) { if (all[i].name.contains(q)) idx[j++] = i; }
  visibleIdx.value = idx;                                      // tylko ValueListenableBuilder wokół ListView.builder się odbuduje
}
```

**Strumień zdarzeń (sensory, websocket) → wykres**

```dart
// 🐢
stream.map((e) => Sample(e.t, e.v)).listen((s) => setState(() => samples.add(s)));   // obiekt per próbka, rebuild per próbka, lista rośnie bez końca
// 🚀 — bufor cykliczny w Float64List, repaint przez Listenable, bez rebuildu
class FrameTick extends ChangeNotifier { void fire() => notifyListeners(); }
final ring = Float64List(4096); var head = 0; final tick = FrameTick();
stream.listen((e) { ring[head] = e.v; head = (head + 1) & 4095; });
Ticker((_) => tick.fire()).start();                            // 1 repaint per klatka, niezależnie od liczby próbek
// CustomPainter(repaint: tick) rysuje `ring` przez drawRawPoints / Path budowany raz na klatkę
```

**Serializacja do pliku/cache (np. zapis 50k rekordów)**

```dart
// 🐢
await File(p).writeAsString(jsonEncode(records.map((r) => r.toJson()).toList()));    // 50k Map + jeden String 10 MB + utf8
// 🚀 — format binarny ze stałym rekordem: ByteData, jeden zapis, odczyt widokami bez parsowania
final bd = ByteData(records.length * 16);
for (var i = 0; i < records.length; i++) { bd.setInt32(i * 16, records[i].id, Endian.little); bd.setFloat64(i * 16 + 4, records[i].score, Endian.little); }
await File(p).writeAsBytes(bd.buffer.asUint8List(), flush: true);
// odczyt: final bd = ByteData.sublistView(await File(p).readAsBytes()); id(i) => bd.getInt32(i*16, Endian.little);  — zero parsowania, zero obiektów
```

### 5.3 Jak mierzyć (repo `benchmarks/`)

```bash
cd benchmarks
dart pub get
tool/build_native.sh                      # libfastmath.so dla benchmarku FFI (gcc/clang)
dart run bin/run_all.dart --only json,ffi # JIT, wybrane grupy
tool/run.sh                               # JIT + AOT (dart build cli), wyniki w results/{jit,aot}.md
```

Harness (`lib/harness.dart`) robi rozgrzewkę 100 ms, dobiera liczbę iteracji na ~300 ms próby, bierze **medianę z 7 prób** i pokazuje min/max. `blackHole()` (`@pragma('vm:never-inline')`) chroni wynik przed usunięciem przez optymalizator. Czytaj kod maszynowy, gdy wynik zaskakuje — jak Egorov w „Microbenchmarks are experiments”: benchmark to eksperyment do interpretacji, nie wyrok.

### 5.4 Trzy zadania praktyczne (refactoring kata)

**Kata 1 — Parser bez alokacji (`benchmarks/lib/src/bench_buffers.dart`)**

`_parseIdiomatic` zwraca `ParsedString` z `Map<String,String>`; `_parseBytes` zwraca offsety (0.93 µs vs 3.7 µs). Zadanie: (a) dodaj obsługę wielu żądań w jednym buforze (pipelining) — pętla po `headerEnd + contentLength`, (b) zamień `ParsedBytes` na `Int32List(8)` (metoda/ścieżka/auth jako pary offsetów) i sprawdź, czy AOT usunął sprawdzenia zakresu (`--disassemble`), (c) dodaj wariant z `String.fromCharCodes` tylko dla `path` i zmierz, ile kosztuje *jeden* String. Cel: < 1 µs na żądanie z 8 nagłówkami, zero alokacji poza tym jednym Stringiem.

**Kata 2 — Group commit „per tick” nad `package:sqlite3` (`benchmarks/lib/src/bench_sqlite.dart`)**

Zaimplementuj `WriteBatcher` z §2.5 i napisz benchmark, który symuluje 1000 „żądań” nadchodzących jako 1000 wywołań `Future.microtask(() => batcher.submit(...))` w jednej iteracji pętli. Porównaj: (a) `await` każdego z osobna (autocommit), (b) batcher z `scheduleMicrotask`, (c) batcher z `Timer(Duration(milliseconds: 1))`. Zmierz czas całkowity i **latencję pierwszego żądania** w każdym wariancie. Potem zamień `insert.execute([a, b])` na `insert.raw..bindInt64(1, a)..bindBlob(2, bytes)..step()` i `reset()` — ile alokacji znika? (Sprawdź `dart run --observe` → Memory → Allocation tracing.)

**Kata 3 — Z `List<Particle>` do `drawRawPoints` (projekt Flutter)**

Weź `bench_soa.dart` jako model: stwórz `CustomPainter` rysujący 10 000 cząstek. Wersja A: `List<Particle>` + `canvas.drawCircle(Offset(...), r, paint)` w pętli, `setState` z `Ticker`. Wersja B: `Float32List xy` + `drawRawPoints`, `CustomPainter(repaint: ticker)` bez `setState`, `RepaintBoundary` wokół `CustomPaint`. W DevTools (`--profile`) porównaj: czas UI thread per klatka, liczbę rebuildów, wykres sterty (zęby GC). Cel: B poniżej 1 ms UI thread i płaska sterta przez 10 s animacji. Bonus: przenieś krok fizyki do C przez FFI `isLeaf` z `Float32List` jako `Pointer<Float>` (`asTypedList` na buforze z `malloc`, żeby ten sam bufor służył C i `drawRawPoints`).

---

## Dodatek — co dokładnie czytaliśmy

| Repozytorium / plik | Linie, fragmenty |
|---|---|
| `sqlite3.dart/sqlite3/lib/src/ffi/libsqlite3.g.dart` | `@Native` externy, `isLeaf: true` na 10 funkcjach, `addresses` dla finalizerów |
| `sqlite3.dart/sqlite3/lib/src/ffi/bindings.dart` | `databaseFinalizer`, `statementFinalizer`, `FfiStatement(... borrowed)`, `sqlite3_bind_text` z `allocate.nativeFree`, `sqlite3_column_blob_into` |
| `sqlite3.dart/sqlite3/lib/src/ffi/memory.dart` | `nullPtr<T>()` z `vm:prefer-inline` (obejście sdk#39488), `allocateBytes`, `allocateBytesWithFinalizer`, `readString` |
| `sqlite3.dart/sqlite3/lib/src/implementation/statement.dart` | `_selectResults`, `_readValue`, `_ActiveCursorIterator`, `hasNativeInts` |
| `sqlite3.dart/sqlite3/lib/src/statement.dart` | `extension type RawPreparedStatement`, `columnBlobInto` |
| `sqlite3.dart/sqlite3/tool/generate_bindings.dart` | `_leafFunctions` + komentarz „Leaf functions must never call back into Dart” |
| `FrameworkBenchmarks/frameworks/Dart/dart3/dart_aot/bin/server.dart` | `MAX_ISOLATES`, `Isolate.spawnUri` jako nowa grupa, `shared: true`, `_sendResponse` |
| `FrameworkBenchmarks/frameworks/Dart/{shelf,relic,dart_frog,angel3}` | routing switch zamiast `shelf_router`, `Body.fromData(bytes)`, anty-wzorce (`Response.json`, 100 izolatów × pool 20) |
| `flatbuffers/dart/lib/flat_buffers.dart` | `BufferContext`, `_getUint32(offset) => _buffer.getUint32(offset, Endian.little)`, `Reader.vTableGet`, 88× `vm:prefer-inline`, `_tryWriteASCIIString` |
| `objectbox-dart/objectbox/lib/src/native/bindings/flatbuffers.dart` | `BuilderWithCBuffer`, `Allocator` na `malloc`, `resetIfLarge` |
| `objectbox-dart/objectbox/lib/src/modelinfo/entity_definition.dart` | `objectFromData` (`asTypedList` → `ByteData.view`) |
| `objectbox-dart/objectbox/lib/src/native/bindings/helpers.dart`, `store.dart` | `ReadPointers`, `CursorHelper.get` |
| `isar/packages/isar/lib/src/isar_core.dart`, `native/bindings.dart`, `ffigen.yaml` | `ptrPtr/countPtr/boolPtr`, `readString` z flagą ASCII, 58× `isLeaf`, sentinel `_nullInt/_nullLong` |
| `dart-lang/sdk/runtime/docs/{README,gc,glossary,types,pragmas,compressed-pointers}.md` | Smi/Mint, nagłówek, wyrównanie new/old, TLAB, scavenger, bariera zapisu i jej eliminacja, safepointy, `vm:prefer-inline`, `vm:never-inline`, `vm:deeply-immutable`, `vm:unsafe:no-bounds-checks` |
| `twelve-dollar-server-challenge` PR #46 `dart-rawsocket-C-Hatton/bin/server.dart` | `_Conn.onData`, `_parseHead`, `_Out.str`, `_feed`, `_auth`, prekomputowane `_notFound`… |
