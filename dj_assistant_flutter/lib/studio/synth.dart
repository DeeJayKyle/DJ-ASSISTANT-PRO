import 'dart:math' as math;
import 'dart:typed_data';

/// A small subtractive synthesiser rendered sample by sample (1.x
/// `sound/synth.ts`): up to three oscillators with unison, a resonant
/// state-variable filter with its own envelope, an amp envelope, drive, chorus
/// and a short reverb. Deterministic: the same patch makes the same sound.
class Env {
  Env(this.a, this.d, this.s, this.r);
  double a, d, s, r;
  Env clone() => Env(a, d, s, r);
  Map<String, Object?> toJson() => {'a': a, 'd': d, 's': s, 'r': r};
}

class Osc {
  Osc(this.wave, this.level, [this.octave = 0, this.detune = 0]);
  String wave; // sine | triangle | saw | square | noise
  double level, octave, detune;
  Osc clone() => Osc(wave, level, octave, detune);
  Map<String, Object?> toJson() => {
    'wave': wave,
    'level': level,
    'octave': octave,
    'detune': detune,
  };
}

class Filter {
  Filter(
    this.type,
    this.cutoff,
    this.resonance,
    this.envAmount,
    this.env,
    this.keyTrack,
  );
  String type; // lp | bp | hp
  double cutoff, resonance, envAmount, keyTrack;
  Env env;
  Filter clone() =>
      Filter(type, cutoff, resonance, envAmount, env.clone(), keyTrack);
  Map<String, Object?> toJson() => {
    'type': type,
    'cutoff': cutoff,
    'resonance': resonance,
    'envAmount': envAmount,
    'env': env.toJson(),
    'keyTrack': keyTrack,
  };
}

class Patch {
  Patch({
    required this.name,
    required this.oscs,
    this.unison = 1,
    this.spread = 0,
    required this.filter,
    required this.amp,
    this.drive = 0,
    this.chorus = 0,
    this.reverbMix = 0,
    this.reverbSize = 0.4,
    this.glideBend,
    this.gain = 0.8,
  });
  String name;
  List<Osc> oscs;
  int unison;
  double spread, drive, chorus, reverbMix, reverbSize, gain;
  Filter filter;
  Env amp;
  double? glideBend;

  Patch clone() => Patch(
    name: name,
    oscs: [for (final o in oscs) o.clone()],
    unison: unison,
    spread: spread,
    filter: filter.clone(),
    amp: amp.clone(),
    drive: drive,
    chorus: chorus,
    reverbMix: reverbMix,
    reverbSize: reverbSize,
    glideBend: glideBend,
    gain: gain,
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'oscs': [for (final o in oscs) o.toJson()],
    'unison': unison,
    'spread': spread,
    'filter': filter.toJson(),
    'amp': amp.toJson(),
    'drive': drive,
    'chorus': chorus,
    'reverb': {'mix': reverbMix, 'size': reverbSize},
    'gain': gain,
    'glideBend': ?glideBend,
  };
}

/// 32-bit xorshift, as 1.x computes it in JavaScript.
double Function() rng(int seed) {
  var s = seed & 0xffffffff;
  if (s == 0) s = 1;
  return () {
    s = (s ^ (s << 13)) & 0xffffffff;
    var a = s >= 0x80000000 ? s - 0x100000000 : s;
    a ^= a >> 17;
    s = (a ^ (a << 5)) & 0xffffffff;
    return s / 4294967296;
  };
}

double _envAt(Env e, double t, double held) {
  double level(double tt) => tt < e.a
      ? tt / math.max(1e-4, e.a)
      : (tt < e.a + e.d
            ? 1 - (1 - e.s) * ((tt - e.a) / math.max(1e-4, e.d))
            : e.s);
  if (t < held) return level(t);
  final atRelease = level(held);
  final r = (t - held) / math.max(1e-3, e.r);
  return r >= 1 ? 0 : atRelease * (1 - r) * (1 - r);
}

double _osc(String wave, double phase, double Function() noise) {
  final p = phase - phase.floorToDouble();
  return switch (wave) {
    'sine' => math.sin(2 * math.pi * p),
    'triangle' => 1 - 4 * (p - 0.5).abs(),
    'saw' => 2 * p - 1,
    'square' => p < 0.5 ? 1 : -1,
    _ => noise() * 2 - 1,
  };
}

