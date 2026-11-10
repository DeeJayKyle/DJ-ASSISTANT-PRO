import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';

/// Four-stem separation on this computer (1.x `src/studio/audio/stems.ts`):
/// vocals, drums, bass and melodies by harmonic/percussive median filtering,
/// a centre-panning measure and frequency bands. The soft masks add up to one,
/// so the stems add back up to the original mix exactly.
const stemNames = ['vocals', 'drums', 'bass', 'melodies'];

typedef Stems = Map<String, List<Float32List>>;

const _n = 4096, _hop = 1024, _med = 17, _half = _med >> 1, _pad = _n;

double _smooth(double x, double a, double b) {
  if (x <= a) return 0;
  if (x >= b) return 1;
  final t = (x - a) / (b - a);
  return t * t * (3 - 2 * t);
}

final Float64List _win = () {
  final w = Float64List(_n);
  for (var i = 0; i < _n; i++) {
    w[i] = 0.5 - 0.5 * math.cos((2 * math.pi * i) / _n); // periodic Hann
  }
  return w;
}();

/// _win[i] / _n and _win[i]², worked out once (the same values the loops
/// used to compute per sample).
final Float64List _winOverN = Float64List.fromList([
  for (var i = 0; i < _n; i++) _win[i] / _n,
]);
final Float64List _win2 = Float64List.fromList([
  for (var i = 0; i < _n; i++) _win[i] * _win[i],
]);

int frameCount(int len) => ((len + _n) / _hop).ceil() + 1;

class PartPlan {
  PartPlan(this.f0, this.f1, this.inStart, this.inEnd);
  final int f0, f1, inStart, inEnd;
}

List<PartPlan> planParts(int len, int parts) {
  final frames = frameCount(len);
  final per = (frames / math.max(1, parts)).ceil();
  return [
    for (var f0 = 0; f0 < frames; f0 += per)
      PartPlan(
        f0,
        math.min(frames, f0 + per),
        math.max(0, (f0 - _half) * _hop - _pad),
        math.min(len, (math.min(frames, f0 + per) + _half) * _hop - _pad + _n),
      ),
  ];
}

class Part {
  Part(this.start, this.stems, this.norm);
  final int start;
  final Stems stems;
  final Float64List norm;
}

class _Frame {
  final lr = Float64List(_n ~/ 2 + 1),
      li = Float64List(_n ~/ 2 + 1),
      rr = Float64List(_n ~/ 2 + 1),
      ri = Float64List(_n ~/ 2 + 1),
      mag = Float64List(_n ~/ 2 + 1);
  int start = 0;
}

void _sortedInsert(Float64List arr, int off, int n, double v) {
  var i = off + n - 1;
  while (i >= off && arr[i] > v) {
    arr[i + 1] = arr[i];
    i--;
  }
  arr[i + 1] = v;
}

void _sortedRemove(Float64List arr, int off, int n, double v) {
  var i = off;
  final end = off + n;
  while (i < end && arr[i] != v) {
    i++;
  }
  for (; i < end - 1; i++) {
    arr[i] = arr[i + 1];
  }
}

