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

/// Drives the real app on Windows (CI): every page opens, then on Stems a
/// song is split with Fast and played through the sound card (or the page
/// says there is no sound output). With `--dart-define=SHOTS=folder` each
/// step is saved as a screenshot.
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
  'set-studio',
  'discovery',
  'gig',
  'gig-pack',
  'upgrades',
  'settings',
  'studio:remix',
  'studio:dj',
  'studio:synth',
  'studio:drums',
  'studio:stems',
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

    Future<bool> until(bool Function() ok, {int seconds = 120}) async {
      final end = DateTime.now().add(Duration(seconds: seconds));
      while (DateTime.now().isBefore(end)) {
        if (ok()) return true;
        await wait(200);
      }
      return ok();
    }

    for (final page in pages) {
      container.read(viewProvider.notifier).go(page);
      await wait(800);
      expect(tester.takeException(), isNull, reason: page);
      await shot(page.replaceAll(':', '-'));
    }

    // Stems: pick a song, split it with Fast, play it.
    await tester.tap(find.text('Fast').first);
    await wait(100);
    // on Windows an MP3, so the real app decodes through Media Foundation
    final title = Platform.isWindows ? 'Basement Hours' : 'Low Tide';
    await tester.enterText(
      find.widgetWithText(TextField, 'Song to split'),
      title,
    );
    await wait(400);
    await tester.tap(find.text(title).last);
    await wait(300);
    await shot('stems-splitting');
    expect(
      await until(() => find.text('Play').evaluate().isNotEmpty),
      isTrue,
      reason: 'the split finished',
    );
    await tester.ensureVisible(find.text('Play').first);
    await wait(300);
    await shot('stems-ready');
    await tester.tap(find.text('Play').first);
    final played = await until(
      () =>
          find.text('Pause').evaluate().isNotEmpty ||
          find.textContaining('No sound output').evaluate().isNotEmpty,
      seconds: 15,
    );
    expect(played, isTrue, reason: 'Play either plays or says why not');
    final noSound = find
        .textContaining('No sound output')
        .evaluate()
        .isNotEmpty;
    if (!noSound) {
      // the playhead moves: one second in, the readout says so
      expect(
        await until(
          () => find.textContaining('0:01 / 0:02').evaluate().isNotEmpty,
          seconds: 5,
        ),
        isTrue,
        reason: 'the playhead advanced',
      );
      await shot('stems-playing');
    }
    // ignore: avoid_print
    print(noSound ? 'no audio device: Stems said so' : 'stems played');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    container.dispose();
    accounts.close();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
