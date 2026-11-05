import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'crates.dart';
import 'paths.dart';
import 'profile.dart';
import 'text.dart';

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

/// Track paths listed in a Serato crate file; unknown chunks are skipped and
/// malformed data simply ends parsing.
List<String> parseSeratoCrate(Uint8List bytes) {
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
      } else if (tag == 'ptrk') {
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
        ciTime = col(['start time', 'start', 'date', 'time', 'played']);
    final index = <String, int>{
      for (final t in loadProfiles(cat))
        '${baseArtist(t.artist)}|${baseTitle(t.title)}|${t.version ?? versionOf(t.title)}':
            t.id,
    };
    var matched = 0, unmatched = 0;
    final now = nowMs();
    for (final l in lines.skip(1)) {
      final f = _splitCsv(l);
      final title = ciTitle < f.length ? f[ciTitle] : '';
      if (title.isEmpty) continue;
      final artist = ciArtist != null && ciArtist < f.length ? f[ciArtist] : '';
      final played = ciTime != null && ciTime < f.length ? f[ciTime] : null;
      final id =
          index['${baseArtist(artist)}|${baseTitle(title)}|${versionOf(title)}'];
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
    return {'matched': matched, 'unmatched': unmatched};
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
