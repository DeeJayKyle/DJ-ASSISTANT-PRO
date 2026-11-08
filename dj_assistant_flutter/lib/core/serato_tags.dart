import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../analysis/beatgrid.dart';

/// Read-only import of the analysis Serato DJ stores in a file's own tags:
/// its beatgrid ("Serato BeatGrid") and BPM ("Serato Autotags"). When a DJ
/// has analysed a track in Serato, these give DJ Assistant Serato's exact
/// grid and tempo for it. The file is only read, never written.
///
/// Where the data lives (the community-documented layout of these tags):
/// - MP3: ID3v2.3/2.4 `GEOB` frames whose description is the tag name.
/// - FLAC: Vorbis comments `SERATO_BEATGRID` / `SERATO_AUTOTAGS`, base64 of
///   `application/octet-stream\0\0<tag name>\0` followed by the data.
///
/// Beatgrid data: version `01 00`, a big-endian u32 marker count, then each
/// marker as a big-endian f32 position in seconds and, for every marker but
/// the last, a u32 beat count to the next marker; the last carries an f32
/// BPM instead. One footer byte follows.
class SeratoAnalysis {
  const SeratoAnalysis({this.beatgrid, this.bpm});
  final BeatGrid? beatgrid;
  final double? bpm;
  bool get isEmpty => beatgrid == null && bpm == null;
}

const _maxTagBytes = 16 * 1024 * 1024;

/// Serato's beatgrid data as a [BeatGrid] (source 'serato'), or null.
BeatGrid? parseSeratoBeatGrid(Uint8List d) {
  if (d.length < 6 || d[0] != 1 || d[1] != 0) return null;
  final bd = ByteData.sublistView(d);
  final n = bd.getUint32(2, Endian.big);
  if (n == 0 || n > 100000 || 6 + n * 8 > d.length) return null;
  final pos = <double>[], beats = <int>[];
  double? lastBpm;
  for (var i = 0; i < n; i++) {
    final o = 6 + i * 8;
    pos.add(bd.getFloat32(o, Endian.big));
    if (i < n - 1) {
      beats.add(bd.getUint32(o + 4, Endian.big));
    } else {
      lastBpm = bd.getFloat32(o + 4, Endian.big);
    }
  }
  final b = lastBpm!;
  if (!b.isFinite || b <= 0 || b > 1000 || pos.any((p) => !p.isFinite)) {
    return null;
  }
  double r2(double v) => (v * 100).round() / 100;
  final markers = <GridMarker>[];
  for (var i = 0; i < n; i++) {
    final bpm = i < n - 1
        ? (pos[i + 1] > pos[i] && beats[i] > 0
              ? 60 * beats[i] / (pos[i + 1] - pos[i])
              : b)
        : b;
    // Serato's markers sit on bar lines; count beats of four from the first
    var beat = 1;
    if (i > 0) {
      var total = 0;
      for (var k = 0; k < i; k++) {
        total += beats[k];
      }
      beat = total % 4 + 1;
    }
    markers.add(GridMarker((pos[i] * 1000).round(), r2(bpm), beat));
  }
  // The first grid line at or after the start of the file.
  final spb = 60 / markers.first.bpm;
  var first = pos.first;
  var back = 0;
  if (first >= 0) {
    back = (first / spb).floor();
    first -= back * spb;
  } else {
    back = -((-first) / spb).ceil();
    first -= back * spb;
  }
  // the first marker (a bar line) is [back] grid lines after the first one
  final toDown = back % 4;
  return BeatGrid(
    // the last marker runs to the end of the track: Serato's track tempo
    bpm: r2(b),
    firstBeatMs: (first * 1000).round(),
    downbeatMs: ((first + toDown * spb) * 1000).round(),
    stable: n == 1,
    beats: 0,
    markers: markers,
    downbeatConfidence: 1,
    source: 'serato',
  );
}

