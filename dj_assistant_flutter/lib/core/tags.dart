import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'video.dart';

/// Read-only tag and audio-property reader in pure Dart (replaces 1.x `lofty`):
/// MP3 (ID3v2.2/2.3/2.4, ID3v1, Xing/Info/VBRI), FLAC, Ogg Vorbis, Opus, MP4/M4A
/// (AAC, ALAC), WAV and AIFF. Files are only ever opened for reading.

const supportedExtensions = [
  'mp3',
  'flac',
  'wav',
  'wave',
  'aif',
  'aiff',
  'aifc',
  'm4a',
  'mp4',
  'aac',
  'ogg',
  'oga',
  'opus',
  'ape',
  'wv',
  'mpc',
  'spx',
  'alac',
];
const videoExtensions = ['m4v', 'mov', 'mkv', 'webm', 'avi'];
const unsupportedVideoExtensions = [
  'wmv',
  'flv',
  'mpg',
  'mpeg',
  'm2ts',
  'mts',
  'vob',
  '3gp',
  'ogv',
];
const unsupportedMusicExtensions = [
  'wma',
  'dsf',
  'dff',
  'm4p',
  'ra',
  'rm',
  'ac3',
  'mka',
  'amr',
  'mid',
  'midi',
];

enum ExtKind { supported, unsupportedMusic, video, unsupportedVideo, other }

ExtKind classifyExtension(String ext) {
  final e = ext.toLowerCase();
  if (supportedExtensions.contains(e)) return ExtKind.supported;
  if (unsupportedMusicExtensions.contains(e)) return ExtKind.unsupportedMusic;
  if (videoExtensions.contains(e)) return ExtKind.video;
  if (unsupportedVideoExtensions.contains(e)) return ExtKind.unsupportedVideo;
  return ExtKind.other;
}

class AudioMeta {
  String? format, codec;
  bool? lossless;
  int? durationMs, bitrateKbps, sampleRate, bitDepth, channels;
  String? title,
      artist,
      album,
      albumArtist,
      genre,
      dateText,
      composer,
      label,
      comment,
      isrc,
      key;
  int? year, originalYear, trackNo, discNo;
  double? bpm;
  String? mediaKind;
  String? videoCodec;
  int? width, height;
  double? frameRate;
}

class TagReadException implements Exception {
  TagReadException(this.message);
  final String message;
  @override
  String toString() => message;
}

String? _clean(String? s) {
  if (s == null) return null;
  final v = s.replaceAll('\u0000', ' ').trim();
  return v.isEmpty ? null : v;
}

int? _parseYear(String? s) {
  if (s == null) return null;
  final t = s.trim();
  if (t.length < 4) return null;
  final d = t.substring(0, 4);
  if (!RegExp(r'^\d{4}$').hasMatch(d)) return null;
  final y = int.parse(d);
  return (y >= 1000 && y <= 9999) ? y : null;
}

double? _parseBpm(String? s) {
  if (s == null) return null;
  final v = double.tryParse(s.trim().replaceAll(',', '.'));
  return (v != null && v.isFinite && v > 0 && v < 1000) ? v : null;
}

int? _leadingInt(String? s) {
  if (s == null) return null;
  final m = RegExp(r'^\s*(\d+)').firstMatch(s);
  return m == null ? null : int.tryParse(m[1]!);
}

/// Generic tag fields as (key, value), merged into AudioMeta the way 1.x does:
/// the first non-empty value of each field wins.
class _Tags {
  final map = <String, String>{};
  void put(String k, String? v) {
    final c = _clean(v);
    if (c != null) map.putIfAbsent(k, () => c);
  }

  void applyTo(AudioMeta m) {
    m.title ??= map['title'];
    m.artist ??= map['artist'];
    m.album ??= map['album'];
    m.genre ??= map['genre'];
    m.comment ??= map['comment'];
    m.albumArtist ??= map['album_artist'];
    m.composer ??= map['composer'];
    m.label ??= map['label'] ?? map['publisher'];
    m.isrc ??= map['isrc'];
    m.key ??= map['key'];
    m.bpm ??= _parseBpm(map['bpm']);
    if (m.dateText == null) {
      m.dateText = map['date'] ?? map['year'];
      m.year = _parseYear(m.dateText);
    }
    m.originalYear ??= _parseYear(map['original_date']);
    m.trackNo ??= _leadingInt(map['track']);
    m.discNo ??= _leadingInt(map['disc']);
  }
}

// ---------------------------------------------------------------------------- bytes

int _u16be(List<int> b, int o) => (b[o] << 8) | b[o + 1];
int _u24be(List<int> b, int o) => (b[o] << 16) | (b[o + 1] << 8) | b[o + 2];
int _u32be(List<int> b, int o) =>
    ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) & 0xffffffff;
int _u64be(List<int> b, int o) => (_u32be(b, o) << 32) | _u32be(b, o + 4);
int _u16le(List<int> b, int o) => b[o] | (b[o + 1] << 8);
int _u32le(List<int> b, int o) =>
    (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) & 0xffffffff;
int _u64le(List<int> b, int o) => _u32le(b, o) | (_u32le(b, o + 4) << 32);
String _ascii(List<int> b, int o, int n) =>
    String.fromCharCodes(b.sublist(o, o + n));
int _syncsafe(List<int> b, int o) =>
    (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];

String _latin1(List<int> b) => latin1.decode(b, allowInvalid: true);
String _utf8(List<int> b) => utf8.decode(b, allowMalformed: true);

