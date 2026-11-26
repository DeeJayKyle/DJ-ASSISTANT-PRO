import 'dart:io';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/main.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:dj_assistant/ui/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'open_files.dart';
import 'scanner_test.dart' show copyLibrary, hashes;

/// Drives the review screens with real taps and keys, on a temporary copy
/// of the synthetic fixture library.
void main() {
  late Directory music;
  late AccountsService accounts;
  late ProviderContainer container;
  late AppSession s;

  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    music = copyLibrary();
    accounts = AccountsService.open(p.join(music.parent.path, 'data'));
    container = ProviderContainer(
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
    s = container.read(sessionProvider);
    await tester.runAsync(() async {
      RootsService(s.cat).add(music.path);
      await runScan(s.cat);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const DjAssistantApp(checkUpdates: false),
      ),
    );
  }

  Future<void> stop(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    // The session's close() was scheduled in the test's fake clock: let it run.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    accounts.close();
    // The session closes its catalogue asynchronously (it first stops its
    // background jobs), so wait for that rather than for a fixed time:
    // Windows will not delete a folder with an open SQLite file.
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && openFiles(music.parent).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    expectNoOpenFiles(music.parent);
    await tester.runAsync(() async {
      for (var i = 0; ; i++) {
        try {
          music.parent.deleteSync(recursive: true);
          return;
        } on FileSystemException {
          if (i >= 50) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('suggestions: approve a batch, then undo it exactly', (
    tester,
  ) async {
    await start(tester);
    final before = hashes(music);
    expect(s.suggestions.generateLocal(), greaterThan(1));
    final pending = s.suggestions.list(status: 'pending');
    final tracks = {for (final x in pending) x.trackId};
    String? title(int id) =>
        s.cat.db.select('SELECT title FROM track_user WHERE track_id=?', [
              id,
            ]).firstOrNull?['title']
            as String?;
    final titlesBefore = {for (final id in tracks) id: title(id)};
    container.read(viewProvider.notifier).go('suggestions');
    await settle(tester);
    await tester.tap(find.textContaining('Waiting ('));
    await settle(tester);

    await tester.ensureVisible(find.bySemanticsLabel('Select all shown'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Select all shown'));
    await settle(tester);
    await tester.ensureVisible(find.text('Approve selected'));
    await settle(tester);
    await tester.tap(find.text('Approve selected'));
    await settle(tester);
    expect(s.suggestions.counts()['pending'] ?? 0, 0);
    final accepted = s.suggestions.list(status: 'accepted');
    expect(accepted, isNotEmpty);
    expect(s.suggestions.decidedBy(accepted.map((x) => x.id)).values.toSet(), {
      'you',
    });

    await tester.ensureVisible(find.textContaining('Applied ('));
    await settle(tester);
    await tester.tap(find.textContaining('Applied ('));
    await settle(tester);
    expect(find.text('by you'), findsWidgets);
    await tester.ensureVisible(find.bySemanticsLabel('Select all shown'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('Select all shown'));
    await settle(tester);
    await tester.ensureVisible(find.text('Undo selected'));
    await settle(tester);
    await tester.tap(find.text('Undo selected'));
    await settle(tester);
    expect(s.suggestions.counts()['accepted'] ?? 0, 0);
    for (final id in tracks) {
      expect(title(id), titlesBefore[id], reason: 'track $id restored');
    }
    expect(hashes(music), before, reason: 'files are never touched');
    await stop(tester);
  });

  testWidgets('undo every automatic change from Settings', (tester) async {
    await start(tester);
    s.suggestions.generateLocal();
    // What "Fill empty fields" mode does after a scan.
    final n = s.suggestions.acceptRecommended(0.35, 2.0, by: 'auto');
    expect(n, greaterThan(0));
    container.read(viewProvider.notifier).go('settings');
    await settle(tester);
    await tester.ensureVisible(find.text('Undo every automatic change…'));
    await settle(tester);
    await tester.tap(find.text('Undo every automatic change…'));
    await settle(tester);
    await tester.tap(find.text('Undo them'));
    await settle(tester);
    expect(s.suggestions.counts()['accepted'] ?? 0, 0);
    expect(
      s.cat.db.select(
        "SELECT 1 FROM suggestion_decisions WHERE undone_at IS NULL AND decided_by='auto'",
      ),
      isEmpty,
    );
    await stop(tester);
  });
}
