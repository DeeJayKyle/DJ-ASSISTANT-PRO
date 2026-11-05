import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'blake3.dart';

/// Minimal-change tag writers for MP3 (ID3v2.3/2.4), FLAC (Vorbis comments) and
/// M4A (iTunes `ilst`). Only the edited fields change; every other frame, comment,
/// atom and block is copied byte for byte (Serato keeps cues, loops and beatgrids
/// in GEOB frames, SERATO_* comments and `----` atoms). Used only by the safe-write
/// service, on a temporary copy, never directly on a DJ's file.

/// Fields that may be written to files (1.x `WRITABLE`).
const writableFields = [
  'title',
  'artist',
  'album',
  'genre',
  'year',
  'bpm',
  'key',
  'comment',
];

class TagWriteException implements Exception {
  TagWriteException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _fail(String m) => throw TagWriteException(m);

/// mp3 / flac / m4a, or null when writing is not supported for this file.
String? writableKind(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  return switch (path.substring(dot + 1).toLowerCase()) {
    'mp3' => 'mp3',
    'flac' => 'flac',
    'm4a' || 'mp4' || 'aac' => 'm4a',
    _ => null,
  };
}

String _sha(List<int> b) => sha256.convert(b).toString();

// ============================================================== ID3v2

class _Frame {
  _Frame(this.id, this.flags, this.data);
  final String id;
  final int flags;
  final Uint8List data;
}

class _Id3 {
  _Id3(this.major, this.frames, this.tagEnd);
  final int major; // 3 or 4
  final List<_Frame> frames;
  final int tagEnd; // offset of the first byte after the tag (incl. padding)
}

int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];
int _be32(List<int> b, int o) =>
    (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

List<int> _deunsync(List<int> b) {
  final out = <int>[];
  for (var i = 0; i < b.length; i++) {
    out.add(b[i]);
    if (b[i] == 0xFF && i + 1 < b.length && b[i + 1] == 0) i++;
  }
  return out;
}

/// Parses the ID3v2 tag at the start of [b]; null when there is none.
_Id3? _parseId3(Uint8List b) {
  if (b.length < 10 || b[0] != 0x49 || b[1] != 0x44 || b[2] != 0x33) {
    return null;
  }
  final major = b[3], flags = b[5];
  if (major != 3 && major != 4) {
    _fail(
      'ID3v2.$major tags are not written in this version (only 2.3 and 2.4).',
    );
  }
  if (flags & 0x40 != 0) {
    _fail(
      'This file has an extended ID3 header; it is left untouched in this version.',
    );
  }
  if (major == 4 && flags & 0x10 != 0) {
    _fail('This file has an ID3 footer; it is left untouched in this version.');
  }
  if (major == 4 && flags & 0x80 != 0) {
    _fail('This file uses whole-tag unsynchronisation; it is left untouched.');
  }
  final size = _syncsafe(b, 6);
  final end = 10 + size;
  if (end > b.length) {
    _fail('The ID3 tag is damaged (it is longer than the file).');
  }
  List<int> body = Uint8List.sublistView(b, 10, end);
  if (major == 3 && flags & 0x80 != 0) body = _deunsync(body);
  final frames = <_Frame>[];
  var p = 0;
  while (p + 10 <= body.length) {
    if (body[p] == 0) break; // padding
    final id = String.fromCharCodes(body.sublist(p, p + 4));
    if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(id)) {
      _fail('The ID3 tag is damaged (bad frame "$id").');
    }
    var fsize = major == 4 ? _syncsafe(body, p + 4) : _be32(body, p + 4);
    // iTunes once wrote plain sizes in 2.4 tags; accept them when that is the only reading that fits.
    if (major == 4 &&
        p + 10 + fsize > body.length &&
        p + 10 + _be32(body, p + 4) <= body.length) {
      fsize = _be32(body, p + 4);
    }
    if (p + 10 + fsize > body.length) {
      _fail('The ID3 tag is damaged (frame $id runs past the tag).');
    }
    frames.add(
      _Frame(
        id,
        (body[p + 8] << 8) | body[p + 9],
        Uint8List.fromList(body.sublist(p + 10, p + 10 + fsize)),
      ),
    );
    p += 10 + fsize;
  }
  return _Id3(major, frames, end);
}

