/// AI model providers for the assistant (1.x `dj-online/llm.rs`).
///
/// * Claude (Anthropic Messages API) with the DJ's own key.
/// * OpenAI-compatible services (OpenAI, Gemini, Groq, Mistral, DeepSeek, xAI…).
/// * Local (Ollama on this computer): nothing leaves the machine.
///
/// The conversation is kept in the Messages format and converted on the way
/// out; replies are converted back.
library;

import 'dart:convert';

import 'online.dart';
import 'parsers.dart';

typedef Json = Map<String, Object?>;

const anthropicUrl = 'https://api.anthropic.com/v1/messages';
const anthropicVersion = '2026-10-21';

/// Server-side refusal fallback ("default" form).
const fallbackBeta = 'server-side-fallback-2026-07-01';
const maxTokens = 8000;

/// Models that accept `fallbacks: "default"` on the Claude API.
bool supportsFallback(String model) => const {
  'claude-opus-5-5',
  'claude-sonnet-5-5',
  'claude-fable-5-1',
}.contains(model);

/// Request body for the Messages API. The system prompt (the app guide) and
/// the tool list are stable, so they are cached across turns.
Json claudeBody(
  String model,
  String system,
  List<Json> tools,
  List<Json> messages,
) => {
  'model': model,
  'max_tokens': maxTokens,
  'system': [
    {
      'type': 'text',
      'text': system,
      'cache_control': {'type': 'ephemeral'},
    },
  ],
  'tools': tools,
  'messages': messages,
  'output_config': {'effort': 'medium'},
  if (supportsFallback(model)) 'fallbacks': 'default',
};

String claudeError(int status, Object? body) {
  final msg = str(at(body, 'error/message')) ?? 'request failed';
  return switch (status) {
    401 || 403 =>
      'Anthropic rejected the API key. Check it in Settings → AI assistant.',
    429 => "Anthropic's rate limit was reached. Wait a moment and try again.",
    529 || 503 => 'Anthropic is busy right now. Try again shortly.',
    _ => '$msg (HTTP $status)',
  };
}

List<Json> _blocks(Object? content) => switch (content) {
  final String s => [
    {'type': 'text', 'text': s},
  ],
  final List l => [
    for (final b in l)
      if (b is Map) Map<String, Object?>.from(b),
  ],
  _ => [],
};

String _contentText(Object? c) => c is String ? c : jsonEncode(c);

/// Messages-format conversation -> Ollama /api/chat messages.
List<Json> toOllamaMessages(String system, List<Json> messages) {
  final out = <Json>[
    {'role': 'system', 'content': system},
  ];
  final names = <String, String>{};
  for (final m in messages) {
    final role = str(m['role']) ?? 'user';
    final blocks = _blocks(m['content']);
    if (role == 'assistant') {
      final text = [
        for (final b in blocks)
          if (b['type'] == 'text' && b['text'] is String) b['text']! as String,
      ];
      final calls = <Json>[];
      for (final b in blocks.where((b) => b['type'] == 'tool_use')) {
        if (b['id'] is String && b['name'] is String) {
          names[b['id']! as String] = b['name']! as String;
        }
        calls.add({
          'function': {'name': b['name'], 'arguments': b['input']},
        });
      }
      out.add({
        'role': 'assistant',
        'content': text.join('\n'),
        if (calls.isNotEmpty) 'tool_calls': calls,
      });
    } else {
      final text = <String>[];
      for (final b in blocks) {
        switch (b['type']) {
          case 'tool_result':
            final id = str(b['tool_use_id']) ?? '';
            out.add({
              'role': 'tool',
              'content': _contentText(b['content']),
              'tool_name': ?names[id],
            });
          case 'text':
            text.add(str(b['text']) ?? '');
        }
      }
      if (text.isNotEmpty) {
        out.add({'role': 'user', 'content': text.join('\n\n')});
      }
    }
  }
  return out;
}

List<Json> toOllamaTools(List<Json> tools) => [
  for (final t in tools)
    {
      'type': 'function',
      'function': {
        'name': t['name'],
        'description': t['description'],
        'parameters': t['input_schema'],
      },
    },
];

