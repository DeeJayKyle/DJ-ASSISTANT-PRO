import 'dart:io';

import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/keys.dart';
import 'package:dj_assistant/core/migrations.g.dart';
import 'package:dj_assistant/core/text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fold matches 1.x: accents and case', () {
    expect(fold('Beyoncé'), 'beyonce');
    expect(fold('SIGUR RÓS'), 'sigur ros');
    expect(
      fold('Mø'),
      'mø',
    ); // ø is a letter, not a combining mark (same as 1.x)
  });

  test('keys match 1.x for every spelling it accepts', () {
    const cases = {
      '8A': '8A',
      '08a': '8A',
      'Am': '8A',
      'A minor': '8A',
      'Amin': '8A',
      'F#m': '11A',
      'F♯ min': '11A',
      'Gbm': '11A',
      'Db': '3B',
      'C#': '3B',
      'Bbmaj': '6B',
      'B♭': '6B',
      'C': '8B',
      '1m': '8A',
      '1d': '8B',
      '6m': '1A',
      'Ebm': '2A',
      'e': '12B',
    };
    cases.forEach((inp, want) => expect(normalizeKey(inp), want, reason: inp));
    for (final bad in ['', 'H', '13A', 'Xm', 'Amajorminor', 'unknown']) {
      expect(normalizeKey(bad), isNull, reason: bad);
    }
    for (var n = 1; n <= 12; n++) {
      for (final l in ['A', 'B']) {
        expect(normalizeKey(musicalName('$n$l')!), '$n$l');
      }
    }
    expect(camelotFor('A minor'), '8A');
    expect(camelotFor('C major'), '8B');
    expect(camelotCompatible('8A', '8A'), 'same key');
    expect(camelotCompatible('8A', '9A'), 'adjacent on the Camelot wheel');
    expect(camelotCompatible('12A', '1A'), 'adjacent on the Camelot wheel');
    expect(camelotCompatible('8A', '8B'), 'relative major/minor');
    expect(camelotCompatible('8A', '3B'), isNull);
  });

  test(
    'catalogue opens with the 1.x schema, folds and normalises keys in SQL',
    () {
      final c = Catalogue.inMemory();
      expect(c.schemaVersion, migrations.length);
      expect(c.db.select("SELECT fold('Beyoncé') AS f").first['f'], 'beyonce');
      expect(
        c.db
            .select("SELECT keynorm('F#m') AS k, keynorm('zzz') AS z")
            .first
            .values,
        ['11A', 'zzz'],
      );
      c.setSetting('theme', 'light');
      c.setSetting('theme', 'dark');
      expect(c.getSetting('theme'), 'dark');
      expect(c.getSetting('missing'), isNull);
      final tables = c.db
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((r) => r['name'])
          .toSet();
      for (final t in [
        'tracks',
        'track_user',
        'analysis',
        'crates',
        'suggestions',
        'settings',
        'scans',
        'catalog_checked',
        'file_ops',
      ]) {
        expect(tables, contains(t));
      }
      c.close();
    },
  );

  test(
    're-opening a catalogue file keeps data and does not re-run migrations',
    () {
      final dir = Directory.systemTemp.createTempSync('dja');
      final path = '${dir.path}/catalogue.sqlite3';
      final a = Catalogue.open(path)..setSetting('key_notation', 'musical');
      a.close();
      final b = Catalogue.open(path);
      expect(b.getSetting('key_notation'), 'musical');
      expect(b.schemaVersion, migrations.length);
      b.close();
      dir.deleteSync(recursive: true);
    },
  );
}
