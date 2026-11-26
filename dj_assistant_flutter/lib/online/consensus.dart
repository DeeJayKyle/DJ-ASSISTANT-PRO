import 'dart:async';
import 'dart:convert';

import '../core/catalogue.dart';
import '../core/jobs.dart';
import '../core/suggestions.dart';
import '../core/taggers.dart' show Findings, agreeKey;
import '../core/text.dart';
import 'lookups.dart' show serviceEnabled;
import 'online.dart';

/// One-button online analysis: the online analysers the DJ switched on are
/// asked about each track, each one casts a vote per field (genre, year,
/// album, label), and the value most of them agree on wins.
///
/// To be fast on big libraries: many tracks are looked up at once (each
/// analyser keeps its own speed limit), the fast analysers are asked first
/// and the slow ones only while a field is still undecided (see [settled]),
/// and tracks of the same album share one set of answers ([AlbumVotes]).
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

/// The fields each analyser can give (Apple Music and Spotify have no label,
/// YouTube Music no genre). A source that cannot give a field cannot change
/// it, so it is never asked just for that field.
const sourceFields = <String, Set<String>>{
  'MusicBrainz': {'genre', 'year', 'album', 'record_label'},
  'Deezer': {'genre', 'year', 'album', 'record_label'},
  'Apple Music': {'genre', 'year', 'album'},
  'Spotify': {'genre', 'year', 'album'},
  'Discogs': {'genre', 'year', 'album', 'record_label'},
  'YouTube Music': {'year', 'album', 'record_label'},
  'OneTagger': {'genre', 'year', 'album', 'record_label'},
};

/// What a field's votes would do to the track: the key of the value that
/// would be written, or null when the track keeps what it has.
String? _outcome(Map<String, int> groups, bool hasValue, String? curKey) {
  if (groups.isEmpty) return null;
  final ranked = groups.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  final top = ranked.first;
  if (ranked.length > 1 && ranked[1].value == top.value) return null; // tie
  if (top.value < 2 && hasValue) return null;
  return top.key == curKey ? null : top.key;
}

/// Whether the votes so far settle [field] so the slower analysers can be
/// skipped for it. Settled when
///  * no combination of votes from the [remaining] analysers that could
///    still answer would change what is applied (so asking them cannot
///    matter), or
///  * at least two analysers agree and none disagrees.
bool settled(
  String field,
  List<Vote> votes, {
  required String? current,
  required int remaining,
}) {
  if (remaining <= 0) return true;
  final hasValue = current != null && current.trim().isNotEmpty;
  final curKey = hasValue ? voteKey(field, current) : null;
  final groups = <String, int>{};
  for (final v in votes) {
    if (v.field != field) continue;
    final k = voteKey(field, v.value);
    groups[k] = (groups[k] ?? 0) + 1;
  }
  if (groups.length == 1 && groups.values.single >= 2) return true;
  final now = _outcome(groups, hasValue, curKey);
  // Each analyser gives at most one value per field. Piling every remaining
  // vote onto one value is the strongest move it has: any split of those
  // votes that changes the result, a single pile also changes.
  const fresh = '\u0000new';
  for (final x in {...groups.keys, ?curKey, fresh}) {
    for (var j = 1; j <= remaining; j++) {
      final g = Map.of(groups)..[x] = (groups[x] ?? 0) + j;
      if (_outcome(g, hasValue, curKey) != now) return false;
    }
  }
  return true;
}

/// Votes shared by tracks of the same release (artist + album), so one
/// lookup serves the whole album. Kept in the catalogue for 90 days so the
/// next album track added later is served too.
class AlbumVotes {
  AlbumVotes(this.cat, {this.useSaved = true}) {
    cat.db.execute(
      'CREATE TABLE IF NOT EXISTS online_album_votes (album_key TEXT PRIMARY KEY, '
      'votes_json TEXT NOT NULL, saved_at INTEGER NOT NULL)',
    );
  }
  final Catalogue cat;

  /// False for "check every track again": saved albums are not reused.
  final bool useSaved;
  static const maxAgeMs = 90 * 24 * 3600 * 1000;
  final _mem = <String, List<Vote>>{};
  final _busy = <String, Future<void>>{};
  int hits = 0;

  /// The key for a track's release; null when it has no album tag.
  static String? keyOf(String artist, String? album) {
    if (album == null || album.trim().isEmpty) return null;
    final a = baseArtist(artist), b = voteKey('album', album);
    if (a.isEmpty || b.isEmpty) return null;
    return '$a\u0001$b';
  }

  List<Vote>? get(String key) {
    if (_mem[key] case final v?) return v;
    if (!useSaved) return null;
    final r = cat.db.select(
      'SELECT votes_json FROM online_album_votes WHERE album_key=? AND saved_at>?',
      [key, nowMs() - maxAgeMs],
    );
    if (r.isEmpty) return null;
    try {
      final v = [
        for (final x in jsonDecode(r.first['votes_json'] as String) as List)
          Vote(x[0] as String, x[1] as String, x[2] as String),
      ];
      return _mem[key] = v;
    } on Object {
      return null;
    }
  }

