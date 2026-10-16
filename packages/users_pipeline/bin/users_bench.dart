/// Benchmark "pobierz 10k użytkowników i przefiltruj" — CLI.
///
///   dart run bin/users_bench.dart                 # pobiera z GitHuba (raw), fallback: data/users_10k.json
///   dart run bin/users_bench.dart --url https://gist.githubusercontent.com/.../users.json
///   dart run bin/users_bench.dart --file data/users_10k.json --no-isolates
///   dart run bin/users_bench.dart --md out.md
library;

import 'dart:io';

import 'package:users_pipeline/users_pipeline.dart';

Future<void> main(List<String> args) async {
  String? url = defaultUsersUrl;
  String? file;
  String? md;
  var isolates = true;
  var samples = 7;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--url':
        url = args[++i];
      case '--file':
        file = args[++i];
        url = null;
      case '--md':
        md = args[++i];
      case '--no-isolates':
        isolates = false;
      case '--samples':
        samples = int.parse(args[++i]);
      default:
        stderr.writeln('nieznany argument: ${args[i]}');
        exit(2);
    }
  }

  final mode = Platform.script.path.endsWith('.dart') ? 'JIT' : 'AOT';
  stdout.writeln('Dart ${Platform.version.split(' ').first}, tryb $mode');

  // ---- 1. Fetch (sieć mierzona osobno, bo jej szum to nie nasz kod)
  var bytes = <int>[] as dynamic;
  if (url != null) {
    final uri = Uri.parse(url);
    try {
      final sw = Stopwatch()..start();
      final body = await fetchBodyString(uri);
      sw.stop();
      stdout.writeln('fetch 🐢 http.get().body (String):      ${sw.elapsedMilliseconds} ms, ${body.length} znaków');
      sw
        ..reset()
        ..start();
      final b1 = await fetchBodyBytes(uri);
      sw.stop();
      stdout.writeln('fetch 🚀 http.get().bodyBytes:          ${sw.elapsedMilliseconds} ms, ${b1.length} B');
      sw
        ..reset()
        ..start();
      bytes = await fetchBytes(uri);
      sw.stop();
      stdout.writeln('fetch 🚀 HttpClient+BytesBuilder:       ${sw.elapsedMilliseconds} ms, ${bytes.length} B');
      stdout.writeln('źródło: $url');
    } catch (e) {
      stderr.writeln('pobieranie nie powiodło się ($e); używam pliku lokalnego');
      bytes = null;
    }
  }
  if (bytes == null || url == null) {
    final path = file ?? _findLocal();
    bytes = loadLocal(path);
    stdout.writeln('źródło: $path (${bytes.length} B)');
  }

  // ---- 2. Sanity: wszystkie warianty liczą to samo
  assertVariantsAgree(bytes);
  stdout.writeln('warianty zgodne ✔  (filtr: ${UserQuery.standard.country}, wiek ${UserQuery.standard.minAge}–${UserQuery.standard.maxAge}, '
      'score ≥ ${UserQuery.standard.minScore}, aktywni premium, top ${UserQuery.standard.top})');
  stdout.writeln('');

  // ---- 3. CPU
  final results = runUsersBenchmark(bytes, samples: samples, onResult: (t) => stdout.writeln('  $t'));
  if (isolates) {
    stdout.writeln('');
    results.addAll(await runIsolateBenchmark(bytes));
    for (final t in results.where((t) => t.stage == 'isolate rt')) {
      stdout.writeln('  $t');
    }
  }

  // ---- 4. Podsumowanie
  stdout.writeln('');
  final slow = results.firstWhere((t) => t.stage == 'end-to-end' && t.variant.startsWith('1'));
  final fast = results.firstWhere((t) => t.stage == 'end-to-end' && t.variant.startsWith('4'));
  stdout.writeln('end-to-end: ${slow.medianMs.toStringAsFixed(1)} ms -> ${fast.medianMs.toStringAsFixed(1)} ms '
      '(${(slow.medianMs / fast.medianMs).toStringAsFixed(1)}x)');

  if (md != null) {
    final sb = StringBuffer()
      ..writeln('# users pipeline ($mode, Dart ${Platform.version.split(' ').first})')
      ..writeln()
      ..writeln('| Etap | Wariant | mediana ms | min | max |')
      ..writeln('|---|---|---:|---:|---:|');
    for (final t in results) {
      sb.writeln('| ${t.stage} | ${t.variant} | ${t.medianMs.toStringAsFixed(2)} | ${t.minMs.toStringAsFixed(2)} | ${t.maxMs.toStringAsFixed(2)} |');
    }
    File(md).writeAsStringSync(sb.toString());
    stdout.writeln('zapisano $md');
  }
}

String _findLocal() {
  for (final p in ['data/users_10k.json', 'packages/users_pipeline/data/users_10k.json', '../packages/users_pipeline/data/users_10k.json']) {
    if (File(p).existsSync()) return p;
  }
  throw StateError('brak data/users_10k.json — uruchom: dart run bin/generate.dart');
}
