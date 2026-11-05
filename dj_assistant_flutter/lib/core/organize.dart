import 'dart:io';

import 'package:path/path.dart' as p;

import 'blake3.dart';
import 'catalogue.dart';
import 'keys.dart';
import 'paths.dart';

/// File organiser (opt-in), ported from 1.x `organize.rs`: rename files and
/// folders, move files into a folder layout, and remove broken or unwanted files —
/// all restorably.
///
/// * Only when "Allow changes to music files" is on.
/// * Every change is previewed first and applied only with explicit approval.
/// * Conflicts (target exists, two files to the same name) block that item.
/// * A source that changed since the preview is skipped.
/// * Every change is logged and can be undone; removed files go to a "Removed
///   files" area in the app's data folder until the DJ empties it.
const seratoWarning =
    "Renaming or moving files breaks Serato's links to them: Serato's crates, cue points and beatgrids for these tracks will show them as missing until Serato is pointed at the new location (Serato: Files → Relocate lost files). Analysis and crates inside DJ Assistant follow the files automatically.";

const templateTokens = [
  'artist',
  'title',
  'album',
  'genre',
  'year',
  'bpm',
  'key',
  'version',
];

class OrganizeException implements Exception {
  OrganizeException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw OrganizeException(m);

class FileOp {
  FileOp(
    this.op,
    this.trackId,
    this.from,
    this.to,
    this.size,
    this.mtime, {
    this.tracks = 1,
  });

  /// rename | move | folder_rename | remove
  final String op;
  final int? trackId;
  final String from;
  String to;
  final int? size, mtime;
  String? blocked;
  final int tracks;

  Map<String, Object?> toJson() => {
    'op': op,
    'track_id': trackId,
    'from': from,
    'to': to,
    'size': size,
    'mtime': mtime,
    'blocked': blocked,
    'tracks': tracks,
  };
}

class OrganizePlan {
  OrganizePlan(this.ops, {this.warning, this.merge});
  final List<FileOp> ops;
  final String? warning;

  /// Duplicates replacement: (keep, others) merged in the catalogue before applying.
  final (int, List<int>)? merge;
  int get ready => ops.where((o) => o.blocked == null).length;
  int get blocked => ops.length - ready;
}

class OrganizeResult {
  OrganizeResult(this.batch, this.done, this.skipped);
  final String batch;
  final int done;
  final List<(String, String)> skipped;
}

/// Makes text safe as a Windows file or folder name (1.x `sanitize`).
String sanitizeName(String name) {
  final b = StringBuffer();
  for (final r in name.runes) {
    final c = String.fromCharCode(r);
    b.write(
      '<>:"/\\|?*'.contains(c) || r < 0x20 || (r >= 0x7F && r <= 0x9F)
          ? ' '
          : c,
    );
  }
  var s = b
      .toString()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join(' ');
  s = s.replaceFirst(RegExp(r'[. ]+$'), '').trim();
  const reserved = [
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'LPT1',
    'LPT2',
    'LPT3',
  ];
  if (reserved.contains(s.toUpperCase())) s = '${s}_';
  final runes = s.runes.toList();
  return String.fromCharCodes(runes.take(180)).trim();
}

/// Fills a template like "{artist} - {title}"; throws the missing field's name.
String renderTemplate(String template, Map<String, String> fields) {
  final out = StringBuffer();
  var rest = template;
  while (true) {
    final i = rest.indexOf('{');
    if (i < 0) break;
    out.write(rest.substring(0, i));
    final j = rest.indexOf('}', i);
    if (j < 0) throw const FormatException('unclosed {');
    final key = rest.substring(i + 1, j);
    final v = fields[key];
    if (v == null) throw FormatException('no $key');
    out.write(v);
    rest = rest.substring(j + 1);
  }
  out.write(rest);
  return out.toString();
}

void _checkTemplate(String t) {
  var rest = t;
  while (true) {
    final i = rest.indexOf('{');
    if (i < 0) break;
    final j = rest.indexOf('}', i);
    if (j < 0) _no('template has an unclosed {');
    final key = rest.substring(i + 1, j);
    if (!templateTokens.contains(key)) {
      _no(
        'unknown field {$key} — use ${templateTokens.map((k) => '{$k}').join(', ')}',
      );
    }
    rest = rest.substring(j + 1);
  }
  if (t.trim().isEmpty || t.length > 200) {
    _no('the template is empty or too long');
  }
}

(int?, int?) _stamp(String path) {
  final st = File(path).statSync();
  if (st.type != FileSystemEntityType.file) return (null, null);
  return (st.size, st.modified.millisecondsSinceEpoch);
}

bool _exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;

/// True when [to] exists and is not just [from] with a different letter case.
bool _targetExists(String to, String from) =>
    _exists(to) &&
    pathKey(to, insensitive: true) != pathKey(from, insensitive: true);

class OrganizeService {
  OrganizeService(this.cat, this.dataDir);
  final Catalogue cat;
  final String dataDir;