  /// Keeps the votes of the analysers that found this very album.
  void put(String key, String album, List<Vote> votes) {
    final want = voteKey('album', album);
    final found = {
      for (final v in votes)
        if (v.field == 'album' &&
            v.source != 'OneTagger' &&
            voteKey('album', v.value) == want)
          v.source,
    };
    final keep = [
      for (final v in votes)
        if (found.contains(v.source)) v,
    ];
    if (keep.isEmpty) return;
    _mem[key] = keep;
    cat.db.execute(
      'INSERT OR REPLACE INTO online_album_votes(album_key, votes_json, saved_at) VALUES (?,?,?)',
      [
        key,
        jsonEncode([
          for (final v in keep) [v.source, v.field, v.value],
        ]),
        nowMs(),
      ],
    );
  }

  /// Runs [f] for [key] one track at a time, so the second track of an
  /// album waits for the first one's answers instead of asking again.
  Future<T> serial<T>(String? key, Future<T> Function() f) async {
    if (key == null) return f();
    for (var b = _busy[key]; b != null; b = _busy[key]) {
      await b;
    }
    final done = Completer<void>();
    _busy[key] = done.future;
    try {
      return await f();
    } finally {
      _busy.remove(key);
      done.complete();
    }
  }
}

/// Shared state of one run (YouTube's daily quota, the album cache).
class _Run {
  _Run(this.cat, this.online, this.secrets, this.albums);
  final Catalogue cat;
  final Online online;
  final Secrets secrets;
  final AlbumVotes albums;
  bool youtube = true;
  int skippedAsks = 0;
}

/// One analyser: its name(s) as votes carry them and how to ask it.
class _Source {
  _Source(this.names, this.ask);
  final List<String> names;
  final Future<List<Vote>> Function(_Track t) ask;
  Set<String> get fields => {for (final n in names) ...?sourceFields[n]};
}

/// The analysers in the order they are asked: the fast ones together first
/// (Deezer, Spotify), then the rate-limited ones one by one, slowest last
/// (MusicBrainz and Discogs one a second, YouTube's daily quota, Apple Music
/// about 20 a minute). A slower one is only asked when the answers so far
/// leave a field it could change undecided.
List<List<_Source>> _tiers(_Run r) {
  final cat = r.cat, online = r.online, secrets = r.secrets;
  final spotify = serviceEnabled(cat, 'spotify')
      ? secrets.get('spotify')
      : null;
  final discogs = serviceEnabled(cat, 'discogs')
      ? secrets.get('discogs')
      : null;
  final yt = serviceEnabled(cat, 'youtube') ? secrets.get('youtube') : null;
  final catalogs = serviceEnabled(cat, 'catalogs');
  final split = catalogs && online.separateCatalogs;
  return [
    [
      if (catalogs && split)
        _Source(
          ['Deezer'],
          (t) async =>
              _catalogVotes(t, await online.deezerLookup(t.artist, t.title)),
        )
      else if (catalogs)
        _Source(
          ['Deezer', 'Apple Music'],
          (t) async =>
              _catalogVotes(t, await online.catalogLookup(t.artist, t.title)),
        ),
      if (spotify != null)
        _Source(
          ['Spotify'],
          (t) async => _catalogVotes(
            t,
            await online.spotifyLookup(spotify, t.artist, t.title),
          ),
        ),
    ],
    if (serviceEnabled(cat, 'musicbrainz'))
      [
        _Source(
          ['MusicBrainz'],
          (t) async => _musicbrainzVotes(
            t,
            await online.musicbrainzRecordings(t.artist, t.title),
          ),
        ),
      ],
    if (discogs != null)
      [
        _Source(
          ['Discogs'],
          (t) async => _catalogVotes(
            t,
            await online.discogsLookup(discogs, t.artist, t.title),
          ),
        ),
      ],
    if (yt != null)
      [
        _Source(['YouTube Music'], (t) async {
          if (!r.youtube) return const <Vote>[];
          return _catalogVotes(
            t,
            await online.youtubeLookup(yt, t.artist, t.title),
          );
        }),
      ],
    if (split)
      [
        _Source(
          ['Apple Music'],
          (t) async =>
              _catalogVotes(t, await online.appleLookup(t.artist, t.title)),
        ),
      ],
  ];
}

