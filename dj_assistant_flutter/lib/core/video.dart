import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Read-only probing of DJ video files (music videos, visuals, loops), ported from
/// 1.x `video.rs`: MP4 / M4V / MOV (ISO-BMFF boxes), Matroska / WebM (EBML) and
/// AVI (RIFF). Only container headers are read — never the frames — and every
/// length taken from the file is checked against the file size and [maxHeader].

/// Largest header region read into memory (moov, Matroska Tracks/Tags, AVI hdrl).
const maxHeader = 32 * 1024 * 1024;

class VideoInfo {
  /// Short container name shown in the Format column: MP4, MOV, M4V, MKV, WebM, AVI.
  String container = '';
  bool hasVideo = false;
  String? videoCodec;
  int? width, height;
  double? frameRate;
  int? durationMs;
  String? audioCodec;
  int? sampleRate, channels;
  String? title, artist, album, genre, date, comment;
}

class VideoProbeException implements Exception {
  VideoProbeException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _fail(String m) => throw VideoProbeException(m);

String? _clean(String s) {
  final t = s.trim().replaceAll(RegExp(r'^\x00+|\x00+$'), '').trim();
  return t.isEmpty ? null : t;
}

double? _roundFps(double f) =>
    (f.isFinite && f > 0.5 && f < 1000) ? (f * 1000).round() / 1000 : null;

int? _be16(Uint8List b, int o) =>
    o + 2 <= b.length ? (b[o] << 8) | b[o + 1] : null;
int? _be32(Uint8List b, int o) => o + 4 <= b.length
    ? ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) &
          0xffffffff
    : null;
int? _be64(Uint8List b, int o) {
  final hi = _be32(b, o), lo = _be32(b, o + 4);
  return (hi == null || lo == null) ? null : (hi << 32) | lo;
}

int? _le16(Uint8List b, int o) =>
    o + 2 <= b.length ? b[o] | (b[o + 1] << 8) : null;
int? _le32(Uint8List b, int o) => o + 4 <= b.length
    ? (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) &
          0xffffffff
    : null;

String _str(List<int> b) => utf8.decode(b, allowMalformed: true);
String _fourcc(Uint8List b, int o) => latin1.decode(b.sublist(o, o + 4));

Uint8List _readAt(RandomAccessFile f, int pos, int n) {
  f.setPositionSync(pos);
  return f.readSync(n);
}

/// Probes a video container chosen by extension. Throws [VideoProbeException]
/// when the file is not a readable container of that kind.
VideoInfo probeVideo(String path, String ext) {
  final RandomAccessFile f;
  try {
    f = File(path).openSync();
  } on FileSystemException catch (e) {
    _fail('cannot open: ${e.message}');
  }
  try {
    final len = f.lengthSync();
    return switch (ext) {
      'mp4' || 'm4v' || 'mov' => _probeMp4(f, len, ext),
      'mkv' || 'webm' => _probeMkv(f, len),
      'avi' => _probeAvi(f, len),
      _ => _fail('$ext video files are not supported'),
    };
  } on FileSystemException catch (e) {
    _fail('cannot read: ${e.message}');
  } finally {
    f.closeSync();
  }
}

// ---------------------------------------------------------------- MP4 / MOV

String _mp4VideoCodec(String c) => switch (c) {
  'avc1' || 'avc3' => 'H.264',
  'hvc1' || 'hev1' => 'HEVC (H.265)',
  'av01' => 'AV1',
  'vp09' => 'VP9',
  'vp08' => 'VP8',
  'mp4v' => 'MPEG-4 Part 2',
  'apcn' || 'apch' || 'apcs' || 'apco' || 'ap4h' || 'ap4x' => 'Apple ProRes',
  'jpeg' || 'mjpa' || 'mjpb' => 'Motion JPEG',
  'hap1' || 'hap5' || 'hapy' || 'hapm' || 'hapa' => 'HAP',
  'dvh1' || 'dvhe' => 'Dolby Vision',
  _ => c.trim(),
};

