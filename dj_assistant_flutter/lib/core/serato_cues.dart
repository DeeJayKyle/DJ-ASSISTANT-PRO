import 'dart:convert';
import 'dart:typed_data';

import 'serato_tags.dart';

/// Read-only import of the hot cues, saved loops, track colour and BPM lock
/// Serato DJ keeps in a file's "Serato Markers2" tag (MP3 `GEOB` frame, or
/// the FLAC Vorbis comment `SERATO_MARKERS_V2`). Nothing is ever written.
///
/// Layout (community-documented): the tag data is `01 01` and then base64
/// text (wrapped in lines, padding sometimes missing) ending in a NUL. The
/// decoded body is `01 01` followed by entries, each an ASCII name, a NUL, a
/// big-endian u32 length and that many bytes; an empty name ends the list.
///
/// - `CUE`:  0, slot, u32 ms, 0, R G B, 0 0, UTF-8 name, NUL
/// - `LOOP`: 0, slot, u32 start ms, u32 end ms, FF FF FF FF, 0, R G B, 0,
///   locked, UTF-8 name, NUL
/// - `COLOR`: 0, R G B (the track's colour)
/// - `BPMLOCK`: 1 byte
///
/// Unknown entries (e.g. flips) are skipped. Damaged data yields whatever
/// could be read before the damage.
class SeratoCue {
  const SeratoCue({
    required this.slot,
    required this.positionMs,
    required this.color,
    this.name = '',
    this.endMs,
    this.locked = false,
  });

  /// 1-based pad number.
  final int slot;
  final int positionMs;

  /// Loop end; null for a hot cue.
  final int? endMs;

  /// 0xRRGGBB.
  final int color;
  final String name;
  final bool locked;
  bool get isLoop => endMs != null;

  String get colorHex =>
      '#${color.toRadixString(16).padLeft(6, '0').toUpperCase()}';

  Map<String, Object?> toJson() => {
    'type': isLoop ? 'loop' : 'hot_cue',
    'slot': slot,
    'position_ms': positionMs,
    if (endMs != null) 'end_ms': endMs,
    'color': colorHex,
    if (name.isNotEmpty) 'name': name,
    if (isLoop) 'locked': locked,
  };
}

class SeratoMarkers {
  const SeratoMarkers({
    this.cues = const [],
    this.loops = const [],
    this.trackColor,
    this.bpmLocked = false,
  });
  final List<SeratoCue> cues;
  final List<SeratoCue> loops;
  final int? trackColor;
  final bool bpmLocked;
  bool get isEmpty => cues.isEmpty && loops.isEmpty && trackColor == null;

  /// Hot cues then loops, each by slot.
  List<SeratoCue> get all => [...cues, ...loops];
}

/// Hot cues and loops Serato stored in [path]'s tags; empty when none.
SeratoMarkers readSeratoMarkers(String path) {
  final data = readSeratoGeobs(path)['Serato Markers2'];
  return data == null ? const SeratoMarkers() : parseSeratoMarkers2Tag(data);
}

/// The tag data (`01 01` + base64 text) → markers.
SeratoMarkers parseSeratoMarkers2Tag(Uint8List data) {
  if (data.length < 3 || data[0] != 1 || data[1] != 1) {
    return const SeratoMarkers();
  }
  var end = data.indexOf(0, 2);
  if (end < 0) end = data.length;
  final text = latin1
      .decode(data.sublist(2, end))
      .replaceAll(RegExp(r'[^A-Za-z0-9+/]'), '');
  var t = text;
  if (t.length % 4 == 1) t = t.substring(0, t.length - 1);
  t = t.padRight(t.length + (4 - t.length % 4) % 4, '=');
  final Uint8List body;
  try {
    body = base64.decode(t);
  } on FormatException {
    return const SeratoMarkers();
  }
  return parseSeratoMarkers2Body(body);
}