String _decodeText(int enc, List<int> b) {
  switch (enc) {
    case 0:
      return latin1.decode(b, allowInvalid: true);
    case 3:
      return utf8.decode(b, allowMalformed: true);
    case 1 || 2:
      var i = 0;
      var be = enc == 2;
      if (enc == 1 && b.length >= 2) {
        if (b[0] == 0xFE && b[1] == 0xFF) {
          be = true;
          i = 2;
        } else if (b[0] == 0xFF && b[1] == 0xFE) {
          i = 2;
        }
      }
      final units = <int>[];
      for (; i + 1 < b.length; i += 2) {
        units.add(be ? (b[i] << 8) | b[i + 1] : b[i] | (b[i + 1] << 8));
      }
      return String.fromCharCodes(units);
  }
  return '';
}

/// First value of a text frame (values are NUL-separated in 2.4).
String? _textValue(_Frame f) {
  // Compressed or encrypted frames are not text this writer understands.
  if (f.data.isEmpty || f.flags & 0x00FF != 0) {
    return null;
  }
  final s = _decodeText(f.data[0], f.data.sublist(1));
  final v = s.split('\u0000').first.trim();
  return v.isEmpty ? null : v;
}

/// COMM frame: (description, text).
(String, String)? _comment(_Frame f) {
  if (f.id != 'COMM' || f.data.length < 5 || f.flags & 0x00FF != 0) return null;
  final enc = f.data[0];
  final rest = f.data.sublist(4);
  final wide = enc == 1 || enc == 2;
  var i = 0;
  if (wide) {
    while (i + 1 < rest.length && !(rest[i] == 0 && rest[i + 1] == 0)) {
      i += 2;
    }
  } else {
    while (i < rest.length && rest[i] != 0) {
      i++;
    }
  }
  final desc = _decodeText(enc, rest.sublist(0, i));
  final start = i + (wide ? 2 : 1);
  final text = start <= rest.length
      ? _decodeText(enc, rest.sublist(start))
      : '';
  return (desc.replaceAll('\u0000', ''), text.split('\u0000').first);
}

List<int> _encodeText(int major, String v) {
  if (major == 4) return [3, ...utf8.encode(v)];
  if (v.codeUnits.every((c) => c < 0x100)) return [0, ...latin1.encode(v)];
  final out = <int>[1, 0xFF, 0xFE];
  for (final u in v.codeUnits) {
    out
      ..add(u & 0xFF)
      ..add(u >> 8);
  }
  return out;
}

List<int> _encodeComment(int major, String v) {
  final t = _encodeText(major, v);
  final enc = t[0];
  final body = t.sublist(1);
  // language "XXX" (unknown, as 1.x writes), empty description, then the text
  final emptyDesc = enc == 1
      ? [0xFF, 0xFE, 0, 0]
      : (enc == 0 || enc == 3 ? [0] : [0, 0]);
  return [enc, 0x58, 0x58, 0x58, ...emptyDesc, ...body];
}

const _id3Ids = {
  'title': ['TIT2'],
  'artist': ['TPE1'],
  'album': ['TALB'],
  'genre': ['TCON'],
  'year': ['TDRC', 'TYER'],
  'bpm': ['TBPM'],
  'key': ['TKEY'],
};

