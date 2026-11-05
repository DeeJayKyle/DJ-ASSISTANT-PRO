import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../core/text.dart';
import 'online.dart';
import 'parsers.dart';

const appVersion = '2.0.0';
const userAgent =
    'DJAssistant/$appVersion ( https://github.com/DeeJayKyle/DJ-ASSISTANT-PRO )';

http.Client _client({bool direct = false}) {
  final c = HttpClient()
    ..userAgent = userAgent
    ..connectionTimeout = Duration(seconds: direct ? 3 : 20);
  c.findProxy = direct ? (_) => 'DIRECT' : HttpClient.findProxyFromEnvironment;
  return IOClient(c);
}

/// The only code in DJ Assistant that talks to the internet (1.x `dj-online`).
/// Each provider's fair-use rules are kept: MusicBrainz one request a second
/// with a descriptive User-Agent, Deezer 50 per 5 s, Apple Music about 20 a
/// minute, GetSongBPM 3000 an hour, AcoustID sends only the fingerprint.
class HttpOnline extends Online {
  HttpOnline({http.Client? client, http.Client? local})
    : web = client ?? _client(),
      localWeb = local ?? _client(direct: true);

  final http.Client web;

  /// Loopback only, never through a proxy (the local model server).
  final http.Client localWeb;

  final _last = <String, DateTime>{};
  (String, String, DateTime)? _spotifyToken;

