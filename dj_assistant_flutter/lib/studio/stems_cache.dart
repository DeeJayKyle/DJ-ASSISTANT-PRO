import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:path/path.dart' as p;

import '../core/disk.dart';
import 'stems.dart' show Stems, stemNames;

/// Prepared stems: a song is split once and its four stems are kept on this
/// computer, so loading it again (or on a deck at a gig) is instant. This is
/// the workflow DJ software calls "prepared stems"; the file format is this
/// app's own.
///
/// Files live in the app's data folder, never next to the music. Each is
/// named from the song's path, size and modified time and from how the stems
/// were made (method and model), so an edited song or a new model never
/// gets stale stems. Writes go to a temporary file renamed into place; a file
/// that doesn't check out is ignored and removed.
///
/// Layout: `DJSTEMS1`, a little-endian u32 header length, a UTF-8 JSON
/// header, then for each stem in [stemNames] its left and right channels as
/// 16-bit little-endian PCM scaled by the header's `scale`.
const _magic = 'DJSTEMS1';
const fileVersion = 1;
const extension = '.djstems';

/// What a prepared stems file was made from.
class StemsSource {
  const StemsSource({
    required this.path,
    required this.size,
    required this.mtimeMs,
    required this.method,
    required this.model,
  });
  final String path;
  final int size, mtimeMs;

  /// 'ai' or 'fast'.
  final String method;

  /// Identifies the separator: the AI model file (name and size), or the Fast
  /// splitter's version.
  final String model;

  static StemsSource? of(String path, String method, String model) {
    try {
      final st = File(path).statSync();
      if (st.type != FileSystemEntityType.file) return null;
      return StemsSource(
        path: path,
        size: st.size,
        mtimeMs: st.modified.millisecondsSinceEpoch,
        method: method,
        model: model,
      );
    } on FileSystemException {
      return null;
    }
  }

  String get key => sha256
      .convert(
        utf8.encode('$fileVersion\n$path\n$size\n$mtimeMs\n$method\n$model'),
      )
      .toString()
      .substring(0, 40);

  Map<String, Object> toJson() => {
    'path': path,
    'size': size,
    'mtime_ms': mtimeMs,
    'method': method,
    'model': model,
  };
}

/// Encodes [stems] (stereo, [frames] long) for [src] at [sampleRate].
Uint8List encodePreparedStems(Stems stems, int sampleRate, StemsSource src) {
  final frames = stems[stemNames.first]![0].length;
  var peak = 0.0;
  for (final s in stemNames) {
    for (final ch in stems[s]!) {
      if (ch.length != frames) {
        throw ArgumentError('stems must all be $frames frames long');
      }
      for (final v in ch) {
        final a = v.abs();
        if (a > peak && a.isFinite) peak = a;
      }
    }
  }
  final scale = math.max(1.0, peak);
  final header = utf8.encode(
    jsonEncode({
      'version': fileVersion,
      'sample_rate': sampleRate,
      'frames': frames,
      'channels': 2,
      'format': 's16le',
      'scale': scale,
      'stems': stemNames,
      'source': src.toJson(),
    }),
  );
  final dataBytes = stemNames.length * 2 * frames * 2;
  final out = Uint8List(8 + 4 + header.length + dataBytes);
  out.setRange(0, 8, ascii.encode(_magic));
  final bd = ByteData.sublistView(out);
  bd.setUint32(8, header.length, Endian.little);
  out.setRange(12, 12 + header.length, header);
  var o = 12 + header.length;
  for (final s in stemNames) {
    for (final ch in stems[s]!) {
      for (var i = 0; i < frames; i++) {
        final v = (ch[i] / scale).clamp(-1.0, 1.0);
        bd.setInt16(o, (v * 32767).round(), Endian.little);
        o += 2;
      }
    }
  }
  return out;
}