String _mp4AudioCodec(String c) => switch (c) {
  'mp4a' => 'AAC',
  'alac' => 'ALAC',
  '.mp3' || 'mp3 ' => 'MP3',
  'ac-3' => 'AC-3',
  'ec-3' => 'E-AC-3',
  'Opus' => 'Opus',
  'fLaC' => 'FLAC',
  'lpcm' || 'sowt' || 'twos' || 'in24' || 'in32' || 'fl32' || 'raw ' => 'PCM',
  _ => c.trim(),
};

/// Child boxes of [b]: (type, payload).
List<(String, Uint8List)> _boxes(Uint8List b) {
  final out = <(String, Uint8List)>[];
  var o = 0;
  while (o + 8 <= b.length) {
    final size32 = _be32(b, o)!;
    final type = _fourcc(b, o + 4);
    int hdr, size;
    if (size32 == 0) {
      hdr = 8;
      size = b.length - o;
    } else if (size32 == 1) {
      final s = _be64(b, o + 8);
      if (s == null) break;
      hdr = 16;
      size = s;
    } else {
      hdr = 8;
      size = size32;
    }
    if (size < hdr || o + size > b.length) break;
    out.add((type, Uint8List.sublistView(b, o + hdr, o + size)));
    o += size;
  }
  return out;
}

Uint8List? _child(Uint8List? b, String type) {
  if (b == null) return null;
  for (final (t, p) in _boxes(b)) {
    if (t == type) return p;
  }
  return null;
}

