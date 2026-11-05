import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dj_assistant/analysis/analysis.dart';
import 'package:dj_assistant/analysis/chromaprint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Analysis parity: 1.x analysed the same files (test/golden/analysis.json).
/// Decoding is bit-exact, so results must match up to floating-point rounding
/// (1.x computes in 32-bit floats, 2.0 in 64-bit).
void main() {
  final golden = (jsonDecode(
    File('test/golden/analysis.json').readAsStringSync(),
  ) as Map).cast<String, Map<String, dynamic>>();
  String locate(String rel) => rel.startsWith('library/')
      ? p.join('..', 'crates', 'dj-core', 'tests', 'fixtures', rel)
      : p.join('test', 'fixtures', rel);

  // Known 1.x errors that 2.0 deliberately does not reproduce.
  // Driftwood.aiff: 1.x's AIFF reader (Symphonia) skips the 8-byte SSND
  // offset/block-size header twice, so the audio is shifted by 4 samples and the
  // last 4 "samples" are the bytes of the following "ID3 " chunk header (0x4944 =
  // −4.8 dBFS). The real peak is −18.1 dBFS (ffmpeg agrees).
  const corrections = {
    'library/Lossless/Driftwood.aiff': {'peak_dbfs': -18.1},
  };

  for (final e in golden.entries) {
    test('analyses ${e.key} as 1.x does', () {
      final w = {...e.value, ...?corrections[e.key]};
      final analysis = analyseFile(locate(e.key));
      final a = analysis.toJson();
      void near(String k, double tol) {
        final x = w[k], y = a[k];
        if (x == null || y == null) {
          expect(y, x, reason: k);
        } else {
          expect(
            (y as num).toDouble(),
            closeTo((x as num).toDouble(), tol),
            reason: k,
          );
        }
      }

      for (final k in [
        'duration_ms',
        'bpm',
        'bpm_alt',
        'key',
        'camelot',
        'energy',
        'clipped_runs',
        'silence_start_ms',
        'silence_end_ms',
        'intro_end_ms',
        'outro_start_ms',
        'tempo_stable',
        'warnings',
      ]) {
        expect(a[k], w[k], reason: k);
      }
      near('bpm_confidence', 0.02);
      near('key_confidence', 0.02);
      near('energy_raw', 0.003);
      near('loudness_lufs', 0.005);
      near('peak_dbfs', 0.05);
      expect(
        [for (final c in a['cues'] as List) (c as Map)['label']],
        [for (final c in w['cues'] as List) (c as Map)['label']],
      );
      expect(
        [for (final c in a['cues'] as List) (c as Map)['ms']],
        [for (final c in w['cues'] as List) (c as Map)['ms']],
      );
      // Fingerprint: the AcoustID encoding is pure logic, so encoding 1.x's own
      // fingerprint must give 1.x's string exactly. 1.x may run rubato's SIMD
      // resampler, which sums in a different order; the bit-agreement and
      // similarity checks below are what would still hold if that ever differed.
      final wfp = (w['fingerprint'] as List).cast<int>();
      final fp = analysis.fingerprint;
      expect(
        wfp.isEmpty ? null : encodeFingerprint(wfp),
        w['fingerprint_encoded'],
      );
      // On these clips 2.0's fingerprints are bit-identical to 1.x.
      expect(
        analysis.fingerprintEncoded,
        w['fingerprint_encoded'],
        reason: 'AcoustID fingerprint',
      );
      expect(
        (fp.length - wfp.length).abs(),
        lessThanOrEqualTo(2),
        reason: 'fingerprint length',
      );
      if (wfp.length >= 20) {
        var same = 0, total = 0;
        for (var i = 0; i < math.min(fp.length, wfp.length); i++) {
          var x = (fp[i] ^ wfp[i]) & 0xFFFFFFFF;
          var diff = 0;
          while (x != 0) {
            x &= x - 1;
            diff++;
          }
          same += 32 - diff;
          total += 32;
        }
        expect(
          same / total,
          greaterThan(0.99),
          reason: 'fingerprint bit agreement',
        );
        expect(
          fingerprintSimilarity(fp, wfp),
          greaterThan(0.95),
          reason: 'same track',
        );
      }
      final wf = (a['waveform'] as List).cast<int>(),
          wwf = (w['waveform'] as List).cast<int>();
      expect(wf.length, wwf.length);
      for (var i = 0; i < wf.length; i++) {
        expect(
          (wf[i] - wwf[i]).abs(),
          lessThanOrEqualTo(1),
          reason: 'waveform[$i]',
        );
      }
    });
  }

  test('different tracks do not match', () {
    final a = analyseFile('test/fixtures/analysis/afro124_amin.flac')
        .fingerprint;
    final b = analyseFile('test/fixtures/analysis/house128_cmaj_stereo.flac')
        .fingerprint;
    expect(fingerprintSimilarity(a, b), lessThan(0.3));
    expect(fingerprintSimilarity(a, a), greaterThan(0.95));
  });
}
