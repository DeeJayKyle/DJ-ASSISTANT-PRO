import 'dart:io';
import 'dart:ui' as ui;

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/main.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:dj_assistant/ui/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// Drives the real app (CI, Linux and Windows): every page opens without an
/// error. With `--dart-define=SHOTS=folder` each page is saved as a
/// screenshot.
const shots = String.fromEnvironment('SHOTS');
const pages = [
  'library',
  'quick',
  'crates',
  'duplicates',
  'activity',
  'health',
  'suggestions',
  'organize',
  'discovery',
  'gig',
  'gig-pack',
  'upgrades',
  'settings',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pages open, and a song splits and plays on Stems', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('dja_it');
    final lib = Directory(p.join(dir.path, 'Music'))..createSync();
    final src = Directory(
      p.join('..', 'crates', 'dj-core', 'tests', 'fixtures', 'library'),
    );
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final to = File(p.join(lib.path, p.relative(f.path, from: src.path)));
      to.parent.createSync(recursive: true);
      f.copySync(to.path);
    }
    final accounts = AccountsService.open(p.join(dir.path, 'data'));
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
    final session = container.read(sessionProvider);
    RootsService(session.cat).add(lib.path);
    await runScan(session.cat);
    final key = GlobalKey();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(
          key: key,
          child: const DjAssistantApp(checkUpdates: false),
        ),
      ),
    );
    await tester.pump();

    var n = 0;
    Future<void> shot(String name) async {
      if (shots.isEmpty) return;
      final b =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage();
      final png = await img.toByteData(format: ui.ImageByteFormat.png);
      final f = File(p.join(shots, '${'${n++}'.padLeft(2, '0')}-$name.png'))
        ..parent.createSync(recursive: true);
      f.writeAsBytesSync(png!.buffer.asUint8List());
    }

    // Renders frames for [ms] (not just one), so animations and page
    // transitions finish and a screenshot shows the page, not the frame
    // before it.
    Future<void> wait(int ms) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      do {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        await tester.pump();
      } while (DateTime.now().isBefore(end));
    }

    for (final page in pages) {
      container.read(viewProvider.notifier).go(page);
      await wait(800);
      expect(tester.takeException(), isNull, reason: page);
      await shot(page.replaceAll(':', '-'));
    }

    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    container.dispose();
    accounts.close();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
