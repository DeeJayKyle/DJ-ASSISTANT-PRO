import 'dart:io';

import 'package:dj_assistant/app/analyse_job.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/settings.dart';
import 'package:dj_assistant/online/consensus.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary;

/// Counts what each analyser was asked and how many tracks were in flight.
class CountingOnline extends Online {
  CountingOnline({this.mbGenre = 'house', this.delay = Duration.zero});
  final String mbGenre;
  final Duration delay;
  final calls = <String, int>{};
  int inFlight = 0, maxInFlight = 0;

  Future<T> _call<T>(String name, T Function() f) async {
    calls[name] = (calls[name] ?? 0) + 1;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(delay);
      return f();
    } finally {
      inFlight--;
    }
  }

  CatalogMatch _m(String source, String artist, String title, String genre) =>
      CatalogMatch(
        source: source,
        title: title,
        artist: artist,
        album: 'Coastline',
        releaseDate: '2014-03-04',
        genres: [genre],
        label: source == 'Deezer' ? 'Harbour Records' : null,
      );

  @override
  bool get separateCatalogs => true;

  @override
  Future<List<CatalogMatch>> deezerLookup(String artist, String title) =>
      _call('Deezer', () => [_m('Deezer', artist, title, 'House')]);

  @override
  Future<List<CatalogMatch>> appleLookup(String artist, String title) =>
      _call('Apple Music', () => [_m('Apple Music', artist, title, 'House')]);

  @override
  Future<List<MbRecording>> musicbrainzRecordings(
    String artist,
    String title,
  ) => _call(
    'MusicBrainz',
    () => [
      MbRecording(
        mbid: 'm',
        title: title,
        artist: artist,
        score: 100,
        firstReleaseDate: '2014-01-01',
        releaseTitle: 'Coastline',
        label: 'Harbour Records',
        tags: [mbGenre],
      ),
    ],
  );
}

