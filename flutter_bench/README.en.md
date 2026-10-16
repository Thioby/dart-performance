> 🇬🇧 English version · [🇵🇱 Wersja polska](README.md)

# flutter_bench — "10k users from JSON" on a device

The same logic as the CLI (`packages/users_pipeline`), run inside a Flutter app with a jank counter. It shows not only *how many ms* a variant takes, but *what it does to the UI*: an icon spins on the UI thread during the measurement, and the table counts frames above 16.7 ms.

```bash
cd flutter_bench
flutter pub get
flutter run --profile          # always profile/release: debug has asserts and the JIT
flutter test                   # widget test: every variant runs and produces a result
```

## What it measures

| Variant | Where | What to expect |
|---|---|---|
| UI: slow (`String` + `jsonDecode` + `fromJson` + `where`) | UI thread | tens to hundreds of ms of blocking, the animation freezes, heavy jank |
| UI: fused + objects + loops | UI thread | similar — the cost is the JSON tree and 100k objects, not UTF-8 |
| UI: byte scanner → columns | UI thread | ~8× shorter; 1–2 janky frames on a fast phone |
| `compute()`: slow → `List<User>` | isolate, result deep-copied | parsing off the UI thread, but **receiving 10k objects** stalls the UI again |
| `Isolate.run`: scanner → `TransferableTypedData` | isolate, O(1) result | smooth UI, time ≈ parsing + spawn |
| `Isolate.run`: whole pipeline, result = top 100 | isolate | cheapest: 100 Strings and a small map come back |

Data source: a URL (by default the raw file from this repository on GitHub; paste your own gist) or the built-in generator (10k users, deterministic, generated in an isolate).

## What the screen shows

- **ms** — median of 3 repetitions of the variant (on a device; numbers on an emulator are meaningless).
- **jank** — the number of frames > 16.7 ms during the variant (`SchedulerBinding.addTimingsCallback`) and the longest frame.
- **vs 1** — speed-up relative to the first row.
- The top 100 names and the number of active users per country — so you can see that the variants compute the same thing (the `assertVariantsAgree` test checks this automatically).

A pitfall the widget test caught immediately: a lambda passed to `Isolate.run` inside a `State` method captured `this` with its `AnimationController` ("object is unsendable: TickerFuture", dart-lang/sdk#36983). Isolate work therefore lives in top-level functions (`scanInIsolate`, `pipelineInIsolate`).

See also `docs/en/dart-flutter-extreme-performance-guide.md` §6 (case study) and `packages/users_pipeline/README.en.md`.
