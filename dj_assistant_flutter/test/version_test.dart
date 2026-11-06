import 'dart:io';

import 'package:dj_assistant/online/http_online.dart' show appVersion;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the version the app reports matches pubspec.yaml', () {
    // The updater compares appVersion with latest.json: if they drift, an
    // installed release offers itself as an update.
    final v = RegExp(
      r'^version:\s*([0-9.]+)',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(appVersion, v);
  });
}
