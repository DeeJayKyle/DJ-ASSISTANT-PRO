import 'keys.dart';
import 'text.dart';

/// Rule engine for search filters and smart crates, ported from 1.x `rules.rs`.
///
/// Rules are plain data (the same JSON as 1.x). They compile to SQL from a fixed
/// whitelist of fields and operators; every user value becomes a bound `?` parameter,
/// so user text can never become SQL.
enum _T { text, number, tag, boolean, enumeration }

const _maxDepth = 4;
const _maxNodes = 200;

class RuleException implements Exception {
  RuleException(this.message);
  final String message;
  @override
  String toString() => message;
}

(String, _T)? _field(String id, int low) {
  const fields = <String, (String, _T)>{
    'title': ('COALESCE(u.title, t.title)', _T.text),
    'artist': ('COALESCE(u.artist, t.artist)', _T.text),
    'album': ('COALESCE(u.album, t.album)', _T.text),
    'album_artist': ('t.album_artist', _T.text),
    'genre': ('COALESCE(u.genre, t.genre)', _T.text),
    'file_genre': ('t.genre', _T.text),
    'label': ('COALESCE(u.record_label, t.label)', _T.text),
    'composer': ('t.composer', _T.text),
    'comment': ('t.comment', _T.text),
    'mood': ('u.mood', _T.text),
    'notes': ('u.notes', _T.text),
    'color': ('u.color', _T.enumeration),
    'key': ('keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot))', _T.text),
    'camelot': ('a.camelot', _T.text),
    'version': ('COALESCE(u.version_label, t.version_hint)', _T.text),
    'clean_explicit': (
      'COALESCE(u.clean_explicit, t.clean_hint)',
      _T.enumeration,
    ),
    'path': ('t.path', _T.text),
    'file_name': ('t.file_name', _T.text),
    'format': ('t.format', _T.text),
    'extension': ('t.extension', _T.enumeration),
    'year': ('COALESCE(u.year, t.year)', _T.number),
    'original_year': ('COALESCE(u.original_year, t.original_year)', _T.number),
    'decade': ('(COALESCE(u.year, t.year) / 10) * 10', _T.number),
    'bpm': ('COALESCE(u.bpm, t.bpm_tag, a.bpm)', _T.number),
    'energy': ('COALESCE(u.energy, a.energy)', _T.number),
    'my_energy': ('u.energy', _T.number),
    'loudness': ('a.loudness_lufs', _T.number),
    'intro_seconds': (
      '((a.intro_end_ms - a.silence_start_ms) / 1000.0)',
      _T.number,
    ),
    'outro_seconds': (
      '((a.duration_ms - a.silence_end_ms - a.outro_start_ms) / 1000.0)',
      _T.number,
    ),
    'plays': (
      "(SELECT COUNT(*) FROM play_history ph WHERE ph.track_id = t.id) + (SELECT COUNT(*) FROM gig_events ge WHERE ge.track_id = t.id AND ge.kind = 'played')",
      _T.number,
    ),
    'analysed': ("(a.status = 'ok')", _T.boolean),
    'rating': ('u.rating', _T.number),
    'bitrate': ('t.bitrate_kbps', _T.number),
    'duration': ('(t.duration_ms / 1000.0)', _T.number),
    'sample_rate': ('t.sample_rate', _T.number),
    'file_size_mb': ('(t.file_size / 1048576.0)', _T.number),
    'added': ('t.first_seen_at', _T.number),
    'lossless': ('t.lossless', _T.boolean),
    'media': ('t.media_kind', _T.enumeration),
    'video_codec': ('t.video_codec', _T.text),
    'video_height': ('t.height', _T.number),
    'frame_rate': ('t.frame_rate', _T.number),
    'tag': ('', _T.tag),
    'status': (
      "(CASE WHEN t.presence='missing' AND t.removed_at IS NOT NULL THEN 'removed' WHEN t.presence='missing' THEN 'missing' WHEN r.status='offline' THEN 'offline' WHEN t.read_status<>'ok' THEN t.read_status ELSE 'ok' END)",
      _T.enumeration,
    ),
  };
  if (id == 'quality') {
    return (
      "(CASE WHEN t.media_kind='video' THEN 'video' WHEN t.lossless=1 THEN 'lossless' WHEN t.lossless=0 AND t.bitrate_kbps IS NOT NULL AND t.bitrate_kbps < $low THEN 'low_bitrate' WHEN t.lossless=0 AND t.bitrate_kbps IS NOT NULL THEN 'lossy' ELSE 'unknown' END)",
      _T.enumeration,
    );
  }
  return fields[id];
}

String? _asText(Object? v) => switch (v) {
  String s => s,
  num n =>
    (n == n.roundToDouble() && n is double)
        ? n.toInt().toString()
        : n.toString(),
  bool b => b.toString(),
  _ => null,
};

double? _asNum(Object? v) {
  final d = switch (v) {
    num n => n.toDouble(),
    String s => double.tryParse(s.trim()),
    _ => null,
  };
  return (d != null && d.isFinite) ? d : null;
}

/// Compiles a rule set (`{"match": "all"|"any", "rules": [...], "exclude": [...]}`) to
/// `(sql, params)` for a WHERE clause over the aliases t, u, a and r.
(String, List<Object?>) compileRules(Map<String, Object?> rs, int lowKbps) {
  final c = _Compiler(lowKbps);
  final rules = (rs['rules'] as List?) ?? const [];
  final exclude = (rs['exclude'] as List?) ?? const [];
  final inc = rules.isEmpty ? '1=1' : c.group(rs['match'] == 'any', rules, 0);
  if (exclude.isEmpty) return (inc, c.params);
  final exc = c.group(true, exclude, 0);
  // COALESCE treats "unknown" (NULL) as not excluded.
  return ('($inc AND NOT COALESCE($exc, 0))', c.params);
}

