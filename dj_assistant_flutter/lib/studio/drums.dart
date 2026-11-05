import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';
import 'midi.dart';
import 'synth.dart';

/// 16-pad drum kits made by synthesis (1.x `sound/drums.ts`), patterns and
/// the sequencer (`sequence.ts`), sounds from words (`prompt.ts`) and sample
/// exports (`export.ts`).
class Pad {
  Pad({
    required this.name,
    required this.type,
    this.pitch = 200,
    this.decay = 0.2,
    this.tone = 0.5,
    this.noise = 0.5,
    this.drive = 0,
    this.volume = 0.9,
    required this.env,
    this.room = 0,
    required this.key,
    required this.note,
  });
  String name, type, key;
  double pitch, decay, tone, noise, drive, volume, room;
  Env env;
  int note;
  Map<String, Object?> toJson() => {
    'name': name,
    'type': type,
    'pitch': pitch,
    'decay': decay,
    'tone': tone,
    'noise': noise,
    'drive': drive,
    'volume': volume,
    'env': env.toJson(),
    'room': room,
    'key': key,
    'note': note,
  };
}

class Kit {
  Kit(this.name, this.prompt, this.seed, this.pads);
  String name, prompt;
  int seed;
  List<Pad> pads;
  Map<String, Object?> toJson() => {
    'name': name,
    'prompt': prompt,
    'seed': seed,
    'pads': [for (final p in pads) p.toJson()],
  };
}

const padLayout = [
  ('Kick', 'kick', 'z'),
  ('Kick 2', 'kick', 'x'),
  ('Snare', 'snare', 'c'),
  ('Clap', 'clap', 'v'),
  ('Closed Hat', 'closedHat', 'a'),
  ('Open Hat', 'openHat', 's'),
  ('Rim', 'rim', 'd'),
  ('Shaker', 'shaker', 'f'),
  ('Tom Low', 'tom', 'q'),
  ('Tom Mid', 'tom', 'w'),
  ('Tom High', 'tom', 'e'),
  ('Perc', 'perc', 'r'),
  ('Crash', 'crash', '1'),
  ('Ride', 'ride', '2'),
  ('Cowbell', 'cowbell', '3'),
  ('FX', 'fx', '4'),
];

