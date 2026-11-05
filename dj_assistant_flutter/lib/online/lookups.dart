import '../core/catalogue.dart';
import '../core/jobs.dart';
import '../core/suggestions.dart';
import '../core/text.dart';
import 'online.dart';
import 'parsers.dart';

/// Online lookups that turn into suggestions (1.x `suggest.rs`, online part).
/// Every one checks first that the DJ switched its service on; results only
/// become suggestions for the DJ (or auto-prep, within its limits) to accept.

bool serviceEnabled(Catalogue cat, String svc) =>
    cat.getSetting('svc_$svc') == '1';

void requireService(Catalogue cat, String svc) {
  if (!serviceEnabled(cat, svc)) {
    throw SuggestionException(
      '$svc is turned off. Turn it on in Settings → Online services first.',
    );
  }
}

int? _yearOf(String? date) {
  if (date == null || date.length < 4) return null;
  final y = int.tryParse(date.substring(0, 4));
  return (y != null && y >= 1000 && y <= 9999) ? y : null;
}

Map<String, Object?> _row(Catalogue cat, int id, String cols) {
  final r = cat.db.select(
    'SELECT $cols FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
    'LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
    [id],
  );
  if (r.isEmpty) throw SuggestionException('track $id not found');
  return Map.of(r.first);
}

String _fmt(num v) => rustNumber(v.toDouble());

/// Picks the MusicBrainz results that match and records suggestions.
int applyMusicbrainz(Catalogue cat, int trackId, List<MbRecording> recs) {
  final r = _row(
    cat,
    trackId,
    'COALESCE(u.title,t.title) AS title, COALESCE(u.artist,t.artist) AS artist, '
    'COALESCE(u.album,t.album) AS album, COALESCE(u.genre,t.genre) AS genre, '
    'COALESCE(u.year,t.year) AS year, COALESCE(u.original_year,t.original_year) AS orig, '
    't.duration_ms AS dur',
  );
  final title = r['title'] as String?, artist = r['artist'] as String?;
  final album = r['album'] as String?, genre = r['genre'] as String?;
  final year = r['year'] as int?, orig = r['orig'] as int?;
  final dur = r['dur'] as int?;
  final wantT = title == null ? '' : baseTitle(title);
  final wantA = artist == null ? '' : baseArtist(artist);
  var n = 0;
  void put(String f, String? cur, String v, String ev, double c) =>
      insertSuggestion(cat, trackId, f, cur, v, 'MusicBrainz', ev, c);
  for (final m in recs.where((m) => m.score >= 80).take(3)) {
    final sameWork =
        baseTitle(m.title) == wantT && baseArtist(m.artist) == wantA;
    var durNote = '';
    if (dur != null && m.lengthMs != null) {
      final d = (dur - m.lengthMs!).abs() ~/ 1000;
      durNote = d > 15
          ? ' Length differs by $d s, so this may be a different version.'
          : ' Length matches within $d s.';
    }
    String ev(String what) =>
        'MusicBrainz recording "${m.title}" by ${m.artist}'
        '${m.disambiguation != null ? ' [${m.disambiguation}]' : ''} '
        '(search score ${m.score.toStringAsFixed(0)}). $what$durNote';
    final conf = (m.score / 100) * (sameWork ? 0.9 : 0.6);
    final y = _yearOf(m.firstReleaseDate);
    if (y != null) {
      put(
        'original_year',
        orig?.toString(),
        '$y',
        ev(
          'Earliest release date of this recording (original release year, not a reissue or remix year).',
        ),
        conf,
      );
      n++;
      if (year == null) {
        put(
          'year',
          null,
          '$y',
          ev('Your file has no year; this is the earliest release year.'),
          conf * 0.9,
        );
      }
    }
    if (!sameWork || title == null) {
      put('title', title, m.title, ev('Title as listed on MusicBrainz.'), conf);
      put(
        'artist',
        artist,
        m.artist,
        ev('Artist credit as listed on MusicBrainz.'),
        conf,
      );
      n += 2;
    }
    if (m.releaseTitle != null && album == null) {
      put(
        'album',
        null,
        m.releaseTitle!,
        ev('Release this recording appears on.'),
        conf * 0.8,
      );
      n++;
    }
    if (m.label != null) {
      put(
        'record_label',
        null,
        m.label!,
        ev('Label of that release.'),
        conf * 0.8,
      );
      n++;
    }
    if (genre == null && m.tags.isNotEmpty) {
      put(
        'genre',
        null,
        m.tags.first,
        ev('Most-used community tag for this recording.'),
        conf * 0.6,
      );
      n++;
    }
  }
  return n;
}

