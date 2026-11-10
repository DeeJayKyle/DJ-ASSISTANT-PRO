import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dj_assistant/studio/dsp.dart';
import 'package:dj_assistant/studio/stems.dart';
import 'package:dj_assistant/studio/stretch.dart';
import 'package:flutter_test/flutter_test.dart';

/// Speed of the Studio's signal processing on three minutes of stereo
/// music-like audio (kick, bass, chords, a voice-like tone, noise). Each
/// step prints its time and a fingerprint of its output, so a speed-up can
/// be checked to give the same result. Budgets are loose (CI machines vary);
/// they catch large regressions.
List<Float32List> testSong({int seconds = 180, int sr = 44100}) {
  final n = seconds * sr;
  final l = Float32List(n), r = Float32List(n);
  final rnd = math.Random(7);
  const bpm = 124.0;
  final beat = (60 / bpm * sr).round();
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    final inBeat = i % beat;
    final kick = inBeat < 4000
        ? math.sin(2 * math.pi * 55 * t) * math.exp(-inBeat / 900)
        : 0.0;
    final bass = 0.3 * math.sin(2 * math.pi * 110 * t);
    final chord =
        0.12 *
        (math.sin(2 * math.pi * 220 * t) +
            math.sin(2 * math.pi * 261.6 * t) +
            math.sin(2 * math.pi * 329.6 * t));
    final voice =
        0.15 *
        math.sin(2 * math.pi * (440 + 30 * math.sin(2 * math.pi * 5 * t)) * t);
    final noise = (rnd.nextDouble() - 0.5) * 0.02;
    l[i] = (kick + bass + chord + voice + noise) * 0.5;
    r[i] = (kick + bass + chord * 0.8 + voice + noise) * 0.5;
  }
  return [l, r];
}

double fingerprint(List<Float32List> ch) {
  var s = 0.0;
  for (final c in ch) {
    for (var i = 0; i < c.length; i += 97) {
      s += c[i] * ((i % 13) + 1);
    }
  }
  return s;
}

void main() {
  test('Studio processing of a 3-minute song', () {
    final song = testSong();
    final m = mono(song);
    final times = <String, int>{};
    final prints = <String, String>{};
    T time<T>(String name, T Function() f) {
      final sw = Stopwatch()..start();
      final r = f();
      times[name] = sw.elapsedMilliseconds;
      return r;
    }

    final fftRe = Float64List(4096), fftIm = Float64List(4096);
    time('fft 4096 x 2000', () {
      for (var k = 0; k < 2000; k++) {
        for (var i = 0; i < 4096; i++) {
          fftRe[i] = m[i + k];
          fftIm[i] = 0;
        }
        fft(fftRe, fftIm);
      }
    });
    prints['fft'] = fftRe[5].toStringAsFixed(6);
    final tempo = time('tempo', () => detectTempo(m, 44100));
    prints['tempo'] = tempo.bpm.toStringAsFixed(3);
    final key = time('key', () => detectKey(m, 44100));
    prints['key'] = '${key.tonic}${key.mode}';
    final rh = time('rhythm', () => rhythm(m, 44100));
    prints['rhythm'] = rh.bpm.toStringAsFixed(3);
    final chords = time('chords', () => detectChords(m, 44100));
    prints['chords'] = '${chords.length}';
    final stems = time('fast stems (1 core)', () => separate(song, 44100));
    prints['stems'] = [
      for (final s in stemNames) fingerprint(stems[s]!).toStringAsFixed(4),
    ].join(',');
    final st = time('time-stretch 1.05', () => timeStretch(song, 1.05));
    prints['stretch'] = fingerprint(st).toStringAsFixed(4);
    final ps = time('pitch shift +1', () => pitchShift(song, 1));
    prints['pitch'] = fingerprint(ps).toStringAsFixed(4);
    final ov = time('overview', () => overview(song));
    prints['overview'] = ov.fold<double>(0, (a, b) => a + b).toStringAsFixed(4);

    // ignore: avoid_print
    print('studio (ms): $times');
    // ignore: avoid_print
    print('studio fingerprints: $prints');
    expect(times['fast stems (1 core)'], lessThan(180000));
    for (final e in times.entries) {
      expect(e.value, lessThan(180000), reason: e.key);
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
