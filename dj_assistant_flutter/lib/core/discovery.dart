import 'dart:convert';
import 'dart:math' as math;

import '../online/lookups.dart';
import '../online/online.dart';
import 'catalogue.dart';
import 'crates.dart';
import 'library.dart';
import 'library_edit.dart';
import 'profile.dart';
import 'text.dart';

class DiscoveryException implements Exception {
  DiscoveryException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A library track that fits, with its reasons.
class Recommendation {
  Recommendation(
    this.trackId,
    this.track,
    this.score,
    this.reasons,
    this.source,
  );
  final int trackId;
  final String track, source;
  final double score;
  final List<String> reasons;
  Map<String, Object?> toJson() => {
    'track_id': trackId,
    'track': track,
    'score': score,
    'reasons': reasons,
    'source': source,
  };
}

String _tpVersion(Tp t) => t.version ?? versionOf(t.title);
double _r2(double v) => (v * 100).roundToDouble() / 100;

/// Discovery and recommendations (1.x `discovery.rs`). Every recommendation
/// carries its reason, source and date. Listening similarity is never offered
/// as proof that two tracks mix well.
class DiscoveryService {
  DiscoveryService(this.cat);
  final Catalogue cat;

  bool get learningEnabled =>
      (cat.getSetting('learning_enabled') ?? '1') == '1';

  /// What the app has learned from ratings, plays and likes. Fully inspectable.
  Map<String, Object?> preferences() {
    final genre = <String, (double, int)>{}, artist = <String, (double, int)>{};
    for (final t in loadProfiles(cat)) {
      final w =
          (t.rating == null ? 0.0 : (t.rating! - 3) / 2) +
          math.min(t.plays, 10) * 0.1;
      if (w == 0) continue;
      void add(Map<String, (double, int)> m, String k) {
        final e = m[k] ?? (0.0, 0);
        m[k] = (e.$1 + w, e.$2 + 1);
      }

      if (t.genre != null) add(genre, t.genre!);
      if (t.artist.isNotEmpty) add(artist, t.artist);
    }
    List<Map<String, Object?>> top(Map<String, (double, int)> m) {
      final v = [
        for (final e in m.entries) (e.key, e.value.$1 / e.value.$2, e.value.$2),
      ]..sort((a, b) => b.$2.compareTo(a.$2));
      return [
        for (final x in v.take(15))
          {'name': x.$1, 'weight': _r2(x.$2), 'tracks': x.$3},
      ];
    }

    return {
      'enabled': learningEnabled,
      'explanation': 'Weights come from your star ratings (above or below 3★), how often tracks were played (gig mode and imported history) and the likes/dislikes you gave recommendations. Nothing else is used — personal files never are.',
      'genres': top(genre),
      'artists': top(artist),
      'feedback': [
        for (final r in cat.db.select(
          'SELECT subject_kind AS kind, subject, value, at FROM pref_feedback ORDER BY at DESC',
        ))
          Map.of(r),
      ],
    };
  }

  void feedback(String kind, String subject, int value) {
    if (!['genre', 'artist', 'track'].contains(kind) ||
        ![-1, 0, 1].contains(value)) {
      throw DiscoveryException('bad feedback');
    }
    if (value == 0) {
      cat.db.execute(
        'DELETE FROM pref_feedback WHERE subject_kind=? AND subject=?',
        [kind, subject],
      );
    } else {
      cat.db.execute(
        'INSERT INTO pref_feedback(subject_kind, subject, value, at) VALUES (?,?,?,?) '
        'ON CONFLICT(subject_kind, subject) DO UPDATE SET value=excluded.value, at=excluded.at',
        [kind, subject, value, nowMs()],
      );
    }
  }

  int resetLearning() {
    cat.db.execute('DELETE FROM pref_feedback');
    return cat.db.updatedRows;
  }

  Map<(String, String), int> _feedback() => !learningEnabled
      ? {}
      : {
          for (final r in cat.db.select(
            'SELECT subject_kind, subject, value FROM pref_feedback',
          ))
            (r['subject_kind'] as String, fold(r['subject'] as String)):
                r['value'] as int,
        };