Map<String, String> _id3Current(_Id3? tag) {
  final m = <String, String>{};
  if (tag == null) return m;
  String? first(String id) {
    for (final f in tag.frames) {
      if (f.id == id) {
        final v = _textValue(f);
        if (v != null) return v;
      }
    }
    return null;
  }

  void put(String k, String? v) {
    if (v != null && v.isNotEmpty) m[k] = v;
  }

  put('title', first('TIT2'));
  put('artist', first('TPE1'));
  put('album', first('TALB'));
  put('genre', first('TCON'));
  put('year', first('TDRC') ?? first('TYER'));
  put('bpm', first('TBPM'));
  put('key', first('TKEY'));
  for (final f in tag.frames) {
    final c = _comment(f);
    if (c != null && c.$1.isEmpty) {
      put('comment', c.$2.trim());
      break;
    }
  }
  return m;
}

bool _isEditedFrame(_Frame f, Iterable<String> edited) {
  for (final k in edited) {
    if (k == 'comment') {
      final c = _comment(f);
      if (c != null && c.$1.isEmpty) return true;
    } else if ((_id3Ids[k] ?? const []).contains(f.id)) {
      return true;
    }
  }
  return false;
}

Uint8List _writeId3(Uint8List file, Map<String, String?> changes) {
  final old = _parseId3(file);
  final major = old?.major ?? 4;
  final frames = List<_Frame>.of(old?.frames ?? const []);
  for (final e in changes.entries) {
    final k = e.key, v = e.value;
    late final String id;
    late final List<int> data;
    if (k == 'comment') {
      id = 'COMM';
      if (v != null) data = _encodeComment(major, v);
    } else {
      final ids = _id3Ids[k];
      if (ids == null) continue;
      id = k == 'year' ? (major == 4 ? 'TDRC' : 'TYER') : ids.first;
      if (v != null) data = _encodeText(major, v);
    }
    final at = frames.indexWhere((f) => _isEditedFrame(f, [k]));
    frames.removeWhere((f) => _isEditedFrame(f, [k]));
    if (v != null) {
      final nf = _Frame(id, 0, Uint8List.fromList(data));
      if (at >= 0 && at <= frames.length) {
        frames.insert(at, nf);
      } else {
        frames.add(nf);
      }
    }
  }
  final body = BytesBuilder();
  for (final f in frames) {
    final n = f.data.length;
    if (major == 4 && n >= 1 << 28) _fail('A tag frame is too large to write.');
    body
      ..add(latin1.encode(f.id))
      ..add(
        major == 4
            ? [(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F]
            : [n >> 24 & 0xFF, n >> 16 & 0xFF, n >> 8 & 0xFF, n & 0xFF],
      )
      ..add([f.flags >> 8, f.flags & 0xFF])
      ..add(f.data);
  }
  final framesLen = body.length;
  final oldSize = old == null ? 0 : old.tagEnd - 10;
  // Reuse the old tag's space (the audio does not move) when the frames fit.
  final size = framesLen <= oldSize ? oldSize : framesLen + 2048;
  if (size >= 1 << 28) _fail('The tag would be too large.');
  final out = BytesBuilder(copy: false)
    ..add([
      0x49,
      0x44,
      0x33,
      major,
      0,
      0,
      (size >> 21) & 0x7F,
      (size >> 14) & 0x7F,
      (size >> 7) & 0x7F,
      size & 0x7F,
    ])
    ..add(body.takeBytes())
    ..add(Uint8List(size - framesLen))
    ..add(Uint8List.sublistView(file, old?.tagEnd ?? 0));
  return out.takeBytes();
}

List<String> _id3Untouched(_Id3? tag, Iterable<String> edited) => [
  for (final f in tag?.frames ?? const <_Frame>[])
    if (!_isEditedFrame(f, edited)) '${f.id}|${f.flags}|${_sha(f.data)}',
]..sort();

// ============================================================== FLAC

class _Block {
  _Block(this.type, this.data);
  final int type;
  Uint8List data;
}

(List<_Block>, int) _parseFlac(Uint8List b) {
  if (b.length < 4 || String.fromCharCodes(b.sublist(0, 4)) != 'fLaC') {
    _fail('Only plain FLAC files (starting with the FLAC header) are written.');
  }
  final blocks = <_Block>[];
  var p = 4;
  while (true) {
    if (p + 4 > b.length) _fail('The FLAC header is damaged.');
    final last = b[p] & 0x80 != 0;
    final type = b[p] & 0x7F;
    final len = (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    if (p + 4 + len > b.length) _fail('The FLAC header is damaged.');
    blocks.add(_Block(type, Uint8List.fromList(b.sublist(p + 4, p + 4 + len))));
    p += 4 + len;
    if (last) break;
  }
  if (blocks.isEmpty || blocks.first.type != 0) {
    _fail('The FLAC header is damaged (no STREAMINFO).');
  }
  return (blocks, p);
}

(Uint8List, List<String>) _parseVorbis(Uint8List d) {
  final bd = ByteData.sublistView(d);
  if (d.length < 8) _fail('The FLAC comment block is damaged.');
  final vlen = bd.getUint32(0, Endian.little);
  if (4 + vlen + 4 > d.length) _fail('The FLAC comment block is damaged.');
  final vendor = Uint8List.fromList(d.sublist(4, 4 + vlen));
  var p = 4 + vlen;
  final n = bd.getUint32(p, Endian.little);
  p += 4;
  final entries = <String>[];
  for (var i = 0; i < n; i++) {
    if (p + 4 > d.length) _fail('The FLAC comment block is damaged.');
    final l = bd.getUint32(p, Endian.little);
    if (p + 4 + l > d.length) _fail('The FLAC comment block is damaged.');
    entries.add(utf8.decode(d.sublist(p + 4, p + 4 + l), allowMalformed: true));
    p += 4 + l;
  }
  return (vendor, entries);
}

const _vorbisKeys = {
  'title': 'TITLE',
  'artist': 'ARTIST',
  'album': 'ALBUM',
  'genre': 'GENRE',
  'year': 'DATE',
  'bpm': 'BPM',
  'key': 'INITIALKEY',
  'comment': 'COMMENT',
};

String _entryKey(String e) {
  final i = e.indexOf('=');
  return (i < 0 ? e : e.substring(0, i)).toUpperCase();
}

Map<String, String> _flacCurrent(List<_Block> blocks) {
  final m = <String, String>{};
  final vc = blocks.where((b) => b.type == 4).firstOrNull;
  if (vc == null) return m;
  final (_, entries) = _parseVorbis(vc.data);
  for (final e in _vorbisKeys.entries) {
    for (final x in entries) {
      if (_entryKey(x) == e.value) {
        final v = x.substring(x.indexOf('=') + 1);
        if (v.isNotEmpty) m[e.key] = v;
        break;
      }
    }
  }
  return m;
}

Uint8List _writeFlac(Uint8List file, Map<String, String?> changes) {
  final (blocks, audioStart) = _parseFlac(file);
  var vc = blocks.where((b) => b.type == 4).firstOrNull;
  final oldVcLen = vc == null
      ? -4
      : vc.data.length; // -4: a new block also adds a header
  Uint8List vendor;
  List<String> entries;
  if (vc == null) {
    vendor = Uint8List.fromList(utf8.encode('DJ Assistant'));
    entries = [];
    vc = _Block(4, Uint8List(0));
    blocks.insert(1, vc);
  } else {
    (vendor, entries) = _parseVorbis(vc.data);
  }
  for (final e in changes.entries) {
    final key = _vorbisKeys[e.key];
    if (key == null) continue;
    entries.removeWhere((x) => _entryKey(x) == key);
    if (e.value != null) entries.add('$key=${e.value}');
  }
  final out = BytesBuilder();
  final w = ByteData(4);
  void u32(int v) {
    w.setUint32(0, v, Endian.little);
    out.add(w.buffer.asUint8List(0, 4));
  }

  u32(vendor.length);
  out.add(vendor);
  u32(entries.length);
  for (final x in entries) {
    final bytes = utf8.encode(x);
    u32(bytes.length);
    out.add(bytes);
  }
  vc.data = out.takeBytes();
  if (vc.data.length >= 1 << 24) {
    _fail('The comments would be too large for a FLAC block.');
  }
  // Keep the audio where it is by resizing the padding block, when there is one.
  final delta = vc.data.length - oldVcLen;
  final pad = blocks.where((b) => b.type == 1).firstOrNull;
  if (pad != null && pad.data.length - delta >= 0) {
    pad.data = Uint8List(pad.data.length - delta);
  } else if (pad == null && delta < 0 && -delta >= 4) {
    blocks.add(_Block(1, Uint8List(-delta - 4)));
  } else if (pad != null) {
    pad.data = Uint8List(1024);
  }
  final res = BytesBuilder(copy: false)..add(latin1.encode('fLaC'));
  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i], n = b.data.length;
    res
      ..add([
        (i == blocks.length - 1 ? 0x80 : 0) | b.type,
        (n >> 16) & 0xFF,
        (n >> 8) & 0xFF,
        n & 0xFF,
      ])
      ..add(b.data);
  }
  res.add(Uint8List.sublistView(file, audioStart));
  return res.takeBytes();
}

