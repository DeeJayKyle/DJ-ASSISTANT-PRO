import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/pcm.dart';
import 'beatgrid.dart';
import 'chromaprint.dart';
import 'fft.dart';
import 'loudness.dart';

/// Local audio analysis, ported from 1.x `analysis.rs`. Everything here is an
/// *estimate*: shown as such, overridable by the DJ, and stored with [method] and
/// [version] so it can be regenerated. Files are only opened for reading.
const method = 'dj-assistant-dsp';

/// 2: whole-file beatgrid, BPM range and tuning-aware key (2.1).
const version = 2;

/// Longest stretch of audio decoded for analysis (keeps very long mixes fast).
const maxSeconds = 15.0 * 60.0;

class CuePoint {
  CuePoint(this.ms, this.label);
  final int ms;
  final String label;
  Map<String, Object> toJson() => {'ms': ms, 'label': label};
}

class Analysis {
  int durationMs = 0;
  double? bpm;
  double bpmConfidence = 0;

  /// Half- or double-time alternative when the tempo is ambiguous.
  double? bpmAlt;
  String? key, camelot;
  double keyConfidence = 0;
  int? energy;

  /// Raw 0..1 energy score before library-relative scaling.
  double? energyRaw;
  double? loudnessLufs, peakDbfs;
  int clippedRuns = 0;
  int silenceStartMs = 0, silenceEndMs = 0;
  int? introEndMs, outroStartMs;
  final cues = <CuePoint>[];
  Uint8List waveform = Uint8List(0);
  bool? tempoStable;

  /// Whole-file beatgrid (tempo markers and downbeat), when beats were found.
  BeatGrid? beatgrid;

  /// How far the music is from A = 440 Hz, in cents (key analysis).
  double? tuningCents;
  final warnings = <String>[];

  /// Chromaprint sub-fingerprints of the first two minutes.
  List<int> fingerprint = const [];

  /// AcoustID-compatible encoded fingerprint.
  String? fingerprintEncoded;

  Map<String, Object?> toJson() => {
    'duration_ms': durationMs,
    'bpm': bpm,
    'bpm_confidence': bpmConfidence,
    'bpm_alt': bpmAlt,
    'key': key,
    'camelot': camelot,
    'key_confidence': keyConfidence,
    'energy': energy,
    'energy_raw': energyRaw,
    'loudness_lufs': loudnessLufs,
    'peak_dbfs': peakDbfs,
    'clipped_runs': clippedRuns,
    'silence_start_ms': silenceStartMs,
    'silence_end_ms': silenceEndMs,
    'intro_end_ms': introEndMs,
    'outro_start_ms': outroStartMs,
    'cues': [for (final c in cues) c.toJson()],
    'waveform': waveform.toList(),
    'tempo_stable': tempoStable,
    'beatgrid': beatgrid?.toJson(),
    'tuning_cents': tuningCents,
    'warnings': warnings,
  };
}

/// Decoded audio plus the measurements taken while decoding.
class Decoded {
  Decoded(
    this.mono,
    this.sampleRate, {
    this.loudnessLufs,
    this.peak = 0,
    this.clippedRuns = 0,
  });
  final Float32List mono;
  final int sampleRate;
  final double? loudnessLufs;
  final double peak;
  final int clippedRuns;
  List<int> fingerprint = const [];
  String? fingerprintEncoded;
}

/// Something that consumes interleaved audio while it is decoded (the fingerprinter).
abstract class DecodeTap {
  void start(int sampleRate, int channels);
  void add(Float32List interleaved, int framesSoFar);
  void finish(Decoded d);
}

