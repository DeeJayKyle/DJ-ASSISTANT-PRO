import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/analysis/analysis.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Precision benchmark for tempo and key detection. Make the tracks with
/// `python3 tool/make_bench.py <dir> 80 45 7`, then run
/// `DJ_BENCH=<dir> flutter test test/precision_bench_test.dart`.
///
/// Tempo: exact = within 2 % (the reading a DJ sees), DJ = exact or the
/// half/double alternative offered, octave = any of ×½, ×1, ×2.
/// Key: exact, and the MIREX weighted score (exact 1, fifth 0.5, relative
/// 0.3, parallel 0.2), the usual measure for key detection.
void main() {
  final dir = Platform.environment['DJ_BENCH'];
  for (final withGenre in [false, true]) {
    test(
      'tempo and key precision${withGenre ? ' (genre tags known)' : ''}',
      () {
        final truth = (jsonDecode(
          File(p.join(dir!, 'truth.json')).readAsStringSync(),
        ) as Map).cast<String, Map<String, dynamic>>();
        var n = 0, tExact = 0, tDj = 0, tOct = 0, kExact = 0;
        var mirex = 0.0;
        final byGenre = <String, List<int>>{};
        final errors = <String>[];
        bool near(double a, double b) => (a - b).abs() <= 0.02 * b;
        for (final MapEntry(key: name, value: t) in truth.entries) {
          // as a DJ's library tags them
          final tag = const {
            'hiphop': 'Hip Hop',
            'rnb': 'R&B',
            'afro': 'Afrobeats',
            'amapiano': 'Amapiano',
            'house': 'House',
            'techno': 'Techno',
            'dnb': 'Drum & Bass',
            'dancehall': 'Dancehall',
          }['${t['genre']}'];
          final a = analyseFile(
            p.join(dir, name),
            genre: withGenre ? tag : null,
          );
          final bpm = (t['bpm'] as num).toDouble();
          final est = a.bpm, alt = a.bpmAlt;
          n++;
          final g = byGenre.putIfAbsent('${t['genre']}', () => [0, 0, 0]);
          g[0]++;
          final exact = est != null && near(est, bpm);
          final dj = exact || (alt != null && near(alt, bpm));
          final oct =
              est != null && [0.5, 1.0, 2.0].any((f) => near(est * f, bpm));
          if (exact) tExact++;
          if (dj) tDj++;
          if (oct) tOct++;
          if (exact) g[1]++;
          final want = '${t['camelot']}', got = a.camelot ?? '-';
          final s = keyScore(got, want);
          mirex += s;
          if (s == 1) {
            kExact++;
            g[2]++;
          }
          if (!exact || s < 1) {
            errors.add(
              '$name ${t['genre']}: bpm $bpm → $est'
              '${alt == null ? '' : ' (alt $alt)'}; key $want (${t['key']}, '
              '${t['progression']}, ${t['cents']}c) → $got',
            );
          }
        }
        String pc(int x) => '${(100 * x / n).toStringAsFixed(1)}%';
        // ignore: avoid_print
        print(
          [
            'tracks: $n${withGenre ? ' (genre tags known)' : ''}',
            'tempo exact: ${pc(tExact)}  with alternative: ${pc(tDj)}  octave: ${pc(tOct)}',
            'key exact: ${pc(kExact)}  MIREX: ${(100 * mirex / n).toStringAsFixed(1)}%',
            for (final MapEntry(:key, :value) in byGenre.entries)
              '  $key: ${value[0]} tracks, tempo ${value[1]}, key ${value[2]}',
            ...errors,
          ].join('\n'),
        );
      },
      skip: dir == null ? 'set DJ_BENCH to a benchmark folder' : null,
      timeout: const Timeout(Duration(minutes: 30)),
    );
  }
}

/// MIREX key score between two Camelot codes.
double keyScore(String got, String want) {
  if (got == want) return 1;
  final g = RegExp(r'^(\d+)([AB])$').firstMatch(got);
  final w = RegExp(r'^(\d+)([AB])$').firstMatch(want);
  if (g == null || w == null) return 0;
  final gn = int.parse(g[1]!), wn = int.parse(w[1]!);
  final sameLetter = g[2] == w[2];
  final d = ((gn - wn) % 12 + 12) % 12;
  if (sameLetter && (d == 1 || d == 11)) return 0.5; // a fifth away
  if (!sameLetter && gn == wn) return 0.3; // relative major/minor
  // parallel: same tonic, other mode (A minor 8A ↔ A major 11B: +3 / −3)
  if (!sameLetter && ((g[2] == 'A' && d == 3) || (g[2] == 'B' && d == 9))) {
    return 0.2;
  }
  return 0;
}
