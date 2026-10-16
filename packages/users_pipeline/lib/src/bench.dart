/// Pomiar wariantów pipeline'u na tych samych bajtach. Niezależny od
/// harnessu w `benchmarks/`, bo używa go też aplikacja Flutter.
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'columnar.dart';
import 'model.dart';
import 'pipeline_fast.dart';
import 'pipeline_slow.dart';

class StageTiming {
  final String variant;
  final String stage;
  final double medianMs;
  final double minMs;
  final double maxMs;
  const StageTiming(this.variant, this.stage, this.medianMs, this.minMs, this.maxMs);

  @override
  String toString() =>
      '${variant.padRight(28)} ${stage.padRight(16)} ${medianMs.toStringAsFixed(2).padLeft(9)} ms  '
      '[${minMs.toStringAsFixed(2)} – ${maxMs.toStringAsFixed(2)}]';
}

typedef Progress = void Function(StageTiming t);

/// Mierzy `fn` `samples` razy (po rozgrzewce `warmup`), zwraca medianę/min/max.
StageTiming measure(String variant, String stage, Object? Function() fn,
    {int samples = 7, int warmup = 2}) {
  for (var i = 0; i < warmup; i++) {
    fn();
  }
  final times = <double>[];
  final sw = Stopwatch();
  for (var i = 0; i < samples; i++) {
    sw
      ..reset()
      ..start();
    final r = fn();
    sw.stop();
    _sink = r;
    times.add(sw.elapsedMicroseconds / 1000);
  }
  times.sort();
  return StageTiming(variant, stage, times[times.length ~/ 2], times.first, times.last);
}

Object? _sink;

/// Ostatni wynik zmierzonej funkcji (chroni przed eliminacją martwego kodu).
Object? get lastMeasuredResult => _sink;

/// Pełny zestaw pomiarów CPU na gotowych bajtach (sieć mierzona osobno).
List<StageTiming> runUsersBenchmark(Uint8List bytes,
    {UserQuery? query, int samples = 7, Progress? onResult, bool includeIsolates = true}) {
  final q = query ?? UserQuery.standard;
  final out = <StageTiming>[];
  void add(StageTiming t) {
    out.add(t);
    onResult?.call(t);
  }

  // Dla wariantu 🐢 wejściem jest String (tak zwraca response.body).
  final bodyString = utf8.decode(bytes);

  // --- decode
  add(measure('1 slow: String+jsonDecode+fromJson', 'decode', () => decodeSlow(bodyString), samples: samples));
  add(measure('2 fused+fromJson (obiekty)', 'decode', () => decodeFused(bytes), samples: samples));
  add(measure('3 tree -> kolumny', 'decode', () => tableFromTree(bytes), samples: samples));
  add(measure('4 byte scanner -> kolumny', 'decode', () => decodeColumnar(bytes), samples: samples));

  // --- query (filter + top-N + group-by + encode) na gotowych strukturach
  final users = decodeSlow(bodyString);
  final usersF = decodeFused(bytes);
  final tableTree = tableFromTree(bytes);
  final table = decodeColumnar(bytes);
  add(measure('1 slow: where/sort/map/jsonEncode', 'query+encode', () => querySlow(users, q), samples: samples));
  add(measure('2 pętle + JsonUtf8Encoder', 'query+encode', () => queryObjects(usersF, q), samples: samples));
  add(measure('3 kolumny (z drzewa)', 'query+encode', () => queryColumnar(tableTree, q), samples: samples));
  add(measure('4 kolumny (ze skanera)', 'query+encode', () => queryColumnar(table, q), samples: samples));

  // --- end-to-end: bajty -> wynik
  add(measure('1 slow', 'end-to-end', () => querySlow(decodeSlow(bodyString), q), samples: samples));
  add(measure('2 fused objects', 'end-to-end', () => queryObjects(decodeFused(bytes), q), samples: samples));
  add(measure('4 byte scanner', 'end-to-end', () => queryColumnar(decodeColumnar(bytes), q), samples: samples));
  return out;
}

/// Warianty w izolacie: koszt przeniesienia wyniku do izolatu głównego.
/// 🐢 `Isolate.run` zwraca `List<User>` (10k obiektów przez port = deep copy),
/// 🚀 zwraca `TransferableTypedData` z tabelą kolumnową (jeden bufor, O(1)).
Future<List<StageTiming>> runIsolateBenchmark(Uint8List bytes, {int samples = 5}) async {
  Future<StageTiming> measureAsync(String variant, Future<Object?> Function() fn) async {
    await fn(); // rozgrzewka
    final times = <double>[];
    for (var i = 0; i < samples; i++) {
      final sw = Stopwatch()..start();
      _sink = await fn();
      sw.stop();
      times.add(sw.elapsedMicroseconds / 1000);
    }
    times.sort();
    return StageTiming(variant, 'isolate rt', times[times.length ~/ 2], times.first, times.last);
  }

  final bodyString = utf8.decode(bytes);
  return [
    await measureAsync('1 Isolate.run -> List<User>', () => Isolate.run(() => decodeSlow(bodyString))),
    await measureAsync('2 Isolate.run -> List<User> (fused)', () => Isolate.run(() => decodeFused(bytes))),
    await measureAsync('4 Isolate.run -> Transferable(kolumny)', () async {
      final ttd = await Isolate.run(() {
        final t = decodeColumnar(bytes);
        return TransferableTypedData.fromList([t.packContiguous()]);
      });
      return UserTable.unpack(ttd.materialize());
    }),
  ];
}

/// Sprawdza, że wszystkie warianty dają identyczny wynik (używane w testach
/// i jako "sanity" przed benchmarkiem).
void assertVariantsAgree(Uint8List bytes, {UserQuery? query}) {
  final q = query ?? UserQuery.standard;
  final a = querySlow(decodeSlow(utf8.decode(bytes)), q);
  final b = queryObjects(decodeFused(bytes), q);
  final c = queryColumnar(tableFromTree(bytes), q);
  final d = queryColumnar(decodeColumnar(bytes), q);
  final e = queryColumnar(UserTable.unpack(decodeColumnar(bytes).packContiguous().buffer), q);
  for (final (name, r) in [('fused', b), ('tree->columns', c), ('scanner', d), ('packed', e)]) {
    if (r.topNames.join('|') != a.topNames.join('|')) {
      throw StateError('$name: topNames differ\n${a.topNames.take(5)}\n${r.topNames.take(5)}');
    }
    if (r.activePerCountry.toString() != a.activePerCountry.toString()) {
      throw StateError('$name: activePerCountry differ');
    }
  }
  // Encoded: warianty 1/2 serializują pełny toJson() (tags, address), wariant
  // kolumnowy — pola płaskie + tagCount. Porównujemy więc wspólne pola po
  // zdekodowaniu, nie bajty.
  final da = jsonDecode(utf8.decode(a.encoded)) as List;
  final dd = jsonDecode(utf8.decode(d.encoded)) as List;
  if (da.length != dd.length) throw StateError('encoded length differs');
  for (var i = 0; i < da.length; i++) {
    final x = da[i] as Map, y = dd[i] as Map;
    for (final k in ['id', 'username', 'email', 'firstName', 'lastName', 'age', 'country', 'city', 'isActive', 'premium', 'score', 'balance', 'createdAt']) {
      if (x[k] != y[k]) throw StateError('encoded[$i].$k differs: ${x[k]} vs ${y[k]}');
    }
    if ((x['tags'] as List).length != y['tagCount']) throw StateError('tagCount differs');
  }
}
