import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'blake3.dart';
import 'catalogue.dart';
import 'disk.dart';
import 'jobs.dart';
import 'keys.dart';
import 'paths.dart';
import 'safe_write.dart';

/// Gig packs (1.x `gigpack.rs`): copy approved tracks to a USB stick or drive,
/// verify every copy by hash, and write a manifest, playlists and a missing-file
/// report. Sources are only read; nothing in the destination is overwritten (the
/// pack is a new folder or a new ZIP, never inside a library folder). Quick Prep
/// uses the same copier with a layout and optional clean tags on the copies.
class GigPackException implements Exception {
  GigPackException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw GigPackException(m);

class PackFile {
  PackFile(
    this.n,
    this.trackId,
    this.artist,
    this.title,
    this.source,
    this.destName,
    this.relPath,
    this.size,
    this.durationS,
    this.problem,
    this.tags,
  );
  final int n, trackId, size;
  final String? artist, title, problem;
  final String source, destName, relPath;
  final int? durationS;
  final Map<String, String?>? tags;
  bool get available => problem == null;
}

class PackPlaylist {
  PackPlaylist(this.name, this.path, this.trackIds);
  final String name, path;
  final List<int> trackIds;
}

class PackItem {
  PackItem(this.trackId, {this.folder = '', this.name});
  final int trackId;
  final String folder;
  final String? name;
}

class PackOptions {
  const PackOptions({
    this.items,
    this.playlists,
    this.zip = false,
    this.writeTags = false,
  });
  final List<PackItem>? items;
  final List<PackPlaylist>? playlists;
  final bool zip, writeTags;
}

class PackPlan {
  PackPlan(
    this.packDir,
    this.files,
    this.totalBytes,
    this.freeBytes,
    this.fits,
    this.missing,
    this.warnings,
    this.playlists,
    this.zip,
    this.writeTags,
  );
  final String packDir;
  final List<PackFile> files;
  final int totalBytes, missing;
  final int? freeBytes;
  final bool fits, zip, writeTags;
  final List<String> warnings;
  final List<PackPlaylist> playlists;
}

const _bad = '<>:"/\\|?*';
bool _isBad(int r) =>
    r < 0x20 ||
    (r >= 0x7F && r <= 0x9F) ||
    _bad.contains(String.fromCharCode(r));

String _sanitize(String name) {
  var s = String.fromCharCodes(name.runes.map((r) => _isBad(r) ? 0x5F : r))
      .trim();
  s = s.replaceFirst(RegExp(r'\.+$'), '');
  if (s.isEmpty) return 'DJ Assistant pack';
  return String.fromCharCodes(s.runes.take(80));
}

String? _segment(String name, int max) {
  var s = String.fromCharCodes(name.runes.map((r) => _isBad(r) ? 0x20 : r));
  s = s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  s = s
      .replaceFirst(RegExp(r'[. ]+$'), '')
      .replaceFirst(RegExp(r'^\.+'), '')
      .trim();
  if (s.isEmpty) return null;
  s = String.fromCharCodes(s.runes.take(max)).trim();
  final stem = s.split('.').first.toUpperCase();
  if (['CON', 'PRN', 'AUX', 'NUL'].contains(stem) ||
      (stem.length == 4 &&
          (stem.startsWith('COM') || stem.startsWith('LPT')) &&
          RegExp(r'\d').hasMatch(stem[3]))) {
    s = '${s}_';
  }
  return s;
}

String _folderPath(String folder) => folder
    .split(RegExp(r'[/\\]'))
    .map((x) => _segment(x, 80))
    .whereType<String>()
    .join('/');

class GigPackService {
  GigPackService(this.cat);
  final Catalogue cat;

  Map<String, String?> _tagValues(int id) {
    final r = cat.db.select(
      'SELECT COALESCE(u.title,t.title,t.file_name) AS title, COALESCE(u.artist,t.artist) AS artist, COALESCE(u.genre,t.genre) AS genre, '
      'COALESCE(u.bpm,t.bpm_tag,a.bpm) AS bpm, keynorm(COALESCE(u.musical_key,t.key_tag,a.camelot)) AS cam, '
      'COALESCE(u.version_label,t.version_hint) AS ver, COALESCE(u.energy,a.energy) AS energy '
      'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
      [id],
    ).first;
    final musical = cat.getSetting('key_notation') == 'musical';
    final cam = r['cam'] as String?;
    final key = cam == null
        ? null
        : (musical ? (musicalName(cam) ?? cam) : cam);
    var title = r['title'] as String?;
    final ver = r['ver'] as String?;
    if (title != null &&
        ver != null &&
        !title.toLowerCase().contains(ver.toLowerCase())) {
      title = '$title ($ver)';
    }
    final bpm = r['bpm'] as num?, energy = r['energy'] as int?;
    final comment = [
      if (cam != null)
        musicalName(cam) != null ? '$cam (${musicalName(cam)})' : cam,
      if (bpm != null) '${bpm.round()} BPM',
      if (energy != null) 'Energy $energy',
    ].join(' · ');
    return {
      'artist': r['artist'] as String?,
      'bpm': bpm?.round().toString(),
      'comment': comment.isEmpty ? null : comment,
      'genre': r['genre'] as String?,
      'key': key,
      'title': title,
    };
  }