List<String> _flacUntouched(List<_Block> blocks, Iterable<String> edited) {
  final keys = {for (final k in edited) _vorbisKeys[k]};
  final out = <String>[];
  for (final b in blocks) {
    if (b.type == 4) {
      final (vendor, entries) = _parseVorbis(b.data);
      out.add('vendor|${_sha(vendor)}');
      for (final x in entries) {
        if (!keys.contains(_entryKey(x))) out.add('c|${_sha(utf8.encode(x))}');
      }
    } else if (b.type != 1) {
      out.add('block${b.type}|${_sha(b.data)}');
    }
  }
  return out..sort();
}

// ============================================================== MP4

class _Atom {
  _Atom(this.type, this.start, this.end, this.header);
  final String type;
  final int start, end, header; // start of the box, end, header length
  int get body => start + header;
}

List<_Atom> _atoms(List<int> b, int start, int end) {
  final out = <_Atom>[];
  var p = start;
  while (p + 8 <= end) {
    var size = _be32(b, p);
    var hdr = 8;
    if (size == 1) {
      if (p + 16 > end) break;
      size = (_be32(b, p + 8) << 32) | _be32(b, p + 12);
      hdr = 16;
    } else if (size == 0) {
      size = end - p;
    }
    if (size < hdr || p + size > end) break;
    out.add(_Atom(latin1.decode(b.sublist(p + 4, p + 8)), p, p + size, hdr));
    p += size;
  }
  return out;
}

