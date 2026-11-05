import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'dsp.dart';

/// Audio → MIDI (1.x `audio/midi.ts`): YIN pitch tracking for bass and
/// melodies, onset detection for drums, and a Standard MIDI File writer.
class Note {
  Note(this.pitch, this.start, this.end, this.velocity);
  final int pitch, velocity;
  final double start, end;
}

class MidiTrack {
  MidiTrack(this.name, this.channel, this.notes, [this.program]);
  final String name;
  final int channel;
  final List<Note> notes;
  final int? program;
}

class Yin {
  Yin(this.f0, this.conf, this.rms, this.hopSec);
  final List<double> f0, conf, rms;
  final double hopSec;
}

/// YIN fundamental frequency per frame (0 = unvoiced) and confidence.
Yin yin(
  Float32List mono,
  int sampleRate, {
  double minHz = 40,
  double maxHz = 1500,
  double hop = 0.01,
}) {
  final factor = math.max(
    1,
    sampleRate ~/ math.min(16000, math.max(2400, maxHz * 8)),
  );
  final x = downsample(mono, factor);
  final sr = sampleRate / factor;
  final h = math.max(64, (hop * sr).round());
  final maxLag = (sr / minHz).ceil(), minLag = (sr / maxHz).floor();
  final w = maxLag + 1;
  final f0 = <double>[], conf = <double>[], rms = <double>[];
  final d = Float64List(maxLag + 2);
  for (var s = 0; s + w + maxLag < x.length; s += h) {
    var e = 0.0;
    for (var i = 0; i < w; i++) {
      e += x[s + i] * x[s + i];
    }
    rms.add(math.sqrt(e / w));
    for (var tau = 1; tau <= maxLag; tau++) {
      var sum = 0.0;
      for (var i = 0; i < w; i++) {
        final df = x[s + i] - x[s + i + tau];
        sum += df * df;
      }
      d[tau] = sum;
    }
    var run = 0.0;
    var best = -1;
    for (var tau = 1; tau <= maxLag; tau++) {
      run += d[tau];
      d[tau] = run > 0 ? (d[tau] * tau) / run : 1;
    }
    for (var tau = minLag; tau <= maxLag; tau++) {
      if (d[tau] < 0.15) {
        while (tau + 1 <= maxLag && d[tau + 1] < d[tau]) {
          tau++;
        }
        best = tau;
        break;
      }
    }
    if (best < 0) {
      f0.add(0);
      conf.add(0);
      continue;
    }
    final a = best - 1 >= 0 ? d[best - 1] : d[best],
        b = d[best],
        c = best + 1 < d.length ? d[best + 1] : d[best];
    final den = 2 * (a - 2 * b + c);
    final shift = (a - c) / (den == 0 ? 1 : den);
    f0.add(sr / (best + (shift.abs() < 1 ? shift : 0)));
    conf.add(1 - b);
  }
  return Yin(f0, conf, rms, h / sr);
}

/// Monophonic notes from a stem (bass or lead melody).
List<Note> transcribePitched(
  Float32List mono,
  int sampleRate, {
  required double minHz,
  required double maxHz,
}) {
  final y = yin(mono, sampleRate, minHz: minHz, maxHz: maxHz);
  final maxR = math.max(y.rms.fold(0.0, math.max), 1e-9);
  final notes = <Note>[];
  (int, double, int, double)? cur; // pitch, start, frames, peak
  var gap = 0;
  void close(double t) {
    final c = cur;
    if (c != null && c.$3 >= 6) {
      notes.add(
        Note(c.$1, c.$2, t, (40 + 80 * math.min(1, c.$4 / maxR)).round()),
      );
    }
    cur = null;
  }

  for (var i = 0; i < y.f0.length; i++) {
    final t = i * y.hopSec;
    final voiced = y.f0[i] > 0 && y.rms[i] > maxR * 0.05;
    final p = voiced
        ? (69 + 12 * (math.log(y.f0[i] / 440) / math.ln2)).round()
        : -1;
    final c = cur;
    if (c != null && p == c.$1) {
      cur = (c.$1, c.$2, c.$3 + 1, math.max(c.$4, y.rms[i]));
      gap = 0;
      continue;
    }
    if (c != null && p < 0 && gap < 3) {
      gap++;
      continue;
    }
    close(t - gap * y.hopSec);
    gap = 0;
    if (p >= 0) cur = (p, t, 1, y.rms[i]);
  }
  close(y.f0.length * y.hopSec);
  return notes;
}

