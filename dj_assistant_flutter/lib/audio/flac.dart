import 'dart:io';
import 'dart:typed_data';

import 'pcm.dart';

/// Pure-Dart FLAC decoder (all subframe types, Rice/Rice2 residuals with escape
/// codes, wasted bits, left/right/mid-side decorrelation, 4–32-bit samples).
/// Frame CRC-16 is checked; a damaged frame ends decoding at the last good one.
class FlacReader implements PcmReader {
  FlacReader(String path) {
    final Uint8List data;
    try {
      data = File(path).readAsBytesSync();
    } on FileSystemException catch (e) {
      throw DecodeException('cannot open: ${e.message}');
    }
    _b = data;
    var p = _id3Size(data);
    if (data.length < p + 42 ||
        String.fromCharCodes(data.sublist(p, p + 4)) != 'fLaC') {
      throw DecodeException('unsupported or damaged audio: not a FLAC stream');
    }
    p += 4;
    var last = false;
    var sawInfo = false;
    while (!last) {
      if (p + 4 > data.length) {
        throw DecodeException(
          'unsupported or damaged audio: truncated FLAC header',
        );
      }
      last = (data[p] & 0x80) != 0;
      final type = data[p] & 0x7F;
      final len = (data[p + 1] << 16) | (data[p + 2] << 8) | data[p + 3];
      p += 4;
      if (p + len > data.length) {
        throw DecodeException(
          'unsupported or damaged audio: truncated FLAC header',
        );
      }
      if (type == 0 && len >= 34) {
        _minBlock = (data[p] << 8) | data[p + 1];
        _maxBlock = (data[p + 2] << 8) | data[p + 3];
        _rate =
            (data[p + 10] << 12) | (data[p + 11] << 4) | (data[p + 12] >> 4);
        _channels = ((data[p + 12] >> 1) & 7) + 1;
        _bps = (((data[p + 12] & 1) << 4) | (data[p + 13] >> 4)) + 1;
        sawInfo = true;
      }
      p += len;
    }
    if (!sawInfo || _rate == 0) {
      throw DecodeException('unsupported or damaged audio: missing STREAMINFO');
    }
    _pos = p;
    if (_maxBlock < 16 || _maxBlock < _minBlock) _maxBlock = 65535;
  }

  /// True when an ID3v2 tag is followed by a FLAC stream.
  static bool hasFlacAfterId3(String path) {
    final f = File(path).openSync();
    try {
      final h = f.readSync(10);
      if (h.length < 10) return false;
      final n = _id3Size(h);
      f.setPositionSync(n);
      return String.fromCharCodes(f.readSync(4)) == 'fLaC';
    } finally {
      f.closeSync();
    }
  }

  static int _id3Size(Uint8List b) {
    if (b.length < 10 || b[0] != 0x49 || b[1] != 0x44 || b[2] != 0x33) return 0;
    final size = (b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9];
    return 10 + size + ((b[5] & 0x10) != 0 ? 10 : 0);
  }

  late final Uint8List _b;
  int _rate = 0, _channels = 0, _bps = 0, _minBlock = 0, _maxBlock = 0;
  int _pos = 0;
  bool _done = false;

  @override
  int get sampleRate => _rate;
  @override
  int get channels => _channels;
  int get bitsPerSample => _bps;

  // Bit reader over _b.
  int _bit = 0; // absolute bit position

  int _bits(int n) {
    var v = 0;
    while (n > 0) {
      final byte = _bit >> 3;
      if (byte >= _b.length) throw const _Eof();
      final off = _bit & 7;
      final avail = 8 - off;
      final take = n < avail ? n : avail;
      v = (v << take) | ((_b[byte] >> (avail - take)) & ((1 << take) - 1));
      _bit += take;
      n -= take;
    }
    return v;
  }

  int _signed(int n) {
    if (n == 0) return 0;
    final v = _bits(n);
    return (v & (1 << (n - 1))) != 0 ? v - (1 << n) : v;
  }

  int _unary() {
    var n = 0;
    while (true) {
      final byte = _bit >> 3;
      if (byte >= _b.length) throw const _Eof();
      final off = _bit & 7;
      final rest = (_b[byte] << off) & 0xFF;
      if (rest == 0) {
        n += 8 - off;
        _bit += 8 - off;
        continue;
      }
      final lz = _clz8(rest);
      n += lz;
      _bit += lz + 1;
      return n;
    }
  }

