---
name: flutter-render-perf
description: Diagnozowanie i naprawianie janku we Flutterze - rebuildy (const, setState nisko, ListenableBuilder z child), RepaintBoundary, CustomPainter/RenderObject z typed data i drawRawPoints/drawRawAtlas, saveLayer (Opacity, Clip), listy (builder, itemExtent), obrazy (cacheWidth), Impeller, workflow DevTools (--profile, Track rebuilds/paints, Allocation tracing), pomiar janku w aplikacji przez addTimingsCallback. Użyj, gdy użytkownik zgłasza jank, gubione klatki, długie klatki UI/Raster, wysokie zużycie pamięci GPU, albo pyta, jak zoptymalizować widget/animację/listę.
---

> 🇵🇱 Wersja polska (referencyjna; aktywny plik skilla to angielski `SKILL.md` w tym katalogu). Samowystarczalna: działa w dowolnym projekcie Flutter.

# flutter-render-perf — klatka w 8.3 ms

Model: wątek UI (Dart: build → layout → paint → compositing) + wątek Raster (Impeller → GPU). Każdy ma własny budżet 16.6 ms (60 Hz) / 8.3 ms (120 Hz). Najpierw ustal, **który** wątek przekracza budżet — traktuje się je inaczej.

## 1. Diagnoza (zawsze `flutter run --profile` na urządzeniu)

1. DevTools → **Performance**: wykres klatek. Czerwone słupki na UI → Dart; na Raster → GPU/shadery/warstwy.
2. Włącz **Track widget rebuilds**, **Track layouts**, **Track paints** → widgety z setkami rebuildów/s i painty poza granicami.
3. **Memory → Allocation tracing** podczas animacji: które klasy są alokowane co klatkę (`Offset`, `Paint`, `_GrowableList`, `TextStyle`, twoje modele). Wykres heapu w kształcie zębów piły = scavenge; cel to płaska linia.
4. Timeline: zdarzenia `GC` tuż przed długą klatką = alokacje w pętli klatki.
5. `flutter run --profile --trace-skia` / Impeller: `--enable-impeller`, overlaye `debugPaintLayerBordersEnabled`, `debugRepaintRainbowEnabled` (repainty), `checkerboardOffscreenLayers` (saveLayer).
6. Pomiar w aplikacji wokół operacji (wrzuć do dowolnej aplikacji):

```dart
class JankMeter {
  int frames = 0, jank = 0; double worstMs = 0; bool _on = false;
  void _cb(List<FrameTiming> timings) {
    if (!_on) return;
    for (final t in timings) {
      final ms = t.totalSpan.inMicroseconds / 1000;
      frames++; if (ms > 16.7) jank++; if (ms > worstMs) worstMs = ms;
    }
  }
  void start() { frames = 0; jank = 0; worstMs = 0; if (!_on) { _on = true; SchedulerBinding.instance.addTimingsCallback(_cb); } }
  void stop()  { if (_on) { _on = false; SchedulerBinding.instance.removeTimingsCallback(_cb); } }
}
// meter.start(); await doWork(); meter.stop(); print('${meter.jank} janky frames, worst ${meter.worstMs} ms');
```

## 2. Wątek UI: rebuildy

| 🐢 | 🚀 |
|---|---|
| `setState` w widgecie ekranu | `setState` w najmniejszym `StatefulWidget`; `ValueListenableBuilder`/`ListenableBuilder` wokół fragmentu |
| `AnimationController.addListener(() => setState(() {}))` | `AnimatedBuilder(animation, child: staticSubtree, builder: ...)` — `child` nie jest przebudowywany; albo `FadeTransition`/`SlideTransition` (bez rebuildu, tylko repaint) |
| `EdgeInsets.all(8)`, `TextStyle(...)`, `BoxDecoration(...)` w `build` | `const` / `static final` — widget `const` jest pomijany przez `identical()` i nigdy nie alokuje |
| `widget.items.map((e) => Tile(e)).toList()` w `build` | `ListView.builder`/`SliverList` z `itemBuilder`, `itemExtent` lub `prototypeItem` |
| lambdy przechwytujące `this` w `build` | metody instancji (`onPressed: _handleTap`) |
| `MediaQuery.of(context)` w wielu miejscach (rebuild przy każdej zmianie) | `MediaQuery.sizeOf(context)`/`paddingOf` (zależność tylko od jednego aspektu) |
| filtrowanie listy 10k przez `where().toList()` + `setState` przy każdym naciśnięciu klawisza | `Int32List` pasujących indeksów w `ValueNotifier`; przebudowuje się tylko `ListView.builder` |

