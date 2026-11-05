import 'dart:convert';

import 'catalogue.dart';
import 'crates.dart';
import 'library.dart';
import 'library_edit.dart';
import 'text.dart';

/// Crate templates, labels and crate hygiene (1.x `templates.rs`), following the
/// "Crate & Playlist Cheat Sheet": organise by genre, sort by energy, utility and
/// event crates, ratings, colour tags and an example folder structure.
class TemplateException implements Exception {
  TemplateException(this.message);
  final String message;
  @override
  String toString() => message;
}

Map<String, Object?> _c(String field, String op, Object? value) => {
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
Map<String, Object?> _any(List<Object?> rules) => {
  'match': 'any',
  'rules': rules,
  'exclude': const [],
};

class _Spec {
  _Spec(this.name, this.color, this.rules);
  final String name;
  final String? color;
  final Map<String, Object?>? rules;
}

const templateGenres = [
  'House',
  'Tech House',
  'Afro House',
  'Hip Hop',
  'R&B',
  'Pop',
  'Latin',
  'Afrobeats',
  'Amapiano',
  'Dancehall',
];
const templateEvents = [
  'Club / Nightclub',
  'Festival',
  'Wedding',
  'Corporate',
  'Private Party',
  'Birthday',
  'Latin Night',
  'House Party',
  'Lounge / Chill', //
];

List<_Spec> _energy() => [
  _Spec(
    'Peak Time (9–10)',
    'red',
    _all([
      _c('energy', 'between', [9, 10]),
    ]),
  ),
  _Spec(
    'High Energy (7–8)',
    'orange',
    _all([
      _c('energy', 'between', [7, 8]),
    ]),
  ),
  _Spec(
    'Mid Energy (5–6)',
    'yellow',
    _all([
      _c('energy', 'between', [5, 6]),
    ]),
  ),
  _Spec(
    'Warm Up (3–4)',
    'green',
    _all([
      _c('energy', 'between', [3, 4]),
    ]),
  ),
  _Spec(
    'Cool Down (1–2)',
    'blue',
    _all([
      _c('energy', 'between', [1, 2]),
    ]),
  ),
];

(String, List<_Spec>)? _build(String id, String? genre) {
  switch (id) {
    case 'genres':
      return (
        'Genres',
        [
          for (final g in templateGenres)
            _Spec(g, null, _all([_c('genre', 'contains', g)])),
          _Spec(
            'Throwbacks (pre-2010)',
            'purple',
            _all([_c('year', 'lt', 2010)]),
          ),
          _Spec('Open Format', null, null),
        ],
      );
    case 'energy':
      return ('Energy', _energy());
    case 'utility':
      return (
        'Utility',
        [
          _Spec('Openers', 'green', _all([_c('tag', 'has', 'opener')])),
          _Spec('Closers', 'blue', _all([_c('tag', 'has', 'closer')])),
          _Spec(
            'Bangers',
            'red',
            _any([_c('tag', 'has', 'banger'), _c('rating', 'eq', 5)]),
          ),
          _Spec('Vocals', null, _all([_c('tag', 'has', 'vocal')])),
          _Spec(
            'Acapellas',
            'purple',
            _all([_c('version', 'contains', 'acapella')]),
          ),
          _Spec(
            'Instrumentals',
            'purple',
            _all([_c('version', 'contains', 'instrumental')]),
          ),
          _Spec('Edits', null, _all([_c('version', 'contains', 'edit')])),
          _Spec('Mashups', null, _all([_c('version', 'contains', 'mashup')])),
          _Spec(
            'Transitions / FX',
            null,
            _all([_c('tag', 'has', 'transition')]),
          ),
          _Spec(
            'Clean Edits',
            null,
            _all([_c('clean_explicit', 'equals', 'clean')]),
          ),
        ],
      );
    case 'events':
      return ('Events', [for (final e in templateEvents) _Spec(e, null, null)]);
    case 'ratings':
      return (
        'Ratings',
        [
          _Spec('★★★★★ Guaranteed', 'red', _all([_c('rating', 'eq', 5)])),
          _Spec('★★★★ Reliable', 'orange', _all([_c('rating', 'eq', 4)])),
          _Spec('★★★ Good', 'yellow', _all([_c('rating', 'eq', 3)])),
          _Spec('★★ Rarely played', 'blue', _all([_c('rating', 'eq', 2)])),
          _Spec('★ Archive', 'grey', _all([_c('rating', 'eq', 1)])),
        ],
      );
    case 'decades':
      return (
        'Decades',
        [
          for (final d in [1970, 1980, 1990, 2000, 2010, 2020])
            _Spec('${d}s', null, _all([_c('decade', 'eq', d)])),
        ],
      );
    case 'genre_by_energy':
      final g = genre?.trim() ?? '';
      if (g.isEmpty) return null;
      final gr = _c('genre', 'contains', g);
      return (
        g,
        [
          _Spec(
            'Warm Up',
            'green',
            _all([
              gr,
              _c('energy', 'between', [1, 4]),
            ]),
          ),
          _Spec(
            'Mid Energy',
            'yellow',
            _all([
              gr,
              _c('energy', 'between', [5, 6]),
            ]),
          ),
          _Spec(
            'Peak Time',
            'red',
            _all([
              gr,
              _c('energy', 'between', [7, 10]),
            ]),
          ),
          _Spec('Closers', 'blue', _all([gr, _c('tag', 'has', 'closer')])),
          _Spec(
            'Tools',
            'purple',
            _any([
              _c('tag', 'has', 'tool'),
              _c('version', 'contains', 'acapella'),
              _c('version', 'contains', 'instrumental'),
            ]),
          ),
        ],
      );
  }
  return null;
}

class CrateTemplate {
  CrateTemplate(
    this.id,
    this.name,
    this.description,
    this.crates,
    this.needsGenre,
  );
  final String id, name, description;
  final List<String> crates;
  final bool needsGenre;
}

List<CrateTemplate> crateTemplates() {
  CrateTemplate t(String id, String name, String desc, bool needsGenre) =>
      CrateTemplate(id, name, desc, [
        for (final s in _build(id, 'House')?.$2 ?? <_Spec>[]) s.name,
      ], needsGenre);
  return [
    t(
      'genres',
      'Organise by genre',
      'Main genre crates (smart: genre contains…), plus Throwbacks and Open Format.',
      false,
    ),
    t(
      'energy',
      'Sort by energy',
      'Peak Time 9–10, High 7–8, Mid 5–6, Warm Up 3–4, Cool Down 1–2. Uses your energy, or the analysis estimate.',
      false,
    ),
    t(
      'utility',
      'Utility crates',
      'Openers, Closers, Bangers, Vocals, Acapellas, Instrumentals, Edits, Mashups, Transitions/FX, Clean Edits.',
      false,
    ),
    t(
      'events',
      'Event crates',
      'Club, Festival, Wedding, Corporate, Private Party, Birthday, Latin Night, House Party, Lounge/Chill (manual).',
      false,
    ),
    t(
      'ratings',
      'Rate your tracks',
      'Guaranteed (5★), Reliable (4★), Good (3★), Rarely played (2★), Archive (1★).',
      false,
    ),
    t('decades', 'Decades', '1970s through 2020s.', false),
    t(
      'genre_by_energy',
      'Genre folder by energy',
      'Example folder structure: <Genre> → Warm Up, Mid Energy, Peak Time, Closers, Tools.',
      true,
    ),
  ];
}

const _defaultLabels = {
  'energy': [
    {
      'min': 9,
      'max': 10,
      'label': 'Peak time',
      'hint': 'High energy, main stage bangers',
    },
    {
      'min': 7,
      'max': 8,
      'label': 'High energy',
      'hint': 'Uplifting, driving and powerful',
    },
    {
      'min': 5,
      'max': 6,
      'label': 'Mid energy',
      'hint': 'Groove, vibe, steady moments',
    },
    {
      'min': 3,
      'max': 4,
      'label': 'Warm up',
      'hint': 'Build the vibe, early set',
    },
    {
      'min': 1,
      'max': 2,
      'label': 'Cool down',
      'hint': 'Chill, deep, end of night',
    },
  ],
  'rating': {
    '5': 'Guaranteed',
    '4': 'Reliable',
    '3': 'Good',
    '2': 'Rarely played',
    '1': 'Archive',
  },
  'rating_hint': {
    '5': 'Crowd reaction every time',
    '4': 'Works in most sets',
    '3': 'Solid tracks / fillers',
    '2': 'Use situationally',
    '1': 'Keep or delete',
  },
  'color': {
    'red': 'Peak time',
    'orange': 'High energy',
    'yellow': 'Mid energy',
    'green': 'Warm up',
    'blue': 'Cool down',
    'purple': 'Special / unique',
    'teal': '',
    'pink': '',
    'grey': '',
  },
  'tag_presets': [
    'Opener',
    'Closer',
    'Banger',
    'Vocal',
    'Instrumental',
    'Acapella',
    'Transition',
    'Tool',
    'Wedding',
    'Throwback',
    'Sing-along',
    'Long intro',
    'Short intro',
  ],
};

String colorForEnergy(int e) => e >= 9
    ? 'red'
    : e >= 7
    ? 'orange'
    : e >= 5
    ? 'yellow'
    : e >= 3
    ? 'green'
    : 'blue';

class TemplatesService {
  TemplatesService(this.cat);
  final Catalogue cat;

  /// Creates a template's crates under a parent crate; existing ones are kept.
  Map<String, Object?> apply(String id, {String? genre}) {
    final b =
        _build(id, genre) ??
        (throw TemplateException('unknown template, or a genre is needed'));
    final (parentName, specs) = b;
    int? find(String name, int? parent) {
      final r = cat.db.select(
        'SELECT id FROM crates WHERE name=? AND parent_id IS ?',
        [name, parent],
      );
      return r.isEmpty ? null : r.first['id'] as int;
    }

    final crates = CratesService(cat);
    final parent =
        find(parentName, null) ??
        crates.create(CrateInput(name: parentName, kind: 'manual')).id;
    var created = 0, skipped = 0;
    for (final s in specs) {
      if (find(s.name, parent) != null) {
        skipped++;
        continue;
      }
      crates.create(
        CrateInput(
          name: s.name,
          kind: s.rules == null ? 'manual' : 'smart',
          color: s.color,
          parentId: parent,
          rules: s.rules,
        ),
      );
      created++;
    }
    return {
      'parent_id': parent,
      'parent': parentName,
      'created': created,
      'skipped': skipped,
    };
  }

  Map<String, Object?> labels() {
    final out = Map<String, Object?>.of(_defaultLabels);
    final over = cat.getSetting('labels_json');
    if (over != null) {
      try {
        out.addAll((jsonDecode(over) as Map).cast<String, Object?>());
      } on FormatException {
        // keep the defaults
      }
    }
    return out;
  }

  void setLabels(Map<String, Object?> v) {
    final s = jsonEncode(v);
    if (s.length > 20000) throw TemplateException('labels must be an object');
    cat.setSetting('labels_json', s);
  }

  /// Sets each track's colour from its (catalogue or estimated) energy.
  int colourByEnergy({bool onlyUncoloured = true}) {
    final lib = LibraryService(cat);
    var n = 0;
    for (final r in cat.db.select(
      'SELECT t.id, COALESCE(u.energy, a.energy) AS e FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
      "LEFT JOIN analysis a ON a.track_id=t.id WHERE t.presence='present' AND COALESCE(u.energy, a.energy) IS NOT NULL "
      'AND (? = 0 OR u.color IS NULL)',
      [onlyUncoloured ? 1 : 0],
    )) {
      n += lib
          .updateUserFields(
            [r['id'] as int],
            {'color': colorForEnergy(r['e'] as int)},
          )
          .clamp(0, 1);
    }
    return n;
  }

  /// "Avoid this": vague crate names, huge unfiltered crates, untagged tracks.
  Map<String, Object?> hygiene() {
    const vague = [
      'new music',
      'random',
      'misc',
      'miscellaneous',
      'house stuff',
      'stuff',
      'untitled',
      'temp',
      'test',
    ];
    final issues = <Map<String, Object?>>[];
    for (final c in CratesService(cat).list()) {
      if (vague.contains(fold(c.name.trim()))) {
        issues.add({
          'crate_id': c.id,
          'crate': c.name,
          'issue': 'Vague name',
          'advice': 'Unorganised crates mean missed moments. Rename it by genre, energy, event or role.',
        });
      }
      if (c.kind == 'manual' && c.trackCount > 300) {
        issues.add({
          'crate_id': c.id,
          'crate': c.name,
          'issue': '${c.trackCount} tracks',
          'advice': 'Huge crates with hundreds of unfiltered tracks are hard to play from. Split it by energy or sub-genre.',
        });
      }
    }
    final untagged = cat.db
        .select(
          "SELECT COUNT(*) AS n FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.presence='present' AND t.read_status='ok' "
          'AND u.rating IS NULL AND NOT EXISTS (SELECT 1 FROM track_tags tt WHERE tt.track_id=t.id)',
        )
        .first['n'];
    return {'issues': issues, 'untagged_unrated': untagged};
  }
}