VideoInfo _probeMp4(RandomAccessFile f, int len, String ext) {
  const notMp4 = 'not a recognised MP4/MOV file (contents do not match)';
  var pos = 0;
  Uint8List? moov;
  var sawFtyp = false;
  var brand = '';
  while (pos + 8 <= len) {
    final h = _readAt(f, pos, 16);
    if (h.length < 8) break;
    final size32 = _be32(h, 0)!;
    final type = _fourcc(h, 4);
    int hdr, size;
    if (size32 == 0) {
      hdr = 8;
      size = len - pos;
    } else if (size32 == 1) {
      if (h.length < 16) break;
      hdr = 16;
      size = _be64(h, 8)!;
    } else {
      hdr = 8;
      size = size32;
    }
    if (size < hdr || pos + size > len) break;
    if (pos == 0 &&
        !const [
          'ftyp',
          'moov',
          'wide',
          'mdat',
          'free',
          'skip',
          'pnot',
        ].contains(type)) {
      _fail(notMp4);
    }
    if (type == 'ftyp') {
      sawFtyp = true;
      if (h.length >= 12) brand = _fourcc(h, 8);
    }
    if (type == 'moov') {
      final body = size - hdr;
      if (body > maxHeader) {
        _fail('movie header is unreasonably large; file skipped');
      }
      final buf = _readAt(f, pos + hdr, body);
      if (buf.length < body) {
        _fail('file is truncated (movie header incomplete)');
      }
      moov = buf;
      break;
    }
    pos += size;
  }
  if (moov == null) {
    _fail(sawFtyp ? 'no movie header found (file may be incomplete)' : notMp4);
  }
  final v = VideoInfo()
    ..container = (ext == 'mov' || brand == 'qt  ')
        ? 'MOV'
        : ext == 'm4v'
        ? 'M4V'
        : 'MP4';
  final mvhd = _child(moov, 'mvhd');
  if (mvhd != null) {
    final v1 = mvhd.isNotEmpty && mvhd[0] == 1;
    final ts = v1 ? _be32(mvhd, 20) : _be32(mvhd, 12);
    final d = v1 ? _be64(mvhd, 24) : _be32(mvhd, 16);
    if (ts != null && d != null && ts > 0 && d > 0 && d != 0xffffffff) {
      v.durationMs = (d * 1000 / ts).round();
    }
  }
  for (final (t, trak) in _boxes(moov)) {
    if (t != 'trak') continue;
    final mdia = _child(trak, 'mdia');
    if (mdia == null) continue;
    final hdlr = _child(mdia, 'hdlr');
    final handler = (hdlr != null && hdlr.length >= 12) ? _fourcc(hdlr, 8) : '';
    var mdTs = 0, mdDur = 0;
    final mdhd = _child(mdia, 'mdhd');
    if (mdhd != null) {
      if (mdhd.isNotEmpty && mdhd[0] == 1) {
        mdTs = _be32(mdhd, 20) ?? 0;
        mdDur = _be64(mdhd, 24) ?? 0;
      } else {
        mdTs = _be32(mdhd, 12) ?? 0;
        mdDur = _be32(mdhd, 16) ?? 0;
      }
    }
    final stbl = _child(_child(mdia, 'minf'), 'stbl');
    final stsd = _child(stbl, 'stsd');
    final entry = (stsd != null && stsd.length >= 16)
        ? Uint8List.sublistView(stsd, 8)
        : null;
    if (handler == 'vide' && !v.hasVideo) {
      v.hasVideo = true;
      if (entry != null) {
        v.videoCodec = _mp4VideoCodec(_fourcc(entry, 4));
        // Visual sample entry: width at 32, height at 34.
        final w = _be16(entry, 32) ?? 0, h = _be16(entry, 34) ?? 0;
        if (w > 0 && h > 0) {
          v
            ..width = w
            ..height = h;
        }
      }
      if (v.width == null) {
        final tkhd = _child(trak, 'tkhd');
        if (tkhd != null && tkhd.length >= 8) {
          final n = tkhd.length;
          final w = (_be32(tkhd, n - 8) ?? 0) >> 16,
              h = (_be32(tkhd, n - 4) ?? 0) >> 16;
          if (w > 0 && h > 0) {
            v
              ..width = w
              ..height = h;
          }
        }
      }
      final stts = _child(stbl, 'stts');
      if (stts != null) {
        final count = (_be32(stts, 4) ?? 0).clamp(0, 1000000);
        var frames = 0;
        for (var i = 0; i < count; i++) {
          final c = _be32(stts, 8 + i * 8);
          if (c == null) break;
          frames += c;
        }
        if (frames > 0 && mdTs > 0 && mdDur > 0) {
          v.frameRate = _roundFps(frames * mdTs / mdDur);
        }
      }
    } else if (handler == 'soun' && v.audioCodec == null) {
      if (entry != null) {
        v.audioCodec = _mp4AudioCodec(_fourcc(entry, 4));
        // Sound sample entry: channels at 24, sample rate (16.16) at 32.
        final c = _be16(entry, 24);
        v.channels = (c != null && c > 0) ? c : null;
        final r = _be32(entry, 32);
        v.sampleRate = (r != null && (r >> 16) > 0) ? r >> 16 : null;
      }
    }
  }
  // QuickTime-style user data (©nam, ©ART…) used by .mov files.
  final udta = _child(moov, 'udta');
  if (udta != null) {
    for (final (t, p) in _boxes(udta)) {
      String? text() {
        final n = _be16(p, 0);
        if (n == null || 4 + n > p.length) return null;
        return _clean(_str(p.sublist(4, 4 + n)));
      }

      switch (t) {
        case '©nam':
          v.title ??= text();
        case '©ART':
          v.artist ??= text();
        case '©alb':
          v.album ??= text();
        case '©gen':
          v.genre ??= text();
        case '©day':
          v.date ??= text();
        case '©cmt':
          v.comment ??= text();
      }
    }
  }
  return v;
}

// ------------------------------------------------------------ Matroska/WebM