  Set<int> _members(int crateId) => LibraryService(cat)
      .trackIds(TrackQuery(extraWhere: CratesService(cat).membership(crateId)))
      .toSet();

  /// Library tracks (not in the crate) that fit the crate's profile.
  List<Recommendation> crateFit(int crateId, {int limit = 50}) {
    final tps = loadProfiles(cat);
    final ids = _members(crateId);
    if (ids.isEmpty) {
      throw DiscoveryException(
        'this crate is empty; add a few tracks first so there is something to compare with',
      );
    }
    final members = tps.where((t) => ids.contains(t.id)).toList();
    final n = members.length;
    final genres = <String, int>{}, artists = <String, int>{};
    final bpms = <double>[], energies = <double>[], years = <int>[];
    for (final t in members) {
      if (t.genre != null) genres[t.genreFold] = (genres[t.genreFold] ?? 0) + 1;
      if (t.artist.isNotEmpty) {
        final a = baseArtist(t.artist);
        artists[a] = (artists[a] ?? 0) + 1;
      }
      if (t.bpm != null) bpms.add(t.bpm!);
      if (t.energy != null) energies.add(t.energy!.toDouble());
      if (t.year != null) years.add(t.year!);
    }
    (double, double)? meanSd(List<double> v) {
      if (v.isEmpty) return null;
      final m = v.reduce((a, b) => a + b) / v.length;
      final sd = math.sqrt(
        v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length,
      );
      return (m, sd);
    }

    final bpm = meanSd(bpms), energy = meanSd(energies);
    final yr = years.isEmpty
        ? null
        : (years.reduce(math.min), years.reduce(math.max));
    final fb = _feedback();
    final recs = <Recommendation>[];
    for (final t in tps.where((t) => !ids.contains(t.id))) {
      var score = 0.0;
      final reasons = <String>[];
      if (genres[t.genreFold] case final g?) {
        final share = g / n;
        score += 3 * share;
        reasons.add(
          'Genre ${t.genre ?? ''} (${(share * 100).toStringAsFixed(0)}% of the crate)',
        );
      }
      if (artists[baseArtist(t.artist)] case final c?) {
        score += 1.5;
        reasons.add('Artist ${t.artist} already has $c track(s) in the crate');
      }
      if (bpm != null && t.bpm != null) {
        final tol = math.max(bpm.$2 / bpm.$1, 0.04);
        if (bpmDistance(t.bpm!, bpm.$1) <= tol) {
          score += 1.5;
          reasons.add(
            "BPM ${t.bpm!.toStringAsFixed(0)} is in the crate's range (around ${bpm.$1.toStringAsFixed(0)})",
          );
        }
      }
      if (energy != null && t.energy != null) {
        if ((t.energy! - energy.$1).abs() <= math.max(energy.$2, 1.0)) {
          score += 1;
          reasons.add(
            'Energy ${t.energy} matches the crate (around ${energy.$1.toStringAsFixed(0)})',
          );
        }
      }
      if (yr != null && t.year != null) {
        if (t.year! >= yr.$1 - 1 && t.year! <= yr.$2 + 1) {
          score += 0.7;
          reasons.add('Year ${t.year} is within ${yr.$1}–${yr.$2}');
        }
      }
      if (t.rating != null) score += (t.rating! - 3) * 0.3;
      if (fb[('artist', fold(t.artist))] case final v?) {
        score += v;
        reasons.add(
          v > 0
              ? 'You liked this artist'
              : 'You marked this artist as not for you',
        );
      }
      if (t.genre != null) {
        if (fb[('genre', fold(t.genre!))] case final v?) score += v * 0.8;
      }
      if (score >= 2.5 && reasons.length >= 2) {
        recs.add(
          Recommendation(t.id, t.label, _r2(score), reasons, 'Your library'),
        );
      }
    }
    _stableSort(recs, (a, b) => b.score.compareTo(a.score));
    return recs.take(limit).toList();
  }

