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
    'analysis_minutes',
    'Analysis: minutes read per track',
    'Energy is worked out from this much of each track. Without a limit the whole file is read (slower for long mixes).',
    unit: 'minutes',
  ),
  LimitDef(
    'suggestions_shown',
    'Changes: items shown',
    'Changes listed at once on the Changes page.',
    unit: 'items',
  ),
  LimitDef(
    'list_rows',
    'Long lists: rows before "Show all"',
    'Logs, histories, previews and reports show this many rows, then a Show all button. Without a limit everything is shown at once.',
    unit: 'rows',
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

/// Every limit.
Map<String, int?> allLimits(Catalogue cat) => {
  for (final d in limitDefs) d.key: limitOf(cat, d.key),
};

/// `LIMIT n` for SQL, or nothing.
String sqlLimit(int? n) => n == null ? '' : ' LIMIT $n';

/// The first [n] of [xs], or all of them.
Iterable<T> upTo<T>(Iterable<T> xs, int? n) => n == null ? xs : xs.take(n);
