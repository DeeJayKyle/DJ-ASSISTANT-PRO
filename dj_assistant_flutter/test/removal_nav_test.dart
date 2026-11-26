import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/removal.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/ui/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

void main() {
  group('deleting songs', () {
    late Directory music;
    late Catalogue cat;
    setUp(() async {
      music = copyLibrary();
      cat = Catalogue.open(p.join(music.parent.path, 'data', 'c.sqlite3'));
      RootsService(cat).add(music.path);
      await runScan(cat);
    });
    tearDown(() {
      cat.close();
      music.parent.deleteSync(recursive: true);
    });

    int? idOf(String f) =>
        cat.db.select('SELECT id FROM tracks WHERE file_name=?', [
              f,
            ]).firstOrNull?['id']
            as int?;

    test('leave the library, stay out on rescans, can come back', () async {
      final before = hashes(music);
      final id = idOf('Mirrorball.ogg')!;
      final r = RemovalService(cat);
      expect(r.removeFromLibrary([id]), 1);
      expect(idOf('Mirrorball.ogg'), isNull);
      expect(hashes(music), before, reason: 'the file is untouched');
      await runScan(cat);
      expect(idOf('Mirrorball.ogg'), isNull, reason: 'scans skip it');
      final hidden = r.hidden();
      expect(hidden.single['title'], isNotNull);
      expect(r.restore([hidden.single['path_key']! as String]), 1);
      await runScan(cat);
      expect(idOf('Mirrorball.ogg'), isNotNull, reason: 'back after a scan');
      expect(r.removeFromLibrary(const []), 0);
    });
  });

  test('navigation remembers back and forward', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final nav = c.read(viewProvider.notifier);
    expect(nav.canGoBack, isFalse);
    nav.go('crates');
    nav.go('gig');
    nav.go('gig'); // same page: no new history step
    expect(c.read(viewProvider).id, 'gig');
    nav.back();
    expect(c.read(viewProvider).id, 'crates');
    nav.back();
    // the app opens on Home
    expect(c.read(viewProvider).id, 'home');
    expect(nav.canGoBack, isFalse);
    nav.forward();
    expect(c.read(viewProvider).id, 'crates');
    nav.go('map');
    expect(nav.canGoForward, isFalse, reason: 'a new page clears forward');
    nav.back();
    expect(c.read(viewProvider).id, 'crates');
  });
}