/// Separates frames [f0, f1) of a signal of [len] samples; [channels] hold
/// samples from [inStart].
Part separatePart(
  List<Float32List> channels,
  int inStart,
  int len,
  int sampleRate,
  int f0,
  int f1, {
  void Function(double)? onProgress,
}) {
  final l = channels[0], r = channels.length > 1 ? channels[1] : channels[0];
  final frames = frameCount(len);
  const bins = _n ~/ 2 + 1;
  final spanStart = math.max(0, f0 * _hop - _pad);
  final spanEnd = math.min(len, (f1 - 1) * _hop - _pad + _n);
  final span = math.max(0, spanEnd - spanStart);
  List<Float32List> mk() => [Float32List(span), Float32List(span)];
  final out = <String, List<Float32List>>{for (final s in stemNames) s: mk()};
  final norm = Float64List(span);
  final vocalBand = Float64List(bins), bassBand = Float64List(bins);
  for (var k = 0; k < bins; k++) {
    final f = (k * sampleRate) / _n;
    vocalBand[k] = _smooth(f, 110, 220) * (1 - _smooth(f, 6000, 9500));
    bassBand[k] = 1 - _smooth(f, 140, 260);
  }
  final pool = List.generate(_med, (_) => _Frame());
  var ringStart = 0, ringLen = 0;
  final zr = Float64List(_n), zi = Float64List(_n);
  void analyse(int start, _Frame f) {
    // samples inside both the signal and the channels held: [a, b)
    final a = math.max(math.max(0, -start), inStart - start);
    final b = math.min(math.min(_n, len - start), l.length + inStart - start);
    if (a > 0) {
      zr.fillRange(0, math.min(a, _n), 0);
      zi.fillRange(0, math.min(a, _n), 0);
    }
    for (var i = a; i < b; i++) {
      final q = start + i - inStart;
      zr[i] = l[q] * _win[i];
      zi[i] = r[q] * _win[i];
    }
    final from = math.max(a, b);
    if (from < _n) {
      zr.fillRange(math.max(0, from), _n, 0);
      zi.fillRange(math.max(0, from), _n, 0);
    }
    fft(zr, zi);
    for (var k = 0; k < bins; k++) {
      final m = k == 0 ? 0 : _n - k;
      final ar = zr[k], ai = zi[k], cr = zr[m], ci = zi[m];
      final lr = (ar + cr) / 2,
          li = (ai - ci) / 2,
          rr = (ai + ci) / 2,
          ri = -(ar - cr) / 2;
      f.lr[k] = lr;
      f.li[k] = li;
      f.rr[k] = rr;
      f.ri[k] = ri;
      f.mag[k] =
          (math.sqrt(lr * lr + li * li) + math.sqrt(rr * rr + ri * ri)) / 2;
    }
    f.start = start;
  }

  final tWin = Float64List(bins * _med + 1);
  var tCount = 0;
  final fSorted = Float64List(_med + 1);
  final sre = Float64List(_n), sim = Float64List(_n);
  final masks = List.generate(4, (_) => Float64List(bins));
  void synth(_Frame f) {
    for (var s = 0; s < 3; s++) {
      final m = masks[s];
      sre.fillRange(0, _n, 0);
      sim.fillRange(0, _n, 0);
      for (var k = 0; k < bins; k++) {
        final g = m[k];
        final lr = f.lr[k] * g,
            li = f.li[k] * g,
            rr = f.rr[k] * g,
            ri = f.ri[k] * g;
        sre[k] = lr - ri;
        sim[k] = -(li + rr);
        if (k > 0 && k < _n ~/ 2) {
          sre[_n - k] = lr + ri;
          sim[_n - k] = li - rr;
        }
      }
      fft(sre, sim);
      final dl = out[stemNames[s]]![0], dr = out[stemNames[s]]![1];
      final off = f.start - spanStart;
      final i0 = math.max(0, -off), i1 = math.min(_n, span - off);
      for (var i = i0; i < i1; i++) {
        final j = off + i;
        final w = _winOverN[i];
        dl[j] += sre[i] * w;
        dr[j] -= sim[i] * w;
      }
    }
    final ml = out['melodies']![0], mr = out['melodies']![1];
    final off = f.start - spanStart;
    final i0 = math.max(0, -off), i1 = math.min(_n, span - off);
    // samples also inside the channels held and the signal
    final q0 = math.max(i0, inStart - f.start),
        q1 = math.min(
          i1,
          math.min(l.length + inStart - f.start, len - f.start),
        );
    for (var i = i0; i < i1; i++) {
      norm[off + i] += _win2[i];
    }
    for (var i = q0; i < q1; i++) {
      final w2 = _win2[i];
      final q = f.start + i - inStart;
      ml[off + i] += l[q] * w2;
      mr[off + i] += r[q] * w2;
    }
  }

  final first = math.max(0, f0 - _half), last = math.min(frames, f1 + _half);
  for (var t = first; t < last + _half; t++) {
    if (t < last) {
      _Frame slot;
      if (ringLen < _med) {
        slot = pool[(ringStart + ringLen) % _med];
        ringLen++;
      } else {
        slot = pool[ringStart];
        for (var k = 0; k < bins; k++) {
          _sortedRemove(tWin, k * _med, _med, slot.mag[k]);
        }
        tCount = _med - 1;
        ringStart = (ringStart + 1) % _med;
      }
      analyse(t * _hop - _pad, slot);
      for (var k = 0; k < bins; k++) {
        _sortedInsert(tWin, k * _med, tCount, slot.mag[k]);
      }
      tCount++;
    }
    final centre = t - _half;
    if (centre < f0 || centre >= f1) continue;
    final newest = math.min(t, last - 1);
    final back = newest - centre;
    if (back >= ringLen) continue;
    final f = pool[(ringStart + ringLen - 1 - back) % _med];
    final full = tCount == _med;
    final mag = f.mag;
    var fn = 0;
    for (var d = -_half; d <= _half; d++) {
      _sortedInsert(fSorted, 0, fn++, mag[math.min(bins - 1, math.max(0, d))]);
    }
    for (var k = 0; k < bins; k++) {
      if (k > 0) {
        _sortedRemove(fSorted, 0, _med, mag[math.max(0, k - 1 - _half)]);
        _sortedInsert(fSorted, 0, _med - 1, mag[math.min(bins - 1, k + _half)]);
      }
      final h0 = full ? tWin[k * _med + _half] : mag[k];
      final p0 = fSorted[_half];
      final h = (h0 * h0) / (h0 * h0 + p0 * p0 + 1e-12);
      final p = 1 - h;
      final lr = f.lr[k], li = f.li[k], rr = f.rr[k], ri = f.ri[k];
      final e = lr * lr + li * li + rr * rr + ri * ri;
      final c = e > 1e-24
          ? math.max(0, (2 * (lr * rr + li * ri)) / (e + 1e-12))
          : 0.0;
      final centred = c * c * vocalBand[k];
      final v = h * centred,
          b = h * bassBand[k] * (1 - centred),
          dd = p * (1 - 0.5 * centred),
          m = h * (1 - centred) * (1 - bassBand[k]);
      final sum = v + b + dd + m;
      if (sum > 1e-9) {
        masks[0][k] = v / sum;
        masks[1][k] = dd / sum;
        masks[2][k] = b / sum;
        masks[3][k] = m / sum;
      } else {
        masks[0][k] = 0;
        masks[1][k] = 0;
        masks[2][k] = 0;
        masks[3][k] = 1;
      }
    }
    synth(f);
    if (onProgress != null && centre % 64 == 0) {
      onProgress(math.min(1, (centre - f0) / math.max(1, f1 - f0)));
    }
  }
  for (var c = 0; c < 2; c++) {
    final m = out['melodies']![c],
        v = out['vocals']![c],
        d = out['drums']![c],
        b = out['bass']![c];
    for (var i = 0; i < span; i++) {
      m[i] -= v[i] + d[i] + b[i];
    }
  }
  onProgress?.call(1);
  return Part(spanStart, out, norm);
}

