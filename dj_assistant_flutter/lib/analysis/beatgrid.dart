import 'dart:math' as math;
import 'dart:typed_data';

/// Whole-file beatgrid: every beat of the track, then tempo markers and a
/// downbeat. Built from the published dynamic-programming beat tracker
/// (D. P. W. Ellis, "Beat Tracking by Dynamic Programming", 2007), so the grid
/// follows the music across the entire file rather than one window of it.
///
/// A steady track gets a single marker (a fixed grid); a track whose tempo
/// moves (live drums, edits, old disco) gets a marker wherever the tempo
/// changes, as DJ software stores a variable grid.
class GridMarker {
  const GridMarker(this.ms, this.bpm, this.beat);

  /// Position of the marker's beat in the file.
  final int ms;
  final double bpm;

  /// Beat of the bar at the marker (1…4), counted from the downbeat.
  final int beat;

  Map<String, Object> toJson() => {'ms': ms, 'bpm': bpm, 'beat': beat};

  static GridMarker fromJson(Map m) => GridMarker(
    (m['ms'] as num).round(),
    (m['bpm'] as num).toDouble(),
    (m['beat'] as num?)?.toInt() ?? 1,
  );
}

class BeatGrid {
  BeatGrid({
    required this.bpm,
    required this.firstBeatMs,
    required this.downbeatMs,
    required this.stable,
    required this.beats,
    required this.markers,
    this.downbeatConfidence = 0,
    this.source = 'analysis',
  });

  /// Main tempo: of the whole track when [stable], else of the longest part.
  final double bpm;

  /// First grid line at or after the start of the file.
  final int firstBeatMs;

  /// First bar line (beat 1) at or after the start of the file.
  final int downbeatMs;
  final bool stable;

  /// Beats found in the audio.
  final int beats;
  final List<GridMarker> markers;
  final double downbeatConfidence;

  /// 'analysis' (this app) or 'serato' (read from the file's Serato tags).
  final String source;

  Map<String, Object> toJson() => {
    'bpm': bpm,
    'first_beat_ms': firstBeatMs,
    'downbeat_ms': downbeatMs,
    'stable': stable,
    'beats': beats,
    'downbeat_confidence': downbeatConfidence,
    'source': source,
    'markers': [for (final m in markers) m.toJson()],
  };

  static BeatGrid? fromJson(Object? j) {
    if (j is! Map) return null;
    try {
      return BeatGrid(
        bpm: (j['bpm'] as num).toDouble(),
        firstBeatMs: (j['first_beat_ms'] as num).round(),
        downbeatMs:
            (j['downbeat_ms'] as num?)?.round() ??
            (j['first_beat_ms'] as num).round(),
        stable: j['stable'] == true,
        beats: (j['beats'] as num?)?.toInt() ?? 0,
        downbeatConfidence: (j['downbeat_confidence'] as num?)?.toDouble() ?? 0,
        source: (j['source'] as String?) ?? 'analysis',
        markers: [
          for (final m in (j['markers'] as List? ?? const []))
            if (m is Map) GridMarker.fromJson(m),
        ],
      );
    } on Object {
      return null;
    }
  }
}

double _round2(double v) => (v * 100).round() / 100;

