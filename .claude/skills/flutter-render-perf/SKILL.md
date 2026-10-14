---
name: flutter-render-perf
description: Diagnoza i naprawa janku w Flutterze - rebuildy (const, setState nisko, ListenableBuilder z child), RepaintBoundary, CustomPainter/RenderObject z typed data i drawRawPoints/drawRawAtlas, saveLayer (Opacity, Clip), listy (builder, itemExtent), obrazy (cacheWidth), Impeller, workflow DevTools (--profile, Track rebuilds/paints, Allocation tracing). Użyj, gdy użytkownik zgłasza jank, dropped frames, długie klatki UI/Raster, wysokie zużycie pamięci GPU lub pyta, jak zoptymalizować widget/animację/listę.
---

# flutter-render-perf — klatka w 8.3 ms

Model: UI thread (Dart: build → layout → paint → compositing) + Raster thread (Impeller → GPU). Każdy ma własny budżet 16.6 ms (60 Hz) / 8.3 ms (120 Hz). Najpierw ustal, **który** wątek przekracza budżet — leczy się je inaczej. Teoria GC/alokacji: `docs/dart-flutter-extreme-performance-guide.md` §1 i §4.

## 1. Diagnoza (zawsze `flutter run --profile` na urządzeniu)

1. DevTools → **Performance**: Frame chart. Czerwone słupki UI → Dart; Raster → GPU/shadery/warstwy.
2. Włącz **Track widget rebuilds**, **Track layouts**, **Track paints** → widgety z setkami rebuildów/s i paint poza granicami.
3. **Memory → Allocation tracing** podczas animacji: które klasy są alokowane co klatkę (`Offset`, `Paint`, `_GrowableList`, `TextStyle`, Twoje modele). Zęby piły na wykresie sterty = scavenge; cel to płaska linia.
4. Timeline: eventy `GC` tuż przed długą klatką = alokacje w pętli klatki.
5. `flutter run --profile --trace-skia` / Impeller: `--enable-impeller`, overlay `debugPaintLayerBordersEnabled`, `debugRepaintRainbowEnabled` (przerysowania), `checkerboardOffscreenLayers` (saveLayer).

## 2. UI thread: rebuildy

| 🐢 | 🚀 |
|---|---|
| `setState` w widgecie ekranu | `setState` w najmniejszym `StatefulWidget`; `ValueListenableBuilder`/`ListenableBuilder` wokół fragmentu |
| `AnimationController.addListener(() => setState(() {}))` | `AnimatedBuilder(animation, child: staticSubtree, builder: ...)` — `child` nie jest rebuildowany; lub `FadeTransition`/`SlideTransition` (bez rebuildu, tylko repaint) |
| `EdgeInsets.all(8)`, `TextStyle(...)`, `BoxDecoration(...)` w `build` | `const` / `static final` — `const` widget jest pomijany przez `identical()` i nigdy nie alokuje |
| `widget.items.map((e) => Tile(e)).toList()` w `build` | `ListView.builder`/`SliverList` z `itemBuilder`, `itemExtent` lub `prototypeItem` |
| lambdy przechwytujące `this` w `build` | metody instancji (`onPressed: _handleTap`) |
| `MediaQuery.of(context)` w wielu miejscach (rebuild przy każdej zmianie) | `MediaQuery.sizeOf(context)`/`paddingOf` (zależność tylko od jednego aspektu) |

Zasada: rebuild poddrzewa = alokacja wszystkich jego `Widget`-ów (krótkożyjące obiekty → scavenge). Im niżej `setState`, tym mniej śmieci.

## 3. UI thread: layout i paint

- `RepaintBoundary` wokół rzeczy animujących się **niezależnie** od reszty (i wokół statycznej, drogiej reszty, gdy sąsiad animuje). Za dużo granic = za dużo warstw/tekstur; sprawdź `debugRepaintRainbowEnabled`.
- `CustomPainter`: `shouldRepaint` zwraca `true` tylko gdy dane się zmieniły; `super(repaint: listenable)` zamiast `setState` — repaint bez rebuildu.
- `IntrinsicHeight/Width`, `Wrap`, zagnieżdżone `Flexible` z `mainAxisSize.min` → wielokrotne przebiegi layoutu; `ListView` z `shrinkWrap: true` w `Column` → layout całej listy.
- `Text` w pętli → `TextPainter` layout jest drogi; w `CustomPainter` cache'uj `TextPainter`/`ui.Paragraph` dla stałych napisów.

### Painter zero-alloc (SoA + raw API)

