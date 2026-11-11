import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'blake3.dart';
import 'catalogue.dart';
import 'organize.dart' show organiseModeOn;
import 'tag_writer.dart';

/// Opt-in, verified tag writing (1.x `safe_write.rs`). This and the organiser are
/// the only code that changes music files, and they follow the same process:
///
/// 1. Off by default (`allow_file_changes`).
/// 2. An exact preview of every field change, with Serato warnings.
/// 3. Before writing, the file must be unchanged since the preview (size,
///    modified time and full BLAKE3 hash).
/// 4. A backup copy is made and verified (hash); if that fails, stop.
/// 5. Tags are written to a temporary copy next to the original; the audio data
///    must hash identically and every tag item that was not edited must be
///    byte-identical. Only then is the copy renamed over the original.
/// 6. Every change is logged with its backup and can be rolled back exactly.
class SafeWriteException implements Exception {
  SafeWriteException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw SafeWriteException(m);

class FileStamp {
  FileStamp(this.size, this.mtime, this.hash);
  final int size;
  final int? mtime;
  final String hash;
  @override
  bool operator ==(Object other) =>
      other is FileStamp &&
      other.size == size &&
      other.mtime == mtime &&
      other.hash == hash;
  @override
  int get hashCode => Object.hash(size, mtime, hash);
  Map<String, Object?> toJson() => {'size': size, 'mtime': mtime, 'hash': hash};
}

FileStamp stampOf(String path) {
  final st = File(path).statSync();
  if (st.type == FileSystemEntityType.notFound) {
    throw const FileSystemException('file not found');
  }
  return FileStamp(
    st.size,
    st.modified.millisecondsSinceEpoch,
    blake3File(path) ?? '',
  );
}

class PlannedChange {
  PlannedChange(this.trackId, this.path);
  final int trackId;
  final String path;
  String format = '';

  /// field → (old, new); new null removes the field. Sorted, as 1.x stores it.
  final changes = SplayTreeMap<String, (String?, String?)>();
  FileStamp stamp = FileStamp(0, null, '');
  final warnings = <String>[];
  String? blocked;

  String get changesJson => jsonEncode({
    for (final e in changes.entries) e.key: [e.value.$1, e.value.$2],
  });

  Map<String, Object?> toJson() => {
    'track_id': trackId,
    'path': path,
    'format': format,
    'changes': {
      for (final e in changes.entries) e.key: [e.value.$1, e.value.$2],
    },
    'stamp': stamp.toJson(),
    'warnings': warnings,
    'blocked': blocked,
  };
}

class SafeWriteService {
  SafeWriteService(this.cat, this.dataDir);
  final Catalogue cat;

  /// The account's data folder; backups go to `<dataDir>/backups/<day>/`.
  final String dataDir;

  /// Tag writing is allowed by its own switch, or as part of Organise Files mode.
  bool get enabled =>
      cat.getSetting('allow_file_changes') == '1' || organiseModeOn(cat);

  /// The exact preview for writing [values] (field → value, null to remove) to
  /// each track. Nothing is written.
  List<PlannedChange> preview(List<int> ids, Map<String, String?> values) {
    if (!enabled) {
      _no(
        'Writing to music files is turned off. Turn it on in Settings → Safety only if you have backups and have tested on copies.',
      );
    }
    if (ids.isEmpty || ids.length > 500) _no('choose between 1 and 500 tracks');
    for (final k in values.keys) {
      if (!writableFields.contains(k)) _no("'$k' cannot be written to files");
    }
    return [for (final id in ids) _plan(id, values)];
  }