  static int _clz8(int x) {
    var n = 0;
    for (var m = 0x80; (x & m) == 0; m >>= 1) {
      n++;
    }
    return n;
  }

  @override
  Float32List? read() {
    if (_done) return null;
    while (_pos + 2 <= _b.length) {
      // Find the next frame sync (0xFFF8 or 0xFFF9).
      if (_b[_pos] != 0xFF || (_b[_pos + 1] & 0xFE) != 0xF8) {
        _pos++;
        continue;
      }
      try {
        final out = _frame();
        if (out != null) return out;
      } on _Eof {
        break;
      } on _BadFrame {
        _pos++;
        continue;
      }
    }
    _done = true;
    return null;
  }

  Float32List? _frame() {
    final start = _pos;
    _bit = start * 8;
    _bits(16); // sync + reserved + blocking strategy
    final bsCode = _bits(4);
    final srCode = _bits(4);
    final chCode = _bits(4);
    final ssCode = _bits(3);
    if (_bits(1) != 0 ||
        chCode > 10 ||
        ssCode == 3 ||
        srCode == 15 ||
        bsCode == 0) {
      throw const _BadFrame();
    }
    // UTF-8-style coded frame/sample number.
    var first = _bits(8);
    var extra = 0;
    while ((first & 0x80) != 0 && extra < 7) {
      first = (first << 1) & 0xFF;
      extra++;
    }
    if (extra == 1) throw const _BadFrame();
    for (var i = 1; i < extra; i++) {
      if (_bits(8) >> 6 != 2) throw const _BadFrame();
    }
    int block;
    switch (bsCode) {
      case 1:
        block = 192;
      case >= 2 && <= 5:
        block = 576 << (bsCode - 2);
      case 6:
        block = _bits(8) + 1;
      case 7:
        block = _bits(16) + 1;
      default:
        block = 256 << (bsCode - 8);
    }
    if (srCode == 12) {
      _bits(8);
    } else if (srCode == 13 || srCode == 14) {
      _bits(16);
    }
    final headerEnd = _bit >> 3;
    final crc8 = _bits(8);
    if (_crc8(start, headerEnd) != crc8) throw const _BadFrame();
    final bps = switch (ssCode) {
      0 => _bps,
      1 => 8,
      2 => 12,
      4 => 16,
      5 => 20,
      6 => 24,
      _ => 32,
    };
    if (block > 65536) throw const _BadFrame();
    final nch = chCode < 8 ? chCode + 1 : 2;
    if (nch != _channels) throw const _BadFrame();
    final chans = List<Int64List>.generate(nch, (_) => Int64List(block));
    for (var c = 0; c < nch; c++) {
      // The side channel carries one extra bit.
      final extraBit =
          (chCode == 8 && c == 1) ||
          (chCode == 9 && c == 0) ||
          (chCode == 10 && c == 1);
      _subframe(chans[c], block, bps + (extraBit ? 1 : 0));
    }
    // Byte-align, then CRC-16 over the whole frame.
    _bit = (_bit + 7) & ~7;
    final end = _bit >> 3;
    final crc16 = _bits(16);
    if (_crc16(start, end) != crc16) throw const _BadFrame();
    _pos = end + 2;

    final l = chans[0];
    switch (chCode) {
      case 8: // left/side
        final s = chans[1];
        for (var i = 0; i < block; i++) {
          s[i] = l[i] - s[i];
        }
      case 9: // side/right
        final r = chans[1];
        for (var i = 0; i < block; i++) {
          l[i] = l[i] + r[i];
        }
      case 10: // mid/side
        final s = chans[1];
        for (var i = 0; i < block; i++) {
          final side = s[i];
          final mid = (l[i] << 1) | (side & 1);
          l[i] = (mid + side) >> 1;
          s[i] = (mid - side) >> 1;
        }
    }
    final out = Float32List(block * nch);
    final scale = 1 / (1 << (bps - 1)).toDouble();
    for (var c = 0; c < nch; c++) {
      final ch = chans[c];
      for (var i = 0; i < block; i++) {
        out[i * nch + c] = ch[i] * scale;
      }
    }
    return out;
  }