  PackPlan preview(
    List<int> ids,
    String dest,
    String name, {
    PackOptions opts = const PackOptions(),
  }) {
    final layout = opts.items == null
        ? null
        : {for (final i in opts.items!) i.trackId: i};
    final order = opts.items == null
        ? ids
        : [for (final i in opts.items!) i.trackId];
    if (order.isEmpty) _no('choose some tracks (a crate or a set) first');
    if (!Directory(dest).existsSync()) {
      _no('choose a destination folder or drive that exists');
    }
    final dkey = pathKey(dest);
    for (final r in cat.db.select('SELECT path FROM library_roots')) {
      if (keyIsWithin(dkey, pathKey(r['path'] as String))) {
        _no(
          'The destination is inside your library folder ${r['path']}. Choose a separate drive or folder so copies are not catalogued as duplicates.',
        );
      }
    }
    final base = _sanitize(name);
    final packDir = opts.zip ? p.join(dest, '$base.zip') : p.join(dest, base);
    final warnings = [
      'Serato cue points, loops and beatgrids stored inside MP3/M4A/FLAC tags travel with the copied files, but Serato crates and library links do not. This has not been tested with every Serato version — check on the gig laptop before you rely on it.',
    ];
    if (FileSystemEntity.typeSync(packDir) != FileSystemEntityType.notFound) {
      warnings.add(
        '“$packDir” already exists there; choose another name. Nothing will be overwritten.',
      );
    }
    final files = <PackFile>[];
    final used = <String>{}, seen = <int>{};
    var total = 0, missing = 0;
    for (var i = 0; i < order.length; i++) {
      final id = order[i];
      if (!seen.add(id)) continue;
      final rows = cat.db.select(
        "SELECT t.path, t.file_size, t.presence, COALESCE(u.artist,t.artist) AS artist, COALESCE(u.title,t.title) AS title, t.file_name, "
        "COALESCE(r.status,'unknown') AS rstatus, t.duration_ms, t.media_kind FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id "
        'LEFT JOIN library_roots r ON r.id=t.root_id WHERE t.id=?',
        [id],
      );
      if (rows.isEmpty) {
        missing++;
        continue;
      }
      final r = rows.first;
      final item = layout?[id];
      final folder = item == null ? 'Music' : _folderPath(item.folder);
      final fileName = r['file_name'] as String;
      final dot = fileName.lastIndexOf('.');
      final origStem = dot >= 0 ? fileName.substring(0, dot) : fileName;
      final ext = dot >= 0 ? fileName.substring(dot) : '';
      final stem =
          (item?.name == null ? null : _segment(item!.name!, 150)) ?? origStem;
      final prefix = folder.isEmpty ? '' : '$folder/';
      var destName = '$stem$ext';
      var k = 2;
      while (!used.add('$prefix$destName'.toLowerCase())) {
        destName = '$stem ($k)$ext';
        k++;
      }
      final src = r['path'] as String;
      final String? problem;
      if (r['presence'] != 'present') {
        problem = 'missing from library';
      } else if (r['rstatus'] == 'offline' || !File(src).existsSync()) {
        problem = 'drive offline or file not found';
      } else {
        problem = null;
      }
      final size = r['file_size'] as int;
      if (problem != null) {
        missing++;
      } else {
        total += size;
      }
      final taggable =
          opts.writeTags &&
          r['media_kind'] != 'video' &&
          ['.mp3', '.flac', '.m4a'].contains(ext.toLowerCase());
      final dur = r['duration_ms'] as int?;
      files.add(
        PackFile(
          i + 1,
          id,
          r['artist'] as String?,
          r['title'] as String?,
          src,
          destName,
          '$prefix$destName',
          size,
          dur == null ? null : (dur + 500) ~/ 1000,
          problem,
          taggable ? _tagValues(id) : null,
        ),
      );
    }
    final playlists = opts.playlists == null
        ? [
            PackPlaylist(base, 'playlist.m3u8', [
              for (final f in files) f.trackId,
            ]),
          ]
        : [
            for (final pl in opts.playlists!.where(
              (x) => x.trackIds.isNotEmpty,
            ))
              PackPlaylist(
                String.fromCharCodes(pl.name.trim().runes.take(120)),
                '${_folderPath(pl.path.replaceFirst(RegExp(r'\.m3u8$'), '')).isEmpty ? 'playlist' : _folderPath(pl.path.replaceFirst(RegExp(r'\.m3u8$'), ''))}.m3u8',
                pl.trackIds,
              ),
          ];
    final free = freeBytes(dest);
    // Tagged copies can grow a little; ZIPs add headers.
    final need = total + 5 * 1024 * 1024 + files.length * 64 * 1024;
    final fits = free != null && need <= free;
    if (!fits) {
      warnings.add(
        free == null
            ? 'Free space on the destination could not be determined.'
            : 'Not enough free space: the pack needs ${need ~/ 1048576} MB, ${free ~/ 1048576} MB available.',
      );
    }
    if (opts.writeTags && files.any((f) => f.tags == null && f.available)) {
      warnings.add(
        'Clean tags are written into MP3, FLAC and M4A copies; other formats are copied unchanged.',
      );
    }
    return PackPlan(
      packDir,
      files,
      total,
      free,
      fits,
      missing,
      warnings,
      playlists,
      opts.zip,
      opts.writeTags,
    );
  }

