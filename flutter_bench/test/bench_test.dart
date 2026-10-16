import 'package:flutter/material.dart';
import 'package:flutter_bench/main.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:users_pipeline/users_pipeline.dart';

void main() {
  testWidgets('benchmark runs all variants and shows results', (tester) async {
    await tester.pumpWidget(const BenchApp());
    final state = tester.state<State<BenchPage>>(find.byType(BenchPage)) as dynamic;
    // Small data so the test is fast; the generator is deterministic.
    state.loadBytes(generateUsersJson(5000, seed: 3), label: 'test');
    await tester.pump();

    // The variants use isolates and real timers -> runAsync (real time),
    // and we pump frames between steps so endOfFrame and setState work.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('run')));
      await tester.pump();
      for (var i = 0; i < 1200 && (state.isRunning as bool); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
      }
    });
    await tester.pump();
    final status = tester.widget<Text>(find.byKey(const Key('status'))).data;
    expect(status, isNot(startsWith('Error')), reason: status);
    expect(state.isRunning, isFalse);
    expect(find.textContaining('Done'), findsOneWidget);
    expect(find.byKey(const Key('ms:UI: slow (String + jsonDecode + fromJson + where)')), findsOneWidget);
    expect(find.byKey(const Key('ms:Isolate.run: scanner -> Transferable')), findsOneWidget);
    // The "Top" section is below the visible area (ListView builds lazily).
    expect(state.topNames as List<String>, isNotEmpty);
    await tester.scrollUntilVisible(find.textContaining('Top '), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Top '), findsOneWidget);
  });

  test('variants agree on generator data', () {
    assertVariantsAgree(generateUsersJson(1000, seed: 11));
  });
}