/// Adds parts together and applies the overlap-add normalisation.
/// Adds parts into the four full-length stems as they finish, so a part can
/// be dropped as soon as it is merged (long songs are split in many parts).
class StemMerger {
  StemMerger(this.len)
    : out = {
        for (final s in stemNames) s: [Float32List(len), Float32List(len)],
      },
      norm = Float32List(len);
  final int len;
  final Stems out;
  final Float32List norm;

  void add(Part p) {
    for (var i = 0; i < p.norm.length; i++) {
      norm[p.start + i] += p.norm[i];
    }
    for (final st in stemNames) {
      for (var c = 0; c < 2; c++) {
        final d = out[st]![c], s = p.stems[st]![c];
        for (var i = 0; i < s.length; i++) {
          d[p.start + i] += s[i];
        }
      }
    }
  }

  Stems finish([int channels = 2]) {
    for (final st in stemNames) {
      for (final ch in out[st]!) {
        for (var i = 0; i < len; i++) {
          ch[i] = norm[i] > 1e-6 ? ch[i] / norm[i] : 0;
        }
      }
    }
    if (channels == 1) {
      for (final st in stemNames) {
        out[st] = [out[st]![0]];
      }
    }
    return out;
  }
}

Stems mergeParts(List<Part> parts, int len, [int channels = 2]) {
  final m = StemMerger(len);
  for (final p in parts) {
    m.add(p);
  }
  return m.finish(channels);
}

Stems separate(
  List<Float32List> channels,
  int sampleRate, {
  void Function(double)? onProgress,
}) {
  final len = channels[0].length;
  final part = separatePart(
    channels,
    0,
    len,
    sampleRate,
    0,
    frameCount(len),
    onProgress: onProgress,
  );
  return mergeParts([part], len, channels.length);
}

/// Everything but the vocals.
List<Float32List> instrumental(Stems stems) => [
  for (var c = 0; c < stems['drums']!.length; c++)
    () {
      final o = Float32List(stems['drums']![c].length);
      for (final s in ['drums', 'bass', 'melodies']) {
        final x = stems[s]![c];
        for (var i = 0; i < o.length; i++) {
          o[i] += x[i];
        }
      }
      return o;
    }(),
];

// ---- chords

