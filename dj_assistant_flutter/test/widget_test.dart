import 'dart:io';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/main.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:dj_assistant/ui/hubs.dart';
import 'package:dj_assistant/ui/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'open_files.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dja_ui'));
  tearDown(() {
    expectNoOpenFiles(dir);
    dir.deleteSync(recursive: true);
  });

  /// Unmounts the app so the session closes its catalogue (Windows will not
  /// delete a folder with an open SQLite file).
  Future<void> closeApp(
    WidgetTester tester,
    AccountsService accounts, [
    ProviderContainer? container,
  ]) async {
    await tester.pumpWidget(const SizedBox());
    container?.dispose();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    accounts.close();
  }

  testWidgets('the shell shows the sidebar and switches pages', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final accounts = AccountsService.open(dir.path);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          accountsProvider.overrideWithValue(accounts),
          sessionFactoryProvider.overrideWithValue(
            (db) => AppSession(
              dbPath: db,
              online: NoOnline(),
              secrets: MemorySecrets(),
            ),
          ),
        ],
        child: const DjAssistantApp(checkUpdates: false),
      ),
    );
    await tester.pump();
    // Home first: the hubs in the sidebar and the bento tiles
    for (final x in [
      'Home',
      'Serato Crates',
      'Metadata & Analysis',
      'Backups & Settings',
    ]) {
      expect(find.text(x), findsWidgets, reason: x);
    }
    expect(find.text('LIBRARY'), findsOneWidget);
    expect(find.text('DJ Decks'), findsNothing);
    await tester.ensureVisible(find.text('Backups & Settings').first);
    await tester.tap(find.text('Backups & Settings').first);
    await tester.pump();
    expect(find.text('Appearance'), findsOneWidget);
    await tester.ensureVisible(find.text('Serato Crates').first);
    await tester.tap(find.text('Serato Crates').first);
    await tester.pump();
    // Ctrl+Tab steps to the hub's next tab
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(find.text('Write to Serato'), findsOneWidget);
    expect(find.byType(Scaffold), findsWidgets);
    await closeApp(tester, accounts);
  });

  testWidgets('every hub shows its tabs and opens each one', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final accounts = AccountsService.open(dir.path);
    final container = ProviderContainer(
      overrides: [
        accountsProvider.overrideWithValue(accounts),
        sessionFactoryProvider.overrideWithValue(
          (db) => AppSession(
            dbPath: db,
            online: NoOnline(),
            secrets: MemorySecrets(),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const DjAssistantApp(checkUpdates: false),
      ),
    );
    await tester.pump();
    for (final h in hubs) {
      for (final tab in h.tabs) {
        container.read(viewProvider.notifier).go(tab.id);
        await tester.pump();
        await tester.pump();
        // the hub's name is the heading and every tab is offered
        expect(find.text(h.label), findsWidgets, reason: tab.id);
        for (final other in h.tabs) {
          expect(find.text(other.label), findsWidgets, reason: tab.id);
        }
      }
    }
    // a tab switches the page
    container.read(viewProvider.notifier).go('suggestions');
    await tester.pump();
    await tester.tap(find.text('Health').first);
    await tester.pump();
    expect(container.read(viewProvider).id, 'health');
    expect(tester.takeException(), isNull);
    await closeApp(tester, accounts, container);
  });
}