(String?, String?) _artistTitle(Catalogue cat, int id) {
  final r = cat.db.select(
    'SELECT COALESCE(u.artist,t.artist) AS a, COALESCE(u.title,t.title) AS t '
    'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?',
    [id],
  );
  return r.isEmpty
      ? (null, null)
      : (r.first['a'] as String?, r.first['t'] as String?);
}

Future<void> _spaced(DateTime started, int ms) async {
  final el = DateTime.now().difference(started).inMilliseconds;
  if (el < ms) await Future<void>.delayed(Duration(milliseconds: ms - el));
}

/// Looks tracks up on MusicBrainz (one request a second).
Future<void> musicbrainzLookup(
  Catalogue cat,
  Online online,
  List<int> ids,
  JobProgress p, {
  int spacingMs = 1100,
}) async {
  requireService(cat, 'musicbrainz');
  p.total = ids.length;
  for (final id in ids) {
    if (await p.checkpoint()) break;
    final (a, t) = _artistTitle(cat, id);
    if (a == null || t == null) {
      p.tick(ok: false);
      continue;
    }
    final started = DateTime.now();
    try {
      applyMusicbrainz(cat, id, await online.musicbrainzRecordings(a, t));
      p.tick();
    } on OnlineException catch (e) {
      p
        ..message = e.message
        ..tick(ok: false);
    }
    await _spaced(started, spacingMs);
  }
}

/// The catalogue BPM corrected for half/double time, and whether the audio
/// analysis agrees: (bpm to suggest, agrees).
(double, bool)? catalogBpm(double catalog, double? analysed) {
  if (catalog < 40 || catalog > 250) return null;
  double tidy(double b) {
    final r = b.roundToDouble();
    return (b - r).abs() < 0.15 ? r : (b * 100).roundToDouble() / 100;
  }

  if (analysed == null || analysed <= 0) return (tidy(catalog), false);
  for (final f in [1.0, 2.0, 0.5]) {
    final c = catalog * f;
    if ((c - analysed).abs() / analysed <= 0.03) return (tidy(c), true);
  }
  return (tidy(catalog), false);
}

String _normGenre(String g) => g
    .trim()
    .toLowerCase()
    .replaceAll(RegExp('[-/&]'), ' ')
    .split(RegExp(r'\s+'))
    .where((w) => w.isNotEmpty)
    .join(' ');

/// Is at least one music catalogue switched on (and keyed, where it needs one)?
bool catalogSourcesOn(Catalogue cat, Secrets secrets) =>
    serviceEnabled(cat, 'catalogs') ||
    (serviceEnabled(cat, 'spotify') && secrets.get('spotify') != null) ||
    (serviceEnabled(cat, 'getsongbpm') && secrets.get('getsongbpm') != null) ||
    (serviceEnabled(cat, 'youtube') && secrets.get('youtube') != null);

/// "Deezer, Spotify and Apple Music".
String _names(List<String> v) => switch (v.length) {
  0 => '',
  1 => v[0],
  _ => '${v.sublist(0, v.length - 1).join(', ')} and ${v.last}',
};

String _s(List<String> v) => v.length == 1 ? 's' : '';

