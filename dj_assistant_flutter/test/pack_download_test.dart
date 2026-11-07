import 'dart:io';

import 'package:dj_assistant/app/session.dart' show defaultOnline;
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/packs.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real Pro Stems AI download, exactly as Settings → Packs → Get runs it
/// (job isolate, the app's HTTP client, checksum, install). Runs when
/// DJ_PACK_DOWNLOAD is set (Windows CI); it fetches 180 MB.
void main() {
  test(
    'Get Pro Stems AI downloads, verifies and installs the pack',
    () async {
      final dir = Directory.systemTemp.createTempSync('dja_pack');
      addTearDown(() => dir.deleteSync(recursive: true));
      final jobs = JobsController();
      final st = await jobs
          .start(
            'pack:stems-ai',
            packInstallJob(dir.path, 'stems-ai', packDownloader(defaultOnline)),
          )
          .timeout(const Duration(minutes: 15));
      expect(st.state, 'completed', reason: st.message);
      expect(packInstalled(dir.path, packById('stems-ai')!), isTrue);
    },
    skip: Platform.environment['DJ_PACK_DOWNLOAD'] == null
        ? 'set DJ_PACK_DOWNLOAD to download the 180 MB pack'
        : null,
    timeout: const Timeout(Duration(minutes: 16)),
  );
}
