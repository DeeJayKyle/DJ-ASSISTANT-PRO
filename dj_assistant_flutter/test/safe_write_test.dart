import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/core/blake3.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/safe_write.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/tag_writer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'tag_writer_test.dart' show serateMp3, geobPayload;

/// Port of 1.x `safe_tag_writing_backs_up_verifies_and_rolls_back`, plus the
/// failure paths: whatever goes wrong, the original stays byte-identical.
void main() {
  late Directory tmp, music;
  late Catalogue cat;
  late SafeWriteService sw;
  late File target;
  late int id;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('dja-safe-');
    music = Directory(p.join(tmp.path, 'Music'))..createSync();
    target = serateMp3(music, 3);
    cat = Catalogue.open(p.join(tmp.path, 'data', 'catalogue.sqlite3'));
    RootsService(cat).add(music.path);
    await runScan(cat);
    id = cat.db.select('SELECT id FROM tracks').first['id'] as int;
    sw = SafeWriteService(cat, p.join(tmp.path, 'data'));
  });
  tearDown(() {
    cat.close();
    tmp.deleteSync(recursive: true);
  });

  bool containsGeob(File f) {
    final s = latin1.decode(f.readAsBytesSync(), allowInvalid: true);
    return s.contains('GEOB') &&
        s.contains(
          latin1.decode(geobPayload.sublist(40, 80), allowInvalid: true),
        );
  }

  test('off by default; preview, apply, verified backup, exact rollback', () {
    expect(
      () => sw.preview([id], {'genre': 'Afro Pop'}),
      throwsA(isA<SafeWriteException>()),
    );
    cat.setSetting('allow_file_changes', '1');
    final original = target.readAsBytesSync();
    final audioBefore = audioHash(target.path, 'mp3');

    final plan = sw.preview([id], {'genre': 'Afro Pop', 'bpm': '105'});
    expect(plan.single.changes['genre'], (null, 'Afro Pop'));
    expect(plan.single.changes['bpm'], ('104', '105'));
    expect(plan.single.warnings.first, contains('Serato'));
    expect(
      target.readAsBytesSync(),
      original,
      reason: 'a preview writes nothing',
    );

    final res = sw.apply(plan);
    expect(res.single['status'], 'done', reason: '$res');
    expect(audioHash(target.path, 'mp3'), audioBefore);
    expect(
      containsGeob(target),
      isTrue,
      reason: 'the Serato GEOB frame must survive',
    );
    final now = readWritableTags(target.path, 'mp3');
    expect(now['genre'], 'Afro Pop');
    expect(now['bpm'], '105');
    final log = sw.log();
    final backup = log.first['backup_path'] as String;
    expect(
      File(backup).readAsBytesSync(),
      original,
      reason: 'the backup is the exact original',
    );
    expect(log.first['changes'], {
      'bpm': ['104', '105'],
      'genre': [null, 'Afro Pop'],
    });
    expect(
      Directory(music.path)
          .listSync()
          .where((e) => p.basename(e.path).startsWith('.')),
      isEmpty,
      reason: 'no temporary files are left behind',
    );

    // The file changed since the preview: refused, nothing written.
    final plan2 = sw.preview([id], {'genre': 'X'});
    final edited = target.readAsBytesSync();
    target.writeAsBytesSync([...edited, 0]);
    final res2 = sw.apply(plan2);
    expect(res2.single['status'], 'failed');
    expect(res2.single['message'], contains('changed since the preview'));
    expect(target.readAsBytesSync(), [...edited, 0]);

    // Rollback refuses while the file differs from what was written…
    final change = log.first['id'] as int;
    expect(() => sw.rollback(change), throwsA(isA<SafeWriteException>()));
    // …and restores the exact original bytes once it matches again.
    target.writeAsBytesSync(edited);
    sw.rollback(change);
    expect(
      target.readAsBytesSync(),
      original,
      reason: 'rollback restores the exact original bytes',
    );
    expect(
      () => sw.rollback(change),
      throwsA(isA<SafeWriteException>()),
      reason: 'only once',
    );
    expect(sw.log().first['action'], 'rollback');
  });

  test('a write that cannot be verified leaves the original untouched', () {
    cat.setSetting('allow_file_changes', '1');
    // Make the tag unreadable for the writer: a damaged frame inside the tag.
    final b = target.readAsBytesSync();
    final broken = [...b];
    broken[10] = 0x01; // first frame id becomes invalid
    target.writeAsBytesSync(broken);
    final plan = sw.preview([id], {'title': 'New'});
    expect(plan.single.blocked, contains('Cannot write tags'));
    expect(sw.apply(plan).single['status'], 'skipped');
    expect(target.readAsBytesSync(), broken);
  });

  test(
    'blocked cases: missing file, unsupported format, nothing to change',
    () {
      cat.setSetting('allow_file_changes', '1');
      final same = sw.preview([id], {'bpm': '104'});
      expect(same.single.blocked, contains('Nothing to change'));
      cat.db.execute("UPDATE tracks SET presence='missing' WHERE id=?", [id]);
      expect(
        sw.preview([id], {'bpm': '1'}).single.blocked,
        contains('missing'),
      );
      cat.db.execute(
        "UPDATE tracks SET presence='present', path=? WHERE id=?",
        [p.join(music.path, 'x.wav'), id],
      );
      expect(
        sw.preview([id], {'bpm': '1'}).single.blocked,
        contains('not supported'),
      );
      expect(
        () => sw.preview([id], {'label': 'x'}),
        throwsA(isA<SafeWriteException>()),
      );
    },
  );

  test('rolls back a change logged by 1.x (same BLAKE3 hashes, same log)', () {
    cat.setSetting('allow_file_changes', '1');
    final original = target.readAsBytesSync();
    final backup = File(p.join(tmp.path, 'data', 'old-backup.mp3'))
      ..writeAsBytesSync(original);
    writeTagsInPlace(target.path, 'mp3', {'genre': 'Changed by 1.x'});
    cat.db.execute(
      "INSERT INTO change_log(track_id, path, action, changes_json, backup_path, before_hash, after_hash, status, at) VALUES (?,?,'tag_write',?,?,?,?,'done',?)",
      [
        id,
        target.path,
        '{"genre":[null,"Changed by 1.x"]}',
        backup.path,
        blake3File(backup.path),
        blake3File(target.path),
        1,
      ],
    );
    sw.rollback(cat.db.lastInsertRowId);
    expect(target.readAsBytesSync(), original);
  });

  test('catalogue values and estimates are previewed for writing', () {
    cat.setSetting('allow_file_changes', '1');
    cat.db.execute(
      'INSERT INTO track_user(track_id, title, genre, updated_at) VALUES (?, ?, ?, 0)',
      [id, 'Sunrise Groove (Edit)', 'Afro House'],
    );
    final plan = sw.previewFromCatalogue([id]);
    expect(plan.single.changes['title'], (
      'Sunrise Groove',
      'Sunrise Groove (Edit)',
    ));
    expect(plan.single.changes['genre'], (null, 'Afro House'));
  });

  test('new copies are tagged without touching their audio', () {
    final copy = File(p.join(tmp.path, 'copy.mp3'));
    target.copySync(copy.path);
    final before = audioHash(copy.path, 'mp3');
    expect(
      SafeWriteService.tagNewCopy(copy.path, {
        'title': 'Clean name',
        'label': 'ignored',
      }),
      isTrue,
    );
    expect(audioHash(copy.path, 'mp3'), before);
    expect(readWritableTags(copy.path, 'mp3')['title'], 'Clean name');
    expect(
      SafeWriteService.tagNewCopy(p.join(tmp.path, 'x.wav'), {'title': 'x'}),
      isFalse,
    );
  });
}
