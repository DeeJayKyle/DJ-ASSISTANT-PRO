import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'snapshot.dart';
import 'text.dart';

/// Matches tracks listed by other DJ software (a history export, a crate, a
/// playlist) to tracks in the library.
///
/// **Sure** matches, in order: the same file path; the same file name; the
/// same artist and title (letters and digits only, accents and case
/// ignored). When several library tracks share the key, the one whose length
/// is closest wins.
///
/// **Likely** matches, only when nothing sure was found: the same title
/// where the artists agree (one list of artist words contains the other:
/// best; they share a word: next, better still when the lengths agree within
/// five seconds), or the same title and length, or the same title when the
/// other side names no artist at all.
///
/// With [MatchOptions.claimOnce] each library track can answer only one
/// entry (for crates and playlists); a play history leaves it off because a
/// track can be played more than once.
class MatchTrack {
  const MatchTrack({
    required this.id,
    this.path,
    this.artist,
    this.title,
    this.durationSec,
  });
  final int id;
  final String? path;
  final String? artist;
  final String? title;
  final double? durationSec;
}

class MatchEntry {
  const MatchEntry({this.path, this.artist, this.title, this.durationSec});
  final String? path;
  final String? artist;
  final String? title;
  final double? durationSec;
}

enum MatchKind { path, fileName, artistTitle, likely }

class TrackMatch {
  const TrackMatch(this.trackId, this.kind, [this.reason = '']);
  final int trackId;
  final MatchKind kind;
  final String reason;
  bool get sure => kind != MatchKind.likely;
}

class MatchOptions {
  const MatchOptions({this.claimOnce = false, this.lengthToleranceSec = 5});
  final bool claimOnce;
  final double lengthToleranceSec;
}

/// Letters and digits only, lower case, accents removed.
String matchKey(String? s) =>
    s == null ? '' : fold(s).replaceAll(RegExp(r'[^a-z0-9]+'), '');

List<String> artistWords(String? s) => s == null
    ? const []
    : fold(s)
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim()
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .toList();

enum ArtistOverlap { none, overlap, subset, same }

ArtistOverlap compareArtists(String? a, String? b) {
  final x = artistWords(a).toSet(), y = artistWords(b).toSet();
  if (x.isEmpty || y.isEmpty) return ArtistOverlap.none;
  if (x.length == y.length && x.containsAll(y)) return ArtistOverlap.same;
  if (x.containsAll(y) || y.containsAll(x)) return ArtistOverlap.subset;
  if (x.any(y.contains)) return ArtistOverlap.overlap;
  return ArtistOverlap.none;
}

/// "4:05", "1:02:03" or "245" → seconds.
double? parseLength(String? s) {
  if (s == null || s.trim().isEmpty) return null;
  var total = 0.0;
  for (final part in s.trim().split(':')) {
    final n = double.tryParse(part.trim());
    if (n == null) return null;
    total = total * 60 + n;
  }
  return total;
}

String _pathKey(String? s) {
  if (s == null || s.trim().isEmpty) return '';
  return fold(s.replaceAll('\\', '/')).replaceAll(RegExp(r'/+'), '/');
}

String _fileKey(String? s) {
  if (s == null || s.trim().isEmpty) return '';
  return fold(p.posix.basename(s.replaceAll('\\', '/')));
}

class TrackMatcher {
  TrackMatcher(
    List<MatchTrack> library, [
    this.options = const MatchOptions(),
  ]) {
    void add(Map<String, List<MatchTrack>> m, String k, MatchTrack t) {
      if (k.isNotEmpty) (m[k] ??= []).add(t);
    }

    for (final t in library) {
      add(_byPath, _pathKey(t.path), t);
      add(_byFile, _fileKey(t.path), t);
      final at = matchKey(t.title);
      if (at.isNotEmpty) add(_byArtistTitle, '${matchKey(t.artist)}|$at', t);
      add(_byTitle, at, t);
    }
  }

