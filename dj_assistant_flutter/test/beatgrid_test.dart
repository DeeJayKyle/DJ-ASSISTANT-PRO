import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dj_assistant/analysis/analysis.dart';
import 'package:dj_assistant/analysis/beatgrid.dart';
import 'package:flutter_test/flutter_test.dart';

const sr = 22050;

/// A drum loop: a kick (60 Hz thump) on beat 1 of each bar, a short noise
/// burst (hat) on the other beats, and a quiet pad so the file isn't bare.
/// [tempoAt] gives the tempo at a time in seconds.
Float32List drums(
  double seconds,
  double Function(double) tempoAt, {
  double start = 0.25,
}) {
  final n = (seconds * sr).round();
  final x = Float32List(n);
  final rnd = math.Random(7);
  var t = start, beat = 0;
  while (t < seconds - 0.5) {
    final s = (t * sr).round();
    if (beat % 4 == 0) {
      for (var i = 0; i < (0.25 * sr).round() && s + i < n; i++) {
        final u = i / sr;
        x[s + i] +=
            0.9 *
            math.sin(2 * math.pi * (60 + 80 * math.exp(-u * 30)) * u) *
            math.exp(-u * 12);
      }
    } else {
      for (var i = 0; i < (0.03 * sr).round() && s + i < n; i++) {
        x[s + i] += 0.25 * (rnd.nextDouble() * 2 - 1) * math.exp(-i / sr * 120);
      }
    }
    t += 60 / tempoAt(t);
    beat++;
  }
  for (var i = 0; i < n; i++) {
    x[i] += 0.02 * math.sin(2 * math.pi * 220 * i / sr);
  }
  return x;
}

Analysis run(Float32List x, {String? range}) =>
    analyseDecoded(Decoded(x, sr), bpmRange: range);

void main() {
  test('a steady track gets one marker on its first beat and its downbeat', () {
    final a = run(drums(60, (_) => 124));
    final g = a.beatgrid!;
    expect(a.bpm, closeTo(124, 0.6));
    expect(g.stable, isTrue);
    expect(g.markers, hasLength(1));
    expect(g.bpm, closeTo(124, 0.1));
    expect(g.firstBeatMs, closeTo(250, 20));
    // the kick is on the first beat, so beat 1 is there too
    expect(g.downbeatMs, closeTo(250, 20));
    expect(g.markers.first.beat, 1);
    expect(g.beats, greaterThan(100));
  });

  test('a grid that starts mid-bar counts back to the start of the file', () {
    // first kick at 1.218 s: grid lines every 0.4839 s fall at 0.25 s too
    final a = run(drums(60, (_) => 124, start: 1.218));
    final g = a.beatgrid!;
    expect(g.firstBeatMs, closeTo(250, 25));
    expect(g.downbeatMs, closeTo(1218, 25));
    expect(g.markers.first.beat, 3);
  });

  test('a track that speeds up gets a marker where the tempo changes', () {
    final a = run(drums(80, (t) => t < 40 ? 120 : 126));
    final g = a.beatgrid!;
    expect(g.stable, isFalse);
    expect(g.markers.length, greaterThanOrEqualTo(2));
    expect(g.markers.first.bpm, closeTo(120, 0.5));
    expect(g.markers.last.bpm, closeTo(126, 0.5));
    final change = g.markers[1].ms;
    expect(change, closeTo(40000, 4000));
  });

  test('BPM range folds half and double time like Serato\'s ranges', () {
    expect(foldBpm(70, '88-175'), 140);
    expect(foldBpm(174, '58-115'), 87);
    expect(foldBpm(128, '68-135'), 128);
    expect(foldBpm(128, 'auto'), 128);
    final a = run(drums(60, (_) => 124), range: '58-115');
    expect(a.bpm, closeTo(62, 0.4));
    expect(a.bpmAlt, closeTo(124, 0.6));
    expect(a.beatgrid!.bpm, closeTo(62, 0.1));
  });

  test('a chord tuned 40 cents sharp is still read in its own key', () {
    // A minor triad (A, C, E) plus a melody on the scale, all +40 cents
    const cents = 40.0;
    final n = 30 * sr;
    final x = Float32List(n);
    double f(int midi) =>
        440 * math.pow(2, (midi - 69 + cents / 100) / 12).toDouble();
    final notes = [57, 60, 64, 69, 72, 76];
    final melody = [69, 71, 72, 74, 76, 77, 79, 81];
    for (var i = 0; i < n; i++) {
      final t = i / sr;
      var v = 0.0;
      for (final m in notes) {
        v += 0.08 * math.sin(2 * math.pi * f(m) * t);
      }
      v += 0.1 * math.sin(2 * math.pi * f(melody[(t * 2).floor() % 8]) * t);
      x[i] = v;
    }
    final a = run(x);
    expect(a.key, 'A minor');
    expect(a.camelot, '8A');
    expect(a.tuningCents, closeTo(cents, 8));
  });

  test('beatgrid round-trips through JSON', () {
    final g = run(drums(30, (_) => 128)).beatgrid!;
    final back = BeatGrid.fromJson(g.toJson())!;
    expect(back.toJson(), g.toJson());
  });
}