Zasada: rebuild poddrzewa = alokacja wszystkich jego `Widget`ów (krótko żyjące obiekty → scavenge). Im niżej `setState`, tym mniej śmieci.

## 3. Wątek UI: layout i paint

- `RepaintBoundary` wokół rzeczy, które animują się **niezależnie** od reszty (oraz wokół statycznej, kosztownej reszty, gdy animuje się rodzeństwo). Za dużo granic = za dużo warstw/tekstur; sprawdź przez `debugRepaintRainbowEnabled`.
- `CustomPainter`: `shouldRepaint` zwraca `true` tylko gdy dane się zmieniły; `super(repaint: listenable)` zamiast `setState` — repaint bez rebuildu.
- `IntrinsicHeight/Width`, `Wrap`, zagnieżdżone `Flexible` z `mainAxisSize.min` → wielokrotne przebiegi layoutu; `ListView` z `shrinkWrap: true` wewnątrz `Column` → layout całej listy.
- `Text` w pętli → layout `TextPainter` jest kosztowny; w `CustomPainter` cache'uj `TextPainter`/`ui.Paragraph` per stała etykieta (`putIfAbsent`).

### Painter zero-alloc (SoA + surowe API)

```dart
class ParticlePainter extends CustomPainter {
  ParticlePainter(this.xy, Listenable tick) : super(repaint: tick);
  final Float32List xy;                                   // [x0,y0,x1,y1,...] aktualizowane w miejscu
  static final _paint = Paint()..color = const Color(0xFFFFFFFF)..strokeWidth = 2..strokeCap = StrokeCap.round;
  @override void paint(Canvas c, Size s) => c.drawRawPoints(PointMode.points, xy, _paint);   // 1 wywołanie, 0 Offsetów
  @override bool shouldRepaint(ParticlePainter old) => !identical(old.xy, xy);
}
```

Surowe API przyjmujące typed data: `drawRawPoints(Float32List)`, `drawRawAtlas(Image, Float32List rstTransforms, Float32List rects, Int32List? colors, ...)`, `drawVertices(Vertices.raw(mode, Float32List positions, ...))`. Dla tysięcy sprite'ów `drawRawAtlas` to jedyny sensowny wybór (RSTransform = `[scos, ssin, tx, ty]` per sprite, aktualizowane w miejscu).

### Pełna kontrola: `RenderBox` sterowany `Ticker`em (layout raz, paint co klatkę)

```dart
class _RenderParticles extends RenderBox {
  _RenderParticles(this._store) { _ticker = Ticker(_tick)..start(); }   // w produkcji przekaż vsync z SingleTickerProviderStateMixin
  ParticleStore _store; late final Ticker _ticker; Duration _last = Duration.zero;
  void _tick(Duration now) { final dt = (now - _last).inMicroseconds / 1e6; _last = now; _store.step(dt, size); markNeedsPaint(); }
  @override bool get sizedByParent => true;
  @override Size computeDryLayout(BoxConstraints c) => c.biggest;
  @override bool get isRepaintBoundary => true;
  @override void paint(PaintingContext ctx, Offset offset) {
    ctx.canvas..save()..translate(offset.dx, offset.dy)..drawRawPoints(PointMode.points, _store.xy, _paint)..restore();
  }
  @override void detach() { _ticker.stop(); super.detach(); }
  @override void attach(PipelineOwner owner) { super.attach(owner); if (!_ticker.isActive) _ticker.start(); }
  @override void dispose() { _ticker.dispose(); super.dispose(); }
}
```

## 4. Wątek Raster

