import 'dart:collection';
import 'dart:convert';

import '../app/session.dart';
import '../core/catalogue.dart';
import '../core/jobs.dart';
import '../online/online.dart';
import 'agent.dart';
import 'ai_config.dart';

/// Quick Prep's optional AI help (1.x `quick.rs`): sharper clean names and
/// genres, and set orders from a request in plain words. It uses the
/// assistant's model and is off while the assistant is off.
///
/// Only file names, tag text and the BPM/key/energy already known are sent —
/// never audio, paths or listening history. Answers are suggestions.

/// The text of a Messages-format reply.
String replyText(Object? v) => v is Map && v['content'] is List
    ? [
        for (final b in v['content'] as List)
          if (b is Map && b['text'] is String) b['text'] as String,
      ].join('\n')
    : '';

/// The JSON object in a model's answer (it may add ``` fences or prose).
Object? extractJson(String text) {
  var t = text.trim();
  for (final p in ['```json', '```']) {
    while (t.startsWith(p)) {
      t = t.substring(p.length);
    }
  }
  while (t.endsWith('```')) {
    t = t.substring(0, t.length - 3);
  }
  t = t.trim();
  try {
    return jsonDecode(t);
  } on FormatException {
    final a = t.indexOf('{'), b = t.lastIndexOf('}');
    if (a < 0 || b < 0 || a >= b) return null;
    try {
      return jsonDecode(t.substring(a, b + 1));
    } on FormatException {
      return null;
    }
  }
}

/// JSON with sorted keys, as 1.x (serde_json) writes it.
String canonicalJson(Object? v) => jsonEncode(_sorted(v));
Object? _sorted(Object? v) => switch (v) {
  final Map m => SplayTreeMap<String, Object?>.from({
    for (final e in m.entries) '${e.key}': _sorted(e.value),
  }),
  final List l => [for (final x in l) _sorted(x)],
  _ => v,
};

double? _r1(Object? b) => b is num ? (b * 10).round() / 10 : null;

class TidyResult {
  TidyResult(this.id, this.artist, this.title, this.mix, this.genre);
  final int id;
  final String artist, title, mix;
  final String? genre;
  Map<String, Object?> toJson() => {
    'id': id,
    'artist': artist,
    'title': title,
    'mix': mix,
    'genre': genre,
  };
  @override
  bool operator ==(Object other) =>
      other is TidyResult &&
      other.id == id &&
      other.artist == artist &&
      other.title == title &&
      other.mix == mix &&
      other.genre == genre;
  @override
  int get hashCode => Object.hash(id, artist, title, mix, genre);
}

Map<String, Object?> _facts(Catalogue cat, int id) {
  final r = cat.db.select(
    'SELECT t.file_name, t.artist, t.title, t.genre, COALESCE(u.bpm,t.bpm_tag,a.bpm) AS bpm, '
    'keynorm(COALESCE(u.musical_key,t.key_tag,a.camelot)) AS k, COALESCE(u.energy,a.energy) AS e '
    'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
    [id],
  );
  if (r.isEmpty) throw AgentException('track $id not found');
  final x = r.first;
  return {
    'file': x['file_name'],
    'tags': {'artist': x['artist'], 'title': x['title'], 'genre': x['genre']},
    'bpm': _r1(x['bpm']),
    'key': x['k'],
    'energy': x['e'],
  };
}

/// (system, user) for a tidy request. [tracks] are (id, current suggestion).
(String, String) tidyPrompt(
  Catalogue cat,
  List<(int, Object?)> tracks,
  List<String> genres,
) {
  final items = [
    for (final (id, current) in tracks)
      {..._facts(cat, id), 'id': '$id', 'suggestion': current},
  ];
  final system = [
    'You help a DJ tidy their music library. For each track, return the real artist, the song title, and the mix/version name (e.g. "Original Mix", "Extended Mix", "Joe Remix", or empty), with normal capitalisation and without junk (track numbers, websites, "free download", bitrates, "final v3").',
    'Also choose the single best genre from this list: ${genres.join(', ')}.',
    'Use the file name, the tags, the BPM and energy (1-10) as clues. Keep stylised names as the artist writes them (e.g. "deadmau5"). If unsure, keep the suggestion you were given.',
    'Answer only with JSON: {"tracks":[{"id":"…","artist":"…","title":"…","mix":"…","genre":"…"}]}',
  ].join('\n');
  return (system, canonicalJson(items));
}

int? _idOf(Object? v) => switch (v) {
  final String s => int.tryParse(s),
  final int i => i,
  _ => null,
};

String _take(Object? v, int max) {
  final s = (v is String ? v : '').trim();
  final r = s.runes;
  return r.length <= max ? s : String.fromCharCodes(r.take(max));
}