const _ebml = 0x1A45DFA3;
const _doctype = 0x4282;
const _segment = 0x18538067;
const _info = 0x1549A966;
const _timecodeScale = 0x2AD7B1;
const _duration = 0x4489;
const _segTitle = 0x7BA9;
const _tracks = 0x1654AE6B;
const _trackEntry = 0xAE;
const _trackType = 0x83;
const _codecId = 0x86;
const _defaultDuration = 0x23E383;
const _video = 0xE0;
const _pixelWidth = 0xB0;
const _pixelHeight = 0xBA;
const _audio = 0xE1;
const _samplingFreq = 0xB5;
const _channels = 0x9F;
const _tags = 0x1254C367;
const _tag = 0x7373;
const _targets = 0x63C0;
const _simpleTag = 0x67C8;
const _tagName = 0x45A3;
const _tagString = 0x4487;

int _leadingZeros8(int x) {
  var n = 0;
  for (var m = 0x80; m > 0 && (x & m) == 0; m >>= 1) {
    n++;
  }
  return n;
}

/// EBML element ID (marker bits kept): (id, length).
(int, int)? ebmlId(List<int> b, [int o = 0]) {
  if (o >= b.length) return null;
  final n = _leadingZeros8(b[o]) + 1;
  if (n > 4 || b.length - o < n) return null;
  var v = 0;
  for (var i = 0; i < n; i++) {
    v = (v << 8) | b[o + i];
  }
  return (v, n);
}

/// EBML size: (size, or null for "unknown"; length).
(int?, int)? ebmlSize(List<int> b, [int o = 0]) {
  if (o >= b.length) return null;
  final first = b[o];
  final n = _leadingZeros8(first) + 1;
  if (n > 8 || b.length - o < n) return null;
  final mask = (1 << (8 - n)) - 1;
  var v = first & mask;
  var allOnes = v == mask;
  for (var i = 1; i < n; i++) {
    v = (v << 8) | b[o + i];
    allOnes &= b[o + i] == 0xFF;
  }
  return (allOnes ? null : v, n);
}

List<(int, Uint8List)> _ebmlChildren(Uint8List b) {
  final out = <(int, Uint8List)>[];
  var o = 0;
  while (o < b.length) {
    final id = ebmlId(b, o);
    if (id == null) break;
    final sz = ebmlSize(b, o + id.$2);
    if (sz == null) break;
    final start = o + id.$2 + sz.$2;
    final s = sz.$1;
    final end = (s != null && start + s <= b.length) ? start + s : b.length;
    out.add((id.$1, Uint8List.sublistView(b, start, end)));
    o = end;
  }
  return out;
}

int _ebmlUint(Uint8List b) {
  var v = 0;
  for (var i = 0; i < b.length && i < 8; i++) {
    v = (v << 8) | b[i];
  }
  return v;
}

double? _ebmlFloat(Uint8List b) => switch (b.length) {
  4 => ByteData.sublistView(b).getFloat32(0),
  8 => ByteData.sublistView(b).getFloat64(0),
  _ => null,
};

String? _ebmlStr(Uint8List b) => _clean(_str(b));

Uint8List? _find(List<(int, Uint8List)> kids, int id) {
  for (final (k, v) in kids) {
    if (k == id) return v;
  }
  return null;
}

String _mkvVideoCodec(String id) => switch (id) {
  'V_MPEG4/ISO/AVC' => 'H.264',
  'V_MPEGH/ISO/HEVC' => 'HEVC (H.265)',
  'V_VP8' => 'VP8',
  'V_VP9' => 'VP9',
  'V_AV1' => 'AV1',
  'V_MJPEG' => 'Motion JPEG',
  'V_PRORES' => 'Apple ProRes',
  'V_THEORA' => 'Theora',
  _ when id.startsWith('V_MPEG4/ISO/') => 'MPEG-4 Part 2',
  _ when id.startsWith('V_MPEG2') => 'MPEG-2',
  _ => id.replaceFirst(RegExp('^(V_)+'), ''),
};

