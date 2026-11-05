import 'catalogue.dart';
import 'text.dart';

/// A compact view of each playable track for discovery, the set planner and
/// history matching (1.x `profile.rs`): effective values, catalogue > tag > analysis.
class Tp {
  Tp(Map<String, Object?> r)
    : id = r['id'] as int,
      artist = r['artist'] as String,
      title = r['title'] as String,
      genre = r['genre'] as String?,
      year = r['year'] as int?,
      bpm = (r['bpm'] as num?)?.toDouble(),
      key = r['key'] as String?,
      energy = r['energy'] as int?,
      rating = r['rating'] as int?,
      durationMs = r['duration_ms'] as int?,
      clean = r['clean'] as String?,
      version = r['version'] as String?,
      tags = (r['tags'] as String?)?.split('\u001f') ?? const [],
      plays = r['plays'] as int,
      workKey = r['work_key'] as String?;
  final int id, plays;
  final String artist, title;
  final String? genre, key, clean, version, workKey;
  final int? year, energy, rating, durationMs;
  final double? bpm;
  final List<String> tags;

  String get genreFold => genre == null ? '' : fold(genre!);
  String get label => '$artist — $title';
}

List<Tp> loadProfiles(Catalogue cat) => cat.db
    .select(
      "SELECT t.id, COALESCE(u.artist, t.artist, '') AS artist, COALESCE(u.title, t.title, t.file_name) AS title, "
      'COALESCE(u.genre, t.genre) AS genre, COALESCE(u.year, t.year) AS year, COALESCE(u.bpm, t.bpm_tag, a.bpm) AS bpm, '
      'keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot)) AS key, COALESCE(u.energy, a.energy) AS energy, u.rating, '
      't.duration_ms, COALESCE(u.clean_explicit, t.clean_hint) AS clean, COALESCE(u.version_label, t.version_hint) AS version, '
      '(SELECT GROUP_CONCAT(g.name_fold, char(31)) FROM track_tags tt JOIN tags g ON g.id=tt.tag_id WHERE tt.track_id=t.id) AS tags, '
      '(SELECT COUNT(*) FROM play_history ph WHERE ph.track_id=t.id) + '
      "(SELECT COUNT(*) FROM gig_events ge WHERE ge.track_id=t.id AND ge.kind='played') AS plays, t.work_key "
      'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id '
      "LEFT JOIN library_roots r ON r.id=t.root_id WHERE t.presence='present' AND t.read_status='ok'",
    )
    .map(Tp.new)
    .toList();

/// Tempo distance allowing half/double time (relative difference).
double bpmDistance(double a, double b) => [
  1.0,
  2.0,
  0.5,
].map((m) => ((a * m - b) / b).abs()).reduce((x, y) => x < y ? x : y);

/// The version label of a title ("Remix", "Live"…), or "".
String versionOf(String title) => detectVersionLabels(title) ?? '';
