import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dj_assistant/analysis/analysis.dart';
import 'package:dj_assistant/analysis/key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'precision_bench_test.dart' show keyScore;

const _minorCam = [
  '5A',
  '12A',
  '7A',
  '2A',
  '9A',
  '4A',
  '11A',
  '6A',
  '1A',
  '8A',
  '3A',
  '10A',
];
const _majorCam = [
  '8B',
  '3B',
  '10B',
  '5B',
  '12B',
  '7B',
  '2B',
  '9B',
  '4B',
  '11B',
  '6B',
  '1B',
];

void main() {
  final dirs = (Platform.environment['DJ_SWEEP'] ?? '')
      .split(',')
      .where((x) => x.isNotEmpty)
      .toList();
  test(
    'key sweep',
    () {
      final sets = <String, List<(Float32List, double, String)>>{};
      for (final dir in dirs) {
        final truth = (jsonDecode(
          File(p.join(dir, 'truth.json')).readAsStringSync(),
        ) as Map);
        sets[dir] = [
          for (final MapEntry(:key, :value) in truth.entries)
            () {
              final d = decode(p.join(dir, key as String));
              final (x, sr) = downsampleForAnalysis(d.mono, d.sampleRate);
              return (x, sr, '${(value as Map)['camelot']}');
            }(),
        ];
      }
      final lines = <String>[];
      for (final n in [4096, 8192]) {
        for (final c in [0.5, 1.0]) {
          for (final norm in [true, false]) {
            final base = KeyParams(fftSize: n, compress: c, frameNorm: norm);
            final sal = {
              for (final e in sets.entries)
                e.key: [
                  for (final t in e.value)
                    (noteSalience(t.$1, t.$2, base)?.$1, t.$3),
                ],
            };
            for (final prof in keyProfiles.keys) {
              for (final h3 in [0.0, 0.2, 0.35, 0.5]) {
                for (final h5 in [0.0, 0.2]) {
                  for (final bw in [0.0, 0.3, 0.6]) {
                    final kp = KeyParams(
                      profile: prof,
                      h3: h3,
                      h5: h5,
                      bassWeight: bw,
                      fftSize: n,
                      compress: c,
                      frameNorm: norm,
                    );
                    final res = <String>[];
                    for (final e in sal.entries) {
                      var ex = 0, mirex = 0.0;
                      for (final (s, want) in e.value) {
                        if (s == null) continue;
                        final k = bestKey(chromaFromSalience(s, kp), prof);
                        final got = k == null
                            ? '-'
                            : (k.$2 ? _minorCam : _majorCam)[k.$1];
                        final sc = keyScore(got, want);
                        mirex += sc;
                        if (sc == 1) ex++;
                      }
                      res.add(
                        '${(100 * ex / e.value.length).toStringAsFixed(1)}/${(100 * mirex / e.value.length).toStringAsFixed(1)}',
                      );
                    }
                    lines.add('${res.join('  ')}  $kp');
                  }
                }
              }
            }
          }
        }
      }
      File(Platform.environment['DJ_SWEEP_OUT']!)
          .writeAsStringSync(lines.join('\n'));
    },
    skip: dirs.isEmpty ? 'set DJ_SWEEP' : null,
    timeout: const Timeout(Duration(minutes: 60)),
  );
}
