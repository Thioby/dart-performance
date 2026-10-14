/// Uruchamia wszystkie benchmarki.
///
///   dart run bin/run_all.dart                 # JIT
///   dart run bin/run_all.dart --only json,ffi # wybrane grupy
///   dart run bin/run_all.dart --json out.json # surowe wyniki
///   dart run bin/run_all.dart --md RESULTS.md # tabela Markdown
///   tool/run.sh                               # JIT + AOT, zapis do RESULTS.md
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_perf_benchmarks/harness.dart';
import 'package:dart_perf_benchmarks/src/bench_buffers.dart' as buffers;
import 'package:dart_perf_benchmarks/src/bench_collections.dart' as collections;
import 'package:dart_perf_benchmarks/src/bench_ffi.dart' as ffi;
import 'package:dart_perf_benchmarks/src/bench_isolates.dart' as isolates;
import 'package:dart_perf_benchmarks/src/bench_json.dart' as json_bench;
import 'package:dart_perf_benchmarks/src/bench_soa.dart' as soa;
import 'package:dart_perf_benchmarks/src/bench_sqlite.dart' as sqlite_bench;
import 'package:dart_perf_benchmarks/src/bench_strings.dart' as strings;
import 'package:dart_perf_benchmarks/src/bench_typed_lists.dart' as typed;

final Map<String, List<Suite> Function()> _groups = {
  'typed': typed.suites,
  'soa': soa.suites,
  'json': json_bench.suites,
  'strings': strings.suites,
  'buffers': buffers.suites,
  'collections': collections.suites,
};

Future<void> main(List<String> args) async {
  String? jsonOut;
  String? mdOut;
  Set<String>? only;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--json':
        jsonOut = args[++i];
      case '--md':
        mdOut = args[++i];
      case '--only':
        only = args[++i].split(',').toSet();
      default:
        stderr.writeln('nieznany argument: ${args[i]}');
        exit(2);
    }
  }
  bool want(String g) => only == null || only.contains(g);

  final mode = Platform.script.path.endsWith('.dart') ? 'JIT' : 'AOT';
  stdout.writeln('Dart ${Platform.version}');
  stdout.writeln('tryb: $mode, ${Platform.numberOfProcessors} CPU, '
      '${Platform.operatingSystem}');

  final all = <BenchResult>[];
  for (final entry in _groups.entries) {
    if (!want(entry.key)) continue;
    for (final suite in entry.value()) {
      all.addAll(suite.run());
    }
  }
  if (want('ffi') && ffi.setupFfi()) {
    for (final suite in ffi.suites()) {
      all.addAll(suite.run());
    }
  }
  if (want('sqlite')) {
    sqlite_bench.setupSqlite();
    try {
      for (final suite in sqlite_bench.suites()) {
        all.addAll(suite.run());
      }
    } finally {
      sqlite_bench.teardownSqlite();
    }
  }
  if (want('isolates')) {
    await isolates.setupIsolates();
    all.addAll(await isolates.runIsolateSuite());
  }

  if (jsonOut != null) {
    File(jsonOut).writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'dart': Platform.version,
      'mode': mode,
      'results': all.map((r) => r.toJson()).toList(),
    }));
    stdout.writeln('zapisano $jsonOut');
  }
  if (mdOut != null) {
    File(mdOut).writeAsStringSync(
        '# Wyniki ($mode, Dart ${Platform.version.split(' ').first})\n'
        '${toMarkdown(all)}');
    stdout.writeln('zapisano $mdOut');
  }
  exit(0);
}
