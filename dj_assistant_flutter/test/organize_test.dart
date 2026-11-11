import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crates.dart';
import 'package:dj_assistant/core/organize.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/blake3.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/serato_links.dart';
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
      throwsA(predicate((e) => '$e'.contains('mode is off'))),
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

  test('Organise Files mode: off by default, its own switch, legacy kept', () {
    final a = idOf('Deep Tenant - Warehouse 94.mp3');
    expect(organiseModeOn(cat), isFalse);
    expect(() => org.previewRemove([a]), throwsA(isA<OrganizeException>()));
    // A library that allowed file changes before keeps Organise available...
    cat.setSetting('allow_file_changes', '1');
    expect(organiseModeOn(cat), isTrue);
    // ...until Organise mode itself is switched off.
    cat.setSetting('organise_mode', '0');
    expect(organiseModeOn(cat), isFalse);
    cat
      ..setSetting('allow_file_changes', '0')
      ..setSetting('organise_mode', '1');
    expect(org.previewRemove([a]).ready, 1);
  });

  test('only the approved items of a plan are applied', () {
    cat.setSetting('organise_mode', '1');
    final a = idOf('Deep Tenant - Warehouse 94.mp3');
    final b = idOf('Basement Hours.mp3');
    final before = {a: pathOf(a), b: pathOf(b)};
    final plan = org.previewRename([a, b], '{title} ({artist})');
    expect(plan.ready, 2);
    final i = plan.ops.indexWhere((o) => o.trackId == b);
    final r = org.apply(plan, only: {i});
    expect(r.done, 1);
    expect(pathOf(a), before[a], reason: 'not approved, not changed');
    expect(pathOf(b), isNot(before[b]));
    expect(File(pathOf(b)).existsSync(), isTrue);
    // The moved file's hash was recorded and matches.
    final h = cat.db.select('SELECT hash FROM file_op_hashes').single['hash'];
    expect(blake3File(pathOf(b)), h);
  });

  test('replace a track: preview, verified copy, original kept, undo', () {
    cat.setSetting('organise_mode', '1');
    final a = idOf('Deep Tenant - Warehouse 94.mp3');
    final path = pathOf(a);
    final crates = CratesService(cat);
    final c = crates.create(const CrateInput(name: 'Keep me', kind: 'manual'));
    crates.addTracks(c.id, [a]);
    final oldHash = blake3File(path);
    // A "better" copy from somewhere else (synthetic bytes; same format).
    final better = File(p.join(music.parent.path, 'downloads', 'better.mp3'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([...File(path).readAsBytesSync(), 1, 2, 3]);
    final newHash = blake3File(better.path);

    final plan = org.previewReplaceFile(a, better.path);
    expect(plan.ops.single.op, 'replace');
    expect(plan.ops.single.to, path, reason: 'same format keeps the name');
    expect(plan.ops.single.blocked, isNull);
    final r = org.apply(plan);
    expect(r.done, 1, reason: '${r.skipped}');
    expect(blake3File(path), newHash);
    expect(better.existsSync(), isTrue, reason: 'the source is copied');
    expect(blake3File(better.path), newHash);
    final kept = org.removedFiles().single['to']! as String;
    expect(p.isWithin(org.removedArea, kept), isTrue);
    expect(blake3File(kept), oldHash, reason: 'original kept, verified');
    expect(pathOf(a), path);
    expect(
      cat.db.select(
        'SELECT 1 FROM crate_tracks WHERE crate_id=? AND track_id=?',
        [c.id, a],
      ),
      hasLength(1),
      reason: 'crates stay with the track',
    );
    expect(org.replacements().single['status'], 'done');

    // Undo from any of its history items restores the original exactly; the
    // copied-in file is kept in Removed files, not deleted.
    final opId = org.history().first['id']! as int;
    org.undo(opId: opId);
    expect(blake3File(path), oldHash);
    expect(org.replacements().single['status'], 'undone');
    final aside = org.removedFiles().single['to']! as String;
    expect(blake3File(aside), newHash);
    expect(
      cat.db.select('SELECT presence FROM tracks WHERE id=?', [
        a,
      ]).single['presence'],
      'present',
    );
  });

  test('replace with another format keeps the name stem and warns', () {
    cat.setSetting('organise_mode', '1');
    final a = idOf('Deep Tenant - Warehouse 94.mp3');
    final path = pathOf(a);
    final flac = File(p.join(music.parent.path, 'downloads', 'x.flac'))
      ..createSync(recursive: true)
      ..writeAsStringSync('not really flac');
    final plan = org.previewReplaceFile(a, flac.path);
    final op = plan.ops.single;
    expect(op.to, p.setExtension(path, '.flac'));
    expect(op.notes.join(), contains('Different format'));
    expect(org.apply(plan).done, 1);
    expect(pathOf(a), op.to);
    expect(File(path).existsSync(), isFalse);
    // Emptying Removed files deletes the kept original but never the track.
    expect(org.emptyRemoved(), 1);
    expect(cat.db.select('SELECT 1 FROM tracks WHERE id=?', [a]), hasLength(1));
    // With the original gone for good, undo refuses and changes nothing.
    final batch = org.replacements().single['batch']! as String;
    expect(
      () => org.undo(batch: batch),
      throwsA(predicate((e) => '$e'.contains('no longer in Removed files'))),
    );
    expect(File(op.to).existsSync(), isTrue);
    expect(pathOf(a), op.to);
    expect(() => org.previewReplaceFile(a, op.to), returnsNormally);
    expect(
      org.previewReplaceFile(a, op.to).ops.single.blocked,
      contains('same file'),
    );
  });

  test('previews say which tracks Serato knows about (read-only)', () {
    cat.setSetting('organise_mode', '1');
    final a = idOf('Deep Tenant - Warehouse 94.mp3');
    final b = idOf('Basement Hours.mp3');
    final serato = Directory(p.join(music.parent.path, '_Serato_'))
      ..createSync();
    List<int> chunk(String tag, List<int> data) => [
      ...tag.codeUnits,
      (data.length >> 24) & 255,
      (data.length >> 16) & 255,
      (data.length >> 8) & 255,
      data.length & 255,
      ...data,
    ];
    List<int> utf16(String s) => [
      for (final u in s.codeUnits) ...[u >> 8, u & 255],
    ];
    final rel = p.relative(pathOf(a), from: p.rootPrefix(pathOf(a)));
    File(p.join(serato.path, 'database V2'))
        .writeAsBytesSync(chunk('otrk', chunk('pfil', utf16(rel))));
    Directory(p.join(serato.path, 'Subcrates')).createSync();
    final crateFile = File(
      p.join(serato.path, 'Subcrates', 'House%%Warm up.crate'),
    )..writeAsBytesSync(chunk('otrk', chunk('ptrk', utf16(rel))));
    final before = crateFile.readAsBytesSync();

    final plan = org.checkSerato(
      org.previewRename([a, b], '{title} ({artist})'),
      links: SeratoLinks(seratoDirs: [serato.path]),
    );
    final opA = plan.ops.firstWhere((o) => o.trackId == a);
    final opB = plan.ops.firstWhere((o) => o.trackId == b);
    expect(opA.serato, contains("Serato's library"));
    expect(opA.serato, contains('House / Warm up'));
    expect(opA.serato, contains('Relocate'));
    expect(opB.serato, isNull);
    expect(crateFile.readAsBytesSync(), before, reason: 'Serato is only read');
  });
}
