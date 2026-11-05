import 'dart:convert';

import 'catalogue.dart';
import 'library.dart';
import 'rules.dart';

/// Crate colours (same list as 1.x).
const crateColors = [
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

class CrateException implements Exception {
  CrateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class Crate {
  Crate(Map<String, Object?> r, this.trackCount)
    : id = r['id'] as int,
      name = r['name'] as String,
      kind = r['kind'] as String,
      color = r['color'] as String?,
      category = r['category'] as String?,
      parentId = r['parent_id'] as int?,
      sortOrder = r['sort_order'] as int,
      rules = _rules(r['rules_json'] as String?),
      createdAt = r['created_at'] as int,
      updatedAt = r['updated_at'] as int;

  static Map<String, Object?>? _rules(String? j) {
    if (j == null) return null;
    try {
      return (jsonDecode(j) as Map).cast<String, Object?>();
    } on FormatException {
      return null;
    }
  }

  final int id;
  final String name, kind;
  final String? color, category;
  final int? parentId;
  final int sortOrder, trackCount, createdAt, updatedAt;
  final Map<String, Object?>? rules;
  bool get smart => kind == 'smart';
}

class CrateInput {
  const CrateInput({
    required this.name,
    required this.kind,
    this.color,
    this.category,
    this.parentId,
    this.rules,
  });
  final String name, kind;
  final String? color, category;
  final int? parentId;
  final Map<String, Object?>? rules;
}

/// Manual and smart crates, ported from 1.x `crates.rs`.
///
/// A smart crate holds every track its rules match, plus tracks added by hand, minus
/// tracks removed by hand (recorded as exclusions so the rules don't bring them back).
class CratesService {
  CratesService(this.cat) : lib = LibraryService(cat);
  final Catalogue cat;
  final LibraryService lib;

  static const _cols =
      'id, name, kind, color, category, parent_id, sort_order, rules_json, created_at, updated_at';

  String _validate(CrateInput input) {
    final name = input.name.trim();
    if (name.isEmpty) throw CrateException('crate name is required');
    if (name.runes.length > 120) {
      throw CrateException('crate name is too long (max 120 characters)');
    }
    if (input.kind != 'manual' && input.kind != 'smart') {
      throw CrateException('crate type must be manual or smart');
    }
    if (input.color != null && !crateColors.contains(input.color)) {
      throw CrateException('unknown colour');
    }
    if (input.kind == 'smart') {
      final rs = input.rules;
      if (rs == null || ((rs['rules'] as List?) ?? const []).isEmpty) {
        throw CrateException('smart crates need at least one rule');
      }
      // Compile once to validate fields, operators and values.
      compileRules(rs, lib.lowBitrateKbps);
    }
    return name;
  }

  String? _category(String? c) {
    final t = c?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  Crate create(CrateInput input) {
    final name = _validate(input);
    final now = nowMs();
    final order =
        cat.db
                .select('SELECT COALESCE(MAX(sort_order),0)+1 AS o FROM crates')
                .first['o']
            as int;
    cat.db.execute(
      'INSERT INTO crates(name, kind, color, category, parent_id, sort_order, rules_json, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?)',
      [
        name,
        input.kind,
        input.color,
        _category(input.category),
        input.parentId,
        order,
        input.kind == 'smart' ? jsonEncode(input.rules) : null,
        now,
        now,
      ],
    );
    return get(cat.db.lastInsertRowId);
  }

  Crate update(int id, CrateInput input) {
    final existing = get(id);
    if (existing.kind != input.kind) {
      throw CrateException(
        "a crate's type cannot be changed; create a new crate instead",
      );
    }
    final name = _validate(input);
    if (input.parentId == id) {
      throw CrateException('a crate cannot be inside itself');
    }
    cat.db.execute(
      'UPDATE crates SET name=?, color=?, category=?, parent_id=?, rules_json=?, updated_at=? WHERE id=?',
      [
        name,
        input.color,
        _category(input.category),
        input.parentId,
        input.kind == 'smart' ? jsonEncode(input.rules) : null,
        nowMs(),
        id,
      ],
    );
    return get(id);
  }

  void delete(int id) {
    cat.db.execute('DELETE FROM crates WHERE id=?', [id]);
    if (cat.db.updatedRows == 0) throw CrateException('crate not found');
  }

  Crate get(int id) {
    final r = cat.db.select('SELECT $_cols FROM crates WHERE id=?', [id]);
    if (r.isEmpty) throw CrateException('crate not found');
    return Crate(r.first, count(id));
  }

  List<Crate> list() => [
    for (final r in cat.db.select(
      'SELECT $_cols FROM crates ORDER BY sort_order, name',
    ))
      Crate(r, count(r['id'] as int)),
  ];

  int count(int id) =>
      lib.search(TrackQuery(extraWhere: membership(id), limit: 1)).total;

  /// WHERE fragment selecting a crate's members: (sql, params).
  (String, List<Object?>) membership(int crateId) {
    final r = cat.db.select('SELECT kind, rules_json FROM crates WHERE id=?', [
      crateId,
    ]);
    if (r.isEmpty) throw CrateException('crate not found');
    const inc =
        "t.id IN (SELECT track_id FROM crate_tracks WHERE crate_id=? AND mode='include')";
    if (r.first['kind'] == 'manual') return (inc, [crateId]);
    final json = r.first['rules_json'] as String?;
    final rs = json == null
        ? <String, Object?>{'match': 'all', 'rules': []}
        : (jsonDecode(json) as Map).cast<String, Object?>();
    final (sql, params) = compileRules(rs, lib.lowBitrateKbps);
    return (
      "(($sql) OR $inc) AND t.id NOT IN (SELECT track_id FROM crate_tracks WHERE crate_id=? AND mode='exclude')",
      [...params, crateId, crateId],
    );
  }

  /// Adds tracks. For smart crates this records a manual inclusion.
  int addTracks(int crateId, List<int> ids) {
    get(crateId);
    final now = nowMs();
    var n = 0;
    cat.db.execute('BEGIN');
    try {
      var pos =
          cat.db.select(
                'SELECT COALESCE(MAX(position),0) AS p FROM crate_tracks WHERE crate_id=?',
                [crateId],
              ).first['p']
              as int;
      final st = cat.db.prepare(
        "INSERT INTO crate_tracks(crate_id, track_id, mode, position, added_at) SELECT ?, id, 'include', ?, ? FROM tracks WHERE id=? "
        "ON CONFLICT(crate_id, track_id) DO UPDATE SET mode='include'",
      );
      for (final id in ids) {
        st.execute([crateId, ++pos, now, id]);
        n += cat.db.updatedRows;
      }
      st.close();
      cat.db.execute('COMMIT');
    } catch (_) {
      cat.db.execute('ROLLBACK');
      rethrow;
    }
    return n;
  }

  /// Removes tracks. For smart crates this records an exclusion so the rules don't bring
  /// them back.
  int removeTracks(int crateId, List<int> ids) {
    final c = get(crateId);
    final now = nowMs();
    var n = 0;
    cat.db.execute('BEGIN');
    try {
      final st = c.smart
          ? cat.db.prepare(
              "INSERT INTO crate_tracks(crate_id, track_id, mode, added_at) SELECT ?, id, 'exclude', ? FROM tracks WHERE id=? "
              "ON CONFLICT(crate_id, track_id) DO UPDATE SET mode='exclude'",
            )
          : cat.db.prepare(
              'DELETE FROM crate_tracks WHERE crate_id=? AND track_id=?',
            );
      for (final id in ids) {
        st.execute(c.smart ? [crateId, now, id] : [crateId, id]);
        n += cat.db.updatedRows;
      }
      st.close();
      cat.db.execute('COMMIT');
    } catch (_) {
      cat.db.execute('ROLLBACK');
      rethrow;
    }
    return n;
  }

  /// What a rule set would match, before saving it.
  TrackPage previewRules(Map<String, Object?> rs, {int limit = 50}) =>
      lib.search(
        TrackQuery(
          extraWhere: compileRules(rs, lib.lowBitrateKbps),
          limit: limit.clamp(1, 200),
        ),
      );

  /// The crate's tracks, for the Library view.
  TrackPage tracks(
    int crateId, {
    String? text,
    String? sort,
    bool desc = false,
    int offset = 0,
    int limit = 200,
  }) => lib.search(
    TrackQuery(
      extraWhere: membership(crateId),
      text: text,
      sort: sort,
      desc: desc,
      offset: offset,
      limit: limit,
    ),
  );
}
