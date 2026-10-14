/// Sekcja 3 przewodnika: koszt komunikacji między izolatami.
///
/// `SendPort.send(obj)` kopiuje głęboko cały graf obiektów (poza niezmiennymi
/// i kilkoma wyjątkami). Dla `List<Map<String, Object>>` z 10k elementów to
/// dziesiątki tysięcy alokacji po stronie odbiorcy + przejście grafu po
/// stronie nadawcy. Alternatywy:
///  * wysłać `Uint8List` (jedna płaska kopia memcpy),
///  * `TransferableTypedData.fromList([...])` -> `materialize()`:
///    przeniesienie własności bufora bez kopii (O(1)),
///  * `Isolate.run` (Dart 2.19+): wynik funkcji jest *przenoszony*, nie
///    kopiowany, jeśli to możliwe — ale sam spawn izolatu kosztuje ~ms.
///
/// Benchmark mierzy: główny izolat -> worker (pełny payload) -> ack (int).
///
/// UWAGA: `TransferableTypedData.fromList` *kopiuje* dane do bufora
/// natywnego (jedna memcpy po stronie nadawcy). Zero-copy jest sam transfer
/// przez port i `materialize()` po stronie odbiorcy; odbiorca nie alokuje
/// i jego GC nie widzi dużego obiektu, dopóki nie zmaterializuje.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../harness.dart';

const _n = 10_000;

final List<Map<String, Object>> _objects = List.generate(
  _n,
  (i) => {
    'id': i,
    'name': 'item $i',
    'score': i * 0.5,
    'tags': ['a', 'b']
  },
);

// Te same dane spłaszczone: id (int32) + score (float64) per rekord.
final Uint8List _flat = () {
  final bd = ByteData(_n * 12);
  for (var i = 0; i < _n; i++) {
    bd.setInt32(i * 12, i, Endian.little);
    bd.setFloat64(i * 12 + 4, i * 0.5, Endian.little);
  }
  return bd.buffer.asUint8List();
}();

late SendPort _worker;
late ReceivePort _inbox;
late StreamIterator<Object?> _replies;

void _workerMain(SendPort reply) {
  final port = ReceivePort();
  reply.send(port.sendPort);
  port.listen((msg) {
    // Worker "konsumuje" dane i odsyła tylko mały ack (int), żeby mierzyć
    // koszt JEDNEGO przesłania w stronę workera, nie dwóch.
    if (msg is TransferableTypedData) {
      reply.send(msg.materialize().lengthInBytes);
    } else if (msg is Uint8List) {
      reply.send(msg.length);
    } else if (msg is List) {
      reply.send(msg.length);
    } else {
      reply.send(0);
    }
  });
}

Future<void> setupIsolates() async {
  _inbox = ReceivePort();
  await Isolate.spawn(_workerMain, _inbox.sendPort);
  _replies = StreamIterator(_inbox);
  await _replies.moveNext();
  _worker = _replies.current as SendPort;
}

Future<Object?> _roundTrip(Object msg) async {
  _worker.send(msg);
  await _replies.moveNext();
  return _replies.current;
}

/// Harness jest synchroniczny; tu mierzymy ręcznie N round-tripów async.
Future<List<BenchResult>> runIsolateSuite() async {
  const reps = 20;
  Future<double> measure(Future<Object?> Function() f) async {
    // rozgrzewka
    for (var i = 0; i < 5; i++) {
      await f();
    }
    final samples = <double>[];
    for (var s = 0; s < 5; s++) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < reps; i++) {
        blackHole(await f());
      }
      sw.stop();
      samples.add(sw.elapsedMicroseconds * 1000 / reps);
    }
    samples.sort();
    return samples[samples.length ~/ 2];
  }

  final results = <BenchResult>[];
  BenchResult mk(String name, double ns) => BenchResult(
        suite: 'isolates/round-trip 10k rekordów',
        name: name,
        nsPerOp: ns,
        opsPerSec: 1e9 / ns,
        iterations: reps * 5,
        samplesNsPerOp: [ns],
        rssDeltaBytes: 0,
      );

  final a = await measure(() => _roundTrip(_objects));
  results.add(mk('List<Map> 10k obiektów (deep copy przez port)', a));
  final b = await measure(() => _roundTrip(_flat));
  results.add(mk('Uint8List 120 KB (kopia przez port)', b));
  final c =
      await measure(() => _roundTrip(TransferableTypedData.fromList([_flat])));
  results.add(mk('TransferableTypedData 120 KB (fromList kopia + move)', c));
  // Przy dużych buforach kopia staje się kosztem dominującym, a przeniesienie
  // własności pozostaje O(1): tu widać, gdzie TransferableTypedData się opłaca.
  final big = Uint8List(16 << 20); // 16 MB
  final e = await measure(() => _roundTrip(big));
  results.add(mk('Uint8List 16 MB (kopia przez port)', e));
  final f =
      await measure(() => _roundTrip(TransferableTypedData.fromList([big])));
  results.add(mk('TransferableTypedData 16 MB (fromList kopia + move)', f));
  final d = await measure(() => Isolate.run(() => _n * 2));
  results.add(mk('Isolate.run(() => trivial) — koszt spawn', d));

  print('');
  print('== ${results.first.suite} ==');
  for (final r in results) {
    final sp = results.first.nsPerOp / r.nsPerOp;
    print(
        '  ${r.name.padRight(48)} ${(r.nsPerOp / 1e3).toStringAsFixed(1).padLeft(10)} µs  '
        '${identical(r, results.first) ? '(baseline)' : '${sp.toStringAsFixed(2)}x faster'}');
  }
  return results;
}
