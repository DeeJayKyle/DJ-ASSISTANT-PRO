import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dj_assistant/audio/pcm_files.dart';
import 'package:dj_assistant/studio/ai_stems.dart';
import 'package:dj_assistant/studio/biquad.dart';
import 'package:dj_assistant/studio/drums.dart';
import 'package:dj_assistant/studio/dsp.dart';
import 'package:dj_assistant/studio/midi.dart';
import 'package:dj_assistant/studio/remix.dart';
import 'package:dj_assistant/studio/stems.dart';
import 'package:dj_assistant/studio/stretch.dart';
import 'package:dj_assistant/studio/synth.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ports of 1.x `src/studio/test/studio.test.ts`.
const sr = 22050;

Float32List tone(
  double hz,
  double sec, [
  int harmonics = 1,
  double vib = 0,
  int rate = sr,
]) {
  final x = Float32List((sec * rate).floor());
  var ph = 0.0;
  for (var i = 0; i < x.length; i++) {
    final f = hz * (1 + vib * math.sin(2 * math.pi * 5 * (i / rate)));
    ph += f / rate;
    var s = 0.0;
    for (var h = 1; h <= harmonics; h++) {
      s += math.sin(2 * math.pi * ph * h) / h;
    }
    x[i] = s * 0.25;
  }
  return x;
}

Float32List kickPattern(double bpm, double seconds, [int rate = sr]) {
  final out = Float32List((seconds * rate).floor());
  final beat = 60 / bpm * rate;
  for (var b = 0; b * beat < out.length; b++) {
    final start = (b * beat).floor();
    for (var i = 0; i < rate * 0.12 && start + i < out.length; i++) {
      final t = i / rate;
      out[start + i] +=
          math.sin(2 * math.pi * (50 + 120 * math.exp(-t * 40)) * t) *
          math.exp(-t * 18) *
          0.8;
    }
  }
  return out;
}

double _freq(int midi) => 440 * math.pow(2, (midi - 69) / 12).toDouble();

Float32List chordSignal(
  List<List<int>> progression,
  double chordSeconds, [
  int rate = sr,
]) {
  final out = Float32List((progression.length * chordSeconds * rate).floor());
  for (var c = 0; c < progression.length; c++) {
    final notes = progression[c];
    final start = (c * chordSeconds * rate).floor();
    for (var i = 0; i < chordSeconds * rate; i++) {
      final t = i / rate;
      var s = 0.0;
      for (final n in notes) {
        for (var h = 1; h <= 3; h++) {
          s += math.sin(2 * math.pi * _freq(n) * h * t) / (h * h);
        }
      }
      if (start + i < out.length) out[start + i] = s / notes.length * 0.3;
    }
  }
  return out;
}

Float32List mixOf(List<Float32List> parts) {
  final n = parts.map((p) => p.length).reduce(math.min);
  final out = Float32List(n);
  for (final p in parts) {
    for (var i = 0; i < n; i++) {
      out[i] += p[i];
    }
  }
  return out;
}

double zeroCrossHz(Float32List x, int rate) {
  var z = 0;
  for (var i = 1; i < x.length; i++) {
    if (x[i - 1] < 0 && x[i] >= 0) z++;
  }
  return z / (x.length / rate);
}

double dot(Float32List a, Float32List b) {
  var s = 0.0;
  for (var i = 0; i < math.min(a.length, b.length); i++) {
    s += a[i] * b[i];
  }
  return s;
}

double energy(Float32List a) => dot(a, a);
Float32List sub(Float32List a, int s, [int? e]) =>
    Float32List.sublistView(a, s, e ?? a.length);

void render(DeckReader d, List<Float32List> out, int frames) {
  final l = Float32List(128), r = Float32List(128);
  for (var o = 0; o < frames; o += 128) {
    final n = math.min(128, frames - o);
    d.render([l, r], n);
    out[0].setRange(o, o + n, l);
    out[1].setRange(o, o + n, r);
  }
}

