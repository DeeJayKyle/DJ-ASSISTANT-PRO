import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

import 'catalogue.dart';
import 'crates.dart';
import 'paths.dart';
import 'profile.dart';
import 'text.dart';
import 'track_match.dart';

/// Read-only Serato import (1.x `serato.rs`): `_Serato_/Subcrates/*.crate` files
/// are parsed defensively and copied in as virtual crates; Serato's history CSV
/// exports become play history. Serato's files are only read.
const _maxCrateBytes = 64 * 1024 * 1024;

class SeratoException implements Exception {
  SeratoException(this.message);
  final String message;
  @override
  String toString() => message;
}

String _utf16be(Uint8List b) {
  final units = <int>[
    for (var i = 0; i + 1 < b.length; i += 2) (b[i] << 8) | b[i + 1],
  ];
  return String.fromCharCodes(units).replaceFirst(RegExp('\u0000+\$'), '');
}

/// Track paths listed in a Serato crate file (`ptrk`) or, with [tag] `pfil`, in
/// Serato's library file `database V2`; unknown chunks are skipped and
/// malformed data simply ends parsing.
List<String> parseSeratoCrate(Uint8List bytes, {String tag = 'ptrk'}) {
  final want = tag;
  final out = <String>[];
  void walk(Uint8List b, int depth) {
    var i = 0;
    while (i + 8 <= b.length) {
      final tag = String.fromCharCodes(b.sublist(i, i + 4));
      final len =
          (b[i + 4] << 24) | (b[i + 5] << 16) | (b[i + 6] << 8) | b[i + 7];
      final start = i + 8, end = start + len;
      if (end > b.length) break;
      final data = Uint8List.sublistView(b, start, end);
      if (tag == 'otrk' && depth < 3) {
        walk(data, depth + 1);
      } else if (tag == want) {
        final s = _utf16be(data);
        if (s.isNotEmpty) out.add(s);
      }
      i = end;
    }
  }

  walk(bytes, 0);
  return out;
}

List<String> _splitCsv(String line) {
  final out = <String>[];
  final cur = StringBuffer();
  var q = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"' && q && i + 1 < line.length && line[i + 1] == '"') {
      cur.write('"');
      i++;
    } else if (c == '"') {
      q = !q;
    } else if (c == ',' && !q) {
      out.add(cur.toString());
      cur.clear();
    } else {
      cur.write(c);
    }
  }
  out.add(cur.toString());
  return [for (final s in out) s.trim()];
}

class SeratoService {
  SeratoService(this.cat);
  final Catalogue cat;

  Map<String, Object?> importCrates(String seratoDir) {
    final sub = Directory(p.join(seratoDir, 'Subcrates'));
    if (!sub.existsSync()) {
      throw SeratoException(
        'That folder has no Subcrates folder. Choose the _Serato_ folder (usually in your Music folder or at the top of an external drive).',
      );
    }
    final root = p.rootPrefix(p.absolute(seratoDir));
    final index = {
      for (final r in cat.db.select('SELECT path_key, id FROM tracks'))
        r['path_key'] as String: r['id'] as int,
    };
    int? find(String name, int? parent) {
      final r = cat.db.select(
        'SELECT id FROM crates WHERE name=? AND parent_id IS ?',
        [name, parent],
      );
      return r.isEmpty ? null : r.first['id'] as int;
    }

    final crates = CratesService(cat);
    final topName = String.fromCharCodes(
      'Serato import ($seratoDir)'.runes.take(120),
    );
    final top =
        find(topName, null) ??
        crates
            .create(
              CrateInput(
                name: topName,
                kind: 'manual',
                color: 'purple',
                category: 'Imported',
              ),
            )
            .id;
    final files =
        sub
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.crate'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final report = <Map<String, Object?>>[];
    for (final f in files) {
      if (f.lengthSync() > _maxCrateBytes) {
        report.add({'crate': p.basename(f.path), 'error': 'file too large'});
        continue;
      }
      final paths = parseSeratoCrate(f.readAsBytesSync());
      final stem = p.basenameWithoutExtension(f.path);
      int? parent = top;
      for (final part
          in stem.split('%%').map((s) => s.trim()).where((s) => s.isNotEmpty)) {
        final name = String.fromCharCodes(part.runes.take(120));
        parent =
            find(name, parent) ??
            crates
                .create(
                  CrateInput(name: name, kind: 'manual', parentId: parent),
                )
                .id;
      }
      final matched = <int>[], unmatched = <String>[];
      for (final x in paths) {
        final full = p.isAbsolute(x) ? x : p.join(root, x);
        final id = index[pathKey(p.normalize(full))];
        if (id != null) {
          matched.add(id);
        } else {
          unmatched.add(x);
        }
      }
      crates.addTracks(parent ?? top, matched);
      report.add({
        'crate': stem.replaceAll('%%', ' / '),
        'tracks': paths.length,
        'matched': matched.length,
        'unmatched': unmatched.length,
        'unmatched_sample': unmatched.take(5).toList(),
      });
    }
    return {
      'parent_id': top,
      'crates': report,
      'note': "Serato's files were only read. Tracks not in your DJ Assistant library (or on a drive that is not added) are listed as unmatched.",
    };
  }

