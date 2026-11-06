import 'dart:io';

import 'package:dj_assistant/studio/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The path a DJ takes on the Stems page, for every format: decode in an
/// isolate (Media Foundation on Windows for MP3/AAC), analyse, split with the
/// Fast method. WAV, AIFF and FLAC run everywhere; MP3 and M4A on Windows.
void main() {
  final lib = p.join('..', 'crates', 'dj-core', 'tests', 'fixtures', 'library');
  const lossless = [
    'Lossless/Low Tide.flac',
    'Lossless/Driftwood.aiff',
    'Lossless/untagged recording.wav',
  ];
  const lossy = [
    'House/Old School/Basement Hours.mp3',
    'Café Ünïcode/Beyoncé – Déjà Vu (Medley).mp3',
    'House/Neon Steps.m4a',
    'Lossless/Shoreline.m4a',
  ];
  final engine = StudioEngine(cores: 3);

  for (final f in [...lossless, ...lossy]) {
    final windowsOnly = lossy.contains(f);
    test(
      'Stems path: $f',
      () async {
        final path = p.join(lib, f);
        final l = await engine.load(SongRef(id: f, title: f, path: path));
        expect(l.sampleRate, greaterThan(8000));
        expect(l.mix[0].length, greaterThan(l.sampleRate ~/ 2)); // > 0.5 s
        expect(l.mix[0].any((x) => x != 0), isTrue, reason: 'decoded silence');
        await engine.analyse(l);
        final progress = <double>[];
        final stems = await engine.separate(
          l,
          method: 'fast',
          onProgress: progress.add,
        );
        for (final s in stems.values) {
          expect(s[0].length, l.mix[0].length);
          expect(s[1].length, l.mix[0].length);
        }
        expect(progress, isNotEmpty);
      },
      skip: windowsOnly && !Platform.isWindows
          ? 'MP3 and AAC decode through Media Foundation (Windows)'
          : null,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  test('a missing file gives a clear reason', () async {
    final err = await engine
        .load(const SongRef(id: 'x', title: 'x', path: 'no/such/song.mp3'))
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect('$err', contains('can’t be found'));
  });

  test('a broken file says why it can’t be decoded', () async {
    final err = await engine
        .load(
          SongRef(
            id: 'b',
            title: 'b',
            path: p.join(lib, 'Broken', 'corrupt.mp3'),
          ),
        )
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(err, isA<StudioException>());
    // the decoder's own reason is kept for the page and the log
    expect((err! as StudioException).detail, isNotEmpty);
  });
}