String _mkvAudioCodec(String id) => switch (id) {
  'A_OPUS' => 'Opus',
  'A_VORBIS' => 'Vorbis',
  'A_MPEG/L3' => 'MP3',
  'A_AC3' => 'AC-3',
  'A_EAC3' => 'E-AC-3',
  'A_FLAC' => 'FLAC',
  'A_ALAC' => 'ALAC',
  _ when id.startsWith('A_AAC') => 'AAC',
  _ when id.startsWith('A_PCM') => 'PCM',
  _ => id.replaceFirst(RegExp('^(A_)+'), ''),
};

VideoInfo _probeMkv(RandomAccessFile f, int len) {
  const notMkv = 'not a recognised Matroska/WebM file (contents do not match)';
  final head = _readAt(f, 0, 64);
  final id = ebmlId(head) ?? _fail(notMkv);
  if (id.$1 != _ebml) _fail(notMkv);
  final hs = ebmlSize(head, id.$2) ?? _fail(notMkv);
  final hsize = hs.$1;
  if (hsize == null || hsize >= 4096) _fail(notMkv);
  final hstart = id.$2 + hs.$2;
  final header = _readAt(f, hstart, hsize);
  final dt = _find(_ebmlChildren(header), _doctype);
  final doctype = dt == null ? '' : (_ebmlStr(dt) ?? '');
  if (doctype != 'matroska' && doctype != 'webm') _fail(notMkv);
  final v = VideoInfo()..container = doctype == 'webm' ? 'WebM' : 'MKV';
  var pos = hstart + hsize;
  final seg = _readAt(f, pos, 12);
  final sid = ebmlId(seg) ?? _fail(notMkv);
  if (sid.$1 != _segment) {
    _fail('Matroska file has no segment (file may be incomplete)');
  }
  final ss = ebmlSize(seg, sid.$2) ?? _fail(notMkv);
  pos += sid.$2 + ss.$2;
  final segEnd = ss.$1 == null ? len : (pos + ss.$1!).clamp(0, len);
  var scale = 1000000;
  double? duration;
  var sawTracks = false;
  var guard = 0;
  while (pos + 2 <= segEnd && guard < 10000) {
    guard++;
    final h = _readAt(f, pos, 12);
    final eid = ebmlId(h);
    if (eid == null) break;
    final es = ebmlSize(h, eid.$2);
    if (es == null) break;
    final body = pos + eid.$2 + es.$2;
    final size = es.$1;
    if (size == null) break; // unknown-size element (live-streamed cluster)
    if (body + size > len) {
      if (eid.$1 == _tracks || eid.$1 == _info) {
        _fail('file is truncated (track header incomplete)');
      }
      break;
    }
    if ((eid.$1 == _info || eid.$1 == _tracks || eid.$1 == _tags) &&
        size <= maxHeader) {
      final b = _readAt(f, body, size);
      if (eid.$1 == _info) {
        for (final (cid, c) in _ebmlChildren(b)) {
          if (cid == _timecodeScale) {
            final s = _ebmlUint(c);
            scale = s < 1 ? 1 : s;
          } else if (cid == _duration) {
            duration = _ebmlFloat(c);
          } else if (cid == _segTitle) {
            v.title ??= _ebmlStr(c);
          }
        }
      } else if (eid.$1 == _tracks) {
        sawTracks = true;
        for (final (tid, t) in _ebmlChildren(b)) {
          if (tid != _trackEntry) continue;
          final kids = _ebmlChildren(t);
          final tyB = _find(kids, _trackType);
          final ty = tyB == null ? null : _ebmlUint(tyB);
          final cB = _find(kids, _codecId);
          final codec = cB == null ? '' : (_ebmlStr(cB) ?? '');
          if (ty == 1 && !v.hasVideo) {
            v
              ..hasVideo = true
              ..videoCodec = _mkvVideoCodec(codec);
            final dd = _find(kids, _defaultDuration);
            if (dd != null && _ebmlUint(dd) > 0) {
              v.frameRate = _roundFps(1e9 / _ebmlUint(dd));
            }
            final vid = _find(kids, _video);
            if (vid != null) {
              for (final (k, x) in _ebmlChildren(vid)) {
                final n = _ebmlUint(x);
                if (k == _pixelWidth) v.width = n > 0 ? n : null;
                if (k == _pixelHeight) v.height = n > 0 ? n : null;
              }
            }
          } else if (ty == 2 && v.audioCodec == null) {
            v.audioCodec = _mkvAudioCodec(codec);
            final au = _find(kids, _audio);
            if (au != null) {
              for (final (k, x) in _ebmlChildren(au)) {
                if (k == _samplingFreq) {
                  final r = _ebmlFloat(x)?.round();
                  v.sampleRate = (r != null && r > 0) ? r : null;
                } else if (k == _channels) {
                  final c = _ebmlUint(x);
                  v.channels = c > 0 ? c : null;
                }
              }
            }
          }
        }
      } else {
        for (final (tid, tag) in _ebmlChildren(b)) {
          if (tid != _tag) continue;
          final parts = _ebmlChildren(tag);
          // Only whole-file tags (no per-track target).
          final perTrack = parts.any(
            (e) =>
                e.$1 == _targets &&
                _ebmlChildren(e.$2).any((x) => x.$1 == 0x63C5),
          );
          if (perTrack) continue;
          for (final (sidT, st) in parts) {
            if (sidT != _simpleTag) continue;
            final kids = _ebmlChildren(st);
            final nB = _find(kids, _tagName);
            final name = (nB == null ? '' : (_ebmlStr(nB) ?? '')).toUpperCase();
            final sB = _find(kids, _tagString);
            final val = sB == null ? null : _ebmlStr(sB);
            if (val == null) continue;
            switch (name) {
              case 'TITLE':
                v.title ??= val;
              case 'ARTIST':
                v.artist ??= val;
              case 'ALBUM':
                v.album ??= val;
              case 'GENRE':
                v.genre ??= val;
              case 'DATE' || 'DATE_RELEASED' || 'DATE_RECORDED' || 'YEAR':
                v.date ??= val;
              case 'COMMENT':
                v.comment ??= val;
            }
          }
        }
      }
    }
    pos = body + size;
  }
  if (!sawTracks) _fail('no track information found (file may be incomplete)');
  final d = duration;
  if (d != null && d.isFinite && d > 0) {
    v.durationMs = (d * scale / 1e6).round();
  }
  return v;
}