/// Records suggestions from catalogue matches of the same recording. Values
/// several sources agree on (or the audio analysis confirms) get high
/// confidence; one source alone only fills empty fields.
int applyCatalog(Catalogue cat, int trackId, List<CatalogMatch> found) {
  final r = _row(
    cat,
    trackId,
    'COALESCE(u.title,t.title) AS title, COALESCE(u.artist,t.artist) AS artist, '
    'COALESCE(u.album,t.album) AS album, COALESCE(u.genre,t.genre) AS genre, '
    'COALESCE(u.year,t.year) AS year, COALESCE(u.bpm,t.bpm_tag,a.bpm) AS bpm, '
    'a.bpm AS analysed, COALESCE(u.record_label,t.label) AS label, '
    't.duration_ms AS dur, keynorm(COALESCE(u.musical_key,t.key_tag,a.camelot)) AS k, '
    'a.camelot AS akey',
  );
  final title = r['title'] as String?, artist = r['artist'] as String?;
  if (title == null || artist == null) return 0;
  final album = r['album'] as String?, genre = r['genre'] as String?;
  final year = r['year'] as int?;
  final bpm = (r['bpm'] as num?)?.toDouble();
  final analysed = (r['analysed'] as num?)?.toDouble();
  final label = r['label'] as String?, dur = r['dur'] as int?;
  final key = r['k'] as String?, aKey = r['akey'] as String?;
  final wantT = baseTitle(title), wantA = baseArtist(artist);

  int dist(CatalogMatch m) => (dur != null && m.durationMs != null)
      ? (dur - m.durationMs!).abs()
      : 1 << 62;
  final sorted = List.generate(found.length, (i) => i)
    ..sort((a, b) {
      final c = dist(found[a]).compareTo(dist(found[b]));
      return c != 0 ? c : a.compareTo(b);
    });
  final best = <(CatalogMatch, double)>[];
  for (final i in sorted) {
    final m = found[i];
    if (baseTitle(m.title) != wantT || baseArtist(m.artist) != wantA) continue;
    double fit;
    if (dur != null && m.durationMs != null) {
      final d = (dur - m.durationMs!).abs();
      if (d > 10000) continue; // another version
      fit = d <= 3000 ? 1.0 : 0.92;
    } else {
      fit = 0.85;
    }
    if (!best.any((b) => b.$1.source == m.source)) best.add((m, fit));
  }
  if (best.isEmpty) return 0;
  final fit = best.map((b) => b.$2).fold(0.0, (a, b) => a > b ? a : b);
  var n = 0;
  void put(String f, String? cur, String v, String src, String ev, double c) =>
      insertSuggestion(cat, trackId, f, cur, v, src, ev, c);

  // BPM: every source's tempo, checked against the audio analysis.
  final bpms = <(double, bool, String, double)>[
    for (final (m, f) in best)
      if (m.bpm != null)
        if (catalogBpm(m.bpm!, analysed) case (final v, final ok))
          (v, ok, m.source, f),
  ];
  final confirmed = bpms.where((b) => b.$2).toList();
  (double, double, String, String)? pick;
  if (confirmed.isNotEmpty) {
    final c = confirmed.first;
    final srcs = [for (final b in confirmed) b.$3];
    pick = (
      c.$1,
      (confirmed.length >= 2 ? 0.95 : 0.93) * c.$4,
      '${_names(srcs)} list${_s(srcs)} ${_fmt(c.$1)} BPM, and this file\'s audio analysis agrees '
          '(${(analysed ?? 0).toStringAsFixed(1)} BPM measured), so this is the exact tempo.',
      _names(srcs),
    );
  } else if (bpms.isNotEmpty) {
    final first = bpms.first;
    final agree = [
      for (final b in bpms)
        if ((b.$1 - first.$1).abs() / first.$1 <= 0.01) b.$3,
    ];
    final conf =
        (analysed != null ? 0.45 : (agree.length >= 2 ? 0.88 : 0.7)) * first.$4;
    final ev = analysed != null
        ? '${_names(agree)} list${_s(agree)} ${_fmt(first.$1)} BPM, but the audio analysis measured '
              '${analysed.toStringAsFixed(1)} BPM. Check by ear before accepting.'
        : "${_names(agree)} list${_s(agree)} ${_fmt(first.$1)} BPM. The file hasn't been analysed yet.";
    pick = (first.$1, conf, ev, _names(agree));
  }
  if (pick != null && (bpm == null || (bpm - pick.$1).abs() > 0.4)) {
    put(
      'bpm',
      bpm == null ? null : _fmt(bpm),
      _fmt(pick.$1),
      pick.$4,
      pick.$3,
      pick.$2,
    );
    n++;
  }

  // Musical key, checked against the audio analysis.
  final keys = <(String, String, double)>[
    for (final (m, f) in best)
      if (m.key != null)
        if (camelotOf(m.key!) case final k?) (k, m.source, f),
  ];
  if (keys.isNotEmpty) {
    final (k, _, f) = keys.first;
    final srcs = [
      for (final x in keys)
        if (x.$1 == k) x.$2,
    ];
    final audio = aKey == null ? null : camelotOf(aKey);
    final (double, String) ce;
    if (audio != null && audio == k) {
      ce = (
        0.93,
        '${_names(srcs)} list${_s(srcs)} the key as $k, and this file\'s audio analysis agrees.',
      );
    } else if (audio != null) {
      ce = (
        0.5,
        '${_names(srcs)} list${_s(srcs)} the key as $k, but the audio analysis found $audio. Check by ear before accepting.',
      );
    } else if (srcs.length >= 2) {
      ce = (0.86, '${_names(srcs)} agree the key is $k.');
    } else {
      ce = (0.65, '${srcs[0]} lists the key as $k.');
    }
    if (key != k) {
      put('key', key, k, _names(srcs), ce.$2, ce.$1 * f);
      n++;
    }
  }

  // Release year: the earliest any source lists.
  final years = <(int, String)>[
    for (final (m, _) in best)
      if (_yearOf(m.releaseDate) case final y?) (y, m.source),
  ];
  if (years.isNotEmpty) {
    var y = years.first.$1;
    for (final v in years) {
      if (v.$1 < y) y = v.$1;
    }
    final srcs = [
      for (final v in years)
        if (v.$1 == y) v.$2,
    ];
    final agree = srcs.length >= 2;
    if (year != y) {
      final ev = agree
          ? '${_names(srcs)} ${srcs.length == 2 ? 'both' : 'all'} list this recording as released in $y.'
          : '${srcs[0]} lists this recording as released in $y; other sources may differ (reissues and compilations show later years).';
      put(
        'year',
        year?.toString(),
        '$y',
        agree ? srcs.join(' + ') : srcs[0],
        ev,
        (agree ? 0.9 : 0.62) * fit,
      );
      n++;
    }
  }

  // Genre: Apple Music's is the most specific, then Spotify's, Deezer's, GetSongBPM's.
  final genres = <(String, String)>[];
  for (final o in ['Apple Music', 'Spotify', 'Deezer', 'GetSongBPM']) {
    final m = best.where((b) => b.$1.source == o).firstOrNull?.$1;
    if (m == null || m.genres.isEmpty) continue;
    final g = m.genres.first;
    if (g.trim().isNotEmpty &&
        !['music', 'other', 'unknown'].contains(_normGenre(g))) {
      genres.add((g, o));
    }
  }
  if (genres.isNotEmpty) {
    final g = genres.first.$1;
    final srcs = [
      for (final x in genres)
        if (_normGenre(x.$1) == _normGenre(g)) x.$2,
    ];
    final agree = srcs.length >= 2;
    if (genre == null || _normGenre(genre) != _normGenre(g)) {
      put(
        'genre',
        genre,
        g,
        srcs.join(' + '),
        agree
            ? '${_names(srcs)} file this recording under $g.'
            : '${srcs[0]} files this recording under $g.',
        (genre != null ? 0.7 : (agree ? 0.88 : 0.6)) * fit,
      );
      n++;
    }
  }

  // Artist credit: differences the sources agree on are suggested.
  final credits = [for (final (m, _) in best) (m.artist, m.source)];
  final other = credits.where((c) => c.$1 != artist).firstOrNull;
  if (other != null) {
    final srcs = [
      for (final x in credits)
        if (x.$1 == other.$1) x.$2,
    ];
    if (srcs.length >= 2) {
      put(
        'artist',
        artist,
        other.$1,
        srcs.join(' + '),
        '${_names(srcs)} credit this recording to "${other.$1}".',
        0.7 * fit,
      );
      n++;
    }
  }
  if (album == null) {
    final albums = [
      for (final (m, _) in best)
        if (m.album != null) (m.album!, m.source),
    ];
    if (albums.isNotEmpty) {
      final al = albums.first.$1;
      final srcs = [
        for (final x in albums)
          if (fold(x.$1) == fold(al)) x.$2,
      ];
      put(
        'album',
        null,
        al,
        srcs.join(' + '),
        '${_names(srcs)} list${_s(srcs)} this recording on "$al".',
        (srcs.length >= 2 ? 0.85 : 0.65) * fit,
      );
      n++;
    }
  }

  // Record label: fills an empty field only.
  if (label == null) {
    final hit = best
        .where((b) => (b.$1.label ?? '').trim().isNotEmpty)
        .firstOrNull;
    if (hit != null) {
      final l = hit.$1.label!;
      put(
        'record_label',
        null,
        l,
        hit.$1.source,
        '${hit.$1.source} lists the label of this release as $l.',
        0.7 * hit.$2,
      );
      n++;
    }
  }
  return n;
}

