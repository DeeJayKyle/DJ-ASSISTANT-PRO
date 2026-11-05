import 'dart:io';

import 'package:dj_assistant/core/autoprep.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/watcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

/// Ports of 1.x `folder_watcher_notices_new_files_without_touching_them` and
/// `auto_prep_analyses_and_applies_recommended_fixes_after_a_scan`.
void main() {
  late Directory music;
  late Catalogue cat;
  late String dbPath;
  setUp(() async {
    music = copyLibrary();
    dbPath = p.join(music.parent.path, 'catalogue.sqlite3');
    cat = Catalogue.open(dbPath);
    RootsService(cat).add(music.path);
    await runScan(cat);
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  test('the folder watcher notices new files without touching them', () async {
    final w = FolderWatcher(cat)..start();
    expect(w.watched, isNotEmpty);
    final newf = p.join(music.path, 'Afrobeats', 'New Download.mp3');
    File(p.join(music.path, 'Afrobeats', 'Night Market (Clean).mp3'))
        .copySync(newf);
    Map<String, Object?>? found;
    for (var i = 0; i < 40 && found == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      found = w
          .pending()
          .where((x) => (x['path'] as String).endsWith('New Download.mp3'))
          .firstOrNull;
    }
    expect(found, isNotNull, reason: 'the watcher did not report the new file');
    expect(found!['kind'], 'new');
    expect(found['suggested_folder'] as String, contains('Afrobeats'));
    w.clear();
    expect(w.pending(), isEmpty);
    w.stop();
  });

  test(
    'auto-prep analyses and applies recommended fixes, catalogue only',
    () async {
      final before = hashes(music);
      final jobs = JobsController();
      final st = await jobs.start('auto_prep', autoPrepJob(dbPath));
      expect(st.state, 'completed', reason: '${st.message}');
      final r = st.result! as Map;
      expect(r['analysed'] as int, greaterThanOrEqualTo(10));
      expect(r['fixes_applied'] as int, greaterThanOrEqualTo(1));
      final after = r['missing_after'] as Map, was = r['missing_before'] as Map;
      // Analysis fills keys where tags had none (lossless files decode here; MP3/AAC on Windows).
      expect(after['missing_key'] as int, lessThan(was['missing_key'] as int));
      expect(
        after['missing_genre'] as int,
        lessThan(was['missing_genre'] as int),
      );
      final lib = LibraryService(cat);
      int idOf(String f) =>
          cat.db.select('SELECT id FROM tracks WHERE file_name=?', [
                f,
              ]).first['id']
              as int;
      expect(lib.row(idOf('Roller Rink.opus'))!.genre, 'House');
      expect(
        lib.row(idOf('untagged recording.wav'))!.title,
        'untagged recording',
      );
      expect(hashes(music), before, reason: 'only the catalogue changed');
      expect(autoFixMin(cat), 0.85);
      cat.setSetting('auto_fix_min', '2');
      expect(autoFixMin(cat), 0.85, reason: 'out-of-range values fall back');
      await jobs.shutdown();
    },
  );
}