/// Beat positions (in envelope frames, fractional) from an onset envelope
/// [env] at [fr] frames per second, around [bpm].
List<double> trackBeats(Float64List env, double fr, double bpm) {
  final n = env.length;
  final period = 60 * fr / bpm;
  if (n < 4 * period || period < 2) return const [];
  // Local score: the envelope over its standard deviation, smoothed by a
  // Gaussian a 32nd of a beat wide.
  var mean = 0.0;
  for (final v in env) {
    mean += v;
  }
  mean /= n;
  var sd = 0.0;
  for (final v in env) {
    sd += (v - mean) * (v - mean);
  }
  sd = math.sqrt(sd / n);
  if (sd <= 1e-12) return const [];
  final half = period.round();
  final kernel = Float64List(2 * half + 1);
  for (var i = -half; i <= half; i++) {
    final z = i * 32 / period;
    kernel[i + half] = math.exp(-0.5 * z * z);
  }
  final local = Float64List(n);
  for (var t = 0; t < n; t++) {
    var s = 0.0;
    final a = math.max(0, t - half), b = math.min(n - 1, t + half);
    for (var u = a; u <= b; u++) {
      s += kernel[u - t + half] * env[u];
    }
    local[t] = s / sd;
  }
  // Dynamic programme: each beat's best predecessor between half a beat and
  // two beats back, penalised by the log of its distance from one beat.
  const tightness = 100.0;
  final lo = math.max(1, (period / 2).round()), hi = (2 * period).round();
  final penalty = Float64List(hi + 1);
  for (var d = lo; d <= hi; d++) {
    final l = math.log(d / period);
    penalty[d] = -tightness * l * l;
  }
  final cum = Float64List(n), back = Int32List(n)..fillRange(0, n, -1);
  for (var t = 0; t < n; t++) {
    var best = double.negativeInfinity, arg = -1;
    for (var d = lo; d <= hi && t - d >= 0; d++) {
      final v = cum[t - d] + penalty[d];
      if (v > best) {
        best = v;
        arg = t - d;
      }
    }
    cum[t] = local[t] + (arg >= 0 && best > 0 ? best : 0);
    back[t] = arg >= 0 && best > 0 ? arg : -1;
  }
  // Last beat: the last local maximum of the cumulative score that is at
  // least half the median of all of them.
  final peaks = <int>[];
  for (var t = 1; t < n - 1; t++) {
    if (cum[t] > cum[t - 1] && cum[t] >= cum[t + 1]) peaks.add(t);
  }
  if (peaks.isEmpty) return const [];
  final vals = [for (final p in peaks) cum[p]]..sort();
  final thr = 0.5 * vals[vals.length ~/ 2];
  var last = peaks.last;
  for (var i = peaks.length - 1; i >= 0; i--) {
    if (cum[peaks[i]] >= thr) {
      last = peaks[i];
      break;
    }
  }
  final beats = <int>[];
  for (var t = last; t >= 0; t = back[t]) {
    beats.add(t);
    if (back[t] < 0) break;
  }
  final ordered = beats.reversed.toList();
  // Trim weak beats at both ends (fade-ins, tails).
  var rms = 0.0;
  for (final v in local) {
    rms += v * v;
  }
  rms = math.sqrt(rms / n);
  var s = 0, e = ordered.length;
  while (s < e && local[ordered[s]] < 0.5 * rms) {
    s++;
  }
  while (e > s && local[ordered[e - 1]] < 0.5 * rms) {
    e--;
  }
  // Sub-frame position: the peak of a parabola through the local score.
  return [
    for (final t in ordered.sublist(s, e))
      () {
        if (t <= 0 || t >= n - 1) return t.toDouble();
        final y0 = local[t - 1], y1 = local[t], y2 = local[t + 1];
        final den = y0 - 2 * y1 + y2;
        return den.abs() > 1e-12
            ? t + (0.5 * (y0 - y2) / den).clamp(-0.5, 0.5)
            : t.toDouble();
      }(),
  ];
}

/// Least-squares line through beat times: (seconds per beat, time of beat 0).
(double, double) _fit(List<double> t, int s, int e) {
  final m = e - s;
  var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0;
  for (var i = 0; i < m; i++) {
    final y = t[s + i];
    sx += i;
    sy += y;
    sxx += i * i;
    sxy += i * y;
  }
  final den = m * sxx - sx * sx;
  if (den.abs() < 1e-12) return (0, t[s]);
  final slope = (m * sxy - sx * sy) / den;
  return (slope, (sy - slope * sx) / m);
}

