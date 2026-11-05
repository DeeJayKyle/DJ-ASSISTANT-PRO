import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/crates.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_test.dart' show addTrack;

void main() {
  late Catalogue c;
  late CratesService crates;
  late int essence, halo, roller;
  setUp(() {
    c = Catalogue.inMemory();
    crates = CratesService(c);
    essence = addTrack(
      c,
      'a.mp3',
      title: 'Essence',
      artist: 'Wizkid',
      genre: 'Afrobeats',
      bpm: 104,
    );
    halo = addTrack(
      c,
      'b.mp3',
      title: 'Halo',
      artist: 'Beyoncé',
      genre: 'Pop',
      bpm: 80,
    );
    roller = addTrack(
      c,
      'c.mp3',
      title: 'Roller',
      artist: 'Deep Tenant',
      genre: 'House',
      bpm: 124,
    );
  });
  tearDown(() => c.close());

  List<String?> titles(int id) =>
      crates.tracks(id, sort: 'bpm').rows.map((r) => r.title).toList();

  test('manual crates: add, re-add, remove, count', () {
    final w = crates.create(
      const CrateInput(name: '  Warm-up ', kind: 'manual', color: 'teal'),
    );
    expect(w.name, 'Warm-up');
    expect(
      crates.addTracks(w.id, [halo, essence, 99999]),
      2,
      reason: 'unknown tracks are skipped',
    );
    crates.addTracks(w.id, [halo]);
    expect(titles(w.id), ['Halo', 'Essence']);
    expect(crates.get(w.id).trackCount, 2);
    crates.removeTracks(w.id, [halo]);
    expect(titles(w.id), ['Essence']);
  });

  test('smart crates: rules, manual additions and remembered removals', () {
    final rules = {
      'match': 'all',
      'rules': [
        {'kind': 'condition', 'field': 'bpm', 'op': 'gte', 'value': 100},
      ],
    };
    final s = crates.create(
      CrateInput(name: 'Peak', kind: 'smart', rules: rules),
    );
    expect(titles(s.id), ['Essence', 'Roller']);
    crates.addTracks(s.id, [halo]);
    expect(titles(s.id), [
      'Halo',
      'Essence',
      'Roller',
    ], reason: 'added by hand though the rule misses it');
    crates.removeTracks(s.id, [roller]);
    expect(titles(s.id), [
      'Halo',
      'Essence',
    ], reason: 'the removal sticks despite matching the rule');
    crates.addTracks(s.id, [roller]);
    expect(
      titles(s.id),
      contains('Roller'),
      reason: 'adding again lifts the exclusion',
    );
    expect(crates.previewRules(rules).total, 2);
  });

  test('validation: names, kinds, colours, rules, nesting', () {
    expect(
      () => crates.create(const CrateInput(name: ' ', kind: 'manual')),
      throwsA(isA<CrateException>()),
    );
    expect(
      () => crates.create(const CrateInput(name: 'x', kind: 'folder')),
      throwsA(isA<CrateException>()),
    );
    expect(
      () => crates.create(
        const CrateInput(name: 'x', kind: 'manual', color: 'magenta'),
      ),
      throwsA(isA<CrateException>()),
    );
    expect(
      () => crates.create(
        const CrateInput(
          name: 'x',
          kind: 'smart',
          rules: {'match': 'all', 'rules': []},
        ),
      ),
      throwsA(isA<CrateException>()),
    );
    expect(
      () => crates.create(
        const CrateInput(
          name: 'x',
          kind: 'smart',
          rules: {
            'match': 'all',
            'rules': [
              {'kind': 'condition', 'field': 'nope', 'op': 'eq', 'value': 1},
            ],
          },
        ),
      ),
      throwsA(anything),
    );
    final parent = crates.create(
      const CrateInput(name: 'Gigs', kind: 'manual'),
    );
    final child = crates.create(
      CrateInput(
        name: 'Weddings',
        kind: 'manual',
        parentId: parent.id,
        category: ' Events ',
      ),
    );
    expect(child.category, 'Events');
    expect(
      () => crates.update(
        child.id,
        CrateInput(name: 'Weddings', kind: 'manual', parentId: child.id),
      ),
      throwsA(isA<CrateException>()),
    );
    expect(
      () => crates.update(
        child.id,
        const CrateInput(
          name: 'W',
          kind: 'smart',
          rules: {
            'match': 'all',
            'rules': [
              {'kind': 'condition', 'field': 'bpm', 'op': 'gt', 'value': 1},
            ],
          },
        ),
      ),
      throwsA(isA<CrateException>()),
    );
    expect(crates.list().map((x) => x.name), ['Gigs', 'Weddings']);
    crates.delete(parent.id);
    expect(
      crates.get(child.id).parentId,
      isNull,
      reason: 'children move to the top level',
    );
    expect(() => crates.delete(parent.id), throwsA(isA<CrateException>()));
  });
}