/// Decodes a prepared stems file made for [src]: (stems, sample rate), or
/// null if it isn't one, is damaged, or was made from something else.
(Stems, int)? decodePreparedStems(Uint8List b, StemsSource src) {
  if (b.length < 12 ||
      ascii.decode(b.sublist(0, 8), allowInvalid: true) != _magic) {
    return null;
  }
  final bd = ByteData.sublistView(b);
  final hl = bd.getUint32(8, Endian.little);
  if (hl > 65536 || 12 + hl > b.length) return null;
  final Map h;
  try {
    h = jsonDecode(utf8.decode(b.sublist(12, 12 + hl))) as Map;
  } on Object {
    return null;
  }
  final s = h['source'];
  if (h['version'] != fileVersion ||
      h['format'] != 's16le' ||
      h['channels'] != 2 ||
      s is! Map ||
      s['path'] != src.path ||
      s['size'] != src.size ||
      s['mtime_ms'] != src.mtimeMs ||
      s['method'] != src.method ||
      s['model'] != src.model ||
      jsonEncode(h['stems']) != jsonEncode(stemNames)) {
    return null;
  }
  final frames = h['frames'], sr = h['sample_rate'], scale = h['scale'];
  if (frames is! int || sr is! int || scale is! num || frames <= 0) {
    return null;
  }
  if (b.length != 12 + hl + stemNames.length * 2 * frames * 2) return null;
  final k = scale.toDouble() / 32767;
  var o = 12 + hl;
  final out = <String, List<Float32List>>{};
  for (final name in stemNames) {
    final chans = <Float32List>[];
    for (var c = 0; c < 2; c++) {
      final x = Float32List(frames);
      for (var i = 0; i < frames; i++) {
        x[i] = bd.getInt16(o, Endian.little) * k;
        o += 2;
      }
      chans.add(x);
    }
    out[name] = chans;
  }
  return (out, sr);
}

/// The prepared stems folder, kept under [maxBytes] by removing the files
/// used longest ago. Its methods do file work: call them from an isolate.
class StemsCache {
  StemsCache(this.dir, {this.maxBytes = 20 * gigabyte});
  static const gigabyte = 1024 * 1024 * 1024;

  final String dir;
  int maxBytes;

  /// Room left free on the drive after a save.
  static const reserveBytes = gigabyte;

  String fileFor(StemsSource src) => p.join(dir, '${src.key}$extension');

  /// Prepared stems for [src], or null. A hit counts as a use (for clean-up).
  (Stems, int)? load(StemsSource src) {
    final f = File(fileFor(src));
    if (!f.existsSync()) return null;
    final r = decodePreparedStems(f.readAsBytesSync(), src);
    if (r == null) {
      _delete(f);
      return null;
    }
    try {
      f.setLastModifiedSync(DateTime.now());
    } on FileSystemException {
      // read-only folder: still a hit
    }
    return r;
  }

  /// Saves [stems] for [src]; false (nothing written) when it won't fit in
  /// the space set for prepared stems or on the drive.
  bool save(StemsSource src, Stems stems, int sampleRate) {
    final bytes = encodePreparedStems(stems, sampleRate, src);
    if (bytes.length > maxBytes) return false;
    Directory(dir).createSync(recursive: true);
    final free = freeBytes(dir);
    if (free != null && free < bytes.length + reserveBytes) return false;
    final target = File(fileFor(src));
    final part = File('${target.path}.part');
    try {
      part.writeAsBytesSync(bytes, flush: true);
      part.renameSync(target.path);
    } on FileSystemException {
      _delete(part);
      return false;
    }
    trim(keep: target.path);
    return true;
  }

  List<File> _files() {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    return [
      for (final e in d.listSync())
        if (e is File && e.path.endsWith(extension)) e,
    ];
  }

  /// Space used by prepared stems, and how many songs.
  (int, int) usage() {
    var total = 0, n = 0;
    for (final f in _files()) {
      try {
        total += f.lengthSync();
        n++;
      } on FileSystemException {
        // removed meanwhile
      }
    }
    return (total, n);
  }

  /// Removes the least recently used files until the folder fits [maxBytes]
  /// (never [keep], the file just written). Leftover `.part` files go too.
  void trim({String? keep}) {
    final d = Directory(dir);
    if (!d.existsSync()) return;
    for (final e in d.listSync()) {
      if (e is File && e.path.endsWith('$extension.part')) _delete(e);
    }
    final files = <(File, DateTime, int)>[];
    var total = 0;
    for (final f in _files()) {
      try {
        final st = f.statSync();
        files.add((f, st.modified, st.size));
        total += st.size;
      } on FileSystemException {
        // removed meanwhile
      }
    }
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final (f, _, size) in files) {
      if (total <= maxBytes) break;
      if (f.path == keep) continue;
      if (_delete(f)) total -= size;
    }
  }

  /// Removes every prepared stems file.
  void clear() {
    for (final f in _files()) {
      _delete(f);
    }
  }

  static bool _delete(File f) {
    try {
      f.deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