  /// A verified, byte-identical copy into a new file; returns its hash.
  static String _verifiedCopy(String src, String dst) {
    if (FileSystemEntity.typeSync(dst) != FileSystemEntityType.notFound) {
      _no('$dst already exists');
    }
    File(dst).parent.createSync(recursive: true);
    File(src).copySync(dst);
    final a = blake3File(src), b = blake3File(dst);
    if (a == null || a != b) {
      File(dst).deleteSync();
      _no('copy did not verify (hash mismatch)');
    }
    return a;
  }

  static String _relative(String fromPlaylist, String to) {
    final from = fromPlaylist.split('/');
    final fromDir = from.sublist(0, from.length - 1);
    final toParts = to.split('/');
    var i = 0;
    while (i < fromDir.length &&
        i + 1 < toParts.length &&
        fromDir[i] == toParts[i]) {
      i++;
    }
    return [
      ...List.filled(fromDir.length - i, '..'),
      ...toParts.sublist(i),
    ].join('/');
  }

  static String _m3u8(PackPlaylist pl, Map<int, Map<String, Object?>> done) {
    final s = StringBuffer(
      '#EXTM3U\r\n#PLAYLIST:${pl.name.replaceAll(RegExp(r'[\r\n]'), ' ')}\r\n',
    );
    for (final id in pl.trackIds) {
      final m = done[id];
      if (m == null) continue;
      final a = m['artist'] as String?, t = m['title'] as String?;
      final label = (a != null && a.isNotEmpty && t != null)
          ? '$a - $t'
          : (t ?? '');
      s.write(
        '#EXTINF:${m['duration_s'] ?? -1},${label.replaceAll(RegExp(r'[\r\n]'), ' ')}\r\n',
      );
      s.write(
        '${_relative(pl.path, m['file'] as String).replaceAll('/', Platform.pathSeparator)}\r\n',
      );
    }
    return s.toString();
  }

