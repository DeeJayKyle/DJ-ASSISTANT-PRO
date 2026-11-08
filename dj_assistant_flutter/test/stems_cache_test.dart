import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dj_assistant/studio/stems.dart' show Stems, stemNames;
import 'package:dj_assistant/studio/stems_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Stems fake(int frames, [double gain = 0.5]) => {
  for (var s = 0; s < stemNames.length; s++)
    stemNames[s]: [
      for (var c = 0; c < 2; c++)
        Float32List.fromList([
          for (var i = 0; i < frames; i++)
            gain * math.sin(2 * math.pi * (110 + 50 * s + c) * i / 44100),
        ]),
    ],
};

void main() {
  late Directory dir;
  late File song;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('stems_cache');
    song = File(p.join(dir.path, 'song.wav'))..writeAsBytesSync([1, 2, 3]);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  StemsSource src([String method = 'ai', String model = 'm:1']) =>
      StemsSource.of(song.path, method, model)!;

  test('prepared stems round-trip at 16-bit precision', () {
    final stems = fake(4410);
    final c = StemsCache(p.join(dir.path, 'cache'));
    expect(c.save(src(), stems, 44100), isTrue);
    final (back, sr) = c.load(src())!;
    expect(sr, 44100);
    for (final s in stemNames) {
      for (var ch = 0; ch < 2; ch++) {
        for (var i = 0; i < 4410; i += 97) {
          expect(back[s]![ch][i], closeTo(stems[s]![ch][i], 1 / 30000));
        }
      }
    }
    expect(c.usage().$2, 1);
  });

  test('loud stems keep their level (scaled, not clipped)', () {
    final c = StemsCache(p.join(dir.path, 'cache'));
    c.save(src(), fake(1000, 1.6), 44100);
    final (back, _) = c.load(src())!;
    var peak = 0.0;
    for (final v in back['vocals']![0]) {
      peak = math.max(peak, v.abs());
    }
    expect(peak, closeTo(1.6, 0.01));
  });

  test('an edited song, another method or a new model misses', () {
    final c = StemsCache(p.join(dir.path, 'cache'));
    c.save(src(), fake(1000), 44100);
    expect(c.load(src('fast', 'fast-1')), isNull);
    expect(c.load(src('ai', 'm:2')), isNull);
    song.writeAsBytesSync([1, 2, 3, 4]);
    expect(c.load(src()), isNull);
  });

  test('a damaged file is ignored and removed', () {
    final c = StemsCache(p.join(dir.path, 'cache'));
    c.save(src(), fake(1000), 44100);
    final f = File(c.fileFor(src()));
    f.writeAsBytesSync(f.readAsBytesSync().sublist(0, 500));
    expect(c.load(src()), isNull);
    expect(f.existsSync(), isFalse);
  });

  test('the folder stays under its size by dropping the oldest', () {
    final c = StemsCache(p.join(dir.path, 'cache'));
    final one = encodePreparedStems(fake(2000), 44100, src()).length;
    c.maxBytes = (one * 2.5).round();
    final songs = <StemsSource>[];
    for (var i = 0; i < 4; i++) {
      final f = File(p.join(dir.path, 's$i.wav'))..writeAsBytesSync([i]);
      f.setLastModifiedSync(DateTime(2020, 1, 1 + i));
      final s = StemsSource.of(f.path, 'ai', 'm:1')!;
      songs.add(s);
      c.save(s, fake(2000), 44100);
      File(c.fileFor(s)).setLastModifiedSync(DateTime(2021, 1, 1 + i));
    }
    expect(c.usage().$2, 2);
    expect(File(c.fileFor(songs[0])).existsSync(), isFalse);
    expect(File(c.fileFor(songs[3])).existsSync(), isTrue);
  });
}