  PlannedChange _plan(int id, Map<String, String?> values) {
    final rows = cat.db.select(
      'SELECT path, presence, media_kind FROM tracks WHERE id=?',
      [id],
    );
    if (rows.isEmpty) _no('track not found');
    final r = rows.first;
    final pc = PlannedChange(id, r['path'] as String);
    if (r['media_kind'] == 'video') {
      return pc
        ..blocked =
            'Video files are never written. Use catalogue values instead.';
    }
    final kind = writableKind(pc.path);
    if (kind == null) {
      return pc
        ..blocked =
            'This format is not supported for writing (only MP3, FLAC and M4A).';
    }
    pc.format = kind;
    if (r['presence'] != 'present' || !File(pc.path).existsSync()) {
      return pc..blocked = 'File is missing or its drive is offline.';
    }
    try {
      pc.stamp = stampOf(pc.path);
    } on FileSystemException catch (e) {
      return pc..blocked = 'Cannot read file: ${e.message}';
    }
    final Map<String, String> cur;
    try {
      cur = readWritableTags(pc.path, kind);
    } on TagWriteException catch (e) {
      return pc..blocked = 'Cannot write tags to this file: ${e.message}';
    } on Exception catch (e) {
      return pc..blocked = 'Cannot read tags: $e';
    }
    for (final e in values.entries) {
      final old = cur[e.key];
      final v = e.value?.trim();
      final nv = (v == null || v.isEmpty) ? null : v;
      if (old != nv) pc.changes[e.key] = (old, nv);
    }
    if (kind == 'mp3') {
      pc.warnings.add(
        "Serato keeps cue points, loops, beatgrids and overview data inside this file's tags. Only the fields listed will change; every other tag frame is verified to be preserved. Test on a copy first.",
      );
    }
    if (kind == 'm4a' &&
        (values.containsKey('bpm') || values.containsKey('key'))) {
      pc.warnings.add(
        'BPM and key are not written to M4A files in this version; those fields will be skipped.',
      );
      pc.changes
        ..remove('bpm')
        ..remove('key');
    }
    if (pc.changes.isEmpty) {
      pc.blocked = 'Nothing to change: the file already has these values.';
    }
    return pc;
  }

  /// Applies previewed changes; one result per file.
  List<Map<String, Object?>> apply(List<PlannedChange> planned) {
    if (!enabled) _no('Writing to music files is turned off.');
    final results = <Map<String, Object?>>[];
    for (final pc in planned) {
      if (pc.blocked != null || pc.changes.isEmpty) {
        results.add({
          'track_id': pc.trackId,
          'status': 'skipped',
          'message': pc.blocked,
        });
        continue;
      }
      try {
        final id = _applyOne(pc);
        results.add({
          'track_id': pc.trackId,
          'status': 'done',
          'change_id': id,
        });
      } catch (e) {
        final msg = e is SafeWriteException ? e.message : '$e';
        cat.db.execute(
          "INSERT INTO change_log(track_id, path, action, changes_json, status, error, at) VALUES (?,?,'tag_write',?,'failed',?,?)",
          [pc.trackId, pc.path, pc.changesJson, msg, nowMs()],
        );
        results.add({
          'track_id': pc.trackId,
          'status': 'failed',
          'message': msg,
        });
      }
    }
    return results;
  }

  String _tempBeside(String path) => p.join(
    p.dirname(path),
    '.${p.basename(path)}.djassistant-${nowMs()}.tmp',
  );

