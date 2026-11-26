import 'dart:convert';

import 'catalogue.dart';
import 'library.dart';
import 'rules.dart';
import 'serato_library.dart';

/// The auto-reorganizer: a nested crate template such as
/// Genre → Decade → Energy turns the analysed library into a tree of Serato
/// crates (`Root%%House%%1990s%%Energy 7-8`), each sorted harmonically
/// (Camelot key round the wheel, then BPM).
class CrateTreeException implements Exception {
  CrateTreeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What a level can split by, with its label.
const treeFields = {
  'genre': 'Genre',
  'decade': 'Decade',
  'year': 'Year',
  'energy': 'Energy',
  'bpm': 'BPM range',
  'key': 'Key (Camelot)',
  'mood': 'Mood',
  'event': 'Event',
  'label': 'Record label',
  'artist': 'Artist',
};

/// One level of the tree. [step] sizes the ranges for energy (default 2:
/// "Energy 7-8") and BPM (default 5: "120-124 BPM").
class TreeLevel {
  const TreeLevel(this.field, {this.step});
  final String field;
  final int? step;

  Map<String, Object?> toJson() => {'field': field, 'step': ?step};
  static TreeLevel fromJson(Map<String, Object?> j) =>
      TreeLevel('${j['field']}', step: (j['step'] as num?)?.toInt());
}

/// A whole template: the top crate's name, its levels, which tracks go in
/// (a rule set as in rules.dart; none: every present track) and whether
/// tracks with no value for a level go into a "No …" crate or are left out.
class CrateTreePlan {
  const CrateTreePlan({
    required this.root,
    required this.levels,
    this.rules,
    this.includeUnknown = true,
  });
  final String root;
  final List<TreeLevel> levels;
  final Map<String, Object?>? rules;
  final bool includeUnknown;

  Map<String, Object?> toJson() => {
    'root': root,
    'levels': [for (final l in levels) l.toJson()],
    'rules': ?rules,
    'include_unknown': includeUnknown,
  };

