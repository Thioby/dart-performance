---
name: dart-isolates
description: Designing concurrency in Dart/Flutter - when an isolate pays off (and when it adds jank), the cost of SendPort deep copies, flat payloads (Uint8List/ByteData), TransferableTypedData, Isolate.run and Isolate.exit, immutable objects and vm:deeply-immutable, isolate groups (Isolate.spawn vs spawnUri), HttpServer shared:true, closure over-capturing. Use when compute(), Isolate.spawn, "move to background", "the UI thread blocks" come up, or when communication between isolates is slow.
---

# dart-isolates — concurrency without copying

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory.

Numbers from `benchmarks/` (`--only isolates`, AOT, Dart 3.13) and the case study `packages/users_pipeline/` (`runIsolateBenchmark`). Theory and server context: `docs/en/dart-flutter-extreme-performance-guide.md` §3 and §6.

## 1. Decision: do you need an isolate at all?

An isolate pays off when **CPU work > ~1 ms** blocks a frame/the event loop. Fixed costs:

| Operation | AOT |
|---|---:|
| `Isolate.run(() => 1)` (spawn + port + result) | ~340 µs |
| `SendPort.send` 10k `Map`s (deep copy) | 9.2 ms |
| `SendPort.send` `Uint8List` 120 KB | 72 µs |
| `TransferableTypedData` 120 KB (`fromList` copies + move) | 124 µs |
| `Uint8List` 16 MB | 14.6 ms |
| `TransferableTypedData` 16 MB | 7.3 ms |
| `Isolate.run` → `List<User>` (10k model objects, deep copy) | 103.6 ms — **slower than parsing on the main thread (93.6 ms)** |
| `Isolate.run` → `TransferableTypedData` (packed columnar table) | 30.7 ms |

Before adding an isolate, check three cheaper options:
1. **Remove allocations** from the synchronous version (skill `dart-zero-alloc`) — 5 ms often becomes 0.3 ms.
2. **Split the work into ≤ 2 ms steps** across frames (`SchedulerBinding.instance.scheduleTask`, `await Future.delayed(Duration.zero)` between chunks).
3. **FFI `isLeaf`** to C/Rust (skill `dart-ffi-perf`) — numeric loops are 5–50× faster than Dart.

I/O **never** needs an isolate — `dart:io` is asynchronous on epoll/kqueue/IOCP.

## 2. Payload: flat bytes, not object graphs

`SendPort.send` serializes the graph (every object: an allocation + copy on the receiver's side, on **its** thread — received in the UI isolate this is jank). Rules:

```dart
// 🐢  port.send(models);                           // List<Model> -> 10k allocations at the receiver
// 🚀  port.send(columnarBytes);                    // Uint8List / Float64List: one memcpy
// 🚀🚀 port.send(TransferableTypedData.fromList([bytes]));   // receiver: materialize() O(1), the receiver's GC never sees a big object
```

Design the worker's result as **columns in one `ByteData`** (offsets, `Endian.little`) and read them through views (`Float64List.view(buffer, off, n)`) — without deserializing into objects. Worked example: `UserTable.packContiguous()` / `UserTable.unpack(ByteBuffer)` in `packages/users_pipeline/lib/src/columnar.dart` (all columns as views over one buffer).

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
// worker: ReceivePort + SendPort handshake; listen() loop; replies with a small ack or TransferableTypedData
// client: keeps the SendPort; queues tasks; uses a StreamIterator on the ReceivePort for in-order replies
```
Complete template: `benchmarks/lib/src/bench_isolates.dart` (`_workerMain`, `setupIsolates`, `_roundTrip`) and §3.2 of the guide.

### Flutter `compute()`
`compute` = `Isolate.run` with a copy of the argument and the result. For JSON < ~50 KB it is **slower** than parsing on the UI thread. Use it for decoding large files/images and return bytes, not lists of models. In `flutter_bench/` the row "compute(): slow → List<User>" shows that the deep copy on receipt stalls the UI again, while "Isolate.run: scanner → Transferable" keeps it smooth.

## 4. Closure over-capturing (dart-lang/sdk#36983)

A lambda passed to `Isolate.run` **inside a method of a class** shares its context with the method's other closures and may capture `this`. If `this` is a `State` with an `AnimationController`, you get "Illegal argument in isolate message: object is unsendable - TickerFuture". Fix: isolate work in **top-level or static functions** with explicit arguments (ObjectBox: "Static callback to avoid over-capturing"):

```dart
// 🐢  await Isolate.run(() => decodeColumnar(bytes));            // inside _MyState: may capture `this`
// 🚀
Future<TransferableTypedData> scanInIsolate(Uint8List bytes) =>
    Isolate.run(() => TransferableTypedData.fromList([decodeColumnar(bytes).packContiguous()]));
```

## 5. Isolate groups (servers, many-core machines)

- `Isolate.spawn` → the same **isolate group**: a shared heap, shared GC and safepoints (one isolate's scavenge stops them all), cheaper messages.
- `Isolate.spawnUri(Platform.script, args, msg)` → a **new group**: a separate heap and GC. TechEmpower `dart3_aot` splits isolates into groups of `MAX_ISOLATES=8` to "bypass internal VM scaling bottlenecks" on 28+ core machines.
- HTTP server: `HttpServer.bind(addr, port, shared: true)` in every isolate — the kernel distributes `accept()`; no dispatcher isolate, no `SendPort` per request.
- On 1 vCPU: **one isolate** (extra isolates = context switches and memory; that is what the Dart entry in the $12 challenge did).

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