  int _applyOne(PlannedChange pc) {
    final path = pc.path, kind = pc.format;
    // 3. unchanged since the preview?
    if (stampOf(path) != pc.stamp) {
      _no(
        'The file changed since the preview. Nothing was written; preview again.',
      );
    }
    // 4. a verified backup
    final day = nowMs() ~/ 86400000;
    final dir = Directory(p.join(dataDir, 'backups', '$day'))
      ..createSync(recursive: true);
    final backup = p.join(
      dir.path,
      '${pc.trackId}-${nowMs()}-${p.basename(path)}',
    );
    if (File(backup).existsSync()) _no('backup name collision; try again');
    try {
      File(path).copySync(backup);
    } on FileSystemException catch (e) {
      _no('Backup failed, nothing was written: ${e.message}');
    }
    if (blake3File(backup) != pc.stamp.hash) {
      File(backup).deleteSync();
      _no('Backup could not be verified, nothing was written.');
    }
    // 5. write a temporary copy and verify it
    final edited = pc.changes.keys.toList();
    final audioBefore = audioHash(path, kind);
    final untouchedBefore = untouchedTags(path, kind, edited);
    final tmp = _tempBeside(path);
    File(path).copySync(tmp);
    try {
      try {
        writeTagsInPlace(tmp, kind, {
          for (final e in pc.changes.entries) e.key: e.value.$2,
        });
      } on TagWriteException catch (e) {
        _no('writing tags failed: ${e.message}');
      }
      if (audioHash(tmp, kind) != audioBefore) {
        _no('verification failed: audio data would change');
      }
      final u = untouchedTags(tmp, kind, edited);
      if (u.length != untouchedBefore.length ||
          [for (var i = 0; i < u.length; i++) u[i] == untouchedBefore[i]]
              .contains(false)) {
        _no(
          'verification failed: other tag data (for example Serato cue/beatgrid frames) would not be preserved',
        );
      }
      final after = readWritableTags(tmp, kind);
      for (final e in pc.changes.entries) {
        final got = after[e.key], want = e.value.$2;
        final ok = want == null
            ? got == null
            : (got == want ||
                  (e.key == 'year' && got != null && want.startsWith(got)));
        if (!ok) {
          _no(
            'verification failed: ${e.key} reads back as ${got ?? 'nothing'}',
          );
        }
      }
      // Final check right before replacing: still unchanged?
      if (stampOf(path) != pc.stamp) {
        _no(
          'The file changed while preparing the update. Nothing was written.',
        );
      }
      try {
        File(tmp).renameSync(path);
      } on FileSystemException catch (e) {
        _no(
          'Could not replace the file (is it open in another app, such as Serato?): ${e.message}. Nothing was written.',
        );
      }
    } catch (_) {
      final t = File(tmp);
      if (t.existsSync()) t.deleteSync();
      rethrow;
    }
    final afterHash = blake3File(path) ?? '';
    cat.db.execute(
      'INSERT INTO change_log(track_id, path, action, changes_json, backup_path, before_hash, after_hash, status, at) '
      "VALUES (?,?,'tag_write',?,?,?,?,'done',?)",
      [
        pc.trackId,
        path,
        pc.changesJson,
        backup,
        pc.stamp.hash,
        afterHash,
        nowMs(),
      ],
    );
    return cat.db.lastInsertRowId;
  }

  /// Restores the verified backup of a change, if the file has not been changed
  /// again since. Works for changes made by 1.x too (same hashes, same log).
  void rollback(int changeId) {
    final rows = cat.db.select(
      "SELECT track_id, path, backup_path, before_hash, after_hash, status FROM change_log WHERE id=? AND action='tag_write'",
      [changeId],
    );
    if (rows.isEmpty) _no('change not found');
    final r = rows.first;
    if (r['status'] != 'done') {
      _no(
        'this change cannot be rolled back (it failed or was already rolled back)',
      );
    }
    final path = r['path'] as String;
    final backup = (r['backup_path'] as String?) ?? '';
    final before = (r['before_hash'] as String?) ?? '',
        after = (r['after_hash'] as String?) ?? '';
    if (blake3File(path) != after) {
      _no(
        'The file has changed since this edit (perhaps by another app). Rolling back would lose those changes, so nothing was done.',
      );
    }
    if (!File(backup).existsSync() || blake3File(backup) != before) {
      _no('The backup no longer matches; nothing was done.');
    }
    final tmp = _tempBeside(path);
    File(backup).copySync(tmp);
    if (blake3File(tmp) != before) {
      File(tmp).deleteSync();
      _no('Restore copy could not be verified; nothing was done.');
    }
    try {
      File(tmp).renameSync(path);
    } on FileSystemException catch (e) {
      File(tmp).deleteSync();
      _no('Could not restore (file in use?): ${e.message}');
    }
    cat.db.execute("UPDATE change_log SET status='rolled_back' WHERE id=?", [
      changeId,
    ]);
    cat.db.execute(
      'INSERT INTO change_log(track_id, path, action, changes_json, backup_path, before_hash, after_hash, status, at) '
      "VALUES (?,?,'rollback',?,?,?,?,'done',?)",
      [
        r['track_id'],
        path,
        jsonEncode({'rolled_back_change': changeId}),
        backup,
        after,
        before,
        nowMs(),
      ],
    );
  }

