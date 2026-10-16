/// Guide section 3: the cost of communication between isolates.
///
/// `SendPort.send(obj)` deep-copies the whole object graph (except immutable
/// objects and a few exceptions). For a `List<Map<String, Object>>` with 10k
/// elements that is tens of thousands of allocations on the receiver side +
/// a graph traversal on the sender side. Alternatives:
///  * send a `Uint8List` (a single flat memcpy copy),
///  * `TransferableTypedData.fromList([...])` -> `materialize()`:
///    transfer of buffer ownership with no copy (O(1)),
///  * `Isolate.run` (Dart 2.19+): the function result is *moved*, not
///    copied, when possible — but spawning the isolate itself costs ~ms.
///
/// The benchmark measures: main isolate -> worker (full payload) -> ack (int).
///
/// NOTE: `TransferableTypedData.fromList` *copies* the data into a native
/// buffer (one memcpy on the sender side). Only the transfer itself through
/// the port and `materialize()` on the receiver side are zero-copy; the
/// receiver does not allocate and its GC does not see the large object until
/// it materializes.
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

// The same data flattened: id (int32) + score (float64) per record.
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
    // The worker "consumes" the data and sends back only a small ack (int),
    // to measure the cost of ONE transfer towards the worker, not two.
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

/// The harness is synchronous; here we time N async round-trips by hand.
Future<List<BenchResult>> runIsolateSuite() async {
  const reps = 20;
  Future<double> measure(Future<Object?> Function() f) async {
    // warm-up
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
        suite: 'isolates/round-trip 10k records',
        name: name,
        nsPerOp: ns,
        opsPerSec: 1e9 / ns,
        iterations: reps * 5,
        samplesNsPerOp: [ns],
        rssDeltaBytes: 0,
      );

  final a = await measure(() => _roundTrip(_objects));
  results.add(mk('List<Map> 10k objects (deep copy via port)', a));
  final b = await measure(() => _roundTrip(_flat));
  results.add(mk('Uint8List 120 KB (copy via port)', b));
  final c =
      await measure(() => _roundTrip(TransferableTypedData.fromList([_flat])));
  results.add(mk('TransferableTypedData 120 KB (fromList copy + move)', c));
  // With large buffers the copy becomes the dominant cost, while transferring
  // ownership stays O(1): this is where TransferableTypedData pays off.
  final big = Uint8List(16 << 20); // 16 MB
  final e = await measure(() => _roundTrip(big));
  results.add(mk('Uint8List 16 MB (copy via port)', e));
  final f =
      await measure(() => _roundTrip(TransferableTypedData.fromList([big])));
  results.add(mk('TransferableTypedData 16 MB (fromList copy + move)', f));
  final d = await measure(() => Isolate.run(() => _n * 2));
  results.add(mk('Isolate.run(() => trivial) — spawn cost', d));

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
