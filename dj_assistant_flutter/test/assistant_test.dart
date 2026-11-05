import 'dart:convert';
import 'dart:io';

import 'package:dj_assistant/app/session.dart';
import 'package:dj_assistant/assistant/agent.dart';
import 'package:dj_assistant/assistant/guide.g.dart';
import 'package:dj_assistant/assistant/rule_assistant.dart';
import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/roots.dart';
import 'package:dj_assistant/core/scanner.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'scanner_test.dart' show copyLibrary;

/// Numbers compared by value (1.x writes 120.0 where Dart may write 120).
Object? _norm(Object? v) => switch (v) {
  final Map m => {for (final e in m.entries) '${e.key}': _norm(e.value)},
  final List l => [for (final x in l) _norm(x)],
  final num n => n.toDouble(),
  _ => v,
};

void main() {
  group('rule-based assistant', () {
    late Directory music;
    late Catalogue cat;
    setUp(() async {
      music = copyLibrary();
      cat = Catalogue.inMemory();
      RootsService(cat).add(music.path);
      await runScan(cat);
    });
    tearDown(() {
      cat.close();
      music.parent.deleteSync(recursive: true);
    });

    test('answers every golden phrase as 1.x does', () {
      final golden = jsonDecode(
        File('test/golden/assistant.json').readAsStringSync(),
      ) as List;
      for (final g in golden.cast<Map>()) {
        final want = Map<String, Object?>.from(g['reply'] as Map);
        final got = ruleAssistant(cat, g['message'] as String).toJson();
        got['sample'] = [
          for (final t in (got['sample']! as List).cast<Map>()) t['file_name'],
        ];
        // Ties in the default order fall back to the track id, which follows the
        // file system's directory order in 1.x and 2.0 alike: compare samples as
        // sets (all of them fit when there are 8 or fewer).
        final gs = got.remove('sample')! as List,
            ws = want.remove('sample')! as List;
        expect(gs.length, ws.length, reason: 'message: "${g['message']}"');
        if (ws.length < 8) expect(gs.toSet(), ws.toSet());
        // serde skips a null `params`; the Dart reply omits it the same way
        expect(_norm(got), _norm(want), reason: 'message: "${g['message']}"');
      }
    });
  });

  group('AI agent', () {
    test('paths are hidden from the model', () {
      final v =
          stripPaths({
                'path': r'C:\Music\a.mp3',
                'row': {
                  'title': 'Intro',
                  'note': r'D:\DJ\x.flac',
                  'unc': r'\\nas\music\x.mp3',
                  'unix': '/home/h/Music/x.mp3',
                  'ratio': '3/4',
                  'text': 'a: b',
                },
                'list': ['E:/Crates/y.mp3'],
              })!
              as Map;
      expect(v.containsKey('path'), isFalse);
      final row = v['row'] as Map;
      expect(row['note'], '[path hidden]');
      expect(row['unc'], '[path hidden]');
      expect(row['unix'], '[path hidden]');
      expect((v['list'] as List).first, '[path hidden]');
      expect(row['ratio'], '3/4');
      expect(row['text'], 'a: b');
      expect(row['title'], 'Intro');
    });

    test(
      'every tool has a tier and an object schema; nothing touches files',
      () {
        final specs = toolSpecs();
        expect(specs.length, tools.length);
        expect({for (final s in specs) s['name']}.length, specs.length);
        for (final s in specs) {
          final schema = s['input_schema']! as Map;
          expect(schema['type'], 'object');
          expect(schema['properties'], isA<Map>());
          final n = s['name']! as String;
          for (final bad in [
            'write_',
            'delete_',
            'move_',
            'rename_',
            'copy_',
            'rollback',
            'gigpack',
          ]) {
            expect(
              n.startsWith(bad) || n.contains('files'),
              isFalse,
              reason: n,
            );
          }
        }
        for (final t in [
          'create_crate',
          'add_to_crate',
          'remove_from_crate',
          'update_tracks',
          'tag_tracks',
          'start_scan',
          'start_analysis',
          'save_set',
          'start_gig_mode',
          'end_gig_mode',
          'change_setting',
          'apply_crate_template',
          'find_local_suggestions',
        ]) {
          expect(tierOf(t), Tier.act, reason: t);
        }
        expect(
          assistantGuide,
          allOf(contains('Camelot wheel'), contains('never written')),
        );
        expect(
          File('../docs/ASSISTANT_GUIDE.md').readAsStringSync(),
          assistantGuide,
          reason: 'run tool/gen_guide.py after editing the guide',
        );
      },
    );

    late Directory music;
    late AppSession app;
    late _ScriptedModel model;
    setUp(() async {
      music = copyLibrary();
      model = _ScriptedModel();
      app = AppSession(
        dbPath: p.join(music.parent.path, 'catalogue.sqlite3'),
        online: model,
        secrets: MemorySecrets(),
      );
      app.roots.add(music.path);
      await runScan(app.cat);
    });
    tearDown(() async {
      await app.close();
      music.parent.deleteSync(recursive: true);
    });

    test('reads run by themselves, actions wait for the DJ', () async {
      final agent = Agent(app);
      await expectLater(
        agent.chat(null, 'hi'),
        throwsA(isA<AgentException>()),
        reason: 'off by default',
      );
      app.settings.set('ai_provider', 'claude');
      expect((await agent.status())['ready'], isFalse);
      app.settings.setSecret('anthropic', 'sk-ant-test');
      final st = await agent.status();
      expect(st['ready'], isTrue);
      expect(st['sends'] as String, contains('Anthropic'));

      final hello = await agent.chat(null, 'hello');
      expect(hello.text, 'Hello! Ask me about your library.');
      expect(model.seen.first, contains('<app_state>tracks: 22'));

      final t = await agent.chat(hello.conversationId, 'make me an afro crate');
      expect(t.lookedUp, ['search tracks']);
      expect(t.pending.map((p) => p.tool), ['create_crate', 'change_setting']);
      expect(
        t.pending.first.summary,
        startsWith('Create smart crate “AI Afrobeats”'),
      );
      expect(app.crates.list().where((c) => c.name == 'AI Afrobeats'), isEmpty);
      // run the crate, skip the setting
      final done = await agent.confirm(t.conversationId, {
        t.pending[0].id: true,
        t.pending[1].id: false,
      });
      expect(done.done.map((d) => d['ok']), [true, false]);
      expect(done.text, startsWith('Done: '));
      expect(done.text, contains('ERR:The DJ chose not to run'));
      expect(
        app.crates.list().where((c) => c.name == 'AI Afrobeats'),
        hasLength(1),
      );
      expect(app.settings.all()['key_notation'], 'camelot');

      final shown = await agent.chat(t.conversationId, 'show afrobeats');
      expect(shown.uiActions.map((a) => a['type']), [
        'show_tracks',
        'open_view',
      ]);

      final d = await agent.chat(t.conversationId, 'track detail please');
      expect(d.lookedUp, ['get track', 'library overview']);
      expect(model.seen.last, contains('Unknown tool'));
      expect(model.seen.last, isNot(contains(music.path)));
    });
  });
}

