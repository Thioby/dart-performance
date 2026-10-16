---
name: dart-isolates
description: Designing concurrency in Dart/Flutter - when an isolate pays off (and when it adds jank), the cost of SendPort deep copies, flat payloads (Uint8List/ByteData), TransferableTypedData, Isolate.run and Isolate.exit, immutable objects and vm:deeply-immutable, isolate groups (Isolate.spawn vs spawnUri), HttpServer shared:true, closure over-capturing. Use when compute(), Isolate.spawn, "move to background", "the UI thread blocks" come up, or when communication between isolates is slow.
---

# dart-isolates — concurrency without copying

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory. Self-contained: works in any Dart/Flutter project.

Reference numbers: Dart 3.13 AOT, x64. Verify in your project (skill `dart-benchmark`).

## 1. Decision: do you need an isolate at all?

An isolate pays off when **CPU work > ~1 ms** blocks a frame/the event loop. Fixed costs:

| Operation | AOT |
|---|---:|
| `Isolate.run(() => 1)` (spawn + port + result) | ~0.1–0.35 ms |
| `SendPort.send` of 10k `Map`s (deep copy) | ~9 ms |
| `SendPort.send` of a 120 KB `Uint8List` | ~70 µs |
| `TransferableTypedData` 120 KB (`fromList` copies + move) | ~120 µs |
| `Uint8List` 16 MB | ~15 ms |
| `TransferableTypedData` 16 MB | ~7 ms |
| `Isolate.run` → `List<Model>` of 10k parsed records | ~104 ms — **slower than parsing on the main thread (~94 ms)** |
| `Isolate.run` → `TransferableTypedData` (packed columnar table) | ~31 ms |

Before adding an isolate, check three cheaper options:
1. **Remove allocations** from the synchronous version (skill `dart-zero-alloc`) — 5 ms often becomes 0.3 ms.
2. **Split the work into ≤ 2 ms steps** across frames (`SchedulerBinding.instance.scheduleTask`, `await Future.delayed(Duration.zero)` between chunks).
3. **FFI `isLeaf`** to C/Rust (skill `dart-ffi-perf`) — numeric loops are 5–50× faster than Dart.

I/O **never** needs an isolate — `dart:io` is asynchronous on epoll/kqueue/IOCP.

## 2. Payload: flat bytes, not object graphs

