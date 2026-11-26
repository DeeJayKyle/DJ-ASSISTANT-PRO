import 'dart:io';
import 'dart:ui' as ui;

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/core/crates.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/suggestions.dart';
import 'package:dj_assistant/core/tag_writer.dart';
import 'package:dj_assistant/core/taggers.dart';
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
  'home',
  'library',
  'quick',
  'crates',
  'duplicates',
  'activity',
  'health',
  'crew',
  'suggestions',
  'taggers',
  'organize',
  'discovery',
  'map',
  'gig',
  'gig-pack',
  'files',
  'settings',
  'upgrades',
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
      p.join('test', 'fixtures', 'library'),
    );
    for (final f in src.listSync(recursive: true).whereType<File>()) {
      final to = File(p.join(lib.path, p.relative(f.path, from: src.path)));
      to.parent.createSync(recursive: true);
      f.copySync(to.path);
    }
  });
  tearDown(() => dir.deleteSync(recursive: true));

  for (final theme in ['dark', 'light']) {
  }


}