  /// Artists you collect who are thin in the crate, and how its decades
  /// compare with the whole library.
  Map<String, Object?> gaps(int crateId) {
    final tps = loadProfiles(cat);
    final ids = _members(crateId);
    final members = tps.where((t) => ids.contains(t.id)).toList();
    final byArtist = <String, (String, int, int)>{};
    for (final t in tps) {
      if (t.artist.isEmpty) continue;
      final k = baseArtist(t.artist);
      final e = byArtist[k] ?? (t.artist, 0, 0);
      byArtist[k] = (e.$1, e.$2 + 1, e.$3 + (ids.contains(t.id) ? 1 : 0));
    }
    final artists = [
      for (final (name, total, inc) in byArtist.values)
        if (inc > 0 && total > inc)
          {
            'artist': name,
            'in_crate': inc,
            'in_library': total,
            'reason': '$inc of your $total $name tracks are in this crate',
          },
    ];
    _stableSort(
      artists,
      (a, b) => ((b['in_library']! as int) - (b['in_crate']! as int)).compareTo(
        (a['in_library']! as int) - (a['in_crate']! as int),
      ),
    );
    Map<int, int> decades(Iterable<Tp> s) {
      final m = <int, int>{};
      for (final t in s) {
        if (t.year != null) {
          m[t.year! ~/ 10 * 10] = (m[t.year! ~/ 10 * 10] ?? 0) + 1;
        }
      }
      return m;
    }

    final lib = decades(tps), cr = decades(members);
    final dec = [
      for (final e in lib.entries)
        {'decade': e.key, 'library': e.value, 'crate': cr[e.key] ?? 0},
    ]..sort((a, b) => (a['decade']!).compareTo(b['decade']!));
    return {
      'artists': artists.take(20).toList(),
      'decades': dec,
      'missing_energy': members.where((t) => t.energy == null).length,
      'missing_bpm': members.where((t) => t.bpm == null).length,
      'size': members.length,
    };
  }

  /// Most-played tracks with fresher alternatives (same genre, tempo, energy).
  List<Map<String, Object?>> overplayed({int limit = 20}) {
    final tps = loadProfiles(cat);
    final played = tps.where((t) => t.plays >= 2).toList();
    _stableSort(played, (a, b) => b.plays.compareTo(a.plays));
    return [
      for (final t in played.take(limit))
        () {
          final alts = <(double, Tp)>[];
          for (final o in tps) {
            if (o.id == t.id ||
                o.plays >= t.plays ~/ 2 + 1 ||
                o.workKey == t.workKey) {
              continue;
            }
            var s = 0.0;
            if (o.genreFold == t.genreFold && o.genre != null) s += 2;
            if (o.bpm != null &&
                t.bpm != null &&
                bpmDistance(o.bpm!, t.bpm!) < 0.04) {
              s += 1.5;
            }
            if (o.energy != null &&
                t.energy != null &&
                (o.energy! - t.energy!).abs() <= 1) {
              s += 1;
            }
            if (s >= 3) alts.add((s, o));
          }
          _stableSort(alts, (a, b) => b.$1.compareTo(a.$1));
          return <String, Object?>{
            'track_id': t.id,
            'track': t.label,
            'plays': t.plays,
            'alternatives': [
              for (final (s, o) in alts.take(5))
                {
                  'track_id': o.id,
                  'track': o.label,
                  'plays': o.plays,
                  'score': s,
                },
            ],
          };
        }(),
    ];
  }

