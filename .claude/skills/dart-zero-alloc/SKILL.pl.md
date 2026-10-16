---
name: dart-zero-alloc
description: Refaktoryzacja kodu Dart do stylu zero-allocation - typed data (Uint8List/Float64List/ByteData) zamiast List<Object>, Struct-of-Arrays, extension types nad indeksami, pule obiektów i reużywalne bufory, zapis JSON/tekstu bezpośrednio jako bajty, parsowanie protokołów na poziomie bajtów bez Stringów, tabele kolumnowe dla dużych payloadów JSON. Użyj, gdy trzeba usunąć alokacje z pętli klatki, parsera, serializatora lub handlera socketu, albo gdy profil pokazuje częste scavenge/GC.
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu). Samowystarczalna: działa w dowolnym projekcie Dart/Flutter.

# dart-zero-alloc — przepisy na hot path bez alokacji

Cel: w hot path **zero** nowych obiektów na heapie Darta poza tym, co musi opuścić funkcję. Każdy przepis ma wariant 🐢 (idiomatyczny) i 🚀 (zero-alloc) z referencyjnym zyskiem (Dart 3.13, AOT, x64). Mierz w swoim projekcie przed i po (skill `dart-benchmark`).

## Zasady VM, które to uzasadniają

- Slot `List<T>` = tagowane słowo (8 B); `double` w kontekście generycznym = 16 B obiekt na heapie; `int` > 2^62 = Mint na heapie.
- `Float64List`/`Int32List`/`Uint8List` = surowe bajty, bez boxingu, bez write barrier (zapisujesz bajty, nie wskaźniki).
- Scavenge new space jest stop-the-world: koszt ∝ liczba *żywych* młodych obiektów + remembered set. 10k obiektów per klatka = jank.
- Top-level/`static final` z inicjalizatorem = leniwy getter; **skopiuj do zmiennej lokalnej przed pętlą** (~2.3×).

## Przepis 1: Struct-of-Arrays zamiast `List<Obj>` (~14×)

```dart
// 🐢
class P { double x, y, vx, vy; }
final ps = <P>[];
for (final p in ps) { p.x += p.vx * dt; }

// 🚀
final x = Float64List(n), vx = Float64List(n);   // pola jako osobne bufory
void step(Float64List x, Float64List vx, double dt) {
  for (var i = 0; i < x.length; i++) { x[i] += vx[i] * dt; }
}
```

Typy mieszane → `ByteData` z offsetami i stałym `Endian.little` (pozwala VM zwinąć gałąź kolejności bajtów):

```dart
const rec = 16;                                  // int32 id | f64 score | u8 flags | pad
final bd = ByteData(n * rec);
int id(int i) => bd.getInt32(i * rec, Endian.little);
double score(int i) => bd.getFloat64(i * rec + 4, Endian.little);
```

API "jak obiekt" bez obiektów — `extension type` nad indeksem (Dart 3.3+):

```dart
extension type const Particle(int i) {
  double get x => _x[i]; set x(double v) => _x[i] = v;
  void step(double dt) => x += _vx[i] * dt;      // kompiluje się do: _x[i] += _vx[i] * dt
}
```

Tabela kolumnowa dla rekordów z JSON/DB: typowane kolumny dla liczb i flag, stringi trzymane jako `(offset, length)` w oryginalnym buforze bajtów i dekodowane leniwie tylko dla wierszy, które pokazuje UI:

```dart
class Table {
  final Uint8List raw;                      // oryginalny payload — źródło do leniwego dekodowania stringów
  final Int32List id, nameOff, nameLen; final Float64List score; final Uint8List flags;
  int length = 0;
  String name(int i) => String.fromCharCodes(raw, nameOff[i], nameOff[i] + nameLen[i]); // szybka ścieżka ASCII; w przeciwnym razie utf8.decode
}
```

## Przepis 2: Prealokacja zamiast `add()` (5–11×)

```dart
// 🐢
final out = <double>[]; for (...) out.add(v);
// 🚀
final out = Float64List(count); var j = 0; for (...) out[j++] = v;
// nieznana liczba: dwa przebiegi (zlicz, wypełnij) — nadal szybciej niż growable z boxingiem
```