  String get removedArea => p.join(dataDir, 'Removed files');

  void _requireEnabled() {
    if (cat.getSetting('allow_file_changes') != '1') {
      _no(
        'Changes to music files are turned off. Turn on "Allow changes to music files" in Settings → Safety first (and keep a backup of your music).',
      );
    }
  }

  (String, String?, Map<String, String>) _track(int id) {
    final rows = cat.db.select(
      'SELECT t.path, r.path AS root, COALESCE(u.artist, t.artist) AS artist, COALESCE(u.title, t.title) AS title, '
      'COALESCE(u.album, t.album) AS album, COALESCE(u.genre, t.genre) AS genre, COALESCE(u.year, t.year) AS year, '
      'COALESCE(u.bpm, t.bpm_tag, a.bpm) AS bpm, COALESCE(u.musical_key, t.key_tag, a.camelot) AS key, '
      'COALESCE(u.version_label, t.version_hint) AS version, t.presence '
      'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id '
      'LEFT JOIN library_roots r ON r.id=t.root_id WHERE t.id=?',
      [id],
    );
    if (rows.isEmpty) _no('track not found');
    final r = rows.first;
    final f = <String, String>{};
    void put(String k, Object? v) {
      final s = v?.toString().trim();
      if (s != null && s.isNotEmpty) f[k] = s;
    }

    for (final k in ['artist', 'title', 'album', 'genre', 'version']) {
      put(k, r[k]);
    }
    put('year', r['year']);
    final bpm = r['bpm'] as num?;
    if (bpm != null) put('bpm', '${bpm.round()}');
    final key = r['key'] as String?;
    if (key != null) put('key', normalizeKey(key) ?? key);
    if (r['presence'] != 'present') f['_missing'] = '1';
    return (r['path'] as String, r['root'] as String?, f);
  }

  OrganizePlan _finish(
    List<FileOp> ops, {
    bool warn = true,
    (int, List<int>)? merge,
  }) {
    // Two items aiming at the same target block each other.
    final count = <String, int>{};
    for (final o in ops.where((o) => o.blocked == null && o.op != 'remove')) {
      final k = pathKey(o.to, insensitive: true);
      count[k] = (count[k] ?? 0) + 1;
    }
    for (final o in ops) {
      if (o.blocked == null &&
          o.op != 'remove' &&
          (count[pathKey(o.to, insensitive: true)] ?? 0) > 1) {
        o.blocked = 'Another file in this plan would get the same name.';
      }
    }
    return OrganizePlan(
      ops,
      warning: warn ? seratoWarning : null,
      merge: merge,
    );
  }

  /// Renames files in place, e.g. "{artist} - {title}".
  OrganizePlan previewRename(List<int> ids, String template) {
    _requireEnabled();
    _checkTemplate(template);
    final ops = <FileOp>[];
    for (final id in ids) {
      final (path, _, f) = _track(id);
      final (size, mtime) = _stamp(path);
      final op = FileOp('rename', id, path, path, size, mtime);
      if (f.containsKey('_missing') || size == null) {
        op.blocked = "The file isn't available.";
      } else {
        try {
          final name = sanitizeName(renderTemplate(template, f));
          if (name.isEmpty) {
            op.blocked = 'The new name would be empty.';
          } else {
            op.to = p.join(p.dirname(path), '$name${p.extension(path)}');
            if (op.to == op.from) continue; // already named this way
            if (_targetExists(op.to, op.from)) {
              op.blocked = 'A file with that name already exists.';
            }
          }
        } on FormatException catch (e) {
          op.blocked = "Can't name it: ${e.message}.";
        }
      }
      ops.add(op);
    }
    return _finish(ops);
  }

