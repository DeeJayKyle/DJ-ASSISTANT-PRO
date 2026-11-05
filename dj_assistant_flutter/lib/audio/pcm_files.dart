import 'dart:io';
import 'dart:typed_data';

import 'pcm.dart';

/// Uncompressed PCM in WAV (RIFF, incl. WAVE_FORMAT_EXTENSIBLE) and AIFF/AIFC.
abstract class _ChunkedPcm implements PcmReader {
  _ChunkedPcm(String path) {
    try {
      raf = File(path).openSync();
    } on FileSystemException catch (e) {
      throw DecodeException('cannot open: ${e.message}');
    }
    try {
      parse();
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
    if (_channels < 1 || _channels > 32 || _rate < 1 || _rate > 768000) {
      close();
      throw DecodeException('unsupported or damaged audio: bad format header');
    }
    _pos = dataStart;
  }

  late final RandomAccessFile raf;
  int _rate = 0, _channels = 0, bits = 0;
  bool float = false, bigEndian = false, unsigned8 = true;
  int dataStart = 0, dataEnd = 0;
  int _pos = 0;
  bool _closed = false;

  void parse();

  @override
  int get sampleRate => _rate;
  @override
  int get channels => _channels;

  int get _bytesPerSample => (bits + 7) ~/ 8;

  @override
  Float32List? read() {
    final frameBytes = _bytesPerSample * _channels;
    final want = 4096 * frameBytes;
    final left = dataEnd - _pos;
    if (_closed || left < frameBytes) return null;
    raf.setPositionSync(_pos);
    final raw = raf.readSync(want < left ? want : left - left % frameBytes);
    final usable = raw.length - raw.length % frameBytes;
    if (usable <= 0) return null;
    _pos += usable;
    final n = usable ~/ _bytesPerSample;
    final out = Float32List(n);
    final bd = ByteData.sublistView(raw);
    final e = bigEndian ? Endian.big : Endian.little;
    final b = _bytesPerSample;
    for (var i = 0; i < n; i++) {
      final o = i * b;
      double v;
      if (float) {
        v = b == 4 ? bd.getFloat32(o, e) : bd.getFloat64(o, e);
      } else {
        switch (b) {
          case 1:
            // WAV 8-bit is unsigned; AIFF 8-bit is signed.
            v = unsigned8 ? (raw[o] - 128) / 128 : bd.getInt8(o) / 128;
          case 2:
            v = bd.getInt16(o, e) / 32768;
          case 3:
            final x = bigEndian
                ? (raw[o] << 16) | (raw[o + 1] << 8) | raw[o + 2]
                : raw[o] | (raw[o + 1] << 8) | (raw[o + 2] << 16);
            v = (x >= 0x800000 ? x - 0x1000000 : x) / 8388608;
          default:
            v = bd.getInt32(o, e) / 2147483648;
        }
      }
      out[i] = v;
    }
    return out;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    raf.closeSync();
  }

  Uint8List at(int pos, int n) {
    raf.setPositionSync(pos);
    return raf.readSync(n);
  }
}

class WavReader extends _ChunkedPcm {
  WavReader(super.path);

  @override
  void parse() {
    final len = raf.lengthSync();
    var p = 12;
    var fmt = 0;
    while (p + 8 <= len) {
      final h = ByteData.sublistView(at(p, 8));
      final id = String.fromCharCodes(Uint8List.sublistView(h).sublist(0, 4));
      final size = h.getUint32(4, Endian.little);
      if (id == 'fmt ' && size >= 16) {
        final f = ByteData.sublistView(at(p + 8, size < 40 ? size : 40));
        fmt = f.getUint16(0, Endian.little);
        _channels = f.getUint16(2, Endian.little);
        _rate = f.getUint32(4, Endian.little);
        bits = f.getUint16(14, Endian.little);
        if (fmt == 0xFFFE && f.lengthInBytes >= 26) {
          fmt = f.getUint16(24, Endian.little);
        }
      } else if (id == 'data') {
        dataStart = p + 8;
        // Some writers leave the size at 0 or 0xFFFFFFFF while streaming.
        dataEnd = (size == 0 || size == 0xFFFFFFFF || dataStart + size > len)
            ? len
            : dataStart + size;
        break;
      }
      p += 8 + size + (size & 1);
    }
    if (fmt == 0 || dataStart == 0) {
      throw DecodeException(
        'unsupported or damaged audio: missing fmt or data chunk',
      );
    }
    if (fmt == 3) {
      float = true;
      if (bits != 32 && bits != 64) {
        throw DecodeException('unsupported float WAV ($bits-bit)');
      }
    } else if (fmt != 1) {
      throw DecodeException('no decoder for this WAV encoding (format $fmt)');
    } else if (bits < 1 || bits > 32) {
      throw DecodeException('unsupported WAV bit depth ($bits)');
    }
  }
}

class AiffReader extends _ChunkedPcm {
  AiffReader(super.path);

  @override
  void parse() {
    final len = raf.lengthSync();
    final aifc = String.fromCharCodes(at(8, 4)) == 'AIFC';
    bigEndian = true;
    unsigned8 = false;
    var p = 12;
    var comp = 'NONE';
    var sawComm = false;
    while (p + 8 <= len) {
      final h = ByteData.sublistView(at(p, 8));
      final id = String.fromCharCodes(Uint8List.sublistView(h).sublist(0, 4));
      final size = h.getUint32(4);
      if (id == 'COMM' && size >= 18) {
        final c = at(p + 8, size < 26 ? size : 26);
        final d = ByteData.sublistView(c);
        _channels = d.getUint16(0);
        bits = d.getUint16(6);
        _rate = _ieee80(c, 8).round();
        if (aifc && c.length >= 22) {
          comp = String.fromCharCodes(c.sublist(18, 22));
        }
        sawComm = true;
      } else if (id == 'SSND' && size >= 8) {
        final offset = ByteData.sublistView(at(p + 8, 4)).getUint32(0);
        dataStart = p + 16 + offset;
        dataEnd = p + 8 + size > len ? len : p + 8 + size;
      }
      p += 8 + size + (size & 1);
    }
    if (!sawComm || dataStart == 0) {
      throw DecodeException(
        'unsupported or damaged audio: missing COMM or SSND chunk',
      );
    }
    switch (comp) {
      case 'NONE' || 'twos':
        break;
      case 'sowt':
        bigEndian = false;
      case 'fl32' || 'FL32':
        float = true;
        bits = 32;
      case 'fl64' || 'FL64':
        float = true;
        bits = 64;
      default:
        throw DecodeException('no decoder for this AIFF compression ($comp)');
    }
    if (!float && (bits < 1 || bits > 32)) {
      throw DecodeException('unsupported AIFF bit depth ($bits)');
    }
  }
}

double _ieee80(Uint8List b, int o) {
  final exp = ((b[o] & 0x7F) << 8) | b[o + 1];
  final d = ByteData.sublistView(b);
  final hi = d.getUint32(o + 2), lo = d.getUint32(o + 6);
  if (exp == 0 && hi == 0 && lo == 0) return 0;
  var r = (hi * 4294967296.0 + lo);
  var e = exp - 16383 - 63;
  while (e > 0) {
    r *= 2;
    e--;
  }
  while (e < 0) {
    r /= 2;
    e++;
  }
  return (b[o] & 0x80) != 0 ? -r : r;
}
