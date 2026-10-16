# flutter_bench — „10k użytkowników z JSON” na urządzeniu

Ta sama logika co w CLI (`packages/users_pipeline`), uruchamiana w aplikacji Flutter z licznikiem janku. Pozwala zobaczyć nie tylko *ile ms* trwa wariant, ale *co robi z UI*: podczas pomiaru kręci się ikona na wątku UI, a tabela zlicza klatki powyżej 16.7 ms.

```bash
cd flutter_bench
flutter pub get
flutter run --profile          # zawsze profile/release: debug ma asercje i JIT
flutter test                   # test widgetowy: wszystkie warianty działają i dają wynik
```

## Co mierzy

| Wariant | Gdzie | Czego się spodziewać |
|---|---|---|
| UI: slow (`String` + `jsonDecode` + `fromJson` + `where`) | wątek UI | kilkadziesiąt–kilkaset ms blokady, animacja staje, duży jank |
| UI: fused + obiekty + pętle | wątek UI | podobnie — koszt to drzewo JSON i 100k obiektów, nie UTF-8 |
| UI: byte scanner → kolumny | wątek UI | ~8× krócej; na szybkim telefonie 1–2 klatki janku |
| `compute()`: slow → `List<User>` | izolat, wynik deep-copy | parsowanie poza UI, ale **odbiór 10k obiektów** znów zatrzymuje UI |
| `Isolate.run`: scanner → `TransferableTypedData` | izolat, wynik O(1) | UI płynne, czas ≈ parsowanie + spawn |
| `Isolate.run`: cały pipeline, wynik = top-100 | izolat | najtańsze: wraca 100 Stringów i mała mapa |

Źródło danych: URL (domyślnie surowy plik z tego repozytorium na GitHubie; wpisz własny gist) albo wbudowany generator (10k użytkowników, deterministyczny, generowany w izolacie).

## Co pokazuje ekran

- **ms** — mediana z 3 powtórzeń wariantu (na urządzeniu; na emulatorze liczby są bez znaczenia).
- **jank** — liczba klatek > 16.7 ms podczas wariantu (`SchedulerBinding.addTimingsCallback`) i najdłuższa klatka.
- **vs 1** — przyspieszenie względem pierwszego wiersza.
- Top-100 nazwisk i liczby aktywnych per kraj — żeby było widać, że warianty liczą to samo (test `assertVariantsAgree` sprawdza to automatycznie).

Zobacz też `docs/dart-flutter-extreme-performance-guide.md` §6 (studium przypadku) i `packages/users_pipeline/README.md`.