  /// Moves files into folders under their library folder, e.g. "{genre}/{artist}".
  OrganizePlan previewMove(List<int> ids, String folderTemplate) {
    _requireEnabled();
    _checkTemplate(folderTemplate);
    final ops = <FileOp>[];
    for (final id in ids) {
      final (path, root, f) = _track(id);
      final (size, mtime) = _stamp(path);
      final op = FileOp('move', id, path, path, size, mtime);
      if (f.containsKey('_missing') || size == null) {
        op.blocked = "The file isn't available.";
      } else if (root == null) {
        op.blocked = "The track isn't in a library folder.";
      } else {
        try {
          final rel = renderTemplate(folderTemplate, f);
          var dir = root;
          for (final part in rel.split(RegExp(r'[/\\]'))) {
            final s = sanitizeName(part);
            if (s.isNotEmpty && s != '.' && s != '..') dir = p.join(dir, s);
          }
          op.to = p.join(dir, p.basename(path));
          if (op.to == op.from) continue;
          if (_targetExists(op.to, op.from)) {
            op.blocked = 'A file with that name is already in that folder.';
          }
        } on FormatException catch (e) {
          op.blocked = "Can't place it: ${e.message}.";
        }
      }
      ops.add(op);
    }
    return _finish(ops);
  }

  /// Renames one folder inside a library folder (never a library folder itself).
  OrganizePlan previewFolderRename(String folder, String newName) {
    _requireEnabled();
    final name = sanitizeName(newName);
    if (name.isEmpty) _no('type a new folder name');
    final key = pathKey(folder, insensitive: true);
    final inside = cat.db.select('SELECT path FROM library_roots').any((r) {
      final rk = pathKey(r['path'] as String, insensitive: true);
      return key != rk && keyIsWithin(key, rk);
    });
    if (!inside) {
      _no(
        'only folders inside your music folders can be renamed (not a music folder itself)',
      );
    }
    final to = p.join(p.dirname(folder), name);
    final prefix = '$folder${Platform.pathSeparator}';
    final tracks =
        cat.db.select(
              'SELECT COUNT(*) AS n FROM tracks WHERE substr(path, 1, length(?)) = ?',
              [prefix, prefix],
            ).first['n']
            as int;
    final op = FileOp(
      'folder_rename',
      null,
      folder,
      to,
      null,
      null,
      tracks: tracks,
    );
    if (!Directory(folder).existsSync()) {
      op.blocked = "The folder isn't available.";
    } else if (_targetExists(to, folder)) {
      op.blocked = 'A folder with that name already exists here.';
    }
    return _finish([op]);
  }

  /// Tracks that look broken: unreadable or empty files.
  List<int> badFiles() => [
    for (final r in cat.db.select(
      "SELECT id FROM tracks WHERE presence='present' AND removed_at IS NULL AND (read_status='error' OR file_size=0) ORDER BY path",
    ))
      r['id'] as int,
  ];

  /// Removes files into the restorable "Removed files" area.
  OrganizePlan previewRemove(List<int> ids) {
    _requireEnabled();
    final ops = <FileOp>[];
    for (final id in ids) {
      final rows = cat.db.select(
        'SELECT path, rel_path FROM tracks WHERE id=?',
        [id],
      );
      if (rows.isEmpty) _no('track not found');
      final path = rows.first['path'] as String;
      final (size, mtime) = _stamp(path);
      // For removals `to` is the path inside the library folder; the file goes to
      // "Removed files/<batch>/<that path>" when applied.
      final op = FileOp(
        'remove',
        id,
        path,
        rows.first['rel_path'] as String,
        size,
        mtime,
      );
      if (size == null) op.blocked = "The file isn't available.";
      ops.add(op);
    }
    return _finish(ops, warn: false);
  }

  /// Keeps one of a set of duplicates: crates, tags and the DJ's values move to
  /// the kept track, then the others are removed (restorably).
  OrganizePlan previewReplace(int keep, List<int> others) {
    if (others.contains(keep) || others.isEmpty) {
      _no('choose the track to keep and at least one other to replace');
    }
    _track(keep);
    final plan = previewRemove(others);
    return OrganizePlan(plan.ops, warning: plan.warning, merge: (keep, others));
  }