/// Looks tracks up in every switched-on catalogue and records suggestions.
Future<int> catalogLookup(
  Catalogue cat,
  Online online,
  Secrets secrets,
  List<int> ids,
  JobProgress p,
) async {
  final free = serviceEnabled(cat, 'catalogs');
  String? keyFor(String s) => serviceEnabled(cat, s) ? secrets.get(s) : null;
  final spotify = keyFor('spotify'), gsb = keyFor('getsongbpm');
  var yt = keyFor('youtube');
  if (!free && spotify == null && gsb == null && yt == null) {
    throw SuggestionException(
      'Turn on Deezer & Apple Music, Spotify, GetSongBPM or YouTube in Settings → Online services first.',
    );
  }
  p.total = ids.length;
  var n = 0;
  for (final id in ids) {
    if (await p.checkpoint()) break;
    final (a, t) = _artistTitle(cat, id);
    if (a == null || t == null) {
      p.tick(ok: false);
      continue;
    }
    final all = <CatalogMatch>[];
    final errors = <String>[];
    Future<void> take(Future<List<CatalogMatch>> Function() f) async {
      try {
        all.addAll(await f());
      } on OnlineException catch (e) {
        errors.add(e.message);
      }
    }

    if (free) await take(() => online.catalogLookup(a, t));
    if (spotify != null) await take(() => online.spotifyLookup(spotify, a, t));
    if (gsb != null) await take(() => online.getsongbpmLookup(gsb, a, t));
    final hadYt = yt != null;
    if (yt != null) {
      final k = yt;
      try {
        all.addAll(await online.youtubeLookup(k, a, t));
      } on OnlineException catch (e) {
        if (e.message.contains('quota')) {
          // the free daily quota is used up: carry on without YouTube today
          p.message = "YouTube's free daily quota is used up; continuing with the other sources.";
          yt = null;
        }
        errors.add(e.message);
      }
    }
    final sources =
        (free ? 1 : 0) +
        (spotify != null ? 1 : 0) +
        (gsb != null ? 1 : 0) +
        (hadYt ? 1 : 0);
    if (errors.length == sources) {
      p
        ..message = errors.join('; ')
        ..tick(ok: false);
      continue;
    }
    n += applyCatalog(cat, id, all);
    cat.db.execute(
      'INSERT INTO catalog_checked(track_id, checked_at) VALUES (?, ?) '
      'ON CONFLICT(track_id) DO UPDATE SET checked_at=excluded.checked_at',
      [id, nowMs()],
    );
    p.tick();
  }
  return n;
}