_Atom? _child(List<int> b, _Atom a, String type, {int skip = 0}) =>
    _atoms(b, a.body + skip, a.end).where((x) => x.type == type).firstOrNull;

const _mp4Atoms = {
  'title': '©nam',
  'artist': '©ART',
  'album': '©alb',
  'genre': '©gen',
  'year': '©day',
  'comment': '©cmt',
};

const _gnre = [
  'Blues',
  'Classic Rock',
  'Country',
  'Dance',
  'Disco',
  'Funk',
  'Grunge',
  'Hip-Hop',
  'Jazz',
  'Metal',
  'New Age', //
  'Oldies',
  'Other',
  'Pop',
  'R&B',
  'Rap',
  'Reggae',
  'Rock',
  'Techno',
  'Industrial',
  'Alternative',
  'Ska',
  'Death Metal',
  'Pranks',
  'Soundtrack',
  'Euro-Techno',
  'Ambient',
  'Trip-Hop',
  'Vocal',
  'Jazz+Funk',
  'Fusion',
  'Trance',
  'Classical',
  'Instrumental',
  'Acid',
  'House',
  'Game',
  'Sound Clip',
  'Gospel',
  'Noise',
  'AlternRock',
  'Bass',
  'Soul',
  'Punk',
  'Space',
  'Meditative',
  'Instrumental Pop',
  'Instrumental Rock',
  'Ethnic',
  'Gothic',
  'Darkwave',
  'Techno-Industrial',
  'Electronic',
  'Pop-Folk',
  'Eurodance',
  'Dream',
  'Southern Rock',
  'Comedy',
  'Cult',
  'Gangsta',
  'Top 40',
  'Christian Rap',
  'Pop/Funk',
  'Jungle',
  'Native American',
  'Cabaret',
  'New Wave',
  'Psychadelic',
  'Rave',
  'Showtunes',
  'Trailer',
  'Lo-Fi',
  'Tribal',
  'Acid Punk',
  'Acid Jazz',
  'Polka',
  'Retro',
  'Musical',
  'Rock & Roll',
  'Hard Rock',
];