/// Decodes [path] (read-only) to mono, measuring loudness, peak and clipping.
/// [seconds] null reads the whole file.
Decoded decode(String path, {double? seconds = maxSeconds, DecodeTap? tap}) {
  final r = openPcm(path);
  try {
    final sr = r.sampleRate, ch = r.channels;
    final maxFrames = seconds == null ? 1 << 62 : (seconds * sr).floor();
    final meter = LoudnessMeter(ch, sr);
    tap?.start(sr, ch);
    final parts = <Float32List>[];
    var frames = 0;
    var peak = 0.0;
    var clipped = 0, run = 0;
    while (frames < maxFrames) {
      final Float32List? block;
      try {
        block = r.read();
      } on DecodeException {
        if (frames == 0) rethrow;
        break; // keep what decoded before the damage
      }
      if (block == null) break;
      meter.add(block);
      tap?.add(block, frames);
      final n = block.length ~/ ch;
      final mono = Float32List(n);
      for (var i = 0; i < n; i++) {
        var sum = 0.0;
        for (var c = 0; c < ch; c++) {
          final s = block[i * ch + c];
          final a = s.abs();
          if (a > peak) peak = a;
          if (a >= 0.999) {
            if (++run == 3) clipped++;
          } else {
            run = 0;
          }
          sum += s;
        }
        mono[i] = sum / ch;
      }
      parts.add(mono);
      frames += n;
    }
    if (frames == 0) throw DecodeException('no audio samples decoded');
    final all = Float32List(frames);
    var o = 0;
    for (final p in parts) {
      all.setAll(o, p);
      o += p.length;
    }
    final d = Decoded(
      all,
      sr,
      loudnessLufs: meter.integrated,
      peak: peak,
      clippedRuns: clipped,
    );
    tap?.finish(d);
    return d;
  } finally {
    r.close();
  }
}

double _db(double x) => 20 * math.log(math.max(x, 1e-9)) / math.ln10;

/// Average-decimates to about 11 kHz for tempo and key work.
(Float32List, double) _downsample(Float32List x, int sr) {
  final d = math.max(1, (sr / 11025).round());
  final n = (x.length + d - 1) ~/ d;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final s = i * d, e = math.min(x.length, s + d);
    var sum = 0.0;
    for (var j = s; j < e; j++) {
      sum += x[j];
    }
    out[i] = sum / (e - s);
  }
  return (out, sr / d);
}

final _ffts = <int, Fft>{};
final _hanns = <int, Float64List>{};

/// Magnitude spectrogram: frames of [n] (Hann window) every [hop] samples, n/2 bins.
List<Float64List> _spectrogram(Float32List x, int n, int hop, [int? limit]) {
  final len = limit == null ? x.length : math.min(limit, x.length);
  if (len < n) return const [];
  final fft = _ffts[n] ??= Fft(n);
  final w = _hanns[n] ??= Float64List.fromList([
    for (var i = 0; i < n; i++) 0.5 - 0.5 * math.cos(2 * math.pi * i / n),
  ]);
  final re = Float64List(n), im = Float64List(n);
  final out = <Float64List>[];
  for (var i = 0; i + n <= len; i += hop) {
    for (var k = 0; k < n; k++) {
      re[k] = x[i + k] * w[k];
      im[k] = 0;
    }
    fft.transform(re, im);
    final m = Float64List(n ~/ 2);
    for (var k = 0; k < n ~/ 2; k++) {
      m[k] = math.sqrt(re[k] * re[k] + im[k] * im[k]);
    }
    out.add(m);
  }
  return out;
}

