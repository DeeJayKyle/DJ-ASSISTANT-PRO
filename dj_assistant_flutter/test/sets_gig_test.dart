import 'dart:io';

import 'package:dj_assistant/analysis/analysis.dart' as an;
import 'package:dj_assistant/core/analysis_store.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/gig.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/rules.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/sets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary;

/// Ports of 1.x `set_studio_plans_reviewable_sets` and
/// `gig_mode_pauses_background_work_and_recaps`. (1.x analyses the MP3 fixtures
/// first; MP3 decoding is Windows-only here, so energies and keys are set in the
/// catalogue instead — the planner reads the same effective values either way.)
void main() {
  late Directory music;
  late Catalogue cat;
  late String dbPath;
  setUp(() async {
    music = copyLibrary();
    dbPath = p.join(music.parent.path, 'catalogue.sqlite3');
    cat = Catalogue.open(dbPath);
    RootsService(cat).add(music.path);
    await runScan(cat);
    final lib = LibraryService(cat);
    final ids = lib.trackIds(const TrackQuery());
    for (var i = 0; i < ids.length; i++) {
      lib.updateUserFields(
        [ids[i]],
        {'energy': 3 + i % 6, 'bpm': 120 + i % 5, 'key': '${8 + i % 2}A'},
      );
    }
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });
  int idOf(String f) =>
      cat.db.select('SELECT id FROM tracks WHERE file_name=?', [f]).first['id']
          as int;

  test('plans reviewable sets with must-plays, clean-only and saving', () {
    final sets = SetsService(cat);
    final must = idOf('Low Tide.flac');
    final plan = sets.plan(
      SetParams(
        durationMin: 15,
        mustPlay: [must],
        curve: 'warmup',
        minTrackSeconds: 0,
      ),
    );
    final slots = (plan['slots'] as List).cast<Map>();
    expect(slots.length, greaterThanOrEqualTo(4));
    expect(
      slots.any((s) => s['track_id'] == must && s['must_play'] == true),
      isTrue,
    );
    final ids = [for (final s in slots) s['track_id'] as int];
    expect(ids.toSet().length, ids.length, reason: 'no repeats');
    expect(plan['note'] as String, contains('trust your ears'));
    expect(
      slots.skip(1).every((s) => (s['transition'] as List).isNotEmpty),
      isTrue,
    );
    final clean = sets.plan(
      SetParams(durationMin: 5, cleanOnly: true, minTrackSeconds: 0),
    );
    for (final s in (clean['slots'] as List).cast<Map>()) {
      expect(s['track'] as String, contains('Night Market'));
    }
    final id = sets.save('Warm-up test', plan);
    expect((sets.get(id)['slots'] as List).length, slots.length);
    expect(sets.list().single['count'], slots.length);
    expect(sets.review(ids).length, ids.length - 1);
    expect(sets.toCrate(id, 'Warm-up test crate').trackCount, ids.length);
    expect(
      () => sets.plan(SetParams(durationMin: 1)),
      throwsA(isA<SetException>()),
    );
  });

  test('gig mode pauses background work, logs plays and recaps', () async {
    final jobs = JobsController();
    final gig = GigService(cat, jobs: jobs);
    final gid = gig.start('Saturday club');
    expect(gig.active, isTrue);
    // Analysis started during a gig starts paused (1.x: "paused_for_gig").
    final run = jobs.start('analysis', analysisJob(dbPath), paused: gig.active);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(jobs.status('analysis').state, 'paused');
    final t = idOf('Deep Tenant - Warehouse 94.mp3');
    gig.addEvent('played', trackId: t);
    final req = gig.addEvent('request', text: 'Something by Velvet Arcade');
    gig.setRequest(req, 'played', trackId: idOf('Mirrorball.ogg'));
    gig.addEvent('note', text: 'Crowd loved the disco section');
    expect(() => gig.addEvent('note'), throwsA(isA<GigException>()));
    gig.end();
    expect(gig.active, isFalse);
    await run;
    final recap = gig.recap(gid);
    expect(recap['played_count'], 2);
    expect(recap['requests_fulfilled'], 1);
    expect((recap['notes'] as List).length, 1);
    expect(gig.recapMarkdown(gid), contains('## Notes'));
    final plays = LibraryService(cat).search(
      TrackQuery(
        extraWhere: compileRules({
          'match': 'all',
          'rules': [
            {'kind': 'condition', 'field': 'plays', 'op': 'gte', 'value': 1},
          ],
        }, 128),
      ),
    );
    expect(plays.total, 2);
    expect(
      AnalysisStore(cat).summary()['analysed'],
      greaterThan(0),
      reason: 'the paused job resumed after the gig',
    );
    expect(an.method, 'dj-assistant-dsp');
    await jobs.shutdown();
  });
}