/// Fingerprint lookup. The UI asks the DJ before each run.
Future<void> acoustidLookup(
  Catalogue cat,
  Online online,
  Secrets secrets,
  List<int> ids,
  JobProgress p, {
  int spacingMs = 350,
}) async {
  requireService(cat, 'acoustid');
  final key = secrets.get('acoustid');
  if (key == null) {
    throw SuggestionException(
      'Add your AcoustID application key in Settings first.',
    );
  }
  p.total = ids.length;
  for (final id in ids) {
    if (await p.checkpoint()) break;
    final fp = cat.db.select(
      'SELECT fingerprint_encoded AS f, duration_ms AS d FROM analysis '
      'WHERE track_id=? AND fingerprint_encoded IS NOT NULL',
      [id],
    );
    if (fp.isEmpty) {
      p
        ..message = 'Some tracks have not been analysed yet; analyse them first to create a fingerprint.'
        ..tick(ok: false);
      continue;
    }
    final started = DateTime.now();
    try {
      final matches = await online.acoustidLookup(
        key,
        (fp.first['d'] as int) ~/ 1000,
        fp.first['f'] as String,
      );
      final (artist, title) = _artistTitle(cat, id);
      for (final m in matches.where((m) => m.score >= 0.5).take(2)) {
        final ev =
            'Audio fingerprint matched AcoustID recording ${m.recordingMbid} with score '
            '${m.score.toStringAsFixed(2)}. A fingerprint match is a candidate, not proof of the exact version or release.';
        if (m.title != null) {
          insertSuggestion(
            cat,
            id,
            'title',
            title,
            m.title!,
            'AcoustID',
            ev,
            m.score * 0.8,
          );
        }
        if (m.artist != null) {
          insertSuggestion(
            cat,
            id,
            'artist',
            artist,
            m.artist!,
            'AcoustID',
            ev,
            m.score * 0.8,
          );
        }
        if (m.firstYear != null) {
          insertSuggestion(
            cat,
            id,
            'original_year',
            null,
            '${m.firstYear}',
            'AcoustID',
            ev,
            m.score * 0.6,
          );
        }
      }
      p.tick();
    } on OnlineException catch (e) {
      p
        ..message = e.message
        ..tick(ok: false);
    }
    await _spaced(started, spacingMs);
  }
}