/// (moov, udta?, meta?, ilst?) in [b].
(_Atom, _Atom?, _Atom?, _Atom?) _mp4Path(Uint8List b) {
  final top = _atoms(b, 0, b.length);
  if (top.isEmpty || top.first.type != 'ftyp') {
    _fail('This is not an MP4/M4A file this version can write.');
  }
  final moov =
      top.where((a) => a.type == 'moov').firstOrNull ??
      _fail('The file has no movie header (moov).');
  if (moov.header != 8) {
    _fail('This file uses a 64-bit movie header; it is left untouched.');
  }
  final udta = _child(b, moov, 'udta');
  var meta = udta == null ? null : _child(b, udta, 'meta');
  meta ??= _child(b, moov, 'meta');
  final ilst = meta == null ? null : _child(b, meta, 'ilst', skip: 4);
  return (moov, udta, meta, ilst);
}

String? _itemText(Uint8List b, _Atom item) {
  for (final d in _atoms(b, item.body, item.end)) {
    if (d.type == 'data' && d.end - d.body >= 8) {
      final kind = _be32(b, d.body) & 0xFFFFFF;
      final raw = b.sublist(d.body + 8, d.end);
      if (kind == 1) return utf8.decode(raw, allowMalformed: true);
      if (item.type == 'gnre' && raw.length >= 2) {
        final g = (raw[0] << 8) | raw[1];
        return g >= 1 && g <= _gnre.length ? _gnre[g - 1] : null;
      }
    }
  }
  return null;
}

Map<String, String> _mp4Current(Uint8List b) {
  final (_, _, _, ilst) = _mp4Path(b);
  final m = <String, String>{};
  if (ilst == null) return m;
  final items = _atoms(b, ilst.body, ilst.end);
  String? get(String type) {
    for (final i in items) {
      if (i.type == type) return _itemText(b, i);
    }
    return null;
  }

  void put(String k, String? v) {
    if (v != null && v.isNotEmpty) m[k] = v;
  }

  put('title', get('©nam'));
  put('artist', get('©ART'));
  put('album', get('©alb'));
  put('genre', get('©gen') ?? get('gnre'));
  put('comment', get('©cmt'));
  final day = get('©day');
  if (day != null &&
      day.length >= 4 &&
      int.tryParse(day.substring(0, 4)) != null) {
    put('year', day.substring(0, 4));
  }
  return m;
}

Uint8List _box(String type, List<int> body) {
  final n = body.length + 8;
  return Uint8List.fromList([
    n >> 24 & 0xFF,
    n >> 16 & 0xFF,
    n >> 8 & 0xFF,
    n & 0xFF,
    ...latin1.encode(type),
    ...body,
  ]);
}

bool _isEditedItem(String type, Iterable<String> edited) =>
    edited.any((k) => _mp4Atoms[k] == type || (k == 'genre' && type == 'gnre'));

