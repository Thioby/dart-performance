---
name: dart-zero-alloc
description: Refaktoryzacja kodu Dart do stylu zero-allocation - typed data (Uint8List/Float64List/ByteData) zamiast List<Object>, Struct-of-Arrays, pule i reużywalne bufory, ręczne pisanie JSON/tekstu jako bajtów, parsowanie protokołów po bajtach bez Stringów. Użyj, gdy trzeba usunąć alokacje z pętli klatki, parsera, serializatora lub obsługi socketu, albo gdy profil pokazuje częste scavenge/GC.
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu).

# dart-zero-alloc — przepisy na kod bez alokacji w hot path

Cel: w gorącej ścieżce **zero** nowych obiektów na stercie Darta poza tym, co musi wyjść na zewnątrz. Każdy przepis ma wariant 🐢 (idiomatyczny) i 🚀 (zero-alloc), zmierzony w `benchmarks/` (AOT, Dart 3.13). Teoria: `docs/dart-flutter-extreme-performance-guide.md` §1.

## Zasady VM, które to uzasadniają

- Slot `List<T>` = tagowane słowo (8 B); `double` w kontekście generycznym = obiekt 16 B na stercie; `int` > 2^62 = Mint na stercie.
- `Float64List`/`Int32List`/`Uint8List` = surowe bajty, bez boxingu, bez bariery zapisu (zapisujesz bajty, nie wskaźniki).
- Scavenge new space jest stop-the-world: koszt ∝ liczba *żywych* młodych obiektów + remembered set. 10k obiektów/klatkę = jank.
- Top-level/`static final` z inicjalizatorem = leniwy getter; **kopiuj do lokalnej przed pętlą**.

## Przepis 1: Struct-of-Arrays zamiast `List<Obj>` (14×)

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

Mieszane typy → `ByteData` z offsetami i stałym `Endian.little`:

```dart
const rec = 16;                                  // int32 id | f64 score | u8 flags | pad
final bd = ByteData(n * rec);
int id(int i) => bd.getInt32(i * rec, Endian.little);
double score(int i) => bd.getFloat64(i * rec + 4, Endian.little);
```

Gdy potrzebujesz API „obiektowego”, użyj `extension type` na indeksie (zero alokacji, czytelny kod):

```dart
extension type const Particle(int i) {
  double get x => _x[i]; set x(double v) => _x[i] = v;
}
```

## Przepis 2: Prealokacja zamiast `add()` (5–11×)

```dart
// 🐢
final out = <double>[]; for (...) out.add(v);
// 🚀
final out = Float64List(count); var j = 0; for (...) out[j++] = v;
// gdy count nieznany: dwa przebiegi (policz, wypełnij) — nadal szybsze niż growable z boxingiem
```

## Przepis 3: `where().map().toList()` → pętla (4.6×)

```dart
// 🐢
final r = data.where((v) => v.isEven).map((v) => v * 2).toList();
// 🚀
var c = 0; for (var i = 0; i < data.length; i++) { if (data[i].isEven) c++; }
final r = Int32List(c); var j = 0;
for (var i = 0; i < data.length; i++) { final v = data[i]; if (v.isEven) r[j++] = v * 2; }
```

## Przepis 4: Histogram / lookup → typed array (10.8×)

```dart
// 🐢  final m = <int,int>{}; m[k] = (m[k] ?? 0) + 1;
// 🚀  final h = Int32List(range); h[k]++;
```

## Przepis 5: Reużywalny bufor wyjściowy (ByteWriter)

```dart
class ByteWriter {
  Uint8List _buf = Uint8List(1 << 16); int _len = 0;
  void reset() => _len = 0;
  void _grow(int extra) { if (_len + extra <= _buf.length) return;
    final nb = Uint8List((_len + extra) * 2); nb.setRange(0, _len, _buf); _buf = nb; }
  void ascii(String s) { _grow(s.length); for (var i = 0; i < s.length; i++) _buf[_len++] = s.codeUnitAt(i); }
  void byte(int c) { _grow(1); _buf[_len++] = c; }
  void integer(int v) { /* cyfry od końca, bez toString — patrz benchmarks/lib/src/bench_json.dart */ }
  void jsonString(Uint8List utf8) { /* escapuj tylko " \ i < 0x20; reszta bajt po bajcie */ }
  Uint8List view() => Uint8List.sublistView(_buf, 0, _len);   // ważny do reset()
}
```

