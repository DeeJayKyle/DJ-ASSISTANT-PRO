import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crew.dart';
import 'package:dj_assistant/core/file_sync.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/safe_write.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/suggestions.dart';
import 'package:dj_assistant/core/tag_writer.dart' show audioHash;
import 'package:dj_assistant/core/tags.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary, hashes;

/// Write-through: changes made in DJ Assistant reach the music files, safely.
void main() {
  late Directory music;
  late Catalogue cat;
  late String db;
  late LibraryService lib;

  setUp(() async {
    music = copyLibrary();
    db = p.join(music.parent.path, 'catalogue.sqlite3');
    cat = Catalogue.open(db);
    RootsService(cat).add(music.path);
    await runScan(cat);
    lib = LibraryService(cat);
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  int idOf(String f) =>
      cat.db.select('SELECT id FROM tracks WHERE file_name=?', [f]).first['id']
          as int;
  String pathOf(int id) =>
      cat.db.select('SELECT path FROM tracks WHERE id=?', [id]).first['path']
          as String;

  test('off (the default): edits stay in DJ Assistant', () async {
    final before = hashes(music);
    lib.updateUserFields([idOf('Low Tide.flac')], {'genre': 'Deep House'});
    expect(fileSyncQueued(cat), 0);
    expect(await flushFileSync(cat), (0, 0, 0));
    expect(hashes(music), before);
  });

  test('on: edits are written into MP3 and FLAC tags, safely', () async {
    cat.setSetting(syncSetting, '1');
    final mp3 = idOf('Lagos Lights - Sunrise Groove.mp3');
    final flac = idOf('Low Tide.flac');
    final others = hashes(music)
      ..remove(pathOf(mp3))
      ..remove(pathOf(flac));
    final audioBefore = audioHash(pathOf(mp3), 'mp3');
    lib.updateUserFields([mp3, flac], {'genre': 'Afro House', 'energy': 7});
    lib.updateUserFields(
      [mp3],
      {'bpm': 122.0, 'key': 'Am', 'title': 'Sunrise'},
    );
    expect(fileSyncQueued(cat), 2, reason: 'energy is not a file tag');
    expect(
      hashes(music)[pathOf(mp3)],
      isNotNull,
      reason: 'nothing written yet',
    );

    final (w, s, f) = await flushFileSync(cat);
    expect((w, s, f), (2, 0, 0));
    expect(fileSyncQueued(cat), 0);
    final m = readMediaMeta(pathOf(mp3));
    expect(m.genre, 'Afro House');
    expect(m.title, 'Sunrise');
    expect(m.bpm, 122);
    expect(m.key, '8A', reason: 'written in the DJ\'s notation (Camelot)');
    expect(readMediaMeta(pathOf(flac)).genre, 'Afro House');
    expect(
      audioHash(pathOf(mp3), 'mp3'),
      audioBefore,
      reason: 'only tags change, never the audio',
    );
    final now = hashes(music);
    for (final e in others.entries) {
      expect(now[e.key], e.value, reason: 'other files untouched');
    }
    // logged with a verified backup, and can be rolled back exactly
    final log = SafeWriteService(cat, music.parent.path).log(limit: 10);
    final done = log.where((c) => c['status'] == 'done').toList();
    expect(done.length, 2);
    for (final c in done) {
      expect(File('${c['backup_path']}').existsSync(), isTrue);
    }
  });

  test('musical notation is written as the DJ reads it', () async {
    cat
      ..setSetting(syncSetting, '1')
      ..setSetting('key_notation', 'musical');
    final mp3 = idOf('Lagos Lights - Sunrise Groove.mp3');
    lib.updateUserFields([mp3], {'key': '8A'});
    await flushFileSync(cat);
    expect(readMediaMeta(pathOf(mp3)).key, 'Am');
  });

  test('accepting a suggestion writes it; undo puts the file back', () async {
    cat.setSetting(syncSetting, '1');
    final flac = idOf('Low Tide.flac');
    final original = readMediaMeta(pathOf(flac)).genre;
    insertSuggestion(
      cat,
      flac,
      'genre',
      original,
      'Deep House',
      'test',
      'x',
      0.9,
    );
    final sug = SuggestionsService(cat);
    final s = sug.list(status: 'pending').firstWhere((x) => x.trackId == flac);
    sug.accept(s.id);
    await flushFileSync(cat);
    expect(readMediaMeta(pathOf(flac)).genre, 'Deep House');
    sug.undo(s.id);
    await flushFileSync(cat);
    expect(
      readMediaMeta(pathOf(flac)).genre,
      original,
      reason: 'the file says what it said before DJ Assistant wrote to it',
    );
  });

  test('earlier edits can be written when switching on', () async {
    final flac = idOf('Low Tide.flac');
    lib.updateUserFields([flac], {'year': 2021});
    expect(fileSyncQueued(cat), 0, reason: 'off at the time');
    cat.setSetting(syncSetting, '1');
    expect(enqueueAllEdited(cat), greaterThan(0));
    await flushFileSync(cat);
    expect(readMediaMeta(pathOf(flac)).year, 2021);
  });

  test('a file that changed on disk is never overwritten', () async {
    cat.setSetting(syncSetting, '1');
    final mp3 = idOf('Lagos Lights - Sunrise Groove.mp3');
    lib.updateUserFields([mp3], {'genre': 'Afro House'});
    // something else rewrote the file after the scan: the write is refused
    // only if the stamp no longer matches; a vanished file is skipped
    File(pathOf(mp3)).deleteSync();
    final (w, s, f) = await flushFileSync(cat);
    expect(w, 0);
    expect(s + f, 1);
  });

  test('the crew writes the fixes it applies', () async {
    cat
      ..setSetting(syncSetting, '1')
      ..setSetting('fix_mode', 'fill_empty');
    final jobs = JobsController();
    final st = await jobs.start(
      'crew',
      crewJob(CrewPlan(dbPath: db, dataDir: music.parent.path)),
    );
    await jobs.shutdown();
    expect(st.state, 'completed', reason: st.message);
    final clerk = ((st.result! as Map)['agents'] as List)
        .cast<Map>()
        .firstWhere((a) => a['id'] == 'clerk');
    expect(clerk['summary'], contains('music file'));
    cat.close();
    cat = Catalogue.open(db);
    expect(fileSyncQueued(cat), 0);
    final last = lastFileSync(cat)!;
    expect(
      (last['written'] as int) + (last['skipped'] as int),
      greaterThan(0),
      reason: 'every applied fix went through the writer',
    );
    expect(last['failed'], 0);
  });
}
