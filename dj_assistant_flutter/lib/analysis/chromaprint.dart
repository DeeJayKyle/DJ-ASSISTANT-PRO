import 'dart:math' as math;
import 'dart:typed_data';

import 'fft.dart';

/// Chromaprint fingerprints (preset "test2", the AcoustID default), ported from
/// `rusty-chromaprint` 0.3 (MIT) as used by 1.x, including its resampler
/// (rubato `SincFixedIn`: 16-tap Blackman sinc, cut-off 0.8, 128× oversampling,
/// nearest-phase interpolation).

const _sampleRate = 11025;
const _frameSize = 4096;
const _frameOverlap = _frameSize - _frameSize ~/ 3;
const _minFreq = 28, _maxFreq = 3520;
const _filterCoefficients = [0.25, 0.75, 1.0, 0.75, 0.25];

/// Seconds of audio one sub-fingerprint covers (f32 as in 1.x).
final double itemDurationSeconds = _f32(
  (_frameSize - _frameOverlap) / _sampleRate,
);

final _f32buf = Float32List(1);
double _f32(double v) {
  _f32buf[0] = v;
  return _f32buf[0];
}

class _Classifier {
  const _Classifier(
    this.kind,
    this.y,
    this.height,
    this.width,
    this.t0,
    this.t1,
    this.t2,
  );
  final int kind, y, height, width;
  final double t0, t1, t2;
}

const _classifiers = [
  _Classifier(0, 4, 3, 15, 1.98215, 2.35817, 2.63523),
  _Classifier(4, 4, 6, 15, -1.03809, -0.651211, -0.282167),
  _Classifier(1, 0, 4, 16, -0.298702, 0.119262, 0.558497),
  _Classifier(3, 8, 2, 12, -0.105439, 0.0153946, 0.135898),
  _Classifier(3, 4, 4, 8, -0.142891, 0.0258736, 0.200632),
  _Classifier(4, 0, 3, 5, -0.826319, -0.590612, -0.368214),
  _Classifier(1, 2, 2, 9, -0.557409, -0.233035, 0.0534525),
  _Classifier(2, 7, 3, 4, -0.0646826, 0.00620476, 0.0784847),
  _Classifier(2, 6, 2, 16, -0.192387, -0.029699, 0.215855),
  _Classifier(2, 1, 3, 2, -0.0397818, -0.00568076, 0.0292026),
  _Classifier(5, 10, 1, 15, -0.53823, -0.369934, -0.190235),
  _Classifier(3, 6, 2, 10, -0.124877, 0.0296483, 0.139239),
  _Classifier(2, 1, 1, 14, -0.101475, 0.0225617, 0.231971),
  _Classifier(3, 5, 6, 4, -0.0799915, -0.00729616, 0.063262),
  _Classifier(1, 9, 2, 12, -0.272556, 0.019424, 0.302559),
  _Classifier(3, 4, 2, 14, -0.164292, -0.0321188, 0.0846339),
];

// ------------------------------------------------------------------ resampler

class _SincResampler {
  _SincResampler(this.ratio) {
    const sincLen = 16, factor = 128;
    final cutoff = ratio >= 1 ? _f32(0.8) : _f32(_f32(0.8) * _f32(ratio));
    final tot = sincLen * factor;
    final y = Float64List(tot);
    var sum = 0.0;
    for (var x = 0; x < tot; x++) {
      final w =
          0.42 -
          0.5 * math.cos(2 * math.pi * x / tot) +
          0.08 * math.cos(4 * math.pi * x / tot);
      final v = (x - tot ~/ 2) * cutoff / factor;
      final s = v == 0 ? 1.0 : math.sin(v * math.pi) / (v * math.pi);
      y[x] = w * s;
      sum += y[x];
    }
    sum /= factor;
    _sincs = List.generate(factor, (_) => Float64List(sincLen));
    for (var p = 0; p < sincLen; p++) {
      for (var n = 0; n < factor; n++) {
        _sincs[factor - n - 1][p] = y[factor * p + n] / sum;
      }
    }
    _buffer = Float64List(maxChunk + 2 * sincLen);
    _lastIndex = -(sincLen ~/ 2).toDouble();
  }

