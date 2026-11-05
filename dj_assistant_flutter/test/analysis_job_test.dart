import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/core/analysis_store.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The whole analysis job against 1.x (test/golden/analysis_job.json): the same
/// folder, the same tags, the same stored rows and suggestions.
void main() {
  late Directory tmp;
  late String dbPath;
  late Catalogue cat;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('dja-analysis-');
    final music = Directory(p.join(tmp.path, 'Music'))..createSync();
    for (final f in Directory(
      'test/fixtures/analysis',
    ).listSync().whereType<File>()) {
      f.copySync(p.join(music.path, p.basename(f.path)));
    }
    for (final f in [
      'Low Tide.flac',
      'Driftwood.aiff',
      'untagged recording.wav',
    ]) {
      File(
        p.join(
          '..',
          'crates',
          'dj-core',
          'tests',
          'fixtures',
          'library',
          'Lossless',
          f,
        ),
      ).copySync(p.join(music.path, f));
    }
    dbPath = p.join(tmp.path, 'catalogue.sqlite3');
    cat = Catalogue.open(dbPath);
    RootsService(cat).add(music.path);
    await runScan(cat);
    cat.db.execute(
      "UPDATE tracks SET bpm_tag=62, key_tag='Am' WHERE file_name='afro124_amin.flac'",
    );
    cat.db.execute(
      "UPDATE tracks SET bpm_tag=140, key_tag='5A' WHERE file_name='house128_cmaj_stereo.flac'",
    );
    cat.db.execute(
      "UPDATE tracks SET bpm_tag=180.5, key_tag='F#m' WHERE file_name='slow90_fsmin.flac'",
    );
  });

  tearDown(() {
    cat.close();
    tmp.deleteSync(recursive: true);
  });

  test('stores what 1.x stores and suggests what 1.x suggests', () async {
    final golden = jsonDecode(
      File('test/golden/analysis_job.json').readAsStringSync(),
    ) as Map;
    final jobs = JobsController();
    final st = await jobs.start('analysis', analysisJob(dbPath));
    final job = golden['job'] as Map;
    expect(st.state, 'completed');
    expect(
      (st.total, st.done, st.errors),
      (job['total'], job['done'], job['errors']),
    );

    final rows = cat.db.select(
      'SELECT t.file_name, a.method, a.version, a.status, a.error, a.bpm, a.bpm_alt, a.musical_key, a.camelot, '
      'a.energy, a.energy_raw, a.loudness_lufs, a.peak_dbfs, a.clipped_runs, a.silence_start_ms, a.silence_end_ms, '
      'a.intro_end_ms, a.outro_start_ms, a.tempo_stable, a.cues_json, a.warnings_json, a.duration_ms, '
      'a.fingerprint_encoded, length(a.waveform) AS waveform_len, length(a.fingerprint) AS fingerprint_len '
      'FROM analysis a JOIN tracks t ON t.id=a.track_id ORDER BY t.file_name',
    );
    final want = (golden['analysis'] as List).cast<Map<String, dynamic>>();
    expect(rows.length, want.length);
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i], w = want[i];
      final name = w['file_name'];
      for (final k in w.keys) {
        final x = w[k], y = r[k];
        if (k == 'energy' &&
            want.where((o) => o['energy_raw'] == w['energy_raw']).length > 1) {
          continue; // tied raw energy: checked as a group below
        }
        if (k == 'peak_dbfs' && name == 'Driftwood.aiff') {
          expect(
            y,
            -18.1,
            reason: '1.x misreads this AIFF; see analysis_test.dart',
          );
        } else if (x is double && y is num) {
          expect(y.toDouble(), closeTo(x, 0.01), reason: '$name $k');
        } else {
          expect(y, x, reason: '$name $k');
        }
      }
    }

    // Tracks with the same raw energy may be ranked in either order (1.x leaves
    // ties to the database): their rescaled energies must match as a group.
    for (final raw in want.map((w) => w['energy_raw']).toSet()) {
      final idx = [
        for (var i = 0; i < want.length; i++)
          if (want[i]['energy_raw'] == raw) i,
      ];
      if (idx.length < 2) continue;
      expect(
        [for (final i in idx) rows[i]['energy'] as int?]..sort(_cmp),
        [for (final i in idx) want[i]['energy'] as int?]..sort(_cmp),
      );
    }

    final sugg = cat.db.select(
      'SELECT t.file_name, s.field, s.current_value, s.suggested_value, s.source, s.evidence, s.confidence, s.status '
      'FROM suggestions s JOIN tracks t ON t.id=s.track_id ORDER BY t.file_name, s.field',
    );
    final ws = (golden['suggestions'] as List).cast<Map<String, dynamic>>();
    expect(sugg.length, ws.length);
    for (var i = 0; i < sugg.length; i++) {
      for (final k in ws[i].keys) {
        final x = ws[i][k], y = sugg[i][k];
        if (x is double) {
          expect((y as num).toDouble(), closeTo(x, 0.02), reason: k);
        } else {
          expect(y, x, reason: '${ws[i]['file_name']} $k');
        }
      }
    }

    // A second run finds nothing left to do.
    final store = AnalysisStore(cat);
    expect(store.pending(), isEmpty);
    expect(store.summary()['analysed'], 9);
    final someId =
        cat.db
                .select(
                  "SELECT id FROM tracks WHERE file_name='afro124_amin.flac'",
                )
                .first['id']
            as int;
    final stored = store.get(someId)!;
    expect(stored['status'], 'ok');
    expect(stored['camelot'], '8A');
    expect(stored['has_fingerprint'], isTrue);
    expect(store.isCurrent(someId), isTrue);
    await jobs.shutdown();
  });

  test('pause holds the job, cancel stops it, one job per kind', () async {
    final jobs = JobsController();
    final run = jobs.start('analysis', analysisJob(dbPath), paused: true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(jobs.status('analysis').state, 'paused');
    expect(cat.db.select('SELECT COUNT(*) AS n FROM analysis').first['n'], 0);
    expect(
      () => jobs.start('analysis', analysisJob(dbPath)),
      throwsA(isA<JobBusyException>()),
    );
    jobs.cancel('analysis');
    final st = await run;
    expect(st.state, 'cancelled');
    expect(st.done, lessThan(9));
    await jobs.shutdown();
  });

  test('a damaged file is recorded as an error and the job carries on', () async {
    final music = p.join(tmp.path, 'Music');
    File(p.join(music, 'Low Tide.flac'))
        .writeAsBytesSync([0x66, 0x4C, 0x61, 0x43, 0, 0, 0, 0]);
    // Keep the old size/mtime check from skipping it: forget the cached state.
    cat.db.execute(
      "UPDATE tracks SET read_status='ok' WHERE file_name='Low Tide.flac'",
    );
    final jobs = JobsController();
    final st = await jobs.start('analysis', analysisJob(dbPath));
    expect(st.state, 'completed');
    expect(st.errors, 1);
    final r = cat.db
        .select(
          "SELECT a.status, a.error FROM analysis a JOIN tracks t ON t.id=a.track_id WHERE t.file_name='Low Tide.flac'",
        )
        .first;
    expect(r['status'], 'error');
    expect(r['error'], isNotEmpty);
    await jobs.shutdown();
  });
}

int _cmp(int? a, int? b) => (a ?? -1).compareTo(b ?? -1);
