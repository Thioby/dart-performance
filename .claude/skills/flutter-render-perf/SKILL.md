---
name: flutter-render-perf
description: Diagnosing and fixing jank in Flutter - rebuilds (const, setState low, ListenableBuilder with child), RepaintBoundary, CustomPainter/RenderObject with typed data and drawRawPoints/drawRawAtlas, saveLayer (Opacity, Clip), lists (builder, itemExtent), images (cacheWidth), Impeller, the DevTools workflow (--profile, Track rebuilds/paints, Allocation tracing), measuring jank with addTimingsCallback. Use when the user reports jank, dropped frames, long UI/Raster frames, high GPU memory, or asks how to optimize a widget/animation/list.
---

# flutter-render-perf — a frame in 8.3 ms

> 🇬🇧 Active skill file. Polish version: `SKILL.pl.md` in this directory.

Model: UI thread (Dart: build → layout → paint → compositing) + Raster thread (Impeller → GPU). Each has its own budget of 16.6 ms (60 Hz) / 8.3 ms (120 Hz). First establish **which** thread exceeds the budget — they are treated differently. GC/allocation theory: `docs/en/dart-flutter-extreme-performance-guide.md` §1 and §4; a device-side example with a jank counter: `flutter_bench/`.

## 1. Diagnosis (always `flutter run --profile` on a device)

1. DevTools → **Performance**: Frame chart. Red bars on UI → Dart; on Raster → GPU/shaders/layers.
2. Enable **Track widget rebuilds**, **Track layouts**, **Track paints** → widgets with hundreds of rebuilds/s and paints outside boundaries.
3. **Memory → Allocation tracing** during the animation: which classes are allocated every frame (`Offset`, `Paint`, `_GrowableList`, `TextStyle`, your models). A sawtooth heap chart = scavenges; the goal is a flat line.
4. Timeline: `GC` events right before a long frame = allocations in the frame loop.
5. `flutter run --profile --trace-skia` / Impeller: `--enable-impeller`, overlays `debugPaintLayerBordersEnabled`, `debugRepaintRainbowEnabled` (repaints), `checkerboardOffscreenLayers` (saveLayer).
6. In-app measurement: `SchedulerBinding.instance.addTimingsCallback` — count frames with `totalSpan > 16.7 ms` during an operation (`JankMeter` in `flutter_bench/lib/main.dart`).

## 2. UI thread: rebuilds

| 🐢 | 🚀 |
|---|---|
| `setState` in the screen widget | `setState` in the smallest `StatefulWidget`; `ValueListenableBuilder`/`ListenableBuilder` around the fragment |
| `AnimationController.addListener(() => setState(() {}))` | `AnimatedBuilder(animation, child: staticSubtree, builder: ...)` — `child` is not rebuilt; or `FadeTransition`/`SlideTransition` (no rebuild, repaint only) |
| `EdgeInsets.all(8)`, `TextStyle(...)`, `BoxDecoration(...)` in `build` | `const` / `static final` — a `const` widget is skipped via `identical()` and never allocates |
| `widget.items.map((e) => Tile(e)).toList()` in `build` | `ListView.builder`/`SliverList` with `itemBuilder`, `itemExtent` or `prototypeItem` |
| lambdas capturing `this` in `build` | instance methods (`onPressed: _handleTap`) |
| `MediaQuery.of(context)` in many places (rebuild on every change) | `MediaQuery.sizeOf(context)`/`paddingOf` (depend on one aspect only) |

Rule: a subtree rebuild = allocation of all its `Widget`s (short-lived objects → scavenge). The lower the `setState`, the less garbage.

## 3. UI thread: layout and paint

- `RepaintBoundary` around things that animate **independently** of the rest (and around a static, expensive rest when a sibling animates). Too many boundaries = too many layers/textures; check with `debugRepaintRainbowEnabled`.
- `CustomPainter`: `shouldRepaint` returns `true` only when the data changed; `super(repaint: listenable)` instead of `setState` — a repaint without a rebuild.
- `IntrinsicHeight/Width`, `Wrap`, nested `Flexible` with `mainAxisSize.min` → multiple layout passes; `ListView` with `shrinkWrap: true` inside a `Column` → layout of the whole list.
- `Text` in a loop → `TextPainter` layout is expensive; in a `CustomPainter` cache `TextPainter`/`ui.Paragraph` for constant labels.

### A zero-alloc painter (SoA + raw APIs)

