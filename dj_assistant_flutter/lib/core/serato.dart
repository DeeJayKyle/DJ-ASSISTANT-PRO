import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'crates.dart';
import 'paths.dart';

/// Copies Serato's crates (`_Serato_/Subcrates/*.crate`, parsed defensively)
/// into the Crate builder, where rules and templates can reshape them.
/// Serato's files are only read here; serato_library.dart changes them.
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
}