/// The decoded body (`01 01` + entries) → markers.
SeratoMarkers parseSeratoMarkers2Body(Uint8List b) {
  if (b.length < 2 || b[0] != 1 || b[1] != 1) return const SeratoMarkers();
  final cues = <int, SeratoCue>{}, loops = <int, SeratoCue>{};
  int? color;
  var lock = false;
  final bd = ByteData.sublistView(b);
  var o = 2;
  while (o < b.length) {
    final nameEnd = b.indexOf(0, o);
    if (nameEnd < 0 || nameEnd == o) break; // end of list (or damaged)
    final name = latin1.decode(b.sublist(o, nameEnd));
    o = nameEnd + 1;
    if (o + 4 > b.length) break;
    final len = bd.getUint32(o);
    o += 4;
    if (o + len > b.length) break;
    final e = Uint8List.sublistView(b, o, o + len);
    o += len;
    final ed = ByteData.sublistView(e);
    switch (name) {
      case 'CUE' when e.length >= 12:
        final slot = e[1] + 1;
        cues.putIfAbsent(
          slot,
          () => SeratoCue(
            slot: slot,
            positionMs: ed.getUint32(2),
            color: (e[7] << 16) | (e[8] << 8) | e[9],
            name: _text(e, 12),
          ),
        );
      case 'LOOP' when e.length >= 20:
        final slot = e[1] + 1;
        final start = ed.getUint32(2), stop = ed.getUint32(6);
        if (stop <= start) continue;
        loops.putIfAbsent(
          slot,
          () => SeratoCue(
            slot: slot,
            positionMs: start,
            endMs: stop,
            color: (e[15] << 16) | (e[16] << 8) | e[17],
            locked: e[19] != 0,
            name: _text(e, 20),
          ),
        );
      case 'COLOR' when e.length >= 4:
        color ??= (e[1] << 16) | (e[2] << 8) | e[3];
      case 'BPMLOCK' when e.isNotEmpty:
        lock = e[0] != 0;
    }
  }
  int bySlot(SeratoCue a, SeratoCue b) => a.slot.compareTo(b.slot);
  return SeratoMarkers(
    cues: cues.values.toList()..sort(bySlot),
    loops: loops.values.toList()..sort(bySlot),
    trackColor: color,
    bpmLocked: lock,
  );
}

String _text(Uint8List e, int from) {
  if (from >= e.length) return '';
  var end = e.indexOf(0, from);
  if (end < 0) end = e.length;
  return utf8.decode(e.sublist(from, end), allowMalformed: true);
}

/// Builds Markers2 tag data. Used by tests to make fixture files.
Uint8List encodeSeratoMarkers2Tag(SeratoMarkers m) {
  final body = BytesBuilder()..add([1, 1]);
  void entry(String name, List<int> data) {
    body
      ..add(latin1.encode(name))
      ..addByte(0)
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(data);
  }

  List<int> u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
  List<int> rgb(int c) => [(c >> 16) & 0xff, (c >> 8) & 0xff, c & 0xff];
  if (m.trackColor != null) entry('COLOR', [0, ...rgb(m.trackColor!)]);
  for (final c in m.cues) {
    entry('CUE', [
      0,
      c.slot - 1,
      ...u32(c.positionMs),
      0,
      ...rgb(c.color),
      0,
      0,
      ...utf8.encode(c.name),
      0,
    ]);
  }
  for (final l in m.loops) {
    entry('LOOP', [
      0,
      l.slot - 1,
      ...u32(l.positionMs),
      ...u32(l.endMs!),
      0xff,
      0xff,
      0xff,
      0xff,
      0,
      ...rgb(l.color),
      0,
      l.locked ? 1 : 0,
      ...utf8.encode(l.name),
      0,
    ]);
  }
  entry('BPMLOCK', [m.bpmLocked ? 1 : 0]);
  body.addByte(0);
  // Serato leaves the base64 padding off
  final text = base64.encode(body.toBytes()).replaceAll('=', '');
  final lines = [
    for (var i = 0; i < text.length; i += 72)
      text.substring(i, i + 72 > text.length ? text.length : i + 72),
  ].join('\n');
  return Uint8List.fromList([1, 1, ...ascii.encode(lines), 0]);
}
