/// Minimalny harness benchmarkowy w stylu `benchmark_harness`, ale z:
///  * rozgrzewką (JIT potrzebuje jej, AOT nie, ale wyrównujemy warunki),
///  * wieloma próbami i medianą (odporność na GC i szum systemu),
///  * raportem ns/op oraz względnym przyspieszeniem "baseline vs optimized",
///  * opcjonalnym pomiarem RSS i liczby bajtów zaalokowanych przez VM
///    (`--observe` nie jest wymagane: używamy `dart:developer` + ProcessInfo).
///
/// Użycie:
/// ```dart
/// final suite = Suite('json');
/// suite.add('jsonEncode + utf8.encode', () => ...);
/// suite.add('JsonUtf8Encoder', () => ...);
/// suite.run();
/// ```
library;

import 'dart:io';
import 'dart:math' as math;

typedef BenchFn = void Function();

class BenchResult {
  final String suite;
  final String name;
  final double nsPerOp;
  final double opsPerSec;
  final int iterations;
  final List<double> samplesNsPerOp;
  final int rssDeltaBytes;

  BenchResult({
    required this.suite,
    required this.name,
    required this.nsPerOp,
    required this.opsPerSec,
    required this.iterations,
    required this.samplesNsPerOp,
    required this.rssDeltaBytes,
  });

  Map<String, Object?> toJson() => {
        'suite': suite,
        'name': name,
        'ns_per_op': nsPerOp,
        'ops_per_sec': opsPerSec,
        'iterations': iterations,
        'samples_ns_per_op': samplesNsPerOp,
        'rss_delta_bytes': rssDeltaBytes,
      };
}

class _Case {
  final String name;
  final BenchFn fn;
  final BenchFn? setup;
  _Case(this.name, this.fn, this.setup);
}

class Suite {
  final String name;
  final List<_Case> _cases = [];

  /// Minimalny czas jednej próby (ms). Większy = stabilniej, wolniej.
  final int sampleMillis;

  /// Liczba prób, z których bierzemy medianę.
  final int samples;

  Suite(this.name, {this.sampleMillis = 300, this.samples = 7});

  void add(String caseName, BenchFn fn, {BenchFn? setup}) {
    _cases.add(_Case(caseName, fn, setup));
  }

  List<BenchResult> run({bool quiet = false}) {
    final results = <BenchResult>[];
    if (!quiet) {
      stdout.writeln('');
      stdout.writeln('== $name ==');
    }
    for (final c in _cases) {
      c.setup?.call();
      final r = _measure(c);
      results.add(r);
      if (!quiet) {
        stdout.writeln(_fmtRow(r, results.first));
      }
    }
    return results;
  }

  BenchResult _measure(_Case c) {
    // Rozgrzewka: ~100 ms. Dla JIT-a to czas na optymalizację gorących funkcji;
    // dla AOT wyrównuje stan cache/pamięci.
    final warm = Stopwatch()..start();
    var warmIters = 0;
    while (warm.elapsedMilliseconds < 100) {
      c.fn();
      warmIters++;
    }
    // Dobór liczby iteracji na próbę tak, by próba trwała ~sampleMillis.
    final nsPerWarmOp =
        warm.elapsedMicroseconds * 1000 / math.max(1, warmIters);
    var iters = (sampleMillis * 1e6 / math.max(1, nsPerWarmOp)).round();
    iters = iters.clamp(1, 1 << 30);

    final rssBefore = ProcessInfo.currentRss;
    final sw = Stopwatch();
    final sampleNs = <double>[];
    for (var s = 0; s < samples; s++) {
      sw
        ..reset()
        ..start();
      for (var i = 0; i < iters; i++) {
        c.fn();
      }
      sw.stop();
      sampleNs.add(sw.elapsedMicroseconds * 1000 / iters);
    }
    final rssAfter = ProcessInfo.currentRss;
    sampleNs.sort();
    final median = sampleNs[sampleNs.length ~/ 2];
    return BenchResult(
      suite: name,
      name: c.name,
      nsPerOp: median,
      opsPerSec: median == 0 ? double.infinity : 1e9 / median,
      iterations: iters * samples,
      samplesNsPerOp: sampleNs,
      rssDeltaBytes: rssAfter - rssBefore,
    );
  }

  static String _fmtRow(BenchResult r, BenchResult baseline) {
    final speedup = baseline.nsPerOp / r.nsPerOp;
    final tag = identical(r, baseline)
        ? '(baseline)'
        : '${speedup.toStringAsFixed(2)}x ${speedup >= 1 ? 'faster' : 'SLOWER'}';
    final min = r.samplesNsPerOp.first;
    final max = r.samplesNsPerOp.last;
    return '  ${r.name.padRight(48)} '
        '${_ns(r.nsPerOp).padLeft(12)}  '
        '[min ${_ns(min)}, max ${_ns(max)}]  '
        '$tag';
  }

  static String _ns(double ns) {
    if (ns < 1e3) return '${ns.toStringAsFixed(1)} ns';
    if (ns < 1e6) return '${(ns / 1e3).toStringAsFixed(2)} µs';
    if (ns < 1e9) return '${(ns / 1e6).toStringAsFixed(2)} ms';
    return '${(ns / 1e9).toStringAsFixed(2)} s';
  }
}

/// Zapobiega wyeliminowaniu wyniku przez optymalizator (dead code elimination).
/// Odpowiednik `std::hint::black_box` z Rusta.
@pragma('vm:never-inline')
void blackHole(Object? value) {
  _sink = value;
}

Object? _sink;

/// Pozwala odczytać wartość pochłoniętą przez [blackHole] (np. w testach).
Object? get lastBlackHoleValue => _sink;

/// Wypisuje tabelę Markdown z wyników (do RESULTS.md).
String toMarkdown(List<BenchResult> results) {
  final sb = StringBuffer();
  String? current;
  BenchResult? baseline;
  for (final r in results) {
    if (r.suite != current) {
      current = r.suite;
      baseline = r;
      sb.writeln();
      sb.writeln('### ${r.suite}');
      sb.writeln();
      sb.writeln('| Wariant | ns/op | ops/s | vs baseline |');
      sb.writeln('|---|---:|---:|---:|');
    }
    final speed = baseline!.nsPerOp / r.nsPerOp;
    sb.writeln('| ${r.name} | ${Suite._ns(r.nsPerOp)} | '
        '${r.opsPerSec.toStringAsFixed(0)} | '
        '${identical(r, baseline) ? '1.00x' : '${speed.toStringAsFixed(2)}x'} |');
  }
  return sb.toString();
}