  static const maxChunk = 1024 * 32;
  static const _sincLen = 16, _factor = 128;
  final double ratio;
  late final List<Float64List> _sincs;
  late final Float64List _buffer;
  late double _lastIndex;
  int chunk = maxChunk;

  /// Resamples exactly [chunk] input frames.
  List<double> process(List<double> input) {
    final tRatio = 1 / ratio;
    final endIdx = chunk - (_sincLen + 1) - tRatio.ceil();
    _buffer.setRange(0, 2 * _sincLen, _buffer, chunk);
    for (var i = 0; i < chunk; i++) {
      _buffer[2 * _sincLen + i] = input[i];
    }
    var idx = _lastIndex;
    final out = <double>[];
    while (idx < endIdx) {
      idx += tRatio;
      var index = idx.floor();
      var sub = ((idx - idx.floor()) * _factor).round();
      if (sub >= _factor) {
        sub -= _factor;
        index++;
      }
      final s = _sincs[sub];
      final o = index + 2 * _sincLen;
      final acc = Float64List(8);
      for (var k = 0; k < _sincLen; k++) {
        acc[k & 7] += _buffer[o + k] * s[k];
      }
      out.add(
        acc[0] + acc[1] + acc[2] + acc[3] + acc[4] + acc[5] + acc[6] + acc[7],
      );
    }
    _lastIndex = idx - chunk;
    return out;
  }
}

// ------------------------------------------------------------------ pipeline

/// Streams 16-bit interleaved audio into a fingerprint, as 1.x's Fingerprinter.
class Fingerprinter {
  Fingerprinter(int sampleRate, this.channels)
    : _resampler = sampleRate == _sampleRate
          ? null
          : _SincResampler(_sampleRate / sampleRate) {
    if (channels < 1 || sampleRate <= 1000) {
      throw ArgumentError('cannot fingerprint this audio');
    }
    for (var i = 0; i < _frameSize; i++) {
      _window[i] = 0.54 - 0.46 * math.cos(2 * math.pi * i / (_frameSize - 1));
    }
    _minIndex = math.max(1, (_frameSize * _minFreq / _sampleRate).round());
    _maxIndex = math.min(
      _frameSize ~/ 2,
      (_frameSize * _maxFreq / _sampleRate).round(),
    );
    for (var i = _minIndex; i < _maxIndex; i++) {
      final freq = i * _sampleRate / _frameSize;
      final octave = math.log(freq / (440 / 16)) / math.ln2;
      final note = 12 * (octave - octave.floor());
      _notes[i] = note.floor();
    }
  }

  final int channels;
  final _SincResampler? _resampler;
  final _buffer = Int16List(_SincResampler.maxChunk);
  var _bufferOffset = 0;
  final _input = <double>[];

  // FFT stage
  final _fft = Fft(_frameSize);
  final _window = Float64List(_frameSize);
  final _ring = <double>[];
  var _ringStart = 0;

  // Chroma stage
  final _notes = Int32List(_frameSize);
  late final int _minIndex, _maxIndex;

  // Chroma filter stage
  final _filterBuf = List.generate(8, (_) => Float64List(12));
  var _filterOffset = 0, _filterSize = 1;

  // Rolling integral image + calculator
  static const _maxRows = 256;
  final _image = Float64List(_maxRows * 12);
  var _rows = 0;
  static final _maxWidth = _classifiers.map((c) => c.width).reduce(math.max);
  final fingerprint = <int>[];

