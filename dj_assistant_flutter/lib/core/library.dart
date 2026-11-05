import 'catalogue.dart';
import 'text.dart';

const defaultLowBitrateKbps = 128;

/// One track as the Library shows it. Each value is the DJ's own edit if there is one,
/// otherwise the file's tag, otherwise the audio analysis (same precedence as 1.x).
class TrackRow {
  TrackRow(Map<String, Object?> r)
    : id = r['id'] as int,
      uid = r['uid'] as String,
      title = r['title'] as String?,
      artist = r['artist'] as String?,
      album = r['album'] as String?,
      genre = r['genre'] as String?,
      year = r['year'] as int?,
      bpm = (r['bpm'] as num?)?.toDouble(),
      key = r['key'] as String?,
      energy = r['energy'] as int?,
      rating = r['rating'] as int?,
      mood = r['mood'] as String?,
      color = r['color'] as String?,
      version = r['version'] as String?,
      cleanExplicit = r['clean_explicit'] as String?,
      durationMs = r['duration_ms'] as int?,
      bitrateKbps = r['bitrate_kbps'] as int?,
      format = r['format'] as String?,
      lossless = r['lossless'] == null ? null : r['lossless'] == 1,
      quality = r['quality'] as String,
      status = r['status'] as String,
      fileName = r['file_name'] as String,
      path = r['path'] as String,
      fileSize = r['file_size'] as int,
      tags = (r['tags'] as String?)?.split('\u001f') ?? const [],
      bpmSource = r['bpm_source'] as String?,
      keySource = r['key_source'] as String?,
      energySource = r['energy_source'] as String?,
      analysis = r['analysis'] as String?,
      originalYear = r['original_year'] as int?,
      mediaKind = r['media_kind'] as String;

  final int id;
  final String uid;
  final String? title,
      artist,
      album,
      genre,
      key,
      mood,
      color,
      version,
      cleanExplicit,
      format,
      bpmSource,
      keySource,
      energySource,
      analysis;
  final int? year, energy, rating, durationMs, bitrateKbps, originalYear;
  final double? bpm;
  final bool? lossless;
  final String quality, status, fileName, path, mediaKind;
  final int fileSize;
  final List<String> tags;
}

class TrackQuery {
  const TrackQuery({
    this.text,
    this.rootId,
    this.includeMissing = false,
    this.sort,
    this.desc = false,
    this.offset = 0,
    this.limit = 200,
    this.extraWhere,
  });
  final String? text;
  final int? rootId;
  final bool includeMissing;
  final String? sort;
  final bool desc;
  final int offset;
  final int limit;

  /// A compiled smart-crate rule or crate membership: (sql, params). Set by CratesService.
  final (String, List<Object?>)? extraWhere;
}

class TrackPage {
  TrackPage(this.total, this.offset, this.rows);
  final int total, offset;
  final List<TrackRow> rows;
}

const from =
    'FROM tracks t LEFT JOIN track_user u ON u.track_id = t.id LEFT JOIN library_roots r ON r.id = t.root_id LEFT JOIN analysis a ON a.track_id = t.id';

String _rowCols(int low) =>
    '''t.id AS id, t.uid AS uid, COALESCE(u.title, t.title) AS title, COALESCE(u.artist, t.artist) AS artist, COALESCE(u.album, t.album) AS album,
  COALESCE(u.genre, t.genre) AS genre, COALESCE(u.year, t.year) AS year, COALESCE(u.bpm, t.bpm_tag, a.bpm) AS bpm,
  keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot)) AS key, COALESCE(u.energy, a.energy) AS energy, u.rating AS rating, u.mood AS mood, u.color AS color,
  COALESCE(u.version_label, t.version_hint) AS version, COALESCE(u.clean_explicit, t.clean_hint) AS clean_explicit, t.duration_ms AS duration_ms,
  t.bitrate_kbps AS bitrate_kbps, t.format AS format, t.lossless AS lossless,
  (CASE WHEN t.media_kind='video' THEN 'video' WHEN t.lossless=1 THEN 'lossless' WHEN t.lossless=0 AND t.bitrate_kbps IS NOT NULL AND t.bitrate_kbps < $low THEN 'low_bitrate' WHEN t.lossless=0 AND t.bitrate_kbps IS NOT NULL THEN 'lossy' ELSE 'unknown' END) AS quality,
  (CASE WHEN t.presence='missing' AND t.removed_at IS NOT NULL THEN 'removed' WHEN t.presence='missing' THEN 'missing' WHEN r.status='offline' THEN 'offline' WHEN t.read_status<>'ok' THEN t.read_status ELSE 'ok' END) AS status,
  t.file_name AS file_name, t.path AS path, t.file_size AS file_size,
  (SELECT GROUP_CONCAT(g.name, char(31)) FROM track_tags tt JOIN tags g ON g.id=tt.tag_id WHERE tt.track_id=t.id) AS tags,
  CASE WHEN u.bpm IS NOT NULL THEN 'you' WHEN t.bpm_tag IS NOT NULL THEN 'tag' WHEN a.bpm IS NOT NULL THEN 'analysis' END AS bpm_source,
  CASE WHEN u.musical_key IS NOT NULL THEN 'you' WHEN t.key_tag IS NOT NULL THEN 'tag' WHEN a.camelot IS NOT NULL THEN 'analysis' END AS key_source,
  CASE WHEN u.energy IS NOT NULL THEN 'you' WHEN a.energy IS NOT NULL THEN 'analysis' END AS energy_source,
  a.status AS analysis, COALESCE(u.original_year, t.original_year) AS original_year, t.media_kind AS media_kind''';

