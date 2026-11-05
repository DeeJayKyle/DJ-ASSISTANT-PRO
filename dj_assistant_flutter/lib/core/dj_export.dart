import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'crates.dart';
import 'gigpack.dart';
import 'jobs.dart';
import 'keys.dart';
import 'library.dart';
import 'library_edit.dart';
import 'organize.dart';

/// Crates to other DJ software (1.x `dj_export.rs`).
///
/// * Serato: one new `.crate` file per crate in `_Serato_/Subcrates`; an existing
///   crate file is never overwritten (" (DJ Assistant)" is added instead).
/// * rekordbox: a new rekordbox XML with a playlist per crate, folders kept.
/// * Folders: each crate copied into its own folder, verified like a gig pack.
class DjExportException implements Exception {
  DjExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw DjExportException(m);

class _Node {
  _Node(this.id, this.name, this.parent);
  final int id;
  final String name;
  final int? parent;
}

class DjExportService {
  DjExportService(this.cat);
  final Catalogue cat;

  List<_Node> _all() => [
    for (final r in cat.db.select(
      'SELECT id, name, parent_id FROM crates ORDER BY sort_order, id',
    ))
      _Node(r['id'] as int, r['name'] as String, r['parent_id'] as int?),
  ];

  List<int> _members(int crateId) => LibraryService(cat).trackIds(
    TrackQuery(extraWhere: CratesService(cat).membership(crateId)),
    max: 50000,
  );

  /// The chosen crates plus everything nested inside them.
  List<int> _selection(List<_Node> all, List<int>? ids) {
    if (ids == null) return [for (final c in all) c.id];
    final out = [...ids];
    for (var i = 0; i < out.length; i++) {
      for (final c in all.where((c) => c.parent == out[i])) {
        if (!out.contains(c.id)) out.add(c.id);
      }
    }
    return out;
  }

  List<String> _chain(List<_Node> all, int id) {
    final names = <String>[];
    _Node? cur = all.where((c) => c.id == id).firstOrNull;
    var guard = 0;
    while (cur != null && guard++ <= 32) {
      names.add(cur.name);
      final parent = cur.parent;
      cur = parent == null
          ? null
          : all.where((x) => x.id == parent).firstOrNull;
    }
    return names.reversed.toList();
  }

  // ------------------------------------------------------------ Serato

  static List<int> _chunk(String tag, List<int> data) => [
    ...tag.codeUnits,
    data.length >> 24 & 0xFF,
    data.length >> 16 & 0xFF,
    data.length >> 8 & 0xFF,
    data.length & 0xFF,
    ...data,
  ];
  static List<int> _u16be(String s) => [
    for (final u in s.codeUnits) ...[u >> 8, u & 0xFF],
  ];

  /// A Serato crate file listing [paths] (relative to the drive root, "/").
  static Uint8List seratoCrateBytes(List<String> paths) => Uint8List.fromList([
    ..._chunk('vrsn', _u16be('1.0/Serato ScratchLive Crate')),
    ..._chunk('osrt', [
      ..._chunk('tvcn', _u16be('song')),
      ..._chunk('brev', [0]),
    ]),
    for (final col in ['song', 'artist', 'bpm', 'key', 'length', 'genre'])
      ..._chunk('ovct', [
        ..._chunk('tvcn', _u16be(col)),
        ..._chunk('tvcw', _u16be('0')),
      ]),
    for (final path in paths) ..._chunk('otrk', _chunk('ptrk', _u16be(path))),
  ]);

  static String _volume(String path) {
    final abs = p.absolute(path);
    if (Platform.isWindows) return p.rootPrefix(abs).toUpperCase();
    return p.rootPrefix(abs);
  }

  static String _seratoRel(String path) =>
      p.split(p.absolute(path)).skip(1).join('/');

  Map<String, Object?> exportSerato(String seratoDir, {List<int>? crateIds}) {
    if (p.basename(seratoDir).toLowerCase() != '_serato_') {
      _no(
        "Choose Serato's _Serato_ folder (in your Music folder, or at the top of an external drive).",
      );
    }
    if (!Directory(seratoDir).existsSync()) {
      _no("That _Serato_ folder doesn't exist.");
    }
    final sub = Directory(p.join(seratoDir, 'Subcrates'))
      ..createSync(recursive: true);
    final vol = _volume(seratoDir);
    final all = _all();
    final written = <Map<String, Object?>>[];
    var skipped = 0;
    for (final id in _selection(all, crateIds)) {
      final c = all.firstWhere((c) => c.id == id);
      final ids = _members(id);
      if (ids.isEmpty && all.any((x) => x.parent == id)) {
        continue; // only groups sub-crates
      }
      final paths = <String>[];
      for (final tid in ids) {
        final r = cat.db.select(
          "SELECT path FROM tracks WHERE id=? AND presence='present'",
          [tid],
        );
        if (r.isEmpty) continue;
        final path = r.first['path'] as String;
        if (_volume(path) != vol) {
          skipped++;
          continue;
        }
        paths.add(_seratoRel(path));
      }
      // Serato nests crates with "%%" in the file name.
      final base = _chain(
        all,
        id,
      ).map((n) => sanitizeName(n.replaceAll('%%', '%'))).join('%%');
      var file = p.join(sub.path, '$base.crate');
      var n = 1;
      while (File(file).existsSync()) {
        file = p.join(
          sub.path,
          n == 1
              ? '$base (DJ Assistant).crate'
              : '$base (DJ Assistant $n).crate',
        );
        n++;
      }
      final tmp = '$file.djassistant-tmp';
      File(tmp).writeAsBytesSync(seratoCrateBytes(paths), flush: true);
      File(tmp).renameSync(file);
      written.add({
        'crate': c.name,
        'file': p.basename(file),
        'tracks': paths.length,
      });
    }
    return {
      'written': written,
      'skipped_other_drive': skipped,
      'note': "Start Serato to see the crates. Tracks on other drives belong in that drive's own _Serato_ folder.",
    };
  }

