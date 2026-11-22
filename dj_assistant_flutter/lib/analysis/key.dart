import 'dart:math' as math;
import 'dart:typed_data';

import 'analysis.dart' show estimateTuning, spectrogramFrames;

/// Key detection (version 3).
///
/// 1. Spectral **peaks** only (local maxima, sub-bin interpolated) are mapped
///    to semitones with a cosine window, so a note counts once however many
///    FFT bins it spans (2.x before: every bin counted, which weighted high
///    notes far above bass and chords).
/// 2. Each frame is normalised, so a loud drop does not outvote the rest.
/// 3. Optional overtone suppression (a note's 3rd and 5th harmonics land a
///    twelfth and two octaves plus a third above it) and bass weighting.
/// 4. Pitch classes are correlated with a key profile; [keyProfiles] holds
///    the candidates the precision benchmark compares (test/key_sweep_test).
class KeyParams {
  /// The defaults won the precision benchmark (tool/make_bench.py, two
  /// independent sets of 80 and 60 tracks): exact key 83.8 % and 86.7 %,
  /// MIREX 88.1 % and 90.2 %, against 63.8 % / 73.0 % for 2.x's detector.
  /// Overtone suppression and bass weighting did not help once the Sha'ath
  /// profile is used (it was derived from audio, overtones included), so
  /// they default to off.
  const KeyParams({
    this.profile = 'shaath',
    this.h3 = 0,
    this.h5 = 0,
    this.bassWeight = 0,
    this.fftSize = 4096,
    this.compress = 1.0,
    this.frameNorm = true,
  });
  final String profile;
  final double h3, h5, bassWeight, compress;
  final int fftSize;
  final bool frameNorm;

  @override
  String toString() =>
      '$profile h3=$h3 h5=$h5 bass=$bassWeight n=$fftSize c=$compress '
      'norm=$frameNorm';
}

/// Major and minor profiles, tonic first.
const keyProfiles = <String, (List<double>, List<double>)>{
  // Krumhansl & Kessler (1982): probe-tone ratings (what 2.x used).
  'krumhansl': (
    [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
    [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17],
  ),
  // Temperley (1999), revised from musical corpora.
  'temperley': (
    [5.0, 2.0, 3.5, 2.0, 4.5, 4.0, 2.0, 4.5, 2.0, 3.5, 1.5, 4.0],
    [5.0, 2.0, 3.5, 4.5, 2.0, 4.0, 2.0, 4.5, 3.5, 2.0, 1.5, 4.0],
  ),
  // Sha'ath (2011), as used by KeyFinder: derived from audio of popular music.
  'shaath': (
    [7.24, 3.50, 3.58, 2.85, 5.38, 4.56, 2.45, 6.99, 3.39, 4.56, 4.07, 4.46],
    [7.00, 3.14, 4.36, 5.40, 3.67, 4.09, 3.91, 6.20, 3.63, 2.87, 5.35, 3.83],
  ),
  // Diatonic with a strong tonic triad; minor allows the raised 7th.
  'diatonic': (
    [1.0, 0.15, 0.55, 0.15, 0.8, 0.55, 0.15, 0.9, 0.15, 0.55, 0.15, 0.55],
    [1.0, 0.15, 0.55, 0.8, 0.15, 0.55, 0.15, 0.9, 0.55, 0.15, 0.45, 0.3],
  ),
};

/// Salience per MIDI note 24…107 (index = midi − 24) and the tuning used.
(Float64List, double, double)? noteSalience(
  Float32List x,
  double sr,
  KeyParams p,
) {
  final n = p.fftSize;
  final spec = spectrogramFrames(x, n, n ~/ 2);
  if (spec.isEmpty) return null;
  final (tune, strength) = estimateTuning(spec, sr, n);
  final shift = tune.abs() >= 0.2 && strength >= 0.2 ? tune : 0.0;
  final sal = Float64List(84);
  final frame = Float64List(84);
  for (final m in spec) {
    var peak = 0.0;
    for (final v in m) {
      if (v > peak) peak = v;
    }
    if (peak <= 0) continue;
    final floor = peak * 1e-3; // −60 dB
    frame.fillRange(0, 84, 0);
    var total = 0.0;
    for (var k = 2; k < m.length - 1; k++) {
      final y1 = m[k];
      if (y1 < floor || y1 <= m[k - 1] || y1 < m[k + 1]) continue;
      final y0 = m[k - 1], y2 = m[k + 1];
      final den = y0 - 2 * y1 + y2;
      final kk = den.abs() > 1e-12 ? k + 0.5 * (y0 - y2) / den : k.toDouble();
      final f = kk * sr / n;
      if (f < 30 || f > 4000) continue;
      final midi = 12 * math.log(f / 440) / math.ln2 + 69 - shift;
      final note = midi.round();
      if (note < 24 || note > 107) continue;
      final d = (midi - note).abs();
      final w = math.pow(math.cos(math.pi * d), 2).toDouble();
      final v = w * math.pow(y1, p.compress).toDouble();
      frame[note - 24] += v;
      total += v;
    }
    if (total <= 0) continue;
    final scale = p.frameNorm ? 1 / total : 1.0;
    for (var i = 0; i < 84; i++) {
      sal[i] += frame[i] * scale;
    }
  }
  return (sal, tune, strength);
}

/// Pitch-class profile from note saliences, with overtones taken back and
/// the bass weighted.
Float64List chromaFromSalience(Float64List sal, KeyParams p) {
  final s = Float64List.fromList(sal);
  // lowest first, so a note's own fundamental is cleaned before it is used
  for (var i = 0; i < 84; i++) {
    var v = sal[i];
    if (i >= 19) v -= p.h3 * sal[i - 19];
    if (i >= 28) v -= p.h5 * sal[i - 28];
    s[i] = math.max(0, v);
  }
  final chroma = Float64List(12), bass = Float64List(12);
  for (var i = 0; i < 84; i++) {
    final pc = (i + 24) % 12;
    chroma[pc] += s[i];
    if (i + 24 < 52) bass[pc] += s[i];
  }
  final ct = chroma.reduce((a, b) => a + b), bt = bass.reduce((a, b) => a + b);
  if (bt > 0 && ct > 0 && p.bassWeight > 0) {
    for (var i = 0; i < 12; i++) {
      chroma[i] += p.bassWeight * ct * bass[i] / bt;
    }
  }
  return chroma;
}

/// (root 0–11 from C, minor, correlation, runner-up correlation) for a
/// pitch-class profile, or null when nothing correlates.
(int, bool, double, double)? bestKey(Float64List chroma, String profile) {
  final (major, minor) = keyProfiles[profile]!;
  final mc = chroma.reduce((a, b) => a + b) / 12;
  double corr(List<double> prof, int root) {
    final mp = prof.reduce((a, b) => a + b) / 12;
    var num = 0.0, dc = 0.0, dp = 0.0;
    for (var i = 0; i < 12; i++) {
      final c = chroma[i] - mc, q = prof[(i - root + 12) % 12] - mp;
      num += c * q;
      dc += c * c;
      dp += q * q;
    }
    return (dc == 0 || dp == 0) ? 0 : num / math.sqrt(dc * dp);
  }

  var best = (-2.0, 0, false), second = -2.0;
  for (var r = 0; r < 12; r++) {
    for (final m in [false, true]) {
      final c = corr(m ? minor : major, r);
      if (c > best.$1) {
        second = best.$1;
        best = (c, r, m);
      } else if (c > second) {
        second = c;
      }
    }
  }
  if (best.$1 <= 0.2) return null;
  return (best.$2, best.$3, best.$1, second);
}
