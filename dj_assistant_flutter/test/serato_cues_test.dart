import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dj_assistant/core/serato_cues.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'serato_tags_test.dart' show flac, flacValue, geob, mp3;

const markers = SeratoMarkers(
  trackColor: 0xFF99FF,
  bpmLocked: true,
  cues: [
    SeratoCue(slot: 1, positionMs: 512, color: 0xCC0000, name: 'Intro'),
    SeratoCue(slot: 4, positionMs: 61250, color: 0x00CC00, name: 'Drop ✓'),
  ],
  loops: [
    SeratoCue(
      slot: 1,
      positionMs: 30000,
      endMs: 37742,
      color: 0x27AAE1,
      locked: true,
      name: 'Vox',
    ),
  ],
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('serato_cues'));
  tearDown(() => dir.deleteSync(recursive: true));

  void expectMarkers(SeratoMarkers m) {
    expect(m.trackColor, 0xFF99FF);
    expect(m.bpmLocked, isTrue);
    expect(
      [for (final c in m.cues) (c.slot, c.positionMs, c.name)],
      [(1, 512, 'Intro'), (4, 61250, 'Drop ✓')],
    );
    expect(m.cues.first.colorHex, '#CC0000');
    final l = m.loops.single;
    expect(
      (l.slot, l.positionMs, l.endMs, l.locked, l.name),
      (1, 30000, 37742, true, 'Vox'),
    );
  }

  test('round trip through the tag encoding', () {
    expectMarkers(parseSeratoMarkers2Tag(encodeSeratoMarkers2Tag(markers)));
  });

  test('reads hot cues and loops from an MP3 without changing it', () {
    final f = File(p.join(dir.path, 'a.mp3'))
      ..writeAsBytesSync(
        mp3([
          ('GEOB', geob('Serato Markers2', encodeSeratoMarkers2Tag(markers))),
        ]),
      );
    final before = f.readAsBytesSync();
    expectMarkers(readSeratoMarkers(f.path));
    expect(f.readAsBytesSync(), before);
  });

  test('reads them from a FLAC', () {
    final f = File(p.join(dir.path, 'b.flac'))
      ..writeAsBytesSync(
        flac([
          'SERATO_MARKERS_V2=${flacValue('Serato Markers2', encodeSeratoMarkers2Tag(markers))}',
        ]),
      );
    expectMarkers(readSeratoMarkers(f.path));
  });

  test('unknown entries are skipped; damage keeps what came before', () {
    final body = BytesBuilder()..add([1, 1]);
    void entry(String n, List<int> d) => body
      ..add(latin1.encode(n))
      ..addByte(0)
      ..add((ByteData(4)..setUint32(0, d.length)).buffer.asUint8List())
      ..add(d);
    entry('FLIP', [1, 2, 3]);
    entry('CUE', [0, 2, 0, 0, 3, 232, 0, 255, 0, 0, 0, 0, 0]);
    body.add([...latin1.encode('CUE'), 0, 0, 0, 0, 99]); // overruns the body
    final m = parseSeratoMarkers2Body(body.toBytes());
    expect(m.cues.single.slot, 3);
    expect(m.cues.single.positionMs, 1000);
    expect(m.cues.single.colorHex, '#FF0000');
  });

  test('garbage and missing data give no markers', () {
    expect(parseSeratoMarkers2Tag(Uint8List.fromList([9, 9, 9])).isEmpty, true);
    expect(readSeratoMarkers(p.join(dir.path, 'missing.mp3')).isEmpty, true);
  });
}