/// The scripted model of 1.x `FakeOnline::llm_chat`.
class _ScriptedModel extends Online {
  final seen = <String>[];

  @override
  Future<Map<String, Object?>> llmChat(
    LlmConfig cfg,
    String system,
    List<Map<String, Object?>> tools,
    List<Map<String, Object?>> messages,
  ) async {
    expect(system, contains('Camelot wheel'));
    expect(tools.any((t) => t['name'] == 'create_crate'), isTrue);
    final last = messages.last;
    final blocks = [for (final b in last['content']! as List) b as Map];
    seen.add(jsonEncode(last));
    if (blocks.any((b) => b['type'] == 'tool_result')) {
      final summary = [
        for (final b in blocks)
          '${b['is_error'] == true ? 'ERR:' : ''}${(b['content'] as String? ?? '').characters60}',
      ];
      return {
        'model': cfg.model,
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': 'Done: ${summary.join(' | ')}'},
        ],
      };
    }
    final text = [
      for (final b in blocks)
        if (b['text'] is String &&
            !(b['text'] as String).startsWith('<app_state>'))
          b['text'] as String,
    ].join(' ').toLowerCase();
    final afro = {
      'match': 'all',
      'rules': [
        {
          'kind': 'condition',
          'field': 'genre',
          'op': 'equals',
          'value': 'Afrobeats',
        },
      ],
    };
    final List<Map<String, Object?>> content;
    if (text.contains('crate')) {
      content = [
        {'type': 'thinking', 'thinking': '', 'signature': 'sig'},
        {'type': 'text', 'text': 'Afrobeats crate coming up.'},
        {
          'type': 'tool_use',
          'id': 't1',
          'name': 'search_tracks',
          'input': {'filters': afro, 'limit': 5},
        },
        {
          'type': 'tool_use',
          'id': 't2',
          'name': 'create_crate',
          'input': {
            'name': 'AI Afrobeats',
            'kind': 'smart',
            'rules': afro,
            'color': 'green',
          },
        },
        {
          'type': 'tool_use',
          'id': 't3',
          'name': 'change_setting',
          'input': {'setting': 'key_notation', 'value': 'musical'},
        },
      ];
    } else if (text.contains('show')) {
      content = [
        {
          'type': 'tool_use',
          'id': 's1',
          'name': 'show_tracks',
          'input': {'filters': afro, 'label': 'Afrobeats'},
        },
        {
          'type': 'tool_use',
          'id': 's2',
          'name': 'open_view',
          'input': {'view': 'library'},
        },
      ];
    } else if (text.contains('detail')) {
      content = [
        {
          'type': 'tool_use',
          'id': 'd1',
          'name': 'get_track',
          'input': {'id': 1},
        },
        {
          'type': 'tool_use',
          'id': 'd2',
          'name': 'library_overview',
          'input': <String, Object?>{},
        },
        {
          'type': 'tool_use',
          'id': 'd3',
          'name': 'delete_files',
          'input': <String, Object?>{},
        },
      ];
    } else {
      content = [
        {'type': 'text', 'text': 'Hello! Ask me about your library.'},
      ];
    }
    return {
      'model': cfg.model,
      'stop_reason': content.any((b) => b['type'] == 'tool_use')
          ? 'tool_use'
          : 'end_turn',
      'content': content,
    };
  }
}

extension on String {
  String get characters60 =>
      runes.length <= 60 ? this : String.fromCharCodes(runes.take(60));
}