  /// Adds interleaved 16-bit samples.
  void consume(Int16List data) {
    var i = 0;
    while (i < data.length) {
      final frames = (data.length - i) ~/ channels;
      final take = math.min(frames, _buffer.length - _bufferOffset);
      for (var f = 0; f < take; f++) {
        final o = i + f * channels;
        int v;
        if (channels == 1) {
          v = data[o];
        } else if (channels == 2) {
          v = (data[o] + data[o + 1]) ~/ 2;
        } else {
          var sum = 0;
          for (var c = 0; c < channels; c++) {
            sum += data[o + c];
          }
          v = sum ~/ channels;
        }
        _buffer[_bufferOffset++] = v;
      }
      i += take * channels;
      if (_bufferOffset == _buffer.length) _resample(false);
      if (take == 0) break;
    }
  }

  void finish() {
    if (_bufferOffset > 0) _resample(true);
  }

  void _resample(bool end) {
    for (var i = 0; i < _bufferOffset; i++) {
      _input.add(_buffer[i] / 32767);
    }
    _bufferOffset = 0;
    final r = _resampler;
    if (r == null) {
      _feed(_input);
      _input.clear();
      return;
    }
    while (_input.isNotEmpty) {
      if (_input.length < r.chunk) {
        if (!end) break;
        r.chunk = _input.length;
      }
      final out = r.process(_input);
      _input.removeRange(0, r.chunk);
      _feed(out);
      if (end) r.chunk = _SincResampler.maxChunk;
    }
  }

  void _feed(List<double> data) {
    _ring.addAll(data);
    final re = Float64List(_frameSize), im = Float64List(_frameSize);
    while (_ring.length - _ringStart >= _frameSize) {
      for (var k = 0; k < _frameSize; k++) {
        re[k] = _ring[_ringStart + k] * _window[k];
        im[k] = 0;
      }
      _fft.transform(re, im);
      final features = Float64List(12);
      for (var k = _minIndex; k < _maxIndex; k++) {
        features[_notes[k]] += re[k] * re[k] + im[k] * im[k];
      }
      _chromaFilter(features);
      _ringStart += _frameSize - _frameOverlap;
    }
    if (_ringStart > 1 << 16) {
      _ring.removeRange(0, _ringStart);
      _ringStart = 0;
    }
  }

  void _chromaFilter(Float64List f) {
    _filterBuf[_filterOffset].setAll(0, f);
    _filterOffset = (_filterOffset + 1) % 8;
    if (_filterSize >= _filterCoefficients.length) {
      final offset = (_filterOffset + 8 - _filterCoefficients.length) % 8;
      final res = Float64List(12);
      for (var i = 0; i < 12; i++) {
        for (var j = 0; j < _filterCoefficients.length; j++) {
          res[i] += _filterBuf[(offset + j) % 8][i] * _filterCoefficients[j];
        }
      }
      // Normalise.
      var norm = 0.0;
      for (final v in res) {
        norm += v * v;
      }
      norm = math.sqrt(norm);
      for (var i = 0; i < 12; i++) {
        res[i] = norm < 0.01 ? 0 : res[i] / norm;
      }
      _addRow(res);
    } else {
      _filterSize++;
    }
  }

  void _addRow(Float64List row) {
    final r = _rows % (_maxRows),
        base = r * 12,
        prev = ((_rows - 1) % _maxRows) * 12;
    var sum = 0.0;
    for (var i = 0; i < 12; i++) {
      sum += row[i];
      _image[base + i] = sum;
    }
    if (_rows > 0) {
      for (var i = 0; i < 12; i++) {
        _image[base + i] += _image[prev + i];
      }
    }
    _rows++;
    if (_rows >= _maxWidth) fingerprint.add(_subFingerprint(_rows - _maxWidth));
  }

