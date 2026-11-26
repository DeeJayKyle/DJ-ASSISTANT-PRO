import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/suggestions.dart';
import 'package:dj_assistant/core/settings.dart';
import 'package:dj_assistant/online/consensus.dart';
import 'package:dj_assistant/online/http_online.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:dj_assistant/online/parsers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary;

String _t(String title) => title.split(' (').first;

/// The scripted services of 1.x `tests/v1.rs` (`FakeOnline`).
class FakeOnline extends Online {
  @override
  Future<List<MbRecording>> musicbrainzRecordings(
    String artist,
    String title,
  ) async => [
    MbRecording(
      mbid: 'mbid-1',
      title: _t(title),
      artist: artist,
      score: 100,
      firstReleaseDate: '2015-06-01',
      releaseTitle: 'Coastline',
      label: 'Harbour Records',
      tags: ['afrobeats'],
      lengthMs: 2000,
    ),
  ];

  @override
  Future<List<CatalogMatch>> youtubeLookup(
    String key,
    String artist,
    String title,
  ) async {
    expect(key, 'yt-key');
    return [
      CatalogMatch(
        source: 'YouTube Music',
        title: _t(title),
        artist: artist,
        album: 'Coastline',
        durationMs: 2000,
        releaseDate: '2014-02-01',
        label: 'Harbour Records',
      ),
    ];
  }

  @override
  Future<List<CatalogMatch>> spotifyLookup(
    String creds,
    String artist,
    String title,
  ) async {
    expect(creds, 'id123:secret456');
    return [
      CatalogMatch(
        source: 'Spotify',
        title: _t(title),
        artist: artist,
        album: 'Coastline',
        durationMs: 2500,
        releaseDate: '2014-02-01',
        genres: ['Amapiano'],
      ),
    ];
  }

  @override
  Future<List<CatalogMatch>> catalogLookup(String artist, String title) async {
    CatalogMatch m(String source, String genre, {String? t}) => CatalogMatch(
      source: source,
      title: t ?? _t(title),
      artist: artist,
      album: 'Coastline',
      durationMs: 2000,
      bpm: source == 'Deezer' ? 122 : null,
      releaseDate: '2014-03-04',
      genres: [genre],
      label: source == 'Deezer' ? 'Harbour Records' : null,
    );
    return [
      m('Deezer', 'Amapiano'),
      m('Apple Music', 'Amapiano'),
      m('Deezer', 'Rock', t: 'Something Else'),
    ];
  }
}