double _tanh(double x) {
  if (x > 20) return 1;
  if (x < -20) return -1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

double _frac(double x) => x - x.floorToDouble();

/// Renders one hit to stereo.
List<Float32List> renderPad(
  Pad p, {
  int sampleRate = 44100,
  double velocity = 1,
}) {
  final dur = math.min(
    4.0,
    p.env.a + p.decay * 3 + p.env.r + (p.room > 0 ? 0.8 : 0),
  );
  final n = (dur * sampleRate).ceil();
  final x = Float32List(n);
  final rand = rng((p.pitch * 1000).round() + p.type.length * 101);
  double noise() => rand() * 2 - 1;
  var ph = 0.0, hp = 0.0, lpN = 0.0, bp1 = 0.0, bp2 = 0.0;
  const metal = [1, 1.342, 1.2312, 1.6532, 1.9523, 2.1523];
  final mph = [for (final _ in metal) rand()];
  for (var i = 0; i < n; i++) {
    final t = i / sampleRate;
    final amp = t < p.env.a
        ? t / math.max(1e-4, p.env.a)
        : math.exp(-(t - p.env.a) / math.max(0.005, p.decay));
    var s = 0.0;
    switch (p.type) {
      case 'kick':
        final f = p.pitch * (1 + 3 * math.exp(-t * (30 + p.tone * 40)));
        ph += f / sampleRate;
        s =
            math.sin(2 * math.pi * ph) +
            (t < 0.004 ? noise() * p.tone * 0.6 : 0);
      case 'tom' || 'perc':
        final f = p.pitch * (1 + 0.6 * math.exp(-t * 25));
        ph += f / sampleRate;
        s =
            math.sin(2 * math.pi * ph) * (1 - p.noise) +
            noise() * p.noise * math.exp(-t * 40);
      case 'snare' || 'rim':
        ph += (p.pitch * (1 + 0.4 * math.exp(-t * 60))) / sampleRate;
        final nz = noise();
        hp = nz - lpN;
        lpN += (nz - lpN) * (0.2 + 0.6 * (1 - p.tone));
        s =
            math.sin(2 * math.pi * ph) * (1 - p.noise) +
            hp * p.noise * (p.type == 'rim' ? 0.4 : 1);
      case 'clap':
        var e = 0.0;
        for (final b in const [0, 0.011, 0.022, 0.034]) {
          if (t >= b) e = math.max(e, math.exp(-(t - b) * 180));
        }
        final nz = noise();
        bp1 += (nz - bp1) * 0.35;
        bp2 += (bp1 - bp2) * 0.35;
        s =
            (bp1 - bp2) *
            3 *
            math.max(
              e,
              t > 0.034 ? math.exp(-(t - 0.034) / math.max(0.01, p.decay)) : 0,
            );
      case 'closedHat' || 'openHat' || 'shaker' || 'crash' || 'ride':
        var m = 0.0;
        for (var k = 0; k < metal.length; k++) {
          mph[k] += (p.pitch * metal[k]) / sampleRate;
          m += _frac(mph[k]) < 0.5 ? 1 : -1;
        }
        final nz = noise();
        final raw = m / metal.length * (1 - p.noise) + nz * p.noise;
        hp = raw - lpN;
        lpN += (raw - lpN) * (0.05 + 0.4 * (1 - p.tone));
        s = hp * (p.type == 'shaker' ? math.min(1, t / 0.01) : 1);
      case 'cowbell':
        ph += p.pitch / sampleRate;
        s =
            ((_frac(ph) < 0.5 ? 1 : -1) + (_frac(ph * 1.48) < 0.5 ? 1 : -1)) *
            0.35;
      default:
        ph += (p.pitch * (1 + 4 * (1 - t / dur))) / sampleRate;
        s = math.sin(2 * math.pi * ph) * 0.4 + noise() * 0.3 * p.noise;
    }
    if (p.drive > 0) s = _tanh(s * (1 + p.drive * 6)) / _tanh(1 + p.drive * 6);
    final rel = t > dur - p.env.r
        ? math.max(0, (dur - t) / math.max(1e-3, p.env.r))
        : 1;
    x[i] = s * amp * rel * p.volume * velocity * 0.9;
  }
  final l = x, r = Float32List.fromList(x);
  if (p.room > 0) reverb(l, r, sampleRate, p.room, 0.3);
  return [l, r];
}

// ---- patterns

const steps = 16;

class Pattern {
  Pattern(this.bpm, this.swing, this.grid);
  double bpm, swing;
  List<List<bool>> grid;
}

Pattern defaultPattern(Kit kit, [double bpm = 124]) {
  final g = [for (final _ in kit.pads) List.filled(steps, false)];
  int idx(String type) => kit.pads.indexWhere((p) => p.type == type);
  final kick = idx('kick'),
      snare = idx('snare'),
      clap = idx('clap'),
      ch = idx('closedHat'),
      oh = idx('openHat');
  for (var s = 0; s < steps; s++) {
    if (kick >= 0 && s % 4 == 0) g[kick][s] = true;
    if (clap >= 0 && (s == 4 || s == 12)) g[clap][s] = true;
    if (snare >= 0 && s == 12) g[snare][s] = true;
    if (oh >= 0 && s % 4 == 2) g[oh][s] = true;
    if (ch >= 0 && s % 2 == 1) g[ch][s] = true;
  }
  return Pattern(bpm, 0, g);
}

List<double> stepTimes(Pattern p) {
  final step = 60 / p.bpm / 4;
  return [
    for (var s = 0; s < steps; s++)
      s * step + (s % 2 == 1 ? p.swing * step * 0.5 : 0),
  ];
}

/// [bars] bars of the pattern with the kit (stereo, exact loop length).
List<Float32List> renderPattern(
  Kit kit,
  Pattern p, {
  int bars = 2,
  int sampleRate = 44100,
}) {
  final barSec = (60 / p.bpm) * 4;
  final n = (barSec * bars * sampleRate).round();
  final l = Float32List(n), r = Float32List(n);
  final times = stepTimes(p);
  for (var i = 0; i < kit.pads.length; i++) {
    if (i >= p.grid.length || !p.grid[i].any((x) => x)) continue;
    final h = renderPad(kit.pads[i], sampleRate: sampleRate);
    for (var b = 0; b < bars; b++) {
      for (var s = 0; s < steps; s++) {
        if (!p.grid[i][s]) continue;
        final at = ((b * barSec + times[s]) * sampleRate).round();
        for (var j = 0; j < h[0].length; j++) {
          final k = (at + j) % n;
          l[k] += h[0][j];
          r[k] += h[1][j];
        }
      }
    }
  }
  var pk = 0.0;
  for (var i = 0; i < n; i++) {
    pk = math.max(pk, math.max(l[i].abs(), r[i].abs()));
  }
  if (pk > 0.98) {
    final g = 0.98 / pk;
    for (var i = 0; i < n; i++) {
      l[i] *= g;
      r[i] *= g;
    }
  }
  return [l, r];
}

Uint8List patternMidi(Kit kit, Pattern p, {int bars = 4}) {
  final barSec = (60 / p.bpm) * 4;
  final times = stepTimes(p);
  final notes = <Note>[];
  for (var b = 0; b < bars; b++) {
    for (var i = 0; i < kit.pads.length; i++) {
      for (var s = 0; s < steps; s++) {
        if (i < p.grid.length && p.grid[i][s]) {
          notes.add(
            Note(
              kit.pads[i].note,
              b * barSec + times[s],
              b * barSec + times[s] + 0.1,
              110,
            ),
          );
        }
      }
    }
  }
  return writeMidi([MidiTrack(kit.name, 9, notes)], p.bpm);
}

// ---- sounds from words

bool _has(String text, List<String> words) =>
    words.any((w) => RegExp('\\b$w', caseSensitive: false).hasMatch(text));
String _titleCase(String s) =>
    s.replaceAllMapped(RegExp(r'\b\w'), (m) => m[0]!.toUpperCase());

const synthIdeas = [
  'bright cinematic synth organ',
  'warm analog pad with slow attack',
  'dark thick sub bass',
  'punchy filtered ambient keys',
  'glassy bell pluck',
  'gritty distorted reese bass',
  'airy shimmering choir pad',
  'retro 80s detuned lead',
  'soft lofi electric piano',
  'sharp dry stab chords',
];
const drumIdeas = [
  'deep punchy techno kick-driven groove',
  'crisp trap kit with booming 808',
  'gritty saturated synthwave drums',
  'dusty lofi hip hop kit',
  'glitchy metallic IDM percussion',
  'tight drum and bass breaks',
  'warm disco house kit',
  'roomy live rock kit',
  'minimal clicky tech house',
  'afro house percussion with shakers',
];

String _nameOf(String prompt, String fallback) {
  final w = prompt
      .trim()
      .split(RegExp(r'\s+'))
      .where((x) => x.isNotEmpty)
      .take(5)
      .join(' ');
  return w.isEmpty ? fallback : _titleCase(w);
}

Patch patchFromPrompt(String prompt, [int seed = 1]) {
  final r = rng(seed * 2654435761);
  double j(double x, [double amt = 0.15]) => x * (1 + (r() - 0.5) * 2 * amt);
  final p = defaultPatch();
  final t = prompt.toLowerCase();
  bool has(List<String> w) => _has(t, w);
  p.name = _nameOf(prompt, 'New Sound');
  if (has(['sub', '808', 'bass', 'reese'])) {
    p.oscs = has(['reese', 'gritt', 'distort'])
        ? [Osc('saw', 0.5, -1, -12), Osc('saw', 0.5, -1, 12)]
        : [Osc('sine', 0.8, -1), Osc('triangle', 0.25, -1)];
    p.filter.cutoff = 600;
    p.amp = Env(0.004, 0.4, 0.85, 0.15);
    p.reverbMix = 0;
    if (has(['808'])) {
      p
        ..glideBend = 5
        ..amp = Env(0.002, 1.2, 0.2, 0.4)
        ..drive = 0.25;
    }
  }
  if (has(['pad', 'choir', 'string', 'atmos', 'ambient'])) {
    p
      ..oscs = [Osc('saw', 0.4), Osc('triangle', 0.4, 1, 5)]
      ..unison = 4
      ..spread = 22
      ..amp = Env(0.6, 1, 0.8, 1.4)
      ..reverbMix = 0.45
      ..reverbSize = 0.8
      ..chorus = 0.4;
    p.filter
      ..cutoff = 1800
      ..envAmount = 0.4;
  }
  if (has(['organ'])) {
    p
      ..oscs = [Osc('sine', 0.5), Osc('sine', 0.35, 1), Osc('square', 0.15, -1)]
      ..amp = Env(0.01, 0.1, 0.95, 0.12);
    p.filter
      ..cutoff = 5000
      ..envAmount = 0;
  }
  if (has(['pluck', 'bell', 'glass', 'mallet', 'marimba'])) {
    p
      ..oscs = has(['bell', 'glass'])
          ? [Osc('sine', 0.6), Osc('sine', 0.3, 2, 8)]
          : [Osc('saw', 0.5), Osc('square', 0.25, 1)]
      ..amp = Env(0.002, 0.5, 0, 0.4);
    p.filter
      ..envAmount = 2.5
      ..env = Env(0.001, 0.25, 0, 0.2)
      ..cutoff = 900;
  }
  if (has(['key', 'piano', 'rhodes', 'electric piano', r'ep\b'])) {
    p
      ..oscs = [Osc('triangle', 0.6), Osc('sine', 0.35, 1, 3)]
      ..amp = Env(0.003, 1.2, 0.25, 0.5)
      ..chorus = math.max(p.chorus, 0.25);
    p.filter.cutoff = 2600;
  }
  if (has(['lead', 'synth lead'])) {
    p
      ..oscs = [Osc('saw', 0.5, 0, -7), Osc('square', 0.35, 0, 7)]
      ..amp = Env(0.005, 0.2, 0.8, 0.2);
    p.filter.cutoff = 3200;
  }
  if (has(['stab', 'chord'])) {
    p
      ..amp = Env(0.002, 0.25, 0.1, 0.2)
      ..unison = math.max(p.unison, 3)
      ..spread = math.max(p.spread, 15);
  }
  if (has(['bright', 'sharp', 'crisp', 'shimmer'])) {
    p.filter
      ..cutoff *= 2.4
      ..resonance = math.max(p.filter.resonance, 0.25);
  }
  if (has(['dark', 'deep', 'muffled', 'lofi', 'lo-fi', 'dusty'])) {
    p.filter.cutoff *= 0.45;
  }
  if (has(['warm', 'analog', 'vintage'])) {
    p.drive = math.max(p.drive, 0.15);
    for (var i = 0; i < p.oscs.length; i++) {
      p.oscs[i].detune += i.isOdd ? 6 : -6;
    }
  }
  if (has(['thick', 'fat', 'wide', 'huge', 'super'])) {
    p
      ..unison = math.max(p.unison, 5)
      ..spread = math.max(p.spread, 25);
  }
  if (has(['gritt', 'distort', 'dirty', 'saturat', 'crunch'])) {
    p.drive = math.max(p.drive, 0.55);
  }
  if (has(['filter', 'resonan', 'acid'])) {
    p.filter
      ..resonance = 0.6
      ..envAmount = math.max(p.filter.envAmount, 2);
  }
  if (has(['punch', 'snappy', 'tight'])) {
    p.amp.a = 0.001;
    p.filter.env.d = 0.12;
  }
  if (has(['soft', 'gentle', 'mellow'])) {
    p.amp.a = math.max(p.amp.a, 0.03);
    p.filter.cutoff *= 0.7;
    p.drive = 0;
  }
  if (has(['slow attack', 'swell'])) p.amp.a = math.max(p.amp.a, 0.9);
  if (has(['cinematic', 'epic', 'huge', 'hall'])) {
    p
      ..reverbMix = math.max(p.reverbMix, 0.5)
      ..reverbSize = 0.95;
  }
  if (has(['dry'])) p.reverbMix = 0;
  if (has(['airy', 'breath'])) p.oscs.add(Osc('noise', 0.08));
  if (has(['retro', '80s', 'synthwave'])) {
    p.chorus = math.max(p.chorus, 0.5);
    for (final o in p.oscs) {
      if (o.wave == 'sine') o.wave = 'square';
    }
  }
  p.filter
    ..cutoff = math.min(16000, j(p.filter.cutoff, 0.25))
    ..resonance = math.min(0.9, j(p.filter.resonance + 0.001, 0.3));
  p.amp
    ..d = j(p.amp.d)
    ..r = j(p.amp.r);
  p.spread = j(p.spread, 0.3);
  for (final o in p.oscs) {
    o.detune += (r() - 0.5) * 6;
  }
  return p;
}

Kit kitFromPrompt(String prompt, [int seed = 1]) {
  final r = rng(seed * 40503 + 7);
  double j(double x, [double amt = 0.12]) => x * (1 + (r() - 0.5) * 2 * amt);
  final t = prompt.toLowerCase();
  bool has(List<String> w) => _has(t, w);
  final st = <String, double>{
    'kickPitch': 52,
    'kickDecay': 0.28,
    'kickTone': 0.5,
    'snarePitch': 190,
    'snareNoise': 0.65,
    'snareDecay': 0.16,
    'hatPitch': 420,
    'hatTone': 0.7,
    'hatDecay': 0.05,
    'drive': 0.1,
    'room': 0.08,
    'tomBase': 90,
    'decayScale': 1,
  };
  if (has(['techno', 'industrial', 'warehouse'])) {
    st.addAll({
      'kickPitch': 48,
      'kickDecay': 0.42,
      'kickTone': 0.7,
      'drive': 0.35,
      'hatTone': 0.85,
      'room': 0.12,
    });
  }
  if (has(['trap', '808', 'drill'])) {
    st.addAll({
      'kickPitch': 42,
      'kickDecay': 1.1,
      'kickTone': 0.35,
      'snarePitch': 220,
      'snareNoise': 0.8,
      'snareDecay': 0.12,
      'hatTone': 0.95,
      'hatDecay': 0.035,
      'drive': 0.2,
      'room': 0.05,
    });
  }
  if (has(['lofi', 'lo-fi', 'dusty', 'boom bap', 'hip hop'])) {
    st.addAll({
      'kickPitch': 55,
      'kickDecay': 0.22,
      'kickTone': 0.25,
      'hatTone': 0.4,
      'snareNoise': 0.55,
      'drive': 0.4,
      'room': 0.18,
    });
  }
  if (has(['synthwave', '80s', 'retro'])) {
    st.addAll({'snareDecay': 0.32, 'room': 0.45, 'drive': 0.25});
  }
  if (has(['house', 'disco'])) {
    st.addAll({
      'kickPitch': 54,
      'kickDecay': 0.3,
      'hatTone': 0.75,
      'room': 0.1,
    });
  }
  if (has(['drum and bass', 'dnb', 'jungle', 'break'])) {
    st.addAll({
      'kickPitch': 58,
      'kickDecay': 0.18,
      'snarePitch': 240,
      'snareDecay': 0.14,
      'hatDecay': 0.04,
    });
  }
  if (has(['rock', 'live', 'acoustic', 'roomy'])) {
    st.addAll({
      'kickPitch': 60,
      'kickDecay': 0.25,
      'snarePitch': 180,
      'snareNoise': 0.55,
      'room': 0.4,
      'tomBase': 80,
    });
  }
  if (has(['minimal', 'click', 'tech house'])) {
    st.addAll({
      'kickDecay': 0.22,
      'hatDecay': 0.03,
      'snareNoise': 0.5,
      'room': 0.06,
    });
  }
  if (has(['glitch', 'idm', 'metallic'])) {
    st.addAll({'hatPitch': 780, 'hatTone': 1, 'decayScale': 0.6, 'drive': 0.3});
  }
  if (has(['afro', 'latin', 'percussion', 'shaker'])) {
    st.addAll({'tomBase': 140, 'room': 0.15});
  }
  if (has(['deep', 'boom'])) st['kickPitch'] = st['kickPitch']! * 0.88;
  if (has(['punch', 'tight'])) st['kickDecay'] = st['kickDecay']! * 0.75;
  if (has(['crisp', 'sharp', 'razor'])) {
    st['hatTone'] = 1;
    st['snareNoise'] = math.min(1, st['snareNoise']! + 0.15);
  }
  if (has(['gritt', 'saturat', 'crunch', 'distort'])) {
    st['drive'] = math.max(st['drive']!, 0.5);
  }
  if (has(['soft', 'warm'])) st['drive'] = st['drive']! * 0.5;
  Env env(double decay) => Env(0.0008, decay, 0, 0.02);
  final pads = <Pad>[];
  for (var i = 0; i < padLayout.length; i++) {
    final (name, type, key) = padLayout[i];
    final b = Pad(
      name: name,
      type: type,
      drive: st['drive']!,
      env: env(0.2),
      room: st['room']!,
      key: key,
      note: 36 + i,
    );
    switch (type) {
      case 'kick':
        b
          ..pitch = j(st['kickPitch']! * (name.endsWith('2') ? 1.2 : 1))
          ..decay = j(st['kickDecay']! * (name.endsWith('2') ? 0.6 : 1))
          ..tone = st['kickTone']!
          ..noise = 0
          ..volume = 1
          ..room = st['room']! * 0.3;
      case 'snare':
        b
          ..pitch = j(st['snarePitch']!)
          ..decay = j(st['snareDecay']!)
          ..noise = st['snareNoise']!
          ..tone = 0.6;
      case 'clap':
        b
          ..decay = j(0.14)
          ..noise = 1
          ..tone = 0.6;
      case 'rim':
        b
          ..pitch = j(420)
          ..decay = 0.04
          ..noise = 0.3
          ..tone = 0.8
          ..volume = 0.7;
      case 'closedHat':
        b
          ..pitch = j(st['hatPitch']!)
          ..decay = j(st['hatDecay']! * st['decayScale']!)
          ..tone = st['hatTone']!
          ..noise = 0.45
          ..volume = 0.6;
      case 'openHat':
        b
          ..pitch = j(st['hatPitch']!)
          ..decay = j(0.32 * st['decayScale']!)
          ..tone = st['hatTone']!
          ..noise = 0.45
          ..volume = 0.55;
      case 'shaker':
        b
          ..pitch = 900
          ..decay = j(0.07)
          ..tone = 0.9
          ..noise = 0.95
          ..volume = 0.45;
      case 'crash':
        b
          ..pitch = j(330)
          ..decay = j(1.2)
          ..tone = 0.8
          ..noise = 0.6
          ..volume = 0.5;
      case 'ride':
        b
          ..pitch = j(520)
          ..decay = j(0.9)
          ..tone = 0.65
          ..noise = 0.25
          ..volume = 0.45;
      case 'tom':
        final k = name.contains('Low')
            ? 1
            : (name.contains('Mid') ? 1.33 : 1.75);
        b
          ..pitch = j(st['tomBase']! * k)
          ..decay = j(0.35)
          ..noise = 0.15;
      case 'perc':
        b
          ..pitch = j(st['tomBase']! * 3.2)
          ..decay = j(0.09)
          ..noise = 0.1
          ..volume = 0.7;
      case 'cowbell':
        b
          ..pitch = j(560)
          ..decay = j(0.18)
          ..volume = 0.5;
      default:
        b
          ..pitch = j(300)
          ..decay = j(0.6)
          ..noise = 0.6
          ..volume = 0.5
          ..room = math.max(0.3, st['room']!);
    }
    b.env = env(b.decay);
    pads.add(b);
  }
  return Kit(_nameOf(prompt, 'New Kit'), prompt, seed, pads);
}

const aiSynthSystem =
    'You design synthesiser patches. Reply only with JSON matching this TypeScript type: {name:string; oscs:{wave:"sine"|"triangle"|"saw"|"square"|"noise"; level:number; octave:number; detune:number}[]; unison:number; spread:number; filter:{type:"lp"|"bp"|"hp"; cutoff:number; resonance:number; envAmount:number; env:{a:number;d:number;s:number;r:number}; keyTrack:number}; amp:{a:number;d:number;s:number;r:number}; drive:number; chorus:number; reverb:{mix:number;size:number}; gain:number}. Times in seconds, cutoff in Hz, levels 0..1, resonance 0..0.9.';

/// Validates an AI patch, filling gaps from the rule-based one.
Patch patchFromAi(Object? json, Patch fallback) {
  if (json is! Map) return fallback;
  double n(Object? v, double lo, double hi, double d) =>
      v is num && v.isFinite ? v.toDouble().clamp(lo, hi) : d;
  Env env(Object? e, Env d) {
    final m = e is Map ? e : const {};
    return Env(
      n(m['a'], 0, 4, d.a),
      n(m['d'], 0.001, 6, d.d),
      n(m['s'], 0, 1, d.s),
      n(m['r'], 0.001, 8, d.r),
    );
  }

  const waves = ['sine', 'triangle', 'saw', 'square', 'noise'];
  final oscs = [
    for (final o
        in (json['oscs'] is List ? json['oscs'] as List : const []).take(3))
      if (o is Map && waves.contains(o['wave']))
        Osc(
          '${o['wave']}',
          n(o['level'], 0, 1, 0.5),
          n(o['octave'], -3, 3, 0).roundToDouble(),
          n(o['detune'], -100, 100, 0),
        ),
  ];
  final f = json['filter'] is Map ? json['filter'] as Map : const {};
  final rv = json['reverb'] is Map ? json['reverb'] as Map : const {};
  final nm = json['name'];
  return Patch(
    name: nm is String && nm.trim().isNotEmpty
        ? (nm.trim().length > 60 ? nm.trim().substring(0, 60) : nm.trim())
        : fallback.name,
    oscs: oscs.isNotEmpty ? oscs : fallback.oscs,
    unison: n(json['unison'], 1, 7, fallback.unison.toDouble()).round(),
    spread: n(json['spread'], 0, 60, fallback.spread),
    filter: Filter(
      ['lp', 'bp', 'hp'].contains(f['type'])
          ? '${f['type']}'
          : fallback.filter.type,
      n(f['cutoff'], 40, 18000, fallback.filter.cutoff),
      n(f['resonance'], 0, 0.9, fallback.filter.resonance),
      n(f['envAmount'], -4, 5, fallback.filter.envAmount),
      env(f['env'], fallback.filter.env),
      n(f['keyTrack'], 0, 1, fallback.filter.keyTrack),
    ),
    amp: env(json['amp'], fallback.amp),
    drive: n(json['drive'], 0, 1, fallback.drive),
    chorus: n(json['chorus'], 0, 1, fallback.chorus),
    reverbMix: n(rv['mix'], 0, 1, fallback.reverbMix),
    reverbSize: n(rv['size'], 0, 1, fallback.reverbSize),
    gain: n(json['gain'], 0.1, 1.2, fallback.gain),
    glideBend: fallback.glideBend,
  );
}

// ---- sample exports

String _safe(String s) {
  final t = s
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return t.isEmpty ? 'Sound' : t;
}

const _noteNames = [
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
String _noteName(int m) => '${_noteNames[m % 12]}${m ~/ 12 - 1}';

/// One WAV per sample plus an SFZ file and the patch JSON.
List<(String, Uint8List)> instrumentFiles(
  Patch patch, {
  int sampleRate = 44100,
}) {
  final files = <(String, Uint8List)>[];
  final regions = <String>[];
  final roots = [for (var m = 36; m <= 84; m += 4) m];
  for (var i = 0; i < roots.length; i++) {
    final m = roots[i];
    final name = 'samples/${_safe(patch.name)} ${_noteName(m)}.wav';
    files.add((
      name,
      encodeWav(renderNote(patch, m, 1.6, sampleRate: sampleRate), sampleRate),
    ));
    final lo = i == 0 ? 0 : m - 1, hi = i == roots.length - 1 ? 127 : m + 2;
    regions.add(
      '<region> sample=${name.replaceFirst('samples/', r'samples\')} pitch_keycenter=$m lokey=$lo hikey=$hi',
    );
  }
  files
    ..add((
      '${_safe(patch.name)}.sfz',
      utf8.encode(
        '// ${patch.name}\n<group> ampeg_release=${patch.amp.r.toStringAsFixed(3)}\n${regions.join('\n')}\n',
      ),
    ))
    ..add((
      '${_safe(patch.name)}.patch.json',
      utf8.encode(const JsonEncoder.withIndent('  ').convert(patch.toJson())),
    ));
  return files;
}

List<(String, Uint8List)> kitFiles(Kit kit, {int sampleRate = 44100}) {
  final files = <(String, Uint8List)>[
    for (var i = 0; i < kit.pads.length; i++)
      (
        '${'${i + 1}'.padLeft(2, '0')} ${_safe(kit.pads[i].name)}.wav',
        encodeWav(renderPad(kit.pads[i], sampleRate: sampleRate), sampleRate),
      ),
  ];
  final sfz = [
    for (var i = 0; i < kit.pads.length; i++)
      '<region> sample=${files[i].$1} key=${kit.pads[i].note} loop_mode=one_shot',
  ].join('\n');
  files
    ..add((
      '${_safe(kit.name)}.sfz',
      utf8.encode(
        '// ${kit.name} — notes ${kit.pads.first.note}–${kit.pads.last.note}\n$sfz\n',
      ),
    ))
    ..add((
      '${_safe(kit.name)}.kit.json',
      utf8.encode(const JsonEncoder.withIndent('  ').convert(kit.toJson())),
    ));
  return files;
}