void main() {
  late Directory music;
  late Catalogue cat;
  late List<int> ids;
  late String dbPath;

  setUp(() async {
    music = copyLibrary();
    dbPath = p.join(music.parent.path, 'catalogue.sqlite3');
    cat = Catalogue.open(dbPath);
    RootsService(cat).add(music.path);
    await runScan(cat);
    final settings = SettingsService(cat, MemorySecrets());
    settings.setService('musicbrainz', true);
    settings.setService('catalogs', true);
    ids = [
      for (final r in cat.db.select(
        "SELECT id FROM tracks WHERE presence='present' ORDER BY id LIMIT 3",
      ))
        r['id'] as int,
    ];
    // three songs of one album, nothing else known
    for (final (i, id) in ids.indexed) {
      cat.db.execute(
        'UPDATE tracks SET artist=?, title=?, album=?, genre=NULL, year=NULL, '
        'label=NULL, duration_ms=NULL WHERE id=?',
        ['Shore Band', 'Song ${i + 1}', 'Coastline', id],
      );
      cat.db.execute('DELETE FROM track_user WHERE track_id=?', [id]);
    }
  });

  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  group('settled: when the slower analysers can be skipped', () {
    Vote g(String s, String v) => Vote(s, 'genre', v);
    test('nothing left to ask', () {
      expect(settled('genre', [], current: null, remaining: 0), isTrue);
    });
    test('one vote for an empty field is not enough', () {
      expect(
        settled('genre', [g('A', 'House')], current: null, remaining: 1),
        isFalse,
      );
    });
    test('two agreeing and none against settles it', () {
      expect(
        settled(
          'genre',
          [g('A', 'House'), g('B', 'house')],
          current: null,
          remaining: 3,
        ),
        isTrue,
      );
    });
    test('a split waits for the tie-breaker', () {
      expect(
        settled(
          'genre',
          [g('A', 'House'), g('B', 'Techno')],
          current: null,
          remaining: 1,
        ),
        isFalse,
      );
    });
    test('one more vote cannot replace a value the first one confirms', () {
      expect(
        settled('genre', [g('A', 'House')], current: 'House', remaining: 1),
        isTrue,
      );
    });
    test('but it could join a vote against the current value', () {
      expect(
        settled('genre', [g('A', 'House')], current: 'Techno', remaining: 1),
        isFalse,
      );
    });
    test('a lead the rest cannot catch is final', () {
      expect(
        settled(
          'genre',
          [g('A', 'House'), g('B', 'House'), g('C', 'Techno')],
          current: null,
          remaining: 0,
        ),
        isTrue,
      );
      expect(
        settled(
          'genre',
          [g('A', 'House'), g('B', 'House'), g('C', 'Techno')],
          current: null,
          remaining: 1,
        ),
        isFalse,
      );
    });
  });

  test(
    'Apple Music (the slowest) is skipped once Deezer and MusicBrainz agree',
    () async {
      final online = CountingOnline();
      final res = await analyseOnline(cat, online, MemorySecrets(), [
        ids.first,
      ], LocalProgress());
      expect(res.tracks, 1);
      expect(online.calls['Deezer'], 1);
      expect(online.calls['MusicBrainz'], 1);
      expect(online.calls['Apple Music'], isNull);
      final row = LibraryService(cat).row(ids.first)!;
      expect(row.genre, 'House');
      expect(row.year, 2014);
    },
  );

  test('a disagreement asks Apple Music to break the tie', () async {
    final online = CountingOnline(mbGenre: 'techno');
    await analyseOnline(cat, online, MemorySecrets(), [
      ids.first,
    ], LocalProgress());
    expect(online.calls['Apple Music'], 1);
    expect(LibraryService(cat).row(ids.first)!.genre, 'House');
  });

  test('songs of one album share one lookup, and later runs too', () async {
    final online = CountingOnline(delay: const Duration(milliseconds: 5));
    final res = await analyseOnline(
      cat,
      online,
      MemorySecrets(),
      ids,
      LocalProgress(),
      concurrency: 8,
    );
    expect(res.tracks, ids.length);
    expect(res.albumHits, ids.length - 1);
    expect(online.calls['Deezer'], 1);
    expect(online.calls['MusicBrainz'], 1);
    for (final id in ids) {
      final row = LibraryService(cat).row(id)!;
      expect(row.genre, 'House', reason: 'track $id');
      expect(row.year, 2014);
    }
    // a song of the same album added later is answered without asking
    final later = CountingOnline();
    cat.db.execute('UPDATE track_user SET genre=NULL WHERE track_id=?', [
      ids.last,
    ]);
    await analyseOnline(cat, later, MemorySecrets(), [
      ids.last,
    ], LocalProgress());
    expect(later.calls, isEmpty);
    // "check every track again" asks again
    await analyseOnline(
      cat,
      later,
      MemorySecrets(),
      [ids.last],
      LocalProgress(),
      reuseAlbums: false,
    );
    expect(later.calls['Deezer'], 1);
  });

  test('many tracks are looked up at the same time', () async {
    for (final (i, id) in ids.indexed) {
      cat.db.execute('UPDATE tracks SET album=? WHERE id=?', ['Album $i', id]);
    }
    final online = CountingOnline(delay: const Duration(milliseconds: 30));
    final res = await analyseOnline(
      cat,
      online,
      MemorySecrets(),
      ids,
      LocalProgress(),
      concurrency: 8,
    );
    expect(res.tracks, ids.length);
    expect(online.maxInFlight, greaterThan(1));
  });

  test('a new run skips complete and already checked tracks', () async {
    expect(onlineScope(cat, 'new', ids), ids);
    // complete: genre, year, album and label all filled
    cat.db.execute(
      "UPDATE tracks SET genre='House', year=2014, label='Harbour' WHERE id=?",
      [ids[0]],
    );
    // checked recently (nothing found online)
    cat.db.execute(
      'INSERT INTO catalog_checked(track_id, checked_at) VALUES (?, ?)',
      [ids[1], nowMs()],
    );
    expect(onlineScope(cat, 'new', ids), [ids[2]]);
    expect(onlineScope(cat, 'all', ids), ids);
    // checked long ago: tried again
    cat.db.execute('UPDATE catalog_checked SET checked_at=? WHERE track_id=?', [
      nowMs() - 100 * 24 * 3600 * 1000,
      ids[1],
    ]);
    expect(onlineScope(cat, 'new', ids), [ids[1], ids[2]]);
  });

  test('Analyse runs the audio and the online part side by side', () async {
    final jobs = JobsController();
    final st = await jobs.start(
      'online',
      analyseJob(
        AnalysePlan(dbPath: dbPath, dataDir: music.parent.path),
        makeOnline: CountingOnline.new,
        makeSecrets: MemorySecrets.new,
      ),
    );
    expect(st.state, 'completed', reason: st.message);
    final summary = (st.result as Map)['summary'] as String;
    expect(summary, contains('energy for'));
    expect(summary, contains('online analyser(s) checked'));
    expect(LibraryService(cat).row(ids.first)!.genre, 'House');
    expect(st.done, st.total);
  });

  test('a cancelled run resumes where it stopped', () async {
    final first = LocalProgress();
    final online = CountingOnline();
    var n = 0;
    final cancelling = _CancelAfter(first, () => ++n > 1);
    await analyseOnline(
      cat,
      online,
      MemorySecrets(),
      [ids.first],
      cancelling,
      concurrency: 1,
    );
    final checked = cat.db.select('SELECT track_id FROM catalog_checked');
    expect(checked.map((r) => r['track_id']), [ids.first]);
    expect(onlineScope(cat, 'new', ids), isNot(contains(ids.first)));
  });
}

class _CancelAfter implements JobProgress {
  _CancelAfter(this.inner, this.cancel);
  final LocalProgress inner;
  final bool Function() cancel;
  @override
  set total(int n) => inner.total = n;
  @override
  void tick({bool ok = true}) => inner.tick(ok: ok);
  @override
  set message(String m) => inner.message = m;
  @override
  Future<bool> checkpoint() async => cancel();
}