/// The model's tidy answer; anything malformed or unknown is dropped.
List<TidyResult> parseTidy(String text, Set<int> ids, List<String> genres) {
  final v = extractJson(text);
  final list = v is Map && v['tracks'] is List
      ? v['tracks'] as List
      : (v is List ? v : const []);
  final out = <TidyResult>[];
  final seen = <int>{};
  for (final r in list.whereType<Map>()) {
    final id = _idOf(r['id']);
    if (id == null || !ids.contains(id) || !seen.add(id)) continue;
    final title = _take(r['title'], 200);
    if (title.isEmpty) continue;
    final g = _take(r['genre'], 60).toLowerCase();
    out.add(
      TidyResult(
        id,
        _take(r['artist'], 200),
        title,
        _take(r['mix'], 100),
        genres.where((x) => x.toLowerCase() == g).firstOrNull,
      ),
    );
  }
  return out;
}

(String, String) orderPrompt(Catalogue cat, String request, List<int> ids) {
  final items = [
    for (final id in ids)
      () {
        final r = cat.db.select(
          "SELECT COALESCE(u.artist,t.artist,'') AS a, COALESCE(u.title,t.title,t.file_name) AS t, "
          'COALESCE(u.genre,t.genre) AS g, COALESCE(u.bpm,t.bpm_tag,a.bpm) AS b, '
          'keynorm(COALESCE(u.musical_key,t.key_tag,a.camelot)) AS k, COALESCE(u.energy,a.energy) AS e '
          'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
          [id],
        );
        if (r.isEmpty) throw AgentException('track $id not found');
        final x = r.first;
        final a = x['a'] as String;
        return {
          'id': '$id',
          'name': a.isEmpty ? x['t'] : '$a - ${x['t']}',
          'bpm': _r1(x['b']),
          'key': x['k'],
          'energy': x['e'],
          'genre': x['g'],
        };
      }(),
  ];
  return (
    'You are a DJ planning a set. Reorder the tracks to fit the request. Prefer smooth mixing: close BPMs, harmonic keys on the Camelot wheel (same number, ±1, or A↔B), and an energy arc that suits the request. Use every track exactly once. Answer only with JSON: {"order":["id", …],"note":"one short sentence on the idea"}',
    'Request: ${_take(request, 500).isEmpty ? '' : String.fromCharCodes(request.runes.take(500))}\nTracks: ${canonicalJson(items)}',
  );
}

/// Every track exactly once: unknown ids dropped, forgotten ones appended.
(List<int>, String)? parseOrder(String text, List<int> ids) {
  final v = extractJson(text);
  if (v is! Map || v['order'] is! List) return null;
  final known = ids.toSet(), seen = <int>{};
  final order = <int>[];
  for (final x in v['order'] as List) {
    final id = _idOf(x);
    if (id != null && known.contains(id) && seen.add(id)) order.add(id);
  }
  order.addAll(ids.where((i) => !seen.contains(i)));
  final note = v['note'] is String ? v['note'] as String : '';
  return (order, String.fromCharCodes(note.runes.take(240)));
}

/// AI helpers over an app session (1.x `ai_tidy`, `ai_order`, `ai_complete`,
/// `ai_list_models`, `ai_local_*`, `ai_pack_setup`).
class AiHelpers {
  AiHelpers(this.app);
  final AppSession app;

  LlmConfig _on() {
    final cfg = llmConfig(app.cat, app.secrets);
    if (cfg.provider == 'off') {
      throw AgentException(
        'turn on the AI assistant in Settings first (Claude or a local model)',
      );
    }
    return cfg;
  }

  Future<String> _ask(LlmConfig cfg, String system, String user) async {
    try {
      final r = await app.online.llmChat(cfg, system, const [], [
        {'role': 'user', 'content': user},
      ]);
      return replyText(r);
    } on OnlineException catch (e) {
      throw AgentException(e.message);
    }
  }

  String _cap(String s) => String.fromCharCodes(s.runes.take(8000));

  /// One plain request to the assistant's model (Studio sound design).
  Future<String> complete(String system, String user) =>
      _ask(_on(), _cap(system), _cap(user));

  Future<List<TidyResult>> tidy(
    List<(int, Object?)> tracks,
    List<String> genres,
  ) async {
    final cfg = _on();
    if (tracks.isEmpty || tracks.length > 25) {
      throw AgentException('send between 1 and 25 tracks at a time');
    }
    final g = genres.take(300).toList();
    final (sys, user) = tidyPrompt(app.cat, tracks, g);
    return parseTidy(await _ask(cfg, sys, user), {
      for (final t in tracks) t.$1,
    }, g);
  }

  Future<(List<int>, String)> order(List<int> ids, String request) async {
    final cfg = _on();
    if (ids.length < 2 || ids.length > 300) {
      throw AgentException('an AI order needs between 2 and 300 tracks');
    }
    if (request.trim().isEmpty) {
      throw AgentException("say how you'd like the tracks ordered");
    }
    final (sys, user) = orderPrompt(app.cat, request, ids);
    final r = parseOrder(await _ask(cfg, sys, user), ids);
    if (r == null) {
      throw AgentException(
        "the AI didn't return a usable order; try rephrasing",
      );
    }
    return r;
  }

