import 'dart:io';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/main.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:dj_assistant/ui/hubs.dart';
import 'package:dj_assistant/ui/state.dart';
import 'package:flutter/material.dart';
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
    expect(find.text('Quick Prep'), findsWidgets);
    expect(find.text('DJ Decks'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('Settings'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Settings').first);
    await tester.pump();
    expect(find.text('Appearance'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Virtual Crates'),
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Virtual Crates').first);
    await tester.pump();
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
    await tester.tap(find.text('Duplicates').first);
    await tester.pump();
    expect(container.read(viewProvider).id, 'duplicates');
    expect(tester.takeException(), isNull);
    await closeApp(tester, accounts, container);
  });
}