`SendPort.send` serializes the graph (every object: an allocation + copy on the receiver's side, on **its** thread — received in the UI isolate this is jank). Rules:

```dart
// 🐢  port.send(models);                           // List<Model> -> thousands of allocations at the receiver
// 🚀  port.send(columnarBytes);                    // Uint8List / Float64List: one memcpy
// 🚀🚀 port.send(TransferableTypedData.fromList([bytes]));   // receiver: materialize() O(1); the receiver's GC never sees a big object
```

Design the worker's result as **columns in one buffer** and read them through views — no deserialization into objects:

```dart
// pack: header (counts) + column bytes, each column aligned to its element size
Uint8List pack(Int32List id, Float64List score) {
  final n = id.length; final out = ByteData(8 + n * 4 + ((n * 4 + 7) & ~7) - n * 4 + n * 8);
  out.setInt32(0, n, Endian.little);
  var off = 8;
  Uint8List.view(out.buffer, off, n * 4).setRange(0, n * 4, Uint8List.view(id.buffer, id.offsetInBytes, n * 4));
  off = (off + n * 4 + 7) & ~7;                                   // align to 8 for Float64List
  Uint8List.view(out.buffer, off, n * 8).setRange(0, n * 8, Uint8List.view(score.buffer, score.offsetInBytes, n * 8));
  return out.buffer.asUint8List();
}
// unpack on the receiver: Int32List.view(buf, 8, n), Float64List.view(buf, alignedOff, n) — views, zero copies
```

### What is sent without copying

- Immutables: `int`, `double`, `bool`, `String`, `null`, `const` collections, `Pointer`, SIMD, *unmodifiable* typed data — shared within an isolate group.
- Classes marked `@pragma('vm:deeply-immutable')` (`final`/`sealed` class, all fields `final` and deeply immutable) — shared.
- `TransferableTypedData` — buffer ownership is moved; `fromList` **copies** into a native buffer once, the transfer itself and `materialize()` are O(1).
- `Isolate.run` / `Isolate.exit(port, result)` — the result is "transplanted" (no copy), because the isolate terminates right after.
- `Pointer.address` (int) — native memory is shared by the process; this is shared memory, you manage its lifetime.

## 3. Patterns

### One-off work
```dart
final result = await Isolate.run(() {
  final bytes = decodeAndFlatten(input);              // input: Uint8List (copied once) or String (shared)
  return TransferableTypedData.fromList([bytes]);
});
final view = result.materialize().asFloat64List();
```

### Long-lived worker (avoid a spawn per task)
```dart
late SendPort _worker;
late StreamIterator<Object?> _replies;

void _workerMain(SendPort reply) {                     // top-level function
  final port = ReceivePort();
  reply.send(port.sendPort);                           // handshake: hand over your SendPort
  port.listen((msg) {
    if (msg is TransferableTypedData) { reply.send(process(msg.materialize().asUint8List())); }
    else if (msg == null) { port.close(); }           // shutdown: no open ports = the isolate exits on its own
  });
}

Future<void> start() async {
  final inbox = ReceivePort();
  await Isolate.spawn(_workerMain, inbox.sendPort);
  _replies = StreamIterator(inbox);
  await _replies.moveNext();
  _worker = _replies.current as SendPort;
}

Future<Object?> submit(Uint8List payload) async {      // one request in flight at a time, replies in order
  _worker.send(TransferableTypedData.fromList([payload]));
  await _replies.moveNext();
  return _replies.current;
}
```
Several tasks in flight → add an `id` to the message and keep a `Map<int, Completer>`; keep reply payloads flat too (`id` in the first 4 bytes of a `Uint8List`).

### Flutter `compute()`
`compute` = `Isolate.run` with a copy of the argument and the result. For JSON < ~50 KB it is **slower** than parsing on the UI thread. Use it for decoding large files/images and return bytes, not lists of models — a deep copy of 10k model objects on receipt stalls the UI again, while `TransferableTypedData` keeps it smooth. Alternatively run the *whole* pipeline in the isolate and return only the small final result (e.g. the top 100 rows).

## 4. Closure over-capturing (dart-lang/sdk#36983)

A lambda passed to `Isolate.run` **inside a method of a class** shares its context with the method's other closures and may capture `this`. If `this` is a `State` with an `AnimationController`, you get "Illegal argument in isolate message: object is unsendable - TickerFuture". Fix: isolate work in **top-level or static functions** with explicit arguments (ObjectBox comments every such callback with "Static callback to avoid over-capturing"):

```dart
// 🐢  await Isolate.run(() => parse(bytes));                          // inside _MyState: may capture `this`
// 🚀
Future<TransferableTypedData> parseInIsolate(Uint8List bytes) =>
    Isolate.run(() => TransferableTypedData.fromList([parseToColumns(bytes)]));
```

## 5. Isolate groups (servers, many-core machines)

- `Isolate.spawn` → the same **isolate group**: a shared heap, shared GC and safepoints (one isolate's scavenge stops them all), cheaper messages.
- `Isolate.spawnUri(Platform.script, args, msg)` → a **new group**: a separate heap and GC. Splitting isolates into groups of ~8 bounds GC interference on many-core machines.
- HTTP server: `HttpServer.bind(addr, port, shared: true)` in every isolate — the kernel distributes `accept()`; no dispatcher isolate, no `SendPort` per request.
- On 1 vCPU: **one isolate** (extra isolates = context switches and memory).

## 6. Pitfalls

- `await for (final r in server)` + `await handle(r).timeout(...)` serializes requests in the isolate and allocates a `Future`+`Timer` per request; use `server.listen` with a synchronous handler.
- Sending closures: a captured `this`/context is copied (or cannot be sent at all). Use static / top-level functions.
- A `ReceivePort` without `close()` keeps the isolate alive.
- `TransferableTypedData` is empty after `materialize()`; do not use it twice.
- Exceptions in the worker: catch and send them back as data (`(error, stack)`), otherwise the isolate dies silently — set `onError`/`onExit` ports.

## 7. Checklist

- [ ] work > 1 ms of CPU? if not — keep it on the main thread and remove allocations
- [ ] payload in both directions is typed data / immutable / `TransferableTypedData`, not `List<Model>`
- [ ] a long-lived worker instead of a spawn per task when there are many tasks
- [ ] isolate work in top-level/static functions (no `this` capture)
- [ ] server: `shared: true`, an isolate per core, optionally groups via `spawnUri`
- [ ] errors and port closing handled

Background reading with runnable benchmarks: https://github.com/Thioby/dart-performance
