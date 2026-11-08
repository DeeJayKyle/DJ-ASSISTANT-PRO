import 'analysis_store.dart';
import 'catalogue.dart';
import 'library.dart';
import 'serato_tags.dart';
import 'text.dart';

/// Catalogue-only edits and queries (1.x `library.rs`): the DJ's own values,
/// tags, facets, stats and track detail. Files are never touched.
const trackColors = [
  'red',
  'orange',
  'yellow',
  'green',
  'teal',
  'blue',
  'purple',
  'pink',
  'grey',
];

class EditException implements Exception {
  EditException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw EditException(m);

/// Patch keys: present → set (null clears), absent → unchanged.
const _patchCols = {
  'genre': 'genre',
  'year': 'year',
  'bpm': 'bpm',
  'key': 'musical_key',
  'energy': 'energy',
  'rating': 'rating',
  'mood': 'mood',
  'color': 'color',
  'notes': 'notes',
  'version_label': 'version_label',
  'clean_explicit': 'clean_explicit',
  'title': 'title',
  'artist': 'artist',
  'album': 'album',
  'original_year': 'original_year',
  'record_label': 'record_label',
};
const _textMax = {
  'genre': 120, 'key': 12, 'mood': 80, 'notes': 4000, 'version_label': 80, //
  'title': 300, 'artist': 300, 'album': 300, 'record_label': 200,
};

extension LibraryEdits on LibraryService {
  /// Sets the DJ's own values on [ids] (validated first, nothing written on error).
  int updateUserFields(List<int> ids, Map<String, Object?> patch) {
    if (ids.isEmpty || ids.length > 100000) {
      _no('select between 1 and 100000 tracks');
    }
    final vals = <String, Object?>{};
    for (final e in patch.entries) {
      final k = e.key;
      if (!_patchCols.containsKey(k)) _no('unknown field $k');
      var v = e.value;
      if (_textMax.containsKey(k)) {
        final s = v?.toString().trim();
        if (s != null && s.runes.length > _textMax[k]!) {
          _no('value is too long (max ${_textMax[k]} characters)');
        }
        v = (s == null || s.isEmpty) ? null : s;
      }
      int? asInt(Object? x) =>
          x == null ? null : (x is num ? x.toInt() : int.tryParse('$x'));
      switch (k) {
        case 'energy':
          v = asInt(v);
          if (v != null && ((v as int) < 1 || v > 10)) {
            _no('energy must be 1–10');
          }
        case 'rating':
          v = asInt(v);
          if (v != null && ((v as int) < 0 || v > 5)) _no('rating must be 0–5');
        case 'year':
          v = asInt(v);
          if (v != null && ((v as int) < 1000 || v > 9999)) {
            _no('year must be four digits');
          }
        case 'original_year':
          v = asInt(v);
          if (v != null && ((v as int) < 1000 || v > 9999)) {
            _no('original year must be four digits');
          }
        case 'bpm':
          v = v == null
              ? null
              : (v is num ? v.toDouble() : double.tryParse('$v'));
          if (v != null && !((v as double) > 0 && v < 1000)) {
            _no('BPM must be between 0 and 1000');
          }
        case 'color':
          if (v != null && !trackColors.contains(v)) _no('unknown colour');
        case 'clean_explicit':
          if (v != null && v != 'clean' && v != 'explicit') {
            _no("clean/explicit must be 'clean' or 'explicit'");
          }
      }
      vals[_patchCols[k]!] = v;
    }
    final db = cat.db;
    final now = nowMs();
    var n = 0;
    db.execute('BEGIN');
    try {
      final ensure = db.prepare(
        'INSERT OR IGNORE INTO track_user(track_id, updated_at) SELECT id, ? FROM tracks WHERE id=?',
      );
      for (final id in ids) {
        ensure.execute([now, id]);
      }
      ensure.close();
      for (final e in vals.entries) {
        final st = db.prepare(
          'UPDATE track_user SET ${e.key}=?, updated_at=? WHERE track_id=?',
        );
        for (final id in ids) {
          st.execute([e.value, now, id]);
          n += db.updatedRows;
        }
        st.close();
      }
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
    return n;
  }

  List<(String, int)> listTags() => [
    for (final r in cat.db.select(
      'SELECT g.name, COUNT(tt.track_id) AS n FROM tags g LEFT JOIN track_tags tt ON tt.tag_id=g.id GROUP BY g.id ORDER BY g.name_fold',
    ))
      (r['name'] as String, r['n'] as int),
  ];

  void setTags(
    List<int> ids, {
    List<String> add = const [],
    List<String> remove = const [],
  }) {
    final db = cat.db;
    db.execute('BEGIN');
    try {
      for (final raw in add) {
        final name = raw.trim();
        if (name.isEmpty) continue;
        if (name.runes.length > 60) _no('tag is too long (max 60 characters)');
        db.execute(
          'INSERT OR IGNORE INTO tags(name, name_fold) VALUES (?, ?)',
          [name, fold(name)],
        );
        final tagId = db.select('SELECT id FROM tags WHERE name_fold=?', [
          fold(name),
        ]).first['id'];
        for (final id in ids) {
          db.execute(
            'INSERT OR IGNORE INTO track_tags(track_id, tag_id) SELECT id, ? FROM tracks WHERE id=?',
            [tagId, id],
          );
        }
      }
      for (final name in remove) {
        for (final id in ids) {
          db.execute(
            'DELETE FROM track_tags WHERE track_id=? AND tag_id=(SELECT id FROM tags WHERE name_fold=?)',
            [id, fold(name.trim())],
          );
        }
      }
      db.execute(
        'DELETE FROM tags WHERE id NOT IN (SELECT tag_id FROM track_tags)',
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Distinct values of a facet with counts (filter dropdowns).
  List<(String, int)> facet(String field, {int limit = 200}) {
    final expr = switch (field) {
      'genre' => 'COALESCE(u.genre, t.genre)',
      'artist' => 'COALESCE(u.artist, t.artist)',
      'format' => 't.format',
      'key' => 'keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot))',
      'mood' => 'u.mood',
      'label' => 'COALESCE(u.record_label, t.label)',
      'decade' => 'CAST((COALESCE(u.year, t.year)/10)*10 AS TEXT)',
      'version' => 'COALESCE(u.version_label, t.version_hint)',
      _ => _no('unknown facet'),
    };
    return [
      for (final r in cat.db.select(
        "SELECT $expr AS v, COUNT(*) AS n $from WHERE t.presence='present' AND v IS NOT NULL AND v <> '' "
        'GROUP BY fold(v) ORDER BY COUNT(*) DESC LIMIT ?',
        [limit.clamp(1, 1000)],
      ))
        ('${r['v']}', r['n'] as int),
    ];
  }

  Map<String, int> stats() {
    final low = lowBitrateKbps;
    final r = cat.db
        .select(
          "SELECT SUM(t.presence='present') AS tracks, SUM(t.presence='missing') AS missing, "
          "SUM(t.presence='present' AND r.status='offline') AS offline, SUM(t.presence='present' AND t.read_status='error') AS errors, "
          "SUM(t.presence='present' AND t.read_status='unsupported') AS unsupported, "
          "SUM(t.presence='present' AND t.lossless=0 AND t.bitrate_kbps IS NOT NULL AND t.bitrate_kbps < $low) AS low_bitrate, "
          "SUM(t.presence='present' AND t.lossless=1) AS lossless, "
          "SUM(CASE WHEN t.presence='present' THEN t.file_size ELSE 0 END) AS total_bytes, "
          "SUM(CASE WHEN t.presence='present' THEN COALESCE(t.duration_ms,0) ELSE 0 END) AS total_duration_ms "
          'FROM tracks t LEFT JOIN library_roots r ON r.id=t.root_id',
        )
        .first;
    return {
      for (final k in r.keys) k: (r[k] as int?) ?? 0,
      'roots':
          cat.db.select('SELECT COUNT(*) AS n FROM library_roots').first['n']
              as int,
      'crates':
          cat.db.select('SELECT COUNT(*) AS n FROM crates').first['n'] as int,
    };
  }

  TrackRow? row(int id) {
    final p = search(
      TrackQuery(
        includeMissing: true,
        limit: 1,
        extraWhere: ('t.id = ?', [id]),
      ),
    );
    return p.rows.isEmpty ? null : p.rows.first;
  }

  /// File values, the DJ's values and technical properties, kept apart so the
  /// interface never blurs them.
  Map<String, Object?> trackDetail(int id) {
    final row = this.row(id) ?? _no('track not found');
    final t = cat.db.select('SELECT * FROM tracks WHERE id=?', [id]).first;
    final mine = cat.db.select('SELECT * FROM track_user WHERE track_id=?', [
      id,
    ]);
    final m =
        mine.isEmpty ? <String, Object?>{} : Map<String, Object?>.of(mine.first)
          ..remove('track_id');
    if (m.containsKey('musical_key')) m['key'] = m.remove('musical_key');
    return {
      'row': row,
      'file': {
        for (final k in [
          'title',
          'artist',
          'album',
          'album_artist',
          'genre',
          'year',
          'original_year',
          'track_no',
          'disc_no',
          'composer',
          'label',
          'comment',
          'isrc',
          'version_hint',
          'clean_hint',
        ])
          k: t[k],
        'date': t['date_text'],
        'bpm': t['bpm_tag'],
        'key': t['key_tag'],
      },
      'mine': m,
      'technical': {
        for (final k in [
          'format',
          'codec',
          'duration_ms',
          'bitrate_kbps',
          'sample_rate',
          'bit_depth',
          'channels',
          'file_size',
          'file_mtime',
          'path',
          'extension',
          'first_seen_at',
          'last_seen_at',
          'content_hash',
          'read_status',
          'presence',
        ])
          k: t[k],
        'lossless': t['lossless'] == null ? null : t['lossless'] == 1,
        'low_bitrate_threshold_kbps': lowBitrateKbps,
      },
      'crates': [
        for (final r in cat.db.select(
          "SELECT c.id, c.name FROM crate_tracks ct JOIN crates c ON c.id=ct.crate_id WHERE ct.track_id=? AND ct.mode='include' ORDER BY c.name",
          [id],
        ))
          (r['id'] as int, r['name'] as String),
      ],
      'read_error': t['read_error'],
      'analysis': AnalysisStore(cat).get(id),
      // Serato's own grid and BPM in the file's tags (read only)
      'serato': () {
        final s = readSeratoAnalysis(t['path'] as String);
        return s.isEmpty
            ? null
            : {'bpm': s.bpm, 'beatgrid': s.beatgrid?.toJson()};
      }(),
      'plays': cat.db.select(
        "SELECT (SELECT COUNT(*) FROM play_history WHERE track_id=?) + (SELECT COUNT(*) FROM gig_events WHERE track_id=? AND kind='played') AS n",
        [id, id],
      ).first['n'],
    };
  }

  /// Ids of the tracks matching [q]: all of them, or the first [max].
  List<int> trackIds(TrackQuery q, {int? max}) {
    final (w, params) = where(q);
    return [
      for (final r in cat.db.select(
        'SELECT t.id $from WHERE $w${max == null ? '' : ' LIMIT ${max < 1 ? 1 : max}'}',
        params,
      ))
        r['id'] as int,
    ];
  }
}
