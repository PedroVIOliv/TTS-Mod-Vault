import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart'
    show ProviderContainer, UncontrolledProviderScope;
import 'package:tts_mod_vault/src/mods/components/export_local_links_progress_bar.dart'
    show ExportLocalLinksProgressBar;
import 'package:tts_mod_vault/src/state/provider.dart'
    show exportLocalLinksProgressProvider;
import 'package:tts_mod_vault/src/state/mods/export_local_links_progress.dart';
import 'package:tts_mod_vault/src/state/mods/export_local_links_state.dart';

void main() {
  widgetTests();

  late ExportLocalLinksProgressNotifier notifier;
  setUp(() => notifier = ExportLocalLinksProgressNotifier());

  test('verifying carries the counts and the save name', () {
    notifier.startVerifying('My Mod');
    expect(notifier.state.status, ExportLocalLinksProgressEnum.verifying);
    expect(notifier.state.saveName, 'My Mod');
    notifier.reportVerified(3, 30);
    expect(notifier.state.currentCount, 3);
    expect(notifier.state.totalCount, 30);
    expect(notifier.state.saveName, 'My Mod');
  });

  test('writing keeps the name and the counts it was given', () {
    notifier.startVerifying('My Mod');
    notifier.reportVerified(30, 30);
    notifier.startWriting();
    expect(notifier.state.status, ExportLocalLinksProgressEnum.writing);
    expect(notifier.state.saveName, 'My Mod');
    expect(notifier.state.currentCount, 30);
  });

  test('reset clears every field, so a later export starts blank', () {
    notifier.startVerifying('My Mod');
    notifier.reportVerified(12, 30);
    notifier.startWriting();
    notifier.reset();
    expect(notifier.state.status, ExportLocalLinksProgressEnum.idle);
    expect(notifier.state.currentCount, 0);
    expect(notifier.state.totalCount, 0);
    expect(notifier.state.saveName, '');
  });
}

Future<void> pumpBar(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: ExportLocalLinksProgressBar()),
      ),
    ),
  );
}

void widgetTests() {
  testWidgets('the bar is absent until an export starts', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await pumpBar(tester, container);
    expect(find.byType(FractionallySizedBox), findsNothing);
  });

  testWidgets('verifying shows the count and the mod name', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier =
        container.read(exportLocalLinksProgressProvider.notifier);
    notifier.startVerifying('My Table');
    notifier.reportVerified(14, 30);
    await pumpBar(tester, container);
    expect(find.text('(14/30)'), findsOneWidget);
    expect(find.text('Verifying assets for My Table'), findsOneWidget);
    expect(
        tester
            .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
            .widthFactor,
        14 / 30);
  });

  testWidgets('writing fills the bar and drops the stale count',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier =
        container.read(exportLocalLinksProgressProvider.notifier);
    notifier.startVerifying('My Table');
    notifier.reportVerified(30, 30);
    notifier.startWriting();
    await pumpBar(tester, container);
    expect(find.text('Writing local links copy of My Table'), findsOneWidget);
    expect(find.text('(30/30)'), findsNothing);
    expect(
        tester
            .widget<FractionallySizedBox>(find.byType(FractionallySizedBox))
            .widthFactor,
        1.0);
  });
}