List<int> _ids(Catalogue cat, String extra, int limit) => [
  for (final r in cat.db.select(
    'SELECT t.id FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
    "WHERE t.presence='present' AND t.read_status='ok' AND t.media_kind='audio' "
    'AND COALESCE(u.artist, t.artist) IS NOT NULL AND COALESCE(u.title, t.title) IS NOT NULL '
    'AND $extra ORDER BY t.first_seen_at DESC LIMIT $limit',
  ))
    r['id'] as int,
];

/// The online steps of auto-prep (1.x `autoprep.rs`): MusicBrainz for tracks
/// missing a year or genre, then the catalogues for tracks not checked yet.
/// Each runs only when its service is on. [online] and [secrets] are made
/// inside the job's isolate.
Future<int> autoPrepOnline(
  Catalogue cat,
  JobProgress p,
  Online online,
  Secrets secrets,
) async {
  var n = 0;
  if (serviceEnabled(cat, 'musicbrainz')) {
    final ids = _ids(
      cat,
      '(COALESCE(u.year, t.year) IS NULL OR COALESCE(u.genre, t.genre) IS NULL)',
      200,
    );
    if (ids.isNotEmpty) {
      p.message =
          'Looking up ${ids.length} track(s) on MusicBrainz (one per second)…';
      n += ids.length;
      await musicbrainzLookup(cat, online, ids, p);
    }
  }
  if (catalogSourcesOn(cat, secrets) && !await p.checkpoint()) {
    final ids = _ids(
      cat,
      't.id NOT IN (SELECT track_id FROM catalog_checked)',
      300,
    );
    if (ids.isNotEmpty) {
      p.message =
          'Checking BPM, key, year, genre and credits of ${ids.length} track(s) against online music catalogues…';
      n += ids.length;
      await catalogLookup(cat, online, secrets, ids, p);
    }
  }
  return n;
}