  /// Matches a pasted tracklist against the library. Unknown entries (ID - ID,
  /// unparseable lines) are kept, never dropped.
  Map<String, Object?> matchTracklist(String text) {
    if (text.length > 200000) throw DiscoveryException('tracklist is too long');
    final tps = loadProfiles(cat);
    final exact = <String, List<Tp>>{}, byTitle = <String, List<Tp>>{};
    for (final t in tps) {
      exact
          .putIfAbsent(
            '${baseArtist(t.artist)}|${baseTitle(t.title)}',
            () => [],
          )
          .add(t);
      byTitle.putIfAbsent(baseTitle(t.title), () => []).add(t);
    }
    final lines = <Map<String, Object?>>[];
    var owned = 0, possible = 0, missing = 0, unknown = 0;
    final raw = const LineSplitter().convert(text);
    for (var i = 0; i < raw.length; i++) {
      final line = raw[i];
      if (line.trim().isEmpty) continue;
      final base = {'line': i + 1, 'text': line.trim()};
      final parsed = parseTracklistLine(line);
      if (parsed == null) {
        unknown++;
        lines.add({
          ...base,
          'status': 'unknown',
          'note': 'Could not read artist and title from this line.',
        });
        continue;
      }
      final (a, t) = parsed;
      if (fold(a) == 'id' || fold(t) == 'id' || fold(t) == 'id?') {
        unknown++;
        lines.add({
          ...base,
          'status': 'unknown',
          'note': 'Unidentified track (ID) — kept as unknown.',
        });
        continue;
      }
      final at = {...base, 'artist': a, 'title': t};
      final want = versionOf(t);
      final cands = exact['${baseArtist(a)}|${baseTitle(t)}'] ?? const <Tp>[];
      final same = cands.where((m) => _tpVersion(m) == want).firstOrNull;
      if (same != null) {
        owned++;
        lines.add({
          ...at,
          'status': 'owned',
          'track_id': same.id,
          'match': same.label,
        });
      } else if (cands.isNotEmpty) {
        possible++;
        final v = _tpVersion(cands.first);
        lines.add({
          ...at,
          'status': 'possibly_owned',
          'track_id': cands.first.id,
          'match': cands.first.label,
          'note':
              'You have a different version (${v.isEmpty ? 'original' : v}). Versions are not treated as the same track.',
        });
      } else if ((byTitle[baseTitle(t)] ?? const <Tp>[])
              .where(
                (m) =>
                    fold(m.artist).contains(baseArtist(a)) ||
                    baseArtist(a).contains(baseArtist(m.artist)),
              )
              .firstOrNull
          case final c?) {
        possible++;
        lines.add({
          ...at,
          'status': 'possibly_owned',
          'track_id': c.id,
          'match': c.label,
          'note': 'Same title, similar artist credit — check it is the same version.',
        });
      } else {
        missing++;
        lines.add({...at, 'status': 'missing'});
      }
    }
    return {
      'lines': lines,
      'owned': owned,
      'possibly_owned': possible,
      'missing': missing,
      'unknown': unknown,
      'note': 'Not every track in a DJ mix can be identified; unknown entries are kept as they are.',
    };
  }

  (String, int?) _ownership(List<Tp> tps, String artist, String? title) {
    final a = baseArtist(artist);
    if (title == null) {
      final m = tps.where((x) => baseArtist(x.artist) == a).firstOrNull;
      return m == null ? ('missing', null) : ('owned', m.id);
    }
    final bt = baseTitle(title), want = versionOf(title);
    for (final (status, test) in <(String, bool Function(Tp))>[
      (
        'owned',
        (x) =>
            baseArtist(x.artist) == a &&
            baseTitle(x.title) == bt &&
            _tpVersion(x) == want,
      ),
      (
        'possibly_owned',
        (x) => baseArtist(x.artist) == a && baseTitle(x.title) == bt,
      ),
      (
        'possibly_owned',
        (x) => baseTitle(x.title) == bt && fold(x.artist).contains(a),
      ),
    ]) {
      final m = tps.where(test).firstOrNull;
      if (m != null) return (status, m.id);
    }
    return ('missing', null);
  }

  void _store(
    String source,
    String kind,
    String artist,
    String? title,
    String detail,
    String reason,
    String? url,
    String? released,
    (String, int?) own,
  ) => cat.db.execute(
    'INSERT INTO discovery (source, kind, artist, title, detail, reason, url, released, fetched_at, owned_track_id, ownership) '
    'VALUES (?,?,?,?,?,?,?,?,?,?,?) '
    'ON CONFLICT(source, kind, artist, title) DO UPDATE SET detail=excluded.detail, reason=excluded.reason, fetched_at=excluded.fetched_at, '
    'owned_track_id=excluded.owned_track_id, ownership=excluded.ownership, released=excluded.released',
    [
      source,
      kind,
      artist,
      title ?? '',
      detail,
      reason,
      url,
      released,
      nowMs(),
      own.$2,
      own.$1,
    ],
  );

