import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dj_assistant/core/blake3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// BLAKE3 must equal 1.x exactly: change-log hashes (rollback) and duplicate
/// content hashes written by 1.x are compared against it.
void main() {
  final golden =
      jsonDecode(File('test/golden/blake3.json').readAsStringSync()) as Map;

  test('the published empty-input hash', () {
    expect(
      blake3Hex(const []),
      'af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262',
    );
  });

  test('every chunk and tree boundary matches 1.x', () {
    for (final e in (golden['lengths'] as Map).entries) {
      final n = int.parse(e.key as String);
      final input = Uint8List(n);
      for (var i = 0; i < n; i++) {
        input[i] = i % 251;
      }
      expect(blake3Hex(input), e.value, reason: 'length $n');
      // Fed in awkward pieces, the result must not change.
      final h = Blake3();
      for (var i = 0; i < n; i += 37) {
        h.add(Uint8List.sublistView(input, i, i + 37 > n ? n : i + 37));
      }
      expect(h.hexDigest(), e.value, reason: 'length $n, incremental');
    }
  });

  test('whole files hash as in 1.x', () {
    for (final e in (golden['files'] as Map).entries) {
      final path = p.join(
        '..',
        'crates',
        'dj-core',
        'tests',
        'fixtures',
        e.key as String,
      );
      expect(blake3File(path), e.value, reason: e.key as String);
    }
  });
}
