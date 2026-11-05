import 'dart:io';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/assistant/agent.dart';
import 'package:dj_assistant/core/jobs.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/online/http_online.dart';
import 'package:dj_assistant/online/lookups.dart';
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

  test(
    'online features refuse to send anything until they are turned on',
    () async {
      final ids = [
        for (final r in app.cat.db.select('SELECT id FROM tracks'))
          r['id'] as int,
      ];
      expect(ids, isNotEmpty);
      final progress = LocalProgress();
      expect(await autoPrepOnline(app.cat, progress, online, app.secrets), 0);
      expect(
        () => musicbrainzLookup(app.cat, online, ids, progress),
        throwsA(anything),
      );
      expect(
        () => acoustidLookup(app.cat, online, app.secrets, ids, progress),
        throwsA(anything),
      );
      expect(
        () => catalogLookup(app.cat, online, app.secrets, ids, progress),
        throwsA(anything),
      );
      expect(() => app.lookupCatalogs(ids), throwsA(anything));
      expect(() => app.lookupMusicbrainz(ids), throwsA(anything));
      expect(() => app.lookupAcoustid(ids, confirmed: true), throwsA(anything));
      expect(() => app.discovery.refreshReleases(online), throwsA(anything));
      expect(
        () => app.discovery.lastfmForTrack(online, app.secrets, ids.first),
        throwsA(anything),
      );
      // the AI assistant refuses while AI is off (the panel then answers
      // from its built-in rules, which never go online)
      await expectLater(
        Agent(app).chat(null, 'how many tracks do I have?'),
        throwsA(isA<AgentException>()),
      );
      await pumpEventQueue();
      expect(sent, isEmpty);
    },
  );

  test('turning a service on is what allows its requests', () async {
    app.settings.setService('musicbrainz', true);
    final ids = [
      for (final r in app.cat.db.select(
        'SELECT id FROM tracks WHERE artist IS NOT NULL AND title IS NOT NULL LIMIT 1',
      ))
        r['id'] as int,
    ];
    await musicbrainzLookup(
      app.cat,
      online,
      ids,
      LocalProgress(),
      spacingMs: 0,
    );
    expect(ids, isNotEmpty);
    expect(sent, isNotEmpty);
    expect(sent.every((u) => u.host == 'musicbrainz.org'), isTrue);
  });
}
