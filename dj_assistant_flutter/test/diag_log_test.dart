import 'dart:io';

import 'package:dj_assistant/core/diag_log.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('diag'));
  tearDown(() {
    DiagLog.reset();
    dir.deleteSync(recursive: true);
  });

  test('writes errors with their stack trace to <data>/logs', () {
    DiagLog.init(dir.path);
    try {
      throw StateError('boom');
    } on StateError catch (e, st) {
      DiagLog.error('stems', e, st);
    }
    final text = File(p.join(dir.path, 'logs', 'dj-assistant.log'))
        .readAsStringSync();
    expect(text, contains('INFO [app] started'));
    expect(text, contains('ERROR [stems] Bad state: boom'));
    expect(text, contains('diag_log_test.dart'));
  });

  test('rotates and keeps three older files', () {
    DiagLog.init(dir.path);
    final line = 'x' * 1000;
    for (var i = 0; i < 5000; i++) {
      DiagLog.info('t', line);
    }
    final names = Directory(
      p.join(dir.path, 'logs'),
    ).listSync().map((e) => p.basename(e.path)).toList()..sort();
    expect(names, [
      'dj-assistant.log',
      'dj-assistant.log.1',
      'dj-assistant.log.2',
      'dj-assistant.log.3',
    ]);
    expect(
      File(p.join(dir.path, 'logs', 'dj-assistant.log')).lengthSync(),
      lessThanOrEqualTo(DiagLog.maxBytes + 2000),
    );
  });

  test('does nothing before init', () {
    DiagLog.info('t', 'nowhere');
    expect(DiagLog.folder, isNull);
  });
}
