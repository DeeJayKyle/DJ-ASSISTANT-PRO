import 'dart:isolate';

import 'package:dj_assistant/studio/engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Stems, Remix and DJ pages pass progress callbacks that hold their
/// widget state. Nothing a page holds may be dragged into the separation
/// isolates (a [ReceivePort] stands in for any object that can't be sent).
void main() {
  const song = SongRef(
    id: 'f32',
    title: 'f32',
    path: 'test/fixtures/audio/f32.wav',
  );

  test(
    'fast split works with a callback that holds unsendable state',
    () async {
      final engine = StudioEngine(cores: 2);
      final l = await engine.load(song);
      final unsendable = ReceivePort();
      var last = 0.0;
      final stems = await engine.separate(
        l,
        method: 'fast',
        onProgress: (f) {
          unsendable.hashCode;
          last = f;
        },
      );
      unsendable.close();
      expect(stems.keys, containsAll(['vocals', 'drums', 'bass', 'melodies']));
      expect(stems['bass']![0].length, l.mix[0].length);
      expect(last, greaterThan(0.9));
    },
  );

  test(
    'a failed AI run falls back to fast stems with a page callback',
    () async {
      final engine = StudioEngine(cores: 2)..aiModel = '/no/such/model.onnx';
      final l = await engine.load(song);
      final unsendable = ReceivePort();
      final err = await engine
          .separate(l, method: 'ai', onProgress: (f) => unsendable.hashCode)
          .then<Object?>((_) => null, onError: (Object e) => e);
      unsendable.close();
      // The missing model must be reported, and the fast stems used instead.
      expect(err, isA<StudioException>());
      expect((err! as StudioException).fallback, isTrue);
      expect('$err', isNot(contains('unsendable')));
      expect(l.stemsBy, 'fast');
    },
  );
}
