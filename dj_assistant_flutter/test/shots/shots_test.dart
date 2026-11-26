@Tags(['shots'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/serato_library.dart';
import 'package:dj_assistant/main.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:dj_assistant/ui/state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../scanner_test.dart' show copyLibrary;

/// Renders each main page to PNG (for design review only):
/// flutter test --tags shots test/shots  →  build/shots/*.png
Future<void> _fonts() async {
  final loader = FontLoader('Inter');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    loader.addFont(
      Future.value(
        ByteData.sublistView(File('assets/fonts/Inter-$w.ttf').readAsBytesSync()),
      ),
    );
  }
  await loader.load();
  final icons = FontLoader('MaterialIcons');
  final sdk = Platform.environment['FLUTTER_ROOT'] ?? '/opt/fl/flutter';
  icons.addFont(
    Future.value(
      ByteData.sublistView(
        File('$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytesSync(),
      ),
    ),
  );
  await icons.load();
}

void main() {
  testWidgets('screenshots', (tester) async {
    await tester.runAsync(_fonts);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('dja_shots');
    final music = copyLibrary();
    final accounts = AccountsService.open(dir.path);
    final container = ProviderContainer(
      overrides: [
        accountsProvider.overrideWithValue(accounts),
        sessionFactoryProvider.overrideWithValue(
          (db) => AppSession(dbPath: db, online: NoOnline(), secrets: MemorySecrets()),
        ),
      ],
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: UncontrolledProviderScope(
          container: container,
          child: const DjAssistantApp(checkUpdates: false),
        ),
      ),
    );
    await tester.pump();
    final s = container.read(sessionProvider);
    await tester.runAsync(() async {
      RootsService(s.cat).add(music.path);
      await runScan(s.cat);
      // a _Serato_ folder with a few crates, as a DJ would have
      final serato = Directory("${music.parent.path}/_Serato_")..createSync();
      s.settings.set('serato_dir', serato.path);
      SeratoLibrary.isRunning = () => false;
      final lib = s.seratoLibraryFor(serato.path);
      final paths = [
        for (final r in s.cat.db.select('SELECT path, genre FROM tracks ORDER BY id'))
          (r['path'] as String, r['genre'] as String?),
      ];
      List<String> of(String g) => [for (final x in paths) if (x.$2 == g) x.$1];
      lib.save('Afrobeats', of('Afrobeats'));
      lib.save('Afrobeats%%Peak time', of('Afrobeats').take(3).toList());
      lib.save('House', of('House'));
      lib.save('House%%Deep', of('House').take(1).toList());
      lib.save('Warm up', [for (final x in paths.take(6)) x.$1]);
      lib.save('Wedding%%Dinner', [for (final x in paths.skip(6).take(4)) x.$1]);
      lib.save('Wedding%%Dance floor', [for (final x in paths.take(8)) x.$1]);
    });
    container.read(versionProvider.notifier).bump();
    final pages = (Platform.environment['SHOTS'] ?? 'home,serato,templates,crates,library,analyse,suggestions,health,activity,settings,backups').split(',');
    Directory('build/shots').createSync(recursive: true);
    for (final id in pages) {
      container.read(viewProvider.notifier).go(id);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.runAsync(() async {
        final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await b.toImage();
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('build/shots/$id.png').writeAsBytesSync(png!.buffer.asUint8List());
      });
    }
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    accounts.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
