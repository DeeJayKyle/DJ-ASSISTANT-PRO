import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crate_tree.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/serato_library.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary;

void main() {
  late Directory music;
  late Catalogue cat;
  late LibraryService lib;
  late List<int> ids;

  setUp(() async {
    music = copyLibrary();
    cat = Catalogue.open(p.join(music.parent.path, 'catalogue.sqlite3'));
    RootsService(cat).add(music.path);
    await runScan(cat);
    lib = LibraryService(cat);
    ids = [
      for (final r in cat.db.select(
        "SELECT id FROM tracks WHERE presence='present' AND read_status='ok' "
        "AND media_kind IS NOT 'video' ORDER BY id LIMIT 4",
      ))
        r['id'] as int,
    ];
    expect(ids, hasLength(4));
    // House 1990s energy 7 & 8 (keys 9A, 8A), Techno 2000s energy 3
    lib.updateUserFields(
      [ids[0]],
      {
        'genre': 'House',
        'year': 1994,
        'energy': 7,
        'key': '9A',
        'bpm': 124.0, //
        'event': 'Club',
      },
    );
    lib.updateUserFields(
      [ids[1]],
      {
        'genre': 'House',
        'year': 1998,
        'energy': 8,
        'key': '8A',
        'bpm': 122.0, //
        'event': 'Club',
      },
    );
    lib.updateUserFields(
      [ids[2]],
      {'genre': 'Techno', 'year': 2003, 'energy': 3, 'key': '8A', 'bpm': 130.0},
    );
    lib.updateUserFields([ids[3]], {'genre': 'Techno', 'year': 2005});
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  String path(int id) =>
      cat.db.select('SELECT path FROM tracks WHERE id=?', [id]).first['path']
          as String;

  test('Genre → Decade → Energy nests and sorts harmonically', () {
    final tree = buildCrateTree(
      cat,
      CrateTreePlan(
        root: 'Auto',
        levels: const [
          TreeLevel('genre'),
          TreeLevel('decade'),
          TreeLevel('energy'),
        ],
        rules: {
          'match': 'any',
          'rules': [
            {'kind': 'condition', 'field': 'genre', 'op': 'equals', 'value': 'House'},
            {'kind': 'condition', 'field': 'genre', 'op': 'equals', 'value': 'Techno'},
          ],
        },
      ),
    );
    final names = tree.map((c) => c.name).toList();
    expect(
      names,
      containsAllInOrder([
        'Auto',
        'Auto%%House',
        'Auto%%House%%1990s',
        'Auto%%House%%1990s%%Energy 7-8',
        'Auto%%Techno',
        'Auto%%Techno%%2000s',
        'Auto%%Techno%%2000s%%Energy 3-4',
        'Auto%%Techno%%2000s%%No energy',
      ]),
    );
    final house = tree.firstWhere(
      (c) => c.name == 'Auto%%House%%1990s%%Energy 7-8',
    );
    // 8A before 9A on the Camelot wheel
    expect(house.paths, [path(ids[1]), path(ids[0])]);
    expect(
      tree.first.paths,
      containsAll([for (final id in ids) path(id)]),
      reason: 'the top crate holds all',
    );
  });

  test('tracks with no value can be left out', () {
    final tree = buildCrateTree(
      cat,
      CrateTreePlan(
        root: 'Events',
        levels: const [TreeLevel('event'), TreeLevel('bpm', step: 10)],
        includeUnknown: false,
      ),
    );
    expect(tree.map((c) => c.name), [
      'Events',
      'Events%%Club',
      'Events%%Club%%120-129 BPM',
    ]);
    expect(tree.first.paths, hasLength(2));
  });

  test('bad templates are refused', () {
    expect(
      () => buildCrateTree(
        cat,
        const CrateTreePlan(root: '', levels: [TreeLevel('genre')]),
      ),
      throwsA(isA<CrateTreeException>()),
    );
    expect(
      () => buildCrateTree(cat, const CrateTreePlan(root: 'X', levels: [])),
      throwsA(isA<CrateTreeException>()),
    );
    expect(
      () => buildCrateTree(
        cat,
        const CrateTreePlan(root: 'X', levels: [TreeLevel('nope')]),
      ),
      throwsA(isA<CrateTreeException>()),
    );
  });

  test('writing to Serato replaces the old tree under the same top crate', () {
    final serato = Directory(p.join(music.parent.path, '_Serato_'))
      ..createSync();
    SeratoLibrary.isRunning = () => false;
    final sl = SeratoLibrary(serato.path);
    sl.save('Auto%%Old crate', [path(ids[0])]);
    sl.save('Keep me', [path(ids[0])]);
    final tree = buildCrateTree(
      cat,
      const CrateTreePlan(root: 'Auto', levels: [TreeLevel('genre')]),
    );
    final (n, other, removed) = writeCrateTree(sl, tree);
    expect(other, 0);
    expect(removed, 1);
    expect(n, tree.length);
    final names = sl.crates().map((c) => c.name).toSet();
    expect(
      names,
      containsAll(['Auto', 'Auto%%House', 'Auto%%Techno', 'Keep me']),
    );
    expect(names, isNot(contains('Auto%%Old crate')));
    expect(
      sl.crate('Auto%%House')!.paths,
      hasLength(tree.firstWhere((c) => c.name == 'Auto%%House').paths.length),
    );
  });

  test('templates are saved and read back', () {
    saveTreeTemplate(
      cat,
      const CrateTreePlan(
        root: 'Auto',
        levels: [TreeLevel('genre'), TreeLevel('bpm', step: 4)],
      ),
    );
    final t = savedTreeTemplates(cat)['Auto']!;
    expect(t.levels.map((l) => (l.field, l.step)), [
      ('genre', null),
      ('bpm', 4),
    ]);
    deleteTreeTemplate(cat, 'Auto');
    expect(savedTreeTemplates(cat), isEmpty);
  });
}