void main() {
  late Directory music;
  late Catalogue cat;
  late String dbPath;
  late SuggestionsService sugg;
  setUp(() async {
    music = copyLibrary();
    dbPath = p.join(music.parent.path, 'catalogue.sqlite3');
    cat = Catalogue.open(dbPath);
    RootsService(cat).add(music.path);
    sugg = SuggestionsService(cat);
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  int idOf(String f) =>
      cat.db.select('SELECT id FROM tracks WHERE file_name=?', [f]).first['id']
          as int;

  group('majority vote', () {
    Vote v(String s, String val) => Vote(s, 'genre', val);
    test('the answer most analysers agree on wins', () {
      final d = decide('genre', [
        v('A', 'House'),
        v('B', 'house'),
        v('C', 'Techno'),
      ], hasValue: true)!;
      expect(d.value, 'House');
      expect(d.agree, ['A', 'B']);
      expect(d.total, 3);
    });
    test('a tie changes nothing', () {
      expect(
        decide('genre', [v('A', 'House'), v('B', 'Techno')], hasValue: false),
        isNull,
      );
    });
    test('one analyser only fills an empty field', () {
      expect(decide('genre', [v('A', 'House')], hasValue: true), isNull);
      expect(
        decide('genre', [v('A', 'House')], hasValue: false)!.value,
        'House',
      );
    });
  });

  test(
    'Analyse asks every analyser at once and applies the majority',
    () async {
      await runScan(cat);
      final secrets = MemorySecrets();
      final settings = SettingsService(cat, secrets);
      for (final s in ['musicbrainz', 'catalogs', 'spotify', 'youtube']) {
        settings.setService(s, true);
      }
      settings.setSecret('spotify', 'id123:secret456');
      settings.setSecret('youtube', 'yt-key');
      expect(activeAnalysers(cat, secrets), hasLength(5));
      final id = idOf('Lagos Lights - Sunrise Groove.mp3');
      final res = await analyseOnline(cat, FakeOnline(), secrets, [
        id,
      ], LocalProgress());
      expect(res.tracks, 1);
      final row = LibraryService(cat).row(id)!;
      // Deezer, Apple Music, Spotify and YouTube say 2014; MusicBrainz 2015
      expect(row.year, 2014);
      // Deezer, Apple Music and Spotify say Amapiano; MusicBrainz afrobeats
      expect(row.genre, 'Amapiano');
      final applied = sugg
          .list(trackId: id)
          .where((s) => s.field == 'year' && s.status == 'accepted')
          .single;
      expect(applied.suggestedValue, '2014');
      expect(applied.source, contains('Spotify'));
      expect(
        cat.db.select("SELECT 1 FROM catalog_checked WHERE track_id=?", [id]),
        isNotEmpty,
      );
    },
  );

  group('parsers (1.x dj-online tests)', () {
    test('YouTube Music releases', () {
      expect(isoDurationMs('PT4M8S'), 248000);
      expect(isoDurationMs('PT1H2M'), 3720000);
      final m = parseYoutubeRelease({
        'snippet': {
          'title': 'Get Lucky',
          'channelTitle': 'Daft Punk - Topic',
          'description': 'Provided to YouTube by Columbia\n\nGet Lucky · Daft Punk · Pharrell Williams · Nile Rodgers\n\nRandom Access Memories\n\n℗ 2013 Daft Life Limited\n\nReleased on: 2013-05-17\n\nAuto-generated by YouTube.',
        },
        'contentDetails': {'duration': 'PT6M9S'},
      })!;
      expect(m.source, 'YouTube Music');
      expect(m.artist, 'Daft Punk');
      expect(m.album, 'Random Access Memories');
      expect(m.label, 'Columbia');
      expect(m.releaseDate, '2013-05-17');
      expect(m.durationMs, 369000);
      expect(
        parseYoutubeRelease({
          'snippet': {'title': 'x', 'channelTitle': 'Some Uploader'},
        }),
        isNull,
      );
    });

    test('Discogs search', () {
      final m = parseDiscogsSearch(
        {
          'results': [
            {
              'title': 'Daft Punk - Discovery',
              'year': '2001',
              'style': ['French House'],
              'genre': ['Electronic'],
              'label': ['Virgin', 'Labels'],
            },
            {
              'title': 'Daft Punk (2) - Homework',
              'year': '1997',
              'genre': ['Electronic'],
            },
          ],
        },
        'Daft Punk',
        'Da Funk',
      );
      expect(m.map((x) => x.album), ['Homework', 'Discovery']);
      expect(m.first.artist, 'Daft Punk');
      expect(m.first.title, 'Da Funk');
      expect(m[1].genres.first, 'French House');
      expect(m[1].label, 'Virgin');
      expect(m[1].releaseDate, '2001');
    });

    test('Deezer and Apple Music', () {
      final d = parseDeezer(
        {
          'id': 3135556,
          'title': 'Harder, Better, Faster, Stronger',
          'duration': 224,
          'bpm': 123.4,
          'release_date': '2001-03-07',
          'isrc': 'GBDUW0000059',
          'artist': {'name': 'Daft Punk'},
          'album': {'id': 302127, 'title': 'Discovery'},
        },
        {
          'genres': {
            'data': [
              {'name': 'Electro'},
              {'name': 'Dance'},
            ],
          },
          'label': 'Parlophone (France)',
          'release_date': '2001-03-07',
        },
      )!;
      expect((d.source, d.bpm, d.durationMs), ('Deezer', 123.4, 224000));
      expect(d.genres, ['Electro', 'Dance']);
      expect(d.label, 'Parlophone (France)');
      expect(d.releaseDate, '2001-03-07');
      final none = parseDeezer({
        'title': 'x',
        'artist': {'name': 'y'},
        'bpm': 0,
        'release_date': '0000-00-00',
      }, null)!;
      expect((none.bpm, none.releaseDate), (null, null));
      final a = parseItunes({
        'resultCount': 2,
        'results': [
          {
            'kind': 'song',
            'trackName': 'Harder, Better, Faster, Stronger',
            'artistName': 'Daft Punk',
            'collectionName': 'Discovery',
            'trackTimeMillis': 224693,
            'releaseDate': '2001-03-07T08:00:00Z',
            'primaryGenreName': 'Electronic',
          },
          {
            'kind': 'music-video',
            'trackName': 'video',
            'artistName': 'Daft Punk',
          },
        ],
      });
      expect(a, hasLength(1));
      expect(a[0].genres, ['Electronic']);
      expect(a[0].releaseDate, '2001-03-07');
      expect(a[0].source, 'Apple Music');
    });
  });

  group('HttpOnline', () {
    test('MusicBrainz is limited to one request a second', () async {
      final at = <DateTime>[];
      final o = HttpOnline(
        client: MockClient((req) async {
          at.add(DateTime.now());
          return http.Response('{"recordings":[]}', 200);
        }),
      );
      await o.musicbrainzRecordings('a', 'b');
      await o.musicbrainzRecordings('a', 'c');
      expect(
        at[1].difference(at[0]).inMilliseconds,
        greaterThanOrEqualTo(1000),
      );
    });
  });

  test('library edits keep working alongside lookups', () async {
    await runScan(cat);
    final id = idOf('Lagos Lights - Sunrise Groove.mp3');
    LibraryService(cat).updateUserFields([id], {'year': 2001});
    expect(LibraryService(cat).row(id)!.year, 2001);
  });
}
