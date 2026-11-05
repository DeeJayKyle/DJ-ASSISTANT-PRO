import 'catalogue.dart';
import 'library.dart';
import 'rules.dart';
import 'suggestions.dart';
import 'text.dart';

/// Library health (1.x `health.rs`): each category is a rule set, so the
/// interface can open the matching tracks in the normal library view, and the
/// fixable ones come with local, evidence-based hints. Nothing is written to files.
class HealthItem {
  HealthItem(
    this.id,
    this.label,
    this.explanation,
    this.count,
    this.filters,
    this.includeMissing,
    this.fixFields,
  );
  final String id, label, explanation;
  final int count;
  final Map<String, Object?> filters;
  final bool includeMissing;
  final List<String> fixFields;
}

class Hint {
  Hint(this.field, this.value, this.source, this.evidence);
  final String field, value, source, evidence;
  int? suggestionId;
}

class FixRow {
  FixRow(this.track, this.folder, this.hints);
  final TrackRow track;
  final String folder;
  final List<Hint> hints;
}

class HealthException implements Exception {
  HealthException(this.message);
  final String message;
  @override
  String toString() => message;
}

Map<String, Object?> _cond(String field, String op, [Object? value]) => {
  'kind': 'condition',
  'field': field,
  'op': op,
  'value': value,
};
Map<String, Object?> _all(List<Object?> rules) => {
  'match': 'all',
  'rules': rules,
  'exclude': const [],
};

List<(String, String, String, Map<String, Object?>, bool)> healthCategories(
  int low,
) => [
  (
    'missing_core',
    'Missing title or artist',
    'The file has no title or artist tag. Values shown as unknown are not guessed.',
    _all([
      _cond('status', 'equals', 'ok'),
      {
        'kind': 'group',
        'match': 'any',
        'rules': [_cond('title', 'is_empty'), _cond('artist', 'is_empty')],
      },
    ]),
    false,
  ),
  (
    'missing_genre',
    'Missing genre',
    'No genre in the file tag and none set in your catalogue.',
    _all([_cond('status', 'equals', 'ok'), _cond('genre', 'is_empty')]),
    false,
  ),
  (
    'missing_year',
    'Missing year',
    'No year in the file tag and none set in your catalogue.',
    _all([_cond('status', 'equals', 'ok'), _cond('year', 'is_empty')]),
    false,
  ),
  (
    'missing_album',
    'Missing album',
    'No album in the file tag and none set in your catalogue.',
    _all([_cond('status', 'equals', 'ok'), _cond('album', 'is_empty')]),
    false,
  ),
  (
    'missing_bpm',
    'Missing BPM',
    'No BPM in the file tag, your catalogue or analysis. Run analysis or type it in.',
    _all([_cond('status', 'equals', 'ok'), _cond('bpm', 'is_empty')]),
    false,
  ),
  (
    'missing_key',
    'Missing key',
    'No key in the file tag, your catalogue or analysis. Run analysis or type it in.',
    _all([_cond('status', 'equals', 'ok'), _cond('key', 'is_empty')]),
    false,
  ),
  (
    'low_bitrate',
    'Low bitrate (lossy, under $low kbps)',
    'Lossy files whose reported average bitrate is below $low kbps. Lossless and unknown-bitrate files are not counted. Bitrate alone does not prove audio quality: a file may have been transcoded from a worse source.',
    _all([_cond('quality', 'equals', 'low_bitrate')]),
    false,
  ),
  (
    'unknown_bitrate',
    'Unknown quality',
    'Bitrate or codec could not be determined. Not flagged as low quality.',
    _all([
      _cond('quality', 'equals', 'unknown'),
      _cond('status', 'equals', 'ok'),
    ]),
    false,
  ),
  (
    'read_errors',
    'Unreadable or corrupt',
    'Files that could not be opened or parsed. They were not modified.',
    _all([_cond('status', 'equals', 'error')]),
    false,
  ),
  (
    'unsupported',
    'Unsupported formats',
    'Music or video files in formats this version cannot read (for example WMA or WMV).',
    _all([_cond('status', 'equals', 'unsupported')]),
    false,
  ),
  (
    'offline',
    'On offline drives',
    'Tracks in folders that were not available at the last scan. They are kept, not deleted.',
    _all([_cond('status', 'equals', 'offline')]),
    false,
  ),
  (
    'missing',
    'Missing files',
    'Files that were not found during the last completed scan of an available folder. Catalogue entries are kept so nothing is lost.',
    {
      'match': 'any',
      'rules': [_cond('status', 'equals', 'missing')],
      'exclude': const [],
    },
    true,
  ),
];

