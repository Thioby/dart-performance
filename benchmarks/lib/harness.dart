/// Minimal benchmark harness in the style of `benchmark_harness`, but with:
///  * a warm-up (the JIT needs it, AOT does not, but we level the conditions),
///  * multiple samples and a median (robust against GC and system noise),
///  * a report of ns/op and the relative speedup "baseline vs optimized",
///  * optional measurement of RSS and the number of bytes allocated by the VM
///    (`--observe` is not required: we use `dart:developer` + ProcessInfo).
///
/// Usage:
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

  /// Minimum duration of a single sample (ms). Larger = more stable, slower.
  final int sampleMillis;

  /// Number of samples from which we take the median.
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
    // Warm-up: ~100 ms. For the JIT this is time to optimize hot functions;
    // for AOT it levels the cache/memory state.
    final warm = Stopwatch()..start();
    var warmIters = 0;
    while (warm.elapsedMilliseconds < 100) {
      c.fn();
      warmIters++;
    }
    // Choose iterations per sample so that one sample takes ~sampleMillis.
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

/// Prevents the optimizer from eliminating the result (dead code elimination).
/// Equivalent of Rust's `std::hint::black_box`.
@pragma('vm:never-inline')
void blackHole(Object? value) {
  _sink = value;
}

Object? _sink;

/// Lets you read the value swallowed by [blackHole] (e.g. in tests).
Object? get lastBlackHoleValue => _sink;

/// Prints a Markdown table of the results (for RESULTS.md).
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
      sb.writeln('| Variant | ns/op | ops/s | vs baseline |');
      sb.writeln('|---|---:|---:|---:|');
    }
    final speed = baseline!.nsPerOp / r.nsPerOp;
    sb.writeln('| ${r.name} | ${Suite._ns(r.nsPerOp)} | '
        '${r.opsPerSec.toStringAsFixed(0)} | '
        '${identical(r, baseline) ? '1.00x' : '${speed.toStringAsFixed(2)}x'} |');
  }
  return sb.toString();
}
