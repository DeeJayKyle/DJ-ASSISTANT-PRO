import 'package:dj_assistant/quick/genres.dart';
import 'package:dj_assistant/quick/names.dart';
import 'package:dj_assistant/quick/setlist.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ports of 1.x `src/lib/quick/quick.test.ts`.
void main() {
  group('name cleanup', () {
    test('cleans promo-pool junk', () {
      expect(
        parseFileName(
          '01_-_DJ_kozi-Sunset_Drive_(Original_Mix)_[FREE DL]_www.promo.net.mp3',
        ),
        const CleanName('DJ Kozi', 'Sunset Drive', 'Original Mix'),
      );
    });
    test('drops bitrates and keeps the mix name', () {
      expect(
        parseFileName('Artist - Afro Pulse (Extended Mix) 320kbps.mp3'),
        const CleanName('Artist', 'Afro Pulse', 'Extended Mix'),
      );
    });
    test('turns underscores into words', () {
      expect(
        parseFileName('deep_house_groove__clean_.mp3'),
        const CleanName('', 'Deep House Groove', 'Clean'),
      );
    });
    test('prefers real tags over a placeholder file name', () {
      expect(
        cleanName(
          'track02 final FINAL v3.mp3',
          title: 'Night Shift',
          artist: 'Mara Vey',
        ),
        const CleanName('Mara Vey', 'Night Shift', ''),
      );
    });
    test('makes a readable name from a placeholder with no tags', () {
      expect(cleanName('track02 final FINAL v3.mp3').title, 'Track 02');
    });
    test('handles remixes, feat. and mixed case', () {
      expect(
        parseFileName(
          'deadmau5 feat. Kaskade - I Remember [Joe Smith Remix].flac',
        ),
        const CleanName(
          'deadmau5 feat. Kaskade',
          'I Remember',
          'Joe Smith Remix',
        ),
      );
      expect(
        parseFileName('A1 BLACK COFFEE - SUPERMAN.wav'),
        const CleanName('Black Coffee', 'Superman', ''),
      );
    });
    test('formats either way round', () {
      const n = CleanName('DJ Kozi', 'Sunset Drive', 'Original Mix');
      expect(formatName(n), 'DJ Kozi - Sunset Drive (Original Mix)');
      expect(
        formatName(n, 'title-artist'),
        'Sunset Drive - DJ Kozi (Original Mix)',
      );
      expect(formatName(const CleanName('', 'Groove', '')), 'Groove');
    });
    test('makes names safe for every OS', () {
      expect(safeFileName('AC/DC: Back <In> Black?'), 'AC DC Back In Black');
      expect(safeFileName('con'), 'con_');
      expect(safeFileName('...'), 'Untitled');
    });
    test('knows which files still need cleanup', () {
      expect(
        needsCleanup(
          'DJ Kozi - Sunset Drive (Original Mix).mp3',
          const CleanName('DJ Kozi', 'Sunset Drive', 'Original Mix'),
        ),
        isFalse,
      );
      expect(
        needsCleanup(
          'dj_kozi-sunset.mp3',
          const CleanName('DJ Kozi', 'Sunset', ''),
        ),
        isTrue,
      );
    });
    test('keeps acronyms and small words right', () {
      expect(
        smartCase('mc solaar and the uk crew'),
        'MC Solaar and the UK Crew',
      );
    });
    test('splits like JavaScript', () {
      expect(jsSplit('a b-c', RegExp(r'(\s+|(?=[-])|(?<=[-]))')), [
        'a',
        ' ',
        'b',
        '',
        '-',
        '',
        'c',
      ]);
    });
  });

  group('genres', () {
    test('maps tag text and AI labels to DJ genres', () {
      expect(normaliseGenre('Electronic---Tech House'), 'Tech House');
      expect(
        normaliseGenre('Techno (Peak Time / Driving)'),
        'Peak Time Techno',
      );
      expect(normaliseGenre('drum n bass'), 'Drum & Bass');
      expect(normaliseGenre('Afro-House'), 'Afro House');
      expect(normaliseGenre('amapiano'), 'Amapiano');
      expect(normaliseGenre(''), isNull);
      expect(normaliseGenre('Polka'), isNull);
    });
    test('groups subgenres into families', () {
      expect(genreFamily('Tech House'), 'House');
      expect(genreFamily('Deep House'), 'House');
      expect(genreFamily('Melodic Techno'), 'Techno');
      expect(genreFamily('Unknown'), 'Other');
    });
    test('every guess is a known genre', () {
      for (final bpm in [0, 70, 90, 100, 110, 120, 128, 140, 174]) {
        for (final e in [2, 5, 8]) {
          expect(allGenres, contains(guessGenre(bpm, e)));
        }
      }
    });
  });

  SetTrack t(
    String id,
    double bpm,
    String camelot,
    double energy, [
    String genre = 'House',
  ]) => SetTrack(id, bpm, camelot, energy, genre);

  group('set building', () {
    final lib = [
      t('peak', 130, '9A', 9, 'Peak Time Techno'),
      t('warm', 118, '8A', 2, 'Deep House'),
      t('mid', 124, '8A', 5),
      t('mid2', 125, '9A', 6, 'Tech House'),
      t('late', 128, '10A', 8, 'Techno'),
    ];
    test(
      'warmup → peak starts calm and ends at the peak, mixing harmonically',
      () {
        final order = warmupToPeak(lib).map((x) => x.id).toList();
        expect(order.first, 'warm');
        expect(order.last, 'peak');
        expect(
          setCost(warmupToPeak(lib)),
          lessThan(setCost([lib[0], lib[1], lib[4], lib[2], lib[3]])),
        );
      },
    );
    test('ascending BPM and genre grouping', () {
      expect(byAscendingBpm(lib).map((x) => x.bpm), [118, 124, 125, 128, 130]);
      expect(byGenre(lib).map((x) => x.genre), [
        'Deep House',
        'House',
        'Tech House',
        'Peak Time Techno',
        'Techno',
      ]);
    });
    test('understands plain-words sort requests', () {
      expect(parseSortRequest('Build a warmup → peak set'), 'warmup-peak');
      expect(parseSortRequest('Sort by BPM ascending'), 'ascending-bpm');
      expect(
        parseSortRequest('fastest first, by tempo descending'),
        'descending-bpm',
      );
      expect(parseSortRequest('group by genre'), 'genre');
      expect(parseSortRequest('harmonic order by key'), 'key');
      expect(parseSortRequest('make me a sandwich'), isNull);
      expect(applySort('energy-down', lib).first.id, 'peak');
    });
    test('spreads energy roles across a library', () {
      final roles = assignRoles(lib);
      expect(roles['warm'], 'Warm Up');
      expect(roles['peak'], 'Peak Time');
      expect(roles.values.toSet().length, 3);
    });
  });

  group('export layouts', () {
    const tracks = [
      LayoutTrack(
        1,
        CleanName('DJ Kozi', 'Sunset Drive', 'Original Mix'),
        'Deep House',
        124,
      ),
      LayoutTrack(
        2,
        CleanName('Mara Vey', 'Night Shift', ''),
        'Peak Time Techno',
        132,
      ),
      LayoutTrack(3, CleanName('', 'Groove', ''), 'Tech House', 120),
    ];
    test('clean: everything in one folder with a playlist', () {
      final l = buildLayout(tracks, const CleanLayout(), 'artist-title');
      expect(l.items.map((i) => i.$3), [
        'DJ Kozi - Sunset Drive (Original Mix)',
        'Mara Vey - Night Shift',
        'Groove',
      ]);
      expect(
        [
          for (final p in l.playlists) [p.$1, p.$2, p.$3],
        ],
        [
          [
            'All tracks',
            'All tracks.m3u8',
            [1, 2, 3],
          ],
        ],
      );
    });
    test('playlist: play order, numbered, title first when asked', () {
      final l = buildLayout(
        tracks,
        const PlaylistLayout('Friday: Set', [3, 1, 2, 99], numbered: true),
        'title-artist',
      );
      expect(l.items.map((i) => '${i.$2}/${i.$3}'), [
        'Friday Set/01 Groove',
        'Friday Set/02 Sunset Drive - DJ Kozi (Original Mix)',
        'Friday Set/03 Night Shift - Mara Vey',
      ]);
      final p0 = l.playlists.first;
      expect(
        [p0.$1, p0.$2, p0.$3],
        [
          'Friday: Set',
          'Friday Set/Friday Set.m3u8',
          [3, 1, 2],
        ],
      );
    });
    test('genres: a folder per genre or family, sorted by BPM', () {
      expect(
        buildLayout(
          tracks,
          const GenresLayout(),
          'artist-title',
        ).playlists.map((p) => p.$2),
        [
          'Playlists/Deep House.m3u8',
          'Playlists/Peak Time Techno.m3u8',
          'Playlists/Tech House.m3u8',
        ],
      );
      final fam = buildLayout(
        tracks,
        const GenresLayout(families: true),
        'artist-title',
      );
      expect(fam.playlists.map((p) => [p.$1, p.$3]), [
        [
          'House',
          [3, 1],
        ],
        [
          'Techno',
          [2],
        ],
      ]);
      expect(fam.items.first, (3, 'House', 'Groove'));
    });
    test('folders: main/sub, the rest unsorted, each track once', () {
      final l = buildLayout(
        tracks,
        const FoldersLayout([
          ('Friday Night', 'Warm Up', [3, 1]),
          ('Friday Night', 'Peak Time', [1]),
          ('Empty', '', <int>[]),
        ]),
        'artist-title',
      );
      expect(l.items.map((i) => [i.$1, i.$2]), [
        [3, 'Friday Night/Warm Up'],
        [1, 'Friday Night/Warm Up'],
        [2, 'Unsorted'],
      ]);
      expect(l.playlists.map((p) => p.$2), [
        'Playlists/Friday Night - Warm Up.m3u8',
        'Playlists/Unsorted.m3u8',
      ]);
    });
  });
}
