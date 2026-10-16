/// Measures the pipeline variants on the same bytes. Independent of the
/// harness in `benchmarks/`, because the Flutter app uses it too.
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
  const StageTiming(
      this.variant, this.stage, this.medianMs, this.minMs, this.maxMs);

  @override
  String toString() =>
      '${variant.padRight(28)} ${stage.padRight(16)} ${medianMs.toStringAsFixed(2).padLeft(9)} ms  '
      '[${minMs.toStringAsFixed(2)} – ${maxMs.toStringAsFixed(2)}]';
}

typedef Progress = void Function(StageTiming t);

/// Measures `fn` `samples` times (after `warmup` warm-up runs), returns median/min/max.
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
  return StageTiming(
      variant, stage, times[times.length ~/ 2], times.first, times.last);
}

Object? _sink;

/// Last result of the measured function (guards against dead-code elimination).
Object? get lastMeasuredResult => _sink;

/// Full set of CPU measurements on ready bytes (network measured separately).
List<StageTiming> runUsersBenchmark(Uint8List bytes,
    {UserQuery? query,
    int samples = 7,
    Progress? onResult,
    bool includeIsolates = true}) {
  final q = query ?? UserQuery.standard;
  final out = <StageTiming>[];
  void add(StageTiming t) {
    out.add(t);
    onResult?.call(t);
  }

  // For the 🐢 variant the input is a String (that is what response.body returns).
  final bodyString = utf8.decode(bytes);

  // --- decode
  add(measure('1 slow: String+jsonDecode+fromJson', 'decode',
      () => decodeSlow(bodyString),
      samples: samples));
  add(measure('2 fused+fromJson (objects)', 'decode', () => decodeFused(bytes),
      samples: samples));
  add(measure('3 tree -> columns', 'decode', () => tableFromTree(bytes),
      samples: samples));
  add(measure(
      '4 byte scanner -> columns', 'decode', () => decodeColumnar(bytes),
      samples: samples));

  // --- query (filter + top-N + group-by + encode) on ready-made structures
  final users = decodeSlow(bodyString);
  final usersF = decodeFused(bytes);
  final tableTree = tableFromTree(bytes);
  final table = decodeColumnar(bytes);
  add(measure('1 slow: where/sort/map/jsonEncode', 'query+encode',
      () => querySlow(users, q),
      samples: samples));
  add(measure('2 loops + JsonUtf8Encoder', 'query+encode',
      () => queryObjects(usersF, q),
      samples: samples));
  add(measure('3 columns (from tree)', 'query+encode',
      () => queryColumnar(tableTree, q),
      samples: samples));
  add(measure(
      '4 columns (from scanner)', 'query+encode', () => queryColumnar(table, q),
      samples: samples));

  // --- end-to-end: bytes -> result
  add(measure(
      '1 slow', 'end-to-end', () => querySlow(decodeSlow(bodyString), q),
      samples: samples));
  add(measure('2 fused objects', 'end-to-end',
      () => queryObjects(decodeFused(bytes), q),
      samples: samples));
  add(measure('4 byte scanner', 'end-to-end',
      () => queryColumnar(decodeColumnar(bytes), q),
      samples: samples));
  return out;
}

/// Variants in an isolate: the cost of moving the result to the main isolate.
/// 🐢 `Isolate.run` returns `List<User>` (10k objects through a port = deep copy),
/// 🚀 returns `TransferableTypedData` with the columnar table (one buffer, O(1)).
Future<List<StageTiming>> runIsolateBenchmark(Uint8List bytes,
    {int samples = 5}) async {
  Future<StageTiming> measureAsync(
      String variant, Future<Object?> Function() fn) async {
    await fn(); // warm-up
    final times = <double>[];
    for (var i = 0; i < samples; i++) {
      final sw = Stopwatch()..start();
      _sink = await fn();
      sw.stop();
      times.add(sw.elapsedMicroseconds / 1000);
    }
    times.sort();
    return StageTiming(variant, 'isolate rt', times[times.length ~/ 2],
        times.first, times.last);
  }

  final bodyString = utf8.decode(bytes);
  return [
    await measureAsync('1 Isolate.run -> List<User>',
        () => Isolate.run(() => decodeSlow(bodyString))),
    await measureAsync('2 Isolate.run -> List<User> (fused)',
        () => Isolate.run(() => decodeFused(bytes))),
    await measureAsync('4 Isolate.run -> Transferable(columns)', () async {
      final ttd = await Isolate.run(() {
        final t = decodeColumnar(bytes);
        return TransferableTypedData.fromList([t.packContiguous()]);
      });
      return UserTable.unpack(ttd.materialize());
    }),
  ];
}

/// Checks that all variants produce an identical result (used in tests
/// and as a "sanity" check before the benchmark).
void assertVariantsAgree(Uint8List bytes, {UserQuery? query}) {
  final q = query ?? UserQuery.standard;
  final a = querySlow(decodeSlow(utf8.decode(bytes)), q);
  final b = queryObjects(decodeFused(bytes), q);
  final c = queryColumnar(tableFromTree(bytes), q);
  final d = queryColumnar(decodeColumnar(bytes), q);
  final e = queryColumnar(
      UserTable.unpack(decodeColumnar(bytes).packContiguous().buffer), q);
  for (final (name, r) in [
    ('fused', b),
    ('tree->columns', c),
    ('scanner', d),
    ('packed', e)
  ]) {
    if (r.topNames.join('|') != a.topNames.join('|')) {
      throw StateError(
          '$name: topNames differ\n${a.topNames.take(5)}\n${r.topNames.take(5)}');
    }
    if (r.activePerCountry.toString() != a.activePerCountry.toString()) {
      throw StateError('$name: activePerCountry differ');
    }
  }
  // Encoded: variants 1/2 serialize the full toJson() (tags, address), the
  // columnar variant — flat fields + tagCount. So we compare the common fields
  // after decoding, not the bytes.
  final da = jsonDecode(utf8.decode(a.encoded)) as List;
  final dd = jsonDecode(utf8.decode(d.encoded)) as List;
  if (da.length != dd.length) throw StateError('encoded length differs');
  for (var i = 0; i < da.length; i++) {
    final x = da[i] as Map, y = dd[i] as Map;
    for (final k in [
      'id',
      'username',
      'email',
      'firstName',
      'lastName',
      'age',
      'country',
      'city',
      'isActive',
      'premium',
      'score',
      'balance',
      'createdAt'
    ]) {
      if (x[k] != y[k]) {
        throw StateError('encoded[$i].$k differs: ${x[k]} vs ${y[k]}');
      }
    }
    if ((x['tags'] as List).length != y['tagCount']) {
      throw StateError('tagCount differs');
    }
  }
}
