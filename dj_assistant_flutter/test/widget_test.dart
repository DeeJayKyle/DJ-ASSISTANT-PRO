import 'dart:io';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/main.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:dj_assistant/ui/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dja_ui'));
  tearDown(() => dir.deleteSync(recursive: true));

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
  });
}