/// Spectral-flux onsets: (envelope, frames per second, low-band envelope).
/// The low band (below 150 Hz: kick and bass) places the downbeat.
(Float64List, double, Float64List) _onsetEnvelope(Float32List x, double sr) {
  const hop = 128;
  final spec = _spectrogram(x, 1024, hop);
  final env = Float64List(spec.length), lowEnv = Float64List(spec.length);
  final lowBins = math.max(2, (150 / (sr / 1024)).ceil());
  Float64List? prev;
  for (var f = 0; f < spec.length; f++) {
    final frame = spec[f];
    final lf = Float64List(frame.length);
    for (var k = 0; k < frame.length; k++) {
      lf[k] = math.log(1 + 10 * frame[k]);
    }
    var flux = 0.0, low = 0.0;
    if (prev != null) {
      for (var k = 0; k < lf.length; k++) {
        final d = lf[k] - prev[k];
        if (d > 0) {
          flux += d;
          if (k < lowBins) low += d;
        }
      }
    }
    env[f] = flux;
    lowEnv[f] = low;
    prev = lf;
  }
  // Remove the slow trend.
  const w = 16;
  final out = Float64List(env.length);
  var acc = 0.0;
  for (var i = 0; i < env.length; i++) {
    acc += env[i];
    if (i >= w) acc -= env[i - w];
    final mean = acc / (math.min(i, w - 1) + 1);
    out[i] = math.max(0, env[i] - mean);
  }
  return (out, sr / hop, lowEnv);
}

/// Tempo from an onset envelope: (bpm, confidence 0..1).
(double, double)? _tempo(Float64List env, double fr) {
  if (env.length < (fr * 8).floor()) return null;
  double ac(int lag) {
    var s = 0.0;
    for (var i = 0; i < env.length - lag; i++) {
      s += env[i] * env[i + lag];
    }
    return s / (env.length - lag);
  }

  final minLag = (60 * fr / 200).floor();
  final maxLag = (60 * fr / 60).ceil();
  if (maxLag + 2 >= env.length) return null;
  final vals = Float64List(maxLag + 2);
  for (var l = 0; l <= maxLag + 1; l++) {
    vals[l] = l < math.max(0, minLag - 1) ? 0 : ac(l);
  }
  int? bestLag;
  var bestScore = 0.0;
  final scores = <double>[];
  for (var lag = minLag; lag <= maxLag; lag++) {
    final bpm = 60 * fr / lag;
    final reinforce = 2 * lag <= maxLag + 1
        ? 0.5 * vals[math.min(2 * lag, vals.length - 1)]
        : 0.0;
    final l2 = math.log(bpm / 120) / math.ln2;
    final prior = math.exp(-0.5 * l2 * l2);
    final s = (vals[lag] + reinforce) * prior;
    scores.add(s);
    if (bestLag == null || s > bestScore) {
      bestLag = lag;
      bestScore = s;
    }
  }
  if (bestLag == null) return null;
  var lag = bestLag;
  // DJ convention: prefer the half-time reading above 150 BPM when the evidence
  // for it is close (hats and off-beats often double the tempo).
  if (60 * fr / lag > 150 && 2 * lag <= maxLag) {
    final hl = 2 * lag;
    final half = math.max(
      math.max(vals[hl], vals[hl - 1]),
      vals[math.min(hl + 1, vals.length - 1)],
    );
    if (half >= 0.55 * vals[lag]) {
      var best = hl - 1;
      for (var c = hl - 1; c <= math.min(hl + 1, vals.length - 2); c++) {
        // max_by keeps the last of equal maxima
        if (vals[c] >= vals[best]) best = c;
      }
      lag = best;
    }
  }
  final mean = scores.reduce((a, b) => a + b) / scores.length;
  final variance =
      scores.fold<double>(0, (a, v) => a + (v - mean) * (v - mean)) /
      scores.length;
  final conf = variance > 0
      ? ((bestScore - mean) / math.sqrt(variance) / 6).clamp(0.0, 1.0)
      : 0.0;
  final y0 = vals[lag - 1], y1 = vals[lag], y2 = vals[lag + 1];
  final denom = y0 - 2 * y1 + y2;
  final off = denom.abs() > 1e-12
      ? (0.5 * (y0 - y2) / denom).clamp(-0.5, 0.5)
      : 0.0;
  final bpm = 60 * fr / (lag + off);
  return ((bpm * 10).round() / 10, conf);
}

