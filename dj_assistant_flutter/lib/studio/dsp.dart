/// The Studio's signal processing (1.x `src/studio/dsp/*` and `audio/wav.ts`,
/// `audio/beats.ts`): FFT, tempo, key, beat phase and WAV encoding.
library;

import 'dart:math' as math;
import 'dart:typed_data';

class _Tables {
  _Tables(this.rev, this.cos, this.sin);
  final Uint32List rev;
  final Float64List cos, sin;
}

final _tables = <int, _Tables>{};
_Tables _table(int n) => _tables.putIfAbsent(n, () {
  final rev = Uint32List(n);
  final bits = (math.log(n) / math.ln2).round();
  for (var i = 0; i < n; i++) {
    var r = 0;
    for (var b = 0; b < bits; b++) {
      r |= ((i >> b) & 1) << (bits - 1 - b);
    }
    rev[i] = r;
  }
  final cos = Float64List(n ~/ 2), sin = Float64List(n ~/ 2);
  for (var k = 0; k < n ~/ 2; k++) {
    cos[k] = math.cos((-2 * math.pi * k) / n);
    sin[k] = math.sin((-2 * math.pi * k) / n);
  }
  return _Tables(rev, cos, sin);
});

/// In-place radix-2 FFT on separate real/imaginary arrays (length a power of two).
void fft(Float64List re, Float64List im) {
  final n = re.length;
  final t = _table(n);
  for (var i = 0; i < n; i++) {
    final j = t.rev[i];
    if (i < j) {
      final tr = re[i];
      re[i] = re[j];
      re[j] = tr;
      final ti = im[i];
      im[i] = im[j];
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final half = len >> 1, step = n ~/ len;
    for (var i = 0; i < n; i += len) {
      for (var k = 0, w = 0; k < half; k++, w += step) {
        final a = i + k, b = a + half;
        final wr = t.cos[w], wi = t.sin[w];
        final tr = re[b] * wr - im[b] * wi;
        final ti = re[b] * wi + im[b] * wr;
        re[b] = re[a] - tr;
        im[b] = im[a] - ti;
        re[a] += tr;
        im[a] += ti;
      }
    }
  }
}

final _hann = <int, Float64List>{};
Float64List hann(int size) => _hann.putIfAbsent(size, () {
  final w = Float64List(size);
  for (var i = 0; i < size; i++) {
    w[i] = 0.5 - 0.5 * math.cos((2 * math.pi * i) / (size - 1));
  }
  return w;
});

/// Magnitude spectrum (first size/2 bins) of one windowed frame.
Float64List magnitudes(
  Float32List signal,
  int start,
  int size, [
  Float64List? out,
]) {
  final o = out ?? Float64List(size ~/ 2);
  final re = Float64List(size), im = Float64List(size);
  final w = hann(size);
  for (var i = 0; i < size; i++) {
    final j = start + i;
    re[i] = (j < signal.length ? signal[j] : 0) * w[i];
  }
  fft(re, im);
  for (var k = 0; k < size ~/ 2; k++) {
    o[k] = math.sqrt(re[k] * re[k] + im[k] * im[k]);
  }
  return o;
}

/// Averaging downsample by an integer factor.
Float32List downsample(Float32List signal, int factor) {
  if (factor <= 1) return signal;
  final out = Float32List(signal.length ~/ factor);
  for (var i = 0; i < out.length; i++) {
    var s = 0.0;
    for (var j = 0; j < factor; j++) {
      s += signal[i * factor + j];
    }
    out[i] = s / factor;
  }
  return out;
}

// ---- tempo

class Onsets {
  Onsets(this.env, this.rate);
  final Float64List env;
  final double rate;
}

Onsets onsetEnvelope(Float32List mono, int sampleRate) =>
    _onsetEnvelope(mono, sampleRate);

Onsets _onsetEnvelope(Float32List mono, int sampleRate) {
  const target = 11025, frame = 1024, hop = 128;
  final factor = math.max(1, (sampleRate / target).round());
  final x = downsample(mono, factor);
  final rate = sampleRate / factor;
  final frames = math.max(0, (x.length - frame) ~/ hop);
  final env = Float64List(frames);
  final prev = Float64List(frame ~/ 2), cur = Float64List(frame ~/ 2);
  for (var f = 0; f < frames; f++) {
    magnitudes(x, f * hop, frame, cur);
    var flux = 0.0;
    for (var k = 1; k < frame ~/ 2; k++) {
      final v = math.log(1 + 100 * cur[k]);
      final d = v - prev[k];
      if (d > 0) flux += d;
      prev[k] = v;
    }
    env[f] = flux;
  }
  final win = ((rate / hop) * 0.5).round();
  final out = Float64List(frames);
  var acc = 0.0;
  for (var i = 0; i < frames; i++) {
    acc += env[i];
    if (i >= win) acc -= env[i - win];
    final mean = acc / math.min(i + 1, win);
    out[i] = math.max(0, env[i] - mean);
  }
  return Onsets(out, rate / hop);
}

Float64List _autocorrelation(Float64List env, int maxLag) {
  final n = env.length;
  var mean = 0.0;
  for (final v in env) {
    mean += v;
  }
  mean /= n == 0 ? 1 : n;
  final ac = Float64List(maxLag + 2);
  for (var lag = 0; lag <= maxLag + 1; lag++) {
    var s = 0.0;
    for (var i = 0; i + lag < n; i++) {
      s += (env[i] - mean) * (env[i + lag] - mean);
    }
    ac[lag] = s / ((n - lag) == 0 ? 1 : (n - lag));
  }
  return ac;
}

double _at(Float64List ac, double x) {
  final i = x.floor();
  final f = x - i;
  return i + 1 < ac.length ? ac[i] * (1 - f) + ac[i + 1] * f : 0;
}

class TempoResult {
  TempoResult(this.bpm, this.confidence);
  final double bpm, confidence;
}

TempoResult detectTempo(
  Float32List mono,
  int sampleRate, {
  double min = 60,
  double max = 200,
  Onsets? onsets,
}) {
  final o = onsets ?? onsetEnvelope(mono, sampleRate);
  if (o.env.length < o.rate * 4) return TempoResult(0, 0);
  const beatsInComb = 8;
  final maxLag = ((60 / min) * o.rate * beatsInComb).ceil();
  final ac = _autocorrelation(o.env, math.min(maxLag, o.env.length - 2));
  double score(double bpm) {
    final period = (60 / bpm) * o.rate;
    var s = 0.0;
    var n = 0;
    for (var k = 1; k <= beatsInComb; k++) {
      final lag = period * k;
      if (lag >= ac.length - 1) break;
      s += _at(ac, lag);
      n++;
    }
    return n > 0 ? s / n : 0;
  }

  double prior(double bpm) =>
      math.exp(-0.5 * math.pow((math.log(bpm / 125) / math.ln2) / 0.9, 2));
  var best = 0.0, bestScore = double.negativeInfinity;
  final scores = <double>[];
  for (var bpm = min; bpm <= max; bpm += 0.05) {
    final s = score(bpm) * prior(bpm);
    scores.add(s);
    if (s > bestScore) {
      bestScore = s;
      best = bpm;
    }
  }
  if (best < 85 && score(best * 2) > 0.5 * score(best)) {
    best *= 2;
  } else if (best > 175 && score(best / 2) > 0.5 * score(best)) {
    best /= 2;
  }
  scores.sort();
  final median = scores[scores.length ~/ 2];
  final top = math.max(bestScore, 1e-12);
  final confidence = ((top - median) / top).clamp(0.0, 1.0);
  return TempoResult(
    (best * 10).round() / 10,
    (confidence * 100).round() / 100,
  );
}

// ---- key

const pitches = [
  'C',
  'C#',
  'D',
  'D#',
  'E',
  'F',
  'F#',
  'G',
  'G#',
  'A',
  'A#',
  'B',
];
const _flatNames = {'C#': 'Db', 'D#': 'Eb', 'F#': 'F#', 'G#': 'Ab', 'A#': 'Bb'};
const _major = [
  6.35,
  2.23,
  3.48,
  2.33,
  4.38,
  4.09,
  2.52,
  5.19,
  2.39,
  3.66,
  2.29,
  2.88,
];
const _minor = [
  6.33,
  2.68,
  3.52,
  5.38,
  2.6,
  3.53,
  2.54,
  4.75,
  3.98,
  2.69,
  3.34,
  3.17,
];
const _camMinor = {
  'G#': '1A',
  'D#': '2A',
  'A#': '3A',
  'F': '4A',
  'C': '5A',
  'G': '6A',
  'D': '7A',
  'A': '8A',
  'E': '9A',
  'B': '10A',
  'F#': '11A',
  'C#': '12A',
};
const _camMajor = {
  'B': '1B',
  'F#': '2B',
  'C#': '3B',
  'G#': '4B',
  'D#': '5B',
  'A#': '6B',
  'F': '7B',
  'C': '8B',
  'G': '9B',
  'D': '10B',
  'A': '11B',
  'E': '12B',
};

class KeyResult {
  KeyResult(
    this.key,
    this.short,
    this.camelot,
    this.confidence,
    this.tonic,
    this.mode,
  );
  final String key, short, camelot, mode;
  final double confidence;
  final int tonic;
}

KeyResult keyFrom(int tonic, String mode, [double confidence = 1]) {
  final p = pitches[tonic];
  final name = mode == 'minor' && (p == 'D#' || p == 'A#' || p == 'G#')
      ? _flatNames[p]!
      : (mode == 'major' && p.contains('#') && p != 'F#' ? _flatNames[p]! : p);
  return KeyResult(
    '$name $mode',
    '$name${mode == 'minor' ? 'm' : ''}',
    (mode == 'minor' ? _camMinor : _camMajor)[p]!,
    (confidence * 100).round() / 100,
    tonic,
    mode,
  );
}

(Float64List, Float64List) chromagram(Float32List mono, int sampleRate) {
  final factor = math.max(1, (sampleRate / 11025).round());
  final x = downsample(mono, factor);
  final rate = sampleRate / factor;
  const size = 8192, hop = 4096;
  final chroma = Float64List(12),
      bass = Float64List(12),
      mags = Float64List(size ~/ 2);
  for (var start = 0; start + size <= x.length; start += hop) {
    magnitudes(x, start, size, mags);
    final frame = Float64List(12), low = Float64List(12);
    for (var k = 1; k < size ~/ 2; k++) {
      final f = (k * rate) / size;
      if (f < 55 || f > 2000) continue;
      final midi = 69 + 12 * (math.log(f / 440) / math.ln2);
      final nearest = midi.round();
      if ((midi - nearest).abs() > 0.3) continue;
      final pc = ((nearest % 12) + 12) % 12;
      frame[pc] += mags[k] * mags[k];
      if (f < 200) low[pc] += mags[k] * mags[k];
    }
    final sum = frame.fold(0.0, (a, b) => a + b);
    if (sum > 0) {
      for (var i = 0; i < 12; i++) {
        chroma[i] += math.sqrt(frame[i] / sum);
      }
    }
    final lowSum = low.fold(0.0, (a, b) => a + b);
    if (lowSum > 0) {
      for (var i = 0; i < 12; i++) {
        bass[i] += math.sqrt(low[i] / lowSum);
      }
    }
  }
  return (chroma, bass);
}

double _corr(List<double> a, List<double> b) {
  final n = a.length;
  final ma = a.reduce((x, y) => x + y) / n, mb = b.reduce((x, y) => x + y) / n;
  var num = 0.0, da = 0.0, db = 0.0;
  for (var i = 0; i < n; i++) {
    num += (a[i] - ma) * (b[i] - mb);
    da += (a[i] - ma) * (a[i] - ma);
    db += (b[i] - mb) * (b[i] - mb);
  }
  return da != 0 && db != 0 ? num / math.sqrt(da * db) : 0;
}

KeyResult keyFromChroma(List<double> chroma, [List<double>? bass]) {
  var bassMax = 0.0;
  if (bass != null) {
    for (final v in bass) {
      bassMax = math.max(bassMax, v);
    }
  }
  final results = <(int, String, double)>[];
  for (var tonic = 0; tonic < 12; tonic++) {
    final rotated = [for (var i = 0; i < 12; i++) chroma[(i + tonic) % 12]];
    final tb = bass != null && bassMax > 0
        ? (bass[tonic] / bassMax) * 0.12
        : 0.0;
    results
      ..add((tonic, 'major', _corr(rotated, _major) + tb))
      ..add((tonic, 'minor', _corr(rotated, _minor) + tb));
  }
  final order = List.generate(results.length, (i) => i)
    ..sort((a, b) {
      final c = results[b].$3.compareTo(results[a].$3);
      return c != 0 ? c : a.compareTo(b);
    });
  final best = results[order[0]], second = results[order[1]];
  final confidence = ((best.$3 - second.$3) * 4 + math.max(0, best.$3) * 0.5)
      .clamp(0.0, 1.0);
  return keyFrom(best.$1, best.$2, confidence);
}

KeyResult detectKey(Float32List mono, int sampleRate) {
  final (c, b) = chromagram(mono, sampleRate);
  return keyFromChroma(c, b);
}

/// Reads a key written in tags ("Am", "A minor", "8A", "F#m"…).
KeyResult? parseKey(String? text) {
  if (text == null) return null;
  final t = text.trim();
  final cam = RegExp(
    r'^(1[0-2]|[1-9])\s*([AB])$',
    caseSensitive: false,
  ).firstMatch(t);
  if (cam != null) {
    final code = '${cam[1]}${cam[2]!.toUpperCase()}';
    final table = code.endsWith('A') ? _camMinor : _camMajor;
    final p = table.entries.where((e) => e.value == code).firstOrNull?.key;
    return p == null
        ? null
        : keyFrom(pitches.indexOf(p), code.endsWith('A') ? 'minor' : 'major');
  }
  final m = RegExp(
    r'^([A-Ga-g])\s*([#b♯♭]?)\s*(m(?!aj)|min(?:or)?|maj(?:or)?|major|minor)?$',
  ).firstMatch(t);
  if (m == null) return null;
  const flats = {
    'Db': 'C#',
    'Eb': 'D#',
    'Gb': 'F#',
    'Ab': 'G#',
    'Bb': 'A#',
    'Cb': 'B',
    'Fb': 'E',
  };
  var name =
      m[1]!.toUpperCase() + (m[2] == '♯' ? '#' : (m[2] == '♭' ? 'b' : m[2]!));
  name = flats[name] ?? name;
  if (name == 'E#') name = 'F';
  if (name == 'B#') name = 'C';
  final idx = pitches.indexOf(name);
  if (idx < 0) return null;
  final q = m[3];
  final minor =
      q != null &&
      RegExp('^m(in)?', caseSensitive: false).hasMatch(q) &&
      !RegExp('^maj', caseSensitive: false).hasMatch(q);
  return keyFrom(idx, minor ? 'minor' : 'major');
}

// ---- rhythm

class Rhythm {
  Rhythm(this.bpm, this.firstBeat, this.key);
  final double bpm, firstBeat;
  final KeyResult key;
}

/// Time of the first beat: the phase whose grid lines up best with the onsets.
double beatPhase(
  Float32List mono,
  int sampleRate,
  double bpm, {
  Onsets? onsets,
}) {
  final o = onsets ?? onsetEnvelope(mono, sampleRate);
  if (bpm == 0 || o.env.isEmpty) return 0;
  final period = (60 / bpm) * o.rate;
  var best = 0.0, bestScore = -1.0;
  final steps = math.max(8, period.round());
  double e(int i) => i >= 0 && i < o.env.length ? o.env[i] : 0;
  for (var s = 0; s < steps; s++) {
    final phase = (s / steps) * period;
    var score = 0.0;
    for (var t = phase; t < o.env.length; t += period) {
      final i = t.round();
      score += e(i) + 0.5 * (e(i - 1) + e(i + 1));
    }
    if (score > bestScore) {
      bestScore = score;
      best = phase;
    }
  }
  return (best / o.rate + 0.07) % (60 / bpm);
}

Rhythm rhythm(Float32List mono, int sampleRate, [double? knownBpm]) {
  // tempo and beat phase read the same onset envelope: work it out once
  final o = onsetEnvelope(mono, sampleRate);
  final bpm = knownBpm != null && knownBpm > 0
      ? knownBpm
      : detectTempo(mono, sampleRate, onsets: o).bpm;
  return Rhythm(
    bpm,
    beatPhase(mono, sampleRate, bpm, onsets: o),
    detectKey(mono, sampleRate),
  );
}

// ---- WAV

/// 16- or 24-bit PCM WAV.
Uint8List encodeWav(
  List<Float32List> channels,
  int sampleRate, [
  int bits = 16,
]) {
  final n = channels.isEmpty ? 0 : channels[0].length;
  final ch = channels.length, bps = bits ~/ 8, data = n * ch * bps;
  final b = ByteData(44 + data);
  void s(int o, String x) {
    for (var i = 0; i < x.length; i++) {
      b.setUint8(o + i, x.codeUnitAt(i));
    }
  }

  s(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  b
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, ch, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * ch * bps, Endian.little)
    ..setUint16(32, ch * bps, Endian.little)
    ..setUint16(34, bits, Endian.little);
  s(36, 'data');
  b.setUint32(40, data, Endian.little);
  var o = 44;
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < ch; c++) {
      final v = channels[c][i].clamp(-1.0, 1.0);
      if (bits == 16) {
        b.setInt16(
          o,
          (v < 0 ? v * 0x8000 : v * 0x7fff).truncate(),
          Endian.little,
        );
        o += 2;
      } else {
        final x = (v < 0 ? v * 0x800000 : v * 0x7fffff).round();
        b
          ..setUint8(o, x & 0xff)
          ..setUint8(o + 1, (x >> 8) & 0xff)
          ..setUint8(o + 2, (x >> 16) & 0xff);
        o += 3;
      }
    }
  }
  return b.buffer.asUint8List();
}

Float32List mono(List<Float32List> ch) {
  if (ch.length == 1) return ch[0];
  final out = Float32List(ch[0].length);
  for (var i = 0; i < out.length; i++) {
    var s = 0.0;
    for (final c in ch) {
      s += c[i];
    }
    out[i] = s / ch.length;
  }
  return out;
}

double peak(List<Float32List> ch) {
  var p = 0.0;
  for (final c in ch) {
    for (final v in c) {
      if (v.abs() > p) p = v.abs();
    }
  }
  return p;
}

/// Waveform overview: [bins] peak values from 0 to 1.
Float32List overview(List<Float32List> ch, [int bins = 600]) {
  final n = ch.isEmpty ? 0 : ch[0].length;
  final out = Float32List(bins);
  final step = math.max(1, n ~/ bins);
  for (var b = 0; b < bins; b++) {
    var p = 0.0;
    for (var i = b * step; i < math.min(n, (b + 1) * step); i += 4) {
      for (final c in ch) {
        if (c[i].abs() > p) p = c[i].abs();
      }
    }
    out[b] = p;
  }
  var m = 1e-9;
  for (final v in out) {
    if (v > m) m = v;
  }
  for (var i = 0; i < bins; i++) {
    out[i] /= m;
  }
  return out;
}