  double _area(int r1, int c1, int r2, int c2) {
    if (r1 == r2 || c1 == c2) return 0;
    double at(int r, int c) => _image[(r % _maxRows) * 12 + c];
    if (r1 == 0) {
      return c1 == 0
          ? at(r2 - 1, c2 - 1)
          : at(r2 - 1, c2 - 1) - at(r2 - 1, c1 - 1);
    }
    if (c1 == 0) return at(r2 - 1, c2 - 1) - at(r1 - 1, c2 - 1);
    return at(r2 - 1, c2 - 1) -
        at(r1 - 1, c2 - 1) -
        at(r2 - 1, c1 - 1) +
        at(r1 - 1, c1 - 1);
  }

  double _filter(_Classifier c, int x) {
    final y = c.y, w = c.width, h = c.height;
    double a, b;
    switch (c.kind) {
      case 0:
        a = _area(x, y, x + w, y + h);
        b = 0;
      case 1:
        final h2 = h ~/ 2;
        a = _area(x, y + h2, x + w, y + h);
        b = _area(x, y, x + w, y + h2);
      case 2:
        final w2 = w ~/ 2;
        a = _area(x + w2, y, x + w, y + h);
        b = _area(x, y, x + w2, y + h);
      case 3:
        final w2 = w ~/ 2, h2 = h ~/ 2;
        a = _area(x, y + h2, x + w2, y + h) + _area(x + w2, y, x + w, y + h2);
        b = _area(x, y, x + w2, y + h2) + _area(x + w2, y + h2, x + w, y + h);
      case 4:
        final h3 = h ~/ 3;
        a = _area(x, y + h3, x + w, y + 2 * h3);
        b = _area(x, y, x + w, y + h3) + _area(x, y + 2 * h3, x + w, y + h);
      default:
        final w3 = w ~/ 3;
        a = _area(x + w3, y, x + 2 * w3, y + h);
        b = _area(x, y, x + w3, y + h) + _area(x + 2 * w3, y, x + w, y + h);
    }
    return math.log((1 + a) / (1 + b));
  }

  int _subFingerprint(int offset) {
    var bits = 0;
    for (final c in _classifiers) {
      final v = _filter(c, offset);
      final q = v < c.t1 ? (v < c.t0 ? 0 : 1) : (v < c.t2 ? 2 : 3);
      bits = ((bits << 2) | const [0, 1, 3, 2][q]) & 0xFFFFFFFF;
    }
    return bits;
  }
}

// ------------------------------------------------------------------ compression

/// AcoustID's compressed fingerprint, base64url without padding.
String encodeFingerprint(List<int> fp) {
  final normal = <int>[], exceptional = <int>[];
  var last = 0;
  for (final sub in fp) {
    final v = sub ^ last;
    last = sub;
    var lastBit = 0;
    for (var bit = 0; bit < 32; bit++) {
      if ((v >> bit) & 1 == 1) {
        final idx = bit + 1;
        final value = idx - lastBit;
        if (value >= 7) {
          normal.add(7);
          exceptional.add(value - 7);
        } else {
          normal.add(value);
        }
        lastBit = idx;
      }
    }
    normal.add(0);
  }
  final size = fp.length;
  final out = <int>[
    1,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ..._pack(normal, 3),
    ..._pack(exceptional, 5),
  ];
  return _b64url(out);
}

List<int> _pack(List<int> values, int bits) {
  final out = <int>[];
  final mask = (1 << bits) - 1;
  for (var s = 0; s < values.length; s += 8) {
    final chunk = values.sublist(s, math.min(values.length, s + 8));
    final res = List<int>.filled(bits, 0);
    var size = 0;
    for (var i = 0; i < chunk.length; i++) {
      final v = chunk[i] & mask;
      final right = i * bits, left = right + bits - 1;
      final rb = right ~/ 8, lb = left ~/ 8;
      res[rb] = (res[rb] | (v << (right % 8))) & 0xFF;
      if (lb != rb) res[lb] = (res[lb] | (v >> ((8 - (right % 8)) % 8))) & 0xFF;
      size = lb + 1;
    }
    out.addAll(res.take(size));
  }
  return out;
}