/// Drum hits from the drums stem: kick (36), snare (38) or hi-hat (42).
List<Note> transcribeDrums(Float32List mono, int sampleRate) {
  const size = 1024, hop = 256;
  final re = Float64List(size), im = Float64List(size);
  const bands = [(30, 150), (150, 2500), (5000, 15000)];
  final env = [<double>[], <double>[], <double>[]];
  final prev = [0.0, 0.0, 0.0];
  for (var s = 0; s + size <= mono.length; s += hop) {
    for (var i = 0; i < size; i++) {
      re[i] = mono[s + i] * (0.5 - 0.5 * math.cos((2 * math.pi * i) / size));
      im[i] = 0;
    }
    fft(re, im);
    for (var j = 0; j < 3; j++) {
      final (a, b) = bands[j];
      var e = 0.0;
      for (
        var k = (a * size / sampleRate).floor();
        k <= math.min(size ~/ 2, (b * size / sampleRate).ceil());
        k++
      ) {
        e += re[k] * re[k] + im[k] * im[k];
      }
      final v = math.log(1 + e * 50);
      env[j].add(math.max(0, v - prev[j]));
      prev[j] = v;
    }
  }
  final hopSec = hop / sampleRate;
  final notes = <Note>[];
  const pitch = [36, 38, 42];
  for (var j = 0; j < 3; j++) {
    final e = env[j];
    if (e.isEmpty) continue;
    final sorted = List.of(e)..sort();
    final thr = math.max(
      sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)],
      sorted.last * 0.25,
    );
    var last = -1000000000;
    final maxE = sorted.last == 0 ? 1.0 : sorted.last;
    for (var i = 1; i < e.length - 1; i++) {
      if (e[i] > thr &&
          e[i] >= e[i - 1] &&
          e[i] >= e[i + 1] &&
          i - last > 0.06 / hopSec) {
        last = i;
        notes.add(
          Note(
            pitch[j],
            i * hopSec,
            i * hopSec + 0.1,
            (50 + 77 * math.min(1, e[i] / maxE)).round(),
          ),
        );
      }
    }
  }
  final idx = List.generate(notes.length, (i) => i)
    ..sort((a, b) {
      final c = notes[a].start.compareTo(notes[b].start);
      return c != 0 ? c : a.compareTo(b);
    });
  return [for (final i in idx) notes[i]];
}

/// Chords as MIDI (root-position triads around middle C).
List<Note> chordNotes(List<(double, double, int, String)> segs) => [
  for (final (start, end, root, quality) in segs)
    if (quality != 'none')
      for (final iv in [0, quality == 'min' ? 3 : 4, 7])
        Note(48 + root + iv, start, end, 80),
];

List<int> _vlq(int n) {
  final bytes = [n & 0x7f];
  var v = n >> 7;
  while (v > 0) {
    bytes.insert(0, (v & 0x7f) | 0x80);
    v >>= 7;
  }
  return bytes;
}