double _tanh(double x) {
  if (x > 20) return 1;
  if (x < -20) return -1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

class _Voice {
  _Voice(this.inc, this.phase, this.pan, this.level, this.wave);
  final double inc, pan, level;
  double phase;
  final String wave;
}

/// Renders one note ([midi] pitch held for [held] seconds) to stereo.
List<Float32List> renderNote(
  Patch patch,
  int midi,
  double held, {
  int sampleRate = 44100,
  double velocity = 1,
}) {
  final tail =
      patch.amp.r + patch.reverbSize * 1.5 * (patch.reverbMix > 0 ? 1 : 0);
  final n = ((held + tail + 0.02) * sampleRate).ceil();
  final l = Float32List(n), r = Float32List(n);
  final noise = rng(midi * 7919 + 13);
  final freq = 440 * math.pow(2, (midi - 69) / 12);
  final voices = <_Voice>[];
  for (final o in patch.oscs) {
    final u = math.max(1, patch.unison);
    for (var v = 0; v < u; v++) {
      final cents = o.detune + (u > 1 ? (v / (u - 1) - 0.5) * patch.spread : 0);
      voices.add(
        _Voice(
          (freq * math.pow(2, o.octave) * math.pow(2, cents / 1200)) /
              sampleRate,
          noise(),
          u > 1 ? v / (u - 1) - 0.5 : 0,
          o.level / math.sqrt(u),
          o.wave,
        ),
      );
    }
  }
  var lowL = 0.0, bandL = 0.0, lowR = 0.0, bandR = 0.0;
  final f = patch.filter;
  final keyCut = f.cutoff * math.pow(2, ((midi - 60) / 12) * f.keyTrack);
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final bend = patch.glideBend != null && patch.glideBend != 0
        ? math.pow(2, (patch.glideBend! * math.exp(-t * 18)) / 12)
        : 1;
    var sl = 0.0, sr = 0.0;
    for (final v in voices) {
      v.phase += v.inc * bend;
      final s = _osc(v.wave, v.phase, noise) * v.level;
      sl += s * (0.5 - v.pan * 0.8);
      sr += s * (0.5 + v.pan * 0.8);
    }
    final fe = _envAt(f.env, t, held);
    final cutoff = math.min(
      sampleRate * 0.45,
      math.max(30, keyCut * math.pow(2, f.envAmount * fe)),
    );
    final ff = 2 * math.sin((math.pi * cutoff) / sampleRate);
    final q = 1 / math.max(0.5, 0.7 + f.resonance * 6);
    for (var ch = 0; ch < 2; ch++) {
      final x = ch == 0 ? sl : sr;
      var low = ch == 0 ? lowL : lowR, band = ch == 0 ? bandL : bandR;
      low += ff * band;
      final high = x - low - q * band;
      band += ff * high;
      if (!low.isFinite || low.abs() > 50) {
        low = 0;
        band = 0;
      }
      final y = f.type == 'lp' ? low : (f.type == 'bp' ? band : high);
      if (ch == 0) {
        lowL = low;
        bandL = band;
        l[i] = y;
      } else {
        lowR = low;
        bandR = band;
        r[i] = y;
      }
    }
    final a = _envAt(patch.amp, t, held) * velocity * patch.gain;
    l[i] *= a;
    r[i] *= a;
    if (patch.drive > 0) {
      final k = 1 + patch.drive * 8;
      l[i] = _tanh(l[i] * k) / _tanh(k);
      r[i] = _tanh(r[i] * k) / _tanh(k);
    }
  }
  if (patch.chorus > 0) _chorus(l, r, sampleRate, patch.chorus);
  if (patch.reverbMix > 0) {
    reverb(l, r, sampleRate, patch.reverbMix, patch.reverbSize);
  }
  return [l, r];
}

void _chorus(Float32List l, Float32List r, int sr, double amount) {
  final n = l.length, max = (0.03 * sr).ceil();
  final dl = Float32List.fromList(l), dr = Float32List.fromList(r);
  for (var i = max; i < n; i++) {
    final m = (0.012 + 0.004 * math.sin((2 * math.pi * 0.8 * i) / sr)) * sr;
    final j = i - m, k = j.floor(), fr = j - k;
    l[i] += amount * 0.5 * (dl[k] * (1 - fr) + dl[k + 1] * fr);
    final m2 = (0.014 + 0.004 * math.cos((2 * math.pi * 0.67 * i) / sr)) * sr;
    final j2 = i - m2, k2 = j2.floor(), fr2 = j2 - k2;
    r[i] += amount * 0.5 * (dr[k2] * (1 - fr2) + dr[k2 + 1] * fr2);
  }
}

/// A compact Schroeder-style reverb (4 combs + 2 allpasses per side).
void reverb(Float32List l, Float32List r, int sr, double mix, double size) {
  final combs = [
    for (final d in [1116, 1188, 1277, 1356])
      ((d * sr) / 44100 * (0.6 + size * 0.8)).round(),
  ];
  final aps = [
    for (final d in [556, 441]) ((d * sr) / 44100).round(),
  ];
  final fb = 0.7 + size * 0.25;
  for (final (x, off) in [(l, 0), (r, 23)]) {
    final dry = Float32List.fromList(x);
    final wet = Float32List(x.length);
    for (final d0 in combs) {
      final d = d0 + off;
      final buf = Float32List(d);
      var p = 0;
      var lp = 0.0;
      for (var i = 0; i < x.length; i++) {
        final y = buf[p];
        lp = y * 0.8 + lp * 0.2;
        buf[p] = dry[i] * 0.25 + lp * fb;
        wet[i] += y;
        p = (p + 1) % d;
      }
    }
    for (final d0 in aps) {
      final d = d0 + off;
      final buf = Float32List(d);
      var p = 0;
      for (var i = 0; i < x.length; i++) {
        final b = buf[p];
        final y = -wet[i] + b;
        buf[p] = wet[i] + b * 0.5;
        wet[i] = y;
        p = (p + 1) % d;
      }
    }
    for (var i = 0; i < x.length; i++) {
      x[i] = dry[i] * (1 - mix * 0.5) + wet[i] * mix * 0.35;
    }
  }
}

Patch defaultPatch() => Patch(
  name: 'Init',
  oscs: [Osc('saw', 0.6)],
  filter: Filter('lp', 2400, 0.15, 1, Env(0.005, 0.4, 0.3, 0.3), 0.5),
  amp: Env(0.005, 0.3, 0.7, 0.3),
  reverbMix: 0.15,
  reverbSize: 0.4,
);
