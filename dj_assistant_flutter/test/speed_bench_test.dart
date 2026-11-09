import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/discovery.dart';
import 'package:dj_assistant/core/gig.dart';
import 'package:dj_assistant/core/json.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/next_track.dart';
import 'package:dj_assistant/core/profile.dart';
import 'package:dj_assistant/core/sets.dart';
import 'package:dj_assistant/core/track_match.dart';
import 'package:dj_assistant/ui/library_map.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_test.dart' show addTrack;

/// Speed budgets on a 50,000-track library with analysis: the work behind
/// Gig Mode's Next up (rebuilt on every played track), the Library Map,
/// Set Studio, playlist matching and a "Follow Serato" poll must each stay
/// inside a few seconds even on a slow machine, and repeat calls on an unchanged catalogue must be
/// near-instant.
void main() {
  test('50,000-track library: everyday operations stay fast', () {
    final c = Catalogue.inMemory();
    addTearDown(c.close);
    const genres = ['House', 'Afrobeats', 'Amapiano', 'Hip Hop', 'R&B'];
    const keys = ['8A', '9A', '7A', '8B', '3A', '10B', '1A', '12B'];
    c.db.execute('BEGIN');
    for (var i = 0; i < 50000; i++) {
      final id = addTrack(
        c,
        'Artist ${i % 997}/Track $i.mp3',
        title: 'Track $i',
        artist: 'Artist ${i % 997}',
        genre: genres[i % genres.length],
        bpm: 90 + (i % 50).toDouble(),
        key: keys[i % keys.length],
        kbps: 320,
      );
      c.db.execute(
        "INSERT INTO analysis(track_id, method, version, analysed_at, status, bpm, camelot, energy, loudness_lufs, duration_ms) "
        "VALUES (?, 'dsp', 2, 0, 'ok', ?, ?, ?, ?, ?)",
        [
          id,
          90 + (i % 50).toDouble(),
          keys[i % keys.length],
          1 + i % 10,
          -14 + (i % 7),
          200000 + (i % 120) * 1000,
        ],
      );
      c.db.execute('UPDATE tracks SET duration_ms=? WHERE id=?', [
        200000 + (i % 120) * 1000,
        id,
      ]);
    }
    c.db.execute('COMMIT');

    final times = <String, int>{};
    T time<T>(String name, T Function() f) {
      final sw = Stopwatch()..start();
      final r = f();
      times[name] = sw.elapsedMilliseconds;
      return r;
    }

    final nt = NextTrackService(c);
    time('next up: first', () => nt.suggest([1, 2, 3]));
    time('next up: again', () => nt.suggest([1, 2, 3]));
    time('next up: after a play', () => nt.suggest([1, 2, 3, 4]));
    time('map: points', () => mapPoints(nt.candidates()));
    time('profiles', () => loadProfiles(c));
    time('profiles: again', () => loadProfiles(c));
    time(
      'set plan 2 h',
      () => SetsService(c).plan(setParamsFromJson({'duration_min': 120})),
    );
    time('matcher: build', () => libraryMatcher(c));
    time('matcher: again', () => libraryMatcher(c));
    final lines = [
      for (var i = 0; i < 100; i++) 'Artist ${i % 997} - Track $i',
    ];
    time(
      'tracklist 100 lines',
      () => DiscoveryService(c).matchTracklist(lines.join('\n')),
    );
    time(
      'tracklist 100 lines: again',
      () => DiscoveryService(c).matchTracklist(lines.join('\n')),
    );
    time(
      'library search page',
      () =>
          LibraryService(c)
              .search(const TrackQuery(text: 'artist 42', limit: 200)),
    );
    GigService(c).start('bench');
    time(
      'follow Serato poll (no database)',
      () => GigService(c).followSerato('/nonexistent/master.sqlite'),
    );

    // ignore: avoid_print
    print('50,000 tracks (ms): $times');
    for (final e in times.entries) {
      // generous enough for a slow CI machine, tight enough to catch a
      // return to whole-library work on every call (a 2 h plan once took
      // 43 s here)
      final budget = e.key.contains('again') || e.key.contains('poll')
          ? 250
          : 5000;
      expect(e.value, lessThan(budget), reason: e.key);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
