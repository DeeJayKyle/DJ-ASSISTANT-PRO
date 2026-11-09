import 'catalogue.dart';

/// Whole-library snapshots (track profiles, match indexes, Next up
/// candidates) are expensive to build on a large library but are asked for
/// again and again while nothing changes: every time Gig Mode redraws, every
/// Follow Serato poll, every set plan. They are kept per catalogue and
/// rebuilt only after the catalogue changes.
///
/// "Changed" is SQLite's own count of changes made through this connection
/// (`total_changes()`) together with `PRAGMA data_version`, which moves
/// when another connection (a scan or analysis worker) commits. Both are
/// cheap to read.
final _store = Expando<Map<String, (Object?, (int, int))>>('snapshots');

(int, int) catalogueVersion(Catalogue cat) => (
  cat.db.select('SELECT total_changes() AS n').first['n'] as int,
  cat.db.select('PRAGMA data_version').first.values.first as int,
);

/// The value [build] made for [name] while the catalogue is unchanged, or a
/// fresh one. Callers must treat the result as read-only.
T snapshot<T>(Catalogue cat, String name, T Function() build) {
  final m = _store[cat] ??= {};
  final v = catalogueVersion(cat);
  final hit = m[name];
  if (hit != null && hit.$2 == v) return hit.$1 as T;
  final value = build();
  // building reads only, but read the version after in case it wrote
  m[name] = (value, catalogueVersion(cat));
  return value;
}

/// Stores [value] as [name]'s snapshot for the catalogue as it is now.
void rememberSnapshot(Catalogue cat, String name, Object? value) {
  (_store[cat] ??= {})[name] = (value, catalogueVersion(cat));
}

/// [name]'s snapshot if the catalogue has not changed since it was stored.
Object? peekSnapshot(Catalogue cat, String name) {
  final hit = _store[cat]?[name];
  return hit != null && hit.$2 == catalogueVersion(cat) ? hit.$1 : null;
}
