import 'dart:math' as math;
import 'dart:typed_data';

/// Tempo and key changes without the chipmunk effect (1.x `audio/stretch.ts`):
/// WSOLA time-stretch, pitch shift, and a realtime deck reader.
const _frame = 2048, _hop = 512, _seek = 384;

final Float32List _hann = () {
  final w = Float32List(_frame);
  for (var i = 0; i < _frame; i++) {
    w[i] = 0.5 - 0.5 * math.cos((2 * math.pi * i) / _frame);
  }
  return w;
}();

Float32List _guide(List<Float32List> ch) {
  final n = ch[0].length ~/ 4;
  final g = Float32List(n);
  for (var i = 0; i < n; i++) {
    var s = 0.0;
    for (final c in ch) {
      s += c[i * 4] + c[i * 4 + 1] + c[i * 4 + 2] + c[i * 4 + 3];
    }
    g[i] = s;
  }
  return g;
}

int _bestOffset(Float32List g, int want, int natural) {
  final w = want >> 2,
      nat = natural >> 2,
      seek = _seek >> 2,
      len = (_frame ~/ 2) >> 2;
  if (nat < 0 || nat + len >= g.length) return want;
  var best = 0;
  var bestScore = double.negativeInfinity;
  for (var d = -seek; d <= seek; d++) {
    final p = w + d;
    if (p < 0 || p + len >= g.length) continue;
    var s = 0.0;
    for (var i = 0; i < len; i += 2) {
      s += g[p + i] * g[nat + i];
    }
    if (s > bestScore) {
      bestScore = s;
      best = d;
    }
  }
  return want + best * 4;
}

/// Changes the length by [ratio] (2 = twice as long) keeping the pitch.
List<Float32List> timeStretch(List<Float32List> ch, double ratio) {
  final n = ch[0].length;
  if ((ratio - 1).abs() < 1e-4) {
    return [for (final c in ch) Float32List.fromList(c)];
  }
  final outLen = math.max(1, (n * ratio).round());
  final out = [for (final _ in ch) Float32List(outLen + _frame)];
  final norm = Float32List(outLen + _frame);
  final g = _guide(ch);
  var prevIn = 0;
  for (var o = 0; o < outLen; o += _hop) {
    final want = (o / ratio).round();
    final src = o == 0 ? 0 : _bestOffset(g, want, prevIn + _hop);
    final i0 = math.max(0, -src), i1 = math.min(_frame, n - src);
    for (var c = 0; c < ch.length; c++) {
      final x = ch[c], y = out[c];
      for (var i = i0; i < i1; i++) {
        y[o + i] += x[src + i] * _hann[i];
      }
    }
    for (var i = 0; i < _frame; i++) {
      norm[o + i] += _hann[i];
    }
    prevIn = src;
  }
  return [
    for (final y in out)
      () {
        final r = Float32List(outLen);
        for (var i = 0; i < outLen; i++) {
          r[i] = norm[i] > 1e-3 ? y[i] / norm[i] : 0;
        }
        return r;
      }(),
  ];
}

/// Linear-interpolation resampling to [outLen] samples.
Float32List resample(Float32List x, int outLen) {
  final r = Float32List(outLen);
  final step = (x.length - 1) / math.max(1, outLen - 1);
  for (var i = 0; i < outLen; i++) {
    final p = i * step, j = p.floor(), f = p - j;
    r[i] = x[j] * (1 - f) + (j + 1 < x.length ? x[j + 1] : x[j]) * f;
  }
  return r;
}

List<Float32List> pitchShift(List<Float32List> ch, double semitones) {
  if (semitones == 0) return [for (final c in ch) Float32List.fromList(c)];
  final ratio = math.pow(2, semitones / 12).toDouble();
  return [for (final c in timeStretch(ch, ratio)) resample(c, ch[0].length)];
}

