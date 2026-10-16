// Benchmark "10k użytkowników z JSON" w Flutterze.
//
// Ekran: źródło danych (URL gista / raw GitHub albo wbudowany generator),
// przycisk uruchamiający warianty, tabela czasów oraz licznik janku:
// podczas pomiaru kręci się animacja, a licznik zlicza klatki > 16.7 ms.
// Dzięki temu widać różnicę między "parsuj na wątku UI" (animacja staje),
// "compute() -> List<User>" (deep copy przy odbiorze też zatrzymuje UI)
// i "Isolate.run -> TransferableTypedData" (UI płynne).
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:users_pipeline/users_pipeline.dart';

void main() => runApp(const BenchApp());

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'users pipeline bench',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const BenchPage(),
      );
}

/// Jeden wiersz wyniku na ekranie.
class RowResult {
  final String variant;
  final double ms;
  final int jankFrames;
  final double worstFrameMs;
  const RowResult(this.variant, this.ms, this.jankFrames, this.worstFrameMs);
}

/// Liczy klatki powyżej budżetu w czasie trwania jednego pomiaru.
class JankMeter {
  int frames = 0;
  int jank = 0;
  double worstMs = 0;
  bool _on = false;

  void _cb(List<FrameTiming> timings) {
    if (!_on) return;
    for (final t in timings) {
      final ms = t.totalSpan.inMicroseconds / 1000;
      frames++;
      if (ms > 16.7) jank++;
      if (ms > worstMs) worstMs = ms;
    }
  }

  void start() {
    frames = 0;
    jank = 0;
    worstMs = 0;
    if (!_on) {
      _on = true;
      SchedulerBinding.instance.addTimingsCallback(_cb);
    }
  }

  void stop() {
    if (_on) {
      _on = false;
      SchedulerBinding.instance.removeTimingsCallback(_cb);
    }
  }
}

/// Praca dla izolatów jest w funkcjach TOP-LEVEL, nie w lambdach wewnątrz
/// `State`. Lambda zdefiniowana w metodzie klasy współdzieli kontekst z innymi
/// closure'ami tej metody i może przechwycić `this` (dart-lang/sdk#36983 —
/// "over-capturing"). Tu `this` to `_BenchPageState` z `AnimationController`,
/// a `TickerFuture` jest nieprzesyłalny: `Isolate.run` rzuca
/// "object is unsendable". ObjectBox komentuje każdy taki callback:
/// "Static callback to avoid over-capturing".
Future<TransferableTypedData> scanInIsolate(Uint8List bytes) => Isolate.run(
      () => TransferableTypedData.fromList([decodeColumnar(bytes).packContiguous()]),
    );

Future<PipelineResult> pipelineInIsolate(Uint8List bytes, UserQuery q) =>
    Isolate.run(() => queryColumnar(decodeColumnar(bytes), q));

class BenchPage extends StatefulWidget {
  const BenchPage({super.key});
  @override
  State<BenchPage> createState() => _BenchPageState();
}

class _BenchPageState extends State<BenchPage> with SingleTickerProviderStateMixin {
  final _url = TextEditingController(text: defaultUsersUrl);
  final _meter = JankMeter();
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  Uint8List? _bytes;
  String _source = '';
  String _status = 'Wybierz źródło danych.';
  bool _running = false;
  final List<RowResult> _rows = [];
  List<String> _topNames = const [];
  Map<String, int> _perCountry = const {};

