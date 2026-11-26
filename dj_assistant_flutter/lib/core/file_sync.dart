import 'dart:convert';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'jobs.dart';
import 'serato_sync.dart';
import 'keys.dart';
import 'safe_write.dart';
import 'suggestions.dart' show rustNumber;

/// Write-through: with "Write my changes into the music files" on, every
/// change to a track's title, artist, album, genre, year, BPM or key in DJ
/// Assistant (your edits, accepted suggestions, the crew's fixes, undo) is
/// also written into the file's tags.
///
/// Changes go into an outbox ([enqueueFileSync]) and a background writer
/// ([flushFileSync]) applies them through the safe writer, one file at a
/// time: the file must be unchanged since it was read, a verified backup is
/// made first, the audio must hash identically afterwards and every other
/// tag (Serato cues, loops, beatgrids) must be byte-identical. Every write is
/// in the change log and can be rolled back (Organise Files → History).
const syncSetting = 'sync_to_files';

/// Catalogue field → file tag field (the fields the safe writer supports).
const syncFields = {
  'title': 'title',
  'artist': 'artist',
  'album': 'album',
  'genre': 'genre',
  'year': 'year',
  'bpm': 'bpm',
  'key': 'key',
  'record_label': 'label',
  'grouping': 'grouping',
};

/// Catalogue fields that make up the Grouping tag (energy and mood).
const groupingSources = {'energy', 'mood'};

/// The catalogue column behind each synced field (Grouping is worked out
/// from energy and mood, see [groupingText]).
const _columns = {
  'title': 'title',
  'artist': 'artist',
  'album': 'album',
  'genre': 'genre',
  'year': 'year',
  'bpm': 'bpm',
  'key': 'musical_key',
  'record_label': 'record_label',
};

