import 'dart:typed_data';

import 'package:dj_assistant/studio/audio_out.dart';
import 'package:flutter_test/flutter_test.dart';

/// The stem mix the Stems page streams (the sound card part runs in the
/// Windows integration test).
void main() {
  List<Float32List> layer(double v, int n) => [
    Float32List(n)..fillRange(0, n, v),
    Float32List(n)..fillRange(0, n, -v),
  ];

  test('mixes stems with their volumes, solo and mute apply at once', () {
    final m = LayerMix([layer(0.1, 3000), layer(0.2, 3000)], 44100);
    final l = Float32List(1024), r = Float32List(1024);
    m
      ..volumes = [1, 0.5]
      ..render(l, r, 1024);
    expect(l[0], closeTo(0.2, 1e-6));
    expect(r[0], closeTo(-0.2, 1e-6));
    m
      ..volumes =
          [0, 1] // solo the second stem
      ..render(l, r, 1024);
    expect(l[5], closeTo(0.2, 1e-6));
    expect(m.pos, 2048);
  });

  test('renders silence after the end and reports it', () {
    final m = LayerMix([layer(0.5, 1500)], 44100);
    final l = Float32List(1024), r = Float32List(1024);
    m
      ..render(l, r, 1024)
      ..render(l, r, 1024);
    expect(l[475], closeTo(0.5, 1e-6)); // frame 1499
    expect(l[476], 0); // past the end
    expect(m.atEnd, isTrue);
    m.render(l, r, 1024);
    expect(l.every((x) => x == 0), isTrue);
  });

  test('a mono layer plays on both sides', () {
    final m = LayerMix([
      [Float32List(10)..fillRange(0, 10, 0.3)],
    ], 48000);
    final l = Float32List(4), r = Float32List(4);
    m.render(l, r, 4);
    expect(r[0], closeTo(0.3, 1e-6));
  });
}