// ---------------------------------------------------------------------- AVI

String _aviVideoCodec(Uint8List fourcc) {
  final s = latin1.decode(fourcc).toUpperCase().trim();
  return switch (s) {
    'XVID' ||
    'DIVX' ||
    'DX50' ||
    'FMP4' ||
    'MP4V' ||
    'DIV3' ||
    'MP42' ||
    'MP43' => 'MPEG-4 Part 2',
    'H264' || 'X264' || 'AVC1' => 'H.264',
    'HEVC' || 'H265' || 'HVC1' => 'HEVC (H.265)',
    'MJPG' => 'Motion JPEG',
    'DVSD' || 'DV25' || 'DV50' => 'DV',
    'HAP1' || 'HAP5' || 'HAPY' => 'HAP',
    '' => 'Uncompressed',
    _ => s,
  };
}

String _aviAudioCodec(int tag) => switch (tag) {
  0x0001 => 'PCM',
  0x0003 => 'PCM (float)',
  0x0055 => 'MP3',
  0x0050 => 'MPEG audio',
  0x00FF || 0x1610 || 0x706D => 'AAC',
  0x2000 => 'AC-3',
  0x0161 || 0x0162 => 'WMA',
  _ => 'format 0x${tag.toRadixString(16).toUpperCase().padLeft(4, '0')}',
};

List<(String, Uint8List)> _riffChunks(Uint8List b) {
  final out = <(String, Uint8List)>[];
  var o = 0;
  while (o + 8 <= b.length) {
    final id = _fourcc(b, o);
    final size = _le32(b, o + 4) ?? 0;
    final start = o + 8;
    final end = (start + size).clamp(0, b.length);
    out.add((id, Uint8List.sublistView(b, start, end)));
    o = end + (size & 1);
  }
  return out;
}