List<String> healthFixFields(String category) => switch (category) {
  'missing_core' => ['artist', 'title'],
  'missing_genre' => ['genre'],
  'missing_year' => ['year'],
  'missing_album' => ['album'],
  'missing_bpm' => ['bpm'],
  'missing_key' => ['key'],
  _ => const [],
};

class HealthService {
  HealthService(this.cat);
  final Catalogue cat;
  LibraryService get _lib => LibraryService(cat);

  TrackPage _query(
    Map<String, Object?> rs,
    bool includeMissing, {
    int limit = 1,
    int offset = 0,
    String? sort,
  }) => _lib.search(
    TrackQuery(
      includeMissing: includeMissing,
      limit: limit,
      offset: offset,
      sort: sort,
      extraWhere: compileRules(rs, _lib.lowBitrateKbps),
    ),
  );

  Map<String, Object?> health() {
    final low = _lib.lowBitrateKbps;
    final items = [
      for (final (id, label, expl, rs, incl) in healthCategories(low))
        HealthItem(
          id,
          label,
          expl,
          _query(rs, incl).total,
          rs,
          incl,
          healthFixFields(id),
        ),
    ];
    final last = cat.db.select(
      'SELECT id, started_at, finished_at, status, files_seen, tracks_added AS added, tracks_updated AS updated, '
      'tracks_unchanged AS unchanged, tracks_missing AS missing, error_count AS errors, message FROM scans ORDER BY id DESC LIMIT 1',
    );
    return {
      'items': items,
      'last_scan': last.isEmpty ? null : Map<String, Object?>.of(last.first),
      'recent_errors': [
        for (final r in cat.db.select(
          'SELECT path, kind, message, at FROM scan_errors WHERE scan_id=(SELECT MAX(id) FROM scans) ORDER BY id LIMIT 500',
        ))
          Map<String, Object?>.of(r),
      ],
      'low_bitrate_threshold_kbps': low,
    };
  }