const _notes = [
  'C',
  'C#',
  'D',
  'Eb',
  'E',
  'F',
  'F#',
  'G',
  'Ab',
  'A',
  'Bb',
  'B',
];
const _camelotMajor = [
  '8B',
  '3B',
  '10B',
  '5B',
  '12B',
  '7B',
  '2B',
  '9B',
  '4B',
  '11B',
  '6B',
  '1B',
];
const _camelotMinor = [
  '5A',
  '12A',
  '7A',
  '2A',
  '9A',
  '4A',
  '11A',
  '6A',
  '1A',
  '8A',
  '3A',
  '10A',
];
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
  2.60,
  3.53,
  2.54,
  4.75,
  3.98,
  2.69,
  3.34,
  3.17,
];

/// How far the music sits from A = 440 Hz, in semitones (−0.5…0.5): the
/// weighted circular mean of where spectral peaks fall between semitones,
/// with how consistent they are (0…1).
(double, double) estimateTuning(List<Float64List> spec, double sr, int n) {
  var c = 0.0, s = 0.0, w = 0.0;
  for (final frame in spec) {
    for (var k = 2; k < frame.length - 1; k++) {
      final m = frame[k];
      if (m <= frame[k - 1] || m < frame[k + 1]) continue;
      final y0 = frame[k - 1], y2 = frame[k + 1];
      final den = y0 - 2 * m + y2;
      final kk = den.abs() > 1e-12 ? k + 0.5 * (y0 - y2) / den : k.toDouble();
      final f = kk * sr / n;
      if (f < 200 || f > 1760) continue;
      final midi = 12 * math.log(f / 440) / math.ln2 + 69;
      final a = 2 * math.pi * (midi - midi.round());
      c += m * math.cos(a);
      s += m * math.sin(a);
      w += m;
    }
  }
  if (w <= 0) return (0, 0);
  return (math.atan2(s, c) / (2 * math.pi), math.sqrt(c * c + s * s) / w);
}

/// Key from chroma and Krumhansl profiles: (name, Camelot, confidence,
/// tuning in cents). Music tuned 20 cents or more away from A = 440 Hz
/// (pitched vinyl rips, older recordings) is read on its own tuning, so its
/// notes are not split between neighbouring semitones.
(String, String, double, double)? _key(Float32List x, double sr) {
  const n = 4096;
  final spec = _spectrogram(x, n, n ~/ 2);
  if (spec.isEmpty) return null;
  final (tune, strength) = estimateTuning(spec, sr, n);
  final shift = tune.abs() >= 0.2 && strength >= 0.2 ? tune : 0.0;
  final chroma = Float64List(12);
  final pcs = Int32List(n ~/ 2);
  for (var k = 1; k < n ~/ 2; k++) {
    final f = k * sr / n;
    if (f < 65 || f > 1760) {
      pcs[k] = -1;
      continue;
    }
    final midi = 12 * math.log(f / 440) / math.ln2 + 69 - shift;
    pcs[k] = midi.round() % 12;
  }
  for (final frame in spec) {
    for (var k = 1; k < frame.length; k++) {
      if (pcs[k] >= 0) chroma[pcs[k]] += math.sqrt(frame[k]);
    }
  }
  double corr(List<double> profile, int root) {
    final p = [for (var i = 0; i < 12; i++) profile[(i + 12 - root) % 12]];
    final mc = chroma.reduce((a, b) => a + b) / 12,
        mp = p.reduce((a, b) => a + b) / 12;
    var num = 0.0, dc = 0.0, dp = 0.0;
    for (var i = 0; i < 12; i++) {
      num += (chroma[i] - mc) * (p[i] - mp);
      dc += (chroma[i] - mc) * (chroma[i] - mc);
      dp += (p[i] - mp) * (p[i] - mp);
    }
    return (dc == 0 || dp == 0) ? 0 : num / math.sqrt(dc * dp);
  }

  final scores = <(double, int, bool)>[];
  for (var r = 0; r < 12; r++) {
    scores.add((corr(_major, r), r, false));
    scores.add((corr(_minor, r), r, true));
  }
  // Stable sort, highest first (as 1.x sort_by).
  final idx = List.generate(scores.length, (i) => i)
    ..sort((a, b) {
      final c = scores[b].$1.compareTo(scores[a].$1);
      return c != 0 ? c : a.compareTo(b);
    });
  final (best, root, minor) = scores[idx[0]];
  if (best <= 0.2) return null;
  final conf = ((best - scores[idx[1]].$1) * 5 + math.max(0, best - 0.5)).clamp(
    0.0,
    1.0,
  );
  return (
    '${_notes[root]} ${minor ? 'minor' : 'major'}',
    minor ? _camelotMinor[root] : _camelotMajor[root],
    conf.toDouble(),
    (tune * 1000).round() / 10,
  );
}

