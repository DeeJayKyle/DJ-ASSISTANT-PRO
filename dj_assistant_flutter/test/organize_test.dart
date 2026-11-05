import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crates.dart';
import 'package:dj_assistant/core/organize.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary;

/// Port of 1.x `organiser_renames_moves_removes_and_undoes_with_previews`.
void main() {
  late Directory music;
  late Catalogue cat;
  late OrganizeService org;

  setUp(() async {
    music = copyLibrary();
    cat = Catalogue.open(
      p.join(music.parent.path, 'data', 'catalogue.sqlite3'),
    );
    RootsService(cat).add(music.path);
    await runScan(cat);
    org = OrganizeService(cat, p.join(music.parent.path, 'data'));
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  int idOf(String file) =>
      cat.db.select('SELECT id FROM tracks WHERE file_name=?', [
            file,
          ]).first['id']
          as int;
  String pathOf(int id) =>
      cat.db.select('SELECT path FROM tracks WHERE id=?', [id]).first['path']
          as String;
  int presentCount() =>
      cat.db
              .select(
                "SELECT COUNT(*) AS n FROM tracks WHERE presence='present'",
              )
              .first['n']
          as int;

  test('names are safe on Windows; templates fill and validate', () {
    expect(sanitizeName('AC/DC: Back <In> Black?'), 'AC DC Back In Black');
    expect(sanitizeName('  trailing dots... '), 'trailing dots');
    expect(sanitizeName('CON'), 'CON_');
    expect(sanitizeName('a\u0000b'), 'a b');
    final f = {'artist': 'Lagos Lights', 'title': 'Sunrise Groove'};
    expect(
      renderTemplate('{artist} - {title}', f),
      'Lagos Lights - Sunrise Groove',
    );
    expect(
      () => renderTemplate('{genre}/{artist}', f),
      throwsA(isA<FormatException>()),
    );
  });

  test('rename, move, folder rename, remove, replace and undo', () async {
    final total = presentCount();
    final a = idOf('Deep Tenant - Warehouse 94.mp3');
    final b = idOf('Basement Hours.mp3');
    expect(
      () => org.previewRename([a], '{artist} - {title}'),
      throwsA(predicate((e) => '$e'.contains('turned off'))),
    );
    cat.setSetting('allow_file_changes', '1');
    expect(
      () => org.previewRename([a], '{artist} - {nope}'),
      throwsA(isA<OrganizeException>()),
    );

    // Rename "{artist} - {title}".
    var plan = org.previewRename([a, b], '{artist} - {title}');
    expect(plan.warning, contains('Serato'));
    expect(
      plan.ops.any((o) => o.to.endsWith('Deep Tenant - Basement Hours.mp3')),
      isTrue,
    );
    var r = org.apply(plan);
    expect(r.done, greaterThanOrEqualTo(1));
    final oldSchool = p.join(music.path, 'House', 'Old School');
    expect(
      File(p.join(oldSchool, 'Deep Tenant - Basement Hours.mp3')).existsSync(),
      isTrue,
    );
    expect(File(p.join(oldSchool, 'Basement Hours.mp3')).existsSync(), isFalse);
    expect(
      cat.db.select('SELECT file_name FROM tracks WHERE id=?', [
        b,
      ]).first['file_name'],
      'Deep Tenant - Basement Hours.mp3',
    );
    // A rescan sees the renamed files as the same tracks.
    final rescan = await runScan(cat);
    expect(rescan.added, 0);
    expect(presentCount(), total);
    org.undo(batch: r.batch);
    expect(File(p.join(oldSchool, 'Basement Hours.mp3')).existsSync(), isTrue);

    // Move into "{genre}/{artist}".
    plan = org.previewMove([a], '{genre}/{artist}');
    r = org.apply(plan);
    expect(r.done, 1);
    final moved = pathOf(a);
    expect(
      File(moved).existsSync() && moved.contains('Deep Tenant'),
      isTrue,
      reason: moved,
    );
    org.undo(batch: r.batch);
    expect(
      File(p.join(oldSchool, 'Deep Tenant - Warehouse 94.mp3')).existsSync(),
      isTrue,
    );

    // Rename a folder; its tracks follow.
    plan = org.previewFolderRename(oldSchool, 'Classics');
    expect(plan.ops.single.tracks, 2);
    r = org.apply(plan);
    expect(
      File(p.join(music.path, 'House', 'Classics', 'Basement Hours.mp3'))
          .existsSync(),
      isTrue,
    );
    expect(pathOf(b), contains('Classics'));
    org.undo(batch: r.batch);
    expect(File(p.join(oldSchool, 'Basement Hours.mp3')).existsSync(), isTrue);
    expect(pathOf(b), contains('Old School'));
    // A music folder itself can't be renamed.
    expect(
      () => org.previewFolderRename(music.path, 'X'),
      throwsA(isA<OrganizeException>()),
    );

    // Bad files go to the restorable "Removed files" area.
    final bad = org.badFiles();
    expect(bad.length, greaterThanOrEqualTo(2));
    r = org.apply(org.previewRemove(bad));
    expect(r.done, bad.length);
    expect(
      File(p.join(music.path, 'Broken', 'corrupt.mp3')).existsSync(),
      isFalse,
    );
    expect(Directory(org.removedArea).existsSync(), isTrue);
    expect(org.removedSummary()['files'], bad.length);
    expect(
      cat.db
          .select("SELECT removed_at FROM tracks WHERE file_name='corrupt.mp3'")
          .first['removed_at'],
      isNotNull,
    );
    org.undo(batch: r.batch);
    expect(
      File(p.join(music.path, 'Broken', 'corrupt.mp3')).existsSync(),
      isTrue,
    );
    // Remove again and empty the area for good.
    org.apply(org.previewRemove(org.badFiles()));
    expect(org.emptyRemoved(), bad.length);
    expect(
      File(p.join(music.path, 'Broken', 'corrupt.mp3')).existsSync(),
      isFalse,
    );
    expect(
      Directory(org.removedArea).listSync(),
      isEmpty,
      reason: 'empty batch folders are tidied',
    );

    // Replace duplicates: crates follow the kept copy, the other is removed.
    final keep = idOf('Lagos Lights - Sunrise Groove.mp3');
    final other = idOf('Sunrise Groove (copy).mp3');
    final crates = CratesService(cat);
    final c = crates.create(
      const CrateInput(name: 'Dupes test', kind: 'manual'),
    );
    crates.addTracks(c.id, [other]);
    org.apply(org.previewReplace(keep, [other]));
    final inCrate = cat.db
        .select('SELECT track_id FROM crate_tracks WHERE crate_id=?', [c.id])
        .map((r) => r['track_id'])
        .toList();
    expect(inCrate, contains(keep));
    expect(
      File(p.join(music.path, 'Copies', 'Sunrise Groove (copy).mp3'))
          .existsSync(),
      isFalse,
    );

    // A file changed since the preview is skipped, not overwritten.
    plan = org.previewRename([b], '{artist} - {title}');
    File(p.join(oldSchool, 'Basement Hours.mp3')).writeAsStringSync('changed');
    r = org.apply(plan);
    expect(r.done, 0);
    expect(r.skipped.first.$2, contains('changed'));
    expect(org.history().isNotEmpty, isTrue);
  });

  test(
    'two files aiming at one name block each other; existing targets block',
    () {
      cat.setSetting('allow_file_changes', '1');
      final x = idOf('Intro (album A).mp3'), y = idOf('Intro (album B).mp3');
      final plan = org.previewRename([x, y], '{artist} - {title}');
      expect(plan.ready, 0);
      expect(plan.ops.every((o) => o.blocked!.contains('same name')), isTrue);
      final z = idOf('Sunrise Groove (copy).mp3');
      final target = org.previewRename([z], '{artist} - {title}').ops.single.to;
      File(target).writeAsStringSync('someone else');
      final clash = org.previewRename([z], '{artist} - {title}');
      expect(clash.ops.single.blocked, contains('already exists'));
    },
  );
}
