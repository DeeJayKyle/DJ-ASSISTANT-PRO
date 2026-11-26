import 'dart:io';
import 'dart:typed_data';

import 'package:dj_assistant/core/serato_backup.dart';
import 'package:dj_assistant/core/serato_database.dart';
import 'package:dj_assistant/core/serato_guard.dart';
import 'package:dj_assistant/core/serato_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

List<int> _chunk(String tag, List<int> data) => [
  ...tag.codeUnits,
  data.length >> 24 & 0xFF,
  data.length >> 16 & 0xFF,
  data.length >> 8 & 0xFF,
  data.length & 0xFF,
  ...data,
];

List<int> _u16(String s) => [
  for (final u in s.codeUnits) ...[u >> 8, u & 0xFF],
];

/// A small database V2: two tracks with cue data (`bcue`) Serato keeps.
Uint8List _db(String a, String b) => Uint8List.fromList([
  ..._chunk('vrsn', _u16('2.0/Serato Scratch LIVE Database')),
  ..._chunk('otrk', [
    ..._chunk('ttyp', _u16('mp3')),
    ..._chunk('pfil', _u16(a)),
    ..._chunk('tgen', _u16('House')),
    ..._chunk('tbpm', _u16('124.00')),
    ..._chunk('bcue', [1, 2, 3, 4]),
  ]),
  ..._chunk('otrk', [
    ..._chunk('pfil', _u16(b)),
    ..._chunk('tkey', _u16('Am')),
  ]),
]);

void main() {
  late Directory root;
  late String serato;
  late SeratoBackups backups;
  late SeratoLibrary lib;
  var running = false;

  setUp(() {
    root = Directory.systemTemp.createTempSync('serato_lib');
    serato = p.join(root.path, '_Serato_');
    Directory(p.join(serato, 'Subcrates')).createSync(recursive: true);
    backups = SeratoBackups(p.join(root.path, 'backups'), keep: 3);
    lib = SeratoLibrary(serato, backups: backups);
    running = false;
    SeratoLibrary.isRunning = () => running;
  });
  tearDown(() {
    SeratoLibrary.isRunning = seratoRunningNow;
    root.deleteSync(recursive: true);
  });

  String track(String name) {
    final f = File(p.join(root.path, 'Music', name))
      ..createSync(recursive: true);
    return f.path;
  }

  test('crates are created, nested with %%, renamed and deleted', () {
    final a = track('a.mp3'), b = track('b.mp3');
    lib.save('House', [a]);
    lib.save('House%%Deep', [a, b]);
    expect(
      File(p.join(serato, 'Subcrates', 'House%%Deep.crate')).existsSync(),
      isTrue,
    );
    expect(lib.crate('House%%Deep')!.paths, hasLength(2));
    lib.rename('House', 'Club');
    expect(lib.crates().map((c) => c.name), ['Club', 'Club%%Deep']);
    lib.move('Club%%Deep', null);
    expect(lib.crates().map((c) => c.name), ['Club', 'Deep']);
    expect(lib.delete('Club'), 1);
    expect(lib.crates().map((c) => c.name), ['Deep']);
  });

  test('nothing changes while Serato DJ is open', () {
    running = true;
    expect(
      () => lib.save('House', [track('a.mp3')]),
      throwsA(isA<SeratoLibraryException>()),
    );
    expect(lib.crates(), isEmpty);
    expect(backups.list(), isEmpty);
  });

  test('when it cannot be told whether Serato is open, nothing changes', () {
    SeratoLibrary.isRunning = () => throw SeratoLibraryException('unknown');
    expect(
      () => lib.save('House', [track('a.mp3')]),
      throwsA(isA<SeratoLibraryException>()),
    );
    expect(lib.crates(), isEmpty);
  });

  test('Serato DJ Pro and Lite are recognised in process lists', () {
    expect(seratoInProcessList('"Serato DJ Pro.exe","1234","Console"'), isTrue);
    expect(seratoInProcessList('"Serato DJ Lite.exe","1","Console"'), isTrue);
    expect(seratoInProcessList('Finder\nSerato DJ Pro\n'), isTrue);
    expect(
      seratoInProcessList('"Serato Studio.exe","1"\nexplorer.exe'),
      isFalse,
    );
  });

  test('every change is backed up first, and a backup restores', () {
    final a = track('a.mp3');
    lib.save('House', [a]);
    expect(backups.list(), hasLength(1)); // the empty state before it
    lib.batch('two at once', () {
      lib.save('Techno', [a]);
      lib.save('Disco', [a]);
    });
    expect(backups.list(), hasLength(2)); // one for the whole batch
    final beforeBatch = backups.list().first;
    expect(beforeBatch.reason, 'two at once');
    lib.restore(beforeBatch);
    expect(lib.crates().map((c) => c.name), ['House']);
    // the restore itself was backed up, and old backups are pruned to 3
    expect(backups.list(), hasLength(3));
    lib.save('X', [a]);
    expect(backups.list(), hasLength(3));
  });

  test('database V2: only the chosen fields of known tracks change', () {
    final bytes = _db('Music/a.mp3', 'Music/b.mp3');
    final same = updateSeratoDatabase(bytes, {});
    expect(same.bytes, bytes);
    final up = updateSeratoDatabase(bytes, {
      'music/A.mp3': {'genre': 'Deep House', 'year': '1999'},
      'Music/unknown.mp3': {'genre': 'Rock'},
    });
    expect((up.tracks, up.fields), (1, 2));
    expect(up.bytes.length, greaterThan(bytes.length));
    // the second track and the first track's cues are untouched
    final tracks = [
      for (final (t, d) in seratoChunks(up.bytes))
        if (t == 'otrk') seratoChunks(d),
    ];
    expect(tracks, hasLength(2));
    final first = {for (final (t, d) in tracks[0]) t: d};
    expect(first['bcue'], [1, 2, 3, 4]);
    expect(
      String.fromCharCodes([
        for (var i = 0; i < first['tgen']!.length; i += 2)
          first['tgen']![i] << 8 | first['tgen']![i + 1],
      ]),
      'Deep House',
    );
    expect(first.containsKey('ttyr'), isTrue);
    expect(parseSeratoDatabase(up.bytes)['Music/a.mp3']!.bpm, 124);
  });

  test('a damaged database V2 is refused, not rewritten', () {
    final bytes = _db('Music/a.mp3', 'Music/b.mp3');
    final cut = Uint8List.sublistView(bytes, 0, bytes.length - 3);
    expect(
      () => updateSeratoDatabase(cut, {
        'Music/a.mp3': {'genre': 'X'},
      }),
      throwsA(isA<SeratoLibraryException>()),
    );
  });

  test('updateDatabase writes through the guard with a backup', () {
    final a = track('a.mp3');
    final rel = lib.relative(a)!;
    File(lib.databasePath).writeAsBytesSync(_db(rel, 'Music/b.mp3'));
    final (t, f) = lib.updateDatabase({
      a: {'genre': 'Deep House'},
    });
    expect((t, f), (1, 1));
    expect(backups.list(), hasLength(1));
    running = true;
    expect(
      () => lib.updateDatabase({
        a: {'genre': 'Techno'},
      }),
      throwsA(isA<SeratoLibraryException>()),
    );
  });
}
