import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/rules.dart';
import 'package:flutter_test/flutter_test.dart';

import 'library_test.dart' show addTrack;

void main() {
  test(
    'unknown fields and operators are rejected; values are bound, not inlined',
    () {
      expect(
        () => compileRules({
          'match': 'all',
          'rules': [
            {
              'kind': 'condition',
              'field': 'title; DROP TABLE tracks',
              'op': 'contains',
              'value': 'x',
            },
          ],
        }, 128),
        throwsA(isA<RuleException>()),
      );
      expect(
        () => compileRules({
          'match': 'all',
          'rules': [
            {
              'kind': 'condition',
              'field': 'title',
              'op': 'OR 1=1 --',
              'value': 'x',
            },
          ],
        }, 128),
        throwsA(isA<RuleException>()),
      );
      final (sql, params) = compileRules({
        'match': 'all',
        'rules': [
          {
            'kind': 'condition',
            'field': 'title',
            'op': 'contains',
            'value': "'); DROP TABLE tracks; --",
          },
        ],
      }, 128);
      expect(sql, isNot(contains('DROP')));
      expect(params, hasLength(1));
    },
  );

  test('nesting and size limits', () {
    Map<String, Object?> nest(int d) => d == 0
        ? {'kind': 'condition', 'field': 'bpm', 'op': 'gt', 'value': 1}
        : {
            'kind': 'group',
            'match': 'all',
            'rules': [nest(d - 1)],
          };
    expect(
      () => compileRules({
        'match': 'all',
        'rules': [nest(6)],
      }, 128),
      throwsA(isA<RuleException>()),
    );
    final many = List.generate(
      201,
      (_) => {'kind': 'condition', 'field': 'bpm', 'op': 'gt', 'value': 1},
    );
    expect(
      () => compileRules({'match': 'any', 'rules': many}, 128),
      throwsA(isA<RuleException>()),
    );
  });

  test('smart crate rules find the right tracks in a real catalogue', () {
    final c = Catalogue.inMemory();
    final lib = LibraryService(c);
    addTrack(
      c,
      'a.mp3',
      title: 'Essence',
      artist: 'Wizkid',
      genre: 'Afrobeats',
      bpm: 104,
      key: 'Am',
      kbps: 320,
    );
    addTrack(
      c,
      'b.mp3',
      title: 'Halo',
      artist: 'Beyoncé',
      genre: 'Pop',
      bpm: 80,
      key: '8B',
      kbps: 96,
    );
    addTrack(
      c,
      'c.mp3',
      title: 'Roller',
      artist: 'Deep Tenant',
      genre: 'House',
      bpm: 124,
      key: '9A',
      kbps: 320,
    );
    List<String?> run(Map<String, Object?> rs) => lib
        .search(
          TrackQuery(
            extraWhere: compileRules(rs, lib.lowBitrateKbps),
            sort: 'bpm',
          ),
        )
        .rows
        .map((r) => r.title)
        .toList();
    expect(
      run({
        'match': 'all',
        'rules': [
          {
            'kind': 'condition',
            'field': 'bpm',
            'op': 'between',
            'value': [128, 100],
          },
        ],
      }),
      ['Essence', 'Roller'],
    );
    // keys may be typed in either notation
    expect(
      run({
        'match': 'all',
        'rules': [
          {
            'kind': 'condition',
            'field': 'key',
            'op': 'equals',
            'value': 'A minor',
          },
        ],
      }),
      ['Essence'],
    );
    expect(
      run({
        'match': 'all',
        'rules': [
          {
            'kind': 'condition',
            'field': 'key',
            'op': 'in',
            'value': ['8A', 'C'],
          },
        ],
      }),
      ['Halo', 'Essence'],
    );
    expect(
      run({
        'match': 'all',
        'rules': [
          {
            'kind': 'condition',
            'field': 'artist',
            'op': 'contains',
            'value': 'beyonce',
          },
        ],
      }),
      ['Halo'],
    );
    expect(
      run({
        'match': 'any',
        'rules': [
          {
            'kind': 'condition',
            'field': 'genre',
            'op': 'equals',
            'value': 'house',
          },
          {
            'kind': 'condition',
            'field': 'quality',
            'op': 'in',
            'value': ['low_bitrate'],
          },
        ],
      }),
      ['Halo', 'Roller'],
    );
    expect(
      run({
        'match': 'all',
        'rules': [
          {'kind': 'condition', 'field': 'bpm', 'op': 'gt', 'value': 90},
        ],
        'exclude': [
          {
            'kind': 'condition',
            'field': 'genre',
            'op': 'equals',
            'value': 'House',
          },
        ],
      }),
      ['Essence'],
    );
    expect(
      run({
        'match': 'all',
        'rules': [
          {'kind': 'condition', 'field': 'tag', 'op': 'is_empty'},
        ],
      }),
      hasLength(3),
    );
    expect(
      run({
        'match': 'all',
        'rules': [
          {
            'kind': 'condition',
            'field': 'genre',
            'op': 'not_equals',
            'value': 'pop',
          },
        ],
      }),
      ['Essence', 'Roller'],
    );
    c.close();
  });
}