/// The BPM in Serato's autotags data, or null.
double? parseSeratoAutotagsBpm(Uint8List d) {
  if (d.length < 3 || d[0] != 1 || d[1] != 1) return null;
  final end = d.indexOf(0, 2);
  if (end < 0) return null;
  final v = double.tryParse(
    ascii.decode(d.sublist(2, end), allowInvalid: true),
  );
  return v != null && v.isFinite && v > 0 && v < 1000 ? v : null;
}

/// Reads Serato's analysis from [path] (MP3 or FLAC); empty when there is
/// none or the file can't be read.
SeratoAnalysis readSeratoAnalysis(String path) {
  RandomAccessFile? f;
  try {
    f = File(path).openSync();
    final head = f.readSync(10);
    if (head.length >= 10 &&
        ascii.decode(head.sublist(0, 3), allowInvalid: true) == 'ID3') {
      return _id3(f, head);
    }
    if (head.length >= 4 &&
        ascii.decode(head.sublist(0, 4), allowInvalid: true) == 'fLaC') {
      return _flac(f);
    }
  } on FileSystemException {
    // unreadable: nothing to import
  } finally {
    f?.closeSync();
  }
  return const SeratoAnalysis();
}

SeratoAnalysis _from(Map<String, Uint8List> geob) {
  final g = geob['Serato BeatGrid'], a = geob['Serato Autotags'];
  return SeratoAnalysis(
    beatgrid: g == null ? null : parseSeratoBeatGrid(g),
    bpm: a == null ? null : parseSeratoAutotagsBpm(a),
  );
}

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

SeratoAnalysis _id3(RandomAccessFile f, Uint8List head) {
  final major = head[3], flags = head[5];
  // whole-tag unsynchronisation and ID3v2.2 aren't used by Serato
  if ((major != 3 && major != 4) || flags & 0x80 != 0) {
    return const SeratoAnalysis();
  }
  final size = _syncsafe(head, 6);
  if (size <= 0 || size > _maxTagBytes) return const SeratoAnalysis();
  final tag = f.readSync(size);
  var o = 0;
  if (flags & 0x40 != 0 && tag.length >= 4) {
    // extended header
    final ext = major == 4
        ? _syncsafe(tag, 0)
        : ByteData.sublistView(tag).getUint32(0) + 4;
    o = ext;
  }
  final geob = <String, Uint8List>{};
  while (o + 10 <= tag.length) {
    final id = ascii.decode(tag.sublist(o, o + 4), allowInvalid: true);
    if (id.codeUnitAt(0) == 0) break;
    final len = major == 4
        ? _syncsafe(tag, o + 4)
        : ByteData.sublistView(tag).getUint32(o + 4);
    final start = o + 10, end = start + len;
    if (len < 0 || end > tag.length) break;
    if (id == 'GEOB' && tag[o + 9] == 0) {
      final frame = tag.sublist(start, end);
      final r = _geob(frame);
      if (r != null) geob[r.$1] = r.$2;
    }
    o = end;
  }
  return _from(geob);
}

/// (description, data) of a GEOB frame body.
(String, Uint8List)? _geob(Uint8List b) {
  if (b.isEmpty) return null;
  final enc = b[0];
  final wide = enc == 1 || enc == 2;
  int term(int from) {
    if (!wide) {
      final i = b.indexOf(0, from);
      return i < 0 ? -1 : i;
    }
    for (var i = from; i + 1 < b.length; i += 2) {
      if (b[i] == 0 && b[i + 1] == 0) return i;
    }
    return -1;
  }

  final mimeEnd = b.indexOf(0, 1); // MIME type is always Latin-1
  if (mimeEnd < 0) return null;
  final fileEnd = term(mimeEnd + 1);
  if (fileEnd < 0) return null;
  final descStart = fileEnd + (wide ? 2 : 1);
  final descEnd = term(descStart);
  if (descEnd < 0) return null;
  final raw = b.sublist(descStart, descEnd);
  final String desc;
  if (wide) {
    var units = [
      for (var i = 0; i + 1 < raw.length; i += 2) raw[i] | (raw[i + 1] << 8),
    ];
    if (units.isNotEmpty && units.first == 0xFFFE) {
      units = [for (final u in units.skip(1)) ((u & 0xff) << 8) | (u >> 8)];
    } else if (units.isNotEmpty && units.first == 0xFEFF) {
      units = units.sublist(1);
    }
    desc = String.fromCharCodes(units);
  } else {
    desc = latin1.decode(raw);
  }
  return (desc, b.sublist(descEnd + (wide ? 2 : 1)));
}