```dart
class ParticlePainter extends CustomPainter {
  ParticlePainter(this.xy, Listenable tick) : super(repaint: tick);
  final Float32List xy;                                   // [x0,y0,x1,y1,...] updated in place
  static final _paint = Paint()..color = const Color(0xFFFFFFFF)..strokeWidth = 2..strokeCap = StrokeCap.round;
  @override void paint(Canvas c, Size s) => c.drawRawPoints(PointMode.points, xy, _paint);   // 1 call, 0 Offsets
  @override bool shouldRepaint(ParticlePainter old) => !identical(old.xy, xy);
}
```

Raw APIs taking typed data: `drawRawPoints(Float32List)`, `drawRawAtlas(Image, Float32List rstTransforms, Float32List rects, Int32List? colors, ...)`, `drawVertices(Vertices.raw(mode, Float32List positions, ...))`, `Path.addPolygon` (a list of `Offset`, but once). For thousands of sprites `drawRawAtlas` is the only sensible choice.

Full control: `LeafRenderObjectWidget` + `RenderBox` (`sizedByParent = true`, `computeDryLayout`, `markNeedsPaint()` from a `Ticker`) — layout once, paint every frame, state in typed data. Complete example: guide §4.3.

## 4. Raster thread

- The `Opacity` widget = `saveLayer` (an offscreen render target). Replace: `Opacity` on a leaf, `FadeTransition` on a `RepaintBoundary`, `Image(opacity:)`, a color with alpha in `Paint`/`Container(color:)`.
- `ClipRRect`/`ClipPath`/`ClipOval` with `Clip.antiAlias(WithSaveLayer)` on animated elements → `Clip.hardEdge` or `DecoratedBox(borderRadius)`; avoid clipping transparent layers.
- `BackdropFilter`, `ImageFilter.blur`, `ShaderMask` → always expensive; limit the `RepaintBoundary` area, cache a static background as a `ui.Image` (`PictureRecorder` → `toImage`).
- Images: `Image.network(url, cacheWidth: w, cacheHeight: h)` — decode to the display size (4000×3000 → a 48 MB texture). `ImageCache` counts GPU memory, not the Dart heap.
- Impeller precompiles shaders (no more "first-frame shader jank"), but does not reduce the cost of `saveLayer` or the number of layers.
- Gradients/shadows on large surfaces: a `BoxShadow` with a large `blurRadius` on every list card → replace with one image/`DecorationImage` or reduce the blur.

## 5. Lists and scrolling

- `ListView.builder`/`GridView.builder`, `itemExtent` or `prototypeItem` (layout without measuring), a `cacheExtent` matched to the scroll speed.
- `addAutomaticKeepAlives: false`, `addRepaintBoundaries: false` when the items are cheap and static (a boundary per item costs more than it saves); keep `true` when items animate independently.
- `AutomaticKeepAlive`/`KeepAlive` only for items with expensive state.
- Slivers instead of nested scrolls; `SliverFixedExtentList` for a constant height.
- Data for long lists: a columnar model with lazy per-row decoding (`UserTable.fullName(i)` in `packages/users_pipeline`) instead of 10k model objects with `DateTime`s.

## 6. Animations: a Ticker without setState

```dart
// 🐢 controller.addListener(() => setState(() {}));           // rebuilds the tree 120×/s
// 🚀 AnimatedBuilder(animation: controller, child: heavyStatic, builder: (_, child) => Transform.translate(offset: ..., child: child));
// 🚀🚀 a RenderObject with a Ticker -> markNeedsPaint(); data in a Float32List; drawRawPoints/drawRawAtlas
```

Implicit animations (`AnimatedContainer`) are convenient but rebuild; for 60+ elements use explicit `*Transition`s with a `RepaintBoundary`.

## 7. Response format for a review

For every finding: `file:line — what happens every frame — fix (code) — how to see it in DevTools`. Separate UI-thread from Raster-thread findings. If it cannot be determined without a profile — say which measurement to take (section 1) instead of guessing.

## 8. PR checklist

- [ ] zero allocations in `paint()`/`Ticker` (DevTools Allocation tracing flat over 10 s of animation)
- [ ] `const` wherever possible; `setState` in the smallest widget; `child:` in builders
- [ ] `RepaintBoundary` around independent animations (and only there)
- [ ] no `Opacity`/`ClipPath`/`BackdropFilter` on animating large surfaces
- [ ] lists: `.builder` + `itemExtent`/`prototypeItem`
- [ ] images with `cacheWidth/Height`
- [ ] a `--profile` before/after attached to the PR (p90 UI and Raster frame times)
