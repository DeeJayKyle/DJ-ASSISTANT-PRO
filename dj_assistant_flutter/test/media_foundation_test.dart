import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dj_assistant/audio/media_foundation.dart';
import 'package:dj_assistant/audio/pcm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Windows Media Foundation decoding (runs in the Windows CI job and on the DJ's PC).
void main() {
  final skip = Platform.isWindows ? null : 'Media Foundation is Windows-only';
  final fixtures = p.join('..', 'crates', 'dj-core', 'tests', 'fixtures');

  (int, int, int, List<double>) decodeAll(PcmReader r) {
    final all = <double>[];
    try {
      for (var b = r.read(); b != null; b = r.read()) {
        all.addAll(b);
      }
    } finally {
      r.close();
    }
    return (r.sampleRate, r.channels, all.length ~/ r.channels, all);
  }

  final lossy = (jsonDecode(
    File('test/golden/lossy.json').readAsStringSync(),
  ) as Map).cast<String, Map<String, dynamic>>();
  for (final e in lossy.entries) {
    test('decodes ${e.key} like ffmpeg (within decoder delay)', () {
      final (rate, ch, frames, s) = decodeAll(
        MediaFoundationReader(p.join(fixtures, e.key)),
      );
      expect(rate, e.value['sample_rate']);
      expect(ch, e.value['channels']);
      // MP3/AAC decoders differ in how much encoder delay and padding they trim.
      expect(
        (frames - (e.value['frames'] as int)).abs(),
        lessThanOrEqualTo(3000),
        reason: 'frames $frames',
      );
      final rms = math.sqrt(s.fold<double>(0, (a, x) => a + x * x) / s.length);
      expect(
        rms,
        closeTo(e.value['rms'] as double, (e.value['rms'] as double) * 0.03),
      );
    }, skip: skip);
  }

  test(
    'PCM through Media Foundation matches the Dart decoder sample for sample',
    () {
      const wav = 'test/fixtures/audio/s16.wav';
      final (r1, c1, f1, a) = decodeAll(MediaFoundationReader(wav));
      final (r2, c2, f2, b) = decodeAll(openPcm(wav));
      expect((r1, c1, f1), (r2, c2, f2));
      var worst = 0.0;
      for (var i = 0; i < a.length; i++) {
        worst = math.max(worst, (a[i] - b[i]).abs());
      }
      expect(worst, lessThan(1e-6));
    },
    skip: skip,
  );

  test('openPcm sends MP3 to Media Foundation on Windows', () {
    final r = openPcm(
      p.join(fixtures, 'library', 'House', 'Old School', 'Basement Hours.mp3'),
    );
    expect(r, isA<MediaFoundationReader>());
    r.close();
  }, skip: skip);

  test('damaged files fail with a readable error', () {
    for (final name in ['corrupt.mp3', 'empty.mp3']) {
      expect(
        () => decodeAll(
          MediaFoundationReader(p.join(fixtures, 'library', 'Broken', name)),
        ),
        throwsA(isA<DecodeException>()),
        reason: name,
      );
    }
  }, skip: skip);
}