void main() {
  group('stem separation', () {
    test('sends each part of a mix to the right stem, and the stems add back up to the mix', () {
      const sec = 6.0;
      final kick = kickPattern(120, sec),
          bass = tone(55, sec),
          voice = tone(330, sec, 6, 0.01),
          pad = tone(523, sec, 3);
      final L = mixOf([kick, bass, voice, pad]), R = mixOf([kick, bass, voice]);
      final stems = separate([L, R], sr);
      var err = 0.0;
      for (var i = 4000; i < L.length - 4000; i += 7) {
        var s = 0.0;
        for (final st in stemNames) {
          s += stems[st]![0][i];
        }
        err = math.max(err, (s - L[i]).abs());
      }
      expect(err, lessThan(1e-3));
      double share(String stem, Float32List src) =>
          dot(stems[stem]![1], src) / energy(src);
      expect(share('drums', kick), greaterThan(0.5));
      expect(share('bass', bass), greaterThan(0.6));
      expect(share('vocals', voice), greaterThan(0.5));
      expect(dot(stems['melodies']![0], pad) / energy(pad), greaterThan(0.5));
      expect(dot(instrumental(stems)[1], voice) / energy(voice), lessThan(0.5));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('gives the same stems when split into parts', () {
      const sec = 3.0;
      final L = mixOf([kickPattern(120, sec), tone(220, sec, 4)]),
          R = mixOf([kickPattern(120, sec), tone(330, sec, 2)]);
      final whole = separate([L, R], sr);
      final parts = [
        for (final p in planParts(L.length, 3))
          separatePart(
            [sub(L, p.inStart, p.inEnd), sub(R, p.inStart, p.inEnd)],
            p.inStart,
            L.length,
            sr,
            p.f0,
            p.f1,
          ),
      ];
      final got = mergeParts(parts, L.length);
      var err = 0.0;
      for (final st in stemNames) {
        for (var c = 0; c < 2; c++) {
          for (var i = 0; i < L.length; i += 3) {
            err = math.max(err, (got[st]![c][i] - whole[st]![c][i]).abs());
          }
        }
      }
      expect(err, lessThan(1e-5));
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('chords, key and MIDI', () {
    test('follows a chord progression', () {
      final prog = [
        [45, 57, 60, 64],
        [41, 57, 60, 65],
        [48, 55, 60, 64],
        [43, 55, 59, 62],
      ];
      final segs = detectChords(chordSignal(prog, 2), sr);
      expect(
        [
          for (final s in segs)
            if (s.end - s.start > 1) s.name,
        ],
        ['Am', 'F', 'C', 'G'],
      );
      expect(
        chordNotes([for (final s in segs) (s.start, s.end, s.root, s.quality)])
            .length,
        greaterThanOrEqualTo(12),
      );
    });

    test('transcribes a bass line and drum hits, and writes a MIDI file that reads back', () {
      const line = [33, 36, 40, 43];
      final bass = Float32List(2 * sr);
      for (var k = 0; k < line.length; k++) {
        bass.setAll((k * 0.5 * sr).floor(), tone(_freq(line[k]), 0.5, 2));
      }
      final notes = transcribePitched(bass, sr, minHz: 30, maxHz: 400);
      expect([for (final n in notes) n.pitch], line);
      final drums = transcribeDrums(kickPattern(120, 4), sr);
      final kicks = drums.where((n) => n.pitch == 36).length;
      expect(kicks, inInclusiveRange(7, 9));
      final (ppq, tracks) = readMidi(
        writeMidi([
          MidiTrack('Bass', 0, notes),
          MidiTrack('Drums', 9, drums),
        ], 120),
      );
      expect(ppq, 480);
      expect(tracks[1].$1, 'Bass');
      expect([for (final n in tracks[1].$2) n.$1], line);
      expect((tracks[1].$2[1].$2 - 480).abs(), lessThan(30));
    });

    test('finds the beat phase', () {
      final x = Float32List(8 * sr)
        ..setAll((0.2 * sr).floor(), kickPattern(120, 7.8));
      final ph = beatPhase(x, sr, 120);
      expect((((ph - 0.2 + 0.25) % 0.5) - 0.25).abs(), lessThan(0.03));
    });

    test('writes WAV that reads back', () {
      final a = tone(440, 0.1);
      final dir = Directory.systemTemp.createTempSync('wav');
      addTearDown(() => dir.deleteSync(recursive: true));
      for (final bits in [16, 24]) {
        final f = File('${dir.path}/t$bits.wav')
          ..writeAsBytesSync(encodeWav([a, a], sr, bits));
        final r = WavReader(f.path);
        expect(r.sampleRate, sr);
        expect(r.channels, 2);
        final block = r.read()!;
        r.close();
        expect((block[201] - a[100]).abs(), lessThan(1e-3));
      }
    });
  });

  group('tempo and key changes', () {
    test('stretches without changing pitch, and shifts pitch without changing length', () {
      final a = tone(440, 1);
      final s = timeStretch([a], 1.5)[0];
      expect(s.length, (a.length * 1.5).round());
      expect(
        (zeroCrossHz(sub(s, 2000, s.length - 2000), sr) - 440).abs(),
        lessThan(12),
      );
      final p = pitchShift([a], 12)[0];
      expect(p.length, a.length);
      expect(
        (zeroCrossHz(sub(p, 2000, p.length - 2000), sr) - 880).abs(),
        lessThan(25),
      );
      final r = retune([a], 1.25, -12)[0];
      expect((r.length - a.length / 1.25).abs(), lessThan(2));
      expect(
        (zeroCrossHz(sub(r, 2000, r.length - 2000), sr) - 220).abs(),
        lessThan(10),
      );
    });

    test('plays a deck in real time at any tempo and key', () {
      final a = tone(440, 2);
      final deck = DeckReader([
        [a, a],
      ])..seek(0);
      deck.playing = true;
      final out = [Float32List(sr), Float32List(sr)];
      render(deck, out, sr);
      expect((zeroCrossHz(sub(out[0], 4000), sr) - 440).abs(), lessThan(10));
      final fast = DeckReader([
        [a, a],
      ]);
      fast
        ..rate = 1.5
        ..pitch = math.pow(2, 2 / 12).toDouble()
        ..seek(0)
        ..playing = true;
      final o2 = [Float32List(sr ~/ 2), Float32List(sr ~/ 2)];
      render(fast, o2, sr ~/ 2);
      expect(fast.pos, greaterThan(sr * 0.7));
      expect(
        (zeroCrossHz(sub(o2[0], 3000), sr) - 440 * math.pow(2, 2 / 12)).abs(),
        lessThan(15),
      );
    });

    test('loops a deck on the beat', () {
      final a = tone(220, 4);
      final deck = DeckReader([
        [a, a],
      ])..seek(sr * 1.0);
      deck
        ..loop = (sr * 1.0, sr * 1.5)
        ..playing = true;
      final o = [Float32List(128), Float32List(128)];
      var maxPos = 0.0;
      for (var i = 0; i < sr * 3 / 128; i++) {
        deck.render(o, 128);
        maxPos = math.max(maxPos, deck.pos);
      }
      expect(maxPos, lessThan(sr * 1.5 + 1024));
      expect(deck.pos, greaterThanOrEqualTo(sr * 1.0));
      deck.loop = null;
      for (var i = 0; i < sr / 128; i++) {
        deck.render(o, 128);
      }
      expect(deck.pos, greaterThan(sr * 1.6));
    });

    test('moves keys the short way round', () {
      expect(semitoneShift(9, 0), 3);
      expect(semitoneShift(0, 11), -1);
      expect(keyShift(9, 'minor', 0, 'major'), 0);
      expect(keyShift(2, 'minor', 9, 'minor'), -5);
    });

    test('deck EQ cuts the band it is set to and leaves the rest', () {
      final low = tone(60, 1), high = tone(8000, 1);
      double after(Float32List x, void Function(DeckStrip) set) {
        final s = DeckStrip();
        set(s);
        final l = Float32List.fromList(x), r = Float32List.fromList(x);
        s.process(l, r, l.length, sr);
        return energy(sub(l, 4000)) / energy(sub(x, 4000));
      }

      expect(after(low, (s) => s.eqLow = -24), lessThan(0.05));
      expect(after(high, (s) => s.eqLow = -24), greaterThan(0.8));
      expect(after(high, (s) => s.filter = -0.6), lessThan(0.05));
      expect(after(low, (s) => s.filter = 0.6), lessThan(0.05));
      expect(after(low, (_) {}), closeTo(1, 1e-9));
    });
  });

  group('remix', () {
    test('syncs clips to the project tempo and mixes tracks', () {
      final loop = kickPattern(100, 4.8);
      final src = Source(
        id: 's',
        name: 'Loop',
        sampleRate: sr,
        layers: {
          'mix': [loop, loop],
        },
        bpm: 100,
        firstBeat: 0,
        tonic: 0,
        mode: 'major',
        keyShort: 'C',
        durationSec: 4.8,
      );
      var project = const Project(
        name: 'Test',
        tonic: 0,
        mode: 'major',
        tracks: [
          RTrack(
            id: 't1',
            name: 'Loop',
            gain: 1,
            clips: [
              Clip(
                id: 'c',
                sourceId: 's',
                layer: 'mix',
                start: 4,
                length: 4,
                loops: 2,
              ),
            ],
          ),
        ],
      );
      final r = renderProject(project, {'s': src}, sr, withTracks: true);
      final m = r.mix;
      expect(energy(sub(m[0], 0, (1.9 * sr).floor())), 0);
      expect(energy(sub(m[0], 2 * sr, 6 * sr)), greaterThan(1));
      expect(energy(sub(m[0], (6.2 * sr).floor())), lessThan(0.05));
      expect(r.tracks['t1'], isNotNull);
      project = project.copyWith(
        tracks: [project.tracks[0].copyWith(mute: true)],
      );
      expect(energy(renderProject(project, {'s': src}, sr).mix[0]), 0);
    });
  });

  group('sound design from words', () {
    test('turns descriptions into patches and kits', () {
      final sub = patchFromPrompt('dark thick sub bass');
      expect(sub.oscs[0].octave, -1);
      expect(sub.unison, greaterThanOrEqualTo(5));
      final organ = patchFromPrompt('bright cinematic synth organ');
      expect(organ.reverbMix, greaterThanOrEqualTo(0.5));
      expect(organ.filter.cutoff, greaterThan(sub.filter.cutoff));
      String j(Patch p) => jsonEncode(p.toJson());
      expect(
        j(patchFromPrompt('warm pad', 1)),
        isNot(j(patchFromPrompt('warm pad', 2))),
      );
      expect(
        j(patchFromPrompt('warm pad', 3)),
        j(patchFromPrompt('warm pad', 3)),
      );
      final trap = kitFromPrompt('crisp trap kit with booming 808'),
          techno = kitFromPrompt('deep punchy techno');
      expect(trap.pads, hasLength(16));
      expect(
        [for (final p in trap.pads) p.note],
        [for (var i = 0; i < 16; i++) 36 + i],
      );
      expect(trap.pads[0].decay, greaterThan(techno.pads[0].decay));
      final ai = patchFromAi({
        'name': 'AI Pad',
        'oscs': [
          {'wave': 'saw', 'level': 2, 'octave': 9, 'detune': 0},
          {'wave': 'bogus'},
        ],
        'filter': {'cutoff': 99999},
      }, sub);
      expect(ai.oscs, hasLength(1));
      expect(ai.oscs[0].level, 1);
      expect(ai.oscs[0].octave, 3);
      expect(ai.filter.cutoff, 18000);
    });

    test('renders playable notes and drum hits', () {
      final p = patchFromPrompt('soft sine organ')
        ..oscs = [Osc('sine', 0.6)]
        ..reverbMix = 0
        ..reverbSize = 0
        ..chorus = 0
        ..unison = 1;
      final note = renderNote(p, 69, 0.5, sampleRate: sr);
      expect(note[0].every((x) => x.isFinite), isTrue);
      expect(
        (zeroCrossHz(sub(note[0], 1000, (0.45 * sr).floor()), sr) - 440).abs(),
        lessThan(8),
      );
      for (final pad in kitFromPrompt(
        'gritty saturated synthwave drums',
      ).pads) {
        final l = renderPad(pad, sampleRate: sr)[0];
        expect(l.every((x) => x.isFinite), isTrue);
        expect(energy(l), greaterThan(0));
      }
    });

    test('exports kits and instruments as WAV + SFZ', () {
      final files = kitFiles(
        kitFromPrompt('dusty lofi hip hop kit'),
        sampleRate: sr,
      );
      expect(files, hasLength(18));
      expect(String.fromCharCodes(files[0].$2.sublist(0, 4)), 'RIFF');
      final sfz = utf8.decode(
        files.firstWhere((f) => f.$1.endsWith('.sfz')).$2,
      );
      expect(sfz, contains('key=36'));
      final inst = instrumentFiles(
        patchFromPrompt('glassy bell pluck'),
        sampleRate: sr,
      );
      expect(inst.where((f) => f.$1.endsWith('.wav')).length, 13);
    });
  });

  group('drum sequencer', () {
    test(
      'plays a pattern on the grid, with swing, as a seamless loop and as MIDI',
      () {
        final kit = kitFromPrompt('warm disco house kit');
        final p = defaultPattern(kit, 120);
        expect(p.grid[0].where((x) => x).length, 4);
        final loop = renderPattern(kit, p, sampleRate: sr);
        expect(loop[0].length, 4 * sr);
        expect(loop[0].every((x) => x.isFinite), isTrue);
        double env(double t) {
          var e = 0.0;
          final i = (t * sr).round();
          for (var j = i; j < i + 200; j++) {
            e += loop[0][j] * loop[0][j];
          }
          return e;
        }

        expect(env(0.5), greaterThan(env(0.4) * 2));
        final swung = stepTimes(Pattern(p.bpm, 0.5, p.grid));
        expect(swung[1] - stepTimes(p)[1], closeTo(0.125 * 0.5 * 0.5, 1e-5));
        expect(swung[2], closeTo(stepTimes(p)[2], 1e-9));
        final (_, tracks) = readMidi(patternMidi(kit, p));
        final kicks = tracks[1].$2
            .where((n) => n.$1 == kit.pads[0].note)
            .toList();
        expect(kicks, hasLength(16));
        expect(kicks[1].$2, 480);
      },
    );
  });

  group('AI stems signal path (HTDemucs pre/post-processing)', () {
    test('rebuilds the input exactly through the spectrogram and the waveform branches', () {
      const rate = 44100, n = rate * 18;
      final L = Float32List(n), R = Float32List(n);
      for (var i = 0; i < n; i++) {
        L[i] =
            0.5 * math.sin(2 * math.pi * 220 * i / rate) +
            0.2 * math.sin(2 * math.pi * 3100 * i / rate);
        R[i] = 0.4 * math.sin(2 * math.pi * 330 * i / rate);
      }
      var calls = 0;
      (Float32List?, Float32List) run(Float32List waveform, Float32List spec) {
        calls++;
        const plane = 4 * bins * frames;
        final freq = Float32List(4 * plane)..setAll(0, spec);
        final time = Float32List(4 * 2 * seg)..setAll(3 * 2 * seg, waveform);
        return (freq, time);
      }

      final seen = <double>[];
      final r = separateAi(
        [L, R],
        rate,
        run,
        onProgress: (d, t) => seen.add(d / t),
      );
      expect(calls, 3);
      expect(seen.last, 1);
      double err(Float32List a, Float32List b) {
        var e = 0.0, s = 0.0;
        for (var i = 2048; i < n - 2048; i++) {
          e += (a[i] - b[i]) * (a[i] - b[i]);
          s += b[i] * b[i];
        }
        return math.sqrt(e / s);
      }

      expect(err(r['drums']![0], L), lessThan(1e-3));
      expect(err(r['drums']![1], R), lessThan(1e-3));
      expect(err(r['vocals']![0], L), lessThan(1e-4));
      expect(sub(r['bass']![0], 0, 50000).every((x) => x == 0), isTrue);
    }, timeout: const Timeout(Duration(minutes: 4)));

    test('works at other sample rates (resampled to 44.1 kHz and back)', () {
      const rate = 48000, n = rate * 3;
      final L = Float32List.fromList([
        for (var i = 0; i < n; i++) math.sin(2 * math.pi * 440 * i / rate),
      ]);
      (Float32List?, Float32List) run(Float32List waveform, Float32List spec) =>
          (null, Float32List(8 * seg)..setAll(6 * seg, waveform));
      final r = separateAi([L, L], rate, run);
      expect(r['vocals']![0].length, n);
      var e = 0.0;
      for (var i = 1000; i < n - 1000; i++) {
        e = math.max(e, (r['vocals']![0][i] - L[i]).abs());
      }
      expect(e, lessThan(0.02));
    });
  });
}
