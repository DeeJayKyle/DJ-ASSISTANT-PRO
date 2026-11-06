import 'dart:io';

import 'package:dj_assistant/core/sysmem.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('free memory can be read on this OS', () {
    final b = availableMemoryBytes();
    expect(b, isNotNull);
    expect(b!, greaterThan(64 << 20));
    expect(gb(3 << 30), '3.0');
  }, skip: Platform.isLinux || Platform.isWindows ? null : 'Linux and Windows');
}