Uint8List _writeMp4(Uint8List file, Map<String, String?> changes) {
  final edits = {
    for (final e in changes.entries)
      if (_mp4Atoms.containsKey(e.key)) e.key: e.value,
  };
  final (moov, udta, meta, ilst) = _mp4Path(file);
  // New ilst body: untouched items verbatim (in order), edited ones replaced in place.
  final items = ilst == null ? <_Atom>[] : _atoms(file, ilst.body, ilst.end);
  final body = BytesBuilder();
  final written = <String>{};
  for (final it in items) {
    if (_isEditedItem(it.type, edits.keys)) {
      final k = edits.keys.firstWhere(
        (k) => _mp4Atoms[k] == it.type || (k == 'genre' && it.type == 'gnre'),
      );
      if (written.add(k) && edits[k] != null) body.add(_item(k, edits[k]!));
    } else {
      body.add(file.sublist(it.start, it.end));
    }
  }
  for (final k in edits.keys) {
    if (written.add(k) && edits[k] != null) body.add(_item(k, edits[k]!));
  }
  final newIlst = _box('ilst', body.takeBytes());

  // Rebuild moov with the new ilst, creating udta/meta when missing.
  Uint8List withChild(
    _Atom parent,
    int skip,
    _Atom? old,
    Uint8List replacement, {
    List<int>? prefix,
  }) {
    final out = BytesBuilder()
      ..add(file.sublist(parent.body, parent.body + skip));
    var done = false;
    for (final c in _atoms(file, parent.body + skip, parent.end)) {
      if (old != null && c.start == old.start) {
        out.add(replacement);
        done = true;
      } else {
        out.add(file.sublist(c.start, c.end));
      }
    }
    if (!done) out.add(replacement);
    return _box(parent.type, out.takeBytes());
  }

  Uint8List newMoov;
  final hdlr = _box('hdlr', [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    ...latin1.encode('mdirappl'),
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
  ]);
  if (meta != null) {
    final newMeta = withChild(meta, 4, ilst, newIlst);
    final metaParent =
        udta != null && meta.start >= udta.body && meta.end <= udta.end
        ? udta
        : null;
    newMoov = metaParent != null
        ? withChild(
            moov,
            0,
            metaParent,
            withChild(metaParent, 0, meta, newMeta),
          )
        : withChild(moov, 0, meta, newMeta);
  } else {
    final newMeta = _box('meta', [0, 0, 0, 0, ...hdlr, ...newIlst]);
    newMoov = udta != null
        ? withChild(moov, 0, udta, withChild(udta, 0, null, newMeta))
        : withChild(moov, 0, null, _box('udta', newMeta));
  }
  final delta = newMoov.length - (moov.end - moov.start);
  final top = _atoms(file, 0, file.length);
  final after = top.where((a) => a.start >= moov.end).toList();
  final out = BytesBuilder(copy: false)..add(file.sublist(0, moov.start));
  var tailStart = moov.end;
  var shift = delta;
  // A 'free' atom right after moov absorbs the change, so the audio stays put.
  if (delta != 0 && after.isNotEmpty && after.first.type == 'free') {
    final free = after.first;
    final newFree = (free.end - free.start) - delta;
    if (newFree >= 8) {
      tailStart = free.end;
      shift = 0;
      newMoovFinal(out, newMoov, 0, false);
      out.add(_box('free', Uint8List(newFree - 8)));
      out.add(file.sublist(tailStart));
      return out.takeBytes();
    }
  }
  final mdatAfter = top.any((a) => a.type == 'mdat' && a.start >= moov.end);
  newMoovFinal(out, newMoov, mdatAfter ? shift : 0, mdatAfter);
  out.add(file.sublist(tailStart));
  return out.takeBytes();
}

/// Appends [moov], first moving every chunk offset by [shift] when the audio
/// (mdat) follows the movie header.
void newMoovFinal(BytesBuilder out, Uint8List moov, int shift, bool patch) {
  if (patch && shift != 0) _shiftChunkOffsets(moov, shift);
  out.add(moov);
}

