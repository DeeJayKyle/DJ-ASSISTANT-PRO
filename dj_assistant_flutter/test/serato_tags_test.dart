import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dj_assistant/core/serato_tags.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List be32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.big)).buffer.asUint8List();
Uint8List le32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

/// A GEOB frame body (Latin-1 text).
List<int> geob(String desc, List<int> data) => [
  0,
  ...ascii.encode('application/octet-stream'),
  0,
  0, // empty file name
  ...latin1.encode(desc),
  0,
  ...data,
];

/// An MP3 with an ID3v2.3 tag holding [frames] (id, body) and fake audio.
Uint8List mp3(List<(String, List<int>)> frames) {
  final body = <int>[];
  for (final (id, b) in frames) {
    body
      ..addAll(ascii.encode(id))
      ..addAll(be32(b.length))
      ..addAll([0, 0])
      ..addAll(b);
  }
  body.addAll(List.filled(64, 0)); // padding
  final n = body.length;
  return Uint8List.fromList([
    ...ascii.encode('ID3'),
    3,
    0,
    0,
    (n >> 21) & 0x7f,
    (n >> 14) & 0x7f,
    (n >> 7) & 0x7f,
    n & 0x7f,
    ...body,
    0xFF, 0xFB, 0x90, 0x64, ...List.filled(400, 0), // a fake MPEG frame
  ]);
}

/// A FLAC with STREAMINFO and a Vorbis comment block.
Uint8List flac(List<String> comments) {
  final vc = <int>[
    ...le32(4),
    ...ascii.encode('test'),
    ...le32(comments.length),
  ];
  for (final c in comments) {
    final b = utf8.encode(c);
    vc
      ..addAll(le32(b.length))
      ..addAll(b);
  }
  return Uint8List.fromList([
    ...ascii.encode('fLaC'),
    0, 0, 0, 34, ...List.filled(34, 0), // STREAMINFO
    0x84, (vc.length >> 16) & 0xff, (vc.length >> 8) & 0xff, vc.length & 0xff,
    ...vc,
  ]);
}

String flacValue(String name, List<int> data) {
  final b64 = base64.encode([
    ...ascii.encode('application/octet-stream'),
    0,
    0,
    ...ascii.encode(name),
    0,
    ...data,
  ]);
  // Serato wraps the base64 text and drops its padding
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 72) {
    lines.add(b64.substring(i, i + 72 > b64.length ? b64.length : i + 72));
  }
  return lines.join('\n').replaceAll('=', '');
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('serato_tags'));
  tearDown(() => dir.deleteSync(recursive: true));

  final autotags = [
    1,
    1,
    ...ascii.encode('124.00'),
    0,
    ...ascii.encode('-1.234'),
    0,
  ];

  test('reads a steady Serato grid and BPM from an MP3', () {
    final grid = encodeSeratoBeatGrid([], 0.512, 124);
    final f = File(p.join(dir.path, 'a.mp3'))
      ..writeAsBytesSync(
        mp3([
          ('TIT2', [0, ...ascii.encode('Song')]),
          ('GEOB', geob('Serato Autotags', autotags)),
          ('GEOB', geob('Serato BeatGrid', [...grid, 0])),
        ]),
      );
    final before = f.readAsBytesSync();
    final s = readSeratoAnalysis(f.path);
    expect(s.bpm, 124);
    final g = s.beatgrid!;
    expect(g.source, 'serato');
    expect(g.stable, isTrue);
    expect(g.bpm, 124);
    expect(g.markers.single.ms, 512);
    // one beat (0.4839 s) before the marker is the first grid line
    expect(g.firstBeatMs, closeTo(28, 1));
    expect(g.downbeatMs, 512);
    expect(f.readAsBytesSync(), before, reason: 'the file is only read');
  });

  test('reads a variable Serato grid from a FLAC', () {
    // 64 beats at 120 BPM from 0.1 s, then 126 BPM
    final grid = encodeSeratoBeatGrid([(0.1, 64)], 32.1, 126);
    final f = File(p.join(dir.path, 'b.flac'))
      ..writeAsBytesSync(
        flac([
          'TITLE=Song',
          'SERATO_BEATGRID=${flacValue('Serato BeatGrid', [...grid, 0])}',
          'SERATO_AUTOTAGS=${flacValue('Serato Autotags', autotags)}',
        ]),
      );
    final s = readSeratoAnalysis(f.path);
    expect(s.bpm, 124);
    final g = s.beatgrid!;
    expect(g.stable, isFalse);
    expect(g.markers, hasLength(2));
    expect(g.markers[0].bpm, closeTo(120, 0.01));
    expect(g.markers[1].bpm, 126);
    expect(g.markers[1].ms, 32100);
    expect(g.markers[1].beat, 1); // 64 beats = 16 bars
    expect(g.bpm, 126, reason: 'the last marker runs to the end');
  });

  test('files without Serato data, or with damaged data, give nothing', () {
    final plain = File(p.join(dir.path, 'c.mp3'))
      ..writeAsBytesSync(
        mp3([
          ('TIT2', [0, ...ascii.encode('x')]),
        ]),
      );
    expect(readSeratoAnalysis(plain.path).isEmpty, isTrue);
    final bad = File(p.join(dir.path, 'd.mp3'))
      ..writeAsBytesSync(
        mp3([
          ('GEOB', geob('Serato BeatGrid', [1, 0, 0, 0, 0, 9, 1, 2])),
        ]),
      );
    expect(readSeratoAnalysis(bad.path).beatgrid, isNull);
    expect(readSeratoAnalysis(p.join(dir.path, 'missing.mp3')).isEmpty, isTrue);
  });
}
