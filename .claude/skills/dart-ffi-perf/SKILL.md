---
name: dart-ffi-perf
description: Efficient dart:ffi and access to SQLite/native code - @Native with isLeaf, asTypedList (zero-copy), NativeFinalizer/Finalizable, reused out-pointers, malloc vs Arena, package:sqlite3 (prepared persistent, stmt.raw, columnBlobInto) and group commit/batching of writes. Use when writing or reviewing FFI bindings, native plugins, the data layer over SQLite/Isar/ObjectBox, or when "FFI is slow" / "database writes are slow".
---

# dart-ffi-perf — FFI and database without overhead

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory.

Pattern sources: `simolus3/sqlite3.dart` (`lib/src/ffi/`), `isar` v4 (`isar_core.dart`, `ffigen.yaml`), `objectbox-dart` (`native/bindings/flatbuffers.dart`, `store.dart`). Numbers from `benchmarks/` (AOT). Theory: `docs/en/dart-flutter-extreme-performance-guide.md` §2.

## 1. Binding functions: `@Native`, not `lookupFunction`

```dart
// 🐢  late final add = lib.lookupFunction<Int64 Function(Int64, Int64), int Function(int, int)>('add_i64');
// 🚀
@Native<Int64 Function(Int64, Int64)>(isLeaf: true, symbol: 'add_i64')
external int addI64(int a, int b);
```

`@Native` resolves the address at load time and lets AOT call the trampoline directly; `late final` with `lookupFunction` adds an initialization check on every call. Library: via *native assets* (`hook/build.dart`, as `sqlite3` v3 does) or `@DefaultAsset`/`DynamicLibrary.open` + `Native.addressOf`.

## 2. `isLeaf: true` — the three-condition rule

Mark as leaf only a function that (1) **never calls back into Dart** (callbacks, UDFs, hooks, a VFS), (2) **never blocks** (no I/O, mutexes, `sleep`), (3) is short. Gain: 21.6 ns → 5.4 ns per call (4×). Breaking (1) = crash, breaking (2) = a blocked GC for the whole isolate group.

How libraries do it:
- `sqlite3.dart` — leaf on only 10 trivial getters (`sqlite3_changes`, `sqlite3_last_insert_rowid`, `sqlite3_column_count`…); **`sqlite3_step` is not leaf**, because it can invoke a user function written in Dart.
- Isar v4 — leaf on *all* `isar_read_*`/`isar_write_*`/`isar_filter_*` (the Rust core never calls Dart) → an FFI call per field is cheaper than parsing bytes in Dart.

When designing your own C API: separate "pure" functions (leaf) from those with callbacks; for callbacks use `NativeCallable.isolateLocal` and close them (`close()`).

## 3. Native memory → Dart: views, not copies

| Operation (4 KB) | AOT |
|---|---:|
| `ptr[i]` in a loop | 10 580 ns |
| `Uint8List.fromList(ptr.asTypedList(n))` | 710 ns |
| `ptr.asTypedList(n)` (view) | **12 ns** |

```dart
final Uint8List view = ptr.asTypedList(size);                       // zero-copy, valid while the memory lives
final bd = ByteData.view(view.buffer, view.offsetInBytes, size);    // fields via getInt32/getFloat64(…, Endian.little)
// when the GC should free the memory together with the view:
final owned = ptr.asTypedList(size, finalizer: malloc.nativeFree);
```

Copy into **your own, reused** buffer when the native one is transient (`sqlite3_column_blob` is valid only until the next `step`): `target.setRange(off, off + n, src.asTypedList(n))` — that is how `columnBlobInto` works.

## 4. Native allocation: once, not per call

| 256 B | AOT |
|---|---:|
| `malloc` + `free` per call | 235 ns |
| `using((Arena a) => a<Uint8>(256))` | 290 ns |
| reused buffer | **172 ns** |

`Arena` is a correctness tool (frees on exceptions) for many temporary allocations, not a speed-up. In the hot path keep **out-pointers allocated once**:

```dart
// Isar: static Pointer<Pointer<NativeType>> ptrPtr = malloc(); static Pointer<Uint32> countPtr = malloc();
// ObjectBox: class ReadPointers { final dataPtrPtr = malloc<Pointer<Uint8>>(); final sizePtr = malloc<Size>(); }
final class Native { static final Pointer<Int64> outLen = malloc<Int64>(); }   // lives for the isolate's lifetime
```

Scratch buffers: growing, reset, reallocated only when they exceed a threshold (`BuilderWithCBuffer.resetIfLarge()` > 64 KiB in ObjectBox).

## 5. Resource ownership: `NativeFinalizer` + `Finalizable`

