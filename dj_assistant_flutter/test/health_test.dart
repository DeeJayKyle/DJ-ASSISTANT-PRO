import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/health.dart';
import 'package:dj_assistant/core/library.dart';
import 'package:dj_assistant/core/library_edit.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/core/suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

import 'scanner_test.dart' show copyLibrary;

/// Health, fix lists and local suggestions against 1.x (test/golden/health.json).
void main() {
  late Directory music;
  late Catalogue cat;
  late Map golden;
  setUp(() async {
    music = copyLibrary();
    cat = Catalogue.inMemory();
    RootsService(cat).add(music.path);
    await runScan(cat);
    golden =
        jsonDecode(File('test/golden/health.json').readAsStringSync()) as Map;
  });
  tearDown(() {
    cat.close();
    music.parent.deleteSync(recursive: true);
  });

  String rel(int id) =>
      (cat.db.select('SELECT rel_path FROM tracks WHERE id=?', [
                id,
              ]).first['rel_path']
              as String)
          .replaceAll(r'\', '/');

  test('local suggestions, health counts, fix hints and stats match 1.x', () {
    final svc = SuggestionsService(cat);
    expect(svc.generateLocal(), golden['created']);
    String sk(Map s) =>
        '${s['file']}|${s['field']}|${s['current']}|${s['value']}|${s['source']}|${s['evidence']}|${s['confidence']}';
    expect(
      {
        for (final s in svc.list())
          sk({
            'file': rel(s.trackId),
            'field': s.field,
            'current': s.currentValue,
            'value': s.suggestedValue,
            'source': s.source,
            'evidence': s.evidence,
            'confidence': s.confidence,
          }),
      },
      {for (final s in (golden['suggestions'] as List).cast<Map>()) sk(s)},
    );

    final h = HealthService(cat).health();
    expect(
      [
        for (final i in h['items'] as List<HealthItem>)
          [i.id, i.label, i.count],
      ],
      [
        for (final i in (golden['items'] as List).cast<Map>())
          [i['id'], i['label'], i['count']],
      ],
    );
    for (final e in (golden['fixes'] as Map).entries) {
      final (_, _, total, rows) = HealthService(cat)
          .fixList(e.key as String, limit: 500);
      final want = e.value as Map;
      expect(total, want['total'], reason: e.key as String);
      String rk(String file, String folder, List hints) =>
          '$file|$folder|${jsonEncode([for (final h in hints) SplayTreeMap.of((h as Map).cast<String, Object?>())])}';
      expect(
        {
          for (final r in rows)
            rk(rel(r.track.id), r.folder, [
              for (final x in r.hints)
                {
                  'field': x.field,
                  'value': x.value,
                  'source': x.source,
                  'evidence': x.evidence,
                  'stored': x.suggestionId != null,
                },
            ]),
        },
        {
          for (final r in (want['rows'] as List).cast<Map>())
            rk(r['file'] as String, r['folder'] as String, r['hints'] as List),
        },
        reason: e.key as String,
      );
    }
    final st = LibraryService(cat).stats();
    for (final e in (golden['stats'] as Map).entries) {
      if (e.key == 'total_duration_ms') {
        // Per-file durations may differ by a few ms of rounding (see tags_test).
        expect(
          (st[e.key]! - (e.value as int)).abs(),
          lessThan((e.value as int) * 0.005),
        );
      } else {
        expect(st[e.key], e.value, reason: e.key as String);
      }
    }
  });

  test(
    'accepting a suggestion edits only the catalogue and supersedes the rest',
    () {
      final svc = SuggestionsService(cat);
      svc.generateLocal();
      final s = svc.list(status: 'pending').first;
      final file =
          cat.db.select('SELECT path FROM tracks WHERE id=?', [
                s.trackId,
              ]).first['path']
              as String;
      final before = File(file).readAsBytesSync();
      svc.accept(s.id, edited: '${s.suggestedValue} (edited)');
      expect(
        File(file).readAsBytesSync(),
        before,
        reason: 'files are never touched',
      );
      final col = s.field == 'key' ? 'musical_key' : s.field;
      expect(
        cat.db.select('SELECT $col AS v FROM track_user WHERE track_id=?', [
          s.trackId,
        ]).first['v'],
        '${s.suggestedValue} (edited)',
      );
      expect(svc.counts()['accepted'], 1);
      svc.reset(s.id);
      expect(svc.list(status: 'pending').any((x) => x.id == s.id), isTrue);
      svc.reject(s.id);
      expect(() => svc.reject(999999), throwsA(isA<SuggestionException>()));
    },
  );

  test('catalogue edits are validated before anything is written', () {
    final lib = LibraryService(cat);
    final id =
        cat.db.select('SELECT id FROM tracks LIMIT 1').first['id'] as int;
    expect(
      () => lib.updateUserFields([id], {'energy': 11}),
      throwsA(isA<EditException>()),
    );
    expect(
      () => lib.updateUserFields([id], {'year': 99}),
      throwsA(isA<EditException>()),
    );
    expect(
      () => lib.updateUserFields([id], {'color': 'gold'}),
      throwsA(isA<EditException>()),
    );
    expect(cat.db.select('SELECT COUNT(*) AS n FROM track_user').first['n'], 0);
    lib.updateUserFields(
      [id],
      {'energy': 7, 'genre': '  Afro House ', 'key': '8A'},
    );
    final d = lib.trackDetail(id);
    expect((d['mine'] as Map)['genre'], 'Afro House');
    expect((d['row'] as TrackRow).energy, 7);
    lib.updateUserFields([id], {'genre': null});
    expect((lib.trackDetail(id)['mine'] as Map)['genre'], isNull);
    lib.setTags([id], add: ['Wedding', 'Warm-up']);
    expect(lib.listTags().map((t) => t.$1), ['Warm-up', 'Wedding']);
    lib.setTags([id], remove: ['wedding']);
    expect(lib.listTags().map((t) => t.$1), ['Warm-up']);
    expect(lib.facet('genre').isNotEmpty, isTrue);
  });

  test('file names and years parse as in 1.x', () {
    expect(parseFilename('01 - Wizkid - Essence'), ('Wizkid', 'Essence'));
    expect(parseFilename('03. Rema - Calm Down (Extended)'), (
      'Rema',
      'Calm Down (Extended)',
    ));
    expect(parseFilename('Fik_Fameica - Darling'), ('Fik Fameica', 'Darling'));
    expect(parseFilename('untagged recording'), isNull);
    expect(yearIn('Darling (2019).mp3'), 2019);
    expect(yearIn('Darling 2019.mp3'), isNull);
  });
}