/// The whole-file grid from an onset envelope [env] (frames at [fr] per
/// second, frame f centred at f / fr + [offsetSec]), a low-band envelope
/// [lowEnv] for the downbeat, and the track's tempo [bpm].
BeatGrid? beatGrid(
  Float64List env,
  double fr,
  double bpm, {
  Float64List? lowEnv,
  double offsetSec = 0,
}) {
  final frames = trackBeats(env, fr, bpm);
  if (frames.length < 8) return null;
  final t = [for (final f in frames) f / fr + offsetSec];
  final n = t.length;

  // Tempo along the track: a line through each window of 16 beats.
  const win = 16;
  final local = Float64List(n);
  for (var i = 0; i < n; i++) {
    final s = math.max(0, math.min(i - win ~/ 2, n - win));
    final e = math.min(n, s + win);
    final (spb, _) = _fit(t, s, e);
    local[i] = spb > 0 ? 60 / spb : bpm;
  }
  final (gspb, _) = _fit(t, 0, n);
  final global = gspb > 0 ? 60 / gspb : bpm;
  var maxDev = 0.0;
  for (final v in local) {
    maxDev = math.max(maxDev, (v / global - 1).abs());
  }

  // Parts of steady tempo: a new part starts where the local tempo has left
  // the current part's tempo by more than 1.5% for 8 beats in a row.
  final starts = <int>[0];
  if (maxDev > 0.01) {
    var ref = local[0], run = 0;
    for (var i = 1; i < n; i++) {
      if ((local[i] / ref - 1).abs() > 0.015) {
        run++;
        if (run >= 8) {
          final at = i - run + 1;
          if (at - starts.last >= 8) starts.add(at);
          ref = local[i];
          run = 0;
        }
      } else {
        run = 0;
        ref = 0.9 * ref + 0.1 * local[i];
      }
    }
  }
  final stable = starts.length == 1;
  // Downbeat: the beat of four on which the low band (kick, bass) lands
  // hardest, over the whole track.
  final score = Float64List(4), count = Int32List(4);
  final src = lowEnv ?? env;
  for (var i = 0; i < n; i++) {
    final f = frames[i].round();
    var v = 0.0;
    for (var d = -1; d <= 1; d++) {
      if (f + d >= 0 && f + d < src.length) v = math.max(v, src[f + d]);
    }
    score[i % 4] += v;
    count[i % 4]++;
  }
  var down = 0;
  for (var k = 1; k < 4; k++) {
    if (count[k] > 0 &&
        score[k] / count[k] > score[down] / math.max(1, count[down])) {
      down = k;
    }
  }
  final means = [
    for (var k = 0; k < 4; k++) count[k] > 0 ? score[k] / count[k] : 0.0,
  ]..sort();
  final dconf = means[3] > 0 ? ((means[3] - means[2]) / means[3]) : 0.0;

  // Markers, each placed by its own part's line; the first is moved back to
  // the earliest grid line at or after the start of the file.
  final markers = <GridMarker>[];
  var longest = 0, mainBpm = global;
  int first = 0, downMs = 0;
  for (var k = 0; k < starts.length; k++) {
    final s = starts[k], e = k + 1 < starts.length ? starts[k + 1] : n;
    final (spb, t0) = _fit(t, s, e);
    if (spb <= 0) continue;
    final partBpm = _round2(60 / spb);
    if (e - s > longest) {
      longest = e - s;
      mainBpm = partBpm;
    }
    var pos = t0, idx = s;
    if (k == 0) {
      final back = (pos / spb).floor();
      pos -= back * spb;
      idx -= back;
      first = (pos * 1000).round();
      final toDown = ((down - idx) % 4 + 4) % 4;
      downMs = ((pos + toDown * spb) * 1000).round();
    }
    final beatInBar = ((idx - down) % 4 + 4) % 4 + 1;
    markers.add(GridMarker((pos * 1000).round(), partBpm, beatInBar));
  }
  if (markers.isEmpty) return null;
  return BeatGrid(
    bpm: stable ? _round2(global) : mainBpm,
    firstBeatMs: first,
    downbeatMs: downMs,
    stable: stable,
    beats: n,
    markers: markers,
    downbeatConfidence: (dconf * 100).round() / 100,
  );
}

/// Serato's BPM ranges (Setup → Analysis), plus 'auto' for this app's own
/// rule. A range folds half- and double-time readings into it.
const bpmRanges = {
  'auto': null,
  '58-115': (58.0, 115.0),
  '68-135': (68.0, 135.0),
  '78-155': (78.0, 155.0),
  '88-175': (88.0, 175.0),
};

double foldBpm(double bpm, String? range) {
  final r = bpmRanges[range];
  if (r == null || bpm <= 0) return bpm;
  final (lo, hi) = r;
  var v = bpm;
  while (v < lo) {
    v *= 2;
  }
  while (v > hi) {
    v /= 2;
  }
  return v < lo ? bpm : v;
}