const noteNames = [
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

class ChordSegment {
  ChordSegment(this.start, this.end, this.name, this.root, this.quality);
  double start, end;
  final String name, quality; // maj | min | none
  final int root;
}

final _templates = [
  for (var r = 0; r < 12; r++)
    for (final q in ['maj', 'min'])
      (
        r,
        q,
        [
          for (var i = 0; i < 12; i++)
            i == r
                ? 1.0
                : (i == (r + (q == 'maj' ? 4 : 3)) % 12 || i == (r + 7) % 12
                      ? 0.8
                      : 0.0),
        ],
      ),
];

String chordName(int root, String quality) => quality == 'none'
    ? 'N.C.'
    : '${noteNames[root]}${quality == 'min' ? 'm' : ''}';

double _hypot(List<double> v) => math.sqrt(v.fold(0.0, (a, b) => a + b * b));

/// A chroma vector every ~0.19 s matched against triads, smoothed with a
/// Viterbi pass, then merged into segments.
List<ChordSegment> detectChords(Float32List mono, int sampleRate) {
  final factor = math.max(1, (sampleRate / 11025).round());
  final x = downsample(mono, factor);
  final rate = sampleRate / factor;
  const size = 4096, hop = 2048;
  final mags = Float64List(size ~/ 2);
  final obs = <List<double>>[], energy = <double>[];
  for (var s = 0; s + size <= x.length; s += hop) {
    magnitudes(x, s, size, mags);
    final c = List<double>.filled(12, 0);
    var e = 0.0;
    for (var k = 2; k < size ~/ 2; k++) {
      final f = (k * rate) / size;
      if (f < 60 || f > 2100) continue;
      final midi = 69 + 12 * (math.log(f / 440) / math.ln2);
      final near = midi.round();
      final w = math.max(0, 1 - (midi - near).abs() * 2.5);
      if (w == 0) continue;
      final p = mags[k] * mags[k] * w;
      c[((near % 12) + 12) % 12] += f < 250 ? p * 1.6 : p;
      e += mags[k] * mags[k];
    }
    obs.add(c);
    energy.add(e);
  }
  if (obs.isEmpty) return [];
  final maxE = math.max(energy.reduce(math.max), 1e-12);
  final nStates = _templates.length + 1;
  final score = [
    for (var t = 0; t < obs.length; t++)
      () {
        final c = obs[t];
        final n = _hypot(c) == 0 ? 1.0 : _hypot(c);
        return [
          for (final tp in _templates)
            () {
              var d = 0.0;
              for (var i = 0; i < 12; i++) {
                d += c[i] * tp.$3[i];
              }
              return d / n / _hypot(tp.$3);
            }(),
          energy[t] / maxE < 0.002 ? 1.0 : 0.2,
        ];
      }(),
  ];
  const stay = 0.35;
  var prev = List.of(score[0]);
  final back = <Int16List>[];
  for (var t = 1; t < score.length; t++) {
    var bestPrev = 0;
    for (var j = 1; j < nStates; j++) {
      if (prev[j] > prev[bestPrev]) bestPrev = j;
    }
    final cur = List<double>.filled(nStates, 0);
    final bk = Int16List(nStates);
    for (var j = 0; j < nStates; j++) {
      final keep = prev[j] + stay;
      if (keep >= prev[bestPrev]) {
        cur[j] = keep + score[t][j];
        bk[j] = j;
      } else {
        cur[j] = prev[bestPrev] + score[t][j];
        bk[j] = bestPrev;
      }
    }
    back.add(bk);
    prev = cur;
  }
  var state = 0;
  for (var j = 1; j < nStates; j++) {
    if (prev[j] > prev[state]) state = j;
  }
  final path = List<int>.filled(score.length, 0);
  path[score.length - 1] = state;
  for (var t = score.length - 1; t > 0; t--) {
    state = back[t - 1][state];
    path[t - 1] = state;
  }
  double sec(int t) => (t * hop + size / 2) / rate;
  final segs = <ChordSegment>[];
  for (var t = 0; t < path.length; t++) {
    final st = path[t];
    final root = st < _templates.length ? _templates[st].$1 : 0;
    final quality = st < _templates.length ? _templates[st].$2 : 'none';
    final lastSeg = segs.isEmpty ? null : segs.last;
    if (lastSeg != null && lastSeg.root == root && lastSeg.quality == quality) {
      lastSeg.end = sec(t + 1);
    } else {
      segs.add(
        ChordSegment(
          t == 0 ? 0 : sec(t),
          sec(t + 1),
          chordName(root, quality),
          root,
          quality,
        ),
      );
    }
  }
  final kept = [
    for (var i = 0; i < segs.length; i++)
      if (segs[i].end - segs[i].start >= 0.4 || i == 0 || i == segs.length - 1)
        segs[i],
  ];
  for (var i = 1; i < kept.length; i++) {
    kept[i].start = kept[i - 1].end;
  }
  return kept;
}

ChordSegment? chordAt(List<ChordSegment> segs, double t) =>
    segs.where((s) => t >= s.start && t < s.end).firstOrNull;
