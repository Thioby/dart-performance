---
name: dart-isolates
description: Projektowanie współbieżności w Dart/Flutter - kiedy izolat się opłaca (a kiedy dodaje jank), koszt głębokich kopii SendPort, płaskie payloady (Uint8List/ByteData), TransferableTypedData, Isolate.run i Isolate.exit, obiekty niezmienne i vm:deeply-immutable, grupy izolatów (Isolate.spawn vs spawnUri), HttpServer shared:true, nadmiarowe przechwytywanie przez closure. Użyj, gdy pojawia się compute(), Isolate.spawn, "przenieś do tła", "wątek UI się blokuje", albo gdy komunikacja między izolatami jest wolna.
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu). Samowystarczalna: działa w dowolnym projekcie Dart/Flutter.

# dart-isolates — współbieżność bez kopiowania

Liczby referencyjne: Dart 3.13 AOT, x64. Zweryfikuj w swoim projekcie (skill `dart-benchmark`).

## 1. Decyzja: czy w ogóle potrzebujesz izolatu?

Izolat opłaca się, gdy **praca CPU > ~1 ms** blokuje klatkę/event loop. Koszty stałe:

| Operacja | AOT |
|---|---:|
| `Isolate.run(() => 1)` (spawn + port + wynik) | ~0.1–0.35 ms |
| `SendPort.send` 10k `Map` (głęboka kopia) | ~9 ms |
| `SendPort.send` `Uint8List` 120 KB | ~70 µs |
| `TransferableTypedData` 120 KB (`fromList` kopiuje + przeniesienie) | ~120 µs |
| `Uint8List` 16 MB | ~15 ms |
| `TransferableTypedData` 16 MB | ~7 ms |
| `Isolate.run` → `List<Model>` z 10k sparsowanych rekordów | ~104 ms — **wolniej niż parsowanie w głównym wątku (~94 ms)** |
| `Isolate.run` → `TransferableTypedData` (spakowana tabela kolumnowa) | ~31 ms |

Przed dodaniem izolatu sprawdź trzy tańsze opcje:
1. **Usuń alokacje** z wersji synchronicznej (skill `dart-zero-alloc`) — 5 ms często staje się 0.3 ms.
2. **Podziel pracę na kroki ≤ 2 ms** rozłożone na klatki (`SchedulerBinding.instance.scheduleTask`, `await Future.delayed(Duration.zero)` między kawałkami).
3. **FFI `isLeaf`** do C/Rusta (skill `dart-ffi-perf`) — pętle numeryczne są 5–50× szybsze niż w Darcie.

I/O **nigdy** nie potrzebuje izolatu — `dart:io` jest asynchroniczne na epoll/kqueue/IOCP.

## 2. Payload: płaskie bajty, nie grafy obiektów

`SendPort.send` serializuje graf (każdy obiekt: alokacja + kopia po stronie odbiorcy, w **jego** wątku — odebrane w izolacie UI to jank). Zasady:

```dart
// 🐢  port.send(models);                           // List<Model> -> tysiące alokacji u odbiorcy
// 🚀  port.send(columnarBytes);                    // Uint8List / Float64List: jeden memcpy
// 🚀🚀 port.send(TransferableTypedData.fromList([bytes]));   // odbiorca: materialize() O(1); GC odbiorcy nigdy nie widzi dużego obiektu
```

Zaprojektuj wynik workera jako **kolumny w jednym buforze** i czytaj je przez widoki — bez deserializacji do obiektów:

```dart
// pakowanie: nagłówek (liczności) + bajty kolumn, każda kolumna wyrównana do rozmiaru elementu
Uint8List pack(Int32List id, Float64List score) {
  final n = id.length; final out = ByteData(8 + n * 4 + ((n * 4 + 7) & ~7) - n * 4 + n * 8);
  out.setInt32(0, n, Endian.little);
  var off = 8;
  Uint8List.view(out.buffer, off, n * 4).setRange(0, n * 4, Uint8List.view(id.buffer, id.offsetInBytes, n * 4));
  off = (off + n * 4 + 7) & ~7;                                   // wyrównaj do 8 dla Float64List
  Uint8List.view(out.buffer, off, n * 8).setRange(0, n * 8, Uint8List.view(score.buffer, score.offsetInBytes, n * 8));
  return out.buffer.asUint8List();
}
// rozpakowanie u odbiorcy: Int32List.view(buf, 8, n), Float64List.view(buf, alignedOff, n) — widoki, zero kopii
```

### Co jest wysyłane bez kopiowania

- Niezmienne: `int`, `double`, `bool`, `String`, `null`, kolekcje `const`, `Pointer`, SIMD, *unmodifiable* typed data — współdzielone w obrębie grupy izolatów.
- Klasy oznaczone `@pragma('vm:deeply-immutable')` (klasa `final`/`sealed`, wszystkie pola `final` i głęboko niezmienne) — współdzielone.
- `TransferableTypedData` — własność bufora jest przenoszona; `fromList` **kopiuje** raz do bufora natywnego, sam transfer i `materialize()` są O(1).
- `Isolate.run` / `Isolate.exit(port, result)` — wynik jest "przeszczepiany" (bez kopii), bo izolat kończy się zaraz potem.
- `Pointer.address` (int) — pamięć natywna jest współdzielona przez proces; to pamięć współdzielona, ty zarządzasz jej czasem życia.