class _Compiler {
  _Compiler(this.low);
  final int low;
  final params = <Object?>[];
  var nodes = 0;

  String bind(Object? v) {
    params.add(v);
    return '?';
  }

  String group(bool any, List<Object?> rules, int depth) {
    if (rules.isEmpty) return '1=1';
    final parts = [for (final r in rules) node(r, depth)];
    return '(${parts.join(any ? ' OR ' : ' AND ')})';
  }

  String node(Object? n, int depth) {
    if (++nodes > _maxNodes) throw RuleException('too many rules');
    if (depth > _maxDepth) {
      throw RuleException('rule groups are nested too deeply');
    }
    if (n is! Map) throw RuleException('a rule must be an object');
    return switch (n['kind']) {
      'condition' => condition('${n['field']}', '${n['op']}', n['value']),
      'group' => group(
        n['match'] == 'any',
        (n['rules'] as List?) ?? const [],
        depth + 1,
      ),
      _ => throw RuleException('unknown rule kind'),
    };
  }

  String condition(String id, String op, Object? value) {
    final f = _field(id, low);
    if (f == null) throw RuleException("unknown field '$id'");
    final (expr, ty) = f;
    final isKey = id == 'key' || id == 'camelot';
    String keyNorm(String t) => isKey ? (normalizeKey(t) ?? t) : t;
    String textValue() {
      final t = _asText(value);
      if (t == null) throw RuleException("'$id' needs a text value");
      return keyNorm(t);
    }

    if (ty == _T.tag) {
      switch (op) {
        case 'has' || 'not_has':
          final p = bind(fold(textValue().trim()));
          final ex =
              'EXISTS (SELECT 1 FROM track_tags tt JOIN tags g ON g.id = tt.tag_id WHERE tt.track_id = t.id AND g.name_fold = $p)';
          return op == 'has' ? ex : 'NOT $ex';
        case 'is_empty':
          return 'NOT EXISTS (SELECT 1 FROM track_tags tt WHERE tt.track_id = t.id)';
        case 'is_not_empty':
          return 'EXISTS (SELECT 1 FROM track_tags tt WHERE tt.track_id = t.id)';
      }
    }
    if (op == 'is_empty') {
      return "($expr IS NULL OR TRIM(CAST($expr AS TEXT)) = '')";
    }
    if (op == 'is_not_empty') {
      return "($expr IS NOT NULL AND TRIM(CAST($expr AS TEXT)) <> '')";
    }
    if (ty == _T.text &&
        (op == 'contains' || op == 'not_contains' || op == 'starts_with')) {
      final v = fold(textValue());
      final p = bind(
        op == 'starts_with' ? '${likeEscape(v)}%' : '%${likeEscape(v)}%',
      );
      final m = "fold($expr) LIKE $p ESCAPE '\\'";
      return op == 'not_contains' ? '($expr IS NULL OR NOT ($m))' : m;
    }
    if ((ty == _T.text || ty == _T.enumeration) &&
        (op == 'equals' || op == 'not_equals')) {
      final p = bind(fold(textValue().trim()));
      return op == 'equals'
          ? 'fold($expr) = $p'
          : '($expr IS NULL OR fold($expr) <> $p)';
    }
    if ((ty == _T.enumeration && (op == 'in' || op == 'not_in')) ||
        (ty == _T.text && op == 'in')) {
      if (value is! List) throw RuleException("'$id' needs a list");
      if (value.isEmpty || value.length > 100) {
        throw RuleException('list must have 1–100 values');
      }
      final ps = [
        for (final v in value)
          bind(
            fold(
              keyNorm(
                _asText(v) ?? (throw RuleException('list values must be text')),
              ).trim(),
            ),
          ),
      ].join(', ');
      return op == 'not_in'
          ? '($expr IS NULL OR fold($expr) NOT IN ($ps))'
          : 'fold($expr) IN ($ps)';
    }
    if (ty == _T.boolean && op == 'is_true') return '$expr = 1';
    if (ty == _T.boolean && op == 'is_false') return '$expr = 0';
    if (ty == _T.number && op == 'between') {
      if (value is! List || value.length != 2) {
        throw RuleException("'$id' between needs [min, max]");
      }
      final a =
          _asNum(value[0]) ?? (throw RuleException('min must be a number'));
      final b =
          _asNum(value[1]) ?? (throw RuleException('max must be a number'));
      final p1 = bind(a <= b ? a : b);
      final p2 = bind(a <= b ? b : a);
      return '($expr BETWEEN $p1 AND $p2)';
    }
    const syms = {
      'eq': '=',
      'neq': '<>',
      'gt': '>',
      'gte': '>=',
      'lt': '<',
      'lte': '<=',
    };
    if (ty == _T.number && syms.containsKey(op)) {
      final p = bind(
        _asNum(value) ?? (throw RuleException("'$id' needs a number")),
      );
      return op == 'neq'
          ? '($expr IS NULL OR $expr <> $p)'
          : '($expr ${syms[op]} $p)';
    }
    throw RuleException("operator '$op' is not valid for field '$id'");
  }
}
