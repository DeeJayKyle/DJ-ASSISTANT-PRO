import 'dart:io';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/online/http_online.dart';
import 'package:dj_assistant/online/consensus.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary;

/// Phase 5 network audit: DJ Assistant is local-first. With the settings a new
/// library starts with, nothing leaves the computer — the only exception is
/// the update check, which 1.x also had on by default and which sends only
/// the app version. Every request goes through [HttpOnline], so a counting
/// HTTP client sees all of them.
void main() {
  late Directory music;
  late AppSession app;
  final sent = <Uri>[];
  late HttpOnline online;

  setUp(() async {
    sent.clear();
    final client = MockClient((r) async {
      sent.add(r.url);
      return http.Response('{}', 200);
    });
    online = HttpOnline(client: client, local: client);
    music = copyLibrary();
    app = AppSession(
      dbPath: p.join(music.parent.path, 'catalogue.sqlite3'),
      online: online,
      secrets: MemorySecrets(),
    );
    app.roots.add(music.path);
    await runScan(app.cat);
  });

  tearDown(() async {
    await app.close();
    music.parent.deleteSync(recursive: true);
  });

  test('a new library has every online service off except update checks', () {
    final on = [
      for (final s in app.settings.services())
        if (s['enabled'] == true) s['id'],
    ];
    expect(on, ['updates']);
  });

  test('Analyse sends nothing online until an analyser is turned on', () async {
    final ids = [
      for (final r in app.cat.db.select('SELECT id FROM tracks'))
        r['id'] as int,
    ];
    expect(ids, isNotEmpty);
    expect(activeAnalysers(app.cat, app.secrets), isEmpty);
    await analyseOnline(app.cat, online, app.secrets, ids, LocalProgress());
    await pumpEventQueue();
    expect(sent, isEmpty);
  });

  test('turning a service on is what allows its requests', () async {
    app.settings.setService('musicbrainz', true);
    final ids = [
      for (final r in app.cat.db.select(
        'SELECT id FROM tracks WHERE artist IS NOT NULL AND title IS NOT NULL LIMIT 1',
      ))
        r['id'] as int,
    ];
    await analyseOnline(app.cat, online, app.secrets, ids, LocalProgress());
    expect(ids, isNotEmpty);
    expect(sent, isNotEmpty);
    expect(sent.every((u) => u.host == 'musicbrainz.org'), isTrue);
  });
}