const _sorts = {
  'title': 'fold(COALESCE(u.title, t.title))',
  'artist': 'fold(COALESCE(u.artist, t.artist))',
  'album': 'fold(COALESCE(u.album, t.album))',
  'genre': 'fold(COALESCE(u.genre, t.genre))',
  'year': 'COALESCE(u.year, t.year)',
  'bpm': 'COALESCE(u.bpm, t.bpm_tag, a.bpm)',
  'key': 'keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot))',
  'energy': 'COALESCE(u.energy, a.energy)',
  'loudness': 'a.loudness_lufs',
  'rating': 'u.rating',
  'duration': 't.duration_ms',
  'bitrate': 't.bitrate_kbps',
  'format': 't.format',
  'added': 't.first_seen_at',
  'path': 'fold(t.path)',
  'size': 't.file_size',
};

class LibraryService {
  LibraryService(this.cat);
  final Catalogue cat;

  int get lowBitrateKbps {
    final v = int.tryParse(cat.getSetting('low_bitrate_kbps') ?? '');
    return (v != null && v >= 8 && v <= 2000) ? v : defaultLowBitrateKbps;
  }

  /// WHERE clause for a query: (sql, params). Text search is accent-insensitive and
  /// matches every word in the file's tags, the DJ's own fields and tag names.
  (String, List<Object?>) where(TrackQuery q) {
    final parts = <String>[];
    final params = <Object?>[];
    if (!q.includeMissing) parts.add("t.presence = 'present'");
    if (q.rootId != null) {
      params.add(q.rootId);
      parts.add('t.root_id = ?');
    }
    final text = q.text;
    if (text != null) {
      final tokens = text
          .split(RegExp(r'\s+'))
          .take(12)
          .map(fold)
          .where((s) => s.isNotEmpty);
      for (final tok in tokens) {
        final like = '%${likeEscape(tok)}%';
        params.addAll([like, like, like]);
        parts.add(
          r"(t.search_text LIKE ? ESCAPE '\' OR fold(COALESCE(u.genre,'') || ' ' || COALESCE(u.mood,'') || ' ' || COALESCE(u.notes,'') || ' ' || COALESCE(u.version_label,'') || ' ' || COALESCE(u.title,'') || ' ' || COALESCE(u.artist,'') || ' ' || COALESCE(u.album,'')) LIKE ? ESCAPE '\' "
          r"OR EXISTS (SELECT 1 FROM track_tags tt JOIN tags g ON g.id=tt.tag_id WHERE tt.track_id=t.id AND g.name_fold LIKE ? ESCAPE '\'))",
        );
      }
    }
    final extra = q.extraWhere;
    if (extra != null) {
      parts.add(extra.$1);
      params.addAll(extra.$2);
    }
    return (parts.isEmpty ? '1=1' : parts.join(' AND '), params);
  }

  TrackPage search(TrackQuery q) {
    final (w, params) = where(q);
    final total =
        cat.db.select('SELECT COUNT(*) AS n $from WHERE $w', params).first['n']
            as int;
    final limit = q.limit.clamp(1, 2000);
    final offset = q.offset < 0 ? 0 : q.offset;
    final String order;
    if (q.sort == null) {
      order = 'fold(COALESCE(u.artist, t.artist)) IS NULL, fold(COALESCE(u.artist, t.artist)), fold(COALESCE(u.title, t.title)), t.id';
    } else {
      final e = _sorts[q.sort];
      if (e == null) throw ArgumentError('unknown sort column');
      order = '$e IS NULL, $e ${q.desc ? 'DESC' : 'ASC'}, t.id';
    }
    final rows = cat.db.select(
      'SELECT ${_rowCols(lowBitrateKbps)} $from WHERE $w ORDER BY $order LIMIT $limit OFFSET $offset',
      params,
    );
    return TrackPage(total, offset, rows.map(TrackRow.new).toList());
  }
}
