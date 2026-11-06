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
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Screenshots of every page, at three window sizes, in dark and light, with
/// the real fonts and a scanned fixture library. Set SCREENSHOTS to a folder
/// to write them (CI uploads them for review); each page must also lay out
/// without overflow or exceptions at every size.
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
  'files',
  'settings',
  'studio:stems',
  'studio:remix',
  'studio:dj',
  'studio:synth',
  'studio:drums',
];
const sizes = {
  'compact': Size(1100, 720),
  'standard': Size(1440, 900),
  'wide': Size(1920, 1080),
};

Future<void> loadFonts() async {
  Future<void> family(String name, List<String> files) async {
    final l = FontLoader(name);
    for (final f in files) {
      l.addFont(Future.value(ByteData.sublistView(File(f).readAsBytesSync())));
    }
    await l.load();
  }

  final fonts = Directory('assets/fonts');
  if (fonts.existsSync()) {
    final byFamily = <String, List<String>>{};
    for (final f in fonts.listSync().whereType<File>()) {
      if (!f.path.endsWith('.ttf') && !f.path.endsWith('.otf')) continue;
      final name = p.basenameWithoutExtension(f.path).split('-').first;
      byFamily.putIfAbsent(name, () => []).add(f.path);
    }
    for (final e in byFamily.entries) {
      await family(e.key, e.value);
    }
  }
  final sdk = p.join(
    p.dirname(p.dirname(Platform.resolvedExecutable)),
    '..',
    '..',
    'artifacts',
    'material_fonts',
  );
  final material = Directory(sdk).existsSync()
      ? sdk
      : p.join(
          Platform.environment['FLUTTER_ROOT'] ?? '',
          'bin',
          'cache',
          'artifacts',
          'material_fonts',
        );
  await family('MaterialIcons', [
    p.join(material, 'MaterialIcons-Regular.otf'),
  ]);
}

void main() {
  final out = Platform.environment['SCREENSHOTS'];
  late Directory dir, lib;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFonts();
  });
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dja_screens');
    lib = Directory(p.join(dir.path, 'Music'))..createSync();
    final src = Directory(
      p.join('..', 'crates', 'dj-core', 'tests', 'fixtures', 'library'),
    );
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final to = File(p.join(lib.path, p.relative(f.path, from: src.path)));
      to.parent.createSync(recursive: true);
      f.copySync(to.path);
    }
  });
  tearDown(() => dir.deleteSync(recursive: true));

  for (final theme in ['dark', 'light']) {
    testWidgets('every page lays out ($theme)', (tester) async {
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
      final key = GlobalKey();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = container.read(sessionProvider);
      await tester.runAsync(() async {
        RootsService(session.cat).add(lib.path);
        await runScan(session.cat);
      });
      session.settings.set('theme', theme);
      container.read(versionProvider.notifier).bump();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: key,
            child: const DjAssistantApp(checkUpdates: false),
          ),
        ),
      );
      final problems = <String>[];
      for (final MapEntry(key: sizeName, value: size) in sizes.entries) {
        tester.view.physicalSize = size;
        for (final page in pages) {
          container.read(viewProvider.notifier).go(page);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          for (
            Object? e = tester.takeException();
            e != null;
            e = tester.takeException()
          ) {
            problems.add('$page at $sizeName: ${'$e'.split('\n').first}');
          }
          if (out != null) {
            await tester.runAsync(() async {
              final b =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final img = await b.toImage();
              final png = await img.toByteData(format: ui.ImageByteFormat.png);
              final f = File(
                p.join(
                  out,
                  '$theme-$sizeName-${page.replaceAll(':', '-')}.png',
                ),
              )..parent.createSync(recursive: true);
              f.writeAsBytesSync(png!.buffer.asUint8List());
            });
          }
        }
      }
      await tester.pumpWidget(const SizedBox());
      container.dispose();
      expect(problems, isEmpty, reason: problems.join('\n'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      accounts.close();
    }, timeout: const Timeout(Duration(minutes: 10)));
  }
}
