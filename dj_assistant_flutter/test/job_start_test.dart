import 'dart:io';
import 'dart:isolate';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 2.0.3: "Get Pro Stems AI" stayed on Downloading forever. The job closure
/// was written inline in the Settings page, so it captured the page's state;
/// Isolate.spawn refused it, nothing caught that, and the job stayed
/// "running" without downloading a byte.
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('dja_jobs'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a job that cannot start fails with the reason, never hangs', () async {
    final jobs = JobsController();
    final unsendable = ReceivePort();
    final st = await jobs
        .start('x', (ctx) async => unsendable.hashCode)
        .timeout(const Duration(seconds: 10));
    unsendable.close();
    expect(st.state, 'failed');
    expect(st.message, contains("couldn't start"));
    expect(jobs.running('x'), isFalse);
  });

}