Json _args(Object? a) {
  var v = a;
  if (v is String) {
    try {
      v = jsonDecode(v);
    } on FormatException {
      v = null;
    }
  }
  return v is Map ? Map<String, Object?>.from(v) : <String, Object?>{};
}

/// A counter for tool-call ids made up for providers that give none.
class CallSeq {
  int value = 0;
}

/// Ollama reply -> Messages-format reply.
Json fromOllama(Object? v, CallSeq seq) {
  final content = <Json>[];
  final t = str(at(v, 'message/content'));
  if (t != null && t.trim().isNotEmpty) {
    content.add({'type': 'text', 'text': t});
  }
  var usedTool = false;
  for (final c in list(at(v, 'message/tool_calls'))) {
    seq.value++;
    content.add({
      'type': 'tool_use',
      'id': 'local_${seq.value}',
      'name': at(c, 'function/name'),
      'input': _args(at(c, 'function/arguments')),
    });
    usedTool = true;
  }
  return {
    'content': content,
    'stop_reason': usedTool
        ? 'tool_use'
        : (at(v, 'done_reason') == 'length' ? 'max_tokens' : 'end_turn'),
    'model': at(v, 'model'),
  };
}

/// Messages-format conversation -> OpenAI chat-completions messages (tool ids
/// kept, so each tool result answers the call that asked for it).
List<Json> toOpenaiMessages(String system, List<Json> messages) {
  final out = <Json>[
    {'role': 'system', 'content': system},
  ];
  for (final m in messages) {
    final role = str(m['role']) ?? 'user';
    final blocks = _blocks(m['content']);
    if (role == 'assistant') {
      final text = [
        for (final b in blocks)
          if (b['type'] == 'text' && b['text'] is String) b['text']! as String,
      ];
      final calls = [
        for (final b in blocks.where((b) => b['type'] == 'tool_use'))
          {
            'id': b['id'],
            'type': 'function',
            'function': {
              'name': b['name'],
              'arguments': jsonEncode(b['input']),
            },
          },
      ];
      out.add({
        'role': 'assistant',
        'content': (calls.isNotEmpty && text.isEmpty) ? null : text.join('\n'),
        if (calls.isNotEmpty) 'tool_calls': calls,
      });
    } else {
      final text = <String>[];
      for (final b in blocks) {
        switch (b['type']) {
          case 'tool_result':
            out.add({
              'role': 'tool',
              'tool_call_id': b['tool_use_id'],
              'content': _contentText(b['content']),
            });
          case 'text':
            text.add(str(b['text']) ?? '');
        }
      }
      if (text.isNotEmpty) {
        out.add({'role': 'user', 'content': text.join('\n\n')});
      }
    }
  }
  return out;
}

Json openaiBody(
  String model,
  String system,
  List<Json> tools,
  List<Json> messages,
) => {
  'model': model,
  'messages': toOpenaiMessages(system, messages),
  if (tools.isNotEmpty) 'tools': toOllamaTools(tools),
};

/// OpenAI chat-completions reply -> Messages-format reply.
Json fromOpenai(Object? v, CallSeq seq) {
  final choice = at(v, 'choices/0');
  final content = <Json>[];
  final t = str(at(choice, 'message/content'));
  if (t != null && t.trim().isNotEmpty) {
    content.add({'type': 'text', 'text': t});
  }
  var usedTool = false;
  for (final c in list(at(choice, 'message/tool_calls'))) {
    seq.value++;
    final id = str(at(c, 'id'));
    content.add({
      'type': 'tool_use',
      'id': (id != null && id.isNotEmpty) ? id : 'call_${seq.value}',
      'name': at(c, 'function/name'),
      'input': _args(at(c, 'function/arguments')),
    });
    usedTool = true;
  }
  return {
    'content': content,
    'stop_reason': usedTool
        ? 'tool_use'
        : (at(choice, 'finish_reason') == 'length' ? 'max_tokens' : 'end_turn'),
    'model': at(v, 'model'),
  };
}

String openaiError(String label, int status, Object? body) {
  final msg =
      str(at(body, 'error/message')) ??
      str(at(body, '0/error/message')) ??
      str(at(body, 'error')) ??
      'request failed';
  if (status == 401 || status == 403) {
    return '$label rejected the API key. Check it in Settings → AI assistant.';
  }
  if (status == 429) {
    return "$label's rate limit or credit was reached. Wait a moment, or check your plan. ($msg)";
  }
  if (status == 404) {
    return "$label doesn't have that model ($msg). Pick another in Settings → AI assistant.";
  }
  if (status >= 500 && status <= 599) {
    return '$label is having trouble right now. Try again shortly. (HTTP $status)';
  }
  return '$msg (HTTP $status)';
}