- Widget `Opacity` = `saveLayer` (offscreen render target). Zamień: `Opacity` na liściu, `FadeTransition` na `RepaintBoundary`, `Image(opacity:)`, kolor z alfą w `Paint`/`Container(color:)`.
- `ClipRRect`/`ClipPath`/`ClipOval` z `Clip.antiAlias(WithSaveLayer)` na animowanych elementach → `Clip.hardEdge` albo `DecoratedBox(borderRadius)`; unikaj przycinania przezroczystych warstw.
- `BackdropFilter`, `ImageFilter.blur`, `ShaderMask` → zawsze kosztowne; ogranicz obszar `RepaintBoundary`, cache'uj statyczne tło jako `ui.Image` (`PictureRecorder` → `toImage`).
- Obrazy: `Image.network(url, cacheWidth: w, cacheHeight: h)` — dekoduj do rozmiaru wyświetlania (4000×3000 → tekstura 48 MB). `ImageCache` liczy pamięć GPU, nie heap Darta.
- Impeller prekompiluje shadery (koniec z "first-frame shader jank"), ale nie zmniejsza kosztu `saveLayer` ani liczby warstw.
- Gradienty/cienie na dużych powierzchniach: `BoxShadow` z dużym `blurRadius` na każdej karcie listy → zamień na jeden obraz/`DecorationImage` albo zmniejsz blur.

## 5. Listy i scrollowanie

- `ListView.builder`/`GridView.builder`, `itemExtent` lub `prototypeItem` (layout bez mierzenia), `cacheExtent` dopasowany do prędkości scrollowania.
- `addAutomaticKeepAlives: false`, `addRepaintBoundaries: false`, gdy elementy są tanie i statyczne (granica per element kosztuje więcej, niż oszczędza); zostaw `true`, gdy elementy animują się niezależnie.
- `AutomaticKeepAlive`/`KeepAlive` tylko dla elementów z kosztownym stanem.
- Slivery zamiast zagnieżdżonych scrolli; `SliverFixedExtentList` dla stałej wysokości.
- Dane dla długich list: model kolumnowy z leniwym dekodowaniem per wiersz (stringi jako offsety w payloadzie) zamiast tysięcy obiektów modelu z `DateTime`; nigdy nie parsuj całego payloadu do modeli w wątku UI (skill `dart-isolates`).

## 6. Animacje: Ticker bez setState

```dart
// 🐢 controller.addListener(() => setState(() {}));           // przebudowuje drzewo 120×/s
// 🚀 AnimatedBuilder(animation: controller, child: heavyStatic, builder: (_, child) => Transform.translate(offset: ..., child: child));
// 🚀🚀 RenderObject z Tickerem -> markNeedsPaint(); dane w Float32List; drawRawPoints/drawRawAtlas
```

Animacje implicit (`AnimatedContainer`) są wygodne, ale przebudowują; dla 60+ elementów używaj explicit `*Transition` z `RepaintBoundary`. Strumienie z sensorów/websocketów → ring buffer w `Float64List` i jeden repaint per klatka przez `Listenable`, nie `setState` per próbka.

## 7. Format odpowiedzi dla review

Dla każdego znaleziska: `plik:linia — co dzieje się co klatkę — poprawka (kod) — jak to zobaczyć w DevTools`. Oddziel znaleziska wątku UI od wątku Raster. Jeśli nie da się ustalić bez profilu — powiedz, jaki pomiar wykonać (sekcja 1), zamiast zgadywać.

## 8. Checklista PR

- [ ] zero alokacji w `paint()`/`Ticker` (DevTools Allocation tracing płasko przez 10 s animacji)
- [ ] `const` gdzie tylko się da; `setState` w najmniejszym widgecie; `child:` w builderach
- [ ] `RepaintBoundary` wokół niezależnych animacji (i tylko tam)
- [ ] brak `Opacity`/`ClipPath`/`BackdropFilter` na animujących się dużych powierzchniach
- [ ] listy: `.builder` + `itemExtent`/`prototypeItem`
- [ ] obrazy z `cacheWidth/Height`
- [ ] `--profile` przed/po dołączony do PR (czasy klatek p90 UI i Raster)

Lektura uzupełniająca z uruchamialnymi benchmarkami: https://github.com/Thioby/dart-performance
