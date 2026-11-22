import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crew.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/suggestions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

/// The Analysis Crew: every analyser as one job, agents with roles handing
/// work on, the Judge cross-checking them, music never changed.
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
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  int idOf(String f) =>
      cat.db.select('SELECT id FROM tracks WHERE file_name=?', [f]).first['id']
          as int;

  test('one job runs every agent in order and reports each one', () async {
    final before = hashes(music);
    final jobs = JobsController();
    final st = await jobs.start(
      'crew',
      crewJob(CrewPlan(dbPath: dbPath, dataDir: music.parent.path)),
    );
    expect(st.state, 'completed', reason: st.message);
    final r = st.result! as Map;
    final agents = {
      for (final a in (r['agents'] as List).cast<Map>()) a['id']: a,
    };
    expect(agents.keys, crewAgents.map((a) => a.id));
    expect(agents['scout']!['status'], 'done');
    expect(agents['scout']!['summary'], contains('in scope'));
    expect(agents['listener']!['status'], 'done');
    expect(agents['listener']!['summary'], contains('Analysed'));
    expect(agents['detective']!['status'], 'done');
    expect(agents['librarian']!['status'], 'skipped');
    expect(agents['librarian']!['summary'], contains('No online services'));
    expect(agents['taggers']!['status'], 'skipped');
    expect(agents['judge']!['status'], 'done');
    expect(agents['clerk']!['summary'], contains('Nothing was changed'));
    expect(r['analysed'] as int, greaterThanOrEqualTo(10));
    expect(st.message, contains('Nothing was changed'));
    // the report is kept for the Analyse page
    expect(lastCrewReport(cat)!['tracks'], r['tracks']);
    // every pending suggestion was judged once, with the reason written down
    final judged = cat.db.select(
      "SELECT evidence FROM suggestions WHERE status='pending'",
    );
    expect(judged, isNotEmpty);
    expect(
      judged.every((x) => '${x['evidence']}'.contains(' · Judge: ')),
      isTrue,
    );
    expect(hashes(music), before, reason: 'music files are only read');

    // a second run finds nothing new to analyse
    final again = await jobs.start(
      'crew',
      crewJob(CrewPlan(dbPath: dbPath, dataDir: music.parent.path)),
    );
    expect((again.result! as Map)['analysed'], 0);
    await jobs.shutdown();
  });

  group('the Judge', () {
    late int track;
    setUp(() {
      track = idOf('Low Tide.flac');
      cat.db.execute(
        'INSERT OR REPLACE INTO analysis (track_id, method, version, analysed_at, '
        "status, bpm, camelot, bpm_confidence, key_confidence) "
        "VALUES (?, 'test', 1, 0, 'ok', 124.0, '8A', 1.0, 1.0)",
        [track],
      );
    });

    Future<Map<String, (double, String)>> judge() async {
      final b = CrewBoard(
        cat,
        CrewPlan(
          dbPath: dbPath,
          dataDir: music.parent.path,
          scope: 'ids',
          ids: [track],
          off: const {'listener', 'detective', 'librarian', 'taggers', 'clerk'},
        ),
      );
      await runCrew(b, LocalProgress());
      return {
        for (final r in cat.db.select(
          "SELECT field, suggested_value, source, confidence, evidence FROM suggestions WHERE track_id=?",
          [track],
        ))
          '${r['field']}:${r['suggested_value']}:${r['source']}': (
            (r['confidence'] as num).toDouble(),
            r['evidence'] as String,
          ),
      };
    }

    test(
      'audio agreement raises, a clash lowers, half-time is noted',
      () async {
        insertSuggestion(cat, track, 'bpm', null, '124', 'a', 'tag', 0.6);
        insertSuggestion(cat, track, 'bpm', null, '62', 'b', 'tag', 0.6);
        insertSuggestion(cat, track, 'bpm', null, '140', 'c', 'tag', 0.6);
        insertSuggestion(cat, track, 'key', null, 'Am', 'a', 'tag', 0.6);
        insertSuggestion(cat, track, 'key', null, '8B', 'b', 'tag', 0.6);
        insertSuggestion(cat, track, 'key', null, '3A', 'c', 'tag', 0.6);
        final j = await judge();
        // three rival BPMs: each −0.05, then the audio decides
        expect(j['bpm:124:a']!.$1, closeTo(0.6 - 0.05 + 0.08, 1e-9));
        expect(j['bpm:124:a']!.$2, contains('the audio agrees'));
        expect(j['bpm:62:b']!.$1, closeTo(0.6 - 0.05 + 0.02, 1e-9));
        expect(j['bpm:62:b']!.$2, contains('half/double'));
        expect(j['bpm:140:c']!.$1, closeTo(0.6 - 0.05 - 0.15, 1e-9));
        expect(j['bpm:140:c']!.$2, contains('the audio says 124 BPM'));
        expect(j['key:Am:a']!.$2, contains('the audio agrees (8A)'));
        expect(j['key:8B:b']!.$2, contains('relative key'));
        expect(j['key:3A:c']!.$2, contains('the audio hears 8A'));
      },
    );

    test('agents that agree raise each other; judged once', () async {
      insertSuggestion(
        cat,
        track,
        'genre',
        null,
        'Deep House',
        'filename',
        'x',
        0.5,
      );
      insertSuggestion(
        cat,
        track,
        'genre',
        null,
        'deep  house',
        'taggers',
        'y',
        0.7,
      );
      final first = await judge();
      expect(first['genre:Deep House:filename']!.$1, closeTo(0.56, 1e-9));
      expect(
        first['genre:Deep House:filename']!.$2,
        contains('also found by taggers'),
      );
      expect(first['genre:deep  house:taggers']!.$1, closeTo(0.76, 1e-9));
      final second = await judge();
      expect(second, first, reason: 'judging again changes nothing');
      // an agent refreshing its suggestion gets it judged afresh
      insertSuggestion(
        cat,
        track,
        'genre',
        null,
        'Deep House',
        'filename',
        'x2',
        0.5,
      );
      final third = await judge();
      expect(
        third['genre:Deep House:filename']!.$2,
        startsWith('x2 · Judge: '),
      );
    });

    test('switched-off agents say so', () async {
      final b = CrewBoard(
        cat,
        CrewPlan(
          dbPath: dbPath,
          dataDir: music.parent.path,
          scope: 'ids',
          ids: [track],
          off: const {'listener', 'detective', 'librarian', 'taggers', 'judge'},
        ),
      );
      await runCrew(b, LocalProgress());
      expect(b.reports['listener']!.status, 'skipped');
      expect(b.reports['listener']!.summary, 'Switched off.');
      expect(b.reports['scout']!.status, 'done');
      expect(b.reports['clerk']!.status, 'done');
    });
  });

  test('helpers', () {
    expect(sameTempo(124, 62), isTrue);
    expect(sameTempo(87, 174), isTrue);
    expect(sameTempo(124, 128), isFalse);
    expect(parseCrewMessage(crewMessage('judge', 'hi')), ('judge', 'hi'));
    expect(parseCrewMessage('Analysing 3 tracks'), isNull);
    setCrewOff(cat, {'scout', 'taggers'});
    expect(crewOff(cat), {'taggers'}, reason: 'the Scout always runs');
  });
}
