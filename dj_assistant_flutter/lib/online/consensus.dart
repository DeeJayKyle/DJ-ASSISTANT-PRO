import 'dart:async';

import '../core/catalogue.dart';
import '../core/jobs.dart';
import '../core/suggestions.dart';
import '../core/taggers.dart' show Findings, agreeKey;
import '../core/text.dart';
import 'lookups.dart' show serviceEnabled;
import 'online.dart';

/// One-button online analysis: every online analyser the DJ switched on is
/// asked about a track **at the same time**, each one casts a vote per field
/// (genre, year, album, label), and the value most of them agree on wins.
///
/// The rules for a winner:
///  * values are compared loosely ("Deep House" = "deep-house", "2019-05-03"
///    = "2019"), and the most common one wins;
///  * a tie at the top decides nothing (the file keeps what it has);
///  * a value only one analyser gave fills an empty field but never replaces
///    an existing one; replacing needs at least two analysers agreeing.
///
/// A winner that differs from what the track says now is applied straight
/// away (recorded under Changes with every analyser's vote, undoable) and,
/// with write-through on, written into the original music file.

/// The fields the online analysers vote on.
const voteFields = ['genre', 'year', 'album', 'record_label'];

/// One analyser's answer for one field.
class Vote {
  const Vote(this.source, this.field, this.value);
  final String source, field, value;
}

/// The outcome for one field of one track.
class Verdict {
  Verdict(this.field, this.value, this.agree, this.total, this.votes);
  final String field, value;

  /// Analysers that gave the winning value, and how many voted at all.
  final List<String> agree;
  final int total;
  final List<Vote> votes;

  String get evidence {
    final others = [
      for (final v in votes)
        if (!agree.contains(v.source)) '${v.source} said "${v.value}"',
    ];
    return '${agree.length} of $total online analysers agree on "$value" '
        '(${agree.join(', ')})'
        '${others.isEmpty ? '.' : '; ${others.join('; ')}.'}';
  }
}