  /// Imports a history CSV (Serato's Export or any CSV with artist/title columns).
  Map<String, int> importHistoryCsv(String text, String session) {
    if (text.length > 20000000) throw SeratoException('file is too large');
    final lines = text
        .split(RegExp(r'\r?\n'))
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final header = lines.isEmpty ? <String>[] : _splitCsv(lines.first);
    int? col(List<String> names) {
      final i = header.indexWhere((h) => names.contains(fold(h)));
      return i < 0 ? null : i;
    }

    final ciTitle = col(['name', 'title', 'song', 'track']);
    if (ciTitle == null) {
      throw SeratoException('Could not find a title/name column in this CSV.');
    }
    final ciArtist = col(['artist']),
        ciTime = col(['start time', 'start', 'date', 'time', 'played']),
        ciPath = col(['location', 'file', 'path', 'filename', 'file name']),
        ciLength = col(['length', 'duration', 'time length']);
    final index = <String, int>{
      for (final t in loadProfiles(cat))
        '${t.artistKey}|${t.titleKey}|${t.version ?? versionOf(t.title)}': t.id,
    };
    // fallback when the version-aware key misses: file path or name, then
    // artist + title, then a likely match on title and artists
    final matcher = libraryMatcher(cat);
    String? field(int? i, List<String> f) =>
        i != null && i < f.length && f[i].isNotEmpty ? f[i] : null;
    var matched = 0, unmatched = 0, likely = 0;
    final now = nowMs();
    for (final l in lines.skip(1)) {
      final f = _splitCsv(l);
      final title = ciTitle < f.length ? f[ciTitle] : '';
      if (title.isEmpty) continue;
      final artist = ciArtist != null && ciArtist < f.length ? f[ciArtist] : '';
      final played = ciTime != null && ciTime < f.length ? f[ciTime] : null;
      var id =
          index['${baseArtist(artist)}|${baseTitle(title)}|${versionOf(title)}'];
      if (id == null) {
        final m = matcher.match(
          MatchEntry(
            path: field(ciPath, f),
            artist: artist,
            title: title,
            durationSec: parseLength(field(ciLength, f)),
          ),
        );
        id = m?.trackId;
        if (m != null && !m.sure) likely++;
      }
      if (id != null) {
        matched++;
      } else {
        unmatched++;
      }
      cat.db.execute(
        "INSERT INTO play_history(source, session, track_id, artist, title, played_at, imported_at) VALUES ('csv', ?, ?, ?, ?, NULL, ?)",
        [
          '$session${played == null ? '' : ' @ $played'}',
          id,
          artist,
          title,
          now,
        ],
      );
    }
    return {'matched': matched, 'unmatched': unmatched, 'likely': likely};
  }

  /// Where Serato DJ 4 keeps its library database (with play history) on
  /// this computer, or null when there is none.
  static String? defaultLibraryDb() {
    final env = Platform.environment;
    final dir = Platform.isWindows
        ? p.join(env['APPDATA'] ?? '', 'Serato', 'Library')
        : p.join(
            env['HOME'] ?? '',
            'Library',
            'Application Support',
            'Serato',
            'Library',
          );
    final f = File(p.join(dir, 'master.sqlite'));
    return f.existsSync() ? f.path : null;
  }