/// "E7 · Uplifting": energy (the DJ's, else the analysed one) and mood, as
/// written to the Grouping tag; null when there is neither.
String? groupingText(Catalogue cat, int id) {
  final r = cat.db.select(
    'SELECT COALESCE(u.energy, a.energy) AS e, u.mood AS m FROM tracks t '
    'LEFT JOIN track_user u ON u.track_id=t.id '
    'LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
    [id],
  ).firstOrNull;
  if (r == null) return null;
  final parts = [
    if (r['e'] case final num e) 'E${e.round()}',
    if ((r['m'] as String?)?.trim() case final m? when m.isNotEmpty) m,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Whether energy and mood also go into the Comments tag (off: Comments
/// often holds Mixed In Key's "8A - Energy 6" and is left alone).
bool groupingToComment(Catalogue cat) =>
    cat.getSetting('energy_to_comment') == '1';

bool fileSyncOn(Catalogue cat) => (cat.getSetting(syncSetting) ?? '1') == '1';

void _ensureQueue(Catalogue cat) => cat.db.execute(
  'CREATE TABLE IF NOT EXISTS file_sync_queue ('
  'track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE, '
  'field TEXT NOT NULL, queued_at INTEGER NOT NULL, '
  'PRIMARY KEY (track_id, field))',
);

/// Queues [fields] of [ids] for writing to their files (only when the switch
/// is on and the fields can be written). Cheap: no file is touched here.
int enqueueFileSync(Catalogue cat, List<int> ids, Iterable<String> fields) {
  if (!fileSyncOn(cat)) return 0;
  final fs = {
    ...fields.where(syncFields.containsKey),
    if (fields.any(groupingSources.contains)) 'grouping',
  }.toList();
  if (fs.isEmpty || ids.isEmpty) return 0;
  _ensureQueue(cat);
  final now = nowMs();
  final st = cat.db.prepare(
    'INSERT OR REPLACE INTO file_sync_queue (track_id, field, queued_at) VALUES (?,?,?)',
  );
  var n = 0;
  for (final id in ids) {
    for (final f in fs) {
      st.execute([id, f, now]);
      n++;
    }
  }
  st.close();
  return n;
}

/// Tracks waiting to be written.
int fileSyncQueued(Catalogue cat) {
  _ensureQueue(cat);
  return cat.db
          .select('SELECT COUNT(DISTINCT track_id) AS n FROM file_sync_queue')
          .first['n']
      as int;
}

/// Queues every track whose catalogue already holds a value of its own for a
/// synced field (for turning write-through on with earlier edits).
int enqueueAllEdited(Catalogue cat) {
  if (!fileSyncOn(cat)) return 0;
  _ensureQueue(cat);
  var n = 0;
  for (final MapEntry(key: field, value: col) in _columns.entries) {
    cat.db.execute(
      'INSERT OR IGNORE INTO file_sync_queue (track_id, field, queued_at) '
      'SELECT track_id, ?, ? FROM track_user WHERE $col IS NOT NULL',
      [field, nowMs()],
    );
    n += cat.db.updatedRows;
  }
  return n;
}

/// The account's data folder (backups live there), from the open catalogue.
String? dataDirOf(Catalogue cat) {
  final f = cat.db.select('PRAGMA database_list').first['file'] as String?;
  return (f == null || f.isEmpty) ? null : p.dirname(f);
}

/// The value written to the file for a catalogue value. Keys follow the DJ's
/// notation (Camelot "8A" or musical "Am"); BPM is whole when it is.
String? _fileValue(Catalogue cat, String field, Object? v) {
  if (v == null) return null;
  switch (field) {
    case 'bpm':
      final b = (v as num).toDouble();
      final r = (b * 10).round() / 10;
      return rustNumber((r - r.round()).abs() < 0.05 ? r.roundToDouble() : r);
    case 'key':
      final cam = normalizeKey('$v') ?? '$v';
      return (cat.getSetting('key_notation') ?? 'camelot') == 'musical'
          ? (musicalName(cam) ?? cam)
          : cam;
  }
  return '$v';
}

/// What a file's [field] said before DJ Assistant first wrote it (from the
/// change log), as a one-element record (the value may be null: the file had
/// no such tag); null when DJ Assistant never wrote that field.
(String?,)? originalFileValue(Catalogue cat, int id, String field) {
  for (final r in cat.db.select(
    "SELECT changes_json FROM change_log WHERE track_id=? AND action='tag_write' "
    "AND status='done' ORDER BY id",
    [id],
  )) {
    final m = jsonDecode(r['changes_json'] as String) as Map;
    final c = m[field];
    if (c is List && c.isNotEmpty) return (c.first as String?,);
  }
  return null;
}

/// Writes queued changes to their files. A value cleared in the catalogue
/// (or undone) puts back what the file said before DJ Assistant first wrote
/// to it; if DJ Assistant never wrote that field, the file is left alone.
/// Returns (written, unchanged or skipped, failed) and keeps it as the last
/// result for Settings.
Future<(int, int, int)> flushFileSync(
  Catalogue cat, {
  String? dataDir,
  JobProgress? progress,
}) async {
  _ensureQueue(cat);
  final dir = dataDir ?? dataDirOf(cat);
  if (dir == null) return (0, 0, 0);
  final writer = SafeWriteService(cat, dir);
  var written = 0, skipped = 0, failed = 0;
  final ids = [
    for (final r in cat.db.select(
      'SELECT DISTINCT track_id FROM file_sync_queue ORDER BY track_id',
    ))
      r['track_id'] as int,
  ];
  progress?.total = ids.length;
  final errors = <String>[];
  for (final id in ids) {
    if (await progress?.checkpoint() ?? false) break;
    final fields = [
      for (final r in cat.db.select(
        'SELECT field FROM file_sync_queue WHERE track_id=?',
        [id],
      ))
        r['field'] as String,
    ];
    final cols = [for (final f in fields) ?_columns[f]];
    final row = cols.isEmpty
        ? null
        : cat.db.select(
            'SELECT ${cols.join(', ')} FROM track_user WHERE track_id=?',
            [id],
          ).firstOrNull;
    final values = <String, String?>{};
    for (final f in fields) {
      if (f == 'grouping') {
        final g = groupingText(cat, id);
        if (g != null) {
          values['grouping'] = g;
          if (groupingToComment(cat)) values['comment'] = g;
        }
        continue;
      }
      final v = _fileValue(cat, f, row?[_columns[f]]);
      if (v != null) {
        values[syncFields[f]!] = v;
      } else if (originalFileValue(cat, id, syncFields[f]!) case (final old,)) {
        // your value was cleared (or undone) after write-through changed the
        // file: put back what the file said before DJ Assistant wrote to it
        values[syncFields[f]!] = old;
      }
    }
    var ok = true;
    if (!fileSyncOn(cat)) break; // switched off while working
    if (values.isNotEmpty) {
      try {
        final plan = writer.preview([id], values);
        final res = writer.apply(plan).single;
        switch (res['status']) {
          case 'done':
            written++;
            enqueueSeratoSync(cat, [id]);
          case 'failed':
            failed++;
            ok = false;
            errors.add('${res['message']}');
          default:
            skipped++;
        }
      } on Object catch (e) {
        failed++;
        ok = false;
        errors.add('$e');
      }
    } else {
      skipped++;
    }
    // a failed file stays queued only if it may work later (it never blocks
    // the rest; it is in the change log either way)
    cat.db.execute('DELETE FROM file_sync_queue WHERE track_id=?', [id]);
    progress?.tick(ok: ok);
  }
  cat.setSetting(
    'file_sync_last',
    jsonEncode({
      'at': nowMs(),
      'written': written,
      'skipped': skipped,
      'failed': failed,
      'errors': errors.take(5).toList(),
    }),
  );
  return (written, skipped, failed);
}

/// The background writer (a job isolate). Afterwards Serato's library is
/// brought in step with the files (when Serato DJ is closed).
JobBody fileSyncJob(
  String dbPath,
  String dataDir, {
  List<String> seratoDirs = const [],
}) => (ctx) async {
  final cat = Catalogue.open(dbPath);
  try {
    final (w, s, f) = await flushFileSync(cat, dataDir: dataDir, progress: ctx);
    final (st, _, note) = flushSeratoSync(
      cat,
      seratoDirs,
      backupsDir: p.join(dataDir, 'serato_backups'),
    );
    ctx
      ..result = {'written': w, 'skipped': s, 'failed': f, 'serato': st}
      ..message =
          'Wrote $w file(s)${f > 0 ? '; $f could not be written (see History)' : ''}'
          '${st > 0 ? '; updated $st track(s) in Serato' : ''}'
          '${note != null ? '; Serato not updated yet: $note' : ''}.';
  } finally {
    cat.close();
  }
};

/// The last write-through result, for Settings.
Map<String, Object?>? lastFileSync(Catalogue cat) {
  final raw = cat.getSetting('file_sync_last');
  if (raw == null) return null;
  try {
    return Map<String, Object?>.from(jsonDecode(raw) as Map);
  } on Object {
    return null;
  }
}
