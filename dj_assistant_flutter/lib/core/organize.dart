import 'dart:io';

import 'package:path/path.dart' as p;

import 'blake3.dart';
import 'catalogue.dart';
import 'keys.dart';
import 'paths.dart';
import 'serato_links.dart';

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

  /// rename | move | folder_rename | remove | replace
  final String op;
  final int? trackId;
  final String from;
  String to;
  final int? size, mtime;
  String? blocked;
  final int tracks;

  /// For `replace`: the better file that is copied in (it stays where it is).
  String? source;

  /// What this change would mean in Serato (see [OrganizeService.checkSerato]).
  String? serato;

  /// Other things to know before approving (a different format, for example).
  final notes = <String>[];

  Map<String, Object?> toJson() => {
    'op': op,
    'track_id': trackId,
    'from': from,
    'to': to,
    'size': size,
    'mtime': mtime,
    'blocked': blocked,
    'tracks': tracks,
    'source': ?source,
    'serato': ?serato,
    if (notes.isNotEmpty) 'notes': notes,
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

/// Organise Files mode (rename, move, remove, replace). Off by default. A
/// library that allowed file changes before this switch existed keeps Organise
/// available, so an existing workflow is not taken away.
bool organiseModeOn(Catalogue cat) =>
    (cat.getSetting('organise_mode') ?? cat.getSetting('allow_file_changes')) ==
    '1';

class OrganizeService {
  OrganizeService(this.cat, this.dataDir);
  final Catalogue cat;
  final String dataDir;

  String get removedArea => p.join(dataDir, 'Removed files');

  /// Side tables kept outside the shared schema (1.x still opens the catalogue):
  /// the hash of each moved file, checked before an undo, and track
  /// replacements (the better file copied in for a track).
  void _ensureTables() {
    cat.db.execute(
      'CREATE TABLE IF NOT EXISTS file_op_hashes (op_id INTEGER PRIMARY KEY, hash TEXT NOT NULL)',
    );
    cat.db.execute(
      'CREATE TABLE IF NOT EXISTS track_replacements (id INTEGER PRIMARY KEY, batch TEXT NOT NULL, '
      'track_id INTEGER, old_path TEXT NOT NULL, new_path TEXT NOT NULL, source_path TEXT NOT NULL, '
      "hash TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('done','undone')), at INTEGER NOT NULL)",
    );
  }

  /// Adds what each change would mean in Serato, read from Serato's own files
  /// (never written). [links] can point at test folders.
  OrganizePlan checkSerato(OrganizePlan plan, {SeratoLinks? links}) {
    final l = links ?? SeratoLinks();
    final files = [
      for (final o in plan.ops)
        if (o.op != 'folder_rename' && o.blocked == null) o.from,
    ];
    final found = l.check(files);
    for (final o in plan.ops) {
      if (o.op == 'folder_rename') {
        o.serato = o.tracks > 0
            ? 'Serato will show the ${o.tracks} track(s) in this folder as missing until you relocate them (Files → Relocate lost files). Cues and beatgrids stored in the files travel with them.'
            : null;
        continue;
      }
      final link = found[o.from];
      if (link == null) continue;
      o.serato = switch (o.op) {
        'rename' || 'move' => link.moveRisk(),
        'replace' => link.replaceRisk(
          samePath:
              pathKey(o.to, insensitive: true) ==
              pathKey(o.from, insensitive: true),
        ),
        'remove' =>
          link.inLibrary || link.crates.isNotEmpty
              ? "Serato will show it as missing in its library${link.crates.isEmpty ? '' : ' and ${link.crates.length} crate(s)'}. The file is kept in Removed files until you empty it."
              : null,
        _ => null,
      };
    }
    return plan;
  }

  void _requireEnabled() {
    if (!organiseModeOn(cat)) {
      _no(
        'Organise Files mode is off. Turn it on in Settings → Changes to music files (and keep a backup of your music).',
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

  /// Replaces a track's file with a better copy ([source], e.g. a higher-quality
  /// purchase). The track keeps its crates, ratings, notes and other catalogue
  /// values. The old file goes to the restorable "Removed files" area; the new
  /// file is copied (never moved) into the old file's folder and verified. With
  /// the same format it takes the old file's exact name, so Serato's crates still
  /// find it; otherwise it keeps the old name with its own extension.
  OrganizePlan previewReplaceFile(int trackId, String source) {
    _requireEnabled();
    final (path, _, f) = _track(trackId);
    final (size, mtime) = _stamp(path);
    final ext = p.extension(source);
    final sameFormat = ext.toLowerCase() == p.extension(path).toLowerCase();
    final to = sameFormat
        ? path
        : p.join(p.dirname(path), '${p.basenameWithoutExtension(path)}$ext');
    final op = FileOp('replace', trackId, path, to, size, mtime)
      ..source = source;
    final srcType = FileSystemEntity.typeSync(source, followLinks: false);
    if (f.containsKey('_missing') || size == null) {
      op.blocked = "The current file isn't available.";
    } else if (srcType != FileSystemEntityType.file) {
      op.blocked = "The replacement file isn't available.";
    } else if (pathKey(source, insensitive: true) ==
        pathKey(path, insensitive: true)) {
      op.blocked = 'That is the same file.';
    } else if (!sameFormat && _targetExists(to, path)) {
      op.blocked = 'A file with the new name already exists in that folder.';
    } else if (cat.db.select(
      'SELECT 1 FROM tracks WHERE path_key=? AND id<>?',
      [pathKey(source), trackId],
    ).isNotEmpty) {
      op.notes.add(
        'The replacement is already in your library as another track; it is copied, so that track stays as it is.',
      );
    }
    if (!sameFormat) {
      op.notes.add(
        'Different format (${p.extension(path)} → $ext): the file name changes, so links from Serato and other apps to the old name will break.',
      );
    }
    return _finish([op]);
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

  /// Applies a previewed plan. Only the items at the indexes in [only] are
  /// applied when it is given (the ones the DJ approved); each item is re-checked
  /// and a problem skips that item only.
  OrganizeResult apply(OrganizePlan plan, {Set<int>? only}) {
    _requireEnabled();
    _ensureTables();
    final chosen = [
      for (var i = 0; i < plan.ops.length; i++)
        if (only == null || only.contains(i)) plan.ops[i],
    ];
    final merge = plan.merge;
    if (merge != null && chosen.any((o) => o.blocked == null)) {
      final removing = {
        for (final o in chosen)
          if (o.blocked == null && o.trackId != null) o.trackId!,
      };
      _mergeInto(merge.$1, [
        for (final x in merge.$2)
          if (removing.contains(x)) x,
      ]);
    }
    var batch = '${nowMs()}';
    while (cat.db.select('SELECT 1 FROM file_ops WHERE batch=?', [
      batch,
    ]).isNotEmpty) {
      batch = '${int.parse(batch) + 1}';
    }
    var done = 0;
    final skipped = <(String, String)>[];
    for (final o in chosen) {
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
      if (o.op == 'replace') {
        final err = _replace(o, batch);
        if (err == null) {
          done++;
        } else {
          skipped.add((o.from, err));
        }
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
      String? hash;
      try {
        if (o.op != 'folder_rename') {
          hash = blake3File(o.from);
          if (hash == null) _no("couldn't read the file to check it");
        }
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
          if (blake3File(to) != hash) {
            // Never expected (a rename doesn't touch the bytes); say so loudly.
            _no(
              'the file at the new location does not match the original; it was left there for you to check',
            );
          }
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
      if (hash != null) {
        cat.db.execute(
          'INSERT OR REPLACE INTO file_op_hashes(op_id, hash) VALUES (?,?)',
          [cat.db.lastInsertRowId, hash],
        );
      }
      done++;
    }
    return OrganizeResult(batch, done, skipped);
  }

  /// One track replacement: the old file goes to "Removed files" (verified),
  /// the new file is copied next to it under a temporary name, verified, then
  /// given its final name. Any failure puts the old file back. Returns an error.
  String? _replace(FileOp o, String batch) {
    final source = o.source!;
    final srcHash = blake3File(source), oldHash = blake3File(o.from);
    if (srcHash == null) return "The replacement file couldn't be read.";
    if (oldHash == null) return "The current file couldn't be read.";
    if (o.to != o.from && _targetExists(o.to, o.from)) {
      return 'Something already exists at the new name.';
    }
    final rel =
        cat.db.select('SELECT rel_path FROM tracks WHERE id=?', [
              o.trackId,
            ]).firstOrNull?['rel_path']
            as String? ??
        p.basename(o.from);
    final parts = p
        .split(rel)
        .where(
          (s) => s.isNotEmpty && s != '.' && s != '..' && !p.isAbsolute(s),
        );
    final kept = p.joinAll([removedArea, batch, ...parts]);
    if (_exists(kept)) return 'The Removed files area already has that file.';
    try {
      _move(o.from, kept);
    } on OrganizeException catch (e) {
      return e.message;
    }
    if (blake3File(kept) != oldHash) {
      return 'The kept copy of the original did not verify; it is at $kept. Nothing else was changed.';
    }
    final tmp = p.join(p.dirname(o.to), '.djassist-replace-$batch.tmp');
    void restore() {
      try {
        if (File(tmp).existsSync()) File(tmp).deleteSync();
        _move(kept, o.from);
      } on Object {
        // left in Removed files; reported below
      }
    }

    try {
      File(source).copySync(tmp);
      if (blake3File(tmp) != srcHash) {
        restore();
        return "The copy of the replacement didn't verify; the original was put back.";
      }
      File(tmp).renameSync(o.to);
    } on FileSystemException catch (e) {
      restore();
      return "Couldn't copy the replacement (${e.message}); the original was put back.";
    }
    final now = nowMs();
    cat.db.execute(
      "INSERT INTO file_ops(batch, op, track_id, from_path, to_path, status, at) VALUES (?,'remove',?,?,?,'done',?)",
      [batch, o.trackId, o.from, kept, now],
    );
    cat.db.execute(
      'INSERT OR REPLACE INTO file_op_hashes(op_id, hash) VALUES (?,?)',
      [cat.db.lastInsertRowId, oldHash],
    );
    cat.db.execute(
      'INSERT INTO track_replacements(batch, track_id, old_path, new_path, source_path, hash, status, at) '
      "VALUES (?,?,?,?,?,?,'done',?)",
      [batch, o.trackId, o.from, o.to, source, srcHash, now],
    );
    if (o.trackId != null && o.to != o.from) _updatePath(o.trackId!, o.to);
    return null;
  }

  /// Undoes the replacements in [batch]: each copied-in file moves to the
  /// "Removed files" area (it is a copy, but it may hold cues Serato added
  /// since, so it is kept, not deleted) and the track points at its old path
  /// again; the old file itself comes back with the batch's file operations.
  int _undoReplacements(String batch) {
    _ensureTables();
    final rows = cat.db.select(
      "SELECT id, track_id, old_path, new_path FROM track_replacements WHERE batch=? AND status='done' ORDER BY id DESC",
      [batch],
    );
    // Check every original is still waiting in Removed files before moving
    // anything, so an undo never leaves a track without a file.
    for (final r in rows) {
      final kept = cat.db.select(
        "SELECT to_path FROM file_ops WHERE batch=? AND op='remove' AND status='done' AND from_path=?",
        [batch, r['old_path']],
      );
      if (kept.isEmpty || !File(kept.first['to_path'] as String).existsSync()) {
        _no(
          "can't undo this replacement: the original file is no longer in Removed files (it was emptied), so the replacement was left in place",
        );
      }
    }
    var n = 0;
    for (final r in rows) {
      final neu = r['new_path'] as String;
      if (_exists(neu)) {
        final dest = p.join(
          removedArea,
          '$batch-undone',
          '${r['id']}-${p.basename(neu)}',
        );
        _move(neu, dest);
        cat.db.execute(
          "INSERT INTO file_ops(batch, op, track_id, from_path, to_path, status, at) VALUES (?,'remove',NULL,?,?,'done',?)",
          ['$batch-undone', neu, dest, nowMs()],
        );
      }
      final tid = r['track_id'] as int?;
      if (tid != null && neu != r['old_path']) {
        _updatePath(tid, r['old_path'] as String);
      }
      cat.db.execute(
        "UPDATE track_replacements SET status='undone' WHERE id=?",
        [r['id']],
      );
      n++;
    }
    return n;
  }

  /// Track replacements, newest first.
  List<Map<String, Object?>> replacements({int? limit}) {
    _ensureTables();
    return [
      for (final r in cat.db.select(
        'SELECT id, batch, track_id, old_path, new_path, source_path, status, at FROM track_replacements ORDER BY id DESC${limit == null ? '' : ' LIMIT $limit'}',
      ))
        {...r},
    ];
  }

  /// Undoes a batch (or one operation): everything moves back, newest first.
  int undo({String? batch, int? opId}) {
    _ensureTables();
    // A replacement is undone as a whole: its new file first, then its old one.
    if (batch == null && opId != null) {
      final b =
          cat.db.select('SELECT batch FROM file_ops WHERE id=?', [
                opId,
              ]).firstOrNull?['batch']
              as String?;
      if (b != null &&
          cat.db.select(
            "SELECT 1 FROM track_replacements WHERE batch=? AND status='done'",
            [b],
          ).isNotEmpty) {
        batch = b;
        opId = null;
      }
    }
    if (batch != null) _undoReplacements(batch);
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

  List<Map<String, Object?>> history({int? limit}) => [
    for (final r in cat.db.select(
      'SELECT id, batch, op, track_id, from_path, to_path, status, error, at FROM file_ops ORDER BY id DESC${limit == null ? '' : ' LIMIT $limit'}',
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

  /// Every file waiting in the "Removed files" area: where it came from, where
  /// it is now and its size. Shown in full before the area is emptied.
  List<Map<String, Object?>> removedFiles() => [
    for (final r in cat.db.select(
      "SELECT id, batch, from_path, to_path, at FROM file_ops WHERE op='remove' AND status='done' ORDER BY id DESC",
    ))
      {
        'id': r['id'],
        'from': r['from_path'],
        'to': r['to_path'],
        'at': r['at'],
        'bytes': File(r['to_path'] as String).existsSync()
            ? File(r['to_path'] as String).lengthSync()
            : 0,
      },
  ];

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