  /// Imports the play history Serato DJ 4 keeps in its library database
  /// (`Serato/Library/master.sqlite`). The database is copied to a temporary
  /// folder and the copy is read, so Serato's file is never opened for
  /// writing, even while Serato runs. Sessions already imported are skipped.
  Map<String, int> importSeratoDbHistory(String dbPath) {
    final src = File(dbPath);
    if (!src.existsSync()) {
      throw SeratoException('Serato library database not found.');
    }
    final tmp = Directory.systemTemp.createTempSync('dja-serato-history-');
    try {
      final copy = p.join(tmp.path, 'master.sqlite');
      src.copySync(copy);
      for (final side in ['-wal', '-shm']) {
        final f = File('$dbPath$side');
        if (f.existsSync()) f.copySync('$copy$side');
      }
      final sql.Database db;
      try {
        db = sql.sqlite3.open(copy);
      } on sql.SqliteException {
        throw SeratoException(
          'This is not a readable Serato library database.',
        );
      }
      try {
        Set<String> cols(String table) => {
          for (final r in db.select('PRAGMA table_info("$table")'))
            r['name'] as String,
        };
        final ec = cols('history_entry'), sc = cols('history_session');
        if (ec.isEmpty || sc.isEmpty || !ec.contains('session_id')) {
          throw SeratoException(
            'This Serato database has no play history (Serato DJ 4 or later keeps it there).',
          );
        }
        String col(Set<String> have, String name) =>
            have.contains(name) ? name : 'NULL';
        final sessions = db.select(
          'SELECT id, ${col(sc, 'start_time')} AS start FROM history_session ORDER BY id',
        );
        final done = {
          for (final r in cat.db.select(
            "SELECT DISTINCT session FROM play_history WHERE source='serato'",
          ))
            r['session'] as String?,
        };
        final matcher = libraryMatcher(cat);
        var imported = 0, matched = 0, unmatched = 0, skipped = 0;
        final now = nowMs();
        int? ms(Object? v) {
          final n = (v as num?)?.toInt();
          if (n == null || n <= 0) return null;
          return n > 100000000000 ? n : n * 1000; // seconds or milliseconds
        }

        for (final s in sessions) {
          final start = ms(s['start']);
          final when = start == null
              ? ''
              : ' · ${DateTime.fromMillisecondsSinceEpoch(start).toIso8601String().substring(0, 16).replaceFirst('T', ' ')}';
          final label = 'Serato session ${s['id']}$when';
          if (done.contains(label)) {
            skipped++;
            continue;
          }
          final rows = db.select(
            'SELECT ${col(ec, 'file_name')} AS file, ${col(ec, 'artist')} AS artist, '
            '${col(ec, 'name')} AS title, ${col(ec, 'start_time')} AS start, '
            '${col(ec, 'length_ms')} AS len, ${col(ec, 'played')} AS played '
            'FROM history_entry WHERE session_id=? ORDER BY ${col(ec, 'start_time')}, id',
            [s['id']],
          );
          var any = false;
          for (final r in rows) {
            if (r['played'] != null && r['played'] == 0) continue;
            final m = matcher.match(
              MatchEntry(
                path: r['file'] as String?,
                artist: r['artist'] as String?,
                title: r['title'] as String?,
                durationSec: (r['len'] as num?) == null
                    ? null
                    : (r['len'] as num) / 1000,
              ),
            );
            if (m == null) {
              unmatched++;
            } else {
              matched++;
            }
            cat.db.execute(
              "INSERT INTO play_history(source, session, track_id, artist, title, played_at, imported_at) VALUES ('serato', ?, ?, ?, ?, ?, ?)",
              [
                label,
                m?.trackId,
                r['artist'],
                (r['title'] as String?) ??
                    p.basename('${r['file'] ?? ''}'.replaceAll('\\', '/')),
                ms(r['start']),
                now,
              ],
            );
            any = true;
          }
          if (any) imported++;
        }
        return {
          'sessions': imported,
          'skipped': skipped,
          'matched': matched,
          'unmatched': unmatched,
        };
      } finally {
        db.close();
      }
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  /// Tracks Serato DJ 4 marked as played since [sinceMs], oldest first, from
  /// a temporary copy of its library database (used by Gig Mode's "Follow
  /// Serato"). Empty when the database has no history.
  List<SeratoPlay> seratoPlaysSince(String dbPath, int sinceMs) {
    final src = File(dbPath);
    if (!src.existsSync()) return const [];
    final tmp = Directory.systemTemp.createTempSync('dja-serato-follow-');
    try {
      final copy = p.join(tmp.path, 'master.sqlite');
      src.copySync(copy);
      for (final side in ['-wal', '-shm']) {
        final f = File('$dbPath$side');
        if (f.existsSync()) f.copySync('$copy$side');
      }
      final db = sql.sqlite3.open(copy);
      try {
        final cols = {
          for (final r in db.select('PRAGMA table_info("history_entry")'))
            r['name'] as String,
        };
        if (!cols.contains('start_time')) return const [];
        String col(String n) => cols.contains(n) ? n : 'NULL';
        // start_time is seconds in the databases seen so far; accept ms too
        final newest =
            (db
                        .select(
                          'SELECT MAX(start_time) AS m FROM history_entry',
                        )
                        .first['m']
                    as num?)
                ?.toInt() ??
            0;
        final inMs = newest > 100000000000;
        final rows = db.select(
          'SELECT ${col('file_name')} AS file, ${col('artist')} AS artist, '
          '${col('name')} AS title, start_time AS start, ${col('played')} AS played '
          'FROM history_entry WHERE start_time >= ? ORDER BY start_time, id',
          [inMs ? sinceMs : (sinceMs + 999) ~/ 1000],
        );
        return [
          for (final r in rows)
            if (r['played'] == null || r['played'] != 0)
              SeratoPlay(
                path: r['file'] as String?,
                artist: r['artist'] as String?,
                title: r['title'] as String?,
                atMs: () {
                  final n = (r['start'] as num).toInt();
                  return n > 100000000000 ? n : n * 1000;
                }(),
              ),
        ];
      } on sql.SqliteException {
        return const [];
      } finally {
        db.close();
      }
    } on FileSystemException {
      return const [];
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }

  List<Map<String, Object?>> history({int limit = 500}) => [
    for (final r in cat.db.select(
      'SELECT id, source, session, track_id, artist, title, imported_at FROM play_history ORDER BY id DESC LIMIT ?',
      [limit.clamp(1, 5000)],
    ))
      Map<String, Object?>.of(r),
  ];

  int clearHistory() {
    cat.db.execute('DELETE FROM play_history');
    return cat.db.updatedRows;
  }
}

class SeratoPlay {
  const SeratoPlay({this.path, this.artist, this.title, required this.atMs});
  final String? path, artist, title;
  final int atMs;
}