  /// Waits so calls through [slot] are at least [gap] apart.
  Future<void> throttle(String slot, Duration gap) async {
    final now = DateTime.now();
    final last = _last[slot];
    var wait = Duration.zero;
    if (last != null && last.add(gap).isAfter(now)) {
      wait = last.add(gap).difference(now);
    }
    _last[slot] = now.add(wait);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  Uri _uri(String url, [Map<String, String> q = const {}]) {
    final u = Uri.parse(url);
    return q.isEmpty
        ? u
        : u.replace(queryParameters: {...u.queryParameters, ...q});
  }

  Future<http.Response> _send(
    Future<http.Response> Function() f, {
    Duration timeout = const Duration(seconds: 20),
    String prefix = 'network error',
  }) async {
    try {
      return await f().timeout(timeout);
    } on TimeoutException {
      throw OnlineException('$prefix: timed out');
    } on Exception catch (e) {
      throw OnlineException('$prefix: $e');
    }
  }

  Object? _json(http.Response r) {
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException catch (e) {
      throw OnlineException('unexpected response (${r.statusCode}): $e');
    }
  }

  Future<Object?> getJson(
    String url, [
    Map<String, String> q = const {},
  ]) async {
    final r = await _send(
      () => web.get(_uri(url, q), headers: {'Accept': 'application/json'}),
    );
    final body = _json(r);
    if (r.statusCode == 503 || r.statusCode == 429) {
      throw OnlineException(
        'the service is busy (rate limited); try again in a minute',
      );
    }
    if (r.statusCode >= 400) {
      final msg =
          str(at(body, 'message')) ??
          str(at(body, 'error/message')) ??
          'request failed';
      throw OnlineException('$msg (HTTP ${r.statusCode})');
    }
    return body;
  }

  Future<void> _mb() => throttle('mb', const Duration(milliseconds: 1050));

  @override
  Future<List<MbRecording>> musicbrainzRecordings(
    String artist,
    String title,
  ) async {
    await _mb();
    final v = await getJson('https://musicbrainz.org/ws/2/recording', {
      'query':
          'recording:${luceneQuote(title)} AND artist:${luceneQuote(artist)}',
      'fmt': 'json',
      'limit': '5',
    });
    return parseMbRecordings(v);
  }

  @override
  Future<List<ReleaseItem>> musicbrainzArtistReleases(String artist) async {
    await _mb();
    final v = await getJson('https://musicbrainz.org/ws/2/artist', {
      'query': 'artist:${luceneQuote(artist)}',
      'fmt': 'json',
      'limit': '1',
    });
    final a = list(at(v, 'artists')).firstOrNull;
    if (a == null || (integer(at(a, 'score')) ?? 0) < 90) return [];
    final id = str(at(a, 'id')) ?? '';
    final name = str(at(a, 'name')) ?? artist;
    await _mb();
    final rg = await getJson('https://musicbrainz.org/ws/2/release-group', {
      'artist': id,
      'fmt': 'json',
      'limit': '100',
    });
    final since = daysAgo(365);
    return [
      for (final r in list(at(rg, 'release-groups')))
        if (str(at(r, 'first-release-date')) case final d?
            when d.compareTo(since) >= 0)
          ReleaseItem(
            artist: name,
            title: str(at(r, 'title')) ?? '',
            date: d,
            kind: str(at(r, 'primary-type')) ?? 'Release',
            url: switch (str(at(r, 'id'))) {
              final i? => 'https://musicbrainz.org/release-group/$i',
              null => null,
            },
          ),
    ];
  }

  @override
  Future<List<AcoustidMatch>> acoustidLookup(
    String apiKey,
    int durationS,
    String fingerprint,
  ) async {
    final r = await _send(
      () => web.post(
        Uri.parse('https://api.acoustid.org/v2/lookup'),
        body: {
          'client': apiKey,
          'meta': 'recordings',
          'duration': '$durationS',
          'fingerprint': fingerprint,
          'format': 'json',
        },
      ),
    );
    return parseAcoustid(_json(r));
  }

  @override
  Future<List<SimilarItem>> lastfmSimilarArtists(
    String apiKey,
    String artist,
  ) async => parseLastfmArtists(
    await _lastfm({
      'method': 'artist.getsimilar',
      'artist': artist,
      'api_key': apiKey,
      'format': 'json',
      'limit': '20',
      'autocorrect': '1',
    }),
  );

  @override
  Future<List<SimilarItem>> lastfmSimilarTracks(
    String apiKey,
    String artist,
    String title,
  ) async => parseLastfmTracks(
    await _lastfm({
      'method': 'track.getsimilar',
      'artist': artist,
      'track': title,
      'api_key': apiKey,
      'format': 'json',
      'limit': '25',
      'autocorrect': '1',
    }),
  );

  Future<Object?> _lastfm(Map<String, String> q) async {
    // Last.fm answers errors with a JSON body that the parsers report.
    final r = await _send(
      () => web.get(
        _uri('https://ws.audioscrobbler.com/2.0/', q),
        headers: {'Accept': 'application/json'},
      ),
    );
    final v = _json(r);
    if (r.statusCode >= 400 && at(v, 'error') is! num) {
      throw OnlineException('Last.fm error (HTTP ${r.statusCode})');
    }
    return v;
  }

  // ---- catalogues ----

  /// Deezer: search, then the best match's track (BPM, date, ISRC) and album.
  Future<List<CatalogMatch>> deezer(String artist, String title) async {
    const gap = Duration(milliseconds: 150);
    await throttle('deezer', gap);
    final v = await getJson('https://api.deezer.com/search', {
      'q': '$artist $title',
      'limit': '10',
    });
    if (str(at(v, 'error/message')) case final e?) {
      throw OnlineException('Deezer: $e');
    }
    final wantT = baseTitle(title), wantA = baseArtist(artist);
    final hits = list(at(v, 'data'))
        .where((t) {
          final sameT =
              baseTitle(str(at(t, 'title')) ?? '') == wantT ||
              baseTitle(str(at(t, 'title_short')) ?? '') == wantT;
          final a = str(at(t, 'artist/name'));
          return sameT && a != null && baseArtist(a) == wantA;
        })
        .take(3)
        .toList();
    if (hits.isEmpty) return [];
    CatalogMatch? main;
    for (var i = 0; i < hits.length; i++) {
      await throttle('deezer', gap);
      final t = await getJson(
        'https://api.deezer.com/track/${integer(at(hits[i], 'id')) ?? 0}',
      );
      if (i == 0) {
        final albumId = integer(at(t, 'album/id')) ?? 0;
        Object? album;
        if (albumId > 0) {
          await throttle('deezer', gap);
          try {
            album = await getJson('https://api.deezer.com/album/$albumId');
          } on OnlineException {
            album = null;
          }
        }
        main = parseDeezer(t, album);
        if (main?.bpm != null) break;
      } else if (parseDeezer(t, null) case final other?) {
        // Deezer lists a tempo on some editions only: borrow one of the same length.
        final a = other.durationMs, b = main?.durationMs;
        final sameLen = a != null && b != null && (a - b).abs() <= 3000;
        if (sameLen && other.bpm != null) {
          main?.bpm = other.bpm;
          break;
        }
      }
    }
    return [?main];
  }

  /// Apple Music (iTunes Search API): genre, release date and length.
  Future<List<CatalogMatch>> itunes(String artist, String title) async {
    await throttle('itunes', const Duration(milliseconds: 3100));
    return parseItunes(
      await getJson('https://itunes.apple.com/search', {
        'term': '$artist $title',
        'media': 'music',
        'entity': 'song',
        'limit': '8',
      }),
    );
  }

  @override
  Future<List<CatalogMatch>> catalogLookup(String artist, String title) async {
    // Either catalogue on its own is useful; both failing is an error.
    List<CatalogMatch>? d, i;
    String? de, ie;
    try {
      d = await deezer(artist, title);
    } on OnlineException catch (e) {
      de = e.message;
    }
    try {
      i = await itunes(artist, title);
    } on OnlineException catch (e) {
      ie = e.message;
    }
    if (d == null && i == null) {
      throw OnlineException('$de; Apple Music: $ie');
    }
    return [...?d, ...?i];
  }

  /// GET with a bearer token; null for 403/404 (a feature this app may not have).
  Future<Object?> _bearer(
    String url,
    String token, [
    Map<String, String> q = const {},
  ]) async {
    final r = await _send(
      () => web.get(
        _uri(url, q),
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer $token',
        },
      ),
    );
    if (r.statusCode == 403 || r.statusCode == 404) return null;
    switch (r.statusCode) {
      case 401:
        throw OnlineException(
          "Spotify rejected the app's Client ID or secret. Check them in Settings → Online services.",
        );
      case 429:
        throw OnlineException(
          'Spotify is rate limiting; try again in a minute',
        );
      case >= 400:
        throw OnlineException('Spotify error (HTTP ${r.statusCode})');
    }
    try {
      return jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      return null;
    }
  }

