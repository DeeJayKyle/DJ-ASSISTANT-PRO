import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/core/tags.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Parity with 1.x: `test/golden/metadata.json` was produced by the Rust reader
/// (`crates/dj-core/tests/golden_meta.rs`) on the shared fixture library.
void main() {
  final fixtures = p.normalize(
    p.join(
      Directory.current.path,
      '..',
      'crates',
      'dj-core',
      'tests',
      'fixtures',
      'library',
    ),
  );
  final golden = (jsonDecode(
    File('test/golden/metadata.json').readAsStringSync(),
  ) as Map).cast<String, Map<String, dynamic>>();

  const kinds = {
    'Supported': ExtKind.supported,
    'UnsupportedMusic': ExtKind.unsupportedMusic,
    'Video': ExtKind.video,
    'UnsupportedVideo': ExtKind.unsupportedVideo,
    'Other': ExtKind.other,
  };

  for (final entry in golden.entries) {
    test('matches 1.x: ${entry.key}', () {
      final want = entry.value;
      final path = p.join(fixtures, entry.key);
      final ext = p.extension(path).replaceFirst('.', '');
      expect(classifyExtension(ext), kinds[want['kind']]);
      if (want['kind'] != 'Supported') return;
      if (want['ok'] != true) {
        expect(() => readAudioMeta(path), throwsA(isA<TagReadException>()));
        return;
      }
      final m = readAudioMeta(path);
      final got = <String, Object?>{
        'format': m.format,
        'codec': m.codec,
        'lossless': m.lossless,
        'sample_rate': m.sampleRate,
        'channels': m.channels,
        'bit_depth': m.bitDepth,
        'title': m.title,
        'artist': m.artist,
        'album': m.album,
        'album_artist': m.albumArtist,
        'genre': m.genre,
        'date_text': m.dateText,
        'composer': m.composer,
        'label': m.label,
        'comment': m.comment,
        'isrc': m.isrc,
        'key': m.key,
        'year': m.year,
        'original_year': m.originalYear,
        'track_no': m.trackNo,
        'disc_no': m.discNo,
        'bpm': m.bpm,
        'media_kind': m.mediaKind,
      };
      for (final k in got.keys) {
        final w = want[k];
        final g = got[k];
        if (w is num && g is num) {
          expect(g.toDouble(), closeTo(w.toDouble(), 1e-6), reason: k);
        } else {
          expect(g, w, reason: k);
        }
      }
      final wd = want['duration_ms'] as int;
      expect(m.durationMs, isNotNull, reason: 'duration_ms');
      expect(
        (m.durationMs! - wd).abs(),
        lessThanOrEqualTo(wd * 0.02 + 30),
        reason: 'duration_ms',
      );
      final wb = want['bitrate_kbps'] as int?;
      if (wb != null) {
        expect(m.bitrateKbps, isNotNull, reason: 'bitrate_kbps');
        expect(
          (m.bitrateKbps! - wb).abs(),
          lessThanOrEqualTo(wb * 0.05 + 2),
          reason: 'bitrate_kbps',
        );
      }
    });
  }
}