Jedna instancja per izolat/połączenie/painter. Wynik `view()` wysyłasz do socketu / `canvas` / FFI; kopiujesz (`Uint8List.fromList(view())`) tylko gdy musi przeżyć `reset()`. Benchmark: feed 20 postów → 6.5 µs vs 60 µs `jsonEncode`+`utf8.encode` (9.3×).

## Przepis 6: JSON bajtowo bez własnego writera (1.6×)

```dart
final _enc = JsonUtf8Encoder();                   // raz
final Uint8List bytes = _enc.convert(obj) as Uint8List;
final _dec = utf8.decoder.fuse(json.decoder);     // raz
final v = _dec.convert(bytes);
```

## Przepis 7: Składanie fragmentów ze strumienia (100–400×)

```dart
// 🐢  buf = Uint8List(buf.length + data.length)..setRange(...)   // kopia per fragment, O(n^2)
// 🚀 a) nieznany rozmiar:
final bb = BytesBuilder(copy: false); stream.listen(bb.add); final all = bb.takeBytes();
// 🚀 b) znany górny limit (protokół z ramkami): prealokowany bufor + offset
final buf = Uint8List(1 << 16); var n = 0;
void onData(Uint8List d) { buf.setRange(n, n + d.length, d); n += d.length; parse(Uint8List.sublistView(buf, 0, n)); }
```

Po sparsowaniu ramki przesuwaj resztę `buf.setRange(0, n - used, buf, used)` (memmove w miejscu) zamiast tworzyć nowy bufor.

## Przepis 8: Parser protokołu po bajtach (4×)

Nie dekoduj do `String`. Porównuj nagłówki po długości i pierwszym bajcie, potem `_ieq` (case-insensitive po `| 0x20`). Wynik to offsety w reużywanym obiekcie/`Int32List`, nie `Map<String,String>`. Wzór: `_parseBytes` w `benchmarks/lib/src/bench_buffers.dart` i `_parseHead` w `dart-rawsocket-C-Hatton/bin/server.dart`.

```dart
if (nameLen == 14 && (b[ls] | 0x20) == 0x63 /* c */ && _ieq(b, ls, 'content-length')) { ... }
```

## Przepis 9: Stringi

- `s += x` w pętli → `StringBuffer` (3.6×). Gdy wynik idzie do I/O → od razu bajty (10×).
- `substring` kopiuje (Dart VM nie ma sliced strings) — trzymaj offsety do oryginału.
- ASCII z bajtów: `String.fromCharCodes(bytes, start, end)` jest szybsze niż `utf8.decode` dla czystego ASCII (sprawdź `(c & ~0x7F) == 0` jak FlatBuffers `_tryWriteASCIIString`).

## Przepis 10: Stałe i `const`

Wszystko, co jest stałe w czasie życia programu — `const` (zero alokacji, old space, bez bariery zapisu). Odpowiedzi błędów, nagłówki, `EdgeInsets`, `TextStyle`, puste listy `const []`. Readery/konwertery jako `const` obiekty (FlatBuffers: „read speed up by about 10 % … `const` constructors of FB readers”).

## Weryfikacja

1. `dart run --observe` → DevTools → Memory → Allocation tracing: klasa, którą usuwałeś, powinna zniknąć z listy.
2. Benchmark z `benchmarks/lib/harness.dart` (`Suite`, `blackHole`) — przed/po, JIT **i** AOT (`tool/run.sh`).
3. Dla pewności, że double jest unboxed / nie ma `CheckSmi`: `dart compile exe --extra-gen-snapshot-options=--print-flow-graph-optimized,--disassemble --extra-gen-snapshot-options=--print-flow-graph-filter=nazwaFunkcji`.

## Kiedy NIE stosować

Kod jednorazowy, kolekcje < ~100 elementów, warstwa UI poza pętlą klatki, testy. Zero-alloc kosztuje czytelność — ogranicz do zmierzonych hot pathów i zamknij w jednej, dobrze nazwanej klasie (`ByteWriter`, `FrameBuffer`, `ParticleStore`).
