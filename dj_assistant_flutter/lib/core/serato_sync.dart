import 'catalogue.dart';
import 'file_sync.dart' show groupingText, groupingToComment;
import 'keys.dart';
import 'paths.dart';
import 'serato_backup.dart';
import 'serato_library.dart';
import 'suggestions.dart' show rustNumber;

/// Keeps Serato's library (`database V2`) in step with what was written into
/// the music files, so Serato shows the new genre, year, label, album and
/// grouping without a rescan. BPM and key go to Serato only where Serato has
/// none of its own (its own analysis always wins).
///
/// Tracks wait in a queue until Serato DJ is closed; nothing is lost when it
/// is open.
void _ensure(Catalogue cat) => cat.db.execute(
  'CREATE TABLE IF NOT EXISTS serato_sync_queue ('
  'track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE, '
  'queued_at INTEGER NOT NULL)',
);

void enqueueSeratoSync(Catalogue cat, List<int> ids) {
  _ensure(cat);
  final st = cat.db.prepare(
    'INSERT OR REPLACE INTO serato_sync_queue (track_id, queued_at) VALUES (?,?)',
  );
  final now = nowMs();
  for (final id in ids) {
    st.execute([id, now]);
  }
  st.close();
}

int seratoSyncQueued(Catalogue cat) {
  _ensure(cat);
  return cat.db.select('SELECT COUNT(*) AS n FROM serato_sync_queue').first['n']
      as int;
}

/// What Serato's library should say for track [id] (fields as in
/// `seratoDbFields`).
Map<String, String> seratoValuesFor(Catalogue cat, int id) {
  final r = cat.db.select(
    'SELECT COALESCE(u.genre, t.genre) AS genre, COALESCE(u.year, t.year) AS year, '
    'COALESCE(u.album, t.album) AS album, COALESCE(u.record_label, t.label) AS label, '
    'u.bpm AS bpm, u.musical_key AS k FROM tracks t '
    'LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?',
    [id],
  ).firstOrNull;
  if (r == null) return const {};
  final g = groupingText(cat, id);
  final cam = r['k'] == null ? null : normalizeKey(r['k'] as String);
  return {
    if (r['genre'] case final String v when v.isNotEmpty) 'genre': v,
    if (r['year'] case final int v) 'year': '$v',
    if (r['album'] case final String v when v.isNotEmpty) 'album': v,
    if (r['label'] case final String v when v.isNotEmpty) 'label': v,
    'grouping': ?g,
    if (g != null && groupingToComment(cat)) 'comment': g,
    if (r['bpm'] case final num v) 'bpm': rustNumber(v.toDouble()),
    if (cam != null) 'key': musicalName(cam) ?? cam,
  };
}

/// Writes the queued tracks into every `_Serato_` folder's library (each
/// takes the tracks on its own drive). Returns (tracks, fields) changed, or
/// a note when Serato is open (the queue then stays for next time).
(int, int, String?) flushSeratoSync(
  Catalogue cat,
  List<String> seratoDirs, {
  String? backupsDir,
}) {
  _ensure(cat);
  final ids = [
    for (final r in cat.db.select('SELECT track_id FROM serato_sync_queue'))
      r['track_id'] as int,
  ];
  if (ids.isEmpty || seratoDirs.isEmpty) return (0, 0, null);
  final changes = <String, Map<String, String>>{};
  for (final id in ids) {
    final path = cat.db.select('SELECT path FROM tracks WHERE id=?', [
      id,
    ]).firstOrNull?['path'];
    if (path is! String) continue;
    final v = seratoValuesFor(cat, id);
    if (v.isNotEmpty) changes[path] = v;
  }
  var tracks = 0, fields = 0;
  final backups = backupsDir == null ? null : SeratoBackups(backupsDir);
  for (final d in seratoDirs) {
    final lib = SeratoLibrary(d, backups: backups);
    // BPM and key only where Serato has no analysis of its own
    final known = lib.databaseValues();
    final mine = {
      for (final e in changes.entries)
        e.key: {
          for (final f in e.value.entries)
            if (!(f.key == 'bpm' && known[pathKey(e.key)]?.bpm != null) &&
                !(f.key == 'key' && known[pathKey(e.key)]?.key != null))
              f.key: f.value,
        },
    };
    try {
      final (t, f) = lib.updateDatabase(mine);
      tracks += t;
      fields += f;
    } on SeratoLibraryException catch (e) {
      return (tracks, fields, e.message);
    }
  }
  cat.db.execute('DELETE FROM serato_sync_queue');
  return (tracks, fields, null);
}
