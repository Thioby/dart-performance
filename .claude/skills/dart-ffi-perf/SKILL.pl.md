---
name: dart-ffi-perf
description: Wydajne dart:ffi i dostęp do SQLite/kodu natywnego - @Native z isLeaf, asTypedList (zero-copy), NativeFinalizer/Finalizable, reużywane out-pointery, malloc vs Arena, package:sqlite3 (prepared persistent, stmt.raw, columnBlobInto) oraz group commit/batchowanie zapisów. Użyj przy pisaniu lub review bindingów FFI, natywnych pluginów, warstwy danych nad SQLite/Isar/ObjectBox, albo gdy "FFI jest wolne" / "zapisy do bazy są wolne".
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu). Samowystarczalna: działa w dowolnym projekcie Dart/Flutter.

# dart-ffi-perf — FFI i baza danych bez narzutu

Wzorce wydestylowane z `sqlite3.dart`, Isar i ObjectBox; referencyjne zyski zmierzone na Dart 3.13 AOT, x64.

## 1. Bindowanie funkcji: `@Native`, nie `lookupFunction`

```dart
// 🐢  late final add = lib.lookupFunction<Int64 Function(Int64, Int64), int Function(int, int)>('add_i64');
// 🚀
@Native<Int64 Function(Int64, Int64)>(isLeaf: true, symbol: 'add_i64')
external int addI64(int a, int b);
```

`@Native` rozwiązuje adres w momencie ładowania i pozwala AOT wołać trampolinę bezpośrednio; `late final` z `lookupFunction` dodaje sprawdzenie inicjalizacji przy każdym wywołaniu. Biblioteka: przez *native assets* (`hook/build.dart`) albo `@DefaultAsset`/`DynamicLibrary.open` + `Native.addressOf`.

## 2. `isLeaf: true` — zasada trzech warunków

Oznacz jako leaf tylko funkcję, która (1) **nigdy nie woła z powrotem do Darta** (callbacki, UDF-y, hooki, VFS), (2) **nigdy nie blokuje** (brak I/O, mutexów, `sleep`), (3) jest krótka. Zysk: ~22 ns → ~5 ns per wywołanie (4×). Złamanie (1) = crash, złamanie (2) = zablokowany GC dla całej grupy izolatów.

Jak robią to biblioteki:
- `sqlite3.dart` — leaf tylko na 10 trywialnych getterach (`sqlite3_changes`, `sqlite3_last_insert_rowid`, `sqlite3_column_count`…); **`sqlite3_step` nie jest leaf**, bo może wywołać funkcję użytkownika napisaną w Darcie.
- Isar v4 — leaf na *wszystkich* `isar_read_*`/`isar_write_*`/`isar_filter_*` (rdzeń w Ruście nigdy nie woła Darta) → wywołanie FFI per pole jest tańsze niż parsowanie bajtów w Darcie.

Projektując własne API w C: oddziel funkcje "czyste" (leaf) od tych z callbackami; do callbacków używaj `NativeCallable.isolateLocal` i zamykaj je (`close()`).

## 3. Pamięć natywna → Dart: widoki, nie kopie

| Operacja (4 KB) | AOT |
|---|---:|
| `ptr[i]` w pętli | ~10 µs |
| `Uint8List.fromList(ptr.asTypedList(n))` | ~0.7 µs |
| `ptr.asTypedList(n)` (widok) | **~12 ns** |

```dart
final Uint8List view = ptr.asTypedList(size);                       // zero-copy, ważny dopóki pamięć żyje
final bd = ByteData.view(view.buffer, view.offsetInBytes, size);    // pola przez getInt32/getFloat64(…, Endian.little)
// gdy GC ma zwolnić pamięć razem z widokiem:
final owned = ptr.asTypedList(size, finalizer: malloc.nativeFree);
```

Kopiuj do **własnego, reużywanego** bufora, gdy natywny jest ulotny (`sqlite3_column_blob` jest ważny tylko do następnego `step`): `target.setRange(off, off + n, src.asTypedList(n))`.

## 4. Alokacja natywna: raz, nie per wywołanie

| 256 B | AOT |
|---|---:|
| `malloc` + `free` per wywołanie | ~235 ns |
| `using((Arena a) => a<Uint8>(256))` | ~290 ns |
| reużywany bufor | **~170 ns** |

`Arena` to narzędzie poprawności (zwalnia przy wyjątkach) dla wielu tymczasowych alokacji, nie przyspieszenie. W hot path trzymaj **out-pointery zaalokowane raz** (Isar: statyczne `ptrPtr`/`countPtr`/`boolPtr`; ObjectBox: `ReadPointers` per store):

```dart
final class Native { static final Pointer<Int64> outLen = malloc<Int64>(); }   // żyje przez cały czas życia izolatu
```

Bufory robocze: rosnące, resetowane, realokowane tylko po przekroczeniu progu (ObjectBox resetuje swój builder FlatBuffers tylko powyżej 64 KiB).

## 5. Własność zasobów: `NativeFinalizer` + `Finalizable`

