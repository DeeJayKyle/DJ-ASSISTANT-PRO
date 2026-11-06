import 'dart:io';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/assistant/agent.dart';
import 'package:dj_assistant/core/limits.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary;

/// The assistant can work every feature: suggestions, auto-prep, lookups,
/// duplicates, Discovery, limits and the Studio.
void main() {
  late Directory music;
  late AppSession app;
  late Agent agent;
  setUp(() async {
    music = copyLibrary();
    app = AppSession(
      dbPath: p.join(music.parent.path, 'catalogue.sqlite3'),
      online: NoOnline(),
      secrets: MemorySecrets(),
    );
    app.roots.add(music.path);
    await runScan(app.cat);
    agent = Agent(app);
  });
  tearDown(() async {
    await app.close();
    music.parent.deleteSync(recursive: true);
  });

  test('every action has a plain description for its approval card', () {
    for (final t in tools.where((t) => t.tier == Tier.act)) {
      final d = agent.describe(t.name, const {});
      expect(d, isNot(t.name.replaceAll('_', ' ')), reason: t.name);
    }
    for (final s in toolSpecs()) {
      expect((s['input_schema']! as Map)['type'], 'object');
    }
  });

  test('suggestions: list, accept and reject', () {
    agent.runTool('find_local_suggestions', const {});
    final pending =
        (agent.runTool('list_suggestions', const {'status': 'pending'})!
                as List)
            .cast<Map>();
    expect(pending, isNotEmpty);
    final a = pending.first['id'] as int;
    final r = pending.length > 1 ? pending[1]['id'] as int : null;
    final res =
        agent.runTool('decide_suggestions', {
              'accept': [a],
              'reject': [?r],
            })!
            as Map;
    expect(res['accepted'], 1);
    final accepted =
        (agent.runTool('list_suggestions', const {'status': 'accepted'})!
                as List)
            .cast<Map>();
    expect(accepted.map((x) => x['id']), contains(a));
  });

  test('limits: read, set and remove', () {
    final all = agent.runTool('get_limits', const {})! as Map;
    expect(all.keys, containsAll(limitDefs.map((d) => d.key)));
    expect((all['autoprep_musicbrainz'] as Map)['value'], isNull);
    agent.runTool('set_limit', const {
      'limit': 'autoprep_musicbrainz',
      'value': 1000,
    });
    expect(limitOf(app.cat, 'autoprep_musicbrainz'), 1000);
    agent.runTool('set_limit', const {'limit': 'autoprep_musicbrainz'});
    expect(limitOf(app.cat, 'autoprep_musicbrainz'), isNull);
  });

  test('duplicates, Discovery and the Studio', () {
    final groups = (agent.runTool('duplicate_groups', const {})! as List)
        .cast<Map>();
    expect(groups, isNotEmpty);
    agent.runTool('decide_duplicates', {
      'group_key': groups.first['group_key'],
      'decision': 'not_duplicate',
    });
    final again = (agent.runTool('duplicate_groups', const {})! as List)
        .cast<Map>();
    expect(
      again.firstWhere(
        (g) => g['group_key'] == groups.first['group_key'],
      )['decision'],
      'not_duplicate',
    );
    agent.runTool('follow_artist', const {'name': 'Quiet Harbour'});
    final d = agent.runTool('discovery_items', const {})! as Map;
    expect(
      (d['followed'] as List).cast<Map>().map((f) => f['name']),
      contains('Quiet Harbour'),
    );
    expect(
      agent.runTool('match_tracklist', const {
        'text': 'Quiet Harbour - Low Tide',
      }),
      isNotNull,
    );
    expect(
      agent.runTool('open_studio', const {'page': 'stems', 'track_id': 1}),
      isA<Map>(),
    );
  });

  test('online lookups refuse until the service is on', () {
    expect(
      () => agent.runTool('online_lookup', const {'service': 'musicbrainz'}),
      throwsA(anything),
    );
  });
}