## Przepis 3: `where().map().toList()` → pętla (~4.6×)

```dart
// 🐢
final r = data.where((v) => v.isEven).map((v) => v * 2).toList();
// 🚀
var c = 0; for (var i = 0; i < data.length; i++) { if (data[i].isEven) c++; }
final r = Int32List(c); var j = 0;
for (var i = 0; i < data.length; i++) { final v = data[i]; if (v.isEven) r[j++] = v * 2; }
```

Pułapka leniwości: `final evens = data.where(...)` uruchamia filtr ponownie przy każdym `length`/`first`/iteracji — zmaterializuj raz (`toList(growable: false)`) albo napisz pętlę.

## Przepis 4: Histogram / lookup / top-N → tablice typowane (~10×)

```dart
// 🐢  final m = <int,int>{}; m[k] = (m[k] ?? 0) + 1;
// 🚀  final h = Int32List(range); h[k]++;
// top-N z dużego zbioru: min-heap rozmiaru N w Int32List indeksów zamiast sortowania wszystkiego
```

## Przepis 5: Reużywalny bufor wyjściowy (ByteWriter)

```dart
class ByteWriter {
  Uint8List _buf = Uint8List(1 << 16); int _len = 0;
  void reset() => _len = 0;
  void _grow(int extra) { if (_len + extra <= _buf.length) return;
    final nb = Uint8List((_len + extra) * 2); nb.setRange(0, _len, _buf); _buf = nb; }
  void byte(int c) { _grow(1); _buf[_len++] = c; }
  void ascii(String s) { _grow(s.length); for (var i = 0; i < s.length; i++) { _buf[_len++] = s.codeUnitAt(i); } }
  void integer(int v) {                                   // cyfry od końca, bez toString
    if (v == 0) { byte(0x30); return; }
    if (v < 0) { byte(0x2d); v = -v; }
    var digits = 0; for (var t = v; t > 0; t ~/= 10) { digits++; }
    _grow(digits); var p = _len + digits - 1;
    while (v > 0) { _buf[p--] = 0x30 + v % 10; v ~/= 10; }
    _len += digits;
  }
  void jsonString(Uint8List s) {                          // escapuj tylko " \ i < 0x20
    _grow(s.length * 6 + 2); final b = _buf; var n = _len; b[n++] = 0x22;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (c >= 0x20 && c != 0x22 && c != 0x5c) { b[n++] = c; }
      else if (c == 0x22 || c == 0x5c) { b[n++] = 0x5c; b[n++] = c; }
      else { const hex = '0123456789abcdef'; b[n++] = 0x5c; b[n++] = 0x75; b[n++] = 0x30; b[n++] = 0x30;
             b[n++] = hex.codeUnitAt(c >> 4); b[n++] = hex.codeUnitAt(c & 15); }
    }
    b[n++] = 0x22; _len = n;
  }
  Uint8List view() => Uint8List.sublistView(_buf, 0, _len);   // ważne do reset()
}
```

Jedna instancja per izolat/połączenie/painter. Wyślij `view()` do socketu / `canvas` / FFI; kopiuj tylko wtedy, gdy wynik musi przeżyć `reset()`. Referencja: odpowiedź JSON z 20 rekordami → ~6.5 µs vs ~60 µs dla `jsonEncode`+`utf8.encode` (~9×). Jeśli stringi przyszły jako JSON, są już zescapowane — kopiuj surowe bajty dosłownie.

## Przepis 6: JSON jako bajty bez własnego writera (~1.6×)

```dart
final _enc = JsonUtf8Encoder();                   // raz
final Uint8List bytes = _enc.convert(obj) as Uint8List;
final _dec = utf8.decoder.fuse(json.decoder);     // raz
final v = _dec.convert(bytes);
```

Znaj granicę: na payloadzie z 10k rekordów fused decoder daje ~30 %; resztę kosztuje drzewo i `fromJson`. Dla jednego wysokowolumenowego endpointu skaner bajtowy prosto do tabeli kolumnowej (przepis 1) daje ~7× end-to-end: rozpoznawaj klucze po długości + pierwszym bajcie, parsuj liczby/daty ręcznie, stringi trzymaj jako offsety, `skipValue()` dla nieznanych pól, waliduj względem `jsonDecode` testem różnicowym.