  List<Map<String, Object?>> log({int? limit}) => [
    for (final r in cat.db.select(
      'SELECT id, track_id, path, action, changes_json, backup_path, status, error, at FROM change_log ORDER BY id DESC${limit == null ? '' : ' LIMIT ${limit < 1 ? 1 : limit}'}',
    ))
      {
        'id': r['id'],
        'track_id': r['track_id'],
        'path': r['path'],
        'action': r['action'],
        'changes': () {
          try {
            return jsonDecode(r['changes_json'] as String);
          } on FormatException {
            return null;
          }
        }(),
        'backup_path': r['backup_path'],
        'status': r['status'],
        'error': r['error'],
        'at': r['at'],
      },
  ];

  /// Previews writing each track's catalogue values (the DJ's edits and accepted
  /// fixes) into its own tags. With [includeEstimates], BPM and key from analysis
  /// fill files that have none. Tracks with nothing to change are left out.
  List<PlannedChange> previewFromCatalogue(
    List<int> ids, {
    bool includeEstimates = false,
  }) {
    if (ids.isEmpty) {
      _no('choose at least one track');
    }
    final out = <PlannedChange>[];
    for (final id in ids) {
      final rows = cat.db.select(
        'SELECT u.title, u.artist, u.album, u.genre, u.year, u.bpm, u.musical_key, t.bpm_tag, t.key_tag, a.bpm AS a_bpm, a.camelot '
        'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
        [id],
      );
      if (rows.isEmpty) continue;
      final r = rows.first;
      final values = <String, String?>{};
      void put(String k, Object? v) {
        final s = v?.toString().trim();
        if (s != null && s.isNotEmpty) values[k] = s;
      }

      String fmtBpm(num b) =>
          (b - b.round()).abs() < 0.05 ? '${b.round()}' : b.toStringAsFixed(1);
      put('title', r['title']);
      put('artist', r['artist']);
      put('album', r['album']);
      put('genre', r['genre']);
      put('year', r['year']);
      final bpm = r['bpm'] as num?, aBpm = r['a_bpm'] as num?;
      put(
        'bpm',
        bpm != null
            ? fmtBpm(bpm)
            : (includeEstimates && r['bpm_tag'] == null && aBpm != null
                  ? fmtBpm(aBpm)
                  : null),
      );
      put(
        'key',
        r['musical_key'] ??
            (includeEstimates && r['key_tag'] == null ? r['camelot'] : null),
      );
      if (values.isEmpty) continue;
      out.addAll(
        preview([
          id,
        ], values).where((pc) => pc.blocked != null || pc.changes.isNotEmpty),
      );
    }
    return out;
  }

  /// Writes clean tags into a file DJ Assistant has just created (a gig-pack or
  /// export copy, never an original); its audio must hash the same afterwards.
  /// Returns false for formats without tag support (they stay byte-identical).
  static bool tagNewCopy(String copy, Map<String, String?> fields) {
    final kind = writableKind(copy);
    if (kind == null) return false;
    final before = audioHash(copy, kind);
    try {
      writeTagsInPlace(copy, kind, {
        for (final e in fields.entries)
          if (writableFields.contains(e.key)) e.key: e.value,
      });
    } on TagWriteException catch (e) {
      _no('could not tag the copy: ${e.message}');
    }
    if (audioHash(copy, kind) != before) {
      _no('writing tags changed the audio data of the copy');
    }
    return true;
  }
}
