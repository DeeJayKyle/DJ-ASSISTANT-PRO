import 'catalogue.dart';

/// Every number that bounds a feature, in one place. Nothing is limited
/// unless the DJ sets a limit in Settings → Limits and batch sizes: each value
/// is stored as `limit_<key>` (a whole number) and missing means no limit.
///
/// Rates set by online services themselves (MusicBrainz: one request a
/// second) are not limits on how much is done, only on how fast, and stay.
class LimitDef {
  const LimitDef(
    this.key,
    this.label,
    this.help, {
    this.unit = '',
    this.min = 1,
  });
  final String key, label, help, unit;
  final int min;
}

const limitDefs = <LimitDef>[
  LimitDef(
    'autoprep_musicbrainz',
    'Auto-prep: MusicBrainz lookups per run',
    'Tracks missing a year or genre looked up on MusicBrainz each time auto-prep runs (one a second, so 3,600 take an hour).',
    unit: 'tracks',
  ),
  LimitDef(
    'autoprep_catalogs',
    'Auto-prep: catalogue checks per run',
    'Tracks checked against the online catalogues you turned on, each time auto-prep runs.',
    unit: 'tracks',
  ),
  LimitDef(
    'lookup_musicbrainz',
    'Suggestions: MusicBrainz button',
    'Tracks looked up when you press MusicBrainz on the Suggestions page.',
    unit: 'tracks',
  ),
  LimitDef(
    'lookup_catalogs',
    'Suggestions: online catalogues button',
    'Tracks checked when you press the online catalogues button.',
    unit: 'tracks',
  ),
  LimitDef(
    'studio_minutes',
    'Studio: longest song',
    'Songs longer than this are not opened in Stems, Remix or DJ Decks. A whole song is held in memory (about 21 MB a minute, more while splitting).',
    unit: 'minutes',
  ),
  LimitDef(
    'analysis_minutes',
    'Analysis: minutes read per track',
    'BPM, key, energy, loudness and cues are worked out from this much of each track. Without a limit the whole file is read (slower for long mixes).',
    unit: 'minutes',
  ),
  LimitDef(
    'picker_results',
    'Song pickers: results shown',
    'Songs listed in the Studio and Quick Prep song pickers.',
    unit: 'songs',
  ),
  LimitDef(
    'suggestions_shown',
    'Suggestions: items shown',
    'Suggestions listed at once on the Suggestions page.',
    unit: 'items',
  ),
  LimitDef(
    'discovery_items',
    'Discovery: recommendations kept',
    'Recommendations listed on the Discovery page.',
    unit: 'items',
  ),
  LimitDef(
    'list_rows',
    'Long lists: rows before "Show all"',
    'Logs, histories, previews and reports show this many rows, then a Show all button. Without a limit everything is shown at once.',
    unit: 'rows',
  ),
  LimitDef(
    'assistant_steps',
    'AI assistant: steps per request',
    'Tool calls the AI assistant may make to answer one request. Each step is a call to the AI service you chose.',
    unit: 'steps',
  ),
  LimitDef(
    'assistant_tokens',
    'AI assistant: length of an answer',
    'The most the AI service may write in one answer (tokens). Some services refuse values above their own maximum.',
    unit: 'tokens',
    min: 256,
  ),
];

LimitDef? limitDef(String key) =>
    limitDefs.where((d) => d.key == key).firstOrNull;

/// The DJ's limit for [key], or null for no limit.
int? limitOf(Catalogue cat, String key) {
  final v = int.tryParse(cat.getSetting('limit_$key') ?? '');
  return v == null || v <= 0 ? null : v;
}

/// Sets (or, with null, removes) the DJ's limit for [key].
void setLimit(Catalogue cat, String key, int? value) {
  final d = limitDef(key);
  if (d == null) throw ArgumentError('unknown limit $key');
  if (value == null) {
    cat.setSetting('limit_$key', '');
    return;
  }
  if (value < d.min) {
    throw ArgumentError('${d.label} must be at least ${d.min}');
  }
  cat.setSetting('limit_$key', '$value');
}

/// Every limit, for the settings page and the assistant.
Map<String, int?> allLimits(Catalogue cat) => {
  for (final d in limitDefs) d.key: limitOf(cat, d.key),
};

/// `LIMIT n` for SQL, or nothing.
String sqlLimit(int? n) => n == null ? '' : ' LIMIT $n';

/// The first [n] of [xs], or all of them.
Iterable<T> upTo<T>(Iterable<T> xs, int? n) => n == null ? xs : xs.take(n);