  void _subframe(Int64List out, int block, int bps) {
    if (_bits(1) != 0) throw const _BadFrame();
    final type = _bits(6);
    var wasted = 0;
    if (_bits(1) == 1) wasted = _unary() + 1;
    final b = bps - wasted;
    if (b <= 0) throw const _BadFrame();
    if (type == 0) {
      final v = _signed(b);
      for (var i = 0; i < block; i++) {
        out[i] = v;
      }
    } else if (type == 1) {
      for (var i = 0; i < block; i++) {
        out[i] = _signed(b);
      }
    } else if (type >= 8 && type <= 12) {
      final order = type - 8;
      if (order > block) throw const _BadFrame();
      for (var i = 0; i < order; i++) {
        out[i] = _signed(b);
      }
      _residual(out, block, order);
      _fixed(out, block, order);
    } else if (type >= 32) {
      final order = type - 31;
      if (order > block) throw const _BadFrame();
      for (var i = 0; i < order; i++) {
        out[i] = _signed(b);
      }
      final precision = _bits(4) + 1;
      if (precision == 16) throw const _BadFrame();
      final shift = _signed(5);
      if (shift < 0) throw const _BadFrame();
      final coefs = List<int>.generate(order, (_) => _signed(precision));
      _residual(out, block, order);
      for (var i = order; i < block; i++) {
        var sum = 0;
        for (var j = 0; j < order; j++) {
          sum += coefs[j] * out[i - j - 1];
        }
        out[i] += sum >> shift;
      }
    } else {
      throw const _BadFrame();
    }
    if (wasted > 0) {
      for (var i = 0; i < block; i++) {
        out[i] <<= wasted;
      }
    }
  }

  void _fixed(Int64List x, int block, int order) {
    switch (order) {
      case 1:
        for (var i = 1; i < block; i++) {
          x[i] += x[i - 1];
        }
      case 2:
        for (var i = 2; i < block; i++) {
          x[i] += 2 * x[i - 1] - x[i - 2];
        }
      case 3:
        for (var i = 3; i < block; i++) {
          x[i] += 3 * x[i - 1] - 3 * x[i - 2] + x[i - 3];
        }
      case 4:
        for (var i = 4; i < block; i++) {
          x[i] += 4 * x[i - 1] - 6 * x[i - 2] + 4 * x[i - 3] - x[i - 4];
        }
    }
  }

  /// Residuals into out[order…block) (added to by the predictor afterwards).
  void _residual(Int64List out, int block, int order) {
    final method = _bits(2);
    if (method > 1) throw const _BadFrame();
    final paramBits = method == 0 ? 4 : 5;
    final escape = method == 0 ? 15 : 31;
    final partOrder = _bits(4);
    final parts = 1 << partOrder;
    if ((block >> partOrder) < order || block % parts != 0) {
      throw const _BadFrame();
    }
    var i = order;
    for (var p = 0; p < parts; p++) {
      final n = (block >> partOrder) - (p == 0 ? order : 0);
      final k = _bits(paramBits);
      if (k == escape) {
        final raw = _bits(5);
        for (var j = 0; j < n; j++) {
          out[i++] = _signed(raw);
        }
      } else {
        for (var j = 0; j < n; j++) {
          final v = (_unary() << k) | (k == 0 ? 0 : _bits(k));
          out[i++] = (v >> 1) ^ -(v & 1);
        }
      }
    }
  }

  int _crc8(int from, int to) {
    var c = 0;
    for (var i = from; i < to; i++) {
      c = _crc8Table[c ^ _b[i]];
    }
    return c;
  }

  int _crc16(int from, int to) {
    var c = 0;
    for (var i = from; i < to; i++) {
      c = ((c << 8) & 0xFFFF) ^ _crc16Table[(c >> 8) ^ _b[i]];
    }
    return c;
  }

  @override
  void close() => _done = true;
}

class _Eof implements Exception {
  const _Eof();
}

class _BadFrame implements Exception {
  const _BadFrame();
}

final _crc8Table = () {
  final t = Uint8List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var j = 0; j < 8; j++) {
      c = (c & 0x80) != 0 ? ((c << 1) ^ 0x07) & 0xFF : (c << 1) & 0xFF;
    }
    t[i] = c;
  }
  return t;
}();

final _crc16Table = () {
  final t = Uint16List(256);
  for (var i = 0; i < 256; i++) {
    var c = i << 8;
    for (var j = 0; j < 8; j++) {
      c = (c & 0x8000) != 0 ? ((c << 1) ^ 0x8005) & 0xFFFF : (c << 1) & 0xFFFF;
    }
    t[i] = c;
  }
  return t;
}();