/// Asks the analysers about one track, fastest first, and stops as soon as
/// the answers so far settle every field (see [settled]). Votes already
/// known for the track's album count as those analysers' answers. Returns
/// the votes and the analysers that failed (with why).
Future<(List<Vote>, List<String>)> _collectVotes(
  _Run run,
  List<List<_Source>> tiers,
  _Track t, {
  Map<String, String>? oneTagger,
}) async {
  final votes = <Vote>[];
  final errors = <String>[];
  if (oneTagger != null) {
    for (final f in voteFields) {
      final v = oneTagger[f];
      if (v == null || v.trim().isEmpty) continue;
      if (f == 'genre' && _junkGenre(v)) continue;
      votes.add(Vote('OneTagger', f, f == 'year' ? voteKey('year', v) : v));
    }
  }
  final albumKey = AlbumVotes.keyOf(t.artist, t.current['album']);
  final known = albumKey == null ? null : run.albums.get(albumKey);
  final answered = <String>{};
  if (known != null) {
    run.albums.hits++;
    votes.addAll(known);
    answered.addAll(known.map((v) => v.source));
  }

  Future<void> ask(_Source s) async {
    try {
      votes.addAll(await s.ask(t));
    } on OnlineException catch (e) {
      final name = s.names.join(' & ');
      if (name.startsWith('YouTube') && e.message.contains('quota')) {
        run.youtube = false;
      }
      errors.add('$name: ${e.message}');
    } on Object catch (e) {
      errors.add('${s.names.join(' & ')}: $e');
    }
  }

  for (var i = 0; i < tiers.length; i++) {
    final todo = [
      for (final s in tiers[i])
        if (!s.names.every(answered.contains)) s,
    ];
    if (todo.isEmpty) continue;
    // fields still open, counting every analyser from this tier on
    final open = <String>{};
    for (final f in voteFields) {
      var remaining = 0;
      for (final tier in tiers.skip(i)) {
        for (final s in tier) {
          if (!s.fields.contains(f)) continue;
          remaining += s.names.where((n) => !answered.contains(n)).length;
        }
      }
      if (!settled(f, votes, current: t.current[f], remaining: remaining)) {
        open.add(f);
      }
    }
    final asking = [
      for (final s in todo)
        if (s.fields.any(open.contains)) s,
    ];
    run.skippedAsks += todo.length - asking.length;
    if (open.isEmpty) {
      for (final tier in tiers.skip(i + 1)) {
        run.skippedAsks += tier.length;
      }
      break;
    }
    await Future.wait([for (final s in asking) ask(s)]);
    for (final s in todo) {
      answered.addAll(s.names);
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

  /// Tracks answered from their album's saved votes, and analyser
  /// questions skipped because the answers so far already decided.
  int albumHits = 0, skippedAsks = 0;
  final errors = <String>{};
}

/// How many tracks are looked up at the same time. Each analyser keeps its
/// own speed limit (see HttpOnline.throttle), so more tracks at once only
/// keeps every analyser busy; it never asks any one of them faster.
const onlineConcurrency = 12;

/// Runs the analysers on [ids] and applies the majority. [oneTagger] holds
/// what OneTagger found for each track (already run on temporary copies).
/// [concurrency] tracks are looked up at once; every finished track is
/// remembered (catalog_checked), so a cancelled run picks up where it
/// stopped. [reuseAlbums] false ignores albums saved by earlier runs.
Future<ConsensusResult> analyseOnline(
  Catalogue cat,
  Online online,
  Secrets secrets,
  List<int> ids,
  JobProgress p, {
  Findings oneTagger = const {},
  int concurrency = onlineConcurrency,
  bool reuseAlbums = true,
}) async {
  final res = ConsensusResult();
  p.total = ids.length;
  final run = _Run(
    cat,
    online,
    secrets,
    AlbumVotes(cat, useSaved: reuseAlbums),
  );
  final tiers = _tiers(run);
  var next = 0, done = 0;
  var stop = false;

  Future<void> one(int id) async {
    final t = _load(cat, id);
    if (t == null) {
      p.tick(ok: false);
      return;
    }
    final albumKey = AlbumVotes.keyOf(t.artist, t.current['album']);
    await run.albums.serial(albumKey, () async {
      final (votes, errors) = await _collectVotes(
        run,
        tiers,
        t,
        oneTagger: oneTagger[id],
      );
      res.errors.addAll(errors);
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
        if (albumKey != null) {
          run.albums.put(albumKey, t.current['album']!, votes);
        }
        p.tick();
      }
      cat.db.execute(
        'INSERT INTO catalog_checked(track_id, checked_at) VALUES (?, ?) '
        'ON CONFLICT(track_id) DO UPDATE SET checked_at=excluded.checked_at',
        [id, nowMs()],
      );
    });
    done++;
    p.message =
        'Online analysers: $done of ${ids.length} '
        '(${t.artist} - ${t.title})';
  }

  Future<void> worker() async {
    while (!stop && next < ids.length) {
      if (await p.checkpoint()) {
        stop = true;
        return;
      }
      if (next >= ids.length) return;
      await one(ids[next++]);
    }
  }

  p.message = 'Asking the online analysers about ${ids.length} track(s)…';
  await Future.wait([
    for (var i = 0; i < concurrency.clamp(1, 64); i++) worker(),
  ]);
  res.albumHits = run.albums.hits;
  res.skippedAsks = run.skippedAsks;
  return res;
}