  final MatchOptions options;
  final _byPath = <String, List<MatchTrack>>{};
  final _byFile = <String, List<MatchTrack>>{};
  final _byArtistTitle = <String, List<MatchTrack>>{};
  final _byTitle = <String, List<MatchTrack>>{};
  final _claimed = <int>{};

  bool _lengthsAgree(MatchEntry e, MatchTrack t) {
    final a = e.durationSec, b = t.durationSec;
    return a != null &&
        b != null &&
        a > 0 &&
        b > 0 &&
        (a - b).abs() <= options.lengthToleranceSec;
  }

  MatchTrack _closest(List<MatchTrack> c, MatchEntry e) {
    final d = e.durationSec;
    if (d == null || d <= 0) return c.first;
    var best = c.first;
    var gap = double.infinity;
    for (final t in c) {
      final td = t.durationSec;
      if (td == null) continue;
      final g = (td - d).abs();
      if (g < gap) {
        gap = g;
        best = t;
      }
    }
    return best;
  }

  /// A match for [e], or null.
  TrackMatch? match(MatchEntry e) {
    final title = matchKey(e.title);
    final tiers = [
      (MatchKind.path, _byPath[_pathKey(e.path)]),
      (MatchKind.fileName, _byFile[_fileKey(e.path)]),
      (
        MatchKind.artistTitle,
        title.isEmpty ? null : _byArtistTitle['${matchKey(e.artist)}|$title'],
      ),
    ];
    for (final (kind, list) in tiers) {
      final free = list
          ?.where((t) => !options.claimOnce || !_claimed.contains(t.id))
          .toList();
      if (free == null || free.isEmpty) continue;
      return _claim(TrackMatch(_closest(free, e).id, kind));
    }
    final same = _byTitle[title];
    if (title.isEmpty || same == null) return null;
    (MatchTrack, int, String)? best;
    final noArtist = artistWords(e.artist).isEmpty;
    for (final t in same) {
      if (options.claimOnce && _claimed.contains(t.id)) continue;
      final rel = compareArtists(e.artist, t.artist);
      final agree = _lengthsAgree(e, t);
      final (score, why) = switch (rel) {
        ArtistOverlap.same ||
        ArtistOverlap.subset => (4, 'Same title; the artists match'),
        ArtistOverlap.overlap => (
          agree ? 3 : 2,
          'Same title; the artists partly match',
        ),
        ArtistOverlap.none when agree => (2, 'Same title and length'),
        ArtistOverlap.none when noArtist => (1, 'Same title'),
        _ => (0, ''),
      };
      if (score > 0 && (best == null || score > best.$2)) {
        best = (t, score, why);
      }
    }
    return best == null
        ? null
        : _claim(TrackMatch(best.$1.id, MatchKind.likely, best.$3));
  }

  TrackMatch _claim(TrackMatch m) {
    if (options.claimOnce) _claimed.add(m.trackId);
    return m;
  }
}

/// Every library track (not removed) as a [MatchTrack]; your own artist and
/// title win over the file's tags.
List<MatchTrack> libraryMatchTracks(Catalogue cat) => snapshot(
  cat,
  'match-tracks',
  () => List<MatchTrack>.unmodifiable(_libraryMatchTracks(cat)),
);

/// A matcher over the whole library (default options), cached until the
/// catalogue changes.
TrackMatcher libraryMatcher(Catalogue cat) =>
    snapshot(cat, 'matcher', () => TrackMatcher(libraryMatchTracks(cat)));

List<MatchTrack> _libraryMatchTracks(Catalogue cat) => [
  for (final r in cat.db.select(
    'SELECT t.id, t.path, t.duration_ms, COALESCE(u.artist,t.artist) AS artist, '
    'COALESCE(u.title,t.title) AS title FROM tracks t '
    'LEFT JOIN track_user u ON u.track_id=t.id WHERE t.removed_at IS NULL',
  ))
    MatchTrack(
      id: r['id'] as int,
      path: r['path'] as String?,
      artist: r['artist'] as String?,
      title: r['title'] as String?,
      durationSec: (r['duration_ms'] as int?) == null
          ? null
          : (r['duration_ms'] as int) / 1000,
    ),
];