VideoInfo _probeAvi(RandomAccessFile f, int len) {
  const notAvi = 'not a recognised AVI file (contents do not match)';
  final head = _readAt(f, 0, 12);
  if (head.length < 12 ||
      _fourcc(head, 0) != 'RIFF' ||
      _fourcc(head, 8) != 'AVI ') {
    _fail(notAvi);
  }
  final v = VideoInfo()..container = 'AVI';
  var pos = 12;
  var sawHdrl = false;
  var usPerFrame = 0, totalFrames = 0;
  var guard = 0;
  while (pos + 12 <= len && guard < 1000) {
    guard++;
    final h = _readAt(f, pos, 12);
    if (h.length < 12) break;
    final size = _le32(h, 4) ?? 0;
    final isList = _fourcc(h, 0) == 'LIST';
    final listType = _fourcc(h, 8);
    if (isList && (listType == 'hdrl' || listType == 'INFO')) {
      if (size > maxHeader || pos + 8 + size > len) {
        if (listType == 'hdrl') _fail('file is truncated (header incomplete)');
        break;
      }
      final b = _readAt(f, pos + 12, size - 4);
      if (listType == 'hdrl') {
        sawHdrl = true;
        for (final (id, c) in _riffChunks(b)) {
          if (id == 'avih') {
            usPerFrame = _le32(c, 0) ?? 0;
            totalFrames = _le32(c, 16) ?? 0;
            final w = _le32(c, 32), hh = _le32(c, 36);
            v.width = (w != null && w > 0) ? w : null;
            v.height = (hh != null && hh > 0) ? hh : null;
          } else if (id == 'LIST' && c.length >= 4 && _fourcc(c, 0) == 'strl') {
            final parts = _riffChunks(Uint8List.sublistView(c, 4));
            Uint8List? strh, strf;
            for (final (pid, pb) in parts) {
              if (pid == 'strh') strh ??= pb;
              if (pid == 'strf') strf ??= pb;
            }
            if (strh == null || strh.length < 4) continue;
            final type = _fourcc(strh, 0);
            if (type == 'vids' && !v.hasVideo) {
              v.hasVideo = true;
              final compression = (strf != null && strf.length >= 20)
                  ? strf.sublist(16, 20)
                  : strh.sublist(4, strh.length < 8 ? strh.length : 8);
              v.videoCodec = _aviVideoCodec(compression);
              final scale = _le32(strh, 20) ?? 0, rate = _le32(strh, 24) ?? 0;
              if (scale > 0 && rate > 0) v.frameRate = _roundFps(rate / scale);
            } else if (type == 'auds' && v.audioCodec == null && strf != null) {
              final tag = _le16(strf, 0);
              v.audioCodec = tag == null ? null : _aviAudioCodec(tag);
              final c2 = _le16(strf, 2), r = _le32(strf, 4);
              v.channels = (c2 != null && c2 > 0) ? c2 : null;
              v.sampleRate = (r != null && r > 0) ? r : null;
            }
          }
        }
      } else {
        for (final (id, c) in _riffChunks(b)) {
          final val = _clean(_str(c));
          switch (id) {
            case 'INAM':
              v.title ??= val;
            case 'IART':
              v.artist ??= val;
            case 'IPRD':
              v.album ??= val;
            case 'IGNR':
              v.genre ??= val;
            case 'ICRD':
              v.date ??= val;
            case 'ICMT':
              v.comment ??= val;
          }
        }
      }
    }
    pos += 8 + size + (size & 1);
  }
  if (!sawHdrl) _fail('no AVI header found (file may be incomplete)');
  if (v.frameRate == null && usPerFrame > 0) {
    v.frameRate = _roundFps(1e6 / usPerFrame);
  }
  final fps = v.frameRate;
  if (totalFrames > 0 && fps != null) {
    v.durationMs = (totalFrames / fps * 1000).round();
  }
  return v;
}