/// A Standard MIDI File (type 1, 480 ticks per beat).
Uint8List writeMidi(List<MidiTrack> tracks, double bpm) {
  const ppq = 480;
  int tick(double sec) => math.max(0, (sec * bpm * ppq / 60).round());
  List<int> chunk(String id, List<int> data) => [
    ...id.codeUnits,
    (data.length >> 24) & 255,
    (data.length >> 16) & 255,
    (data.length >> 8) & 255,
    data.length & 255,
    ...data,
  ];
  final tempo = (60000000 / (bpm == 0 ? 120 : bpm)).round();
  final meta = [
    0,
    0xff,
    0x51,
    3,
    (tempo >> 16) & 255,
    (tempo >> 8) & 255,
    tempo & 255,
    0,
    0xff,
    0x58,
    4,
    4,
    2,
    24,
    8,
    0,
    0xff,
    0x2f,
    0,
  ];
  final out = [
    ...chunk('MThd', [0, 1, 0, tracks.length + 1, ppq >> 8, ppq & 255]),
    ...chunk('MTrk', meta),
  ];
  for (final t in tracks) {
    final ev = <(int, List<int>)>[];
    final name = utf8.encode(t.name);
    ev.add((0, [0xff, 0x03, ..._vlq(name.length), ...name]));
    if (t.program != null) ev.add((0, [0xc0 | t.channel, t.program!]));
    for (final n in t.notes) {
      final p = n.pitch.clamp(0, 127), v = n.velocity.clamp(1, 127);
      ev
        ..add((tick(n.start), [0x90 | t.channel, p, v]))
        ..add((
          math.max(tick(n.start) + 1, tick(n.end)),
          [0x80 | t.channel, p, 0],
        ));
    }
    final order = List.generate(ev.length, (i) => i)
      ..sort((a, b) {
        final c = ev[a].$1 - ev[b].$1;
        if (c != 0) return c;
        final d = (ev[a].$2[0] & 0xf0) - (ev[b].$2[0] & 0xf0);
        return d != 0 ? d : a.compareTo(b);
      });
    final data = <int>[];
    var now = 0;
    for (final i in order) {
      data
        ..addAll(_vlq(ev[i].$1 - now))
        ..addAll(ev[i].$2);
      now = ev[i].$1;
    }
    data.addAll([0, 0xff, 0x2f, 0]);
    out.addAll(chunk('MTrk', data));
  }
  return Uint8List.fromList(out);
}

/// Note events of a MIDI file (for checks and the piano roll).
(int, List<(String, List<(int, int, int)>)>) readMidi(Uint8List bytes) {
  var o = 0;
  int u32() {
    final v =
        (bytes[o] << 24) |
        (bytes[o + 1] << 16) |
        (bytes[o + 2] << 8) |
        bytes[o + 3];
    o += 4;
    return v;
  }

  int u16() {
    final v = (bytes[o] << 8) | bytes[o + 1];
    o += 2;
    return v;
  }

  int vl() {
    var n = 0;
    int b;
    do {
      b = bytes[o++];
      n = (n << 7) | (b & 0x7f);
    } while (b & 0x80 != 0);
    return n;
  }

  o = 4;
  u32();
  u16();
  final ntr = u16(), ppq = u16();
  final tracks = <(String, List<(int, int, int)>)>[];
  for (var t = 0; t < ntr; t++) {
    o += 4;
    final end = u32() + o;
    var now = 0, status = 0;
    var name = '';
    final open = <int, int>{};
    final notes = <(int, int, int)>[];
    while (o < end) {
      now += vl();
      var st = bytes[o];
      if (st & 0x80 != 0) {
        o++;
      } else {
        st = status;
      }
      status = st;
      if (st == 0xff) {
        final type = bytes[o++];
        final len = vl();
        if (type == 3) {
          name = utf8.decode(bytes.sublist(o, o + len), allowMalformed: true);
        }
        o += len;
      } else if ((st & 0xf0) == 0x90 || (st & 0xf0) == 0x80) {
        final p = bytes[o++], v = bytes[o++];
        if ((st & 0xf0) == 0x90 && v > 0) {
          open[p] = now;
        } else if (open.containsKey(p)) {
          notes.add((p, open[p]!, now - open[p]!));
          open.remove(p);
        }
      } else if ((st & 0xf0) == 0xc0 || (st & 0xf0) == 0xd0) {
        o += 1;
      } else {
        o += 2;
      }
    }
    tracks.add((name, notes));
  }
  return (ppq, tracks);
}
