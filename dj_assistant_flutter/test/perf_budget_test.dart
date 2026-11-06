import 'dart:io';

import 'package:dj_assistant/studio/engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Performance budgets for the Stems page (Phase 5): with DJ_PERF_SONG set to
/// a full-length song, the Fast split must take less than the song's length
/// on 4 cores and the app must stay under 1.5 GB while splitting.
void main() {
  final song = Platform.environment['DJ_PERF_SONG'];
  test(
    'Fast split of a full song is faster than real time, under 1.5 GB',
    () async {
      final e = StudioEngine(cores: 4);
      var peak = ProcessInfo.currentRss;
      final sw = Stopwatch()..start();
      final l = await e.load(SongRef(id: 'p', title: 'p', path: song!));
      final decode = sw.elapsedMilliseconds;
      await e.separate(
        l,
        method: 'fast',
        onProgress: (_) {
          final r = ProcessInfo.currentRss;
          if (r > peak) peak = r;
        },
      );
      final total = sw.elapsedMilliseconds / 1000;
      final mb = ProcessInfo.maxRss / (1 << 20);
      // ignore: avoid_print
      print(
        'song ${l.durationSec.toStringAsFixed(0)} s: decode $decode ms, '
        'decode+split ${total.toStringAsFixed(1)} s, max RSS ${mb.round()} MB',
      );
      expect(total, lessThan(l.durationSec));
      expect(mb, lessThan(1536));
    },
    skip: song == null ? 'set DJ_PERF_SONG to a full-length song' : null,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