String _b64url(List<int> bytes) {
  const t = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final b = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final c1 = i + 1 < bytes.length ? bytes[i + 1] : 0,
        c2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    final n = (bytes[i] << 16) | (c1 << 8) | c2;
    b.write(t[(n >> 18) & 63]);
    b.write(t[(n >> 12) & 63]);
    if (i + 1 < bytes.length) b.write(t[(n >> 6) & 63]);
    if (i + 2 < bytes.length) b.write(t[n & 63]);
  }
  return b.toString();
}

// ------------------------------------------------------------------ matching

int _popcount(int x) {
  var n = 0;
  while (x != 0) {
    x &= x - 1;
    n++;
  }
  return n;
}

/// Fraction (0..1) of the shorter fingerprint covered by matching segments (1.x
/// `fingerprint_similarity`).
double fingerprintSimilarity(List<int> a, List<int> b) {
  if (a.length < 20 || b.length < 20) return 0;
  final segs = _match(a, b);
  var matched = 0.0;
  for (final s in segs) {
    if (s.$2 < 10) matched = _f32(matched + _f32(itemDurationSeconds * s.$1));
  }
  final shorter = _f32(math.min(a.length, b.length) * itemDurationSeconds);
  return shorter <= 0 ? 0 : math.min(1.0, matched / shorter);
}

/// Segments as (items, score).
List<(int, double)> _match(List<int> fp1, List<int> fp2) {
  const alignBits = 12, hashShift = 32 - alignBits;
  const hashMask = ((1 << alignBits) - 1) << hashShift;
  const offsetMask = (1 << (32 - alignBits - 1)) - 1;
  const sourceMask = 1 << (32 - alignBits - 1);
  if (fp1.length + 1 >= offsetMask || fp2.length + 1 >= offsetMask) {
    return const [];
  }
  final offsets = <int>[
    for (var i = 0; i < fp1.length; i++)
      ((fp1[i] >> hashShift) << hashShift) | i,
    for (var i = 0; i < fp2.length; i++)
      ((fp2[i] >> hashShift) << hashShift) | i | sourceMask,
  ]..sort();
  final hist = Int32List(fp1.length + fp2.length);
  for (var k = 0; k < offsets.length; k++) {
    final item1 = offsets[k];
    if (item1 & sourceMask != 0) continue;
    final h1 = item1 & hashMask, o1 = item1 & offsetMask;
    for (var j = k + 1; j < offsets.length; j++) {
      final item2 = offsets[j];
      if (item2 & hashMask != h1) break;
      if (item2 & sourceMask != 0) {
        hist[o1 + fp2.length - (item2 & offsetMask)]++;
      }
    }
  }
  var bestCount = -1, best = -1;
  for (var i = 0; i < hist.length; i++) {
    final c = hist[i];
    if (c <= 1) continue;
    if ((i == 0 || hist[i - 1] <= c) &&
        (i == hist.length - 1 || hist[i + 1] <= c)) {
      // Highest count first, then the highest offset (sort by Reverse((count, i))).
      if (c > bestCount || (c == bestCount && i > best)) {
        bestCount = c;
        best = i;
      }
    }
  }
  if (best < 0) return const [];
  final diff = best - fp2.length;
  final off1 = diff > 0 ? diff : 0, off2 = diff < 0 ? -diff : 0;
  final size = math.min(fp1.length - off1, fp2.length - off2);
  final bits = Float64List(size);
  for (var i = 0; i < size; i++) {
    bits[i] = _popcount((fp1[off1 + i] ^ fp2[off2 + i]) & 0xFFFFFFFF)
        .toDouble();
  }
  final smooth = _gaussian(Float64List.fromList(bits), 8, 3);
  final grad = _gradient(smooth).map((g) => g.abs()).toList();
  final peaks = <int>[];
  for (var i = 1; i < size - 1; i++) {
    final g = grad[i];
    if (g > 0.15 &&
        g >= grad[i - 1] &&
        g >= grad[i + 1] &&
        (peaks.isEmpty || peaks.last + 1 < i)) {
      peaks.add(i);
    }
  }
  peaks.add(size);
  final segs = <(int, int, int, double)>[]; // (o1, o2, items, score)
  var begin = 0;
  for (final end in peaks) {
    final dur = end - begin;
    var sum = 0.0;
    for (var i = begin; i < end; i++) {
      sum += bits[i];
    }
    final score = sum / dur;
    if (score < 10) {
      final seg = (off1 + begin, off2 + begin, dur, score);
      var added = false;
      if (segs.isNotEmpty) {
        final s1 = segs.last;
        if ((s1.$4 - score).abs() < 0.7 &&
            s1.$1 + s1.$3 == seg.$1 &&
            s1.$2 + s1.$3 == seg.$2) {
          final n = s1.$3 + dur;
          segs[segs.length - 1] = (
            s1.$1,
            s1.$2,
            n,
            (s1.$4 * s1.$3 + score * dur) / n,
          );
          added = true;
        }
      }
      if (!added) segs.add(seg);
    }
    begin = end;
  }
  return [for (final s in segs) (s.$3, s.$4)];
}

