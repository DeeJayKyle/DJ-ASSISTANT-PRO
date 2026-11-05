import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:io';

import 'package:dj_assistant/analysis/analysis.dart' as an;
import 'package:dj_assistant/core/analysis_store.dart';
import 'package:dj_assistant/core/autoprep.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/suggestions.dart';
import 'package:dj_assistant/online/http_online.dart';
import 'package:dj_assistant/online/lookups.dart';
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
  Future<List<AcoustidMatch>> acoustidLookup(
    String key,
    int d,
    String fp,
  ) async {
    expect(key, 'test-key');
    expect(fp, isNotEmpty);
    return [
      AcoustidMatch(
        score: 0.92,
        recordingMbid: 'rec-1',
        title: 'Long Tone (Original Mix)',
        artist: 'Quiet Harbour',
        firstYear: 2019,
      ),
    ];
  }

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
  Future<List<CatalogMatch>> getsongbpmLookup(
    String key,
    String artist,
    String title,
  ) async {
    expect(key, 'gsb-key');
    return [
      CatalogMatch(
        source: 'GetSongBPM',
        title: _t(title),
        artist: artist,
        bpm: 122,
        key: 'Dm',
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

Future<int> _fakeAutoPrepStep(Catalogue cat, JobContext ctx) =>
    autoPrepOnline(cat, ctx, FakeOnline(), MemorySecrets());

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
  Suggestion? pending(int id, String field) => sugg
      .list(trackId: id)
      .where((s) => s.field == field && s.status == 'pending')
      .firstOrNull;

  test('online lookups need consent and give evidence', () async {
    _writeWav(File(p.join(music.path, 'Lossless', 'Long Tone.wav')), 20);
    await runScan(cat);
    final id = idOf('Lagos Lights - Sunrise Groove.mp3');
    final online = FakeOnline();
    // Off by default
    expect(
      () => musicbrainzLookup(cat, online, [id], LocalProgress()),
      throwsA(isA<SuggestionException>()),
    );
    cat.setSetting('svc_musicbrainz', '1');
    await musicbrainzLookup(cat, online, [id], LocalProgress(), spacingMs: 0);
    final orig = sugg
        .list(trackId: id)
        .firstWhere(
          (s) => s.field == 'original_year' && s.source == 'MusicBrainz',
        );
    expect(orig.suggestedValue, '2015');
    expect(orig.evidence, contains('original release year'));

    // AcoustID: needs the service, a key and a fingerprint
    final wav = idOf('Long Tone.wav');
    final secrets = MemorySecrets();
    expect(
      () => acoustidLookup(cat, online, secrets, [wav], LocalProgress()),
      throwsA(isA<SuggestionException>()),
    );
    cat.setSetting('svc_acoustid', '1');
    expect(
      () => acoustidLookup(cat, online, secrets, [wav], LocalProgress()),
      throwsA(isA<SuggestionException>()),
    );
    secrets.set('acoustid', 'test-key');
    final notYet = LocalProgress();
    await acoustidLookup(cat, online, secrets, [wav], notYet, spacingMs: 0);
    expect(notYet.errors, 1);
    expect(notYet.messages.single, contains('analyse them first'));
    final path =
        cat.db.select('SELECT path FROM tracks WHERE id=?', [wav]).first['path']
            as String;
    final st = File(path).statSync();
    AnalysisStore(cat).storeResult(
      wav,
      st.size,
      st.modified.millisecondsSinceEpoch,
      an.analyseFile(path),
    );
    await acoustidLookup(
      cat,
      online,
      secrets,
      [wav],
      LocalProgress(),
      spacingMs: 0,
    );
    final t = sugg.list(trackId: wav).firstWhere((s) => s.source == 'AcoustID');
    expect(t.evidence, contains('not proof'));
  });

  test('catalogues fix BPM, year and genre when they agree', () async {
    await runScan(cat);
    final id = idOf('Lagos Lights - Sunrise Groove.mp3');
    final online = FakeOnline(), secrets = MemorySecrets();
    expect(
      () => catalogLookup(cat, online, secrets, [id], LocalProgress()),
      throwsA(isA<SuggestionException>()),
    );
    expect(catalogSourcesOn(cat, secrets), isFalse);
    cat.setSetting('svc_catalogs', '1');
    final prog = LocalProgress();
    await catalogLookup(cat, online, secrets, [id], prog);
    expect(prog.done, 1);
    expect(prog.errors, 0);
    final year = pending(id, 'year')!;
    expect(year.suggestedValue, '2014');
    expect(year.source, 'Deezer + Apple Music');
    expect(year.confidence, greaterThanOrEqualTo(0.85));
    final genre = pending(id, 'genre')!;
    expect(genre.suggestedValue, 'Amapiano');
    expect(genre.evidence, contains('Apple Music and Deezer'));
    expect(pending(id, 'bpm')!.source, 'Deezer');
    // The unrelated "Something Else" result was ignored.
    expect(
      sugg.list(trackId: id).any((s) => s.suggestedValue == 'Rock'),
      isFalse,
    );
    expect(
      cat.db.select('SELECT 1 FROM catalog_checked WHERE track_id=?', [id]),
      hasLength(1),
    );
    // Auto-prep applies what the catalogues agree on.
    final jobs = JobsController();
    final st = await jobs.start(
      'auto_prep',
      autoPrepJob(dbPath, onlineSteps: [_fakeAutoPrepStep]),
    );
    expect(st.state, 'completed', reason: st.message);
    final row = LibraryService(cat).row(id)!;
    expect(row.year, 2014);
    // the file already had a genre: the catalogue's is suggested, not forced
    expect(row.genre, 'Afrobeats');
    expect(genre.confidence, lessThan(0.85));
    await jobs.shutdown();
  });

  test('Spotify, GetSongBPM and YouTube add a key and corroborate', () async {
    await runScan(cat);
    final id = idOf('Lagos Lights - Sunrise Groove.mp3');
    final online = FakeOnline(), secrets = MemorySecrets();
    // Spotify on but no app credentials: nothing to look up with.
    cat.setSetting('svc_spotify', '1');
    expect(
      () => catalogLookup(cat, online, secrets, [id], LocalProgress()),
      throwsA(isA<SuggestionException>()),
    );
    secrets
      ..set('spotify', 'id123:secret456')
      ..set('getsongbpm', 'gsb-key')
      ..set('youtube', 'yt-key');
    cat
      ..setSetting('svc_getsongbpm', '1')
      ..setSetting('svc_youtube', '1');
    await catalogLookup(cat, online, secrets, [id], LocalProgress());
    final key = pending(id, 'key')!;
    expect(key.suggestedValue, '7A'); // D minor
    expect(key.source, 'GetSongBPM');
    final year = pending(id, 'year')!;
    expect(year.suggestedValue, '2014');
    expect(year.source, allOf(contains('Spotify'), contains('YouTube Music')));
    expect(year.confidence, greaterThanOrEqualTo(0.85));
    final genre = pending(id, 'genre')!;
    expect(genre.suggestedValue, 'Amapiano');
    expect(genre.evidence, contains('Spotify'));
    expect(pending(id, 'bpm')!.suggestedValue, '122');
  });

  test('catalogue BPM follows the analysis octave', () {
    expect(catalogBpm(61, 122), (122.0, true));
    expect(catalogBpm(244.6, 122.1), (122.3, true));
    expect(catalogBpm(128, 100), (128.0, false));
    expect(catalogBpm(300, null), isNull);
    expect(pitchClassKey(9, 0), 'Am');
    expect(pitchClassKey(12, 1), isNull);
  });

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

    test('Spotify and GetSongBPM', () {
      expect(
        base64.encode(utf8.encode('client:secret')),
        'Y2xpZW50OnNlY3JldA==',
      );
      final m = parseSpotifyTrack({
        'id': 'x1',
        'name': 'Get Lucky',
        'duration_ms': 248413,
        'artists': [
          {'name': 'Daft Punk', 'id': 'a1'},
          {'name': 'Pharrell Williams'},
        ],
        'album': {
          'name': 'Random Access Memories',
          'release_date': '2013-05-17',
        },
        'external_ids': {'isrc': 'USQX91300108'},
      });
      expect(m.artist, 'Daft Punk, Pharrell Williams');
      expect(m.releaseDate, '2013-05-17');
      applyAudioFeatures(m, {'tempo': 116.047, 'key': 9, 'mode': 0});
      expect((m.bpm, m.key), (116.047, 'Am'));
      expect(titleCase('afro house'), 'Afro House');
      final g = parseGetsongbpm({
        'search': [
          {
            'id': '1',
            'title': 'Get Lucky',
            'tempo': '116',
            'key_of': 'F♯m',
            'open_key': '4m',
            'artist': {
              'name': 'Daft Punk',
              'genres': ['electronic', 'house'],
            },
            'album': {'title': 'Random Access Memories', 'year': '2013'},
          },
        ],
      });
      expect(g[0].bpm, 116.0);
      expect(g[0].key, 'F♯m');
      expect(g[0].genres, ['Electronic', 'House']);
      expect(g[0].releaseDate, '2013');
      expect(
        parseGetsongbpm({
          'search': {'error': 'no result'},
        }),
        isEmpty,
      );
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

    test('MusicBrainz, AcoustID and Last.fm', () {
      final r = parseMbRecordings({
        'recordings': [
          {
            'id': 'r1',
            'score': 100,
            'title': 'Essence',
            'length': 248000,
            'disambiguation': '',
            'artist-credit': [
              {'name': 'Wizkid', 'joinphrase': ' feat. '},
              {'name': 'Tems', 'joinphrase': ''},
            ],
            'first-release-date': '2020-10-30',
            'releases': [
              {'title': 'Made in Lagos', 'date': '2020-10-30'},
            ],
            'tags': [
              {'count': 1, 'name': 'pop'},
              {'count': 3, 'name': 'afrobeats'},
            ],
            'isrcs': ['USRC12003456'],
          },
        ],
      });
      expect(r[0].artist, 'Wizkid feat. Tems');
      expect(r[0].firstReleaseDate, '2020-10-30');
      expect(r[0].releaseTitle, 'Made in Lagos');
      expect(r[0].tags[0], 'afrobeats');
      expect(r[0].lengthMs, 248000);
      expect(r[0].disambiguation, isNull);
      final ok = parseAcoustid({
        'status': 'ok',
        'results': [
          {
            'score': 0.9,
            'id': 'a',
            'recordings': [
              {
                'id': 'rec',
                'title': 'T',
                'artists': [
                  {'name': 'A'},
                  {'name': 'B'},
                ],
              },
            ],
          },
        ],
      });
      expect(ok[0].artist, 'A, B');
      expect(
        () => parseAcoustid({
          'status': 'error',
          'error': {'code': 4, 'message': 'invalid API key'},
        }),
        throwsA(
          isA<OnlineException>().having(
            (e) => e.message,
            'message',
            'invalid API key',
          ),
        ),
      );
      expect(
        parseLastfmArtists({
          'similarartists': {
            'artist': [
              {'name': 'Burna Boy', 'match': '0.81', 'url': 'u'},
            ],
          },
        })[0].score,
        0.81,
      );
      expect(
        parseLastfmTracks({
          'similartracks': {
            'track': [
              {
                'name': 'Ye',
                'match': 0.5,
                'artist': {'name': 'Burna Boy'},
              },
            ],
          },
        })[0].title,
        'Ye',
      );
      expect(
        () => parseLastfmArtists({'error': 10, 'message': 'Invalid API key'}),
        throwsA(isA<OnlineException>()),
      );
      expect(luceneQuote(r'Say "Hi" \o/'), r'"Say \"Hi\" \\o/"');
      expect(daysAgo(0).length, 10);
      expect(daysAgo(365).compareTo(daysAgo(0)), lessThan(0));
    });
  });

  group('HttpOnline', () {
    test('sends the 1.x requests and nothing else', () async {
      final seen = <http.Request>[];
      final client = MockClient((req) async {
        seen.add(req);
        final u = req.url;
        if (u.host == 'musicbrainz.org') {
          expect(
            u.queryParameters['query'],
            'recording:"Essence" AND artist:"Wizkid"',
          );
          return http.Response(
            jsonEncode({
              'recordings': [
                {'id': 'r1', 'score': 100, 'title': 'Essence'},
              ],
            }),
            200,
          );
        }
        if (u.host == 'accounts.spotify.com') {
          expect(req.headers['Authorization'], 'Basic aWQ6c2VjcmV0');
          return http.Response(
            jsonEncode({'access_token': 'tok', 'expires_in': 3600}),
            200,
          );
        }
        if (u.host == 'api.spotify.com') {
          expect(req.headers['Authorization'], 'Bearer tok');
          return http.Response('{}', 404);
        }
        if (u.host == 'api.acoustid.org') {
          expect(req.bodyFields['fingerprint'], 'FP');
          expect(req.bodyFields.keys, isNot(contains('audio')));
          return http.Response(
            jsonEncode({'status': 'ok', 'results': []}),
            200,
          );
        }
        return http.Response('{"message":"nope"}', 500);
      });
      final o = HttpOnline(client: client, local: client);
      expect(await o.musicbrainzRecordings('Wizkid', 'Essence'), hasLength(1));
      expect(await o.spotifyLookup('id:secret', 'A', 'B'), isEmpty);
      // the token is cached
      expect(await o.spotifyLookup('id:secret', 'A', 'B'), isEmpty);
      expect(
        seen.where((r) => r.url.host == 'accounts.spotify.com'),
        hasLength(1),
      );
      expect(await o.acoustidLookup('k', 200, 'FP'), isEmpty);
      await expectLater(
        o.getJson('https://example.invalid/x'),
        throwsA(
          isA<OnlineException>().having(
            (e) => e.message,
            'm',
            'nope (HTTP 500)',
          ),
        ),
      );
    });

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

    test(
      'a 1.x-style auto-prep with every service off sends nothing',
      () async {
        await runScan(cat);
        var requests = 0;
        final o = HttpOnline(
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
        expect(
          await autoPrepOnline(cat, LocalProgress(), o, MemorySecrets()),
          0,
        );
        expect(requests, 0);
        expect(userAgent, startsWith('DJAssistant/2.'));
      },
    );
  });

  test('library edits keep working alongside lookups', () async {
    await runScan(cat);
    final id = idOf('Lagos Lights - Sunrise Groove.mp3');
    LibraryService(cat).updateUserFields([id], {'year': 2001});
    expect(LibraryService(cat).row(id)!.year, 2001);
  });
}

/// A 16-bit mono WAV with a few tones (long enough to fingerprint).
void _writeWav(File f, int secs) {
  const sr = 22050;
  final n = sr * secs;
  final data = BytesBuilder();
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    final fr = [220.0, 330.0, 440.0, 550.0][(t * 2).toInt() % 4];
    final v = (_sin(2 * 3.141592653589793 * fr * t) * 0.4 * 32767).toInt();
    data.add([v & 0xff, (v >> 8) & 0xff]);
  }
  final d = data.toBytes();
  final h = ByteData(44);
  void s(int o, String x) {
    for (var i = 0; i < 4; i++) {
      h.setUint8(o + i, x.codeUnitAt(i));
    }
  }

  s(0, 'RIFF');
  h.setUint32(4, 36 + d.length, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  h
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, sr, Endian.little)
    ..setUint32(28, sr * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  s(36, 'data');
  h.setUint32(40, d.length, Endian.little);
  f.writeAsBytesSync([...h.buffer.asUint8List(), ...d]);
}

double _sin(double x) => math.sin(x);
