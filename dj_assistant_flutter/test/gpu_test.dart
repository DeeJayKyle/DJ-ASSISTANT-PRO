import 'dart:typed_data';

import 'package:dj_assistant/studio/gpu.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List desc(String name, int vendor, int device, int flags) {
  final b = ByteData(312);
  for (var i = 0; i < name.length; i++) {
    b.setUint16(i * 2, name.codeUnitAt(i), Endian.little);
  }
  b
    ..setUint32(256, vendor, Endian.little)
    ..setUint32(260, device, Endian.little)
    ..setUint32(304, flags, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  test('a hardware graphics card is used for Pro Stems AI', () {
    expect(
      describe(desc('NVIDIA GeForce RTX 4060', 0x10de, 0x2882, 0)),
      'NVIDIA GeForce RTX 4060',
    );
  });
  test('software renderers are not', () {
    expect(
      describe(desc('Microsoft Basic Render Driver', 0x1414, 0x8c, 0)),
      isNull,
    );
    expect(describe(desc('Some adapter', 0x1234, 1, 2)), isNull);
  });
  test('no graphics card off Windows', () {
    expect(hardwareGpu(), isNull);
  }, testOn: '!windows');
}
