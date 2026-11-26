import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'keys.dart';
import 'library.dart';
import 'library_edit.dart';
import 'paths.dart';
import 'serato_backup.dart';
import 'serato_database.dart';
import 'serato_guard.dart';
import 'serato_tags.dart';
import 'suggestions.dart';
import 'text.dart';

/// Serato DJ's own files, read and changed in place:
///
/// * `_Serato_/Subcrates/*.crate`: one file per crate; a sub-crate is named
///   `Parent%%Child.crate`. Each lists its tracks as paths relative to the
///   root of the drive the `_Serato_` folder is on.
/// * `_Serato_/database V2`: Serato's library, with the BPM and key Serato's
///   own analysis found for every track it knows.
///
/// Crates are rewritten through a temporary file and a rename, so a crash
/// never leaves half a crate. Serato must be closed while crates change:
/// it keeps its crates in memory and writes them back when it quits.
class SeratoLibraryException implements Exception {
  SeratoLibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw SeratoLibraryException(m);

const _maxFileBytes = 256 * 1024 * 1024;

/// One crate saved in Serato.
class SeratoCrate {
  SeratoCrate(this.name, this.file, this.paths);

  /// Full name with "%%" between parent and child ("House%%Deep").
  final String name;
  final String file;

  /// Track paths as Serato stores them (relative to the drive root, "/").
  final List<String> paths;

  List<String> get parts => name.split('%%');
  String get label => parts.last;
  String? get parent =>
      parts.length < 2 ? null : parts.sublist(0, parts.length - 1).join('%%');
  int get depth => parts.length - 1;
}

/// What Serato's own analysis found for a track (database V2 or the tags
/// Serato writes into the file).
class SeratoValues {
  const SeratoValues({this.bpm, this.key, this.source = 'Serato'});
  final double? bpm;

