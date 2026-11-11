import 'dart:convert';

import '../app/session.dart';
import '../core/crates.dart';
import '../core/duplicates.dart' show dupDecisions;
import '../core/limits.dart';
import '../core/json.dart';
import '../core/keys.dart';
import '../core/library.dart';
import '../core/library_edit.dart';
import '../core/rule_fields.g.dart';
import '../core/rules.dart';
import '../core/templates.dart';
import '../online/online.dart';
import 'ai_config.dart';
import 'guide.g.dart';

/// The AI assistant (1.x `agent.rs`): a language model that knows the app
/// (its guide is the system prompt) and works through the app's own services.
///
/// Every tool has a tier:
/// * read: looks things up, runs automatically;
/// * ui: changes only what is on screen, applied by the front end;
/// * act: changes the catalogue or starts work. It never runs on the model's
///   say-so: the DJ sees an action card and presses Run.
///
/// No tool can write, move, rename or delete music files, or touch Serato data,
/// and tool results never include file paths.
enum Tier { read, ui, act }

const maxResultChars = 24000;

class AgentException implements Exception {
  AgentException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef Json = Map<String, Object?>;

class ToolDef {
  const ToolDef(this.name, this.tier, this.description, this.schema);
  final String name, description;
  final Tier tier;
  final Json Function() schema;
}

Json _obj([Json props = const {}, List<String>? required]) => {
  'type': 'object',
  'properties': props,
  'required': ?required,
};

Json _rules() => {
  'type': 'object',
  'description': 'A rule set: {"match": "all"|"any", "rules": [{"kind": "condition", "field", "op", "value"} | {"kind": "group", "match", "rules"}]}. See list_rule_fields.',
  'properties': {
    'match': {
      'type': 'string',
      'enum': ['all', 'any'],
    },
    'rules': {
      'type': 'array',
      'items': {'type': 'object'},
    },
  },
  'required': ['match', 'rules'],
};

Json _ids(String desc) => {
  'type': 'array',
  'items': {'type': 'integer'},
  'description': desc,
};

Json _int([int? min, int? max]) => {
  'type': 'integer',
  'minimum': ?min,
  'maximum': ?max,
};

const _str = {'type': 'string'};

Json _setParams() => _obj(
  {
    'name': _str,
    'duration_min': _int(1),
    'event_type': {
      'type': 'string',
      'description': 'e.g. wedding, club, corporate, birthday, lounge',
    },
    'audience': _str,
    'genres': {'type': 'array', 'items': _str},
    'curve': {
      'type': 'string',
      'enum': ['journey', 'warmup', 'peak', 'wedding', 'lounge', 'custom'],
    },
    'custom_curve': {
      'type': 'array',
      'items': {'type': 'number'},
      'description': 'Energy points 1–10 for a custom curve.',
    },
    'clean_only': {'type': 'boolean'},
    'bpm_min': {'type': 'number'},
    'bpm_max': {'type': 'number'},
    'must_play': _ids('Track ids that must be in the set.'),
    'exclude': _ids('Track ids to leave out.'),
  },
  ['duration_min'],
);

final List<ToolDef> tools = [
  ToolDef(
    'library_overview',
    Tier.read,
    'Counts for the whole library (tracks, videos, lossless, low bitrate, missing, offline, errors, folders, total duration) plus the top genres and decades.',
    _obj,
  ),
  ToolDef(
    'search_tracks',
    Tier.read,
    'Find tracks in the catalogue by free text and/or a rule set. Returns the total and up to `limit` compact rows (id, artist, title, genre, year, bpm, key, energy, rating, version, quality, format, media, duration). Use the ids in other tools.',
    () => _obj({
      'text': {
        'type': 'string',
        'description': 'Free text matched against title, artist, album, genre, label, file name and tags (accent-insensitive).',
      },
      'filters': _rules(),
      'sort': {
        'type': 'string',
        'enum': [
          'title',
          'artist',
          'album',
          'genre',
          'year',
          'bpm',
          'key',
          'energy',
          'rating',
          'duration',
          'added',
          'plays',
        ],
      },
      'desc': {'type': 'boolean'},
      'limit': _int(1),
    }),
  ),
  ToolDef(
    'get_track',
    Tier.read,
    'Full details for one track: catalogue values, original file tags, analysis (BPM, key, energy, loudness, intro/outro, cue ideas), crates it is in and play count.',
    () => _obj({'id': _int()}, ['id']),
  ),
  ToolDef(
    'list_rule_fields',
    Tier.read,
    'Every field usable in filters and smart crates, with its type.',
    _obj,
  ),
  ToolDef(
    'facet_values',
    Tier.read,
    'Distinct values with counts for a field, to see what genres, keys, formats, moods, labels, decades or versions exist.',
    () => _obj(
      {
        'field': {
          'type': 'string',
          'enum': [
            'genre',
            'artist',
            'format',
            'key',
            'mood',
            'label',
            'decade',
            'version',
          ],
        },
      },
      ['field'],
    ),
  ),
  ToolDef(
    'list_crates',
    Tier.read,
    'All crates (id, name, kind manual/smart, parent folder, colour, track count, rules).',
    _obj,
  ),
  ToolDef(
    'crate_tracks',
    Tier.read,
    'Tracks in one crate (compact rows).',
    () => _obj({'crate_id': _int(), 'limit': _int(1)}, ['crate_id']),
  ),
  ToolDef(
    'crate_templates',
    Tier.read,
    'Crate templates from the Crate & Playlist Cheat Sheet (id, name, what crates they create).',
    _obj,
  ),
  ToolDef(
    'library_health',
    Tier.read,
    'Library Health cards with counts (missing metadata, low bitrate, unreadable, unsupported, offline, missing files) and the last scan.',
    _obj,
  ),
  ToolDef(
    'duplicates_summary',
    Tier.read,
    'Duplicate groups (exact / possible / alternate versions) with their tracks and reasons. Exact groups need a full-file hash run first.',
    () => _obj({'limit': _int(1)}),
  ),
  ToolDef(
    'suggestions_summary',
    Tier.read,
    'Pending metadata suggestions (field, current value, suggested value, source, confidence).',
    () => _obj({'limit': _int(1)}),
  ),
  ToolDef(
    'jobs_status',
    Tier.read,
    'Scan, analysis and other background jobs with progress, plus analysis coverage.',
    _obj,
  ),
  ToolDef(
    'crate_fit',
    Tier.read,
    'Library tracks that would fit a crate but are not in it, with reasons.',
    () => _obj({'crate_id': _int()}, ['crate_id']),
  ),
  ToolDef('list_sets', Tier.read, 'Saved sets from Set Studio.', _obj),
  ToolDef(
    'preview_set',
    Tier.read,
    'Build a set plan without saving it: running order with transition notes. Use it to discuss options; open_view set-studio with params to let the DJ edit it, or save_set to keep it.',
    _setParams,
  ),
  ToolDef(
    'gig_status',
    Tier.read,
    'The current gig (if gig mode is on): set list position, requests, notes.',
    _obj,
  ),
  ToolDef(
    'get_settings',
    Tier.read,
    'Current app settings (theme, key notation, premium UI, video scanning, low-bitrate threshold, online services, gig mode…).',
    _obj,
  ),
  ToolDef(
    'show_tracks',
    Tier.ui,
    'Show tracks in the Library view with these filters/text applied (the DJ sees them immediately and can edit the filters).',
    () => _obj({
      'text': _str,
      'filters': _rules(),
      'label': {
        'type': 'string',
        'description': 'Short description of what is shown.',
      },
    }),
  ),
  ToolDef(
    'open_view',
    Tier.ui,
    'Open a screen in the app. For set-studio you can pre-fill set parameters; for crate you need crate_id; for health-fix you need category (missing_core, missing_genre, missing_year, missing_album, missing_bpm, missing_key).',
    () => _obj(
      {
        'view': {
          'type': 'string',
          'enum': [
            'library',
            'crates',
            'crate',
            'duplicates',
            'activity',
            'health',
            'health-fix',
            'set-studio',
            'discovery',
            'suggestions',
            'gig',
            'gig-pack',
            'settings',
            'quick',
            'organize',
            'files',
            'upgrades',
          ],
        },
        'crate_id': _int(),
        'category': _str,
        'set_params': {'type': 'object'},
      },
      ['view'],
    ),
  ),
  ToolDef(
    'create_crate',
    Tier.act,
    "Create a crate. kind 'smart' needs rules (it updates itself); kind 'manual' can be filled with track_ids. Optional parent_id puts it in a folder crate; color is one of red, orange, yellow, green, teal, blue, purple, pink, grey.",
    () => _obj(
      {
        'name': _str,
        'kind': {
          'type': 'string',
          'enum': ['manual', 'smart', 'folder'],
        },
        'rules': _rules(),
        'track_ids': _ids('For manual crates: tracks to add.'),
        'parent_id': _int(),
        'color': _str,
      },
      ['name', 'kind'],
    ),
  ),
  ToolDef(
    'add_to_crate',
    Tier.act,
    'Add tracks to an existing manual crate (by ids, or every track matching filters).',
    () => _obj(
      {
        'crate_id': _int(),
        'track_ids': _ids('Tracks to add.'),
        'filters': _rules(),
      },
      ['crate_id'],
    ),
  ),
  ToolDef(
    'remove_from_crate',
    Tier.act,
    'Remove tracks from a crate (files are untouched).',
    () => _obj(
      {'crate_id': _int(), 'track_ids': _ids('Tracks to remove.')},
      ['crate_id', 'track_ids'],
    ),
  ),
  ToolDef(
    'apply_crate_template',
    Tier.act,
    'Create the crates of a cheat-sheet template (see crate_templates). Some templates need a genre.',
    () => _obj({'template_id': _str, 'genre': _str}, ['template_id']),
  ),
  ToolDef(
    'update_tracks',
    Tier.act,
    "Set catalogue values on tracks (DJ Assistant only — never written to the files). Use null to clear a value. energy 1–10, rating 0–5, key in Camelot or musical notation, color one of the crate colours, clean_explicit 'clean'|'explicit'.",
    () => _obj(
      {
        'track_ids': _ids('Tracks to change.'),
        'values': _obj({
          for (final k in [
            'title',
            'artist',
            'album',
            'genre',
            'year',
            'original_year',
            'record_label',
            'bpm',
            'key',
            'energy',
            'rating',
            'mood',
            'color',
            'notes',
            'version_label',
            'clean_explicit',
          ])
            k: <String, Object?>{},
        }),
      },
      ['track_ids', 'values'],
    ),
  ),
  ToolDef(
    'tag_tracks',
    Tier.act,
    "Add and/or remove catalogue tags (e.g. 'opener', 'sing-along') on tracks.",
    () => _obj(
      {
        'track_ids': _ids('Tracks to tag.'),
        'add': {'type': 'array', 'items': _str},
        'remove': {'type': 'array', 'items': _str},
      },
      ['track_ids'],
    ),
  ),
  ToolDef(
    'start_scan',
    Tier.act,
    'Scan all music folders for new and changed files (read-only).',
    _obj,
  ),
  ToolDef(
    'start_analysis',
    Tier.act,
    'Analyse audio in the background (BPM, key, energy, loudness, intro/outro, cue ideas) for the given tracks, or for every track not analysed yet.',
    () => _obj({
      'track_ids': _ids('Optional: only these tracks.'),
      'redo': {
        'type': 'boolean',
        'description': 'Re-analyse tracks that already have results.',
      },
    }),
  ),
  ToolDef(
    'find_local_suggestions',
    Tier.act,
    "Generate metadata suggestions from file names, folder names and consistent spellings (they still need the DJ's review).",
    _obj,
  ),
  ToolDef(
    'save_set',
    Tier.act,
    'Plan and save a set in Set Studio with these parameters.',
    _setParams,
  ),
  ToolDef(
    'start_gig_mode',
    Tier.act,
    'Start gig mode (pauses background work), optionally with a saved set.',
    () => _obj({'name': _str, 'set_id': _int()}),
  ),
  ToolDef(
    'end_gig_mode',
    Tier.act,
    'End the current gig and produce the recap.',
    _obj,
  ),
  // ---- every feature: suggestions, auto-prep, lookups, duplicates,
  // discovery, limits, Studio, and every page
  ToolDef(
    'list_suggestions',
    Tier.read,
    'Metadata suggestions (pending, accepted or rejected) with their evidence and confidence.',
    () => _obj({
      'status': {
        'type': 'string',
        'enum': ['pending', 'accepted', 'rejected'],
      },
      'track_id': _int(),
      'limit': _int(1),
    }),
  ),
  ToolDef(
    'duplicate_groups',
    Tier.read,
    'Exact duplicates (same file contents), possible duplicates and alternate versions, with the decision the DJ made for each group.',
    _obj,
  ),
  ToolDef(
    'discovery_items',
    Tier.read,
    'Recommendations and new releases on the Discovery page, and the artists the DJ follows.',
    _obj,
  ),
  ToolDef(
    'get_limits',
    Tier.read,
    'Every limit in Settings → Limits and batch sizes (null means no limit).',
    _obj,
  ),
  ToolDef(
    'run_auto_prep',
    Tier.act,
    'Run auto-prep: analysis, suggestions from names and folders, online lookups for services that are on, then the confident fixes (catalogue only).',
    _obj,
  ),
  ToolDef(
    'decide_suggestions',
    Tier.act,
    'Accept or reject suggestions by id (accepting writes the value to the catalogue only, never to files).',
    () => _obj({
      'accept': _ids('Suggestion ids to accept.'),
      'reject': _ids('Suggestion ids to reject.'),
    }),
  ),
  ToolDef(
    'accept_confident_suggestions',
    Tier.act,
    'Accept every pending suggestion at or above a confidence (0–1), optionally from one source.',
    () => _obj(
      {
        'min_confidence': {'type': 'number'},
        'source': _str,
      },
      ['min_confidence'],
    ),
  ),
  ToolDef(
    'online_lookup',
    Tier.act,
    'Look tracks up online: musicbrainz (year, genre, album) or catalogs (BPM, key, credits from the catalogues the DJ turned on). Only for services that are on. Without track_ids, the whole library.',
    () => _obj(
      {
        'service': {
          'type': 'string',
          'enum': ['musicbrainz', 'catalogs'],
        },
        'track_ids': _ids('Tracks to look up (default: all).'),
      },
      ['service'],
    ),
  ),
  ToolDef(
    'find_exact_duplicates',
    Tier.act,
    'Compare file contents (full-file hash, read-only) to confirm exact duplicates, in the background.',
    _obj,
  ),
  ToolDef(
    'decide_duplicates',
    Tier.act,
    'Record the DJ\'s decision for a duplicate group: ${dupDecisions.join(', ')}, or null to clear it. Nothing is deleted.',
    () => _obj(
      {
        'group_key': _str,
        'decision': {
          'type': ['string', 'null'],
          'enum': [...dupDecisions, null],
        },
      },
      ['group_key'],
    ),
  ),
  ToolDef(
    'follow_artist',
    Tier.act,
    'Follow an artist on the Discovery page (new releases are checked when MusicBrainz is on).',
    () => _obj({'name': _str}, ['name']),
  ),
  ToolDef(
    'match_tracklist',
    Tier.read,
    'Match a pasted tracklist ("Artist - Title" per line) against the library: owned, missing, unknown.',
    () => _obj({'text': _str}, ['text']),
  ),
  ToolDef(
    'set_limit',
    Tier.act,
    'Set or remove a limit in Settings → Limits and batch sizes (value null removes it). See get_limits for the names.',
    () => _obj(
      {
        'limit': {
          'type': 'string',
          'enum': [for (final d in limitDefs) d.key],
        },
        'value': <String, Object?>{},
      },
      ['limit'],
    ),
  ),
  ToolDef(
    'open_studio',
    Tier.ui,
    'Open a Studio page. With track_id: stems splits that song (method fast or ai), remix selects it, dj loads it on a free deck.',
    () => _obj(
      {
        'page': {
          'type': 'string',
          'enum': ['stems', 'remix', 'dj', 'synth', 'drums'],
        },
        'track_id': _int(),
        'method': {
          'type': 'string',
          'enum': ['fast', 'ai'],
        },
      },
      ['page'],
    ),
  ),
  ToolDef(
    'change_setting',
    Tier.act,
    'Change an app preference: theme (dark|light), key_notation (camelot|musical), premium_ui (true|false), motion (full|reduced), accent (mint|cyan|violet|amber|rose), surface (glass|solid), scan_video (true|false), low_bitrate_kbps (number), ai_gpu (true|false: Pro Stems AI on the graphics card), studio_cores (number, 0 = automatic), audio_buffer_ms (number).',
    () => _obj(
      {
        'setting': {'type': 'string', 'enum': _assistantSettings},
        'value': <String, Object?>{},
      },
      ['setting', 'value'],
    ),
  ),
];

const _assistantSettings = [
  'theme',
  'key_notation',
  'premium_ui',
  'motion',
  'accent',
  'surface',
  'scan_video',
  'low_bitrate_kbps',
  'ai_gpu',
  'studio_cores',
  'audio_buffer_ms',
];

Tier? tierOf(String name) =>
    tools.where((t) => t.name == name).firstOrNull?.tier;

/// Tool definitions in the Messages API format (stable order, so the prompt
/// cache holds).
List<Json> toolSpecs() => [
  for (final t in tools)
    {
      'name': t.name,
      'description': t.tier == Tier.act
          ? "${t.description} [Needs the DJ's approval: shown as an action card.]"
          : t.description,
      'input_schema': {'properties': <String, Object?>{}, ...t.schema()},
    },
];

// ------------------------------------------------------------------ helpers

Json compactRow(Json r) {
  final o = <String, Object?>{};
  for (final k in [
    'id',
    'artist',
    'title',
    'album',
    'genre',
    'year',
    'bpm',
    'key',
    'energy',
    'rating',
    'version',
    'clean_explicit',
    'quality',
    'format',
    'media_kind',
    'height',
    'tags',
    'status',
  ]) {
    final v = r[k];
    if (v == null) continue;
    if (k == 'tags' && (v is! List || v.isEmpty)) continue;
    if (k == 'media_kind' && v == 'audio') continue;
    if (k == 'status' && v == 'ok') continue;
    o[k] = v;
  }
  if (r['duration_ms'] case final int ms) {
    o['duration'] =
        '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';
  }
  if (o['title'] == null && r['file_name'] != null) {
    o['file_name'] = r['file_name'];
  }
  return o;
}

const _pathKeys = {
  'path',
  'rel_path',
  'root',
  'root_path',
  'db_path',
  'folder',
  'dest',
  'source_path',
  'backup_path',
};

/// Windows ("C:\Music\…", "\\server\…") or Unix-style absolute paths.
bool looksLikePath(String s) =>
    (s.length > 3 && s[1] == ':' && (s[2] == r'\' || s[2] == '/')) ||
    s.startsWith(r'\\') ||
    (s.startsWith('/') && '/'.allMatches(s).length > 2);

/// Removes anything that looks like a file path before it reaches the model.
Object? stripPaths(Object? v) => switch (v) {
  final Map m => {
    for (final e in m.entries)
      if (!_pathKeys.contains(e.key)) '${e.key}': stripPaths(e.value),
  },
  final List l => [for (final x in l) stripPaths(x)],
  final String s when looksLikePath(s) => '[path hidden]',
  _ => v,
};

/// Converts service results (models, records) to plain JSON values.
Object? plain(Object? v) => switch (v) {
  null || String() || num() || bool() => v,
  final TrackRow r => r.toJson(),
  final Map m => {for (final e in m.entries) '${e.key}': plain(e.value)},
  final Iterable l => [for (final x in l) plain(x)],
  final (Object?, Object?) r => [plain(r.$1), plain(r.$2)],
  _ => _model(v),
};

Object? _model(Object v) {
  try {
    return plain((v as dynamic).toJson());
  } on NoSuchMethodError {
    return '$v';
  }
}

List<int> _idList(Json v, String k) => [
  for (final x in v[k] is List ? v[k]! as List : const [])
    ?(x is num ? x.toInt() : null),
];
int? _intOf(Object? v) => v is num ? v.toInt() : null;
String _s(Json v, String k) => v[k] is String ? v[k]! as String : '';

Json _setInput(Json input) => {
  for (final e in input.entries)
    if (e.value != null) e.key: e.value,
};

String _plural(int n) => n == 1 ? '' : 's';

String _bare(Object? v) => (jsonEncode(v)).replaceAll(RegExp(r'^"|"$'), '');

/// The assistant over one app session.
class Agent {
  Agent(this.app);
  final AppSession app;
  final _conversations = <String, Conversation>{};

  Map<String, Object?>? _rulesOf(Json input) => input['rules'] is Map
      ? Map<String, Object?>.from(input['rules']! as Map)
      : null;

  TrackPage _search({
    String? text,
    Object? filters,
    String? sort,
    bool desc = false,
    int limit = 25,
    (String, List<Object?>)? where,
  }) => app.library.search(
    TrackQuery(
      text: text,
      sort: sort,
      desc: desc,
      limit: limit,
      extraWhere:
          where ??
          (filters is Map
              ? compileRules(
                  Map<String, Object?>.from(filters),
                  app.library.lowBitrateKbps,
                )
              : null),
    ),
  );

  /// A one-line human description of an act tool call for its action card.
  String describe(String name, Json input) {
    int n(String k) => _idList(input, k).length;
    String crateName(int? id) {
      final c = id == null
          ? null
          : app.crates.list().where((c) => c.id == id).firstOrNull;
      return c == null ? 'the crate' : '“${c.name}”';
    }

    switch (name) {
      case 'create_crate':
        final kind = _s(input, 'kind');
        var extra = '';
        if (kind == 'smart') {
          final r = _rulesOf(input);
          if (r != null) {
            try {
              final t = _search(filters: r, limit: 1).total;
              extra = ' — $t track${_plural(t)} match now';
            } on Exception {
              extra = '';
            }
          }
        } else if (n('track_ids') > 0) {
          extra = ' with ${n('track_ids')} track${_plural(n('track_ids'))}';
        }
        return 'Create $kind crate “${_s(input, 'name')}”$extra';
      case 'add_to_crate':
        final what = n('track_ids') > 0
            ? '${n('track_ids')} track${_plural(n('track_ids'))}'
            : 'the matching tracks';
        return 'Add $what to ${crateName(_intOf(input['crate_id']))}';
      case 'remove_from_crate':
        return 'Remove ${n('track_ids')} track(s) from ${crateName(_intOf(input['crate_id']))} (files untouched)';
      case 'apply_crate_template':
        final g = _s(input, 'genre');
        return 'Create the crates of template “${_s(input, 'template_id')}”${g.isEmpty ? '' : ' for $g'}';
      case 'update_tracks':
        final vals = input['values'] is Map
            ? (input['values']! as Map).entries
                  .map(
                    (e) =>
                        '${e.key} → ${e.value == null ? 'cleared' : _bare(e.value)}',
                  )
                  .join(', ')
            : '';
        return 'Set $vals on ${n('track_ids')} track${_plural(n('track_ids'))} (catalogue only)';
      case 'tag_tracks':
        final add = input['add'] == null ? '' : jsonEncode(input['add']);
        final rem = input['remove'] == null ? '' : jsonEncode(input['remove']);
        return 'Tags on ${n('track_ids')} track(s): ${add.isEmpty ? '' : 'add $add '}${rem.isEmpty ? '' : 'remove $rem'}';
      case 'start_scan':
        return 'Scan your music folders (read-only)';
      case 'start_analysis':
        return n('track_ids') > 0
            ? 'Analyse ${n('track_ids')} track(s) in the background'
            : "Analyse all tracks that aren't analysed yet";
      case 'find_local_suggestions':
        return 'Look for metadata suggestions in file and folder names';
      case 'save_set':
        final nm = _s(input, 'name');
        return 'Plan and save a ${_intOf(input['duration_min']) ?? 60}-minute set${nm.isEmpty ? '' : ' “$nm”'}';
      case 'start_gig_mode':
        final nm = _s(input, 'name');
        return 'Start gig mode${nm.isEmpty ? '' : ' “$nm”'} (background work pauses)';
      case 'end_gig_mode':
        return 'End the gig and make the recap';
      case 'change_setting':
        return 'Change ${_s(input, 'setting')} to ${input['value'] == null ? '' : _bare(input['value'])}';
      case 'run_auto_prep':
        return 'Run auto-prep (catalogue only; online steps only for services that are on)';
      case 'decide_suggestions':
        return 'Accept ${n('accept')} and reject ${n('reject')} suggestion(s) (catalogue only)';
      case 'accept_confident_suggestions':
        return 'Accept every pending suggestion with confidence ≥ ${input['min_confidence']}${_s(input, 'source').isEmpty ? '' : ' from ${_s(input, 'source')}'}';
      case 'online_lookup':
        final t = n('track_ids');
        return 'Look up ${t == 0 ? 'the whole library' : '$t track(s)'} on ${_s(input, 'service') == 'musicbrainz' ? 'MusicBrainz' : 'the online catalogues'}';
      case 'find_exact_duplicates':
        return 'Compare file contents to find exact duplicates (read-only)';
      case 'decide_duplicates':
        return 'Mark a duplicate group as ${input['decision'] == null ? 'undecided' : _bare(input['decision'])} (nothing is deleted)';
      case 'follow_artist':
        return 'Follow ${_s(input, 'name')} on Discovery';
      case 'set_limit':
        return input['value'] == null
            ? 'Remove the limit ${_s(input, 'limit')}'
            : 'Set the limit ${_s(input, 'limit')} to ${_bare(input['value'])}';
    }
    return name.replaceAll('_', ' ');
  }

  /// Runs one tool. ui tools return a confirmation; the front end applies them.
  Object? runTool(String name, Json input) {
    // a default page size; the assistant can ask for as many as it needs
    int lim(int d) =>
        (_intOf(input['limit']) ?? d) < 1 ? 1 : (_intOf(input['limit']) ?? d);
    switch (name) {
      case 'library_overview':
        final videos = _search(
          filters: {
            'match': 'all',
            'rules': [
              {
                'kind': 'condition',
                'field': 'media',
                'op': 'equals',
                'value': 'video',
              },
            ],
          },
          limit: 1,
        ).total;
        return {
          'stats': app.library.stats(),
          'videos': videos,
          'crates': app.crates.list().length,
          'top_genres': plain(app.library.facet('genre').take(15)),
          'decades': plain(app.library.facet('decade').take(10)),
        };
      case 'search_tracks':
        final page = _search(
          text: input['text'] as String?,
          filters: input['filters'],
          sort: input['sort'] as String?,
          desc: input['desc'] == true,
          limit: lim(25),
        );
        final rows = [for (final r in page.rows) compactRow(r.toJson())];
        return {'total': page.total, 'shown': rows.length, 'tracks': rows};
      case 'get_track':
        final id = _intOf(input['id']);
        if (id == null) throw AgentException('give the track id');
        final d = plain(app.library.trackDetail(id))! as Json;
        d.remove('technical');
        if (d['row'] is Map) d['row'] = compactRow(d['row']! as Json);
        if (d['analysis'] is Map) {
          (d['analysis']! as Map)
            ..remove('waveform')
            ..remove('fingerprint')
            ..remove('fingerprint_encoded');
        }
        return d;
      case 'list_rule_fields':
        return [for (final f in ruleFields) f.toJson()];
      case 'facet_values':
        return plain(
          app.library.facet(
            _s(input, 'field').isEmpty ? 'genre' : _s(input, 'field'),
          ),
        );
      case 'list_crates':
        return [for (final c in app.crates.list()) c.toJson()];
      case 'crate_tracks':
        final id = _intOf(input['crate_id']);
        if (id == null) throw AgentException('give the crate id');
        final page = app.crates.tracks(id, limit: lim(50));
        return {
          'total': page.total,
          'tracks': [for (final r in page.rows) compactRow(r.toJson())],
        };
      case 'crate_templates':
        return [for (final t in crateTemplates()) t.toJson()];
      case 'library_health':
        final h = plain(app.health.health())! as Json;
        for (final it in (h['items'] as List?) ?? const []) {
          (it as Map).remove('filters');
        }
        if (h['recent_errors'] case final List e when e.length > 10) {
          h['recent_errors'] = e.take(10).toList();
        }
        return h;
      case 'duplicates_summary':
        final g = app.duplicates.findGroups();
        return {
          'groups': g.length,
          'first': [for (final x in g.take(lim(15))) x.toJson()],
        };
      case 'suggestions_summary':
        final s = app.suggestions.list(status: 'pending');
        return {
          'pending': s.length,
          'first': [for (final x in s.take(lim(30))) x.toJson()],
        };
      case 'jobs_status':
        return {
          'jobs': [for (final j in app.jobs.all()) j.toJson()],
          'scan': app.lastScan?.toJson(),
          'analysis': app.analysis.summary(),
        };
      case 'crate_fit':
        final id = _intOf(input['crate_id']);
        if (id == null) throw AgentException('give the crate id');
        return [for (final r in app.discovery.crateFit(id)) r.toJson()];
      case 'list_sets':
        return app.sets.list();
      case 'preview_set':
        return app.sets.plan(setParamsFromJson(_setInput(input)));
      case 'gig_status':
        return app.gig.current();
      case 'get_settings':
        return app.settings.all()..remove('privacy_acknowledged');
      case 'show_tracks' || 'open_view' || 'open_studio':
        return {'ok': true, 'note': 'The app is now showing it to the DJ.'};

      case 'create_crate':
        final kind = _s(input, 'kind').isEmpty ? 'manual' : _s(input, 'kind');
        final c = app.crates.create(
          CrateInput(
            name: _s(input, 'name'),
            kind: kind,
            color: input['color'] as String?,
            parentId: _intOf(input['parent_id']),
            rules: _rulesOf(input),
          ),
        );
        final tids = _idList(input, 'track_ids');
        if (kind == 'manual' && tids.isNotEmpty) {
          app.crates.addTracks(c.id, tids);
        }
        return app.crates.get(c.id).toJson();
      case 'add_to_crate':
        final cid = _intOf(input['crate_id']);
        if (cid == null) throw AgentException('give the crate id');
        final tids = _idList(input, 'track_ids');
        if (tids.isNotEmpty) return {'added': app.crates.addTracks(cid, tids)};
        if (input['filters'] is Map) {
          final ids = app.library.trackIds(
            TrackQuery(
              extraWhere: compileRules(
                Map<String, Object?>.from(input['filters']! as Map),
                app.library.lowBitrateKbps,
              ),
            ),
          );
          return {'added': app.crates.addTracks(cid, ids)};
        }
        throw AgentException('give track_ids or filters');
      case 'remove_from_crate':
        final cid = _intOf(input['crate_id']);
        if (cid == null) throw AgentException('give the crate id');
        return {
          'removed': app.crates.removeTracks(cid, _idList(input, 'track_ids')),
        };
      case 'apply_crate_template':
        return app.templates.apply(
          _s(input, 'template_id'),
          genre: input['genre'] as String?,
        );
      case 'update_tracks':
        final tids = _idList(input, 'track_ids');
        if (tids.isEmpty) {
          throw AgentException('choose at least one track');
        }
        final patch = input['values'] is Map
            ? Map<String, Object?>.from(input['values']! as Map)
            : <String, Object?>{};
        if (patch['key'] case final String k) {
          patch['key'] = normalizeKey(k) ?? k;
        }
        return {'updated': app.library.updateUserFields(tids, patch)};
      case 'tag_tracks':
        app.library.setTags(
          _idList(input, 'track_ids'),
          add: [for (final x in (input['add'] as List?) ?? const []) '$x'],
          remove: [
            for (final x in (input['remove'] as List?) ?? const []) '$x',
          ],
        );
        return {'ok': true};
      case 'start_scan':
        return app.startScan();
      case 'start_analysis':
        final t = _idList(input, 'track_ids');
        return app.startAnalysis(
          ids: t.isEmpty ? null : t,
          force: input['redo'] == true,
        );
      case 'find_local_suggestions':
        return {'created': app.suggestions.generateLocal()};
      case 'save_set':
        final params = _setInput(input);
        final plan = app.sets.plan(setParamsFromJson(params));
        final nm = input['name'] is String
            ? input['name']! as String
            : '${_intOf(input['duration_min']) ?? 60} min set';
        final id = app.sets.save(nm, plan);
        return {
          'saved': id,
          'name': nm,
          'slots': (plan['slots'] as List?)?.length,
        };
      case 'start_gig_mode':
        final nm = input['name'] is String ? input['name']! as String : 'Gig';
        return {
          'gig_id': app.gig.start(nm, setPlanId: _intOf(input['set_id'])),
        };
      case 'end_gig_mode':
        final id = app.gig.end();
        return {'gig_id': id, 'recap': id == null ? null : app.gig.recap(id)};
      case 'list_suggestions':
        return [
          for (final x in app.suggestions.list(
            status: _s(input, 'status').isEmpty ? null : _s(input, 'status'),
            trackId: _intOf(input['track_id']),
            limit: _intOf(input['limit']),
          ))
            {
              'id': x.id,
              'track_id': x.trackId,
              'track': x.track,
              'field': x.field,
              'current': x.currentValue,
              'suggested': x.suggestedValue,
              'source': x.source,
              'confidence': x.confidence,
              'status': x.status,
            },
        ];
      case 'duplicate_groups':
        return [
          for (final g in app.duplicates.findGroups())
            {
              'kind': g.kind,
              'group_key': g.key,
              'reason': g.reason,
              'decision': g.decision,
              'tracks': [for (final r in g.tracks) compactRow(r.toJson())],
            },
        ];
      case 'discovery_items':
        return {
          'items': app.discovery.items(),
          'followed': app.discovery.followed(),
        };
      case 'get_limits':
        return {
          for (final d in limitDefs)
            d.key: {
              'label': d.label,
              'value': limitOf(app.cat, d.key),
              'unit': d.unit,
            },
        };
      case 'match_tracklist':
        return app.discovery.matchTracklist(_s(input, 'text'));
      case 'run_auto_prep':
        return app.runAutoPrep();
      case 'decide_suggestions':
        final acc = _idList(input, 'accept'), rej = _idList(input, 'reject');
        for (final id in acc) {
          app.suggestions.accept(id);
        }
        for (final id in rej) {
          app.suggestions.reject(id);
        }
        return {'accepted': acc.length, 'rejected': rej.length};
      case 'accept_confident_suggestions':
        final min = (input['min_confidence'] as num?)?.toDouble() ?? 0.9;
        final src = _s(input, 'source');
        return {
          'accepted': app.suggestions.acceptBulk(
            min,
            source: src.isEmpty ? null : src,
          ),
        };
      case 'online_lookup':
        final ids = _idList(input, 'track_ids');
        final all = ids.isEmpty
            ? app.library.trackIds(const TrackQuery())
            : ids;
        return _s(input, 'service') == 'musicbrainz'
            ? app.lookupMusicbrainz(all)
            : app.lookupCatalogs(all);
      case 'find_exact_duplicates':
        return app.startHash();
      case 'decide_duplicates':
        app.duplicates.setDecision(
          _s(input, 'group_key'),
          input['decision'] == null ? null : '${input['decision']}',
        );
        return {'ok': true};
      case 'follow_artist':
        app.discovery.follow('artist', _s(input, 'name'));
        return {'ok': true};
      case 'set_limit':
        final v = input['value'];
        setLimit(
          app.cat,
          _s(input, 'limit'),
          v == null ? null : (v is num ? v.toInt() : int.tryParse('$v')),
        );
        return {'ok': true};
      case 'change_setting':
        final key = _s(input, 'setting');
        if (!_assistantSettings.contains(key)) {
          throw AgentException(
            "that setting can't be changed by the assistant",
          );
        }
        app.settings.set(key, input['value']);
        return {'ok': true};
    }
    throw AgentException("unknown tool '$name'");
  }

  // ------------------------------------------------------- conversation

  LlmConfig config() => llmConfig(app.cat, app.secrets);

  /// Is the assistant ready, which service does it use, what does it send.
  Future<Json> status() async {
    final c = config();
    final svc = aiService(c.provider);
    String? reason;
    var ready = false;
    switch (c.provider) {
      case 'claude':
        ready = c.apiKey != null;
        if (!ready) {
          reason = 'Add your Anthropic API key in Settings → AI assistant.';
        }
      case 'local':
        final probe = await app.online.llmLocalProbe(c.localUrl);
        final has = probe.models.any(
          (m) =>
              m == c.model || m.replaceAll(RegExp(r':latest$'), '') == c.model,
        );
        if (probe.running && has) {
          ready = true;
        } else if (!probe.installed && !probe.running) {
          reason = 'Finish setting up the local model in Settings → AI assistant (install Ollama).';
        } else if (!probe.running) {
          reason = "Ollama isn't running. Start it in Settings → AI assistant.";
        } else {
          reason = 'Download the local model in Settings → AI assistant.';
        }
      case 'custom':
        ready = c.baseUrl.isNotEmpty;
        if (!ready) {
          reason = "Enter your server's address in Settings → AI assistant.";
        }
      case _ when svc != null:
        ready = c.apiKey != null;
        if (!ready) {
          reason =
              'Add the API key for this AI service in Settings → AI assistant.';
        }
      default:
        reason = 'The AI assistant is off. The built-in rule-based assistant answers instead.';
    }
    const what =
        'Your messages to the assistant and the catalogue details its tools look up (titles, artists, genres, ratings and similar) are sent to';
    const never = 'Never audio, file paths or personal documents.';
    final sends = switch (c.provider) {
      'claude' => '$what Anthropic to answer. $never',
      'local' =>
        'Nothing leaves this computer: the model runs locally (Ollama).',
      final p when aiService(p) != null =>
        '$what ${p == 'custom' ? 'the server you entered' : c.label} to answer. $never',
      _ => 'Nothing — the AI assistant is off.',
    };
    return {
      'provider': c.provider,
      'model': c.model,
      'ready': ready,
      'reason': reason,
      'sends': sends,
      'local_url': c.localUrl,
      'has_key': app.secrets.get('anthropic') != null,
      'claude_models': [
        for (final m in claudeModels) {'id': m.$1, 'label': m.$2},
      ],
      'default_local_model': defaultLocalModel,
      'services': [
        for (final s in aiServices)
          {
            'id': s.id,
            'label': s.label,
            'key_url': s.keyUrl,
            'model_hint': s.model,
            'free': freeAiServices.contains(s.id),
            'has_key': app.secrets.get('ai_${s.id}') != null,
          },
      ],
      'custom_url': app.cat.getSetting('ai_custom_url') ?? '',
      'label': c.label,
    };
  }

  /// A short, stable snapshot of the library for the first message.
  String appState() {
    final st = app.library.stats();
    final s = app.settings.all();
    return '<app_state>tracks: ${st['tracks']}, crates: ${app.crates.list().length}, '
        'folders: ${st['roots']}, low bitrate: ${st['low_bitrate']}, missing: ${st['missing']}, '
        'offline: ${st['offline']}. Key notation: ${s['key_notation']}. '
        "Gig mode: ${s['gig_mode'] == true ? 'on' : 'off'}. Theme: ${s['theme']}"
        "${s['premium_ui'] == true ? ', Premium UI on' : ''}.</app_state>";
  }

  static Json resultBlock(String id, Object? content, {bool isError = false}) {
    final c = stripPaths(content);
    var text = c is String ? c : jsonEncode(c);
    if (utf8.encode(text).length > maxResultChars) {
      // cut on a character boundary, as 1.x does on a UTF-8 boundary
      var cut = maxResultChars;
      while (utf8
              .encode(text.substring(0, cut > text.length ? text.length : cut))
              .length >
          maxResultChars) {
        cut--;
      }
      text =
          '${text.substring(0, cut)}… [truncated — ask for fewer results or use filters]';
    }
    return {
      'type': 'tool_result',
      'tool_use_id': id,
      'content': text,
      if (isError) 'is_error': true,
    };
  }

  static String _newId() =>
      'c${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';

  /// Starts or continues a conversation with a message from the DJ.
  Future<Turn> chat(String? conversationId, String message) async {
    final msg = message.trim();
    if (msg.isEmpty || msg.length > 8000) {
      throw AgentException('message must be 1–8000 characters');
    }
    final cfg = config();
    if (cfg.provider == 'off') throw AgentException('the AI assistant is off');
    final id = (conversationId == null || conversationId.isEmpty)
        ? _newId()
        : conversationId;
    final conv = _conversations.remove(id) ?? Conversation();
    final content = <Json>[];
    // A new message while actions wait means the DJ moved on: they are skipped.
    if (conv.pending.isNotEmpty) {
      content.addAll(conv.readyResults);
      conv.readyResults = [];
      for (final (tid, _, _) in conv.pending) {
        content.add(
          resultBlock(tid, 'The DJ did not run this action.', isError: true),
        );
      }
      conv.pending = [];
    }
    if (conv.messages.isEmpty) {
      content.add({'type': 'text', 'text': appState()});
    }
    content.add({'type': 'text', 'text': msg});
    conv.messages.add({'role': 'user', 'content': content});
    final turn = Turn(id);
    try {
      await _drive(cfg, conv, turn);
    } finally {
      _conversations[id] = conv;
    }
    return turn;
  }

  /// Approves or declines the actions waiting in a conversation, then continues.
  Future<Turn> confirm(
    String conversationId,
    Map<String, bool> decisions,
  ) async {
    final cfg = config();
    final conv = _conversations.remove(conversationId);
    if (conv == null) throw AgentException('conversation not found');
    if (conv.pending.isEmpty) {
      _conversations[conversationId] = conv;
      throw AgentException('there are no actions waiting');
    }
    final turn = Turn(conversationId);
    final results = conv.readyResults;
    conv.readyResults = [];
    final pending = conv.pending;
    conv.pending = [];
    for (final (tid, name, input) in pending) {
      final summary = describe(name, input);
      if (decisions[tid] ?? false) {
        try {
          final v = runTool(name, input);
          turn.done.add({'tool': name, 'summary': summary, 'ok': true});
          results.add(resultBlock(tid, v));
        } on Exception catch (e) {
          turn.done.add({
            'tool': name,
            'summary': summary,
            'ok': false,
            'error': '$e',
          });
          results.add(resultBlock(tid, 'Failed: $e', isError: true));
        }
      } else {
        turn.done.add({
          'tool': name,
          'summary': summary,
          'ok': false,
          'skipped': true,
        });
        results.add(
          resultBlock(
            tid,
            'The DJ chose not to run this action.',
            isError: true,
          ),
        );
      }
    }
    conv.messages.add({'role': 'user', 'content': results});
    try {
      await _drive(cfg, conv, turn);
    } finally {
      _conversations[conversationId] = conv;
    }
    return turn;
  }

  void reset(String conversationId) => _conversations.remove(conversationId);

  Future<void> _drive(LlmConfig cfg, Conversation conv, Turn turn) async {
    turn
      ..provider = cfg.provider
      ..model = cfg.model;
    if (cfg.provider == 'claude' && cfg.apiKey == null) {
      throw AgentException(
        'add your Anthropic API key in Settings → AI assistant first',
      );
    }
    final specs = toolSpecs();
    final texts = <String>[];
    // Settings → Limits: no limit means until the model has finished.
    final maxSteps = limitOf(app.cat, 'assistant_steps');
    for (var step = 0; maxSteps == null || step < maxSteps; step++) {
      final Json reply;
      try {
        reply = await app.online.llmChat(
          cfg,
          assistantGuide,
          specs,
          conv.messages,
        );
      } on OnlineException catch (e) {
        throw AgentException('The AI model could not be reached: ${e.message}');
      }
      final blocks = [
        for (final b in (reply['content'] as List?) ?? const [])
          if (b is Map) Map<String, Object?>.from(b),
      ];
      if (reply['model'] case final String m) turn.model = m;
      conv.messages.add({'role': 'assistant', 'content': blocks});
      for (final b in blocks) {
        if (b['type'] == 'text' && b['text'] is String) {
          final t = (b['text']! as String).trim();
          if (t.isNotEmpty) texts.add(t);
        }
      }
      final stop = reply['stop_reason'] as String? ?? 'end_turn';
      if (stop == 'refusal') {
        texts.add("Sorry — I can't help with that request.");
        break;
      }
      final uses = [
        for (final b in blocks.where((b) => b['type'] == 'tool_use'))
          (
            b['id'] as String? ?? '',
            b['name'] as String? ?? '',
            b['input'] is Map
                ? Map<String, Object?>.from(b['input']! as Map)
                : <String, Object?>{},
          ),
      ];
      if (uses.isEmpty) {
        if (stop == 'max_tokens') {
          texts.add('(My reply was cut short — ask me to continue.)');
        }
        break;
      }
      final results = <Json>[];
      final pending = <(String, String, Json)>[];
      for (final (tid, name, input) in uses) {
        switch (tierOf(name)) {
          case Tier.read:
            turn.lookedUp.add(name.replaceAll('_', ' '));
            try {
              results.add(resultBlock(tid, runTool(name, input)));
            } on Exception catch (e) {
              results.add(resultBlock(tid, 'Error: $e', isError: true));
            }
          case Tier.ui:
            turn.uiActions.add({...input, 'type': name});
            results.add(
              resultBlock(tid, {
                'ok': true,
                'note': 'The app is now showing it to the DJ.',
              }),
            );
          case Tier.act:
            turn.pending.add(
              PendingAction(tid, name, describe(name, input), input),
            );
            pending.add((tid, name, input));
          case null:
            results.add(
              resultBlock(tid, "Unknown tool '$name'.", isError: true),
            );
        }
      }
      if (pending.isNotEmpty) {
        conv
          ..pending = pending
          ..readyResults = results;
        break;
      }
      conv.messages.add({'role': 'user', 'content': results});
      if (maxSteps != null && step + 1 == maxSteps) {
        texts.add(
          "(I stopped after several steps — tell me how you'd like to continue.)",
        );
      }
    }
    turn.text = texts.join('\n\n');
  }
}

class Conversation {
  final messages = <Json>[];

  /// Tool calls waiting for the DJ, with results already computed for the
  /// other calls of the same model turn.
  var pending = <(String, String, Json)>[];
  var readyResults = <Json>[];
}

class PendingAction {
  PendingAction(this.id, this.tool, this.summary, this.input);
  final String id, tool, summary;
  final Json input;
  Json toJson() => {'id': id, 'tool': tool, 'summary': summary, 'input': input};
}

class Turn {
  Turn(this.conversationId);
  final String conversationId;
  String text = '', model = '', provider = '';

  /// Screen changes for the front end: {"type": "show_tracks"|"open_view", ...}.
  final uiActions = <Json>[];
  final pending = <PendingAction>[];

  /// Actions run in this turn (after approval), with their outcome.
  final done = <Json>[];

  /// Read tools used, for transparency ("Looked up: …").
  final lookedUp = <String>[];

  Json toJson() => {
    'conversation_id': conversationId,
    'text': text,
    'ui_actions': uiActions,
    'pending': [for (final p in pending) p.toJson()],
    'done': done,
    'looked_up': lookedUp,
    'model': model,
    'provider': provider,
  };
}