  String _lastfmKey(Secrets secrets) {
    requireService(cat, 'lastfm');
    final key = secrets.get('lastfm');
    if (key == null) {
      throw DiscoveryException('Add your Last.fm API key in Settings first.');
    }
    return key;
  }

  /// Last.fm similar artists for a crate's most common artists.
  Future<int> lastfmForCrate(
    Online online,
    Secrets secrets,
    int crateId, {
    int pauseMs = 250,
  }) async {
    final key = _lastfmKey(secrets);
    final tps = loadProfiles(cat);
    final ids = _members(crateId);
    final counts = <String, (String, int)>{};
    for (final t in tps.where(
      (t) => ids.contains(t.id) && t.artist.isNotEmpty,
    )) {
      final k = baseArtist(t.artist);
      final e = counts[k] ?? (t.artist, 0);
      counts[k] = (e.$1, e.$2 + 1);
    }
    final top = counts.values.toList();
    _stableSort(top, (a, b) => b.$2.compareTo(a.$2));
    var n = 0;
    for (final (artist, _) in top.take(5)) {
      final List<SimilarItem> sims;
      try {
        sims = await online.lastfmSimilarArtists(key, artist);
      } on OnlineException catch (e) {
        throw DiscoveryException(e.message);
      }
      for (final s in sims.take(12)) {
        _store(
          'Last.fm',
          'artist',
          s.artist,
          null,
          'Similarity ${(s.score * 100).toStringAsFixed(0)}%',
          'Similar to $artist on Last.fm (listening similarity, not a mixing guarantee).',
          s.url,
          null,
          _ownership(tps, s.artist, null),
        );
        n++;
      }
      await Future<void>.delayed(Duration(milliseconds: pauseMs));
    }
    return n;
  }

  Future<int> lastfmForTrack(
    Online online,
    Secrets secrets,
    int trackId,
  ) async {
    final key = _lastfmKey(secrets);
    final tps = loadProfiles(cat);
    final t = tps.where((t) => t.id == trackId).firstOrNull;
    if (t == null) throw DiscoveryException('track not found');
    final List<SimilarItem> sims;
    try {
      sims = await online.lastfmSimilarTracks(
        key,
        t.artist,
        baseTitle(t.title),
      );
    } on OnlineException catch (e) {
      throw DiscoveryException(e.message);
    }
    for (final s in sims) {
      _store(
        'Last.fm',
        'track',
        s.artist,
        s.title,
        'Similarity ${(s.score * 100).toStringAsFixed(0)}%',
        'Listeners of ${t.label} also play this (Last.fm).',
        s.url,
        null,
        _ownership(tps, s.artist, s.title),
      );
    }
    return sims.length;
  }

  void follow(String kind, String name) {
    final n = name.trim();
    if (n.isEmpty || n.length > 200 || !['artist', 'label'].contains(kind)) {
      throw DiscoveryException('enter an artist name');
    }
    cat.db.execute(
      'INSERT OR IGNORE INTO followed(kind, name, added_at) VALUES (?,?,?)',
      [kind, n, nowMs()],
    );
  }

  void unfollow(int id) =>
      cat.db.execute('DELETE FROM followed WHERE id=?', [id]);

  List<Map<String, Object?>> followed() => [
    for (final r in cat.db.select(
      'SELECT id, kind, name, added_at FROM followed ORDER BY name',
    ))
      Map.of(r),
  ];