String _genreKey(String g) =>
    fold(g)
        .replaceAll(RegExp('[-/&_]'), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .join(' ');

/// The comparison key for a voted value.
String voteKey(String field, String v) => switch (field) {
  'genre' => _genreKey(v),
  _ => agreeKey(field, v),
};

bool _junkGenre(String g) => const {
  '',
  'music',
  'other',
  'unknown',
  'misc',
  'various',
}.contains(_genreKey(g));

/// The majority decision for one field, or null when there is none.
/// [hasValue]: the track already has a value for the field.
Verdict? decide(String field, List<Vote> votes, {required bool hasValue}) {
  if (votes.isEmpty) return null;
  final groups = <String, List<Vote>>{};
  for (final v in votes) {
    groups.putIfAbsent(voteKey(field, v.value), () => []).add(v);
  }
  final ranked = groups.values.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final top = ranked.first;
  if (ranked.length > 1 && ranked[1].length == top.length) return null; // tie
  if (top.length < 2 && hasValue) return null;
  // the spelling most of the winners used
  final spellings = <String, int>{};
  for (final v in top) {
    spellings[v.value] = (spellings[v.value] ?? 0) + 1;
  }
  final value =
      (spellings.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
          .first
          .key;
  return Verdict(
    field,
    field == 'year' ? voteKey('year', value) : value,
    [for (final v in top) v.source],
    votes.length,
    votes,
  );
}

int? _year(String? date) {
  if (date == null || date.length < 4) return null;
  final y = int.tryParse(date.substring(0, 4));
  return (y != null && y >= 1900 && y <= 2100) ? y : null;
}

/// The track as the analysers will be asked about it.
class _Track {
  _Track(this.id, this.artist, this.title, this.durationMs, this.current);
  final int id;
  final String artist, title;
  final int? durationMs;
  final Map<String, String?> current;
}

_Track? _load(Catalogue cat, int id) {
  final r = cat.db.select(
    'SELECT COALESCE(u.title,t.title) AS title, COALESCE(u.artist,t.artist) AS artist, '
    'COALESCE(u.album,t.album) AS album, COALESCE(u.genre,t.genre) AS genre, '
    'COALESCE(u.year,t.year) AS year, COALESCE(u.record_label,t.label) AS label, '
    't.duration_ms AS dur FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
    'WHERE t.id=?',
    [id],
  );
  if (r.isEmpty) return null;
  final x = r.first;
  final a = x['artist'] as String?, t = x['title'] as String?;
  if (a == null || t == null || a.trim().isEmpty || t.trim().isEmpty) {
    return null;
  }
  return _Track(id, a, t, x['dur'] as int?, {
    'genre': x['genre'] as String?,
    'year': (x['year'] as int?)?.toString(),
    'album': x['album'] as String?,
    'record_label': x['label'] as String?,
  });
}

/// The analysers the DJ switched on (and gave a key, where one is needed).
List<String> activeAnalysers(
  Catalogue cat,
  Secrets secrets, {
  bool oneTagger = false,
}) => [
  if (serviceEnabled(cat, 'musicbrainz')) 'MusicBrainz',
  if (serviceEnabled(cat, 'catalogs')) ...['Deezer', 'Apple Music'],
  if (serviceEnabled(cat, 'spotify') && secrets.get('spotify') != null)
    'Spotify',
  if (serviceEnabled(cat, 'youtube') && secrets.get('youtube') != null)
    'YouTube Music',
  if (serviceEnabled(cat, 'discogs') && secrets.get('discogs') != null)
    'Discogs',
  if (oneTagger) 'OneTagger',
];

/// The catalogue matches that are this recording: same title and artist,
/// length within 10 s; the closest per source.
List<CatalogMatch> _sameRecording(_Track t, List<CatalogMatch> found) {
  final wantT = baseTitle(t.title), wantA = baseArtist(t.artist);
  final best = <String, (CatalogMatch, int)>{};
  for (final m in found) {
    if (baseTitle(m.title) != wantT || baseArtist(m.artist) != wantA) continue;
    final d = (t.durationMs != null && m.durationMs != null)
        ? (t.durationMs! - m.durationMs!).abs()
        : 5000;
    if (d > 10000) continue; // another version
    final have = best[m.source];
    if (have == null || d < have.$2) best[m.source] = (m, d);
  }
  return [for (final b in best.values) b.$1];
}

List<Vote> _catalogVotes(_Track t, List<CatalogMatch> found) => [
  for (final m in _sameRecording(t, found)) ...[
    if (m.genres.isNotEmpty && !_junkGenre(m.genres.first))
      Vote(m.source, 'genre', m.genres.first.trim()),
    if (_year(m.releaseDate) case final y?) Vote(m.source, 'year', '$y'),
    if ((m.album ?? '').trim().isNotEmpty)
      Vote(m.source, 'album', m.album!.trim()),
    if ((m.label ?? '').trim().isNotEmpty)
      Vote(m.source, 'record_label', m.label!.trim()),
  ],
];

List<Vote> _musicbrainzVotes(_Track t, List<MbRecording> recs) {
  final wantT = baseTitle(t.title), wantA = baseArtist(t.artist);
  for (final m in recs) {
    if (m.score < 80) continue;
    if (baseTitle(m.title) != wantT || baseArtist(m.artist) != wantA) continue;
    if (t.durationMs != null &&
        m.lengthMs != null &&
        (t.durationMs! - m.lengthMs!).abs() > 15000) {
      continue;
    }
    return [
      if (m.tags.isNotEmpty && !_junkGenre(m.tags.first))
        Vote('MusicBrainz', 'genre', m.tags.first.trim()),
      if (_year(m.firstReleaseDate) case final y?)
        Vote('MusicBrainz', 'year', '$y'),
      if ((m.releaseTitle ?? '').trim().isNotEmpty)
        Vote('MusicBrainz', 'album', m.releaseTitle!.trim()),
      if ((m.label ?? '').trim().isNotEmpty)
        Vote('MusicBrainz', 'record_label', m.label!.trim()),
    ];
  }
  return const [];
}

/// Asks every switched-on analyser about one track at once. Returns the votes
/// and the analysers that failed (with why).
Future<(List<Vote>, List<String>)> _collectVotes(
  Catalogue cat,
  Online online,
  Secrets secrets,
  _Track t, {
  Map<String, String>? oneTagger,
  bool youtube = true,
}) async {
  final votes = <Vote>[];
  final errors = <String>[];
  Future<void> ask(String name, Future<List<Vote>> Function() f) async {
    try {
      votes.addAll(await f());
    } on OnlineException catch (e) {
      errors.add('$name: ${e.message}');
    } on Object catch (e) {
      errors.add('$name: $e');
    }
  }

  final spotify = serviceEnabled(cat, 'spotify')
      ? secrets.get('spotify')
      : null;
  final discogs = serviceEnabled(cat, 'discogs')
      ? secrets.get('discogs')
      : null;
  final yt = youtube && serviceEnabled(cat, 'youtube')
      ? secrets.get('youtube')
      : null;
  await Future.wait([
    if (serviceEnabled(cat, 'musicbrainz'))
      ask(
        'MusicBrainz',
        () async => _musicbrainzVotes(
          t,
          await online.musicbrainzRecordings(t.artist, t.title),
        ),
      ),
    if (serviceEnabled(cat, 'catalogs'))
      ask(
        'Deezer & Apple Music',
        () async =>
            _catalogVotes(t, await online.catalogLookup(t.artist, t.title)),
      ),
    if (spotify != null)
      ask(
        'Spotify',
        () async => _catalogVotes(
          t,
          await online.spotifyLookup(spotify, t.artist, t.title),
        ),
      ),
    if (discogs != null)
      ask(
        'Discogs',
        () async => _catalogVotes(
          t,
          await online.discogsLookup(discogs, t.artist, t.title),
        ),
      ),
    if (yt != null)
      ask(
        'YouTube Music',
        () async =>
            _catalogVotes(t, await online.youtubeLookup(yt, t.artist, t.title)),
      ),
  ]);
  if (oneTagger != null) {
    for (final f in voteFields) {
      final v = oneTagger[f];
      if (v == null || v.trim().isEmpty) continue;
      if (f == 'genre' && _junkGenre(v)) continue;
      votes.add(Vote('OneTagger', f, f == 'year' ? voteKey('year', v) : v));
    }
  }
  return (votes, errors);
}

/// Applies a verdict: recorded under Changes (source: the agreeing
/// analysers) and accepted at once. Returns true when the value changed.
bool applyVerdict(Catalogue cat, int trackId, Verdict v, String? current) {
  if (current != null &&
      voteKey(v.field, current) == voteKey(v.field, v.value)) {
    return false;
  }
  final source = v.agree.join(' + ');
  insertSuggestion(
    cat,
    trackId,
    v.field,
    current,
    v.value,
    source,
    v.evidence,
    v.agree.length / v.total,
  );
  final r = cat.db.select(
    "SELECT id FROM suggestions WHERE track_id=? AND field=? AND suggested_value=? AND source=? AND status='pending'",
    [trackId, v.field, v.value, source],
  );
  if (r.isEmpty) return false;
  SuggestionsService(cat).accept(r.first['id'] as int, by: 'auto');
  return true;
}

/// Summary of a run.
class ConsensusResult {
  int tracks = 0, changed = 0, fields = 0, noMatch = 0;
  final errors = <String>{};
}

/// Runs the analysers on [ids] and applies the majority. [oneTagger] holds
/// what OneTagger found for each track (already run on temporary copies).
/// MusicBrainz allows one request a second, so tracks are spaced that far
/// apart when it is on.
Future<ConsensusResult> analyseOnline(
  Catalogue cat,
  Online online,
  Secrets secrets,
  List<int> ids,
  JobProgress p, {
  Findings oneTagger = const {},
  int spacingMs = 1100,
}) async {
  final res = ConsensusResult();
  p.total = ids.length;
  var youtube = true;
  for (final id in ids) {
    if (await p.checkpoint()) break;
    final t = _load(cat, id);
    if (t == null) {
      p.tick(ok: false);
      continue;
    }
    final started = DateTime.now();
    p.message = 'Asking every analyser about ${t.artist} - ${t.title}…';
    final (votes, errors) = await _collectVotes(
      cat,
      online,
      secrets,
      t,
      oneTagger: oneTagger[id],
      youtube: youtube,
    );
    for (final e in errors) {
      if (e.startsWith('YouTube') && e.contains('quota')) youtube = false;
      res.errors.add(e);
    }
    res.tracks++;
    if (votes.isEmpty) {
      res.noMatch++;
      p.tick(ok: errors.isEmpty);
    } else {
      var changed = false;
      for (final f in voteFields) {
        final cur = t.current[f];
        final v = decide(f, [
          for (final x in votes)
            if (x.field == f) x,
        ], hasValue: cur != null && cur.trim().isNotEmpty);
        if (v != null && applyVerdict(cat, id, v, cur)) {
          res.fields++;
          changed = true;
        }
      }
      if (changed) res.changed++;
      p.tick();
    }
    cat.db.execute(
      'INSERT INTO catalog_checked(track_id, checked_at) VALUES (?, ?) '
      'ON CONFLICT(track_id) DO UPDATE SET checked_at=excluded.checked_at',
      [id, nowMs()],
    );
    if (serviceEnabled(cat, 'musicbrainz')) {
      final el = DateTime.now().difference(started).inMilliseconds;
      if (el < spacingMs) {
        await Future<void>.delayed(Duration(milliseconds: spacingMs - el));
      }
    }
  }
  return res;
}
