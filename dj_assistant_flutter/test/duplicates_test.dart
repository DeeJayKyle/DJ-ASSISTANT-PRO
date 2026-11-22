import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/analysis/analysis.dart' show analyseFile;
import 'package:dj_assistant/core/analysis_store.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/duplicates.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

/// Duplicate review against 1.x (test/golden/duplicates.json).
void main() {
  test('hashes and groups match 1.x; files are only read', () async {
    final music = copyLibrary();
    final before = hashes(music);
    final dbPath = p.join(music.parent.path, 'catalogue.sqlite3');
    final cat = Catalogue.open(dbPath);
    RootsService(cat).add(music.path);
    await runScan(cat);
    final golden = jsonDecode(
      File('test/golden/duplicates.json').readAsStringSync(),
    ) as Map;

    final jobs = JobsController();
    final st = await jobs.start('hash', hashJob(dbPath));
    final h = golden['hashing'] as Map;
    expect(
      (st.total, st.done, st.errors),
      (h['candidates'], h['hashed'], h['errors']),
    );
    final got = {
      for (final r in cat.db.select(
        'SELECT rel_path, content_hash FROM tracks WHERE content_hash IS NOT NULL',
      ))
        (r['rel_path'] as String).replaceAll(r'\', '/'): r['content_hash'],
    };
    expect(
      got,
      golden['hashes'],
      reason: 'BLAKE3 content hashes identical to 1.x',
    );

    final svc = DuplicatesService(cat);
    final groups = svc.findGroups();
    String sig(String kind, String reason, List<String> files) =>
        '$kind|$reason|${(files..sort()).join(';')}';
    expect(
      {
        for (final g in groups)
          sig(g.kind, g.reason, [
            for (final t in g.tracks)
              t.path.substring(music.path.length + 1).replaceAll(r'\', '/'),
          ]),
      },
      {
        for (final g in (golden['groups'] as List).cast<Map>())
          sig(
            g['kind'] as String,
            g['reason'] as String,
            (g['files'] as List).cast<String>(),
          ),
      },
    );
    expect(
      svc.hashCandidates(),
      isEmpty,
      reason: 'hashes are cached until a file changes',
    );

    // Decisions are remembered per group.
    final g = groups.firstWhere((g) => g.kind == 'alternate');
    svc.setDecision(g.key, 'intentional_version');
    expect(
      svc.findGroups().firstWhere((x) => x.key == g.key).decision,
      'intentional_version',
    );
    svc.setDecision(g.key, null);
    expect(svc.findGroups().firstWhere((x) => x.key == g.key).decision, isNull);
    expect(
      () => svc.setDecision('nope', 'x'),
      throwsA(isA<DuplicateException>()),
    );
    expect(
      () => svc.setDecision(g.key, 'delete'),
      throwsA(isA<DuplicateException>()),
    );

    expect(
      hashes(music),
      before,
      reason: 'duplicate review never changes files',
    );
    await jobs.shutdown();
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  group('audio fingerprints check possible duplicates', () {
    final afro = analyseFile('test/fixtures/analysis/afro124_amin.flac');
    final house = analyseFile(
      'test/fixtures/analysis/house128_cmaj_stereo.flac',
    );

    test('the verdict', () {
      expect(fingerprintVerdict(afro.fingerprint, afro.fingerprint).$1, true);
      expect(fingerprintVerdict(afro.fingerprint, house.fingerprint).$1, false);
      expect(fingerprintVerdict(null, afro.fingerprint), (null, null));
    });

    test('same name, different audio is not a duplicate', () async {
      final music = copyLibrary();
      final cat = Catalogue.open(
        p.join(music.parent.path, 'catalogue.sqlite3'),
      );
      addTearDown(() {
        cat.close();
        music.parent.deleteSync(recursive: true);
      });
      RootsService(cat).add(music.path);
      await runScan(cat);
      int idOf(String f) =>
          cat.db.select('SELECT id FROM tracks WHERE file_name=?', [
                f,
              ]).first['id']
              as int;
      final a = idOf('Low Tide.flac'), b = idOf('Driftwood.aiff');
      // pretend both are "Quiet Harbour - Low Tide", 30 s long
      cat.db.execute(
        "UPDATE tracks SET work_key='quiet harbour|low tide', duration_ms=30000, "
        "version_hint=NULL WHERE id IN (?, ?)",
        [a, b],
      );
      final store = AnalysisStore(cat);
      List<String> possible() => [
        for (final g in DuplicatesService(cat).findGroups())
          if (g.kind == 'possible' && g.tracks.any((t) => t.id == a)) g.reason,
      ];
      // no fingerprints yet: grouped on the names, as before
      expect(possible().single, contains('not proven identical'));
      store.storeResult(a, 1, null, afro);
      store.storeResult(b, 1, null, house);
      expect(possible(), isEmpty, reason: 'the audio differs');
      store.storeResult(b, 1, null, afro);
      expect(possible().single, contains('Audio fingerprints match'));
    });
  });
}