  /// New releases (last 365 days) for followed artists, from MusicBrainz.
  Future<int> refreshReleases(Online online, {int pauseMs = 1100}) async {
    requireService(cat, 'musicbrainz');
    final tps = loadProfiles(cat);
    var n = 0;
    for (final f in followed().where((f) => f['kind'] == 'artist')) {
      final a = f['name']! as String;
      final List<ReleaseItem> rels;
      try {
        rels = await online.musicbrainzArtistReleases(a);
      } on OnlineException catch (e) {
        throw DiscoveryException(e.message);
      }
      for (final r in rels) {
        _store(
          'MusicBrainz',
          'release',
          r.artist,
          r.title,
          r.kind,
          'New ${r.kind.toLowerCase()} from $a, an artist you follow.',
          r.url,
          r.date,
          _ownership(tps, r.artist, r.title),
        );
        n++;
      }
      await Future<void>.delayed(Duration(milliseconds: pauseMs));
    }
    return n;
  }

  List<Map<String, Object?>> items({String? status}) => [
    for (final r in cat.db.select(
      'SELECT id, source, kind, artist, title, detail, reason, url, released, fetched_at, owned_track_id, ownership, status FROM discovery '
      "WHERE (? IS NULL AND status<>'dismissed') OR status=? ORDER BY fetched_at DESC, id LIMIT 500",
      [status, status],
    ))
      Map.of(r),
  ];

  void setItemStatus(int id, String status) {
    if (!['new', 'wishlist', 'dismissed'].contains(status)) {
      throw DiscoveryException('bad status');
    }
    cat.db.execute('UPDATE discovery SET status=? WHERE id=?', [status, id]);
  }
}

/// One tracklist line as (artist, title); null when it can't be read.
(String, String)? parseTracklistLine(String line) {
  var s = line.trim();
  // strip leading numbering / timestamps like "01.", "1)", "[00:12:30]", "12:30"
  while (true) {
    final t = s.trimLeft();
    var n = 0;
    while (n < t.length && RegExp(r'[0-9:\[\]]').hasMatch(t[n])) {
      n++;
    }
    if (n > 0 && RegExp(r'\d').hasMatch(t.substring(0, n))) {
      s = t.substring(n).replaceFirst(RegExp(r'^[.)\- \t]+'), '');
      continue;
    }
    break;
  }
  s = s.split(' [').first.trim();
  for (final sep in [' - ', ' – ', ' — ']) {
    final i = s.indexOf(sep);
    if (i >= 0) {
      return (s.substring(0, i).trim(), s.substring(i + sep.length).trim());
    }
  }
  return null;
}

/// Search links for buying or previewing music from legitimate stores (links
/// only: nothing is downloaded).
List<Map<String, String>> storeLinks(String artist, String title) {
  final sb = StringBuffer();
  for (final b in utf8.encode('$artist $title')) {
    final c = String.fromCharCode(b);
    if (RegExp(r'[A-Za-z0-9\-_.~]').hasMatch(c)) {
      sb.write(c);
    } else if (b == 0x20) {
      sb.write('+');
    } else {
      sb.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  final enc = sb.toString();
  return [
    ('Beatport', 'https://www.beatport.com/search?q=$enc'),
    ('Bandcamp', 'https://bandcamp.com/search?q=$enc'),
    ('Traxsource', 'https://www.traxsource.com/search?term=$enc'),
    (
      'Juno Download',
      'https://www.junodownload.com/search/?q%5Ball%5D%5B%5D=$enc',
    ),
    ('Apple Music / iTunes', 'https://music.apple.com/search?term=$enc'),
    ('Amazon Music', 'https://www.amazon.com/s?k=$enc&i=digital-music'),
    (
      'YouTube (preview only)',
      'https://www.youtube.com/results?search_query=$enc',
    ),
  ].map((e) => {'store': e.$1, 'url': e.$2}).toList();
}

/// Rust's sort_by is stable; Dart's List.sort is not guaranteed to be.
void _stableSort<T>(List<T> l, int Function(T, T) cmp) {
  final idx = List.generate(l.length, (i) => i);
  final copy = List.of(l);
  idx.sort((a, b) {
    final c = cmp(copy[a], copy[b]);
    return c != 0 ? c : a.compareTo(b);
  });
  for (var i = 0; i < idx.length; i++) {
    l[i] = copy[idx[i]];
  }
}
