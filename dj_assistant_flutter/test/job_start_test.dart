import 'dart:io';
import 'dart:isolate';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/assistant/quick_ai.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/packs.dart';
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

  test('the Pro Stems AI download job starts in its isolate', () async {
    final jobs = JobsController();
    // offline: the job starts, tries to download, and says what went wrong
    final st = await jobs
        .start(
          'pack:stems-ai',
          packInstallJob(dir.path, 'stems-ai', packDownloader(NoOnline.new)),
        )
        .timeout(const Duration(seconds: 30));
    expect(st.state, 'failed');
    expect(st.message, isNot(contains("couldn't start")));
    expect(st.message, contains('internet connection'));
  });

  test('the AI model download jobs start in their isolates', () async {
    final app = AppSession(
      dbPath: p.join(dir.path, 'catalogue.sqlite3'),
      online: NoOnline(),
      secrets: MemorySecrets(),
      onlineFactory: NoOnline.new,
    );
    addTearDown(app.close);
    final ai = AiHelpers(app);
    ai.localPull('qwen2.5:7b');
    ai.packSetup('qwen2.5:7b');
    for (final kind in ['ai_model', 'ai_pack']) {
      for (var i = 0; i < 100 && app.jobs.running(kind); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        app.jobs.status(kind).message,
        isNot(contains("couldn't start")),
        reason: kind,
      );
    }
  });
}