  /// Copies and verifies. Re-checks the plan so nothing is overwritten.
  Future<Map<String, Object?>> execute(
    PackPlan plan, {
    JobContext? ctx,
    String appVersion = '2.0',
  }) async {
    final pack = plan.packDir;
    if (FileSystemEntity.typeSync(pack) != FileSystemEntityType.notFound) {
      _no('the pack folder already exists; nothing was copied');
    }
    if (!plan.fits) _no('not enough free space; nothing was copied');
    final todo = plan.files.where((f) => f.available).toList();
    if (ctx != null) ctx.total = todo.length;
    final manifest = <Map<String, Object?>>[];
    final failures = <String>[];
    var tagged = 0;
    // A ZIP is built from a staging folder next to it, then verified entry by entry.
    final stage = plan.zip ? '$pack.tmp' : pack;
    if (plan.zip &&
        FileSystemEntity.typeSync(stage) != FileSystemEntityType.notFound) {
      _no(
        'a previous copy left a temporary folder next to the ZIP; remove it and try again',
      );
    }
    Directory(stage).createSync(recursive: true);
    for (final f in todo) {
      if (ctx != null && await ctx.checkpoint()) break;
      try {
        final st = File(f.source).statSync();
        if (st.size != f.size) _no('file changed since the preview');
        final dst = p.join(stage, f.relPath);
        var h = _verifiedCopy(f.source, dst);
        var t = false;
        if (f.tags != null) {
          t = SafeWriteService.tagNewCopy(dst, f.tags!);
          if (t) h = blake3File(dst)!;
        }
        if (t) tagged++;
        manifest.add({
          'n': f.n,
          'track_id': f.trackId,
          'artist': f.artist,
          'title': f.title,
          'file': f.relPath,
          'source': f.source, //
          'size': f.size,
          'duration_s': f.durationS,
          'blake3': h,
          'verified': true,
          'tagged': t,
        });
        ctx?.tick();
      } on Exception catch (e) {
        failures.add('${f.source} — ${e is GigPackException ? e.message : e}');
        ctx?.tick(ok: false);
      }
    }
    final cancelled = ctx?.cancelled ?? false;
    void text(String rel, String content) {
      final f = File(p.join(stage, rel));
      f.parent.createSync(recursive: true);
      if (f.existsSync()) _no('$rel already exists in the pack');
      f.writeAsStringSync(content);
    }

    final done = {for (final m in manifest) m['track_id'] as int: m};
    for (final pl in plan.playlists) {
      text(pl.path, _m3u8(pl, done));
    }
    text(
      'manifest.json',
      const JsonEncoder.withIndent('  ').convert({
        'created_at': nowMs(),
        'app': 'DJ Assistant $appVersion',
        'files': manifest,
        'tagged': tagged, //
        'complete': !cancelled && failures.isEmpty,
      }),
    );
    String q(Object? v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';
    final csv = StringBuffer(
      '#,Artist,Title,File,Size,BLAKE3,Verified,Tagged\r\n',
    );
    for (final m in manifest) {
      csv.write(
        '${m['n']},${q(m['artist'])},${q(m['title'])},${q(m['file'])},${m['size']},${m['blake3']},yes,${m['tagged'] == true ? 'yes' : 'no'}\r\n',
      );
    }
    text('manifest.csv', csv.toString());
    final miss = StringBuffer();
    for (final f in plan.files.where((f) => !f.available)) {
      miss.write('MISSING  ${f.source} — ${f.problem ?? ''}\r\n');
    }
    for (final e in failures) {
      miss.write('FAILED   $e\r\n');
    }
    if (cancelled) miss.write('The copy was cancelled before it finished.\r\n');
    text('missing-and-failed.txt', miss.toString());
    text(
      'README.txt',
      'Made by DJ Assistant.\r\n\r\nThe music files are verified copies (BLAKE3 hashes in manifest.csv)'
          '${plan.writeTags ? '; clean title, artist, genre, BPM and key were written into the MP3, FLAC and M4A copies only' : ''}.\r\n'
          'Playlists: ${plan.playlists.map((x) => x.path).join(', ')}. Drag a .m3u8 into Serato, or import it in Rekordbox, Traktor or VirtualDJ.\r\n\r\n'
          "Serato crates and library links are NOT copied. Cues and beatgrids stored in the files' tags travel with them, but check before the gig.\r\n"
          'Your original files were not changed.\r\n',
    );
    if (plan.zip) {
      final part = '$pack.part';
      if (FileSystemEntity.typeSync(part) != FileSystemEntityType.notFound) {
        _no('$part already exists');
      }
      final enc = ZipFileEncoder()..create(part, level: ZipFileEncoder.store);
      final entries = <String>[];
      for (final f in Directory(
        stage,
      ).listSync(recursive: true).whereType<File>()) {
        final rel = p.relative(f.path, from: stage).replaceAll(r'\', '/');
        enc.addFileSync(f, rel, ZipFileEncoder.store);
        entries.add(rel);
      }
      enc.closeSync();
      // Verify every stored entry against the staged copy before keeping the ZIP.
      final input = InputFileStream(part);
      try {
        final zip = ZipDecoder().decodeStream(input);
        for (final rel in entries) {
          final e = zip.findFile(rel) ?? _no('zip entry $rel is missing');
          if (blake3Hex(e.readBytes()!) != blake3File(p.join(stage, rel))) {
            _no('zip entry $rel did not verify');
          }
        }
      } finally {
        await input.close();
      }
      if (FileSystemEntity.typeSync(pack) != FileSystemEntityType.notFound) {
        _no(
          "a file with the ZIP's name appeared while copying; the copy is kept as .part",
        );
      }
      File(part).renameSync(pack);
      Directory(stage).deleteSync(recursive: true);
    }
    cat.setSetting('last_gig_pack', pack);
    if (ctx != null) {
      if (failures.isNotEmpty) {
        ctx.message =
            '${failures.length} file(s) failed; see missing-and-failed.txt in the pack';
      } else if (plan.writeTags) {
        ctx.message = '$tagged copies tagged';
      }
    }
    return {
      'pack': pack,
      'files': manifest.length,
      'failed': failures.length,
      'tagged': tagged,
      'cancelled': cancelled,
    };
  }
}

/// Copies a previewed pack as a background job (the plan is plain data, so it
/// can be sent to the job's isolate).
JobBody gigPackJob(
  String dbPath,
  PackPlan plan, {
  String appVersion = '2.0.0',
}) => (ctx) async {
  final c = Catalogue.open(dbPath);
  try {
    ctx.result = await GigPackService(c)
        .execute(plan, ctx: ctx, appVersion: appVersion);
  } finally {
    c.close();
  }
};