  void _mergeInto(int keep, List<int> others) {
    const cols = [
      'genre',
      'year',
      'bpm',
      'musical_key',
      'energy',
      'rating',
      'mood',
      'color',
      'notes', //
      'version_label',
      'clean_explicit',
      'title',
      'artist',
      'album',
      'original_year',
      'record_label',
    ];
    for (final o in others) {
      cat.db.execute(
        'INSERT OR IGNORE INTO crate_tracks(crate_id, track_id, mode, position, added_at) '
        'SELECT crate_id, ?, mode, position, added_at FROM crate_tracks WHERE track_id=?',
        [keep, o],
      );
      cat.db.execute(
        'INSERT OR IGNORE INTO track_tags(track_id, tag_id) SELECT ?, tag_id FROM track_tags WHERE track_id=?',
        [keep, o],
      );
      cat.db.execute('INSERT OR IGNORE INTO track_user(track_id) VALUES (?)', [
        keep,
      ]);
      for (final c in cols) {
        cat.db.execute(
          'UPDATE track_user SET $c = (SELECT $c FROM track_user WHERE track_id=?) WHERE track_id=? AND $c IS NULL',
          [o, keep],
        );
      }
    }
  }

  /// Moves a file; across drives it copies, verifies the copy by hash, then
  /// deletes the original.
  void _move(String from, String to) {
    Directory(p.dirname(to)).createSync(recursive: true);
    try {
      File(from).renameSync(to);
      return;
    } on FileSystemException {
      // different drive: fall through to copy + verify
    }
    try {
      File(from).copySync(to);
    } on FileSystemException catch (e) {
      throw OrganizeException('copy failed: ${e.message}');
    }
    final a = blake3File(from), b = blake3File(to);
    if (a == null || a != b) {
      File(to).deleteSync();
      _no("the copy didn't verify; the original was left in place");
    }
    try {
      File(from).deleteSync();
    } on FileSystemException catch (e) {
      _no("couldn't remove the original (is it open in Serato?): ${e.message}");
    }
  }

  void _updatePath(int id, String newPath) {
    final root =
        cat.db.select(
              'SELECT r.path FROM tracks t LEFT JOIN library_roots r ON r.id=t.root_id WHERE t.id=?',
              [id],
            ).first['path']
            as String?;
    final rel = root != null && p.isWithin(root, newPath)
        ? p.relative(newPath, from: root)
        : p.basename(newPath);
    cat.db.execute(
      'UPDATE tracks SET path=?, path_key=?, rel_path=?, file_name=? WHERE id=?',
      [newPath, pathKey(newPath), rel, p.basename(newPath), id],
    );
  }

  void _movePrefix(String oldDir, String newDir) {
    final old = '$oldDir${Platform.pathSeparator}',
        neu = '$newDir${Platform.pathSeparator}';
    final rows = cat.db.select(
      'SELECT id, path FROM tracks WHERE substr(path, 1, length(?)) = ?',
      [old, old],
    );
    for (final r in rows) {
      _updatePath(
        r['id'] as int,
        '$neu${(r['path'] as String).substring(old.length)}',
      );
    }
  }

  /// Applies a previewed plan. Each item is re-checked; a problem skips that item only.
  OrganizeResult apply(OrganizePlan plan) {
    _requireEnabled();
    final merge = plan.merge;
    if (merge != null) _mergeInto(merge.$1, merge.$2);
    final batch = '${nowMs()}';
    var done = 0;
    final skipped = <(String, String)>[];
    for (final o in plan.ops) {
      if (o.blocked != null) {
        skipped.add((o.from, o.blocked!));
        continue;
      }
      if (o.op != 'folder_rename' && _stamp(o.from) != (o.size, o.mtime)) {
        skipped.add((
          o.from,
          'The file changed or moved since the preview; preview again.',
        ));
        continue;
      }
      final String to;
      if (o.op == 'remove') {
        // Only plain path parts: never escape the "Removed files" area.
        final parts = p
            .split(o.to)
            .where(
              (s) => s.isNotEmpty && s != '.' && s != '..' && !p.isAbsolute(s),
            );
        to = p.joinAll([removedArea, batch, ...parts]);
      } else {
        to = o.to;
      }
      if (_targetExists(to, o.from)) {
        skipped.add((o.from, 'Something already exists at the new location.'));
        continue;
      }
      String? error;
      try {
        if (o.op == 'folder_rename') {
          try {
            Directory(o.from).renameSync(to);
          } on FileSystemException catch (e) {
            throw OrganizeException(
              "couldn't rename the folder (is a file in it open?): ${e.message}",
            );
          }
        } else {
          _move(o.from, to);
        }
      } on OrganizeException catch (e) {
        error = e.message;
      }
      if (error != null) {
        cat.db.execute(
          "INSERT INTO file_ops(batch, op, track_id, from_path, to_path, status, error, at) VALUES (?,?,?,?,?,'failed',?,?)",
          [batch, o.op, o.trackId, o.from, to, error, nowMs()],
        );
        skipped.add((o.from, error));
        continue;
      }
      switch (o.op) {
        case 'folder_rename':
          _movePrefix(o.from, to);
        case 'remove':
          cat.db.execute(
            "UPDATE tracks SET presence='missing', removed_at=? WHERE id=?",
            [nowMs(), o.trackId],
          );
        default:
          if (o.trackId != null) _updatePath(o.trackId!, to);
      }
      cat.db.execute(
        "INSERT INTO file_ops(batch, op, track_id, from_path, to_path, status, at) VALUES (?,?,?,?,?,'done',?)",
        [batch, o.op, o.trackId, o.from, to, nowMs()],
      );
      done++;
    }
    return OrganizeResult(batch, done, skipped);
  }