SeratoAnalysis _flac(RandomAccessFile f) {
  final geob = <String, Uint8List>{};
  var last = false;
  var budget = _maxTagBytes;
  while (!last) {
    final h = f.readSync(4);
    if (h.length < 4) break;
    last = h[0] & 0x80 != 0;
    final type = h[0] & 0x7f;
    final len = (h[1] << 16) | (h[2] << 8) | h[3];
    if (type != 4) {
      f.setPositionSync(f.positionSync() + len);
      continue;
    }
    budget -= len;
    if (budget < 0) break;
    final b = f.readSync(len);
    final bd = ByteData.sublistView(b);
    var o = 0;
    if (b.length < 8) break;
    o += 4 + bd.getUint32(0, Endian.little); // vendor
    if (o + 4 > b.length) break;
    final count = bd.getUint32(o, Endian.little);
    o += 4;
    for (var i = 0; i < count && o + 4 <= b.length; i++) {
      final l = bd.getUint32(o, Endian.little);
      o += 4;
      if (o + l > b.length) break;
      final c = utf8.decode(b.sublist(o, o + l), allowMalformed: true);
      o += l;
      final eq = c.indexOf('=');
      if (eq < 0) continue;
      final k = c.substring(0, eq).toUpperCase();
      if (k != 'SERATO_BEATGRID' && k != 'SERATO_AUTOTAGS') continue;
      final payload = _unbase64(c.substring(eq + 1));
      if (payload == null) continue;
      // application/octet-stream \0 \0 <name> \0 <data>
      final m = payload.indexOf(0);
      if (m < 0 || m + 1 >= payload.length) continue;
      final nameStart = payload[m + 1] == 0 ? m + 2 : m + 1;
      final nameEnd = payload.indexOf(0, nameStart);
      if (nameEnd < 0) continue;
      final name = latin1.decode(payload.sublist(nameStart, nameEnd));
      geob[name] = payload.sublist(nameEnd + 1);
    }
  }
  return _from(geob);
}

Uint8List? _unbase64(String s) {
  var t = s.replaceAll(RegExp(r'\s'), '');
  // Serato may drop padding (and leave one stray character)
  if (t.length % 4 == 1) t = t.substring(0, t.length - 1);
  t = t.padRight(t.length + (4 - t.length % 4) % 4, '=');
  try {
    return base64.decode(t);
  } on FormatException {
    return null;
  }
}

/// Beatgrid tag data from markers: each (position in seconds, beats to the
/// next marker), then the last marker's position and BPM. Used by tests.
Uint8List encodeSeratoBeatGrid(
  List<(double, int)> markers,
  double lastPos,
  double lastBpm,
) {
  final n = markers.length + 1;
  final b = ByteData(6 + n * 8 + 1)
    ..setUint8(0, 1)
    ..setUint8(1, 0)
    ..setUint32(2, n, Endian.big);
  var o = 6;
  for (final (pos, beats) in markers) {
    b
      ..setFloat32(o, pos, Endian.big)
      ..setUint32(o + 4, beats, Endian.big);
    o += 8;
  }
  b
    ..setFloat32(o, lastPos, Endian.big)
    ..setFloat32(o + 4, lastBpm, Endian.big);
  return b.buffer.asUint8List();
}
