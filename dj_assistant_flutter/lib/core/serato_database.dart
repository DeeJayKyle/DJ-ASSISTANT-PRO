import 'dart:typed_data';

import 'serato_library.dart';

/// Changes to the text fields of tracks already in Serato's `database V2`.
///
/// The file is a list of chunks (4-byte tag, 4-byte big-endian length,
/// data). Each track is an `otrk` chunk holding its own field chunks: `pfil`
/// is the path, and fields starting with `t` are UTF-16BE text (`tbpm` BPM,
/// `tkey` key, `tgen` genre, `ttyr` year, `tgrp` grouping, `tcom` comment,
/// `tlbl` label, `talb` album).
///
/// Only those text fields of tracks already listed change. Tracks are never
/// added or removed, every other chunk (cues, play counts, flags, unknown
/// fields) is copied byte for byte, and a file that doesn't parse cleanly
/// from start to end is refused rather than rewritten.
const seratoDbFields = {
  'bpm': 'tbpm',
  'key': 'tkey',
  'genre': 'tgen',
  'year': 'ttyr',
  'grouping': 'tgrp',
  'comment': 'tcom',
  'label': 'tlbl',
  'album': 'talb',
};

class _Chunk {
  _Chunk(this.tag, this.data);
  final String tag;
  final Uint8List data;
}

List<_Chunk> _strict(Uint8List b, String what) {
  final out = <_Chunk>[];
  var i = 0;
  while (i < b.length) {
    if (i + 8 > b.length) {
      throw SeratoLibraryException(
        "Serato's $what looks damaged, so it was left unchanged.",
      );
    }
    final tag = String.fromCharCodes(b.sublist(i, i + 4));
    final len =
        (b[i + 4] << 24) | (b[i + 5] << 16) | (b[i + 6] << 8) | b[i + 7];
    final end = i + 8 + len;
    if (end > b.length) {
      throw SeratoLibraryException(
        "Serato's $what looks damaged, so it was left unchanged.",
      );
    }
    out.add(_Chunk(tag, Uint8List.sublistView(b, i + 8, end)));
    i = end;
  }
  return out;
}

void _put(BytesBuilder out, String tag, List<int> data) {
  out
    ..add(tag.codeUnits)
    ..add([
      data.length >> 24 & 0xFF,
      data.length >> 16 & 0xFF,
      data.length >> 8 & 0xFF,
      data.length & 0xFF,
    ])
    ..add(data);
}

String _text(Uint8List b) {
  final units = <int>[
    for (var i = 0; i + 1 < b.length; i += 2) (b[i] << 8) | b[i + 1],
  ];
  return String.fromCharCodes(units).replaceFirst(RegExp('\u0000+\$'), '');
}

List<int> _utf16(String s) => [
  for (final u in s.codeUnits) ...[u >> 8, u & 0xFF],
];

/// The result of [updateSeratoDatabase].
class SeratoDbUpdate {
  SeratoDbUpdate(this.bytes, this.tracks, this.fields);
  final Uint8List bytes;

  /// Tracks changed, and fields changed in total.
  final int tracks, fields;
}

/// Applies [changes] (Serato path → field → new text; see [seratoDbFields]
/// for the field names) to a `database V2` file's [bytes]. Paths are
/// compared without case. Returns the new bytes; when nothing differs they
/// are the same bytes.
SeratoDbUpdate updateSeratoDatabase(
  Uint8List bytes,
  Map<String, Map<String, String>> changes,
) {
  final want = {for (final e in changes.entries) e.key.toLowerCase(): e.value};
  for (final f in changes.values.expand((m) => m.keys)) {
    if (!seratoDbFields.containsKey(f)) {
      throw ArgumentError('Serato has no field "$f"');
    }
  }
  final top = _strict(bytes, 'library (database V2)');
  final out = BytesBuilder(copy: false);
  var tracks = 0, fields = 0;
  for (final c in top) {
    if (c.tag != 'otrk') {
      _put(out, c.tag, c.data);
      continue;
    }
    final inner = _strict(c.data, 'library (database V2)');
    final path = inner
        .where((x) => x.tag == 'pfil')
        .map((x) => _text(x.data))
        .firstOrNull;
    final edit = path == null ? null : want[path.toLowerCase()];
    if (edit == null || edit.isEmpty) {
      _put(out, c.tag, c.data);
      continue;
    }
    final pending = {
      for (final e in edit.entries) seratoDbFields[e.key]!: e.value,
    };
    final track = BytesBuilder(copy: false);
    var changed = 0;
    for (final x in inner) {
      final v = pending.remove(x.tag);
      if (v != null && _text(x.data) != v) {
        _put(track, x.tag, _utf16(v));
        changed++;
      } else {
        _put(track, x.tag, x.data);
      }
    }
    for (final e in pending.entries) {
      if (e.value.isEmpty) continue;
      _put(track, e.key, _utf16(e.value));
      changed++;
    }
    if (changed == 0) {
      _put(out, c.tag, c.data);
      continue;
    }
    _put(out, 'otrk', track.takeBytes());
    tracks++;
    fields += changed;
  }
  if (fields == 0) return SeratoDbUpdate(bytes, 0, 0);
  final result = out.takeBytes();
  // read it back: same tracks in the same order, or nothing is written
  final before = [
    for (final c in top)
      if (c.tag == 'otrk') _pathOf(c.data),
  ];
  final after = [
    for (final c in _strict(result, 'updated library'))
      if (c.tag == 'otrk') _pathOf(c.data),
  ];
  if (before.length != after.length ||
      !Iterable.generate(before.length).every((i) => before[i] == after[i])) {
    throw SeratoLibraryException(
      "The updated Serato library didn't check out, so it was not saved.",
    );
  }
  return SeratoDbUpdate(result, tracks, fields);
}

String? _pathOf(Uint8List otrk) {
  for (final x in _strict(otrk, 'library (database V2)')) {
    if (x.tag == 'pfil') return _text(x.data);
  }
  return null;
}