  @override
  void dispose() {
    _spin.dispose();
    _meter.stop();
    _url.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------- źródło

  Future<void> _fetch() async {
    setState(() => _status = 'Pobieram…');
    try {
      final sw = Stopwatch()..start();
      final bytes = await fetchBytes(Uri.parse(_url.text.trim()));
      sw.stop();
      setState(() {
        _bytes = bytes;
        _source = 'sieć: ${(bytes.length / 1024).toStringAsFixed(0)} KB w ${sw.elapsedMilliseconds} ms';
        _status = 'Dane gotowe. Uruchom benchmark.';
      });
    } catch (e) {
      setState(() => _status = 'Pobieranie nie powiodło się: $e');
    }
  }

  Future<void> _generate() async {
    setState(() => _status = 'Generuję 10k użytkowników w izolacie…');
    final bytes = await Isolate.run(() => generateUsersJson(10000));
    setState(() {
      _bytes = bytes;
      _source = 'generator: ${(bytes.length / 1024).toStringAsFixed(0)} KB';
      _status = 'Dane gotowe. Uruchom benchmark.';
    });
  }

  @visibleForTesting
  bool get isRunning => _running;

  @visibleForTesting
  List<String> get topNames => _topNames;

  /// Używane przez testy widgetowe: wstrzyknięcie bajtów bez sieci.
  @visibleForTesting
  void loadBytes(Uint8List bytes, {String label = 'test'}) {
    setState(() {
      _bytes = bytes;
      _source = label;
      _status = 'Dane gotowe.';
    });
  }

  // ------------------------------------------------------------- pomiar

  /// Jeden wariant: start licznika janku, kilka iteracji (żeby animacja miała
  /// szansę się zaciąć), stop. Między wariantami oddajemy klatkę UI.
  Future<void> _runVariant(String name, Future<Object?> Function() fn, {int reps = 3}) async {
    await SchedulerBinding.instance.endOfFrame;
    _meter.start();
    final sw = Stopwatch();
    final times = <double>[];
    Object? last;
    for (var i = 0; i < reps; i++) {
      sw
        ..reset()
        ..start();
      last = await fn();
      sw.stop();
      times.add(sw.elapsedMicroseconds / 1000);
      await Future<void>.delayed(const Duration(milliseconds: 50)); // kilka klatek animacji między iteracjami
    }
    _meter.stop();
    times.sort();
    if (last is PipelineResult) {
      _topNames = last.topNames;
      _perCountry = last.activePerCountry;
    }
    setState(() => _rows.add(RowResult(name, times[times.length ~/ 2], _meter.jank, _meter.worstMs)));
  }

  Future<void> _runAll() async {
    final bytes = _bytes;
    if (bytes == null || _running) return;
    setState(() {
      _running = true;
      _rows.clear();
      _status = 'Benchmark w toku — obserwuj animację.';
    });
    final q = UserQuery.standard;
    final bodyString = utf8.decode(bytes); // odpowiednik response.body
    try {
      // --- wątek UI
      await _runVariant('UI: slow (String + jsonDecode + fromJson + where)',
          () async => querySlow(decodeSlow(bodyString), q));
      await _runVariant('UI: fused + obiekty + pętle',
          () async => queryObjects(decodeFused(bytes), q));
      await _runVariant('UI: byte scanner -> kolumny',
          () async => queryColumnar(decodeColumnar(bytes), q));
      // --- izolaty
      await _runVariant('compute(): slow -> List<User> (deep copy)', () async {
        final users = await compute(decodeSlow, bodyString);
        return querySlow(users, q);
      });
      await _runVariant('Isolate.run: scanner -> Transferable', () async {
        final ttd = await scanInIsolate(bytes);
        return queryColumnar(UserTable.unpack(ttd.materialize()), q);
      });
      await _runVariant('Isolate.run: cały pipeline w izolacie, wynik = top-100',
          () => pipelineInIsolate(bytes, q)); // PipelineResult: 100 Stringów + mała mapa + bajty — tanie do skopiowania
      setState(() => _status = 'Gotowe.');
    } catch (e) {
      setState(() => _status = 'Błąd: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  // ------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('10k users: slow vs fast')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _url,
            decoration: const InputDecoration(labelText: 'URL JSON (gist / raw GitHub)', border: OutlineInputBorder()),
            maxLines: 2,
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.tonal(onPressed: _running ? null : _fetch, child: const Text('Pobierz z URL')),
            FilledButton.tonal(onPressed: _running ? null : _generate, child: const Text('Wygeneruj lokalnie')),
            FilledButton(
              key: const Key('run'),
              onPressed: _bytes == null || _running ? null : _runAll,
              child: const Text('Uruchom benchmark'),
            ),
          ]),
          const SizedBox(height: 8),
          Text(_source, style: theme.textTheme.bodySmall),
          Text(_status, key: const Key('status')),
          const SizedBox(height: 12),
          // Animacja-wskaźnik: jeśli parsowanie blokuje wątek UI, kółko staje.
          Row(children: [
            RepaintBoundary(
              child: RotationTransition(
                turns: _spin,
                child: const Icon(Icons.autorenew, size: 36),
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('Kółko kręci się na wątku UI. Zacięcia = jank. Kolumna "jank" zlicza klatki > 16.7 ms podczas wariantu.')),
          ]),
          const SizedBox(height: 12),
          _ResultsTable(rows: _rows),
          if (_topNames.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Aktywni per kraj: ${_perCountry.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
                style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Text('Top ${_topNames.length} (PL, premium, aktywni):', style: theme.textTheme.titleSmall),
            SizedBox(
              height: 200,
              child: ListView.builder(
                itemExtent: 24,
                itemCount: _topNames.length,
                itemBuilder: (_, i) => Text('${i + 1}. ${_topNames[i]}'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ResultsTable extends StatelessWidget {
  const _ResultsTable({required this.rows});
  final List<RowResult> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final base = rows.first.ms;
    return Table(
      columnWidths: const {0: FlexColumnWidth(3), 1: FlexColumnWidth(1), 2: FlexColumnWidth(1), 3: FlexColumnWidth(1)},
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      children: [
        const TableRow(children: [
          Text('Wariant', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('ms', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('jank', style: TextStyle(fontWeight: FontWeight.bold)),
          Text('vs 1', style: TextStyle(fontWeight: FontWeight.bold)),
        ]),
        for (final r in rows)
          TableRow(children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(r.variant, style: const TextStyle(fontSize: 12))),
            Text(r.ms.toStringAsFixed(1), key: Key('ms:${r.variant}')),
            Text('${r.jankFrames} (max ${r.worstFrameMs.toStringAsFixed(0)})'),
            Text('${(base / r.ms).toStringAsFixed(1)}x'),
          ]),
      ],
    );
  }
}