```dart
final _closeFinalizer = NativeFinalizer(Native.addressOf<NativeFunction<Void Function(Pointer<Void>)>>(nativeClose).cast());

final class Handle implements Finalizable {       // Finalizable: the object stays alive until the end of an FFI call on its pointer
  final Pointer<Void> _p; final _token = Object();
  Handle(this._p) { _closeFinalizer.attach(this, _p, detach: _token, externalSize: 4096); }
  void close() { nativeClose(_p); _closeFinalizer.detach(_token); }   // explicit close -> detach, no double free
}
```

- A native finalizer is a C function `void (*)(void*)` — zero Dart code in the GC; `externalSize` helps the GC estimate memory pressure.
- Native finalizers fire in the **creation order of the `NativeFinalizer` objects** (ObjectBox creates the transaction finalizer before the store finalizer).
- `leak()`/`borrowed` (sqlite3.dart): detach the finalizer when ownership moves to native code.

## 6. Text across the FFI boundary

- To C: `utf8.encode` → `malloc` + `memcpy`, destructor `malloc.nativeFree` instead of `SQLITE_TRANSIENT` (avoids a second copy in C) — this is how `sqlite3_bind_text` in `sqlite3.dart` works. If you already have UTF-8 bytes — bind them as a BLOB.
- From C: `ptr.asTypedList(len)` + `utf8.decode` (1 copy). For ASCII `String.fromCharCodes(view)` is faster; Isar gets an `is_ascii` flag from Rust and picks the path.
- Isar writes strings through a grow-only `Pointer<Uint16>` and `codeUnitAt` (no `utf8.encode`), and lets Rust do the UTF-8 encoding.

## 7. SQLite via `package:sqlite3` (≥ 3.7)

```dart
final db = sqlite3.open(path, mutex: false);              // one isolate => SQLITE_OPEN_NOMUTEX
db..execute('PRAGMA journal_mode=WAL')..execute('PRAGMA synchronous=NORMAL')..execute('PRAGMA temp_store=MEMORY');
final ins = db.prepare('INSERT INTO t(a,b) VALUES(?,?)', persistent: true);   // SQLITE_PREPARE_PERSISTENT
```

**Allocation-free reads** (4.7× vs `select()`):

```dart
final raw = stmt.raw;                                      // RawPreparedStatement (extension type, 0 allocations)
while (raw.step()) {
  final id = raw.columnInt64(0);                           // Smi, no boxing
  final n = raw.columnBlobInto(1, scratch);                // SELECT CAST(body AS BLOB): bytes into a reused buffer
}
stmt.reset();
```

Caveat: raw does not check state — calling it on a closed statement is a use-after-free. Enclose it in one DAO class.

**Group commit** (13× on 10k writes): one transaction per batch, where a batch = whatever is already waiting in this event-loop iteration:

```dart
class WriteBatcher {
  final Database db; final _pending = <(void Function(), Completer<void>)>[]; bool _scheduled = false;
  Future<void> submit(void Function() apply) {
    final c = Completer<void>(); _pending.add((apply, c));
    if (!_scheduled) { _scheduled = true; scheduleMicrotask(_flush); }   // no timer: zero latency with 1 request
    return c.future;                                                       // reply to the client ONLY after COMMIT
  }
  void _flush() {
    _scheduled = false; final batch = List.of(_pending); _pending.clear();
    try { db.execute('BEGIN IMMEDIATE'); for (final (f, _) in batch) f(); db.execute('COMMIT');
          for (final (_, c) in batch) c.complete(); }
    catch (e, st) { db.execute('ROLLBACK'); for (final (_, c) in batch) c.completeError(e, st); }
  }
}
```

Batches of 100 give 85 % of the full-transaction gain — do not wait for "everything". Run the WAL checkpoint (`PRAGMA wal_checkpoint(PASSIVE)`) off the response path, every N commits or when the queue is empty. Isar: `putAll`; ObjectBox: `putMany` (one transaction, a reused FlatBuffers builder on `malloc`).

## 8. Binding review checklist

- [ ] `@Native` instead of `lookupFunction`; `isLeaf` only when the 3 conditions hold
- [ ] no `ptr[i]` in loops → `asTypedList`
- [ ] no `malloc`/`Arena` per call in the hot path → static out-pointers and buffers
- [ ] every class holding a pointer: `implements Finalizable`, `NativeFinalizer` with `detach` in `close()`
- [ ] `NativeCallable`s closed; no callbacks from functions marked leaf
- [ ] SQLite: `persistent: true`, `mutex: false` for a single isolate, `raw` in row loops, transactions per batch
- [ ] AOT: packages with build hooks (`sqlite3` ≥ 3) are built with `dart build cli`, not `dart compile exe`