  static CrateTreePlan fromJson(Map<String, Object?> j) => CrateTreePlan(
    root: '${j['root'] ?? ''}',
    levels: [
      for (final l in (j['levels'] as List? ?? const []))
        TreeLevel.fromJson((l as Map).cast<String, Object?>()),
    ],
    rules: (j['rules'] as Map?)?.cast<String, Object?>(),
    includeUnknown: j['include_unknown'] != false,
  );
}

class _T {
  _T(this.id, this.path, this.v);
  final int id;
  final String path;
  final Map<String, Object?> v;
  double? get bpm => (v['bpm'] as num?)?.toDouble();
  String? get key => v['key'] as String?;
}

/// One crate of the tree: its full name ("Root%%House%%1990s"), and its
/// tracks' paths in harmonic order (every track below it, for a parent).
class TreeCrate {
  TreeCrate(this.name, this.paths);
  final String name;
  final List<String> paths;
  int get depth => '%%'.allMatches(name).length;
  String get label => name.split('%%').last;
}

String _range(String unit, num v, int step, {String suffix = ''}) {
  final lo = (v ~/ step) * step;
  final hi = lo + step - 1;
  return step <= 1 ? '$unit$lo$suffix' : '$unit$lo-$hi$suffix';
}

/// The crate a track falls in at [level], or null when it has no value.
String? bucketOf(TreeLevel level, Map<String, Object?> v) {
  String? text(Object? x) {
    final s = x?.toString().trim();
    return s == null || s.isEmpty ? null : s;
  }

  switch (level.field) {
    case 'decade':
      final y = v['year'] as int?;
      return y == null || y < 1900 ? null : '${(y ~/ 10) * 10}s';
    case 'year':
      final y = v['year'] as int?;
      return y == null || y < 1900 ? null : '$y';
    case 'energy':
      final e = (v['energy'] as num?)?.round();
      if (e == null) return null;
      final step = level.step ?? 2;
      // bands start at 1: 1-2, 3-4, …, 9-10
      final lo = ((e - 1) ~/ step) * step + 1;
      final hi = (lo + step - 1).clamp(lo, 10);
      return step <= 1 ? 'Energy $e' : 'Energy $lo-$hi';
    case 'bpm':
      final b = (v['bpm'] as num?)?.toDouble();
      return b == null || b <= 0
          ? null
          : _range('', b.round(), level.step ?? 5, suffix: ' BPM');
    case 'key':
      return text(v['key']);
    default:
      return text(v[level.field]);
  }
}

String _unknown(String field) => switch (field) {
  'genre' => 'No genre',
  'decade' || 'year' => 'No year',
  'energy' => 'No energy',
  'bpm' => 'No BPM',
  'key' => 'No key',
  'label' => 'No label',
  _ => 'No ${field.toLowerCase()}',
};

/// Sort key for crate names inside one parent: numbers in order ("Energy 3-4"
/// before "Energy 10"), Camelot keys round the wheel, the "No …" crate last.
Comparable<Object> _nameKey(String name) {
  if (name.startsWith('No ')) return '~$name';
  final cam = camelotSortKey(name);
  if (cam != null) return cam.toString().padLeft(4, '0');
  final m = RegExp(r'\d+').firstMatch(name);
  if (m != null) {
    return '${m.group(0)!.padLeft(6, '0')}$name'.toLowerCase();
  }
  return name.toLowerCase();
}

int harmonicCompare((int?, double?) a, (int?, double?) b) {
  final (ka, ba) = a;
  final (kb, bb) = b;
  if (ka != kb) {
    if (ka == null) return 1;
    if (kb == null) return -1;
    return ka.compareTo(kb);
  }
  if (ba != bb) {
    if (ba == null) return 1;
    if (bb == null) return -1;
    return ba.compareTo(bb);
  }
  return 0;
}

/// Works the tree out from the catalogue: every crate, parents first, each
/// sorted harmonically. Nothing is written.
List<TreeCrate> buildCrateTree(Catalogue cat, CrateTreePlan plan) {
  final root = plan.root
      .split('%%')
      .map(crateFileName)
      .where((x) => x.isNotEmpty)
      .join('%%');
  if (root.isEmpty) throw CrateTreeException('Give the top crate a name.');
  if (plan.levels.isEmpty) {
    throw CrateTreeException('Choose at least one level.');
  }
  if (plan.levels.length > 5) {
    throw CrateTreeException('Five levels at most.');
  }
  for (final l in plan.levels) {
    if (!treeFields.containsKey(l.field)) {
      throw CrateTreeException('Unknown level "${l.field}".');
    }
    if (l.step != null && (l.step! < 1 || l.step! > 50)) {
      throw CrateTreeException('A range must be between 1 and 50.');
    }
  }
  final lib = LibraryService(cat);
  var where = "t.presence='present' AND t.media_kind IS NOT 'video'";
  var params = <Object?>[];
  if (plan.rules != null) {
    final (sql, p) = compileRules(plan.rules!, lib.lowBitrateKbps);
    where = '$where AND ($sql)';
    params = p;
  }
  final tracks = <_T>[
    for (final r in cat.db.select(
      'SELECT t.id AS id, t.path AS path, COALESCE(u.genre, t.genre) AS genre, '
      'COALESCE(u.year, t.year) AS year, COALESCE(u.energy, a.energy) AS energy, '
      'COALESCE(u.bpm, t.bpm_tag, a.bpm) AS bpm, '
      'keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot)) AS key, '
      'u.mood AS mood, u.event AS event, COALESCE(u.record_label, t.label) AS label, '
      'COALESCE(u.artist, t.artist) AS artist '
      '$from WHERE $where',
      params,
    ))
      _T(r['id'] as int, r['path'] as String, {
        for (final k in r.keys) k: r[k],
      }),
  ];
  final byCrate = <String, List<_T>>{};
  for (final t in tracks) {
    var name = root;
    var ok = true;
    (byCrate[name] ??= []).add(t);
    for (final l in plan.levels) {
      final b =
          bucketOf(l, t.v) ?? (plan.includeUnknown ? _unknown(l.field) : null);
      if (b == null) {
        ok = false;
        break;
      }
      name = '$name%%${crateFileName(b)}';
      (byCrate[name] ??= []).add(t);
    }
    if (!ok) {
      // left out below this level: take it out of the parents again
      for (final e in byCrate.entries) {
        if (name == e.key || name.startsWith('${e.key}%%')) e.value.remove(t);
      }
    }
  }
  byCrate.removeWhere((_, v) => v.isEmpty);
  List<String> ordered(List<_T> ts) {
    final s = [...ts]
      ..sort(
        (a, b) => harmonicCompare(
          (camelotSortKey(a.key), a.bpm),
          (camelotSortKey(b.key), b.bpm),
        ),
      );
    return [for (final t in s) t.path];
  }

  final names = byCrate.keys.toList()
    ..sort((a, b) {
      final pa = a.split('%%'), pb = b.split('%%');
      for (var i = 0; i < pa.length && i < pb.length; i++) {
        if (pa[i] != pb[i]) {
          return _nameKey(pa[i]).compareTo(_nameKey(pb[i]));
        }
      }
      return pa.length.compareTo(pb.length);
    });
  return [for (final n in names) TreeCrate(n, ordered(byCrate[n]!))];
}

/// Writes [tree] into Serato (one check that Serato is closed, one backup).
/// With [replace], crates already under the top crate that the tree no
/// longer has are deleted; otherwise they stay. Returns
/// (crates written, tracks on another drive left out, crates removed).
(int, int, int) writeCrateTree(
  SeratoLibrary lib,
  List<TreeCrate> tree, {
  bool replace = true,
}) {
  if (tree.isEmpty) return (0, 0, 0);
  final root = tree.first.name.split('%%').first;
  return lib.batch('Write crate template “$root”', () {
    var removed = 0;
    if (replace) {
      final keep = {for (final c in tree) c.name};
      for (final c in lib.crates()) {
        if ((c.name == root || c.name.startsWith('$root%%')) &&
            !keep.contains(c.name)) {
          removed += lib.delete(c.name);
        }
      }
    }
    var other = 0;
    for (final c in tree) {
      final (_, o) = lib.save(c.name, c.paths);
      if (c.depth == 0) other = o;
    }
    return (tree.length, other, removed);
  });
}

/// Templates the DJ saved (setting `crate_tree_templates`), by name.
Map<String, CrateTreePlan> savedTreeTemplates(Catalogue cat) {
  final raw = cat.getSetting('crate_tree_templates');
  if (raw == null || raw.isEmpty) return {};
  try {
    final m = (jsonDecode(raw) as Map).cast<String, Object?>();
    return {
      for (final e in m.entries)
        e.key: CrateTreePlan.fromJson((e.value as Map).cast<String, Object?>()),
    };
  } on Object {
    return {};
  }
}

void saveTreeTemplate(Catalogue cat, CrateTreePlan plan) {
  final all = savedTreeTemplates(cat)..[plan.root] = plan;
  cat.setSetting(
    'crate_tree_templates',
    jsonEncode({for (final e in all.entries) e.key: e.value.toJson()}),
  );
}

void deleteTreeTemplate(Catalogue cat, String root) {
  final all = savedTreeTemplates(cat)..remove(root);
  cat.setSetting(
    'crate_tree_templates',
    jsonEncode({for (final e in all.entries) e.key: e.value.toJson()}),
  );
}

/// Ready-made templates offered first.
const treePresets = <String, List<TreeLevel>>{
  'Genre → Decade → Energy': [
    TreeLevel('genre'),
    TreeLevel('decade'),
    TreeLevel('energy'),
  ],
  'Genre → BPM range': [TreeLevel('genre'), TreeLevel('bpm')],
  'Energy → Key': [TreeLevel('energy'), TreeLevel('key')],
  'Event → Genre': [TreeLevel('event'), TreeLevel('genre')],
};
