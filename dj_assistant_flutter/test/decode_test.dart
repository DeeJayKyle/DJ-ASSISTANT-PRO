import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dj_assistant/audio/pcm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Bit-exact decoding: every clip must give the same 32-bit float samples as
/// ffmpeg (tool/gen_audio_fixtures.sh wrote the expected hashes).
void main() {
  final golden = (jsonDecode(
    File('test/golden/pcm.json').readAsStringSync(),
  ) as Map).cast<String, Map<String, dynamic>>();
  String locate(String rel) => rel.startsWith('library/')
      ? p.join('..', 'crates', 'dj-core', 'tests', 'fixtures', rel)
      : p.join('test', 'fixtures', rel);

  for (final e in golden.entries) {
    test('decodes ${e.key} exactly', () {
      final r = openPcm(locate(e.key));
      final bytes = BytesBuilder(copy: false);
      var samples = 0;
      try {
        for (var b = r.read(); b != null; b = r.read()) {
          final le = ByteData(b.length * 4);
          for (var i = 0; i < b.length; i++) {
            le.setFloat32(i * 4, b[i], Endian.little);
          }
          bytes.add(le.buffer.asUint8List());
          samples += b.length;
        }
      } finally {
        r.close();
      }
      expect(r.sampleRate, e.value['sample_rate']);
      expect(r.channels, e.value['channels']);
      expect(samples ~/ r.channels, e.value['frames']);
      expect(sha256.convert(bytes.takeBytes()).toString(), e.value['sha256']);
    });
  }

  test('broken files fail with a readable error', () {
    for (final name in ['truncated.flac', 'corrupt.mp3', 'empty.mp3']) {
      final path = p.join(
        '..',
        'crates',
        'dj-core',
        'tests',
        'fixtures',
        'library',
        'Broken',
        name,
      );
      if (name.endsWith('.mp3') && Platform.isWindows) continue;
      expect(
        () => openPcm(path),
        throwsA(isA<DecodeException>()),
        reason: name,
      );
    }
  });

  test('a FLAC cut off mid-stream decodes its good frames', () {
    final whole = File('test/fixtures/audio/lpc_stereo16.flac')
        .readAsBytesSync();
    final tmp = Directory.systemTemp.createTempSync('dja-flac-');
    final cut = File(p.join(tmp.path, 'cut.flac'))
      ..writeAsBytesSync(whole.sublist(0, whole.length * 6 ~/ 10));
    final r = openPcm(cut.path);
    var frames = 0;
    for (var b = r.read(); b != null; b = r.read()) {
      frames += b.length ~/ 2;
    }
    r.close();
    tmp.deleteSync(recursive: true);
    // ffmpeg recovers exactly the same 4608 frames (8 KB of padding precede the audio).
    expect(frames, 4608);
  });

  test('formats that need Media Foundation are refused off Windows', () {
    final mp3 = p.join(
      '..',
      'crates',
      'dj-core',
      'tests',
      'fixtures',
      'library',
      'House',
      'Old School',
      'Basement Hours.mp3',
    );
    if (Platform.isWindows) return;
    expect(() => openPcm(mp3), throwsA(isA<DecodeException>()));
  });
}
