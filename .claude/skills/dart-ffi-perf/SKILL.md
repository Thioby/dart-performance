---
name: dart-ffi-perf
description: Wydajne dart:ffi i dostęp do SQLite/kodu natywnego - @Native z isLeaf, asTypedList (zero-copy), NativeFinalizer/Finalizable, reużywane out-pointery, malloc vs Arena, package:sqlite3 (prepared persistent, stmt.raw, columnBlobInto) i group commit/batching zapisów. Użyj przy pisaniu lub przeglądzie bindingów FFI, pluginów natywnych, warstwy dostępu do SQLite/Isar/ObjectBox, albo gdy "FFI jest wolne" / "zapis do bazy jest wolny".
---

# dart-ffi-perf — FFI i baza danych bez narzutu

Źródła wzorców: `simolus3/sqlite3.dart` (`lib/src/ffi/`), `isar` v4 (`isar_core.dart`, `ffigen.yaml`), `objectbox-dart` (`native/bindings/flatbuffers.dart`, `store.dart`). Liczby z `benchmarks/` (AOT). Teoria: `docs/dart-flutter-extreme-performance-guide.md` §2.

## 1. Wiązanie funkcji: `@Native`, nie `lookupFunction`

```dart
// 🐢  late final add = lib.lookupFunction<Int64 Function(Int64, Int64), int Function(int, int)>('add_i64');
// 🚀
@Native<Int64 Function(Int64, Int64)>(isLeaf: true, symbol: 'add_i64')
external int addI64(int a, int b);
```

`@Native` rozwiązuje adres przy ładowaniu i pozwala AOT wołać trampolinę bezpośrednio; `late final` z `lookupFunction` to dodatkowe sprawdzenie inicjalizacji przy każdym wywołaniu. Biblioteka: przez *native assets* (`hook/build.dart`, jak `sqlite3` v3) lub `@DefaultAsset`/`DynamicLibrary.open` + `Native.addressOf`.

## 2. `isLeaf: true` — reguła trzech warunków

Oznacz jako leaf tylko funkcję, która (1) **nie woła z powrotem do Darta** (callbacki, UDF, hooki, VFS), (2) **nie blokuje** (brak I/O, mutexów, `sleep`), (3) jest krótka. Zysk: 21.6 ns → 5.4 ns per wywołanie (4×). Złamanie (1) = crash, złamanie (2) = zablokowany GC całej grupy izolatów.

Jak robią to biblioteki:
- `sqlite3.dart` — leaf tylko 10 trywialnych getterów (`sqlite3_changes`, `sqlite3_last_insert_rowid`, `sqlite3_column_count`…); **`sqlite3_step` nie jest leaf**, bo może wywołać funkcję użytkownika w Darcie.
- Isar v4 — leaf na *wszystkich* `isar_read_*`/`isar_write_*`/`isar_filter_*` (rdzeń w Ruście nigdy nie woła Darta) → wywołanie FFI per pole jest tańsze niż parsowanie bajtów w Darcie.

Projektując własne API C: oddziel funkcje „czyste” (leaf) od tych z callbackami; dla callbacków używaj `NativeCallable.isolateLocal` i zamykaj je (`close()`).

## 3. Pamięć natywna → Dart: widoki, nie kopie

| Operacja (4 KB) | AOT |
|---|---:|
| `ptr[i]` w pętli | 10 580 ns |
| `Uint8List.fromList(ptr.asTypedList(n))` | 710 ns |
| `ptr.asTypedList(n)` (widok) | **12 ns** |

```dart
final Uint8List view = ptr.asTypedList(size);                       // zero-copy, ważny póki żyje pamięć
final bd = ByteData.view(view.buffer, view.offsetInBytes, size);    // pola przez getInt32/getFloat64(…, Endian.little)
// gdy GC ma zwolnić pamięć razem z widokiem:
final owned = ptr.asTypedList(size, finalizer: malloc.nativeFree);
```

Kopiuj do **własnego, reużywanego** bufora, gdy natywny jest ulotny (`sqlite3_column_blob` jest ważny tylko do następnego `step`): `target.setRange(off, off + n, src.asTypedList(n))` — tak działa `columnBlobInto`.

## 4. Alokacja natywna: raz, nie per wywołanie

| 256 B | AOT |
|---|---:|
| `malloc` + `free` per wywołanie | 235 ns |
| `using((Arena a) => a<Uint8>(256))` | 290 ns |
| reużywany bufor | **172 ns** |

`Arena` to narzędzie poprawności (zwalnia przy wyjątku) dla wielu tymczasowych alokacji, nie przyspieszenie. W hot path trzymaj **out-pointery zaalokowane raz**:

```dart
// Isar: static Pointer<Pointer<NativeType>> ptrPtr = malloc(); static Pointer<Uint32> countPtr = malloc();
// ObjectBox: class ReadPointers { final dataPtrPtr = malloc<Pointer<Uint8>>(); final sizePtr = malloc<Size>(); }
final class Native { static final Pointer<Int64> outLen = malloc<Int64>(); }   // żyje całe życie izolatu
```

Bufory robocze: rosnące, resetowane, realokowane tylko gdy przerosną próg (`BuilderWithCBuffer.resetIfLarge()` > 64 KiB w ObjectBox).