  /// Undoes a batch (or one operation): everything moves back, newest first.
  int undo({String? batch, int? opId}) {
    final rows = cat.db.select(
      "SELECT id, op, track_id, from_path, to_path FROM file_ops WHERE status='done' AND ((? IS NOT NULL AND batch=?) OR id=?) ORDER BY id DESC",
      [batch, batch, opId],
    );
    if (rows.isEmpty) _no('nothing to undo');
    var n = 0;
    for (final r in rows) {
      final op = r['op'] as String,
          from = r['from_path'] as String,
          to = r['to_path'] as String;
      if (_exists(from) && op != 'folder_rename') {
        _no("can't undo: something already exists at $from");
      }
      try {
        if (op == 'folder_rename') {
          Directory(to).renameSync(from);
        } else {
          _move(to, from);
        }
      } on Exception catch (e) {
        _no("couldn't move $to back: $e");
      }
      final tid = r['track_id'] as int?;
      switch (op) {
        case 'folder_rename':
          _movePrefix(to, from);
        case 'remove':
          cat.db.execute(
            "UPDATE tracks SET presence='present', removed_at=NULL WHERE id=?",
            [tid],
          );
        default:
          if (tid != null) _updatePath(tid, from);
      }
      cat.db.execute("UPDATE file_ops SET status='undone' WHERE id=?", [
        r['id'],
      ]);
      n++;
    }
    return n;
  }

  List<Map<String, Object?>> history({int limit = 200}) => [
    for (final r in cat.db.select(
      'SELECT id, batch, op, track_id, from_path, to_path, status, error, at FROM file_ops ORDER BY id DESC LIMIT ?',
      [limit],
    ))
      {
        'id': r['id'],
        'batch': r['batch'],
        'op': r['op'],
        'track_id': r['track_id'],
        'from': r['from_path'],
        'to': r['to_path'],
        'status': r['status'],
        'error': r['error'],
        'at': r['at'],
      },
  ];

  /// Files and bytes waiting in the "Removed files" area.
  Map<String, int> removedSummary() {
    final r = cat.db
        .select(
          "SELECT COUNT(*) AS n, COALESCE(SUM(t.file_size),0) AS bytes FROM file_ops f LEFT JOIN tracks t ON t.id=f.track_id WHERE f.op='remove' AND f.status='done'",
        )
        .first;
    return {'files': r['n'] as int, 'bytes': r['bytes'] as int};
  }

  /// Permanently deletes everything in the "Removed files" area. Explicit and
  /// final; never deletes anything outside that area.
  int emptyRemoved() {
    _requireEnabled();
    final area = removedArea;
    var n = 0;
    for (final r in cat.db.select(
      "SELECT id, track_id, to_path FROM file_ops WHERE op='remove' AND status='done'",
    )) {
      final to = r['to_path'] as String;
      if (!p.isWithin(area, to)) continue;
      final f = File(to);
      if (f.existsSync()) {
        try {
          f.deleteSync();
        } on FileSystemException catch (e) {
          _no("couldn't delete $to: ${e.message}");
        }
      }
      cat.db.execute("UPDATE file_ops SET status='purged' WHERE id=?", [
        r['id'],
      ]);
      final tid = r['track_id'] as int?;
      if (tid != null) {
        cat.db.execute(
          'DELETE FROM tracks WHERE id=? AND removed_at IS NOT NULL',
          [tid],
        );
      }
      n++;
    }
    final d = Directory(area);
    if (d.existsSync()) {
      for (final e in d.listSync()) {
        _removeEmptyDirs(e);
      }
    }
    return n;
  }

  void _removeEmptyDirs(FileSystemEntity e) {
    if (e is! Directory) return;
    for (final c in e.listSync()) {
      _removeEmptyDirs(c);
    }
    if (e.listSync().isEmpty) e.deleteSync();
  }
}