  /// Tracks in a fixable category with hints for each missing field. Saving a
  /// hint only changes DJ Assistant's catalogue.
  (String, List<String>, int, List<FixRow>) fixList(
    String category, {
    int limit = 100,
    int offset = 0,
  }) {
    final low = _lib.lowBitrateKbps;
    final cats = healthCategories(low).where((c) => c.$1 == category);
    if (cats.isEmpty) throw HealthException('unknown health category');
    final (id, label, _, rs, incl) = cats.first;
    final fields = healthFixFields(id);
    if (fields.isEmpty) {
      throw HealthException(
        'this category is reviewed in the library, not fixed here',
      );
    }
    final page = _query(
      rs,
      incl,
      limit: limit.clamp(1, 500),
      offset: offset < 0 ? 0 : offset,
      sort: 'path',
    );

    final genreForms = <String, Map<String, int>>{},
        byAlbumGenre = <String, Map<String, int>>{};
    final byAlbumYear = <String, Map<String, int>>{},
        byAlbumArtist = <String, Map<String, int>>{};
    final byArtistGenre = <String, Map<String, int>>{};
    void bump(Map<String, Map<String, int>> m, String k, String v) {
      final x = m[k] ??= {};
      x[v] = (x[v] ?? 0) + 1;
    }

    for (final r in cat.db.select(
      'SELECT COALESCE(u.genre, t.genre) AS g, COALESCE(u.year, t.year) AS y, COALESCE(u.album, t.album) AS al, '
      "COALESCE(u.artist, t.artist) AS ar FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.presence='present' AND t.read_status='ok'",
    )) {
      final g0 = (r['g'] as String?)?.trim();
      final g = (g0 == null || g0.isEmpty) ? null : g0;
      final y = r['y'] as int?,
          al = r['al'] as String?,
          ar = (r['ar'] as String?)?.trim();
      if (g != null) bump(genreForms, fold(g), g);
      final alf = al == null ? '' : fold(al);
      if (alf.isNotEmpty) {
        if (g != null) bump(byAlbumGenre, alf, g);
        if (y != null) bump(byAlbumYear, alf, '$y');
        if (ar != null && ar.isNotEmpty) bump(byAlbumArtist, alf, ar);
      }
      if (ar != null && ar.isNotEmpty && g != null) {
        bump(byArtistGenre, fold(ar), g);
      }
    }
    // Most frequent value; ties go to the alphabetically first (1.x majority()).
    (String, int)? majority(Map<String, Map<String, int>> m, String k) {
      final x = m[k];
      if (x == null || x.isEmpty) return null;
      final e = x.entries.reduce(
        (a, b) =>
            b.value > a.value ||
                (b.value == a.value && b.key.compareTo(a.key) < 0)
            ? b
            : a,
      );
      return (e.key, e.value);
    }

    final rows = <FixRow>[];
    for (final t in page.rows) {
      final rel =
          (cat.db.select('SELECT rel_path FROM tracks WHERE id=?', [
                    t.id,
                  ]).first['rel_path']
                  as String)
              .replaceAll(r'\', '/');
      final parts = rel.split('/');
      final folders = parts.sublist(0, parts.length - 1);
      final dot = t.fileName.lastIndexOf('.');
      final stem = dot > 0 ? t.fileName.substring(0, dot) : t.fileName;
      final hints = <Hint>[];
      void add(String field, String value, String source, String evidence) {
        final v = value.trim();
        if (v.isEmpty ||
            hints.any((h) => h.field == field && fold(h.value) == fold(v))) {
          return;
        }
        hints.add(Hint(field, v, source, evidence));
      }

      final stored = cat.db.select(
        "SELECT id, field, suggested_value, source, COALESCE(evidence,'') AS ev FROM suggestions WHERE track_id=? AND status='pending' ORDER BY confidence DESC, id",
        [t.id],
      );
      final album = t.album == null || fold(t.album!).isEmpty
          ? null
          : fold(t.album!);
      final artistF = t.artist == null || fold(t.artist!).isEmpty
          ? null
          : fold(t.artist!);
      for (final f in fields) {
        for (final s in stored.where((s) => s['field'] == f)) {
          final v = s['suggested_value'] as String;
          add(f, v, s['source'] as String, s['ev'] as String);
          final h = hints.isEmpty ? null : hints.last;
          if (h != null &&
              h.suggestionId == null &&
              h.field == f &&
              fold(h.value) == fold(v)) {
            h.suggestionId = s['id'] as int;
          }
        }
        switch (f) {
          case 'artist' || 'title':
            final parsed = parseFilename(stem);
            if (parsed != null) {
              if (f == 'artist' && (t.artist ?? '').trim().isEmpty) {
                add(
                  'artist',
                  parsed.$1,
                  'file name',
                  'File name "${t.fileName}"',
                );
              }
              if (f == 'title' && (t.title ?? '').trim().isEmpty) {
                add(
                  'title',
                  parsed.$2,
                  'file name',
                  'File name "${t.fileName}"',
                );
              }
            } else if (f == 'title' &&
                (t.title ?? '').trim().isEmpty &&
                stem.trim().isNotEmpty) {
              add(
                'title',
                stem.replaceAll('_', ' '),
                'file name',
                'The file name without its extension',
              );
            }
            if (f == 'artist' && album != null) {
              final m = majority(byAlbumArtist, album);
              if (m != null) {
                add(
                  'artist',
                  m.$1,
                  'same album',
                  '${m.$2} other track(s) on this album',
                );
              }
            }
          case 'genre':
            for (final dir in folders.reversed) {
              final m = majority(genreForms, fold(dir));
              if (m != null) {
                add(
                  'genre',
                  m.$1,
                  'folder name',
                  'In folder "$dir"; ${m.$2} track(s) already use this genre',
                );
              }
            }
            if (album != null) {
              final m = majority(byAlbumGenre, album);
              if (m != null) {
                add(
                  'genre',
                  m.$1,
                  'same album',
                  '${m.$2} other track(s) on this album',
                );
              }
            }
            if (artistF != null) {
              final m = majority(byArtistGenre, artistF);
              if (m != null) {
                add(
                  'genre',
                  m.$1,
                  'same artist',
                  '${m.$2} other track(s) by this artist',
                );
              }
            }
          case 'year':
            final y = yearIn(stem);
            if (y != null) {
              add('year', '$y', 'file name', '"($y)" in the file name');
            }
            for (final dir in folders.reversed) {
              final yd = yearIn(dir);
              if (yd != null) {
                add('year', '$yd', 'folder name', '"($yd)" in folder "$dir"');
              }
            }
            if (t.originalYear != null) {
              add(
                'year',
                '${t.originalYear}',
                'original year tag',
                "The file's original-year tag",
              );
            }
            if (album != null) {
              final m = majority(byAlbumYear, album);
              if (m != null) {
                add(
                  'year',
                  m.$1,
                  'same album',
                  '${m.$2} other track(s) on this album',
                );
              }
            }
        }
      }
      rows.add(FixRow(t, folders.join('/'), hints));
    }
    return (label, fields, page.total, rows);
  }
}