/// A service saying the chosen model can't call tools.
bool openaiNoTools(int status, Object? body) {
  final m = jsonEncode(body).toLowerCase();
  return (status == 400 || status == 404 || status == 422) &&
      m.contains('tool') &&
      (m.contains('not support') ||
          m.contains('unsupported') ||
          m.contains('not enabled') ||
          m.contains('not available'));
}

/// Ollama runs models with a small context window unless asked for more, and
/// the app guide plus tools alone are several thousand tokens.
Json ollamaBody(
  String model,
  String system,
  List<Json> tools,
  List<Json> messages, [
  int? numCtx,
]) {
  final body = <String, Object?>{
    'model': model,
    'messages': toOllamaMessages(system, messages),
    'stream': false,
    // models without tool support reject any "tools" field, even an empty one
    if (tools.isNotEmpty) 'tools': toOllamaTools(tools),
  };
  body['options'] = {'num_ctx': numCtx ?? contextFor(body)};
  return body;
}

/// Estimated size (about 3 bytes per token) plus room for the reply, as a
/// power of two between 8192 and 32768 tokens.
int contextFor(Json body) {
  final est = utf8.encode(jsonEncode(body)).length ~/ 3;
  final c = fitContext(est);
  return c < 32768 ? c : 32768;
}

/// The smallest power-of-two window (at least 8192) holding [tokens] + 2048.
int fitContext(int tokens) {
  var p = 1;
  while (p < tokens + 2048) {
    p <<= 1;
  }
  return p.clamp(8192, 131072);
}

/// Ollama's "request (7010 tokens) exceeds the available context size": 7010.
int? ollamaTooLong(Object? v) {
  final e = str(at(v, 'error'));
  if (e == null) return null;
  if (!e.contains('exceeds the available context size') &&
      !e.contains('context length')) {
    return null;
  }
  final i = e.indexOf('(');
  if (i < 0) return null;
  final w = e.substring(i + 1).trim().split(RegExp(r'\s+')).first;
  return int.tryParse(w);
}

bool ollamaNoTools(Object? v) => (str(at(v, 'error')) ?? '')
    .toLowerCase()
    .contains('does not support tools');

/// Every model in an Ollama `/api/tags` reply; embedding models can't chat.
List<LocalModel> parseOllamaTags(Object? v) => [
  for (final m in list(at(v, 'models')))
    if (str(at(m, 'name')) ?? str(at(m, 'model')) case final name?)
      () {
        final family = str(at(m, 'details/family')) ?? '';
        final families = [
          for (final f in list(at(m, 'details/families')))
            if (f is String) f,
        ];
        final embed =
            name.toLowerCase().contains('embed') ||
            [family, ...families].any((f) => f.contains('bert'));
        return LocalModel(
          name: name,
          size: integer(at(m, 'size')) ?? 0,
          family: family,
          parameters: str(at(m, 'details/parameter_size')) ?? '',
          canChat: !embed,
        );
      }(),
];

/// Sums Ollama's per-layer download progress into one figure.
class PullProgress {
  final _layers = <String, (int, int)>{};

  /// (done bytes, total bytes, status text, finished). Throws on an error event.
  (int, int, String, bool) update(Object? ev) {
    if (str(at(ev, 'error')) case final e?) throw OnlineException(e);
    final status = str(at(ev, 'status')) ?? '';
    if (str(at(ev, 'digest')) case final d?) {
      final total = integer(at(ev, 'total')) ?? 0;
      final done = integer(at(ev, 'completed')) ?? 0;
      final cur = _layers[d] ?? (0, 0);
      _layers[d] = (
        done > cur.$1 ? done : cur.$1,
        total > cur.$2 ? total : cur.$2,
      );
    }
    var done = 0, total = 0;
    for (final l in _layers.values) {
      done += l.$1;
      total += l.$2;
    }
    return (done, total, status, status == 'success');
  }
}