  // --------------------------------------------------------- rekordbox

  static String _x(String s) {
    final b = StringBuffer();
    for (final r in s.runes) {
      if (r < 0x20 && r != 9) continue;
      b.write(switch (r) {
        0x26 => '&amp;',
        0x3C => '&lt;',
        0x3E => '&gt;',
        0x22 => '&quot;',
        0x27 => '&apos;',
        _ => String.fromCharCode(r),
      });
    }
    return b.toString();
  }

  /// file://localhost/C:/Music/My%20Track.mp3
  static String fileUrl(String path) {
    final s = path.replaceAll(r'\', '/');
    final b = StringBuffer('file://localhost');
    if (!s.startsWith('/')) b.write('/');
    for (final byte in Uint8List.fromList(
      s.codeUnits.any((c) => c > 127) ? _utf8(s) : s.codeUnits,
    )) {
      final c = String.fromCharCode(byte);
      if (RegExp(r'[A-Za-z0-9/\-_.~:]').hasMatch(c)) {
        b.write(c);
      } else {
        b.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return b.toString();
  }

  static List<int> _utf8(String s) => utf8.encode(s);

  Map<String, Object?> exportRekordbox(
    String dest, {
    List<int>? crateIds,
    String version = '2.0',
  }) {
    if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
      _no('A file with that name already exists; choose a new name.');
    }
    if (p.extension(dest).toLowerCase() != '.xml') {
      _no('the rekordbox file must end in .xml');
    }
    final all = _all();
    final sel = _selection(all, crateIds);
    final trackIds = <int>[];
    final members = <int, List<int>>{};
    for (final id in sel) {
      final ids = _members(id);
      for (final t in ids) {
        if (!trackIds.contains(t)) trackIds.add(t);
      }
      members[id] = ids;
    }
    final xml =
        StringBuffer(
          '<?xml version="1.0" encoding="UTF-8"?>\n<DJ_PLAYLISTS Version="1.0.0">\n',
        )..write(
          '  <PRODUCT Name="DJ Assistant" Version="${_x(version)}" Company="DJ Assistant"/>\n',
        );
    final tracks = StringBuffer();
    final exported = <int>[];
    for (var i = 0; i < trackIds.length; i++) {
      final rows = cat.db.select(
        'SELECT t.path, COALESCE(u.title, t.title, t.file_name) AS title, COALESCE(u.artist, t.artist) AS artist, '
        'COALESCE(u.album, t.album) AS album, COALESCE(u.genre, t.genre) AS genre, COALESCE(u.year, t.year) AS year, '
        'COALESCE(u.bpm, t.bpm_tag, a.bpm) AS bpm, keynorm(COALESCE(u.musical_key, t.key_tag, a.camelot)) AS key, u.rating, '
        't.duration_ms, t.file_size, t.bitrate_kbps, t.sample_rate, t.format, u.notes, t.presence '
        'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
        [trackIds[i]],
      );
      if (rows.isEmpty || rows.first['presence'] != 'present') continue;
      final r = rows.first;
      final key = r['key'] as String?;
      final tonality = key == null ? '' : (musicalName(key) ?? key);
      final kind =
          '${((r['format'] as String?) ?? 'Audio').split(' ').first} File';
      final bpm = r['bpm'] as num?;
      tracks.write(
        '    <TRACK TrackID="${i + 1}" Name="${_x((r['title'] as String?) ?? '')}" Artist="${_x((r['artist'] as String?) ?? '')}" '
        'Album="${_x((r['album'] as String?) ?? '')}" Genre="${_x((r['genre'] as String?) ?? '')}" Kind="${_x(kind)}" '
        'Size="${r['file_size']}" TotalTime="${((r['duration_ms'] as int?) ?? 0) ~/ 1000}" Year="${r['year'] ?? ''}" '
        'AverageBpm="${bpm == null ? '0.00' : bpm.toStringAsFixed(2)}" BitRate="${r['bitrate_kbps'] ?? 0}" '
        'SampleRate="${r['sample_rate'] ?? 0}" Comments="${_x((r['notes'] as String?) ?? '')}" '
        'Rating="${((r['rating'] as int?) ?? 0).clamp(0, 5) * 51}" Tonality="${_x(tonality)}" '
        'Location="${_x(fileUrl(r['path'] as String))}"/>\n',
      );
      exported.add(trackIds[i]);
    }
    xml.write(
      '  <COLLECTION Entries="${exported.length}">\n$tracks  </COLLECTION>\n',
    );
    int? idx(int t) {
      final i = exported.indexOf(t);
      return i < 0 ? null : i + 1;
    }

    String playlist(String pad, String name, List<int> ids) {
      final keys = ids.map(idx).whereType<int>().toList();
      final s = StringBuffer(
        '$pad<NODE Name="${_x(name)}" Type="1" KeyType="0" Entries="${keys.length}">\n',
      );
      for (final k in keys) {
        s.write('$pad  <TRACK Key="$k"/>\n');
      }
      return (s..write('$pad</NODE>\n')).toString();
    }

    String node(int id, int depth) {
      final c = all.firstWhere((c) => c.id == id);
      final pad = '  ' * (depth + 3);
      final kids = [
        for (final x in all)
          if (x.parent == id && sel.contains(x.id)) x.id,
      ];
      final own = (members[id] ?? const []).isNotEmpty;
      if (kids.isEmpty) return playlist(pad, c.name, members[id] ?? const []);
      final s = StringBuffer(
        '$pad<NODE Type="0" Name="${_x(c.name)}" Count="${kids.length + (own ? 1 : 0)}">\n',
      );
      if (own) s.write(playlist('$pad  ', c.name, members[id]!));
      for (final k in kids) {
        s.write(node(k, depth + 1));
      }
      return (s..write('$pad</NODE>\n')).toString();
    }

    final tops = sel.where((id) {
      final parent = all.firstWhere((c) => c.id == id).parent;
      return parent == null || !sel.contains(parent);
    }).toList();
    xml.write(
      '  <PLAYLISTS>\n    <NODE Type="0" Name="ROOT" Count="${tops.length}">\n',
    );
    for (final id in tops) {
      xml.write(node(id, 0));
    }
    xml.write('    </NODE>\n  </PLAYLISTS>\n</DJ_PLAYLISTS>\n');
    // Never replaces a file, even one created a moment ago.
    final f = File(dest).openSync(mode: FileMode.writeOnlyAppend);
    try {
      if (f.lengthSync() != 0) {
        _no('A file with that name already exists; choose a new name.');
      }
      f.writeStringSync(xml.toString());
      f.flushSync();
    } finally {
      f.closeSync();
    }
    return {
      'file': dest,
      'tracks': exported.length,
      'playlists': sel.length,
      'note': 'In rekordbox: Preferences → Advanced → Database → rekordbox xml → choose this file, then open "rekordbox xml" in the tree and import the playlists.',
    };
  }

  // ------------------------------------------------------------ folders

  /// Copies each crate into its own folder under [dest] (crate folders become
  /// real folders), verified like a gig pack. Existing folders are skipped.
  Future<List<Map<String, Object?>>> exportFolders(
    String dest, {
    List<int>? crateIds,
    JobContext? ctx,
  }) async {
    final all = _all();
    final report = <Map<String, Object?>>[];
    final packs = GigPackService(cat);
    for (final id in _selection(all, crateIds)) {
      if (ctx != null && await ctx.checkpoint()) break;
      final c = all.firstWhere((c) => c.id == id);
      final ids = _members(id);
      if (ids.isEmpty) continue;
      final names = _chain(all, id);
      var parent = dest;
      for (final n in names.sublist(0, names.length - 1)) {
        parent = p.join(parent, sanitizeName(n));
      }
      Directory(parent).createSync(recursive: true);
      if (ctx != null) ctx.message = 'Copying “${c.name}”…';
      try {
        final plan = packs.preview(ids, parent, c.name);
        if (FileSystemEntity.typeSync(plan.packDir) !=
            FileSystemEntityType.notFound) {
          report.add({
            'crate': c.name,
            'skipped': '${plan.packDir} already exists',
          });
        } else if (!plan.fits) {
          report.add({'crate': c.name, 'skipped': 'not enough free space'});
        } else {
          await packs.execute(plan, ctx: ctx);
          report.add({
            'crate': c.name,
            'folder': plan.packDir,
            'files': plan.files.length,
          });
        }
      } on GigPackException catch (e) {
        report.add({'crate': c.name, 'skipped': e.message});
      }
    }
    if (ctx != null) {
      ctx
        ..message =
            'Exported ${report.where((r) => r.containsKey('folder')).length} crate(s).'
        ..result = {'crates': report};
    }
    return report;
  }
}
