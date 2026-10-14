---
name: dart-isolates
description: Projektowanie współbieżności w Dart/Flutter - kiedy izolat się opłaca (a kiedy dodaje jank), koszt SendPort deep copy, płaskie payloady (Uint8List/ByteData), TransferableTypedData, Isolate.run, obiekty niezmienne i vm:deeply-immutable, grupy izolatów (Isolate.spawn vs spawnUri), HttpServer shared:true. Użyj, gdy pojawia się compute(), Isolate.spawn, "przenieś do tła", "wątek UI blokuje", albo gdy komunikacja między izolatami jest wolna.
---

# dart-isolates — współbieżność bez kopiowania

Liczby z `benchmarks/` (`--only isolates`, AOT, Dart 3.13). Teoria i kontekst serwerowy: `docs/dart-flutter-extreme-performance-guide.md` §3.

## 1. Decyzja: czy w ogóle potrzebujesz izolatu?

Izolat opłaca się, gdy **praca CPU > ~1 ms** i blokuje klatkę/pętlę zdarzeń. Koszty stałe:

| Operacja | AOT |
|---|---:|
| `Isolate.run(() => 1)` (spawn + port + wynik) | ~340 µs |
| `SendPort.send` 10k `Map` (deep copy) | 9.2 ms |
| `SendPort.send` `Uint8List` 120 KB | 72 µs |
| `TransferableTypedData` 120 KB (`fromList` kopiuje + move) | 124 µs |
| `Uint8List` 16 MB | 14.6 ms |
| `TransferableTypedData` 16 MB | 7.3 ms |

Zanim dodasz izolat, sprawdź trzy tańsze opcje:
1. **Usuń alokacje** z synchronicznej wersji (skill `dart-zero-alloc`) — 5 ms często staje się 0.3 ms.
2. **Podziel pracę na kroki ≤ 2 ms** i rozłóż między klatki (`SchedulerBinding.instance.scheduleTask`, `await Future.delayed(Duration.zero)` między porcjami).
3. **FFI `isLeaf`** do C/Rust (skill `dart-ffi-perf`) — pętle numeryczne 5–50× szybsze niż Dart.

I/O **nigdy** nie wymaga izolatu — `dart:io` jest asynchroniczne na epoll/kqueue/IOCP.

## 2. Payload: płaskie bajty, nie grafy obiektów

`SendPort.send` serializuje graf (każdy obiekt: alokacja + kopia po stronie odbiorcy, na **jego** wątku — przy odbiorze w izolacie UI to jank). Reguły:

```dart
// 🐢  port.send(models);                           // List<Model> -> 10k alokacji u odbiorcy
// 🚀  port.send(columnarBytes);                    // Uint8List / Float64List: jedna memcpy
// 🚀🚀 port.send(TransferableTypedData.fromList([bytes]));   // odbiorca: materialize() O(1), GC odbiorcy nie widzi dużego obiektu
```

Projektuj wynik workera jako **kolumny w jednym `ByteData`** (offsety, `Endian.little`) i czytaj widokami (`Float64List.view(buffer, off, n)`) — bez deserializacji do obiektów.

### Co jest przesyłane bez kopii

- Niezmienne: `int`, `double`, `bool`, `String`, `null`, `const` kolekcje, `Pointer`, SIMD, typed data *unmodifiable* — współdzielone w obrębie grupy izolatów.
- Klasy `@pragma('vm:deeply-immutable')` (`final`/`sealed` klasa, wszystkie pola `final` i deeply-immutable) — współdzielone.
- `TransferableTypedData` — własność bufora przenoszona; `fromList` **kopiuje** do bufora natywnego raz, sam transfer i `materialize()` są O(1).
- `Isolate.run` — wynik jest „przeszczepiany” (bez kopii), bo izolat kończy się od razu.
- `Pointer.address` (int) — pamięć natywna jest wspólna dla procesu; to jest shared memory, zarządzasz życiem sam.

## 3. Wzorce

### Jednorazowa praca
```dart
final result = await Isolate.run(() {
  final bytes = decodeAndFlatten(input);              // input: Uint8List (kopiowane raz) lub String (współdzielone)
  return TransferableTypedData.fromList([bytes]);
});
final view = result.materialize().asFloat64List();
```

### Długożyjący worker (unikaj spawn per zadanie)
```dart
// worker: ReceivePort + handshake SendPort; pętla listen(); odpowiada małym ack lub TransferableTypedData
// klient: trzyma SendPort; kolejkuje zadania; używa StreamIterator na ReceivePort dla odpowiedzi w kolejności
```
Wzór kompletny: `benchmarks/lib/src/bench_isolates.dart` (`_workerMain`, `setupIsolates`, `_roundTrip`).

### Flutter `compute()`
`compute` = `Isolate.run` z kopiowaniem argumentu i wyniku. Dla JSON < ~50 KB jest **wolniejsze** niż parsowanie na wątku UI. Użyj dla dekodowania dużych plików/obrazów i zwracaj bajty, nie listy modeli.

## 4. Grupy izolatów (serwery, wielordzeniowe maszyny)

- `Isolate.spawn` → ten sam **isolate group**: wspólna sterta, wspólny GC i safepointy (scavenge jednego zatrzymuje wszystkich), tańsze wiadomości.
- `Isolate.spawnUri(Platform.script, args, msg)` → **nowa grupa**: osobna sterta i GC. TechEmpower `dart3_aot` dzieli izolaty na grupy po `MAX_ISOLATES=8`, by „bypass internal VM scaling bottlenecks” na maszynach 28+ rdzeni.
- Serwer HTTP: `HttpServer.bind(addr, port, shared: true)` w każdym izolacie — jądro rozdziela `accept()`; bez dispatcher-izolatu i bez `SendPort` per żądanie.
- Na 1 vCPU: **jeden izolat** (extra izolaty = przełączenia kontekstu i pamięć; tak zrobił Dart w $12 challenge).

## 5. Pułapki

- `await for (final r in server)` + `await handle(r).timeout(...)` serializuje żądania w izolacie i alokuje `Future`+`Timer` per żądanie; użyj `server.listen` z synchronicznym handlerem.
- Wysyłanie closure'ów: przechwycony `this`/kontekst jest kopiowany (lub nie da się wysłać). Używaj funkcji statycznych / top-level (ObjectBox: „Static callback to avoid over-capturing due to dart-lang/sdk#36983”).
- `ReceivePort` bez `close()` trzyma izolat żywym.
- `TransferableTypedData` po `materialize()` jest puste; nie używaj dwa razy.
- Wyjątki w workerze: łap i odsyłaj jako dane (`(error, stack)`), inaczej izolat umiera cicho — ustaw `onError`/`onExit` porty.

## 6. Checklista

- [ ] praca > 1 ms CPU? jeśli nie — zostaw na wątku głównym i usuń alokacje
- [ ] payload w obie strony to typed data / niezmienne / `TransferableTypedData`, nie `List<Model>`
- [ ] worker długożyjący zamiast spawn per zadanie, gdy zadań jest wiele
- [ ] serwer: `shared: true`, izolat per rdzeń, ewentualnie grupy przez `spawnUri`
- [ ] błędy i zamykanie portów obsłużone