## 3. Wzorce

### Praca jednorazowa
```dart
final result = await Isolate.run(() {
  final bytes = decodeAndFlatten(input);              // input: Uint8List (kopiowany raz) albo String (współdzielony)
  return TransferableTypedData.fromList([bytes]);
});
final view = result.materialize().asFloat64List();
```

### Długo żyjący worker (unikaj spawnu per zadanie)
```dart
late SendPort _worker;
late StreamIterator<Object?> _replies;

void _workerMain(SendPort reply) {                     // funkcja top-level
  final port = ReceivePort();
  reply.send(port.sendPort);                           // handshake: oddaj swój SendPort
  port.listen((msg) {
    if (msg is TransferableTypedData) { reply.send(process(msg.materialize().asUint8List())); }
    else if (msg == null) { port.close(); }           // zamknięcie: brak otwartych portów = izolat kończy się sam
  });
}

Future<void> start() async {
  final inbox = ReceivePort();
  await Isolate.spawn(_workerMain, inbox.sendPort);
  _replies = StreamIterator(inbox);
  await _replies.moveNext();
  _worker = _replies.current as SendPort;
}

Future<Object?> submit(Uint8List payload) async {      // jedno żądanie w locie naraz, odpowiedzi po kolei
  _worker.send(TransferableTypedData.fromList([payload]));
  await _replies.moveNext();
  return _replies.current;
}
```
Kilka zadań w locie → dodaj `id` do wiadomości i trzymaj `Map<int, Completer>`; payloady odpowiedzi też trzymaj płaskie (`id` w pierwszych 4 bajtach `Uint8List`).

### Flutter `compute()`
`compute` = `Isolate.run` z kopią argumentu i wyniku. Dla JSON < ~50 KB jest **wolniejsze** niż parsowanie w wątku UI. Używaj go do dekodowania dużych plików/obrazów i zwracaj bajty, nie listy modeli — głęboka kopia 10k obiektów modelu przy odbiorze znów zatrzymuje UI, podczas gdy `TransferableTypedData` utrzymuje płynność. Alternatywnie uruchom *cały* pipeline w izolacie i zwróć tylko mały wynik końcowy (np. top 100 wierszy).

## 4. Nadmiarowe przechwytywanie przez closure (dart-lang/sdk#36983)

Lambda przekazana do `Isolate.run` **wewnątrz metody klasy** współdzieli kontekst z innymi closure'ami tej metody i może przechwycić `this`. Jeśli `this` to `State` z `AnimationController`, dostajesz "Illegal argument in isolate message: object is unsendable - TickerFuture". Poprawka: praca izolatu w **funkcjach top-level lub statycznych** z jawnymi argumentami (ObjectBox komentuje każdy taki callback "Static callback to avoid over-capturing"):

```dart
// 🐢  await Isolate.run(() => parse(bytes));                          // wewnątrz _MyState: może przechwycić `this`
// 🚀
Future<TransferableTypedData> parseInIsolate(Uint8List bytes) =>
    Isolate.run(() => TransferableTypedData.fromList([parseToColumns(bytes)]));
```

## 5. Grupy izolatów (serwery, maszyny wielordzeniowe)

- `Isolate.spawn` → ta sama **grupa izolatów**: współdzielony heap, współdzielony GC i safepointy (scavenge jednego izolatu zatrzymuje wszystkie), tańsze wiadomości.
- `Isolate.spawnUri(Platform.script, args, msg)` → **nowa grupa**: osobny heap i GC. Podział izolatów na grupy po ~8 ogranicza interferencję GC na maszynach wielordzeniowych.
- Serwer HTTP: `HttpServer.bind(addr, port, shared: true)` w każdym izolacie — kernel rozdziela `accept()`; bez izolatu-dyspozytora, bez `SendPort` per żądanie.
- Na 1 vCPU: **jeden izolat** (dodatkowe izolaty = przełączanie kontekstu i pamięć).

## 6. Pułapki

- `await for (final r in server)` + `await handle(r).timeout(...)` serializuje żądania w izolacie i alokuje `Future`+`Timer` per żądanie; użyj `server.listen` z synchronicznym handlerem.
- Wysyłanie closure'ów: przechwycone `this`/kontekst jest kopiowane (albo nie da się go wysłać w ogóle). Używaj funkcji statycznych / top-level.
- `ReceivePort` bez `close()` utrzymuje izolat przy życiu.
- `TransferableTypedData` jest puste po `materialize()`; nie używaj go dwa razy.
- Wyjątki w workerze: łap i odsyłaj jako dane (`(error, stack)`), inaczej izolat umiera po cichu — ustaw porty `onError`/`onExit`.

## 7. Checklista

- [ ] praca > 1 ms CPU? jeśli nie — zostaw w głównym wątku i usuń alokacje
- [ ] payload w obu kierunkach to typed data / niezmienne / `TransferableTypedData`, nie `List<Model>`
- [ ] długo żyjący worker zamiast spawnu per zadanie, gdy zadań jest wiele
- [ ] praca izolatu w funkcjach top-level/statycznych (bez przechwytywania `this`)
- [ ] serwer: `shared: true`, izolat per rdzeń, opcjonalnie grupy przez `spawnUri`
- [ ] obsłużone błędy i zamykanie portów

Lektura uzupełniająca z uruchamialnymi benchmarkami: https://github.com/Thioby/dart-performance