double _rms(Float32List x, int s, int e) {
  var sum = 0.0;
  for (var i = s; i < e; i++) {
    sum += x[i] * x[i];
  }
  return math.sqrt(sum / (e - s));
}

/// Runs every analysis stage on decoded audio. [bpmRange] is one of
/// [bpmRanges] ('auto' or null keeps this app's own half/double-time rule).
Analysis analyseDecoded(Decoded d, {String? bpmRange}) {
  final sr = d.sampleRate.toDouble();
  final x = d.mono;
  final a = Analysis()
    ..durationMs = (x.length / sr * 1000).floor()
    ..loudnessLufs = d.loudnessLufs
    ..clippedRuns = d.clippedRuns
    ..peakDbfs = (_db(d.peak) * 10).round() / 10
    ..fingerprint = d.fingerprint
    ..fingerprintEncoded = d.fingerprintEncoded;

  // Silence at start and end: 10 ms windows under −48 dBFS RMS.
  final win = math.max(1, (sr / 100).floor());
  final rms = [
    for (var s = 0; s < x.length; s += win)
      _rms(x, s, math.min(x.length, s + win)),
  ];
  final first = rms.indexWhere((r) => _db(r) > -48);
  final last = rms.lastIndexWhere((r) => _db(r) > -48);
  if (first < 0) {
    a.warnings.add('The file appears to be silent.');
    return a;
  }
  a
    ..silenceStartMs = first * 10
    ..silenceEndMs = (rms.length - 1 - last) * 10;

  // Waveform overview: 800 peak buckets.
  const buckets = 800;
  final per = math.max(1, x.length ~/ buckets);
  final wf = <int>[];
  for (var s = 0; s < x.length && wf.length < buckets; s += per) {
    var m = 0.0;
    for (var i = s; i < math.min(x.length, s + per); i++) {
      final v = x[i].abs();
      if (v > m) m = v;
    }
    wf.add((math.min(m, 1.0) * 255).floor());
  }
  a.waveform = Uint8List.fromList(wf);

  // Section envelope: 0.5 s RMS in dB.
  final half = math.max(1, (sr / 2).floor());
  final env = [
    for (var s = 0; s < x.length; s += half)
      _db(_rms(x, s, math.min(x.length, s + half))),
  ];
  if (env.length >= 16) {
    final sorted = [...env]..sort();
    final thr = sorted[sorted.length * 3 ~/ 4] - 3.0;
    const run = 4;
    bool loud(int s, int e) {
      for (var i = s; i < e; i++) {
        if (env[i] < thr) return false;
      }
      return true;
    }

    int? intro, outro;
    for (var i = 0; i < math.max(0, env.length - run); i++) {
      if (loud(i, i + run)) {
        intro = i;
        break;
      }
    }
    for (var i = env.length - 1; i >= run; i--) {
      if (loud(i - run, i)) {
        outro = i;
        break;
      }
    }
    if (intro != null && intro * 500 > a.silenceStartMs + 2000) {
      a.introEndMs = intro * 500;
    }
    if (outro != null && outro * 500 < a.durationMs - a.silenceEndMs - 2000) {
      a.outroStartMs = outro * 500;
    }
    // Drop: biggest rise between consecutive 4 s blocks in the middle of the track.
    const block = 8;
    final blocks = <double>[];
    for (var s = 0; s < env.length; s += block) {
      final e = math.min(env.length, s + block);
      var sum = 0.0;
      for (var i = s; i < e; i++) {
        sum += env[i];
      }
      blocks.add(sum / (e - s));
    }
    final n = blocks.length;
    int? dropAt;
    var dropRise = 0.0;
    for (
      var i = math.max(1, n * 15 ~/ 100);
      i < math.max(1, n * 75 ~/ 100);
      i++
    ) {
      final rise = blocks[i] - blocks[i - 1];
      if (rise > 4.0 && (dropAt == null || rise > dropRise)) {
        dropAt = i;
        dropRise = rise;
      }
    }
    a.cues.add(CuePoint(a.silenceStartMs, 'First sound'));
    if (a.introEndMs != null) {
      a.cues.add(CuePoint(a.introEndMs!, 'Mix in (intro ends)'));
    }
    if (dropAt != null) {
      a.cues.add(CuePoint(dropAt * block * 500, 'Drop (estimate)'));
    }
    if (a.outroStartMs != null) {
      a.cues.add(CuePoint(a.outroStartMs!, 'Mix out (outro starts)'));
    }
  }

  // Tempo and key on a ~11 kHz mono copy.
  final (low, lsr) = _downsample(x, d.sampleRate);
  final (oenv, fr, lowEnv) = _onsetEnvelope(low, lsr);
  final t = _tempo(oenv, fr);
  if (t != null) {
    final (detected, conf) = t;
    final bpm = (foldBpm(detected, bpmRange) * 10).round() / 10;
    a
      ..bpm = bpm
      ..bpmConfidence = (conf * 100).round() / 100;
    if (bpm != detected) {
      a.bpmAlt = detected;
    } else if (bpm < 95 && bpm * 2 <= 200) {
      a.bpmAlt = bpm * 2;
    } else if (bpm > 145) {
      a.bpmAlt = (bpm / 2 * 10).round() / 10;
    }
    a.beatgrid = beatGrid(
      oenv,
      fr,
      bpm,
      lowEnv: lowEnv,
      // Flux peaks when an onset is three quarters into the 1024-sample
      // window (measured: a constant 2 hops after the window centre at every
      // tempo), the same lag the Studio's beat phase allows for.
      offsetSec: 768 / lsr,
    );
    if (oenv.length > (fr * 40).floor()) {
      final mid = oenv.length ~/ 2;
      final h1 = _tempo(Float64List.sublistView(oenv, 0, mid), fr);
      final h2 = _tempo(Float64List.sublistView(oenv, mid), fr);
      if (h1 != null && h2 != null && h1.$2 > 0.25 && h2.$2 > 0.25) {
        final ratio = h1.$1 / h2.$1;
        final same = [0.5, 1.0, 2.0].any((r) => (ratio / r - 1).abs() < 0.015);
        a.tempoStable = same;
        if (!same) {
          a.warnings.add(
            'Tempo may change during the track (about ${h1.$1.toStringAsFixed(0)} BPM in the first half, '
            '${h2.$1.toStringAsFixed(0)} in the second). A fixed beatgrid may drift.',
          );
        }
      }
    }
    if (conf < 0.2) a.warnings.add('Tempo is uncertain for this track.');
  }
  // Key needs the notes up to 1.76 kHz, so a sample rate of at least 4 kHz.
  final k = d.sampleRate < 4000 ? null : _key(low, lsr);
  if (d.sampleRate < 4000) {
    a.warnings.add(
      'Key not analysed: the sample rate (${d.sampleRate} Hz) is too low.',
    );
  }
  if (k != null) {
    a
      ..key = k.$1
      ..camelot = k.$2
      ..keyConfidence = (k.$3 * 100).round() / 100
      ..tuningCents = k.$4;
  }

  // Energy: a raw 0..1 score from loudness, tempo, percussive punch and brightness.
  // The 1–10 value is later scaled against the DJ's library.
  final lufs =
      d.loudnessLufs ??
      () {
        var s = 0.0;
        for (final v in x) {
          s += v * v;
        }
        return 20 *
                math.log(math.max(math.sqrt(s / x.length), 1e-9)) /
                math.ln10 -
            0.7;
      }();
  double norm(double v, double lo, double hi) =>
      ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
  final onsetMean = oenv.isEmpty
      ? 0.0
      : oenv.reduce((p, q) => p + q) / oenv.length;
  var ls = 0.0;
  for (final v in low) {
    ls += v * v;
  }
  final level = math.max(math.sqrt(ls / math.max(1, low.length)), 1e-6);
  final punch = onsetMean / (level * 100);
  final spec = _spectrogram(low, 2048, 2048, (lsr * 60).floor());
  var num = 0.0, den = 0.0;
  for (final frame in spec) {
    for (var b = 0; b < frame.length; b++) {
      num += b * lsr / 2048 * frame[b];
      den += frame[b];
    }
  }
  final centroid = den > 0 ? num / den : 0.0;
  final bpmNow = a.bpm;
  final tempo = bpmNow == null
      ? 0.5
      : norm(bpmNow > 150 ? bpmNow / 2 : bpmNow, 70, 132);
  final raw =
      0.35 * norm(lufs, -20, -7) +
      0.3 * tempo +
      0.25 * norm(punch, 0.05, 0.6) +
      0.1 * norm(centroid, 500, 2500);
  a
    ..energyRaw = (raw * 1000).round() / 1000
    ..energy = (1 + (raw * 9).round()).clamp(1, 10);
  if (d.clippedRuns > 10) {
    a.warnings.add(
      '${d.clippedRuns} clipped passages detected (samples at full scale).',
    );
  }
  final l = d.loudnessLufs;
  if (l != null && l < -20) {
    a.warnings.add(
      'Quiet master (${l.toStringAsFixed(1)} LUFS); you may need extra gain.',
    );
  }
  return a;
}