## 5. Własność zasobów: `NativeFinalizer` + `Finalizable`

```dart
final _closeFinalizer = NativeFinalizer(Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(nativeClose).cast());

final class Handle implements Finalizable {       // Finalizable: obiekt żyje do końca wywołania FFI na jego wskaźniku
  final Pointer<Void> _p; final _token = Object();
  Handle(this._p) { _closeFinalizer.attach(this, _p, detach: _token, externalSize: 4096); }
  void close() { nativeClose(_p); _closeFinalizer.detach(_token); }   // jawne zamknięcie -> odczep, bez double free
}
```

- Finalizer natywny to funkcja C `void (*)(void*)` — zero kodu Darta w GC; `externalSize` pomaga GC wyceniać presję pamięci.
- Finalizery natywne odpalają w **kolejności utworzenia obiektów `NativeFinalizer`** (ObjectBox tworzy finalizer transakcji przed finalizerem store'a).
- `leak()`/`borrowed` (sqlite3.dart): odczep finalizer, gdy własność przechodzi do kodu natywnego.

## 6. Tekst przez granicę FFI

- Do C: `utf8.encode` → `malloc` + `memcpy`, destruktor `malloc.nativeFree` zamiast `SQLITE_TRANSIENT` (unikasz drugiej kopii w C) — tak robi `sqlite3_bind_text` w `sqlite3.dart`. Jeśli masz już bajty UTF-8 — binduj jako BLOB.
- Z C: `ptr.asTypedList(len)` + `utf8.decode` (1 kopia). Dla ASCII `String.fromCharCodes(view)` jest szybsze; Isar dostaje flagę `is_ascii` z Rusta i wybiera ścieżkę.
- Isar pisze stringi przez grow-only `Pointer<Uint16>` i `codeUnitAt` (bez `utf8.encode`), a kodowanie UTF-8 robi Rust.

## 7. SQLite przez `package:sqlite3` (≥ 3.7)

```dart
final db = sqlite3.open(path, mutex: false);              // jeden izolat => SQLITE_OPEN_NOMUTEX
db..execute('PRAGMA journal_mode=WAL')..execute('PRAGMA synchronous=NORMAL')..execute('PRAGMA temp_store=MEMORY');
final ins = db.prepare('INSERT INTO t(a,b) VALUES(?,?)', persistent: true);   // SQLITE_PREPARE_PERSISTENT
```

**Odczyt bez alokacji** (4.7× vs `select()`):

```dart
final raw = stmt.raw;                                      // RawPreparedStatement (extension type, 0 alokacji)
while (raw.step()) {
  final id = raw.columnInt64(0);                           // Smi, bez boxingu
  final n = raw.columnBlobInto(1, scratch);                // SELECT CAST(body AS BLOB): bajty do reużywanego bufora
}
stmt.reset();
```

Uwaga: raw nie sprawdza stanu — wywołanie na zamkniętym statement to use-after-free. Zamknij w jednej klasie DAO.

**Group commit** (13× na 10k zapisów): jedna transakcja na paczkę, paczka = to, co już czeka w tej iteracji pętli zdarzeń:

```dart
class WriteBatcher {
  final Database db; final _pending = <(void Function(), Completer<void>)>[]; bool _scheduled = false;
  Future<void> submit(void Function() apply) {
    final c = Completer<void>(); _pending.add((apply, c));
    if (!_scheduled) { _scheduled = true; scheduleMicrotask(_flush); }   // bez timera: zero latencji przy 1 żądaniu
    return c.future;                                                       // odpowiedź do klienta DOPIERO po COMMIT
  }
  void _flush() {
    _scheduled = false; final batch = List.of(_pending); _pending.clear();
    try { db.execute('BEGIN IMMEDIATE'); for (final (f, _) in batch) f(); db.execute('COMMIT');
          for (final (_, c) in batch) c.complete(); }
    catch (e, st) { db.execute('ROLLBACK'); for (final (_, c) in batch) c.completeError(e, st); }
  }
}
```

Paczki po 100 dają 85 % zysku pełnej transakcji — nie czekaj na „wszystko”. Checkpoint WAL (`PRAGMA wal_checkpoint(PASSIVE)`) rób poza ścieżką odpowiedzi, co N commitów lub gdy kolejka pusta. Isar: `putAll`; ObjectBox: `putMany` (jedna transakcja, reużywany builder FlatBuffers na `malloc`).

## 8. Checklista review bindingów

- [ ] `@Native` zamiast `lookupFunction`; `isLeaf` tylko przy spełnieniu 3 warunków
- [ ] brak `ptr[i]` w pętlach → `asTypedList`
- [ ] brak `malloc`/`Arena` per wywołanie w hot path → out-pointery i bufory statyczne
- [ ] każda klasa z wskaźnikiem: `implements Finalizable`, `NativeFinalizer` z `detach` w `close()`
- [ ] `NativeCallable` zamykane; brak callbacków z funkcji oznaczonych leaf
- [ ] SQLite: `persistent: true`, `mutex: false` dla jednego izolatu, `raw` w pętlach po wierszach, transakcje per paczka
- [ ] AOT: pakiety z build hooks (`sqlite3` ≥ 3) buduj przez `dart build cli`, nie `dart compile exe`
