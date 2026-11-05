/// JSON parsers for the online services (1.x `dj-online` parsers), kept apart
/// from the network code so they can be tested on sample replies.
library;

import '../core/keys.dart';
import 'online.dart';

Object? at(Object? v, String path) {
  Object? cur = v;
  for (final p in path.split('/').where((s) => s.isNotEmpty)) {
    if (cur is Map) {
      cur = cur[p];
    } else if (cur is List) {
      final i = int.tryParse(p);
      cur = (i != null && i >= 0 && i < cur.length) ? cur[i] : null;
    } else {
      return null;
    }
  }
  return cur;
}

String? str(Object? v) => v is String ? v : null;
int? integer(Object? v) => v is int
    ? v
    : (v is double && v == v.truncateToDouble() ? v.toInt() : null);
double? number(Object? v) => v is num ? v.toDouble() : null;
List<Object?> list(Object? v) => v is List ? v : const [];

/// Lucene phrase: escape backslash and double quote.
String luceneQuote(String s) =>
    '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// "afro house" -> "Afro House".
String titleCase(String g) => g
    .split(' ')
    .map((w) => w.isEmpty ? '' : w[0].toUpperCase() + w.substring(1))
    .join(' ');

/// Spotify-style pitch class (0 = C) and mode (1 = major) as a key name.
String? pitchClassKey(int key, int mode) {
  const n = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  if (key < 0 || key >= 12) return null;
  return '${n[key]}${mode == 1 ? '' : 'm'}';
}

