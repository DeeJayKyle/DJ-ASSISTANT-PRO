import 'dart:io';
import 'dart:ui' as ui;

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/core/crates.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/suggestions.dart';
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
  'map',
  'gig',
  'gig-pack',
  'files',
  'settings',
  'upgrades',
  'studio:stems',
  'studio:remix',
  'studio:dj',
  'studio:synth',
  'studio:drums',
];
const sizes = {
  // Small laptops at 125–150% scaling, and a narrow window (the assistant
  // floats over the page below 960 px).
  'narrow': Size(900, 600),
  'small': Size(1024, 640),
  'laptop': Size(1280, 720),
  'laptop-hd': Size(1366, 768),
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

  testWidgets('gig mode shows Next up after a played track', (tester) async {
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
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = container.read(sessionProvider);
    await tester.runAsync(() async {
      RootsService(session.cat).add(lib.path);
      await runScan(session.cat);
    });
    final ids = [
      for (final r in session.cat.db.select(
        'SELECT id FROM tracks ORDER BY id LIMIT 3',
      ))
        r['id'] as int,
    ];
    for (final (i, id) in ids.indexed) {
      session.cat.db.execute(
        'INSERT OR REPLACE INTO track_user(track_id, bpm, musical_key, energy, updated_at) VALUES (?,?,?,?,0)',
        [id, 124 + i, '8A', 5 + i],
      );
    }
    session.gig.start('Test gig');
    session.gig.addEvent('played', trackId: ids.first);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const DjAssistantApp(checkUpdates: false),
      ),
    );
    final problems = <String>[];
    for (final size in sizes.values) {
      tester.view.physicalSize = size;
      container.read(viewProvider.notifier).go('gig');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (
        var e = tester.takeException();
        e != null;
        e = tester.takeException()
      ) {
        problems.add('$size: ${'$e'.split('\n').first}');
      }
      expect(find.text('Next up'), findsOneWidget);
      expect(find.text('Lift'), findsOneWidget);
    }
    expect(find.textContaining('Same key'), findsWidgets);
    session.gig.end();
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    accounts.close();
  }, timeout: const Timeout(Duration(minutes: 5)));

  testWidgets('long names, Organise mode and every assistant mode fit', (
    tester,
  ) async {
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
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = container.read(sessionProvider);
    await tester.runAsync(() async {
      RootsService(session.cat).add(lib.path);
      await runScan(session.cat);
    });
    const long =
        'An Extremely Long Track Title That Keeps Going (Extended Club Mix With Even More Words) [Remastered 2026 Deluxe Edition]';
    const artist =
        'Somebody Featuring Somebody Else And A Whole Collective Of Other Artists';
    final ids = [
      for (final r in session.cat.db.select('SELECT id FROM tracks'))
        r['id'] as int,
    ];
    for (final id in ids) {
      session.cat.db.execute(
        'INSERT OR REPLACE INTO track_user(track_id, title, artist, genre, updated_at) VALUES (?,?,?,?,0)',
        [
          id,
          '$long $id',
          artist,
          'Afro House / Amapiano / Deep Tech Crossover',
        ],
      );
    }
    session.crates.create(
      const CrateInput(
        name: 'A crate with a really long name for warm-up sets at weddings and late-night lounges',
        kind: 'manual',
      ),
    );
    session.settings.set('organise_mode', true);
    session.settings.set('low_bitrate_kbps', 2000);
    session.suggestions.generateLocal();
    insertSuggestion(
      session.cat,
      ids.first,
      'genre',
      null,
      'Afro House With A Very Long Genre Name That Should Wrap Or Shorten',
      'File name',
      long,
      0.6,
    );
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
    final problems = <String>[];
    for (final size in const [Size(900, 600), Size(1366, 768)]) {
      tester.view.physicalSize = size;
      for (final mode in ['open', 'full', 'hidden']) {
        container.read(chatModeProvider.notifier).set(mode);
        for (final page in [
          'library',
          'crates',
          'quick',
          'suggestions',
          'organize',
          'upgrades',
          'discovery',
          'settings',
        ]) {
          container.read(viewProvider.notifier).go(page);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          for (
            var e = tester.takeException();
            e != null;
            e = tester.takeException()
          ) {
            problems.add(
              '$page, assistant $mode, $size: ${'$e'.split('\n').first}',
            );
          }
          if (out != null && mode == 'open') {
            await tester.runAsync(() async {
              final b =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final img = await b.toImage();
              final png = await img.toByteData(format: ui.ImageByteFormat.png);
              File(p.join(out, 'long-${size.width.round()}-$page.png'))
                ..parent.createSync(recursive: true)
                ..writeAsBytesSync(png!.buffer.asUint8List());
            });
          }
        }
      }
    }
    // The assistant is open by default and remembers being hidden.
    container.read(chatModeProvider.notifier).set('open');
    expect(session.cat.getSetting('chat_open'), '1');
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    accounts.close();
  }, timeout: const Timeout(Duration(minutes: 10)));
}
