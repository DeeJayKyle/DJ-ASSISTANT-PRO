import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/paths.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/text.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final fixtures = p.normalize(
  p.join(
    Directory.current.path,
    '..',
    'crates',
    'dj-core',
    'tests',
    'fixtures',
    'library',
  ),
);

/// A private copy of the fixture library, so tests can delete and unplug folders.
Directory copyLibrary() {
  final tmp = Directory.systemTemp.createTempSync('dja-scan-');
  final lib = Directory(p.join(tmp.path, 'Music'))..createSync();
  for (final f in Directory(
    fixtures,
  ).listSync(recursive: true).whereType<File>()) {
    final dest = File(p.join(lib.path, p.relative(f.path, from: fixtures)));
    dest.parent.createSync(recursive: true);
    f.copySync(dest.path);
    dest.setLastModifiedSync(f.lastModifiedSync());
  }
  return lib;
}

Map<String, String> hashes(Directory d) => {
  for (final f in d.listSync(recursive: true).whereType<File>())
    f.path: '${sha256.convert(f.readAsBytesSync())}|${f.lastModifiedSync()}',
};

void main() {
  group('text helpers match 1.x', () {
    test('version labels only inside brackets or after a dash', () {
      expect(detectVersionLabels('Live Your Life'), isNull);
      expect(detectVersionLabels('Intro to Love'), isNull);
      expect(detectVersionLabels('Song (Live at Wembley)'), 'Live');
      expect(detectVersionLabels('Song (Radio Edit)'), 'Radio Edit');
      expect(detectVersionLabels('Song (Clean)'), 'Clean');
      expect(detectVersionLabels('Song - Extended Mix'), 'Extended');
      expect(detectVersionLabels('Song (Artist Remix)'), 'Remix');
      expect(detectVersionLabels('Song (Original Mix)'), 'Mix');
      expect(detectCleanExplicit('Song (Dirty)'), 'explicit');
    });
    test('base title and artist', () {
      expect(baseTitle('Essence (feat. Tems) [Remix]'), 'essence');
      expect(baseTitle('Essence ft. Tems'), 'essence');
      expect(baseArtist('Wizkid feat. Tems'), 'wizkid');
      expect(baseArtist('Wizkid, Tems'), 'wizkid');
    });
    test('path keys', () {
      expect(
        pathKey(r'D:\Music\Afro\Track.MP3', insensitive: true),
        pathKey('d:/music/afro/track.mp3', insensitive: true),
      );
      expect(
        pathKey('Caf\u00e9.mp3', insensitive: false),
        pathKey('Cafe\u0301.mp3', insensitive: false),
      );
      expect(keyIsWithin('/music/a/b.mp3', '/music/a'), isTrue);
      expect(keyIsWithin('/music/ab/b.mp3', '/music/a'), isFalse);
    });
  });

  group('library folders', () {
    test('nested and duplicate folders are refused', () {
      final lib = copyLibrary();
      final c = Catalogue.inMemory();
      final roots = RootsService(c);
      roots.add(lib.path);
      expect(() => roots.add(lib.path), throwsA(isA<RootException>()));
      expect(
        () => roots.add(p.join(lib.path, 'House')),
        throwsA(isA<RootException>()),
      );
      expect(() => roots.add(lib.parent.path), throwsA(isA<RootException>()));
      expect(() => roots.add('relative/path'), throwsA(isA<RootException>()));
      expect(
        () => roots.add(p.join(lib.path, 'House', 'Mirrorball.ogg')),
        throwsA(isA<RootException>()),
      );
      lib.parent.deleteSync(recursive: true);
    });
  });

  group('scanner', () {
    late Directory lib;
    late Catalogue c;
    late int rootId;
    setUp(() {
      lib = copyLibrary();
      c = Catalogue.inMemory();
      rootId = RootsService(c).add(lib.path).id;
    });
    tearDown(() {
      c.close();
      if (lib.parent.existsSync()) lib.parent.deleteSync(recursive: true);
    });

    test('catalogues the fixture library exactly as 1.x does, without changing a byte', () async {
      final before = hashes(lib);
      final golden =
          jsonDecode(File('test/golden/scan.json').readAsStringSync()) as Map;
      final pr = await runScan(c);
      final sum = golden['summary'] as Map;
      expect(pr.state, sum['status']);
      expect(pr.filesFound, sum['files_seen']);
      expect(pr.added, sum['added']);
      expect(pr.errors, sum['errors']);
      final rows = {
        for (final r in c.db.select('SELECT * FROM tracks'))
          (r['rel_path'] as String).replaceAll(r'\', '/'): r,
      };
      final want = (golden['tracks'] as Map)
          .cast<String, Map<String, dynamic>>();
      expect(rows.keys.toSet(), want.keys.toSet());
      for (final e in want.entries) {
        final r = rows[e.key]!;
        for (final k in [
          'read_status',
          'version_hint',
          'clean_hint',
          'work_key',
          'search_text',
          'media_kind',
          'presence',
        ]) {
          expect(r[k], e.value[k], reason: '${e.key}: $k');
        }
        if (e.value['read_status'] == 'unsupported') {
          expect(r['read_error'], e.value['read_error']);
        }
      }
      expect(hashes(lib), before, reason: 'music files must never change');
      final page = LibraryService(c).search(TrackQuery(text: 'beyonce deja'));
      expect(page.total, 1);
    });

    test(
      'a rescan reads only what changed and marks deleted files missing',
      () async {
        await runScan(c);
        final uid = c.db
            .select("SELECT uid FROM tracks WHERE file_name='Low Tide.flac'")
            .first['uid'];
        final pr = await runScan(c);
        // Files that failed to read are retried; everything else is unchanged.
        expect(pr.unchanged, 22 - 3);
        expect(pr.updated, 3);
        expect(pr.added, 0);
        File(p.join(lib.path, 'House', 'Mirrorball.ogg')).deleteSync();
        final again = await runScan(c);
        expect(again.missing, 1);
        final gone = c.db.select(
          "SELECT presence FROM tracks WHERE file_name='Mirrorball.ogg'",
        );
        expect(
          gone.single['presence'],
          'missing',
          reason: 'kept, never deleted',
        );
        expect(
          c.db
              .select("SELECT uid FROM tracks WHERE file_name='Low Tide.flac'")
              .first['uid'],
          uid,
          reason: 'a track keeps its identity across scans',
        );
      },
    );

    test(
      'an unplugged folder is marked offline and its tracks are kept',
      () async {
        await runScan(c);
        final moved = lib.renameSync('${lib.path}-away');
        final pr = await runScan(c);
        expect(pr.offlineRoots, 1);
        expect(pr.missing, 0);
        expect(
          c.db
              .select(
                "SELECT COUNT(*) AS n FROM tracks WHERE presence='present'",
              )
              .first['n'],
          22,
        );
        expect(
          c.db.select('SELECT status FROM library_roots').first['status'],
          'offline',
        );
        moved.renameSync(lib.path);
      },
    );

    test(
      'links are not followed, so a loop cannot trap the scan',
      () async {
        Link(p.join(lib.path, 'House', 'loop')).createSync(lib.path);
        Link(p.join(lib.path, 'alias.mp3'))
            .createSync(p.join(lib.path, 'Lossless', 'Low Tide.flac'));
        final pr = await runScan(c);
        expect(pr.state, 'completed');
        expect(pr.filesFound, 22);
      },
      skip: Platform.isWindows ? 'links need developer mode on Windows' : null,
    );

    test('cancel stops the scan without marking anything missing', () async {
      await runScan(c);
      final ctl = ScanControl()..cancelled = true;
      final pr = await runScan(c, control: ctl);
      expect(pr.state, 'cancelled');
      expect(
        c.db
            .select("SELECT COUNT(*) AS n FROM tracks WHERE presence='missing'")
            .first['n'],
        0,
      );
    });

    test('pause holds the scan until resumed', () async {
      final ctl = ScanControl()..paused = true;
      final states = <String>{};
      final run = runScan(
        c,
        control: ctl,
        onProgress: (pr) => states.add(pr.state),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(c.db.select('SELECT COUNT(*) AS n FROM tracks').first['n'], 0);
      ctl.paused = false;
      final pr = await run;
      expect(pr.added, 22);
      expect(states, contains('paused'));
      expect(rootId, isPositive);
    });
  });

  test(
    'ScanService runs in a background isolate on the account database',
    () async {
      final lib = copyLibrary();
      final dbPath = p.join(lib.parent.path, 'catalogue.sqlite3');
      final c = Catalogue.open(dbPath);
      RootsService(c).add(lib.path);
      final svc = ScanService(dbPath);
      final seen = <String>[];
      svc.progress.listen((pr) => seen.add(pr.phase));
      final pr = await svc.start();
      expect(pr.state, 'completed');
      expect(pr.added, 22);
      expect(seen, containsAll(['discovering', 'reading', 'done']));
      expect(c.db.select('SELECT COUNT(*) AS n FROM tracks').first['n'], 22);
      expect(svc.isRunning, isFalse);
      c.close();
      await svc.dispose();
      lib.parent.deleteSync(recursive: true);
    },
  );
}