String _utf16(List<int> b, {bool? bigEndian}) {
  var i = 0;
  var be = bigEndian ?? false;
  if (bigEndian == null && b.length >= 2) {
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

// ---------------------------------------------------------------------------- entry

/// Random access to a file without loading it: 64 KB chunks are read on demand, so
/// a tag read touches only the headers, the tail and whatever the format points at.
class _FileBytes extends ListBase<int> {
  _FileBytes(this._raf) : _length = _raf.lengthSync();
  final RandomAccessFile _raf;
  final int _length;
  static const _chunk = 65536;
  static const _maxCached = 64;
  final _cache = <int, Uint8List>{};

  Uint8List _get(int c) {
    final hit = _cache[c];
    if (hit != null) return hit;
    if (_cache.length >= _maxCached) _cache.remove(_cache.keys.first);
    _raf.setPositionSync(c * _chunk);
    return _cache[c] = _raf.readSync(_chunk);
  }

  @override
  int get length => _length;
  @override
  set length(int _) => throw UnsupportedError('read-only');

  @override
  int operator [](int i) {
    if (i < 0 || i >= _length) throw RangeError.index(i, this);
    return _get(i ~/ _chunk)[i % _chunk];
  }

  @override
  void operator []=(int i, int v) => throw UnsupportedError('read-only');

  @override
  Uint8List sublist(int start, [int? end]) {
    final e = RangeError.checkValidRange(start, end, _length);
    final out = Uint8List(e - start);
    var o = 0;
    var i = start;
    while (i < e) {
      final c = _get(i ~/ _chunk);
      final off = i % _chunk;
      final n = (c.length - off).clamp(0, e - i);
      out.setRange(o, o + n, c, off);
      o += n;
      i += n;
    }
    return out;
  }
}

/// Reads tags and audio properties. Throws [TagReadException] with a readable message
/// when the file is unreadable or not a valid audio file.
AudioMeta readAudioMeta(String path) {
  final RandomAccessFile raf;
  try {
    raf = File(path).openSync();
  } on FileSystemException catch (e) {
    throw TagReadException('cannot open: ${e.message}');
  }
  try {
    return _readFrom(_FileBytes(raf));
  } on FileSystemException catch (e) {
    throw TagReadException('cannot read: ${e.message}');
  } finally {
    raf.closeSync();
  }
}

/// Reads any supported media file: audio through [readAudioMeta], video containers
/// through [probeVideo]. An .mp4 without a video track is read as audio (1.x
/// `read_media_meta`).
AudioMeta readMediaMeta(String path) {
  final dot = path.lastIndexOf('.');
  final sep = path.lastIndexOf(RegExp(r'[\\/]'));
  final ext = dot > sep ? path.substring(dot + 1).toLowerCase() : '';
  final isContainer = ext == 'mp4' || videoExtensions.contains(ext);
  if (!isContainer) return readAudioMeta(path);
  final VideoInfo v;
  try {
    v = probeVideo(path, ext);
  } on VideoProbeException catch (e) {
    if (ext == 'mp4') {
      try {
        return readAudioMeta(path);
      } on TagReadException {
        throw TagReadException(e.message);
      }
    }
    throw TagReadException(e.message);
  }
  var m = AudioMeta();
  if (ext == 'mp4' || ext == 'm4v' || ext == 'mov') {
    try {
      m = readAudioMeta(path);
    } on TagReadException {
      m = AudioMeta();
    }
  }
  if (!v.hasVideo) {
    if (ext == 'mp4' || ext == 'm4v') return readAudioMeta(path);
    throw TagReadException('no video or audio track this version can read');
  }
  m
    ..mediaKind = 'video'
    ..format = v.container
    ..videoCodec = v.videoCodec
    ..width = v.width
    ..height = v.height
    ..frameRate = v.frameRate
    ..durationMs ??= v.durationMs;
  if (m.codec == null || m.codec == '') m.codec = v.audioCodec;
  m
    ..sampleRate ??= v.sampleRate
    ..channels ??= v.channels;
  m.lossless = switch (m.codec ?? v.audioCodec) {
    'PCM' || 'FLAC' || 'ALAC' || 'PCM (float)' => true,
    null => null,
    _ => false,
  };
  m
    ..title ??= v.title
    ..artist ??= v.artist
    ..album ??= v.album
    ..genre ??= v.genre
    ..comment ??= v.comment;
  if (m.year == null && v.date != null) {
    m.year = _parseYear(v.date);
    m.dateText ??= v.date;
  }
  return m;
}

/// Reads tags and properties from bytes already in memory.
AudioMeta readAudioMetaBytes(Uint8List bytes) => _readFrom(bytes);

AudioMeta _readFrom(List<int> b) {
  if (b.length >= 4 && _ascii(b, 0, 4) == 'fLaC') return _flac(b);
  if (b.length >= 4 && _ascii(b, 0, 4) == 'OggS') return _ogg(b);
  if (b.length >= 12 &&
      _ascii(b, 0, 4) == 'RIFF' &&
      _ascii(b, 8, 4) == 'WAVE') {
    return _wav(b);
  }
  if (b.length >= 12 &&
      _ascii(b, 0, 4) == 'FORM' &&
      (_ascii(b, 8, 4) == 'AIFF' || _ascii(b, 8, 4) == 'AIFC')) {
    return _aiff(b);
  }
  if (b.length >= 8 && _ascii(b, 4, 4) == 'ftyp') return _mp4(b);
  if (b.length >= 3 && _ascii(b, 0, 3) == 'ID3') {
    final size = 10 + _syncsafe(b, 6) + ((b[5] & 0x10) != 0 ? 10 : 0);
    // FLAC with a leading ID3 tag
    if (b.length > size + 4 && _ascii(b, size, 4) == 'fLaC') {
      return _flac(b, start: size);
    }
    return _mp3(b);
  }
  if (_findMpegFrame(b, 0) != null) return _mp3(b);
  throw TagReadException(
    'not a recognised audio file (contents do not match a supported format)',
  );
}

// ---------------------------------------------------------------------------- ID3

const _id3Genres = [
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
  'New Age',
  'Oldies',
  'Other',
  'Pop',
  'R&B',
  'Rap', //
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
  'Vocal', //
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
  'Soul', //
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
  'Pop-Folk', //
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
  'Cabaret', //
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
  'Rock & Roll', //
  'Hard Rock',
];

String _genreName(String g) {
  final m =
      RegExp(r'^\((\d+)\)(.*)$').firstMatch(g) ??
      RegExp(r'^(\d+)$').firstMatch(g);
  if (m != null) {
    final n = int.parse(m[1]!);
    final rest = m.groupCount > 1 ? (m[2] ?? '').trim() : '';
    if (rest.isNotEmpty) return rest;
    if (n < _id3Genres.length) return _id3Genres[n];
  }
  return g;
}

String _decodeText(int enc, List<int> b) {
  final s = switch (enc) {
    1 => _utf16(b),
    2 => _utf16(b, bigEndian: true),
    3 => _utf8(b),
    _ => _latin1(b),
  };
  // multiple values are NUL-separated; keep the first (as lofty's accessors do)
  final z = s.indexOf('\u0000');
  return z >= 0 ? s.substring(0, z) : s;
}

/// Splits "description\0value" honouring the text encoding's NUL width.
(String, String) _splitDesc(int enc, List<int> b) {
  final wide = enc == 1 || enc == 2;
  var i = 0;
  while (i < b.length) {
    if (wide) {
      if (i + 1 < b.length && b[i] == 0 && b[i + 1] == 0 && i % 2 == 0) break;
      i += 2;
    } else {
      if (b[i] == 0) break;
      i++;
    }
  }
  final desc = _decodeText(enc, b.sublist(0, i.clamp(0, b.length)));
  final rest = i + (wide ? 2 : 1) <= b.length
      ? b.sublist(i + (wide ? 2 : 1))
      : <int>[];
  return (desc, _decodeText(enc, rest));
}

List<int> _deunsync(List<int> b) {
  final out = <int>[];
  for (var i = 0; i < b.length; i++) {
    out.add(b[i]);
    if (b[i] == 0xFF && i + 1 < b.length && b[i + 1] == 0x00) i++;
  }
  return out;
}

/// Parses an ID3v2 tag at [o]; returns its total length (0 when there is none).
int _id3v2(List<int> b, int o, _Tags t) {
  if (b.length < o + 10 || _ascii(b, o, 3) != 'ID3') return 0;
  final ver = b[o + 3];
  final flags = b[o + 5];
  final size = _syncsafe(b, o + 6);
  final total = 10 + size + ((flags & 0x10) != 0 ? 10 : 0);
  if (o + 10 + size > b.length) return total.clamp(0, b.length - o);
  List<int> body = b.sublist(o + 10, o + 10 + size);
  if ((flags & 0x80) != 0 && ver < 4) body = _deunsync(body);
  var p = 0;
  if ((flags & 0x40) != 0 && body.length >= 4) {
    final ext = ver >= 4
        ? _syncsafe(Uint8List.fromList(body), 0)
        : _u32be(Uint8List.fromList(body), 0) + 4;
    p = ext;
  }
  final idLen = ver == 2 ? 3 : 4;
  final hdr = ver == 2 ? 6 : 10;
  final bb = Uint8List.fromList(body);
  while (p + hdr <= bb.length) {
    final id = _ascii(bb, p, idLen);
    if (id.codeUnits.every((c) => c == 0)) break;
    final fsize = ver == 2
        ? _u24be(bb, p + 3)
        : (ver == 4 ? _syncsafe(bb, p + 4) : _u32be(bb, p + 4));
    final fflags = ver == 2 ? 0 : _u16be(bb, p + 8);
    p += hdr;
    if (fsize <= 0 || p + fsize > bb.length) break;
    List<int> data = bb.sublist(p, p + fsize);
    p += fsize;
    if (ver == 4) {
      if ((fflags & 0x0001) != 0 && data.length >= 4) {
        data = data.sublist(4); // data length indicator
      }
      if ((fflags & 0x0002) != 0 || (flags & 0x80) != 0) data = _deunsync(data);
      if ((fflags & 0x0008) != 0 || (fflags & 0x0004) != 0) {
        continue; // compressed/encrypted
      }
    }
    if (data.isEmpty) continue;
    final enc = data[0];
    String text() => _decodeText(enc, data.sublist(1));
    switch (id) {
      case 'TIT2' || 'TT2':
        t.put('title', text());
      case 'TPE1' || 'TP1':
        t.put('artist', text());
      case 'TALB' || 'TAL':
        t.put('album', text());
      case 'TPE2' || 'TP2':
        t.put('album_artist', text());
      case 'TCON' || 'TCO':
        t.put('genre', _genreName(text()));
      case 'TCOM' || 'TCM':
        t.put('composer', text());
      case 'TPUB' || 'TPB':
        t.put('label', text());
      case 'TSRC' || 'TRC':
        t.put('isrc', text());
      case 'TKEY' || 'TKE':
        t.put('key', text());
      case 'TBPM' || 'TBP':
        t.put('bpm', text());
      case 'TDRC' || 'TYER' || 'TYE':
        t.put('date', text());
      case 'TDOR' || 'TORY' || 'TOR':
        t.put('original_date', text());
      case 'TRCK' || 'TRK':
        t.put('track', text());
      case 'TPOS' || 'TPA':
        t.put('disc', text());
      case 'COMM' || 'COM':
        if (data.length > 4) {
          final (desc, value) = _splitDesc(enc, data.sublist(4));
          if (desc.isEmpty) t.put('comment', value);
        }
      case 'TXXX' || 'TXX':
        final (desc, value) = _splitDesc(enc, data.sublist(1));
        switch (desc.toUpperCase()) {
          case 'INITIALKEY' || 'INITIAL KEY' || 'KEY':
            t.put('key', value);
          case 'LABEL':
            t.put('label', value);
          case 'ORIGINALDATE' || 'ORIGINALYEAR':
            t.put('original_date', value);
        }
    }
  }
  return total;
}

void _id3v1(List<int> b, _Tags t) {
  if (b.length < 128) return;
  final o = b.length - 128;
  if (_ascii(b, o, 3) != 'TAG') return;
  String f(int s, int n) => _latin1(b.sublist(o + s, o + s + n));
  t.put('title', f(3, 30));
  t.put('artist', f(33, 30));
  t.put('album', f(63, 30));
  t.put('year', f(93, 4));
  t.put('comment', f(97, b[o + 125] == 0 ? 28 : 30));
  if (b[o + 125] == 0 && b[o + 126] != 0) t.put('track', '${b[o + 126]}');
  if (b[o + 127] < _id3Genres.length) t.put('genre', _id3Genres[b[o + 127]]);
}

// ---------------------------------------------------------------------------- MP3

const _bitratesV1L3 = [
  0,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  0,
];
const _bitratesV2L3 = [
  0,
  8,
  16,
  24,
  32,
  40,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  144,
  160,
  0,
];
const _bitratesV1L2 = [
  0,
  32,
  48,
  56,
  64,
  80,
  96,
  112,
  128,
  160,
  192,
  224,
  256,
  320,
  384,
  0,
];
const _bitratesV1L1 = [
  0,
  32,
  64,
  96,
  128,
  160,
  192,
  224,
  256,
  288,
  320,
  352,
  384,
  416,
  448,
  0,
];
const _rates = {
  3: [44100, 48000, 32000],
  2: [22050, 24000, 16000],
  0: [11025, 12000, 8000],
};

class _Frame {
  _Frame(
    this.offset,
    this.version,
    this.layer,
    this.bitrate,
    this.sampleRate,
    this.channels,
    this.length,
    this.samples,
  );
  final int offset,
      version,
      layer,
      bitrate,
      sampleRate,
      channels,
      length,
      samples;
}

_Frame? _frameAt(List<int> b, int i) {
  if (i + 4 > b.length || b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) {
    return null;
  }
  final ver = (b[i + 1] >> 3) & 3; // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
  final layer = (b[i + 1] >> 1) & 3; // 1 = III, 2 = II, 3 = I
  final bri = (b[i + 2] >> 4) & 0xF;
  final sri = (b[i + 2] >> 2) & 3;
  if (ver == 1 || layer == 0 || bri == 0 || bri == 15 || sri == 3) return null;
  final padding = (b[i + 2] >> 1) & 1;
  final mode = (b[i + 3] >> 6) & 3;
  final sr = _rates[ver]![sri];
  final br = switch ((ver, layer)) {
    (3, 1) => _bitratesV1L3[bri],
    (3, 2) => _bitratesV1L2[bri],
    (3, 3) => _bitratesV1L1[bri],
    (_, 3) => const [
      0,
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
      176,
      192,
      224,
      256,
      0,
    ][bri],
    _ => _bitratesV2L3[bri],
  };
  final samples = layer == 3 ? 384 : (layer == 2 || ver == 3 ? 1152 : 576);
  final len = layer == 3
      ? ((12 * br * 1000 ~/ sr) + padding) * 4
      : (samples ~/ 8) * br * 1000 ~/ sr + padding;
  return _Frame(i, ver, layer, br, sr, mode == 3 ? 1 : 2, len, samples);
}

/// The first MPEG frame at or after [from] that is followed by another valid frame.
_Frame? _findMpegFrame(List<int> b, int from) {
  final end = (from + 512 * 1024).clamp(0, b.length);
  for (var i = from; i < end - 4; i++) {
    final f = _frameAt(b, i);
    if (f == null || f.length <= 0) continue;
    final next = _frameAt(b, i + f.length);
    if (next != null || i + f.length == b.length) return f;
  }
  return null;
}

AudioMeta _mp3(List<int> b) {
  final t = _Tags();
  var start = 0;
  // ID3v2 tags (there may be more than one, back to back)
  for (var k = 0; k < 4; k++) {
    final n = _id3v2(b, start, t);
    if (n == 0) break;
    start += n;
  }
  final hasV1 = b.length >= 128 && _ascii(b, b.length - 128, 3) == 'TAG';
  _id3v1(b, t);
  final f = _findMpegFrame(b, start);
  if (f == null) {
    throw TagReadException(
      'could not parse audio data: failed to parse Mpeg frames',
    );
  }
  final m = AudioMeta()
    ..format = 'MP3'
    ..codec = 'MP3'
    ..lossless = false
    ..sampleRate = f.sampleRate
    ..channels = f.channels;
  final streamEnd = b.length - (hasV1 ? 128 : 0);
  final streamLen = streamEnd - f.offset;
  // Xing / Info / VBRI header with the frame count
  final sideInfo = f.version == 3
      ? (f.channels == 1 ? 17 : 32)
      : (f.channels == 1 ? 9 : 17);
  final x = f.offset + 4 + sideInfo;
  int? frames;
  if (x + 12 <= b.length &&
      (_ascii(b, x, 4) == 'Xing' || _ascii(b, x, 4) == 'Info')) {
    if ((_u32be(b, x + 4) & 1) != 0) frames = _u32be(b, x + 8);
  } else if (f.offset + 36 + 18 <= b.length &&
      _ascii(b, f.offset + 36, 4) == 'VBRI') {
    frames = _u32be(b, f.offset + 36 + 14);
  }
  final double ms;
  if (frames != null && frames > 0) {
    ms = frames * f.samples * 1000 / f.sampleRate;
  } else {
    ms = streamLen * 8 / f.bitrate;
  }
  if (ms > 0) {
    m.durationMs = ms.floor();
    m.bitrateKbps = (streamLen * 8 / ms).round();
  }
  t.applyTo(m);
  return m;
}

// ---------------------------------------------------------------------------- FLAC

void _vorbisComments(List<int> b, int o, _Tags t, {int? end}) {
  final e = end ?? b.length;
  if (o + 4 > e) return;
  final vendor = _u32le(b, o);
  var p = o + 4 + vendor;
  if (p + 4 > e) return;
  final n = _u32le(b, p);
  p += 4;
  for (var i = 0; i < n && p + 4 <= e; i++) {
    final len = _u32le(b, p);
    p += 4;
    if (p + len > e) break;
    final s = _utf8(b.sublist(p, p + len));
    p += len;
    final eq = s.indexOf('=');
    if (eq <= 0) continue;
    final k = s.substring(0, eq).toUpperCase();
    final v = s.substring(eq + 1);
    final key = switch (k) {
      'TITLE' => 'title',
      'ARTIST' => 'artist',
      'ALBUM' => 'album',
      'ALBUMARTIST' || 'ALBUM ARTIST' => 'album_artist',
      'GENRE' => 'genre',
      'DATE' || 'YEAR' => 'date',
      'ORIGINALDATE' || 'ORIGINALYEAR' => 'original_date',
      'TRACKNUMBER' => 'track',
      'DISCNUMBER' => 'disc',
      'COMPOSER' => 'composer',
      'LABEL' || 'ORGANIZATION' => 'label',
      'PUBLISHER' => 'publisher',
      'COMMENT' || 'DESCRIPTION' => 'comment',
      'ISRC' => 'isrc',
      'BPM' || 'TEMPO' => 'bpm',
      'INITIALKEY' || 'KEY' => 'key',
      _ => null,
    };
    if (key != null) t.put(key, v);
  }
}

AudioMeta _flac(List<int> b, {int start = 0}) {
  final t = _Tags();
  if (start > 0) _id3v2(b, 0, t);
  var p = start + 4;
  int? sr, ch, bps, total;
  var last = false;
  while (!last && p + 4 <= b.length) {
    last = (b[p] & 0x80) != 0;
    final type = b[p] & 0x7F;
    final len = _u24be(b, p + 1);
    p += 4;
    if (p + len > b.length) {
      throw TagReadException(
        'could not parse audio data: failed to parse Flac file',
      );
    }
    if (type == 0 && len >= 18) {
      sr = (b[p + 10] << 12) | (b[p + 11] << 4) | (b[p + 12] >> 4);
      ch = ((b[p + 12] >> 1) & 7) + 1;
      bps = (((b[p + 12] & 1) << 4) | (b[p + 13] >> 4)) + 1;
      total = ((b[p + 13] & 0xF) << 32) | _u32be(b, p + 14);
    } else if (type == 4) {
      _vorbisComments(b, p, t, end: p + len);
    }
    p += len;
  }
  if (sr == null || sr == 0 || p >= b.length) {
    throw TagReadException(
      'could not parse audio data: failed to parse Flac file',
    );
  }
  final m = AudioMeta()
    ..format = 'FLAC'
    ..codec = 'FLAC'
    ..lossless = true
    ..sampleRate = sr
    ..channels = ch
    ..bitDepth = bps;
  if (total != null && total > 0) {
    final ms = total * 1000 / sr;
    m.durationMs = ms.floor();
    m.bitrateKbps = ((b.length - p) * 8 / ms).round();
  }
  t.applyTo(m);
  return m;
}

// ---------------------------------------------------------------------------- Ogg

AudioMeta _ogg(List<int> b) {
  final packets = <List<int>>[];
  var cur = <int>[];
  var p = 0;
  var lastGranule = 0;
  var firstPageEnd = 0;
  while (p + 27 <= b.length && _ascii(b, p, 4) == 'OggS') {
    final granule = _u64le(b, p + 6);
    final nseg = b[p + 26];
    if (p + 27 + nseg > b.length) break;
    final lacing = b.sublist(p + 27, p + 27 + nseg);
    var q = p + 27 + nseg;
    for (final l in lacing) {
      if (q + l > b.length) break;
      if (packets.length < 3) cur.addAll(b.sublist(q, q + l));
      q += l;
      if (l < 255 && packets.length < 3) {
        packets.add(cur);
        cur = [];
      }
    }
    if (granule != 0xFFFFFFFFFFFFFFFF && granule > 0) lastGranule = granule;
    if (firstPageEnd == 0) firstPageEnd = q;
    p = q;
    // The headers are read; the duration comes from the last page instead of
    // walking every page of the file.
    if (packets.length >= 3) break;
  }
  final tail = _lastOggGranule(b);
  if (tail != null && tail > lastGranule) lastGranule = tail;
  if (packets.isEmpty) {
    throw TagReadException(
      'could not parse audio data: not a valid Ogg stream',
    );
  }
  final id = Uint8List.fromList(packets[0]);
  final t = _Tags();
  final m = AudioMeta()..lossless = false;
  int rate;
  var preskip = 0;
  if (id.length >= 30 && id[0] == 1 && _ascii(id, 1, 6) == 'vorbis') {
    m.format = 'Ogg Vorbis';
    m.codec = 'Vorbis';
    m.channels = id[11];
    rate = _u32le(id, 12);
    m.sampleRate = rate;
    final nominal = _u32le(id, 20);
    if (packets.length > 1) {
      final c = Uint8List.fromList(packets[1]);
      if (c.length > 7 && c[0] == 3 && _ascii(c, 1, 6) == 'vorbis') {
        _vorbisComments(c, 7, t);
      }
    }
    if (lastGranule > 0 && rate > 0) {
      final ms = lastGranule * 1000 / rate;
      m.durationMs = ms.floor();
      m.bitrateKbps = nominal > 0
          ? (nominal / 1000).round()
          : ((b.length - firstPageEnd) * 8 / ms).round();
    }
  } else if (id.length >= 19 && _ascii(id, 0, 8) == 'OpusHead') {
    m.format = 'Opus';
    m.codec = 'Opus';
    m.channels = id[9];
    preskip = _u16le(id, 10);
    rate = 48000;
    m.sampleRate = rate;
    if (packets.length > 1) {
      final c = Uint8List.fromList(packets[1]);
      if (c.length > 8 && _ascii(c, 0, 8) == 'OpusTags') {
        _vorbisComments(c, 8, t);
      }
    }
    if (lastGranule > preskip) {
      final ms = (lastGranule - preskip) * 1000 / rate;
      m.durationMs = ms.floor();
      m.bitrateKbps = ((b.length - firstPageEnd) * 8 / ms).round();
    }
  } else {
    throw TagReadException(
      'not a recognised audio file (unsupported Ogg codec)',
    );
  }
  t.applyTo(m);
  return m;
}

/// Granule position of the last complete Ogg page (pages are at most ~64 KB).
int? _lastOggGranule(List<int> b) {
  final from = (b.length - 65536 - 27).clamp(0, b.length);
  for (var i = b.length - 27; i >= from; i--) {
    if (b[i] != 0x4F ||
        b[i + 1] != 0x67 ||
        b[i + 2] != 0x67 ||
        b[i + 3] != 0x53) {
      continue;
    }
    if (b[i + 4] != 0) continue; // stream structure version
    final g = _u64le(b, i + 6);
    if (g != -1 && g > 0) return g;
  }
  return null;
}

// ---------------------------------------------------------------------------- MP4

class _Atom {
  _Atom(this.type, this.start, this.end);
  final String type;
  final int start, end; // content range
}

List<_Atom> _atoms(List<int> b, int start, int end) {
  final out = <_Atom>[];
  var p = start;
  while (p + 8 <= end) {
    var size = _u32be(b, p);
    final type = _ascii(b, p + 4, 4);
    var hdr = 8;
    if (size == 1 && p + 16 <= end) {
      size = _u64be(b, p + 8);
      hdr = 16;
    } else if (size == 0) {
      size = end - p;
    }
    if (size < hdr || p + size > end) break;
    out.add(_Atom(type, p + hdr, p + size));
    p += size;
  }
  return out;
}

_Atom? _child(List<int> b, _Atom a, String type, {int skip = 0}) {
  for (final c in _atoms(b, a.start + skip, a.end)) {
    if (c.type == type) return c;
  }
  return null;
}

AudioMeta _mp4(List<int> b) {
  final top = _atoms(b, 0, b.length);
  final moov = top.where((a) => a.type == 'moov').firstOrNull;
  if (moov == null) {
    throw TagReadException('could not parse audio data: no moov atom');
  }
  final m = AudioMeta();
  final t = _Tags();
  final mvhd = _child(b, moov, 'mvhd');
  double? ms;
  if (mvhd != null) {
    final v = b[mvhd.start];
    final scale = v == 1
        ? _u32be(b, mvhd.start + 20)
        : _u32be(b, mvhd.start + 12);
    final dur = v == 1
        ? _u64be(b, mvhd.start + 24)
        : _u32be(b, mvhd.start + 16);
    if (scale > 0) ms = dur * 1000 / scale;
  }
  String? codec;
  int? avgBitrate;
  for (final trak in _atoms(
    b,
    moov.start,
    moov.end,
  ).where((a) => a.type == 'trak')) {
    final mdia = _child(b, trak, 'mdia');
    if (mdia == null) continue;
    final hdlr = _child(b, mdia, 'hdlr');
    if (hdlr == null || _ascii(b, hdlr.start + 8, 4) != 'soun') continue;
    // The audio track's own duration (includes encoder priming), as 1.x reports.
    final mdhd = _child(b, mdia, 'mdhd');
    if (mdhd != null && mdhd.end - mdhd.start >= 24) {
      final v1 = b[mdhd.start] == 1;
      final ts = _u32be(b, mdhd.start + (v1 ? 20 : 12));
      final d = v1 ? _u64be(b, mdhd.start + 24) : _u32be(b, mdhd.start + 16);
      if (ts > 0 && d > 0) ms = d * 1000 / ts;
    }
    final stsd = [mdia, 'minf', 'stbl', 'stsd']
        .skip(1)
        .fold<_Atom?>(
          mdia,
          (a, n) => a == null ? null : _child(b, a, n as String),
        );
    if (stsd == null) continue;
    final entries = _atoms(b, stsd.start + 8, stsd.end);
    if (entries.isEmpty) continue;
    final e = entries.first;
    codec = switch (e.type) {
      'mp4a' => 'AAC',
      'alac' => 'ALAC',
      'fLaC' => 'FLAC',
      '.mp3' => 'MP3',
      _ => null,
    };
    m.channels = _u16be(b, e.start + 16);
    m.bitDepth = _u16be(b, e.start + 18);
    m.sampleRate = _u32be(b, e.start + 24) >> 16;
    if (e.type == 'alac') {
      final cfg = _child(b, e, 'alac', skip: 28);
      if (cfg != null && cfg.end - cfg.start >= 24) {
        m.bitDepth = b[cfg.start + 9];
        m.channels = b[cfg.start + 13];
        m.sampleRate = _u32be(b, cfg.start + 24);
      }
    } else if (e.type == 'mp4a') {
      m.bitDepth = null; // lossy: the sample-entry field is a placeholder
      final esds = _child(b, e, 'esds', skip: 28);
      if (esds != null) {
        // find DecoderConfigDescriptor (tag 4): avgBitrate is at +9 after its header
        for (var i = esds.start + 4; i + 13 < esds.end; i++) {
          if (b[i] == 0x04) {
            var j = i + 1;
            while (j < esds.end && (b[j] & 0x80) != 0) {
              j++;
            }
            j++;
            if (j + 13 <= esds.end) {
              final objType = b[j];
              if (objType == 0x6B || objType == 0x69) codec = 'MP3';
              avgBitrate = _u32be(b, j + 9);
            }
            break;
          }
        }
      }
    }
    break;
  }
  // iTunes-style tags: moov/udta/meta/ilst
  final udta = _child(b, moov, 'udta');
  final meta = udta == null ? null : _child(b, udta, 'meta');
  final ilst = meta == null ? null : _child(b, meta, 'ilst', skip: 4);
  if (ilst != null) {
    for (final item in _atoms(b, ilst.start, ilst.end)) {
      String? name;
      String? value;
      List<int>? raw;
      for (final a in _atoms(b, item.start, item.end)) {
        if (a.type == 'name' && a.end - a.start > 4) {
          name = _utf8(b.sublist(a.start + 4, a.end));
        }
        if (a.type == 'data' && a.end - a.start >= 8) {
          raw = b.sublist(a.start + 8, a.end);
          final kind = _u32be(b, a.start) & 0xFFFFFF;
          value = kind == 1 ? _utf8(raw) : null;
        }
      }
      final key = switch (item.type) {
        '©nam' => 'title',
        '©ART' => 'artist',
        '©alb' => 'album',
        'aART' => 'album_artist',
        '©gen' => 'genre',
        '©day' => 'date',
        '©wrt' => 'composer',
        '©cmt' => 'comment',
        '----' => switch ((name ?? '').toUpperCase()) {
          'INITIALKEY' || 'KEY' => 'key',
          'LABEL' => 'label',
          'PUBLISHER' => 'publisher',
          'ISRC' => 'isrc',
          'ORIGINALDATE' => 'original_date',
          _ => null,
        },
        _ => null,
      };
      if (key != null) t.put(key, value);
      if (item.type == 'gnre' && raw != null && raw.length >= 2) {
        final g = _u16be(raw, 0) - 1;
        if (g >= 0 && g < _id3Genres.length) t.put('genre', _id3Genres[g]);
      }
      if ((item.type == 'trkn' || item.type == 'disk') &&
          raw != null &&
          raw.length >= 4) {
        t.put(item.type == 'trkn' ? 'track' : 'disc', '${_u16be(raw, 2)}');
      }
      if (item.type == 'tmpo' && raw != null && raw.length >= 2) {
        t.put('bpm', '${_u16be(raw, 0)}');
      }
    }
  }
  m.codec = codec;
  m.lossless = switch (codec) {
    'ALAC' || 'FLAC' => true,
    'AAC' || 'MP3' => false,
    _ => null,
  };
  m.format = codec == null ? 'MP4' : 'M4A ($codec)';
  if (ms != null && ms > 0) {
    m.durationMs = ms.floor();
    final mdat = top.where((a) => a.type == 'mdat').firstOrNull;
    // Media data over duration (1.x/lofty); the esds average is only a fallback.
    if (mdat != null && mdat.end > mdat.start) {
      m.bitrateKbps = ((mdat.end - mdat.start) * 8 / ms).floor();
    } else if (avgBitrate != null && avgBitrate > 0) {
      m.bitrateKbps = (avgBitrate / 1000).round();
    }
  }
  t.applyTo(m);
  return m;
}

// ---------------------------------------------------------------------------- WAV / AIFF

void _riffInfo(List<int> b, int start, int end, _Tags t) {
  for (var p = start; p + 8 <= end;) {
    final id = _ascii(b, p, 4);
    final len = _u32le(b, p + 4);
    final s = p + 8;
    if (s + len > end) break;
    final v = _latin1(b.sublist(s, s + len));
    switch (id) {
      case 'INAM':
        t.put('title', v);
      case 'IART':
        t.put('artist', v);
      case 'IPRD':
        t.put('album', v);
      case 'IGNR':
        t.put('genre', v);
      case 'ICRD':
        t.put('date', v);
      case 'ICMT':
        t.put('comment', v);
      case 'ITRK':
        t.put('track', v);
    }
    p = s + len + (len & 1);
  }
}

AudioMeta _wav(List<int> b) {
  final t = _Tags();
  int? fmt, ch, sr, bits, dataLen, byteRate;
  for (var p = 12; p + 8 <= b.length;) {
    final id = _ascii(b, p, 4);
    final len = _u32le(b, p + 4);
    final s = p + 8;
    final e = (s + len).clamp(0, b.length);
    if (id == 'fmt ' && len >= 16) {
      fmt = _u16le(b, s);
      ch = _u16le(b, s + 2);
      sr = _u32le(b, s + 4);
      byteRate = _u32le(b, s + 8);
      bits = _u16le(b, s + 14);
      if (fmt == 0xFFFE && len >= 26) fmt = _u16le(b, s + 24);
    } else if (id == 'data') {
      dataLen = e - s;
    } else if (id == 'LIST' && len >= 4 && _ascii(b, s, 4) == 'INFO') {
      _riffInfo(b, s + 4, e, t);
    } else if (id == 'id3 ' || id == 'ID3 ') {
      _id3v2(b, s, t);
    }
    p = s + len + (len & 1);
  }
  if (sr == null || sr == 0) {
    throw TagReadException('could not parse audio data: missing fmt chunk');
  }
  final m = AudioMeta()
    ..format = 'WAV'
    ..sampleRate = sr
    ..channels = ch
    ..bitDepth = bits;
  final (wc, wl) = switch (fmt) {
    1 => ('PCM', true),
    3 => ('PCM float', true),
    _ => ('format $fmt', null),
  };
  m
    ..codec = wc
    ..lossless = wl;
  if (dataLen != null && byteRate != null && byteRate > 0) {
    final ms = dataLen * 1000 / byteRate;
    m.durationMs = ms.floor();
    m.bitrateKbps = (byteRate * 8 / 1000).round();
  }
  t.applyTo(m);
  return m;
}

double _ieee80(List<int> b, int o) {
  final exp = ((b[o] & 0x7F) << 8) | b[o + 1];
  // The 64-bit mantissa uses its top bit, so read it as two unsigned halves.
  final hi = _u32be(b, o + 2), lo = _u32be(b, o + 6);
  if (exp == 0 && hi == 0 && lo == 0) return 0;
  return (hi * 4294967296.0 + lo) *
      _pow2(exp - 16383 - 63) *
      ((b[o] & 0x80) != 0 ? -1 : 1);
}

double _pow2(int e) {
  var r = 1.0;
  if (e >= 0) {
    for (var i = 0; i < e; i++) {
      r *= 2;
    }
  } else {
    for (var i = 0; i < -e; i++) {
      r /= 2;
    }
  }
  return r;
}

AudioMeta _aiff(List<int> b) {
  final t = _Tags();
  final aifc = _ascii(b, 8, 4) == 'AIFC';
  int? ch, frames, bits;
  double? sr;
  String comp = 'NONE';
  for (var p = 12; p + 8 <= b.length;) {
    final id = _ascii(b, p, 4);
    final len = _u32be(b, p + 4);
    final s = p + 8;
    if (id == 'COMM' && len >= 18) {
      ch = _u16be(b, s);
      frames = _u32be(b, s + 2);
      bits = _u16be(b, s + 6);
      sr = _ieee80(b, s + 8);
      if (aifc && len >= 22) comp = _ascii(b, s + 18, 4);
    } else if (id == 'NAME') {
      t.put('title', _latin1(b.sublist(s, s + len)));
    } else if (id == 'AUTH') {
      t.put('artist', _latin1(b.sublist(s, s + len)));
    } else if (id == 'ID3 ' || id == 'id3 ') {
      _id3v2(b, s, t);
    }
    p = s + len + (len & 1);
  }
  if (sr == null || sr <= 0) {
    throw TagReadException('could not parse audio data: missing COMM chunk');
  }
  final m = AudioMeta()
    ..format = 'AIFF'
    ..sampleRate = sr.round()
    ..channels = ch
    ..bitDepth = bits;
  final (ac, al) = switch (comp) {
    'NONE' || 'sowt' => ('PCM', true),
    'fl32' || 'fl64' || 'FL32' || 'FL64' => ('PCM float', true),
    _ => (comp, null),
  };
  m
    ..codec = ac
    ..lossless = al;
  if (frames != null && frames > 0) {
    final ms = frames * 1000 / sr;
    m.durationMs = ms.floor();
    m.bitrateKbps = (sr * (bits ?? 16) * (ch ?? 1) / 1000).round();
  }
  t.applyTo(m);
  return m;
}