```dart
final _closeFinalizer = NativeFinalizer(Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(nativeClose).cast());

final class Handle implements Finalizable {       // Finalizable: obiekt żyje do końca wywołania FFI na jego wskaźniku
  final Pointer<Void> _p; final _token = Object();
  Handle(this._p) { _closeFinalizer.attach(this, _p, detach: _token, externalSize: 4096); }
  void close() { nativeClose(_p); _closeFinalizer.detach(_token); }   // jawne close -> detach, bez double free
}
```

- Natywny finalizer to funkcja C `void (*)(void*)` — zero kodu Darta w GC; `externalSize` pomaga GC oszacować presję pamięci.
- Natywne finalizery odpalają się w **kolejności tworzenia obiektów `NativeFinalizer`** (utwórz finalizer dziecka przed finalizerem rodzica).
- Odłącz finalizer, gdy własność przechodzi do kodu natywnego.

## 6. Tekst przez granicę FFI

- Do C: `utf8.encode` → `malloc` + `memcpy`, destruktor `malloc.nativeFree` zamiast `SQLITE_TRANSIENT` (unika drugiej kopii w C). Jeśli masz już bajty UTF-8 — binduj je jako BLOB.
- Z C: `ptr.asTypedList(len)` + `utf8.decode` (1 kopia). Dla ASCII `String.fromCharCodes(view)` jest szybsze; niech strona natywna raportuje flagę `is_ascii`.
- Zapis stringów: rosnący tylko w górę `Pointer<Uint16>` wypełniany przez `codeUnitAt` i kodowanie UTF-8 po stronie natywnej unika alokacji `utf8.encode` (Isar).

## 7. SQLite przez `package:sqlite3` (≥ 3.7)

```dart
final db = sqlite3.open(path, mutex: false);              // jeden izolat => SQLITE_OPEN_NOMUTEX
db..execute('PRAGMA journal_mode=WAL')..execute('PRAGMA synchronous=NORMAL')..execute('PRAGMA temp_store=MEMORY');
final ins = db.prepare('INSERT INTO t(a,b) VALUES(?,?)', persistent: true);   // SQLITE_PREPARE_PERSISTENT
```

**Odczyty bez alokacji** (~4.7× vs `select()`):

```dart
final raw = stmt.raw;                                      // RawPreparedStatement (extension type, 0 alokacji)
while (raw.step()) {
  final id = raw.columnInt64(0);                           // Smi, bez boxingu
  final n = raw.columnBlobInto(1, scratch);                // SELECT CAST(body AS BLOB): bajty do reużywanego bufora
}
stmt.reset();
```

Uwaga: raw nie sprawdza stanu — wywołanie na zamkniętym statemencie to use-after-free. Zamknij go w jednej klasie DAO.

**Group commit** (~13× na 10k zapisów): jedna transakcja per batch, gdzie batch = wszystko, co już czeka w tej iteracji event loopa:

```dart
class WriteBatcher {
  final Database db; final _pending = <(void Function(), Completer<void>)>[]; bool _scheduled = false;
  WriteBatcher(this.db);
  Future<void> submit(void Function() apply) {
    final c = Completer<void>(); _pending.add((apply, c));
    if (!_scheduled) { _scheduled = true; scheduleMicrotask(_flush); }   // bez timera: zero opóźnienia przy 1 żądaniu
    return c.future;                                                       // odpowiedz klientowi DOPIERO po COMMIT
  }
  void _flush() {
    _scheduled = false; final batch = List.of(_pending); _pending.clear();
    try { db.execute('BEGIN IMMEDIATE'); for (final (f, _) in batch) { f(); } db.execute('COMMIT');
          for (final (_, c) in batch) { c.complete(); } }
    catch (e, st) { db.execute('ROLLBACK'); for (final (_, c) in batch) { c.completeError(e, st); } }
  }
}
```

Batche po 100 dają ~85 % zysku pełnej transakcji — nie czekaj na "wszystko". Checkpoint WAL (`PRAGMA wal_checkpoint(PASSIVE)`) uruchamiaj poza ścieżką odpowiedzi, co N commitów albo gdy kolejka jest pusta. Isar: `putAll`; ObjectBox: `putMany`.

## 8. Checklista review bindingów

- [ ] `@Native` zamiast `lookupFunction`; `isLeaf` tylko gdy spełnione są 3 warunki
- [ ] brak `ptr[i]` w pętlach → `asTypedList`
- [ ] brak `malloc`/`Arena` per wywołanie w hot path → statyczne out-pointery i bufory
- [ ] każda klasa trzymająca wskaźnik: `implements Finalizable`, `NativeFinalizer` z `detach` w `close()`
- [ ] `NativeCallable` zamykane; brak callbacków z funkcji oznaczonych leaf
- [ ] SQLite: `persistent: true`, `mutex: false` dla jednego izolatu, `raw` w pętlach po wierszach, transakcje per batch
- [ ] AOT: pakiety z build hookami (`sqlite3` ≥ 3) budowane przez `dart build cli`, nie `dart compile exe`

Lektura uzupełniająca z uruchamialnymi benchmarkami: https://github.com/Thioby/dart-performance