/// Fingerprints the first two minutes while decoding (1.x behaviour).
class FingerprintTap implements DecodeTap {
  Fingerprinter? _printer;
  int _limit = 0;

  @override
  void start(int sampleRate, int channels) {
    _limit = 120 * sampleRate;
    try {
      _printer = Fingerprinter(sampleRate, channels);
    } on ArgumentError {
      _printer = null;
    }
  }

  @override
  void add(Float32List interleaved, int framesSoFar) {
    final p = _printer;
    if (p == null || framesSoFar >= _limit) return;
    final pcm = Int16List(interleaved.length);
    for (var i = 0; i < interleaved.length; i++) {
      pcm[i] = (interleaved[i].clamp(-1.0, 1.0) * 32767).truncate();
    }
    p.consume(pcm);
  }

  @override
  void finish(Decoded d) {
    final p = _printer;
    if (p == null) return;
    p.finish();
    d.fingerprint = List.unmodifiable(p.fingerprint);
    d.fingerprintEncoded = p.fingerprint.isEmpty
        ? null
        : encodeFingerprint(p.fingerprint);
  }
}

/// Decodes and analyses [path], fingerprint included: the first [seconds]
/// (15 minutes, as 1.x), or with null the whole file.
Analysis analyseFile(
  String path, {
  double? seconds = maxSeconds,
  String? bpmRange,
}) => analyseDecoded(
  decode(path, seconds: seconds, tap: FingerprintTap()),
  bpmRange: bpmRange,
);
