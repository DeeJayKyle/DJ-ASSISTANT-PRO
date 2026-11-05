import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/settings.dart';
import 'package:dj_assistant/online/llm.dart';
import 'package:dj_assistant/online/online.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ports of 1.x `dj-online/llm.rs` tests and the settings checks of `tests/v1.rs`.
void main() {
  group('model conversions', () {
    test('scans installed models and spots embedding models', () {
      final m = parseOllamaTags({
        'models': [
          {
            'name': 'mistral:latest',
            'size': 4100000000,
            'details': {'family': 'llama', 'parameter_size': '7.2B'},
          },
          {
            'name': 'nomic-embed-text:latest',
            'size': 274000000,
            'details': {
              'family': 'nomic-bert',
              'families': ['nomic-bert'],
            },
          },
          {
            'name': 'gemma2:2b',
            'size': 1600000000,
            'details': {'family': 'gemma2', 'parameter_size': '2.6B'},
          },
        ],
      });
      expect(m.map((x) => x.name), [
        'mistral:latest',
        'nomic-embed-text:latest',
        'gemma2:2b',
      ]);
      expect([for (final x in m) x.canChat], [true, false, true]);
      expect(m[0].parameters, '7.2B');
      expect(m[0].size, 4100000000);
      expect(parseOllamaTags(<String, Object?>{}), isEmpty);
    });

    test('OpenAI round trip keeps tool ids', () {
      final conv = <Json>[
        {'role': 'user', 'content': 'show me house'},
        {
          'role': 'assistant',
          'content': [
            {
              'type': 'tool_use',
              'id': 'call_9',
              'name': 'search_tracks',
              'input': {'text': 'house'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {'type': 'tool_result', 'tool_use_id': 'call_9', 'content': '[]'},
          ],
        },
      ];
      final m = toOpenaiMessages('GUIDE', conv);
      expect(m[0]['role'], 'system');
      final calls = m[2]['tool_calls']! as List;
      expect((calls[0] as Map)['id'], 'call_9');
      expect(
        ((calls[0] as Map)['function'] as Map)['arguments'],
        '{"text":"house"}',
      );
      expect(m[2]['content'], isNull);
      expect(m[3]['role'], 'tool');
      expect(m[3]['tool_call_id'], 'call_9');
      final seq = CallSeq();
      var r = fromOpenai({
        'model': 'gpt-x',
        'choices': [
          {
            'finish_reason': 'tool_calls',
            'message': {
              'content': null,
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'search_tracks',
                    'arguments': '{"text":"afro"}',
                  },
                },
              ],
            },
          },
        ],
      }, seq);
      expect(r['stop_reason'], 'tool_use');
      final c0 = (r['content']! as List)[0] as Map;
      expect(c0['id'], 'call_1');
      expect((c0['input'] as Map)['text'], 'afro');
      r = fromOpenai({
        'choices': [
          {
            'finish_reason': 'stop',
            'message': {'content': 'Hi'},
          },
        ],
      }, seq);
      expect(r['stop_reason'], 'end_turn');
      expect(((r['content']! as List)[0] as Map)['text'], 'Hi');
      expect(openaiBody('m', 's', [], conv).containsKey('tools'), isFalse);
      expect(
        openaiError('OpenAI', 401, <String, Object?>{}),
        contains('OpenAI rejected the API key'),
      );
      expect(
        openaiNoTools(400, {
          'error': {'message': 'This model does not support tools'},
        }),
        isTrue,
      );
      expect(
        openaiNoTools(400, {
          'error': {'message': 'bad request'},
        }),
        isFalse,
      );
    });

    test('asks Ollama for a big enough context', () {
      Object? ctx(Json b) => (b['options']! as Map)['num_ctx'];
      expect(ctx(ollamaBody('m', 'hi', [], [])), 8192);
      expect(ctx(ollamaBody('m', 'x' * 30000, [], [])), 16384);
      expect(ctx(ollamaBody('m', 'hi', [], [], 65536)), 65536);
      expect(fitContext(7010), 16384);
      expect(fitContext(1), 8192);
      expect(
        ollamaTooLong({
          'error': 'request (7010 tokens) exceeds the available context size (4096 tokens), try increasing it',
        }),
        7010,
      );
      expect(ollamaTooLong({'error': 'model not found'}), isNull);
    });

    test('plain chat for models without tools', () {
      expect(
        ollamaNoTools({
          'error':
              'registry.ollama.ai/library/gemma2:2b does not support tools',
        }),
        isTrue,
      );
      expect(ollamaNoTools({'error': 'model not found'}), isFalse);
      expect(
        ollamaBody('gemma2:2b', 'sys', [], []).containsKey('tools'),
        isFalse,
      );
      final b = ollamaBody('qwen2.5:7b', 'sys', [
        {'name': 't', 'description': 'd', 'input_schema': <String, Object?>{}},
      ], []);
      expect((b['tools']! as List).length, 1);
    });

    test('pull progress sums layers and reports errors', () {
      final p = PullProgress();
      expect(p.update({'status': 'pulling manifest'}), (
        0,
        0,
        'pulling manifest',
        false,
      ));
      p.update({
        'status': 'pulling a',
        'digest': 'a',
        'total': 100,
        'completed': 40,
      });
      var r = p.update({
        'status': 'pulling b',
        'digest': 'b',
        'total': 50,
        'completed': 10,
      });
      expect((r.$1, r.$2), (50, 150));
      // completed never goes backwards for a layer
      r = p.update({'status': 'pulling a', 'digest': 'a', 'total': 100});
      expect(r.$1, 50);
      expect(p.update({'status': 'success'}).$4, isTrue);
      expect(
        () => p.update({'error': 'pull model manifest: file does not exist'}),
        throwsA(
          isA<OnlineException>().having(
            (e) => e.message,
            'm',
            'pull model manifest: file does not exist',
          ),
        ),
      );
    });

    test('Claude body caches the guide and opts into fallbacks', () {
      final b = claudeBody(
        'claude-opus-5-5',
        'GUIDE',
        [
          {'name': 't'},
        ],
        [
          {'role': 'user', 'content': 'hi'},
        ],
      );
      expect(
        (((b['system']! as List)[0] as Map)['cache_control'] as Map)['type'],
        'ephemeral',
      );
      expect(b['fallbacks'], 'default');
      expect((b['output_config']! as Map)['effort'], 'medium');
      expect(
        b.containsKey('temperature') ||
            b.containsKey('thinking') ||
            b.containsKey('tool_choice'),
        isFalse,
      );
      expect(
        claudeBody('claude-haiku-5-5', 'G', [], []).containsKey('fallbacks'),
        isFalse,
      );
    });

    test('Ollama round trip keeps tool calls and results paired', () {
      final o = toOllamaMessages('SYS', [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '<app_state>x</app_state>'},
            {'type': 'text', 'text': 'show house'},
          ],
        },
        {
          'role': 'assistant',
          'content': [
            {'type': 'thinking', 'thinking': '', 'signature': 's'},
            {'type': 'text', 'text': 'Looking'},
            {
              'type': 'tool_use',
              'id': 'local_1',
              'name': 'search_tracks',
              'input': {'text': 'house'},
            },
          ],
        },
        {
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'local_1',
              'content': '{"total":3}',
            },
          ],
        },
      ]);
      expect(o[0]['role'], 'system');
      expect(o[1]['content'], '<app_state>x</app_state>\n\nshow house');
      expect(
        (((o[2]['tool_calls']! as List)[0] as Map)['function'] as Map)['name'],
        'search_tracks',
      );
      expect(o[3]['role'], 'tool');
      expect(o[3]['tool_name'], 'search_tracks');
      final seq = CallSeq()..value = 1;
      final r = fromOllama({
        'model': 'qwen2.5:7b',
        'message': {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {
              'function': {
                'name': 'show_tracks',
                'arguments': '{"text":"house"}',
              },
            },
          ],
        },
        'done_reason': 'stop',
      }, seq);
      expect(r['stop_reason'], 'tool_use');
      final c0 = (r['content']! as List)[0] as Map;
      expect((c0['input'] as Map)['text'], 'house');
      expect(c0['id'], 'local_2');
      expect(
        fromOllama({
          'message': {'content': 'Done.'},
          'done_reason': 'stop',
        }, seq)['stop_reason'],
        'end_turn',
      );
    });
  });

  group('settings', () {
    late Catalogue cat;
    late SettingsService s;
    late MemorySecrets secrets;
    setUp(() {
      cat = Catalogue.inMemory();
      secrets = MemorySecrets();
      s = SettingsService(cat, secrets);
    });
    tearDown(() => cat.close());

    test('defaults and validation match 1.x', () {
      final a = s.all();
      expect(a['theme'], 'dark');
      expect(a['allow_file_changes'], false);
      expect(a['ai_provider'], 'off');
      expect(a['low_bitrate_kbps'], 128);
      s.set('low_bitrate_kbps', 192);
      expect(s.all()['low_bitrate_kbps'], 192);
      for (final (k, v) in <(String, Object?)>[
        ('low_bitrate_kbps', 4),
        ('low_bitrate_kbps', 1.5),
        ('theme', 'pink'),
        ('auto_fix_min', 0.2),
        ('ai_provider', 'nope'),
        ('ai_model_openai', 'bad model name!'),
        ('ai_custom_url', 'http://example.com/v1'),
        ('ai_local_url', 'http://192.168.1.4:11434'),
        ('nonsense', true),
      ]) {
        expect(() => s.set(k, v), throwsA(isA<SettingsException>()), reason: k);
      }
      s
        ..set('ai_custom_url', 'http://127.0.0.1:1234/v1/')
        ..set('ai_local_url', 'http://localhost:11434');
      expect(cat.getSetting('ai_custom_url'), 'http://127.0.0.1:1234/v1');
      s.set('allow_file_changes', true);
      expect(s.all()['allow_file_changes'], true);
    });

    test('services are off by default and keys are never shown', () {
      expect(
        s.services().where((x) => x['enabled'] == true).map((x) => x['id']),
        ['updates'],
      );
      expect(
        () => s.setSecret('acoustid', 'has spaces'),
        throwsA(isA<SettingsException>()),
      );
      expect(
        () => s.setSecret('spotify', 'no-colon'),
        throwsA(isA<SettingsException>()),
      );
      expect(
        () => s.setSecret('anthropic', 'sk-x'),
        throwsA(isA<SettingsException>()),
      );
      expect(
        () => s.setSecret('ai_nope', 'k'),
        throwsA(isA<SettingsException>()),
      );
      s
        ..setSecret('acoustid', 'test-key')
        ..setSecret('ai_openai', 'sk-proj-test');
      final ac = s.services().firstWhere((x) => x['id'] == 'acoustid');
      expect(ac['has_key'], true);
      expect('${s.services()}', isNot(contains('test-key')));
      // the online-assistant switch remembers the chosen service
      s.set('ai_provider', 'openai');
      s.setService('anthropic', false);
      expect(cat.getSetting('ai_provider'), 'off');
      s.setService('anthropic', true);
      expect(cat.getSetting('ai_provider'), 'openai');
      s.setService('lastfm', true);
      expect(cat.getSetting('svc_lastfm'), '1');
      expect(
        () => s.setService('nope', true),
        throwsA(isA<SettingsException>()),
      );
      s.deleteSecret('acoustid');
      expect(secrets.get('acoustid'), isNull);
    });
  });
}