  Future<String> _spotify(String creds) async {
    final t = _spotifyToken;
    if (t != null && t.$1 == creds && DateTime.now().isBefore(t.$3)) {
      return t.$2;
    }
    final r = await _send(
      () => web.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {
          'Authorization': 'Basic ${base64.encode(utf8.encode(creds.trim()))}',
        },
        body: {'grant_type': 'client_credentials'},
      ),
      prefix: 'Spotify sign-in failed',
    );
    Object? v;
    try {
      v = jsonDecode(utf8.decode(r.bodyBytes));
    } on FormatException {
      v = null;
    }
    final tok = str(at(v, 'access_token'));
    if (tok == null || r.statusCode >= 400) {
      throw OnlineException(
        "Spotify rejected the app's Client ID or secret. Check them in Settings → Online services.",
      );
    }
    final secs = ((integer(at(v, 'expires_in')) ?? 3600) - 60).clamp(
      0,
      1 << 31,
    );
    _spotifyToken = (creds, tok, DateTime.now().add(Duration(seconds: secs)));
    return tok;
  }

  @override
  Future<List<CatalogMatch>> spotifyLookup(
    String creds,
    String artist,
    String title,
  ) async {
    final token = await _spotify(creds);
    const gap = Duration(milliseconds: 120);
    await throttle('spotify', gap);
    final v = await _bearer('https://api.spotify.com/v1/search', token, {
      'q': 'track:$title artist:$artist',
      'type': 'track',
      'limit': '8',
    });
    if (v == null) return [];
    final wantT = baseTitle(title), wantA = baseArtist(artist);
    final items = list(at(v, 'tracks/items'))
        .where((t) {
          final a = str(at(t, 'artists/0/name'));
          return baseTitle(str(at(t, 'name')) ?? '') == wantT &&
              a != null &&
              baseArtist(a) == wantA;
        })
        .take(3)
        .toList();
    final out = <CatalogMatch>[];
    for (var i = 0; i < items.length; i++) {
      final t = items[i];
      final m = parseSpotifyTrack(t);
      if (i == 0) {
        // genres live on the artist; tempo and key on audio features (older apps only)
        if (str(at(t, 'artists/0/id')) case final aid?) {
          await throttle('spotify', gap);
          final a = await _bearer(
            'https://api.spotify.com/v1/artists/$aid',
            token,
          );
          if (a != null) {
            m.genres = [
              for (final g in list(at(a, 'genres')))
                if (g is String) titleCase(g),
            ];
          }
        }
        if (str(at(t, 'id')) case final id?) {
          await throttle('spotify', gap);
          try {
            final f = await _bearer(
              'https://api.spotify.com/v1/audio-features/$id',
              token,
            );
            if (f != null) applyAudioFeatures(m, f);
          } on OnlineException {
            // audio features are optional
          }
        }
      }
      out.add(m);
    }
    return out;
  }

  @override
  Future<List<CatalogMatch>> youtubeLookup(
    String apiKey,
    String artist,
    String title,
  ) async {
    Future<Object?> yt(String url, Map<String, String> q) async {
      final r = await _send(
        () => web.get(
          _uri(url, {...q, 'key': apiKey}),
          headers: {'Accept': 'application/json'},
        ),
      );
      Object? v;
      try {
        v = jsonDecode(utf8.decode(r.bodyBytes));
      } on FormatException {
        v = null;
      }
      if (r.statusCode >= 400) {
        final reason = str(at(v, 'error/errors/0/reason')) ?? '';
        if (reason == 'quotaExceeded' || reason == 'dailyLimitExceeded') {
          throw OnlineException('YouTube: the free daily quota is used up');
        }
        if (r.statusCode == 400 || r.statusCode == 403) {
          throw OnlineException(
            'YouTube rejected the API key. Check it in Settings → Online services.',
          );
        }
        throw OnlineException('YouTube error (HTTP ${r.statusCode})');
      }
      return v;
    }

    // Official releases are uploaded to "Artist - Topic" channels in the Music category.
    final found = await yt('https://www.googleapis.com/youtube/v3/search', {
      'part': 'snippet',
      'q': '$artist $title',
      'type': 'video',
      'videoCategoryId': '10',
      'maxResults': '5',
    });
    final ids = [
      for (final i in list(at(found, 'items')))
        if ((str(at(i, 'snippet/channelTitle')) ?? '').endsWith(' - Topic'))
          ?str(at(i, 'id/videoId')),
    ].take(3).toList();
    if (ids.isEmpty) return [];
    final v = await yt('https://www.googleapis.com/youtube/v3/videos', {
      'part': 'snippet,contentDetails',
      'id': ids.join(','),
    });
    return [for (final i in list(at(v, 'items'))) ?parseYoutubeRelease(i)];
  }

  @override
  Future<List<CatalogMatch>> getsongbpmLookup(
    String apiKey,
    String artist,
    String title,
  ) async {
    await throttle('gsb', const Duration(milliseconds: 1300));
    final v = await getJson('https://api.getsong.co/search/', {
      'api_key': apiKey,
      'type': 'both',
      'lookup': 'song:$title artist:$artist',
    });
    if (str(at(v, 'search/error')) case final e?) {
      if (e.toLowerCase().contains('no result')) return [];
      throw OnlineException('GetSongBPM: $e');
    }
    return parseGetsongbpm(v);
  }

  @override
  Future<void> download(
    String url,
    String dest,
    bool Function(int bytes) progress,
  ) async {
    final f = File(dest);
    final have = f.existsSync() ? f.lengthSync() : 0;
    final req = http.Request('GET', Uri.parse(url));
    if (have > 0) req.headers['Range'] = 'bytes=$have-';
    final http.StreamedResponse res;
    try {
      res = await web.send(req).timeout(const Duration(seconds: 20));
    } on Exception catch (e) {
      throw OnlineException('download failed: $e');
    }
    if (res.statusCode == 416) return; // already complete
    if (res.statusCode >= 400) {
      throw OnlineException('download failed (HTTP ${res.statusCode})');
    }
    // 206 resumes; 200 means the server sent the whole file again
    final resumed = res.statusCode == 206;
    final out = f.openSync(mode: resumed ? FileMode.append : FileMode.write);
    var written = resumed ? have : 0;
    try {
      await for (final chunk in res.stream.timeout(
        const Duration(seconds: 120),
      )) {
        out.writeFromSync(chunk);
        written += chunk.length;
        if (!progress(written)) break;
      }
    } on TimeoutException {
      throw OnlineException('download interrupted: no data for 2 minutes');
    } on Exception catch (e) {
      throw OnlineException('download interrupted: $e');
    } finally {
      out.closeSync();
    }
  }
}