## Przepis 7: Składanie chunków ze strumienia (100–400×)

```dart
// 🐢  buf = Uint8List(buf.length + data.length)..setRange(...)   // kopia per chunk, O(n^2)
// 🚀 a) nieznany rozmiar:
final bb = BytesBuilder(copy: false); stream.listen(bb.add); final all = bb.takeBytes();
// 🚀 b) znana górna granica (protokół ramkowy): prealokowany bufor + offset
final buf = Uint8List(1 << 16); var n = 0;
void onData(Uint8List d) {
  buf.setRange(n, n + d.length, d); n += d.length;
  final used = parse(Uint8List.sublistView(buf, 0, n));            // skonsumowane bajty
  if (used > 0) { buf.setRange(0, n - used, buf, used); n -= used; }  // memmove ogona, w miejscu
}
```

## Przepis 8: Parser protokołu na poziomie bajtów (~4×)

Nie dekoduj do `String`. Porównuj nazwy nagłówków/kluczy po długości i pierwszym bajcie, a potem porównaniem bajtów bez rozróżniania wielkości liter przez `| 0x20`. Wynikiem są offsety w reużywanym obiekcie/`Int32List`, nie `Map<String,String>`.

```dart
bool _ieq(Uint8List b, int s, String name) {
  for (var k = 0; k < name.length; k++) { if ((b[s + k] | 0x20) != name.codeUnitAt(k)) return false; }
  return true;
}
if (nameLen == 14 && (b[ls] | 0x20) == 0x63 /* c */ && _ieq(b, ls, 'content-length')) { ... }
```

## Przepis 9: Stringi

- `s += x` w pętli → `StringBuffer` (~3.6×). Gdy wynik idzie do I/O → od razu bajty (~10×).
- `substring` kopiuje (Dart VM nie ma sliced strings) — trzymaj offsety w oryginale.
- ASCII z bajtów: `String.fromCharCodes(bytes, start, end)` bije `utf8.decode` dla czystego ASCII (najpierw sprawdź `(c & ~0x7F) == 0`).
- `toLowerCase()` do porównania alokuje — porównuj przez `| 0x20`.

## Przepis 10: Stałe i `const`

Wszystko stałe przez cały czas życia programu — `const` (zero alokacji, old space, bez write barrier). Odpowiedzi błędów, nagłówki, `EdgeInsets`, `TextStyle`, puste listy `const []`. Readery/konwertery jako obiekty `const`.

## Przepis 11: Pula obiektów, gdy obiektów nie da się spłaszczyć

```dart
class TouchEvent { double x = 0, y = 0; }
final _pool = List.generate(256, (_) => TouchEvent(), growable: false);
var _used = 0;
TouchEvent acquire() => _pool[_used++];              // powiększ/rzuć wyjątek, gdy _used == length
void endFrame() => _used = 0;                         // "zwolnij" wszystko jednym przypisaniem
```

Działa tak samo dla `Paint`, `Path` (`path.reset()`), `TextPainter`, buforów `Uint8List`.

## Weryfikacja

1. `dart run --observe` / `flutter run --profile` → DevTools → Memory → Allocation tracing: klasa, którą usunąłeś, powinna zniknąć z listy.
2. Mikrobenchmark przed/po, JIT **i** AOT (skill `dart-benchmark`).
3. Aby mieć pewność, że double jest unboxed / nie ma `CheckSmi`: `dart compile exe --extra-gen-snapshot-options=--print-flow-graph-optimized,--disassemble --extra-gen-snapshot-options=--print-flow-graph-filter=functionName`.

## Kiedy NIE stosować

Kod jednorazowy, kolekcje < ~100 elementów, warstwy UI poza pętlą klatki, testy. Zero-alloc kosztuje czytelność — ogranicz go do zmierzonych hot pathów i zamknij w jednej dobrze nazwanej klasie (`ByteWriter`, `FrameBuffer`, `ParticleStore`, `UserTable`).

Lektura uzupełniająca z uruchamialnymi benchmarkami: https://github.com/Thioby/dart-performance