  Future<List<String>> listModels() async {
    final cfg = llmConfig(app.cat, app.secrets);
    if (cfg.baseUrl.isEmpty) {
      throw AgentException('choose an online AI service first');
    }
    try {
      return await app.online.llmListModels(cfg);
    } on OnlineException catch (e) {
      throw AgentException(e.message);
    }
  }

  Future<List<String>> installedLocalModels() async {
    try {
      return await app.online.llmLocalModels(
        llmConfig(app.cat, app.secrets).localUrl,
      );
    } on OnlineException catch (e) {
      throw AgentException(e.message);
    }
  }

  static bool _has(LocalProbe p, String model) => p.models.any(
    (m) => m == model || m.replaceAll(RegExp(r':latest$'), '') == model,
  );

  Future<Map<String, Object?>> localSetup() async {
    final cfg = llmConfig(app.cat, app.secrets);
    final probe = await app.online.llmLocalProbe(cfg.localUrl);
    return {
      'probe': probe.toJson(),
      'model': cfg.model,
      'has_model': _has(probe, cfg.model),
      'local_url': cfg.localUrl,
      'recommended': [
        for (final (id, size, note) in localModels)
          {'id': id, 'size': size, 'note': note},
      ],
      'download': app.jobs.status('ai_model').toJson(),
    };
  }

  /// Starts Ollama and waits up to 10 s for it to answer.
  Future<bool> localStart() async {
    try {
      await app.online.llmLocalStart();
    } on OnlineException catch (e) {
      throw AgentException(e.message);
    }
    final url = llmConfig(app.cat, app.secrets).localUrl;
    for (var i = 0; i < 40; i++) {
      if ((await app.online.llmLocalProbe(url)).running) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  /// Downloads a model into Ollama (a background job; not paused by gigs, it
  /// only talks to this computer).
  Map<String, Object?> localPull([String? model]) {
    final cfg = llmConfig(app.cat, app.secrets);
    final m = model ?? cfg.model;
    if (m.isEmpty ||
        m.length > 100 ||
        !RegExp(r'^[A-Za-z0-9:._\-/]+$').hasMatch(m)) {
      throw AgentException("that doesn't look like a model name");
    }
    final make = app.onlineFactory;
    final url = cfg.localUrl;
    app.jobs.start('ai_model', (ctx) async {
      ctx.message = 'Downloading $m…';
      await make().llmLocalPull(url, m, (done, total, status) {
        ctx
          ..total = total
          ..message = switch (status) {
            'success' => '$m is ready',
            final st when st.startsWith('pulling') && total > 0 =>
              'Downloading $m',
            final st => '$m: $st',
          };
        _setDone(ctx, done);
        return !ctx.cancelled;
      });
    }).ignore();
    return {'started': true};
  }

  /// One click: install Ollama if needed, start it, download the model and
  /// switch the assistant to it. Steps already done are skipped.
  Map<String, Object?> packSetup([String? model]) {
    final m = model ?? defaultLocalModel;
    if (!validModelName(m)) {
      throw AgentException("that doesn't look like a model name");
    }
    final url = llmConfig(app.cat, app.secrets).localUrl;
    final make = app.onlineFactory;
    final path = app.dbPath;
    app.jobs.start('ai_pack', (ctx) async {
      final online = make();
      void set(int done, int total, String msg) {
        ctx
          ..total = total
          ..message = msg;
        _setDone(ctx, done);
      }

      var probe = await online.llmLocalProbe(url);
      if (!probe.installed) {
        set(0, 0, 'Downloading Ollama…');
        await online.llmLocalInstall((d, t) {
          set(d, t, 'Downloading Ollama…');
          return !ctx.cancelled;
        });
        set(0, 0, 'Installing Ollama…');
        probe = await online.llmLocalProbe(url);
      }
      if (!probe.running) {
        set(0, 0, 'Starting Ollama…');
        await online.llmLocalStart();
        for (var i = 0; i < 120; i++) {
          if ((await online.llmLocalProbe(url)).running) break;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        probe = await online.llmLocalProbe(url);
        if (!probe.running) {
          throw OnlineException(
            "Ollama didn't start. Start it from the Start menu, then try again.",
          );
        }
      }
      if (!_has(probe, m)) {
        await online.llmLocalPull(url, m, (done, total, _) {
          set(done, total, 'Downloading the $m model…');
          return !ctx.cancelled;
        });
        if (ctx.cancelled) {
          set(
            0,
            0,
            'Stopped. Press the button again to pick up where it left off.',
          );
          return;
        }
      }
      final c = Catalogue.open(path);
      try {
        c
          ..setSetting('ai_local_model', m)
          ..setSetting('ai_provider', 'local');
      } finally {
        c.close();
      }
      set(1, 1, 'The assistant now runs privately on this computer with $m.');
    }).ignore();
    return {'started': true};
  }
}

/// Download progress is reported as bytes done of total.
void _setDone(JobContext ctx, int done) => ctx.progressTo(done);
