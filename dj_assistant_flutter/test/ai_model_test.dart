import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dj_assistant/studio/ai_stems.dart';
import 'package:dj_assistant/studio/engine.dart';
import 'package:dj_assistant/studio/onnx_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pro Stems AI with the real model (HTDemucs through ONNX Runtime). Runs when
/// DJ_AI_MODEL names `htdemucs_embedded.onnx`: in the Windows CI job (the
/// model is downloaded from the pack's URL and cached) or on a dev machine.
void main() {
  final model = Platform.environment['DJ_AI_MODEL'];
  final skip = model == null || !File(model).existsSync()
      ? 'set DJ_AI_MODEL to htdemucs_embedded.onnx'
      : null;

  // 10 s of a bass line, a lead and a kick at 44.1 kHz.
  List<Float32List> clip() {
    const n = aiSr * 10;
    final l = Float32List(n), r = Float32List(n);
    for (var i = 0; i < n; i++) {
      final t = i / aiSr;
      final kick = math.exp(-((t % 0.5) * 30)) * math.sin(2 * math.pi * 55 * t);
      final bass = 0.3 * math.sin(2 * math.pi * 82.4 * t);
      final lead = 0.2 * math.sin(2 * math.pi * 659 * t);
      l[i] = (0.4 * kick + bass + lead).toDouble();
      r[i] = (0.4 * kick + bass + 0.8 * lead).toDouble();
    }
    return [l, r];
  }

  test(
    'the model loads and has the inputs 2.0 feeds it',
    () {
      final m = HtDemucs.open(model!);
      try {
        expect(m.inputNames.length, inInclusiveRange(1, 2));
        final (freq, time) = m.run(
          Float32List(2 * seg),
          Float32List(4 * bins * frames),
        );
        expect(time.length, 4 * 2 * seg);
        if (freq != null) expect(freq.length, 4 * 4 * bins * frames);
      } finally {
        m.close();
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'the engine splits a song with the model, without falling back',
    () async {
      final engine = StudioEngine(cores: 2)..aiModel = model;
      final mix = clip();
      final l = Loaded(
        const SongRef(id: 'ai', title: 'ai', path: ''),
        aiSr,
        mix,
      );
      final progress = <double>[];
      final sw = Stopwatch()..start();
      final stems = await engine.separate(
        l,
        method: 'ai',
        onProgress: progress.add,
      );
      // ignore: avoid_print
      print('AI split of 10 s: ${sw.elapsedMilliseconds} ms');
      expect(l.stemsBy, 'ai');
      expect(stems.keys, containsAll(['vocals', 'drums', 'bass', 'melodies']));
      for (final s in stems.values) {
        expect(s.length, 2);
        expect(s[0].length, mix[0].length);
        expect(s[0].every((x) => x.isFinite), isTrue);
      }
      // The stems add back up to the mix (HTDemucs is close to energy-preserving).
      var err = 0.0, ref = 0.0;
      for (var i = 0; i < mix[0].length; i += 7) {
        final sum = stems.values.fold(0.0, (a, s) => a + s[0][i]);
        err += (sum - mix[0][i]) * (sum - mix[0][i]);
        ref += mix[0][i] * mix[0][i];
      }
      expect(err / ref, lessThan(0.1));
      expect(progress.last, closeTo(1, 1e-9));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
