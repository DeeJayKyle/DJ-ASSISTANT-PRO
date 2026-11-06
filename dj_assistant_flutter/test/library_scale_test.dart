import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_test.dart' show addTrack;

/// The Library with 50,000 tracks (Phase 5 budget): the list loads 200 rows
/// a page as it scrolls, so each page of the default order, a sorted column
/// and a search must come back well inside a frame budget of a few frames.
void main() {
  test('pages of a 50,000-track library load quickly', () {
    final c = Catalogue.inMemory();
    addTearDown(c.close);
    const genres = ['House', 'Afrobeats', 'Amapiano', 'Hip Hop', 'R&B'];
    c.db.execute('BEGIN');
    for (var i = 0; i < 50000; i++) {
      addTrack(
        c,
        'Artist ${i % 997}/Track $i.mp3',
        title: 'Track $i',
        artist: 'Artist ${i % 997}',
        genre: genres[i % genres.length],
        bpm: 90 + (i % 50).toDouble(),
        kbps: 320,
      );
    }
    c.db.execute('COMMIT');
    final lib = LibraryService(c);
    int ms(TrackQuery q) {
      final sw = Stopwatch()..start();
      final p = lib.search(q);
      expect(p.rows, isNotEmpty);
      return sw.elapsedMilliseconds;
    }

    final times = {
      'first page': ms(const TrackQuery(limit: 200)),
      'next page (scrolling)': ms(const TrackQuery(limit: 200, offset: 200)),
      'deep page (scrolling)': ms(const TrackQuery(limit: 200, offset: 40000)),
      'sorted by BPM': ms(const TrackQuery(limit: 200, sort: 'bpm')),
      'search': ms(const TrackQuery(text: 'artist 42', limit: 200)),
    };
    // ignore: avoid_print
    print('50,000 tracks: $times ms');
    for (final e in times.entries) {
      expect(
        e.value,
        lessThan(e.key.contains('scrolling') ? 50 : 1000),
        reason: e.key,
      );
    }
    // an edit is seen at once (the cached order is dropped)
    final before = lib.search(const TrackQuery(limit: 1)).rows.first;
    c.db.execute(
      "INSERT INTO track_user(track_id, artist, updated_at) VALUES (?, '!first', 0)",
      [lib.search(const TrackQuery(limit: 1, offset: 30000)).rows.first.id],
    );
    final after = lib.search(const TrackQuery(limit: 1)).rows.first;
    expect(after.artist, '!first');
    expect(after.id, isNot(before.id));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