/// The date [days] ago as YYYY-MM-DD (UTC).
String daysAgo(int days) {
  final d = DateTime.now().toUtc().subtract(Duration(days: days));
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

String _credit(Map r) =>
    list(r['artist-credit'])
        .whereType<Map>()
        .map((c) => '${str(c['name']) ?? ''}${str(c['joinphrase']) ?? ''}')
        .join();

CatalogMatch? parseDeezer(Object? track, Object? album) {
  final title = str(at(track, 'title'));
  final artist = str(at(track, 'artist/name'));
  if (title == null || artist == null) return null;
  String? text(Object? v) {
    final s = str(v);
    return (s == null || s.trim().isEmpty || s == '0000-00-00') ? null : s;
  }

  final dur = integer(at(track, 'duration'));
  final bpm = number(at(track, 'bpm'));
  return CatalogMatch(
    source: 'Deezer',
    title: title,
    artist: artist,
    album: text(at(track, 'album/title')),
    durationMs: (dur != null && dur > 0) ? dur * 1000 : null,
    bpm: (bpm != null && bpm > 0) ? bpm : null,
    releaseDate:
        text(at(track, 'release_date')) ?? text(at(album, 'release_date')),
    genres: [
      for (final g in list(at(album, 'genres/data'))) ?str(at(g, 'name')),
    ],
    label: text(at(album, 'label')),
    isrc: text(at(track, 'isrc')),
  );
}

CatalogMatch parseSpotifyTrack(Object? t) {
  final date = str(at(t, 'album/release_date'));
  return CatalogMatch(
    source: 'Spotify',
    title: str(at(t, 'name')) ?? '',
    artist: [for (final a in list(at(t, 'artists'))) ?str(at(a, 'name'))]
        .join(', '),
    album: str(at(t, 'album/name')),
    durationMs: integer(at(t, 'duration_ms')),
    releaseDate: (date == null || date.isEmpty) ? null : date,
    isrc: str(at(t, 'external_ids/isrc')),
  );
}

/// Spotify audio features (tempo, key, mode), when the app is allowed them.
void applyAudioFeatures(CatalogMatch m, Object? f) {
  final t = number(at(f, 'tempo'));
  m.bpm = (t != null && t > 0) ? t : null;
  final k = integer(at(f, 'key')), mode = integer(at(f, 'mode'));
  if (k != null && mode != null) m.key = pitchClassKey(k, mode);
}

/// ISO 8601 duration ("PT4M8S", "PT1H2M") in milliseconds.
int? isoDurationMs(String d) {
  if (!d.startsWith('PT')) return null;
  var total = 0;
  var num = '';
  for (final c in d.substring(2).split('')) {
    if (RegExp(r'\d').hasMatch(c)) {
      num += c;
    } else {
      final n = int.tryParse(num);
      if (n == null) return null;
      num = '';
      final unit = switch (c) {
        'H' => 3600000,
        'M' => 60000,
        'S' => 1000,
        _ => null,
      };
      if (unit == null) return null;
      total += n * unit;
    }
  }
  return total;
}

/// A YouTube Music release (an auto-generated "Artist - Topic" video).
CatalogMatch? parseYoutubeRelease(Object? v) {
  final channel = str(at(v, 'snippet/channelTitle'));
  if (channel == null || !channel.endsWith(' - Topic')) return null;
  final title = str(at(v, 'snippet/title'));
  if (title == null) return null;
  final desc = str(at(v, 'snippet/description')) ?? '';
  String? lineAfter(String prefix) {
    for (final l in desc.split('\n')) {
      final t = l.trim();
      if (t.startsWith(prefix)) return t.substring(prefix.length).trim();
    }
    return null;
  }

  final paras = desc
      .split('\n\n')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  final credit = paras.indexWhere((p) => p.contains(' · '));
  String? album;
  if (credit >= 0 && credit + 1 < paras.length) {
    final p = paras[credit + 1];
    if (!p.startsWith('℗') &&
        !p.startsWith('Released on') &&
        !p.contains('\n')) {
      album = p;
    }
  }
  var artist = channel.substring(0, channel.length - ' - Topic'.length);
  if (credit >= 0) {
    final parts = paras[credit].split(' · ');
    if (parts.length > 1) artist = parts[1];
  }
  final dur = str(at(v, 'contentDetails/duration'));
  return CatalogMatch(
    source: 'YouTube Music',
    title: title,
    artist: artist,
    album: album,
    durationMs: dur == null ? null : isoDurationMs(dur),
    releaseDate: lineAfter('Released on: '),
    label: lineAfter('Provided to YouTube by '),
  );
}

List<CatalogMatch> parseGetsongbpm(Object? v) => [
  for (final r in list(at(v, 'search')))
    if (str(at(r, 'title')) case final title?)
      if (str(at(r, 'artist/name')) case final artist?)
        CatalogMatch(
          source: 'GetSongBPM',
          title: title,
          artist: artist,
          album: str(at(r, 'album/title')),
          bpm: () {
            final t = at(r, 'tempo');
            final b = t is String ? double.tryParse(t.trim()) : number(t);
            return (b != null && b > 0) ? b : null;
          }(),
          releaseDate: switch (at(r, 'album/year')) {
            final String y => y,
            final int y => '$y',
            _ => null,
          },
          genres: [
            for (final g in list(at(r, 'artist/genres')))
              if (g is String) titleCase(g),
          ],
          key: switch (str(at(r, 'key_of'))) {
            final k? when k.trim().isNotEmpty => k,
            _ => null,
          },
        ),
];

List<CatalogMatch> parseItunes(Object? v) => [
  for (final r in list(at(v, 'results')))
    if (str(at(r, 'kind')) == null || str(at(r, 'kind')) == 'song')
      if (str(at(r, 'trackName')) case final title?)
        if (str(at(r, 'artistName')) case final artist?)
          CatalogMatch(
            source: 'Apple Music',
            title: title,
            artist: artist,
            album: str(at(r, 'collectionName')),
            durationMs: integer(at(r, 'trackTimeMillis')),
            releaseDate: switch (str(at(r, 'releaseDate'))) {
              final d? => d.length > 10 ? d.substring(0, 10) : d,
              null => null,
            },
            genres: [?str(at(r, 'primaryGenreName'))],
          ),
];

List<MbRecording> parseMbRecordings(Object? v) => [
  for (final r in list(at(v, 'recordings')).whereType<Map>())
    () {
      final tags = <(int, String)>[
        for (final t in list(r['tags']))
          if (str(at(t, 'name')) case final n?)
            (integer(at(t, 'count')) ?? 0, n),
      ];
      // stable sort by count, highest first (Rust sort_by_key is stable)
      final idx = List.generate(tags.length, (i) => i)
        ..sort((a, b) {
          final c = tags[b].$1.compareTo(tags[a].$1);
          return c != 0 ? c : a.compareTo(b);
        });
      final rels = list(r['releases']);
      Object? rel;
      for (final x in rels) {
        final d = at(x, 'date');
        if (d is! String) continue;
        if (rel == null || d.compareTo(str(at(rel, 'date')) ?? '9999') < 0) {
          rel = x;
        }
      }
      rel ??= rels.isEmpty ? null : rels.first;
      final first = str(r['first-release-date']);
      final dis = str(r['disambiguation']);
      return MbRecording(
        mbid: str(r['id']) ?? '',
        title: str(r['title']) ?? '',
        artist: _credit(r),
        score: number(r['score']) ?? 0,
        firstReleaseDate: (first == null || first.isEmpty) ? null : first,
        releaseTitle: str(at(rel, 'title')),
        tags: [for (final i in idx.take(5)) tags[i].$2],
        isrcs: [for (final i in list(r['isrcs'])) ?str(i)],
        lengthMs: integer(r['length']),
        disambiguation: (dis == null || dis.isEmpty) ? null : dis,
      );
    }(),
];

List<AcoustidMatch> parseAcoustid(Object? v) {
  if (at(v, 'status') != 'ok') {
    throw OnlineException(
      str(at(v, 'error/message')) ?? 'AcoustID lookup failed',
    );
  }
  final out = <AcoustidMatch>[];
  for (final r in list(at(v, 'results'))) {
    final score = number(at(r, 'score')) ?? 0;
    for (final rec in list(at(r, 'recordings'))) {
      final artists = [
        for (final a in list(at(rec, 'artists'))) ?str(at(a, 'name')),
      ].join(', ');
      out.add(
        AcoustidMatch(
          score: score,
          recordingMbid: str(at(rec, 'id')) ?? '',
          title: str(at(rec, 'title')),
          artist: artists.isEmpty ? null : artists,
        ),
      );
    }
  }
  // stable, highest score first
  final idx = List.generate(out.length, (i) => i)
    ..sort((a, b) {
      final c = out[b].score.compareTo(out[a].score);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in idx) out[i]];
}

void _lastfmError(Object? v) {
  final m = str(at(v, 'message'));
  if (m != null && at(v, 'error') is num) {
    throw OnlineException('Last.fm: $m');
  }
}

double _match(Object? m) => (m is String ? double.tryParse(m) : number(m)) ?? 0;

List<SimilarItem> parseLastfmArtists(Object? v) {
  _lastfmError(v);
  return [
    for (final x in list(at(v, 'similarartists/artist')))
      if (str(at(x, 'name')) case final n?)
        SimilarItem(
          artist: n,
          score: _match(at(x, 'match')),
          url: str(at(x, 'url')),
        ),
  ];
}

List<SimilarItem> parseLastfmTracks(Object? v) {
  _lastfmError(v);
  return [
    for (final x in list(at(v, 'similartracks/track')))
      if (str(at(x, 'artist/name')) case final a?)
        SimilarItem(
          artist: a,
          title: str(at(x, 'name')),
          score: _match(at(x, 'match')),
          url: str(at(x, 'url')),
        ),
  ];
}

/// A key in any notation as Camelot, when it is a real key.
String? camelotOf(String k) {
  final c = normalizeKey(k);
  return (c != null && parseCamelot(c) != null) ? c : null;
}