/// Tempo (speed, pitch kept) and key together, for one remix clip.
List<Float32List> retune(List<Float32List> ch, double speed, double semitones) {
  final pitch = math.pow(2, semitones / 12).toDouble();
  final outLen = math.max(1, (ch[0].length / speed).round());
  return [for (final c in timeStretch(ch, pitch / speed)) resample(c, outLen)];
}

/// Semitones to move [fromRoot] to [toRoot], at most a tritone either way.
int semitoneShift(int fromRoot, int toRoot) {
  var d = (((toRoot - fromRoot) % 12) + 12) % 12;
  if (d > 6) d -= 12;
  return d;
}

/// Realtime deck reader: stereo layers (song or stems) with gains, at a tempo
/// [rate] and [pitch] ratio. [render] fills each block.
class DeckReader {
  DeckReader(this.layers) : gains = List.filled(layers.length, 1);
  final List<List<Float32List>> layers;
  final List<double> gains;
  double rate = 1, pitch = 1, pos = 0;
  bool playing = false;
  (double, double)? loop;
  final _ring = [Float32List(_frame * 2), Float32List(_frame * 2)];
  final _ringNorm = Float32List(_frame * 2);
  int _outPos = 0, _readPos = 0;
  double _lastSrc = 0;

  int get length => layers.isEmpty ? 0 : layers[0][0].length;

  void seek(double p) {
    pos = p.clamp(0, length.toDouble());
    for (final r in _ring) {
      r.fillRange(0, r.length, 0);
    }
    _ringNorm.fillRange(0, _ringNorm.length, 0);
    _outPos = 0;
    _readPos = 0;
    _lastSrc = pos;
    _grain(first: true);
  }

  double _sample(int c, double p) {
    final j = p.floor(), f = p - j;
    var s = 0.0;
    for (var l = 0; l < layers.length; l++) {
      final g = gains[l];
      if (g == 0) continue;
      final x = c < layers[l].length ? layers[l][c] : layers[l][0];
      if (j < 0 || j + 1 >= x.length) continue;
      s += (x[j] * (1 - f) + x[j + 1] * f) * g;
    }
    return s;
  }

  double _match(double want) {
    final nat = _lastSrc + _hop * pitch;
    var best = 0;
    var bestScore = double.negativeInfinity;
    for (var d = -128; d <= 128; d += 8) {
      var s = 0.0;
      for (var i = 0; i < 256; i += 4) {
        s += _sample(0, want + d + i * pitch) * _sample(0, nat + i * pitch);
      }
      if (s > bestScore) {
        bestScore = s;
        best = d;
      }
    }
    return want + best;
  }

  void _grain({bool first = false}) {
    final src = first ? pos : _match(pos);
    final base = _readPos;
    for (var i = 0; i < _frame; i++) {
      final k = (base + i) % _ringNorm.length;
      final w = _hann[i];
      for (var c = 0; c < 2; c++) {
        _ring[c][k] += _sample(c, src + i * pitch) * w;
      }
      _ringNorm[k] += w;
    }
    _lastSrc = src;
    pos += _hop * rate;
    final lp = loop;
    if (lp != null && lp.$2 > lp.$1 && pos >= lp.$2) {
      final len = lp.$2 - lp.$1;
      pos = lp.$1 + ((pos - lp.$1) % len);
      _lastSrc = pos - _hop * pitch;
    }
  }

  void render(List<Float32List> out, int frames) {
    for (var i = 0; i < frames; i++) {
      if (!playing || pos >= length) {
        out[0][i] = 0;
        out[1][i] = 0;
        continue;
      }
      final k = _readPos % _ringNorm.length;
      final nrm = _ringNorm[k] > 1e-3 ? _ringNorm[k] : 1;
      out[0][i] = _ring[0][k] / nrm;
      out[1][i] = _ring[1][k] / nrm;
      _ring[0][k] = 0;
      _ring[1][k] = 0;
      _ringNorm[k] = 0;
      _readPos++;
      if (++_outPos >= _hop) {
        _outPos = 0;
        _grain();
      }
    }
  }

  double time(int sampleRate) =>
      math.max(0, pos - (_frame - _hop) * rate) / sampleRate;
}