void _shiftChunkOffsets(Uint8List moov, int shift) {
  final bd = ByteData.sublistView(moov);
  void walk(int start, int end) {
    for (final a in _atoms(moov, start, end)) {
      switch (a.type) {
        case 'trak' || 'mdia' || 'minf' || 'stbl':
          walk(a.body, a.end);
        case 'stco':
          final n = bd.getUint32(a.body + 4);
          for (var i = 0; i < n; i++) {
            final o = a.body + 8 + i * 4;
            final v = bd.getUint32(o) + shift;
            if (v < 0 || v > 0xFFFFFFFF) {
              _fail('The file is too large to rewrite its chunk table.');
            }
            bd.setUint32(o, v);
          }
        case 'co64':
          final n = bd.getUint32(a.body + 4);
          for (var i = 0; i < n; i++) {
            final o = a.body + 8 + i * 8;
            bd.setUint64(o, bd.getUint64(o) + shift);
          }
      }
    }
  }

  final root = _atoms(moov, 0, moov.length).first;
  walk(root.body, root.end);
}

Uint8List _item(String field, String value) {
  final text = field == 'year'
      ? (value.length >= 4 ? value.substring(0, 4) : value)
      : value;
  return _box(
    _mp4Atoms[field]!,
    _box('data', [0, 0, 0, 1, 0, 0, 0, 0, ...utf8.encode(text)]),
  );
}

List<String> _mp4Untouched(Uint8List b, Iterable<String> edited) {
  final (_, _, _, ilst) = _mp4Path(b);
  if (ilst == null) return const [];
  return [
    for (final it in _atoms(b, ilst.body, ilst.end))
      if (!_isEditedItem(it.type, edited)) _sha(b.sublist(it.start, it.end)),
  ]..sort();
}

// ============================================================== public API

/// The current values the writer would replace (1.x `read_current`).
Map<String, String> readWritableTags(String path, String kind) {
  final b = File(path).readAsBytesSync();
  return switch (kind) {
    'mp3' => _id3Current(_parseId3(b)),
    'flac' => _flacCurrent(_parseFlac(b).$1),
    'm4a' => _mp4Current(b),
    _ => _fail('unsupported format'),
  };
}

/// Writes [changes] (field → new value, or null to remove) into the file at
/// [path] in place. Call only on a temporary copy.
void writeTagsInPlace(String path, String kind, Map<String, String?> changes) {
  final f = File(path);
  final b = f.readAsBytesSync();
  final out = switch (kind) {
    'mp3' => _writeId3(b, changes),
    'flac' => _writeFlac(b, changes),
    'm4a' => _writeMp4(b, changes),
    _ => _fail('unsupported format'),
  };
  final raf = f.openSync(mode: FileMode.writeOnly);
  try {
    raf.truncateSync(0);
    raf.writeFromSync(out);
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
}

/// Every tag item that was not edited, as comparable strings.
List<String> untouchedTags(String path, String kind, Iterable<String> edited) {
  final b = File(path).readAsBytesSync();
  return switch (kind) {
    'mp3' => _id3Untouched(_parseId3(b), edited),
    'flac' => _flacUntouched(_parseFlac(b).$1, edited),
    'm4a' => _mp4Untouched(b, edited),
    _ => const [],
  };
}

/// BLAKE3 of the audio data only (everything except the tags), as 1.x
/// `audio_hash` defines the region.
String audioHash(String path, String kind) {
  final b = File(path).readAsBytesSync();
  int start, end;
  switch (kind) {
    case 'mp3':
      start = 0;
      if (b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33) {
        start = 10 + _syncsafe(b, 6) + (b[5] & 0x10 != 0 ? 10 : 0);
      }
      end = b.length;
      if (b.length >= 128 &&
          b[b.length - 128] == 0x54 &&
          b[b.length - 127] == 0x41 &&
          b[b.length - 126] == 0x47) {
        end = b.length - 128;
      }
      while (start < end && b[start] == 0) {
        start++;
      }
    case 'flac':
      start = _parseFlac(b).$2;
      end = b.length;
    case 'm4a':
      final mdat =
          _atoms(b, 0, b.length).where((a) => a.type == 'mdat').firstOrNull ??
          _fail('no audio data atom');
      start = mdat.body;
      end = mdat.end;
    default:
      _fail('unsupported');
  }
  return blake3Hex(Uint8List.sublistView(b, start, end < start ? start : end));
}
