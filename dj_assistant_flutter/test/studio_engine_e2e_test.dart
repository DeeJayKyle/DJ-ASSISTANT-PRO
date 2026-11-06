import 'package:dj_assistant/studio/engine.dart';
import 'package:flutter_test/flutter_test.dart';

const _song = '../crates/dj-core/tests/fixtures/library/Lossless/Low Tide.flac';

void main() {
  test(
    'engine: decode, analyse, split and make MIDI from a real file',
    () async {
      final e = StudioEngine(cores: 3);
      final l = await e.load(
        const SongRef(id: '1', title: 'Low Tide', path: _song),
      );
      expect(l.mix[0].length, greaterThan(1000));
      final a = await e.analyse(l);
      expect(a.bpm, greaterThanOrEqualTo(0));
      final p = <double>[];
      final s = await e.separate(l, onProgress: p.add, method: 'fast');
      expect(s.keys, containsAll(['vocals', 'drums', 'bass', 'melodies']));
      expect(s['drums']![0].length, l.mix[0].length);
      expect(p, isNotEmpty);
      final (midi, counts) = await e.midi(l);
      expect(midi.length, greaterThan(20));
      expect(counts, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