List<double> _gradient(List<double> x) {
  if (x.isEmpty) return const [];
  if (x.length == 1) return [0];
  if (x.length == 2) return [x[1] - x[0], x[1] - x[0]];
  return [
    x[1] - x[0],
    for (var i = 1; i < x.length - 1; i++) (x[i + 1] - x[i - 1]) / 2,
    x[x.length - 1] - x[x.length - 2],
  ];
}

Float64List _gaussian(Float64List input, double sigma, int n) {
  final w = math.sqrt(12 * sigma * sigma / n + 1).floor();
  final wl = w - (w % 2 == 0 ? 1 : 0);
  final wu = wl + 2;
  final m =
      ((12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4 * wl - 4))
          .round();
  var a = input, b = Float64List(input.length);
  for (var i = 0; i < n; i++) {
    _box(a, b, i < m ? wl : wu);
    final t = a;
    a = b;
    b = t;
  }
  return a;
}

class _Reflect {
  _Reflect(this.size);
  final int size;
  var pos = 0;
  var forward = true;
  void fwd() {
    if (forward) {
      if (pos + 1 == size) {
        forward = false;
      } else {
        pos++;
      }
    } else if (pos == 0) {
      forward = true;
    } else {
      pos--;
    }
  }

  void back() {
    if (forward) {
      if (pos == 0) {
        forward = false;
      } else {
        pos--;
      }
    } else if (pos + 1 == size) {
      forward = true;
    } else {
      pos++;
    }
  }
}

void _box(Float64List input, Float64List output, int w) {
  final size = input.length;
  if (w == 0 || size == 0) return;
  final wl = w ~/ 2, wr = w - wl;
  final it1 = _Reflect(size), it2 = _Reflect(size);
  for (var i = 0; i < wl; i++) {
    it1.back();
    it2.back();
  }
  var sum = 0.0;
  for (var i = 0; i < w; i++) {
    sum += input[it2.pos];
    it2.fwd();
  }
  var o = 0;
  if (size > w) {
    for (var i = 0; i < wl; i++) {
      output[o++] = sum / w;
      sum += input[it2.pos] - input[it1.pos];
      it1.fwd();
      it2.fwd();
    }
    for (var i = 0; i < size - w - 1; i++) {
      output[o++] = sum / w;
      sum += input[it2.pos] - input[it1.pos];
      it2.pos++;
      it1.pos++;
    }
    for (var i = 0; i < wr + 1; i++) {
      output[o++] = sum / w;
      sum += input[it2.pos] - input[it1.pos];
      it1.fwd();
      it2.fwd();
    }
  } else {
    for (var i = 0; i < size; i++) {
      output[o++] = sum / w;
      sum += input[it2.pos] - input[it1.pos];
      it1.fwd();
      it2.fwd();
    }
  }
}