  /// Camelot code ("8A").
  final String? key;
  final String source;
}

// ---------------------------------------------------------------- binary

int _u32(Uint8List b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

String _utf16be(Uint8List b) {
  final units = <int>[
    for (var i = 0; i + 1 < b.length; i += 2) (b[i] << 8) | b[i + 1],
  ];
  return String.fromCharCodes(units).replaceFirst(RegExp('\u0000+\$'), '');
}

List<int> _u16be(String s) => [
  for (final u in s.codeUnits) ...[u >> 8, u & 0xFF],
];

List<int> _chunk(String tag, List<int> data) => [
  ...tag.codeUnits,
  data.length >> 24 & 0xFF,
  data.length >> 16 & 0xFF,
  data.length >> 8 & 0xFF,
  data.length & 0xFF,
  ...data,
];

/// The top-level chunks of a Serato file: (tag, data). Malformed data ends
/// the list.
List<(String, Uint8List)> seratoChunks(Uint8List b) {
  final out = <(String, Uint8List)>[];
  var i = 0;
  while (i + 8 <= b.length) {
    final tag = String.fromCharCodes(b.sublist(i, i + 4));
    final len = _u32(b, i + 4);
    final start = i + 8, end = start + len;
    if (end > b.length) break;
    out.add((tag, Uint8List.sublistView(b, start, end)));
    i = end;
  }
  return out;
}

/// The tracks of a crate file, in order.
List<String> crateTracks(Uint8List bytes) => [
  for (final (tag, data) in seratoChunks(bytes))
    if (tag == 'otrk')
      for (final (t, d) in seratoChunks(data))
        if (t == 'ptrk' && _utf16be(d).isNotEmpty) _utf16be(d),
];

/// A crate file listing [paths]. When [previous] (the crate's current bytes)
/// is given, its header, columns and sort order are kept and only the track
/// list is replaced, so the crate looks the same in Serato.
Uint8List crateBytes(List<String> paths, {Uint8List? previous}) {
  final head = <int>[];
  if (previous != null) {
    for (final (tag, data) in seratoChunks(previous)) {
      if (tag != 'otrk') head.addAll(_chunk(tag, data));
    }
  }
  if (head.isEmpty) {
    head
      ..addAll(_chunk('vrsn', _u16be('1.0/Serato ScratchLive Crate')))
      ..addAll(
        _chunk('osrt', [
          ..._chunk('tvcn', _u16be('song')),
          ..._chunk('brev', [0]),
        ]),
      );
    for (final col in ['song', 'artist', 'bpm', 'key', 'length', 'genre']) {
      head.addAll(
        _chunk('ovct', [
          ..._chunk('tvcn', _u16be(col)),
          ..._chunk('tvcw', _u16be('0')),
        ]),
      );
    }
  }
  return Uint8List.fromList([
    ...head,
    for (final path in paths) ..._chunk('otrk', _chunk('ptrk', _u16be(path))),
  ]);
}

/// Serato's database V2: path → BPM and key, as Serato's analysis left them.
Map<String, SeratoValues> parseSeratoDatabase(Uint8List bytes) {
  final out = <String, SeratoValues>{};
  for (final (tag, data) in seratoChunks(bytes)) {
    if (tag != 'otrk') continue;
    String? path, bpm, key;
    for (final (t, d) in seratoChunks(data)) {
      switch (t) {
        case 'pfil':
          path = _utf16be(d);
        case 'tbpm':
          bpm = _utf16be(d);
        case 'tkey':
          key = _utf16be(d);
      }
    }
    if (path == null || path.isEmpty) continue;
    final b = double.tryParse((bpm ?? '').trim());
    final k = key == null || key.trim().isEmpty ? null : normalizeKey(key);
    if ((b == null || b <= 0) && k == null) continue;
    out[path] = SeratoValues(
      bpm: b == null || b <= 0 ? null : b,
      key: k,
      source: 'Serato library',
    );
  }
  return out;
}

/// Characters a Windows file name can't hold become "_"; "%%" is reserved
/// for nesting.
String crateFileName(String part) => part
    .replaceAll('%%', '%')
    .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
    .trim();

// --------------------------------------------------------------- service

class SeratoLibrary {
  SeratoLibrary(this.dir, {this.backups});

  /// The `_Serato_` folder.
  final String dir;

  /// Where a ZIP of the crates and library goes before every change (none:
  /// no backup, used by tests).
  final SeratoBackups? backups;

  /// Is Serato DJ open? Replaceable in tests.
  static bool Function() isRunning = seratoRunningNow;

  int _depth = 0;

  /// Every change goes through here: the folder is checked, the change is
  /// refused while Serato DJ is open (or when that can't be told), and the
  /// crates and library are backed up first. Nested changes (a [batch])
  /// are checked and backed up once.
  T _change<T>(String reason, T Function() f) {
    if (_depth > 0) return f();
    _check();
    if (isRunning()) {
      _no(
        'Close Serato DJ first: it rewrites its crates and library when it '
        'quits, which would undo this change.',
      );
    }
    backups?.create(dir, reason: reason);
    _depth++;
    try {
      return f();
    } finally {
      _depth--;
    }
  }

  /// Runs several changes with one check and one backup.
  T batch<T>(String reason, T Function() f) => _change(reason, f);

  String get subcrates => p.join(dir, 'Subcrates');
  String get databasePath => p.join(dir, 'database V2');

  /// The drive (or root) the crate paths are relative to.
  String get volume => p.rootPrefix(p.absolute(dir));

  /// `_Serato_` folders on this computer: the one in the Music folder and
  /// one at the top of each drive.
  static List<String> find() {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'];
    final found = <String>[];
    void add(String d) {
      if (Directory(d).existsSync() &&
          !found.any((f) => pathKey(f) == pathKey(d))) {
        found.add(d);
      }
    }

    if (home != null) add(p.join(home, 'Music', '_Serato_'));
    if (Platform.isWindows) {
      for (var c = 'C'.codeUnitAt(0); c <= 'Z'.codeUnitAt(0); c++) {
        add('${String.fromCharCode(c)}:\\_Serato_');
      }
    } else if (Platform.isMacOS) {
      try {
        for (final v in Directory('/Volumes').listSync()) {
          add(p.join(v.path, '_Serato_'));
        }
      } on FileSystemException {
        // no volumes listed
      }
    }
    return found;
  }

  /// Is Serato DJ open? Changes are refused while it is. Throws when it
  /// can't be told.
  static Future<bool> running() async => isRunning();

  void _check() {
    if (p.basename(dir).toLowerCase() != '_serato_') {
      _no(
        "Choose Serato's _Serato_ folder (in your Music folder, or at the top of an external drive).",
      );
    }
    if (!Directory(dir).existsSync()) {
      _no("That _Serato_ folder doesn't exist.");
    }
  }

  String _file(String name) => p.join(subcrates, '$name.crate');

  /// Every crate, sorted so parents come before their children.
  List<SeratoCrate> crates() {
    _check();
    final d = Directory(subcrates);
    if (!d.existsSync()) return const [];
    final out = <SeratoCrate>[];
    for (final f in d.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.crate')) continue;
      if (f.lengthSync() > _maxFileBytes) continue;
      out.add(
        SeratoCrate(
          p.basenameWithoutExtension(f.path),
          f.path,
          crateTracks(f.readAsBytesSync()),
        ),
      );
    }
    // Serato lists parents even when only "A%%B.crate" exists: add them.
    final names = {for (final c in out) c.name};
    for (final c in [...out]) {
      for (var i = 1; i < c.parts.length; i++) {
        final n = c.parts.sublist(0, i).join('%%');
        if (names.add(n)) out.add(SeratoCrate(n, _file(n), const []));
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  SeratoCrate? crate(String name) =>
      crates().where((c) => c.name == name).firstOrNull;

  /// Absolute path of a track listed in a crate.
  String absolute(String seratoPath) =>
      p.normalize(p.join(volume, seratoPath.replaceAll('/', p.separator)));

  /// The crate form of an absolute path, or null when it is on another drive.
  String? relative(String path) {
    final abs = p.absolute(path);
    if (pathKey(p.rootPrefix(abs)) != pathKey(volume)) return null;
    return p.split(abs).skip(1).join('/');
  }

  void _write(String name, List<String> paths) {
    Directory(subcrates).createSync(recursive: true);
    final file = _file(name);
    final f = File(file);
    final prev = f.existsSync() ? f.readAsBytesSync() : null;
    final tmp = '$file.djassistant-tmp';
    File(tmp).writeAsBytesSync(crateBytes(paths, previous: prev), flush: true);
    File(tmp).renameSync(file);
  }

  String _cleanName(String name) {
    final parts = name
        .split('%%')
        .map(crateFileName)
        .where((x) => x.isNotEmpty)
        .toList();
    if (parts.isEmpty) _no('Give the crate a name.');
    return parts.join('%%');
  }

  /// Creates (or replaces the tracks of) a crate. Paths are absolute; tracks
  /// on another drive than this `_Serato_` folder are left out and counted.
  (int, int) save(String name, List<String> absPaths) =>
      _change('Save crate “$name”', () {
        _check();
        final n = _cleanName(name);
        final rel = <String>[];
        var other = 0;
        for (final a in absPaths) {
          final r = relative(a);
          if (r == null) {
            other++;
          } else if (!rel.contains(r)) {
            rel.add(r);
          }
        }
        _write(n, rel);
        return (rel.length, other);
      });

  /// Sets a crate's track list (Serato paths, in order).
  void setTracks(String name, List<String> seratoPaths) =>
      _change('Change crate “$name”', () {
        _check();
        _write(name, [
          ...{...seratoPaths},
        ]);
      });

  /// Renames a crate and moves its sub-crates with it. [newName] may contain
  /// "%%" to place it under another crate.
  void rename(String name, String newName) => _change(
    'Rename crate “$name”',
    () {
      _check();
      final to = _cleanName(newName);
      if (to == name) return;
      if (to.startsWith('$name%%')) _no("A crate can't go inside itself.");
      final all = crates();
      if (all.any((c) => c.name == to)) _no('There is already a crate “$to”.');
      for (final c in all) {
        if (c.name != name && !c.name.startsWith('$name%%')) continue;
        final target = to + c.name.substring(name.length);
        final f = File(c.file);
        if (f.existsSync()) {
          f.renameSync(_file(target));
        } else {
          _write(target, const []);
        }
      }
    },
  );

  /// Moves a crate under [parent] (null: to the top level).
  void move(String name, String? parent) {
    final leaf = name.split('%%').last;
    rename(name, parent == null ? leaf : '$parent%%$leaf');
  }

  /// Deletes a crate and its sub-crates. The tracks are not touched.
  int delete(String name) => _change('Delete crate “$name”', () {
    _check();
    var n = 0;
    for (final c in crates()) {
      if (c.name != name && !c.name.startsWith('$name%%')) continue;
      final f = File(c.file);
      if (f.existsSync()) {
        f.deleteSync();
        n++;
      }
    }
    return n;
  });

  /// Deletes every crate in this `_Serato_` folder.
  int deleteAll() => _change('Delete every crate', () {
    _check();
    var n = 0;
    final d = Directory(subcrates);
    if (!d.existsSync()) return 0;
    for (final f in d.listSync().whereType<File>()) {
      if (f.path.toLowerCase().endsWith('.crate')) {
        f.deleteSync();
        n++;
      }
    }
    return n;
  });

  /// Merges [names] into [into] (created when missing), keeping each track
  /// once. With [removeSources] the merged crates are deleted afterwards.
  int merge(List<String> names, String into, {bool removeSources = false}) =>
      _change('Merge crates into “$into”', () {
        final all = {for (final c in crates()) c.name: c};
        final target = _cleanName(into);
        final paths = <String>[...?all[target]?.paths];
        for (final n in names) {
          for (final x in all[n]?.paths ?? const <String>[]) {
            if (!paths.contains(x)) paths.add(x);
          }
        }
        _write(target, paths);
        if (removeSources) {
          for (final n in names) {
            if (n != target) File(_file(n)).existsSync() ? delete(n) : null;
          }
        }
        return paths.length;
      });

  /// Tracks of [name] whose files no longer exist.
  List<String> missing(String name) => [
    for (final x in crate(name)?.paths ?? const <String>[])
      if (!File(absolute(x)).existsSync()) x,
  ];

  /// Removes tracks whose files are gone from a crate. Returns how many.
  int removeMissing(String name) =>
      _change('Remove missing tracks from “$name”', () {
        final c = crate(name);
        if (c == null) return 0;
        final keep = [
          for (final x in c.paths)
            if (File(absolute(x)).existsSync()) x,
        ];
        final gone = c.paths.length - keep.length;
        if (gone > 0) _write(name, keep);
        return gone;
      });

  /// Writes [changes] (absolute track path → field → text, fields as in
  /// [seratoDbFields]) into Serato's library, so Serato shows them without
  /// a rescan. Tracks Serato doesn't know, or on another drive, are skipped.
  /// Returns (tracks changed, fields changed).
  (int, int) updateDatabase(Map<String, Map<String, String>> changes) {
    final f = File(databasePath);
    if (!f.existsSync()) return (0, 0);
    final rel = <String, Map<String, String>>{};
    for (final e in changes.entries) {
      final r = relative(e.key);
      if (r != null && e.value.isNotEmpty) rel[r] = e.value;
    }
    if (rel.isEmpty) return (0, 0);
    final bytes = f.readAsBytesSync();
    if (bytes.length > _maxFileBytes) {
      _no("Serato's library is too large to change.");
    }
    final up = updateSeratoDatabase(bytes, rel);
    if (up.fields == 0) return (0, 0);
    return _change('Update ${up.tracks} track(s) in Serato\'s library', () {
      // read again under the guard: Serato may have changed it meanwhile
      final now = updateSeratoDatabase(f.readAsBytesSync(), rel);
      final tmp = '$databasePath.djassistant-tmp';
      File(tmp).writeAsBytesSync(now.bytes, flush: true);
      File(tmp).renameSync(databasePath);
      return (now.tracks, now.fields);
    });
  }

  /// Puts a backup's crates and library back. The current state is backed
  /// up first, so a restore can itself be undone.
  void restore(SeratoBackup backup) => _change(
    'Before restoring the backup of ${backup.at.toIso8601String()}',
    () {
      final b = backups;
      if (b == null) _no('Backups are not set up.');
      b.restoreInto(backup, dir);
    },
  );

  /// Serato's BPM and key for every track in its library (database V2).
  /// Keys are absolute paths' [pathKey]s.
  Map<String, SeratoValues> databaseValues() {
    final f = File(databasePath);
    if (!f.existsSync() || f.lengthSync() > _maxFileBytes) return const {};
    return {
      for (final e in parseSeratoDatabase(f.readAsBytesSync()).entries)
        pathKey(absolute(e.key)): e.value,
    };
  }
}

/// How crate tracks can be sorted in [sortCrate].
const crateSorts = {
  'artist': 'Artist',
  'title': 'Title',
  'bpm': 'BPM',
  'key': 'Key (Camelot)',
  'genre': 'Genre',
  'year': 'Year',
  'energy': 'Energy',
};

/// [paths] (Serato's form) in the order [by], using what the catalogue knows
/// about each track. Unknown tracks keep their order at the end.
List<String> sortCratePaths(
  Catalogue cat,
  SeratoLibrary lib,
  List<String> paths,
  String by, {
  bool descending = false,
}) {
  final rows = <String, TrackRow>{};
  final library = LibraryService(cat);
  for (final x in paths) {
    final r = cat.db.select('SELECT id FROM tracks WHERE path_key=?', [
      pathKey(lib.absolute(x)),
    ]);
    if (r.isEmpty) continue;
    final row = library.row(r.first['id'] as int);
    if (row != null) rows[x] = row;
  }
  Comparable<Object>? keyOf(TrackRow r) => switch (by) {
    'artist' => fold(r.artist ?? ''),
    'title' => fold(r.title ?? ''),
    'bpm' => r.bpm,
    'key' => camelotSortKey(r.key),
    'genre' => fold(r.genre ?? ''),
    'year' => r.year,
    'energy' => r.energy,
    _ => null,
  };
  final known = [
    for (final x in paths)
      if (rows[x] != null && keyOf(rows[x]!) != null) x,
  ];
  final rest = [
    for (final x in paths)
      if (!known.contains(x)) x,
  ];
  known.sort((a, b) {
    final c = keyOf(rows[a]!)!.compareTo(keyOf(rows[b]!)!);
    return descending ? -c : c;
  });
  return [...known, ...rest];
}

/// "8A" → 15 (number × 2 − 1 for A), so keys sort round the Camelot wheel.
int? camelotSortKey(String? key) {
  final k = key == null ? null : normalizeKey(key);
  if (k == null) return null;
  final n = int.tryParse(k.substring(0, k.length - 1));
  if (n == null) return null;
  return n * 2 - (k.endsWith('A') ? 1 : 0);
}

/// Reads Serato's own BPM and key for [ids] (all present tracks when null)
/// and puts them into the catalogue (field `bpm` / `key`), recorded as
/// automatic changes from "Serato" so they show under Changes and can be
/// undone. Sources, best first: Serato's library database, then the
/// "Serato Autotags" Serato writes into the file (read only for tracks still
/// missing a BPM or key), then the file's BPM/key tags. Returns (tracks updated, tracks Serato hasn't analysed).
(int, int) syncSeratoAnalysis(
  Catalogue cat,
  List<String> seratoDirs, {
  List<int>? ids,
  void Function(int done, int total)? progress,
}) {
  final db = <String, SeratoValues>{};
  for (final d in seratoDirs) {
    try {
      db.addAll(SeratoLibrary(d).databaseValues());
    } on Object {
      // unreadable library: the file tags still count
    }
  }
  final rows = cat.db.select(
    'SELECT t.id, t.path, t.path_key, t.bpm_tag, t.key_tag, '
    'COALESCE(u.bpm, t.bpm_tag) AS bpm, keynorm(COALESCE(u.musical_key, t.key_tag)) AS k '
    'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
    "WHERE t.presence='present' AND t.media_kind IS NOT 'video'"
    '${ids == null ? '' : ' AND t.id IN (${ids.isEmpty ? '0' : ids.join(',')})'}',
  );
  final sugg = SuggestionsService(cat);
  var updated = 0, unanalysed = 0, i = 0;
  for (final r in rows) {
    progress?.call(i++, rows.length);
    final id = r['id'] as int;
    var v = db[r['path_key'] as String];
    if (v == null || v.bpm == null || v.key == null) {
      double? bpm = v?.bpm;
      String? key = v?.key;
      // Serato's own tags in the file are only read when the catalogue
      // still lacks a BPM or key: reading 35,000 files to confirm values
      // the library already has is what made this step slow.
      if (bpm == null && (r['bpm'] == null || r['k'] == null)) {
        try {
          bpm = readSeratoAnalysis(r['path'] as String).bpm;
        } on Object {
          // unreadable now
        }
      }
      bpm ??= (r['bpm_tag'] as num?)?.toDouble();
      final kt = r['key_tag'] as String?;
      key ??= kt == null ? null : normalizeKey(kt);
      v = (bpm == null && key == null)
          ? null
          : SeratoValues(
              bpm: bpm,
              key: key,
              source: v?.source ?? 'Serato tags',
            );
    }
    if (v == null) {
      unanalysed++;
      continue;
    }
    final cur = (r['bpm'] as num?)?.toDouble();
    var changed = false;
    void apply(String field, String? current, String value) {
      insertSuggestion(
        cat,
        id,
        field,
        current,
        value,
        'Serato',
        'From ${v!.source}: Serato DJ analysed this track as $value.',
        1.0,
      );
      final s = cat.db.select(
        "SELECT id FROM suggestions WHERE track_id=? AND field=? AND suggested_value=? AND source='Serato' AND status='pending'",
        [id, field, value],
      );
      if (s.isNotEmpty) {
        sugg.accept(s.first['id'] as int, by: 'auto');
        changed = true;
      }
    }

    if (v.bpm != null) {
      final b = (v.bpm! * 100).round() / 100;
      if (cur == null || (cur - b).abs() > 0.05) {
        apply('bpm', cur == null ? null : rustNumber(cur), rustNumber(b));
      }
    }
    final k = r['k'] as String?;
    if (v.key != null && k != v.key) apply('key', k, v.key!);
    if (changed) updated++;
  }
  return (updated, unanalysed);
}