```dart
class ParticlePainter extends CustomPainter {
  ParticlePainter(this.xy, Listenable tick) : super(repaint: tick);
  final Float32List xy;                                   // [x0,y0,x1,y1,...] aktualizowane w miejscu
  static final _paint = Paint()..color = const Color(0xFFFFFFFF)..strokeWidth = 2..strokeCap = StrokeCap.round;
  @override void paint(Canvas c, Size s) => c.drawRawPoints(PointMode.points, xy, _paint);   // 1 wywołanie, 0 Offsetów
  @override bool shouldRepaint(ParticlePainter old) => !identical(old.xy, xy);
}
```

Raw API przyjmujące typed data: `drawRawPoints(Float32List)`, `drawRawAtlas(Image, Float32List rstTransforms, Float32List rects, Int32List? colors, ...)`, `drawVertices(Vertices.raw(mode, Float32List positions, ...))`, `Path.addPolygon` (lista `Offset`, ale raz). Dla tysięcy sprite'ów `drawRawAtlas` jest jedynym rozsądnym wyborem.

Pełna kontrola: `LeafRenderObjectWidget` + `RenderBox` (`sizedByParent = true`, `computeDryLayout`, `markNeedsPaint()` z `Ticker`) — layout raz, paint co klatkę, stan w typed data.

## 4. Raster thread

- `Opacity` widget = `saveLayer` (offscreen render target). Zamień: `Opacity` na liściu, `FadeTransition` na `RepaintBoundary`, `Image(opacity:)`, kolor z alfą w `Paint`/`Container(color:)`.
- `ClipRRect`/`ClipPath`/`ClipOval` z `Clip.antiAlias(WithSaveLayer)` na animowanych elementach → `Clip.hardEdge` lub `DecoratedBox(borderRadius)`; unikaj klipowania przezroczystych warstw.
- `BackdropFilter`, `ImageFilter.blur`, `ShaderMask` → drogie zawsze; ogranicz obszar `RepaintBoundary`, cache'uj statyczne tło jako `ui.Image` (`PictureRecorder` → `toImage`).
- Obrazy: `Image.network(url, cacheWidth: w, cacheHeight: h)` — dekoduj do rozmiaru wyświetlania (4000×3000 → 48 MB tekstury). `ImageCache` liczy pamięć GPU, nie stertę Darta.
- Impeller prekompiluje shadery (koniec „first-frame shader jank”), ale nie zmniejsza kosztu `saveLayer` ani liczby warstw.
- Gradienty/cienie na dużych powierzchniach: `BoxShadow` z dużym `blurRadius` na każdej karcie listy → zastąp jednym obrazem/`DecorationImage` lub zmniejsz blur.

## 5. Listy i scroll

- `ListView.builder`/`GridView.builder`, `itemExtent` lub `prototypeItem` (layout bez mierzenia), `cacheExtent` dobrany do prędkości scrolla.
- `addAutomaticKeepAlives: false`, `addRepaintBoundaries: false` gdy elementy są tanie i statyczne (granica per element kosztuje więcej, niż daje); zostaw `true`, gdy elementy animują się niezależnie.
- `AutomaticKeepAlive`/`KeepAlive` tylko dla elementów z kosztownym stanem.
- Slivers zamiast zagnieżdżonych scrolli; `SliverFixedExtentList` dla stałej wysokości.

## 6. Animacje: Ticker bez setState

```dart
// 🐢 controller.addListener(() => setState(() {}));           // rebuild drzewa 120×/s
// 🚀 AnimatedBuilder(animation: controller, child: heavyStatic, builder: (_, child) => Transform.translate(offset: ..., child: child));
// 🚀🚀 RenderObject z Ticker -> markNeedsPaint(); dane w Float32List; drawRawPoints/drawRawAtlas
```

Implicit animations (`AnimatedContainer`) są wygodne, ale rebuildują; dla 60+ elementów użyj explicit `*Transition` z `RepaintBoundary`.

## 7. Format odpowiedzi przy review

Dla każdego znaleziska: `plik:linia — co się dzieje co klatkę — poprawka (kod) — jak zobaczyć w DevTools`. Oddziel UI-thread od Raster-thread. Jeśli nie da się stwierdzić bez profilu — napisz, jaki pomiar zrobić (sekcja 1), zamiast zgadywać.

## 8. Checklista PR

- [ ] zero alokacji w `paint()`/`Ticker` (DevTools Allocation tracing płaskie przez 10 s animacji)
- [ ] `const` gdzie się da; `setState` w najmniejszym widgecie; `child:` w builderach
- [ ] `RepaintBoundary` wokół niezależnych animacji (i tylko tam)
- [ ] brak `Opacity`/`ClipPath`/`BackdropFilter` na animujących się dużych powierzchniach
- [ ] listy: `.builder` + `itemExtent`/`prototypeItem`
- [ ] obrazy z `cacheWidth/Height`
- [ ] profil `--profile` przed/po dołączony do PR (p90 czasu klatki UI i Raster)
