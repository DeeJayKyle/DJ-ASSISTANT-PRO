import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/core/accounts.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dja-acc'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('accounts keep separate catalogues and the last one reopens', () {
    final s = AccountsService.open(tmp.path);
    expect(
      s.catalogue,
      isNull,
      reason: 'nothing open before an account exists',
    );
    final a = s.create('Herbie');
    s.catalogue!.setSetting('theme', 'light');
    final b = s.create('Kyle');
    expect(s.currentId, b.id);
    expect(
      s.catalogue!.getSetting('theme'),
      isNull,
      reason: 'a new account starts empty',
    );
    s.switchTo(a.id);
    expect(s.catalogue!.getSetting('theme'), 'light');
    s.close();
    final again = AccountsService.open(tmp.path);
    expect(again.currentId, a.id);
    expect(again.accounts.map((x) => x.name), ['Herbie', 'Kyle']);
    again.close();
  });

  test('names are cleaned, unique ignoring case, and validated', () {
    final s = AccountsService.open(tmp.path);
    final a = s.create('  DJ   Kyle ');
    expect(a.name, 'DJ Kyle');
    expect(() => s.create('dj kyle'), throwsA(isA<AccountException>()));
    expect(() => s.create('   '), throwsA(isA<AccountException>()));
    expect(() => s.create('x' * 41), throwsA(isA<AccountException>()));
    final b = s.create('Second');
    expect(() => s.rename(b.id, 'DJ KYLE'), throwsA(isA<AccountException>()));
    expect(s.rename(b.id, 'Booth').name, 'Booth');
    s.close();
  });

  test('a 1.x catalogue from before accounts becomes "My library"', () {
    Catalogue.open(p.join(tmp.path, 'catalogue.sqlite3'))
      ..setSetting('key_notation', 'musical')
      ..close();
    final s = AccountsService.open(tmp.path);
    expect(s.accounts.single.id, legacyId);
    expect(s.accounts.single.name, 'My library');
    expect(s.catalogue!.getSetting('key_notation'), 'musical');
    final book = jsonDecode(
      File(p.join(tmp.path, 'accounts.json')).readAsStringSync(),
    );
    expect(book['last'], legacyId);
    s.close();
  });

  test(
    'deleting removes the catalogue, keeps backups, and never the only account',
    () {
      final s = AccountsService.open(tmp.path);
      final a = s.create('One');
      expect(() => s.delete(a.id), throwsA(isA<AccountException>()));
      final b = s.create('Two');
      final backups = Directory(p.join(tmp.path, 'accounts', b.id, 'backups'))
        ..createSync(recursive: true);
      File(p.join(backups.path, 'track.mp3.bak')).writeAsStringSync('x');
      expect(s.delete(b.id), backups.path);
      expect(s.currentId, a.id, reason: 'switched away before deleting');
      expect(File(s.cataloguePath(b.id)).existsSync(), isFalse);
      expect(File(p.join(backups.path, 'track.mp3.bak')).existsSync(), isTrue);
      final c = s.create('Three');
      expect(c.name, 'Three');
      s.isBusy = () => true;
      expect(
        () => s.switchTo(a.id),
        throwsA(isA<AccountException>()),
        reason: 'busy accounts cannot be left',
      );
      s.close();
    },
  );

  test('reads an accounts.json written by DJ Assistant 1.x', () {
    File(p.join(tmp.path, 'accounts.json')).writeAsStringSync(
      jsonEncode({
        'accounts': [
          {
            'id': 'main',
            'name': 'My library',
            'color': '#3ee6c4',
            'created_at': 1793800000000,
          },
          {
            'id': 'a1b2c3d4e5f6',
            'name': 'DJ Kyle',
            'color': '#7aa2ff',
            'created_at': 1793800001000,
          },
        ],
        'last': 'a1b2c3d4e5f6',
      }),
    );
    final s = AccountsService.open(tmp.path);
    expect(s.currentId, 'a1b2c3d4e5f6');
    expect(
      File(p.join(tmp.path, 'accounts', 'a1b2c3d4e5f6', 'catalogue.sqlite3'))
          .existsSync(),
      isTrue,
    );
    s.close();
    File(p.join(tmp.path, 'accounts.json')).writeAsStringSync('{broken');
    expect(
      () => AccountsService.open(tmp.path),
      throwsA(isA<AccountException>()),
    );
  });
}
