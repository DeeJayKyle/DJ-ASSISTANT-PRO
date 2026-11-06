import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../assistant/agent.dart';
import '../assistant/rule_assistant.dart';
import '../core/crates.dart';
import 'state.dart';
import 'theme.dart';

/// The assistant lives here for the whole session (the conversation survives
/// switching screens).
final agentProvider = Provider<Agent>(
  (ref) => Agent(ref.watch(sessionProvider)),
);

class _Msg {
  _Msg(this.role, this.text, {this.turn, this.reply, this.error = false});
  final String role; // user | bot | ai | cmd
  final String text;
  final Turn? turn;
  final AssistantReply? reply;
  final bool error;
  final decided = <String, bool>{};
}

/// Applies a screen change asked for by the assistant or a /command.
void applyUiAction(WidgetRef ref, Map<String, Object?> a) {
  final v = ref.read(viewProvider.notifier);
  if (a['type'] == 'show_tracks') {
    ref
        .read(libraryQueryProvider.notifier)
        .set(
          LibraryQuery(
            text: '${a['text'] ?? ''}',
            filters: a['filters'] is Map
                ? Map<String, Object?>.from(a['filters']! as Map)
                : null,
            label: a['label'] as String?,
          ),
        );
    v.go('library');
    return;
  }
  final view = '${a['view'] ?? 'library'}';
  switch (view) {
    case 'crate':
      v.go('crate', crateId: (a['crate_id'] as num?)?.toInt());
    case 'health-fix':
      v.go('health', params: {'fix': a['category'] ?? 'missing_genre'});
    case 'set-studio':
      v.go(
        'set-studio',
        params: a['set_params'] is Map
            ? Map<String, Object?>.from(a['set_params']! as Map)
            : null,
      );
    default:
      v.go(view);
  }
}

const _commands = [
  ('/scan', '', 'Scan your music folders (read-only)'),
  (
    '/analyse',
    '[all]',
    'Analyse tracks not analysed yet (all: redo every track)',
  ),
  ('/suggest', '', 'Find metadata suggestions in file and folder names'),
  ('/find', '<text>', 'Show matching tracks in the library'),
  ('/fix', 'genre|year|album|bpm|key|artist', 'Open the Library Health fixer'),
  ('/health', '', 'Open Library Health'),
  ('/dupes', '', 'Open Duplicate Review'),
  ('/crate', '<name>', 'Create an empty manual crate'),
  (
    '/set',
    '<minutes> [journey|warmup|peak|wedding|lounge] [clean]',
    'Open Set Studio pre-filled',
  ),
  ('/gig', 'start [name] | end', 'Start or end gig mode'),
  ('/keys', 'camelot|musical', 'Choose how keys are shown'),
  ('/premium', 'on|off', 'Premium UI (Midnight Pro look)'),
  ('/theme', 'dark|light', 'Switch theme'),
  ('/clear', '', 'Start a new conversation'),
  ('/help', '', 'List these commands'),
];

const _ruleSuggestions = [
  'Show low-bitrate Afrobeats tracks',
  'house 120-128 bpm',
  'plan a 2 hour wedding set',
  'show duplicates',
  'help',
];
const _aiSuggestions = [
  "What's in my library?",
  'Build me a peak-time Afrobeats crate',
  'Which tracks are missing genre or year?',
  'Plan a 2 hour wedding set, clean only',
];

class AssistantPanel extends ConsumerStatefulWidget {
  const AssistantPanel({super.key});
  @override
  ConsumerState<AssistantPanel> createState() => _AssistantPanelState();
}

class _AssistantPanelState extends ConsumerState<AssistantPanel> {
  final msgs = <_Msg>[];
  final input = TextEditingController();
  final scroll = ScrollController();
  bool busy = false;
  String? conv;
  Map<String, Object?>? status;

  @override
  void initState() {
    super.initState();
    _status();
  }

  Future<void> _status() async {
    final st = await ref.read(agentProvider).status();
    if (mounted) setState(() => status = st);
  }

  void _say(_Msg m) {
    setState(() => msgs.add(m));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _applyTurn(Turn t) {
    conv = t.conversationId;
    for (final a in t.uiActions) {
      applyUiAction(ref, a);
    }
    if (t.done.any((d) => d['ok'] == true)) {
      ref.read(versionProvider.notifier).bump();
    }
  }

  bool _command(String q) {
    final parts = q.trim().split(RegExp(r'\s+'));
    final cmd = parts.first.toLowerCase(),
        rest = parts.skip(1).toList(),
        arg = rest.join(' ');
    final s = ref.read(sessionProvider);
    void done(String t) => _say(_Msg('cmd', t));
    void bump() => ref.read(versionProvider.notifier).bump();
    switch (cmd) {
      case '/help':
        done(
          [
            for (final c in _commands)
              '${c.$1}${c.$2.isEmpty ? '' : ' ${c.$2}'} — ${c.$3}',
          ].join('\n'),
        );
      case '/clear':
        if (conv != null) ref.read(agentProvider).reset(conv!);
        setState(() {
          conv = null;
          msgs.clear();
        });
      case '/scan':
        s.startScan();
        done('Scan started (read-only). Progress is in Scan Activity.');
      case '/analyse' || '/analyze':
        s.startAnalysis(force: rest.firstOrNull == 'all');
        done(
          rest.firstOrNull == 'all'
              ? 'Re-analysing every track in the background.'
              : "Analysing tracks that aren't analysed yet, in the background.",
        );
      case '/suggest':
        final n = s.suggestions.generateLocal();
        done(
          'Found $n new suggestion${n == 1 ? '' : 's'}. Review them in Suggestions.',
        );
        bump();
      case '/find':
        applyUiAction(ref, {'type': 'show_tracks', 'text': arg});
        done('Showing tracks matching “$arg”.');
      case '/fix':
        const map = {
          'genre': 'missing_genre',
          'year': 'missing_year',
          'album': 'missing_album',
          'bpm': 'missing_bpm',
          'key': 'missing_key',
          'artist': 'missing_core',
          'title': 'missing_core',
        };
        final c = map[rest.firstOrNull?.toLowerCase()];
        if (c == null) {
          done('Use /fix genre, year, album, bpm, key or artist.');
        } else {
          applyUiAction(ref, {
            'type': 'open_view',
            'view': 'health-fix',
            'category': c,
          });
          done('Opened the fixer for missing ${rest.first}.');
        }
      case '/health':
        ref.read(viewProvider.notifier).go('health');
        done('Opened Library Health.');
      case '/dupes':
        ref.read(viewProvider.notifier).go('duplicates');
        done('Opened Duplicate Review.');
      case '/crate':
        if (arg.isEmpty) {
          done('Give the crate a name: /crate Peak Time Afro');
        } else {
          s.crates.create(CrateInput(name: arg, kind: 'manual'));
          done('Created the manual crate “$arg”. Add tracks from the library.');
          bump();
        }
      case '/set':
        final minutes =
            int.tryParse(
              rest.firstWhere(
                (x) => RegExp(r'^\d+$').hasMatch(x),
                orElse: () => '60',
              ),
            ) ??
            60;
        final curve = rest
            .where(
              (x) => [
                'journey',
                'warmup',
                'peak',
                'wedding',
                'lounge',
              ].contains(x),
            )
            .firstOrNull;
        applyUiAction(ref, {
          'type': 'open_view',
          'view': 'set-studio',
          'set_params': {
            'duration_min': minutes,
            'curve': ?curve,
            if (rest.contains('clean')) 'clean_only': true,
          },
        });
        done('Opened Set Studio for a $minutes-minute set.');
      case '/gig':
        if (rest.firstOrNull == 'end') {
          s.gig.end();
          done('Gig ended. The recap is in Gig Mode.');
        } else {
          s.gig.start(rest.length > 1 ? rest.skip(1).join(' ') : 'Gig');
          done('Gig mode on: background work is paused.');
        }
        bump();
      case '/keys':
        s.settings.set(
          'key_notation',
          rest.firstOrNull == 'musical' ? 'musical' : 'camelot',
        );
        done(
          'Keys now show in ${rest.firstOrNull == 'musical' ? 'musical' : 'Camelot'} notation.',
        );
        bump();
      case '/premium':
        s.settings.set('premium_ui', rest.firstOrNull != 'off');
        done('Premium UI ${rest.firstOrNull == 'off' ? 'off' : 'on'}.');
        bump();
      case '/theme':
        s.settings.set('theme', rest.firstOrNull == 'light' ? 'light' : 'dark');
        done('Theme: ${rest.firstOrNull == 'light' ? 'light' : 'dark'}.');
        bump();
      default:
        return false;
    }
    return true;
  }

  Future<void> _send([String? text]) async {
    final q = (text ?? input.text).trim();
    if (q.isEmpty || busy) return;
    input.clear();
    _say(_Msg('user', q));
    if (q.startsWith('/')) {
      try {
        if (!_command(q)) {
          _say(
            _Msg(
              'cmd',
              'Unknown command. Type /help for the list.',
              error: true,
            ),
          );
        }
      } on Object catch (e) {
        _say(_Msg('cmd', '$e', error: true));
      }
      return;
    }
    if (status?['ready'] == true) {
      setState(() => busy = true);
      try {
        final t = await ref.read(agentProvider).chat(conv, q);
        _say(_Msg('ai', t.text, turn: t));
        _applyTurn(t);
      } on Object catch (e) {
        _say(_Msg('ai', '$e', error: true));
      } finally {
        if (mounted) setState(() => busy = false);
      }
      return;
    }
    final r = ruleAssistant(ref.read(sessionProvider).cat, q);
    _say(_Msg('bot', r.reply, reply: r));
    if (r.action == 'search') {
      applyUiAction(ref, {
        'type': 'show_tracks',
        'text': r.text ?? '',
        'filters': r.filters,
      });
    } else if (r.action == 'navigate' && r.target != null) {
      applyUiAction(ref, {
        'type': 'open_view',
        'view': r.target,
        'set_params': r.params,
      });
    }
  }

  Future<void> _decide(_Msg m, Map<String, bool> d) async {
    setState(() {
      m.decided.addAll(d);
      busy = true;
    });
    try {
      final t = await ref
          .read(agentProvider)
          .confirm(m.turn!.conversationId, d);
      _say(_Msg('ai', t.text, turn: t));
      _applyTurn(t);
    } on Object catch (e) {
      _say(_Msg('ai', '$e', error: true));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final mode = ref.watch(chatModeProvider);
    final aiOn = status?['ready'] == true;
    return Container(
      decoration: BoxDecoration(
        color: t.panel,
        border: Border(left: BorderSide(color: t.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 6),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, color: t.accent, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Assistant',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Tooltip(
                  message: '${status?['sends'] ?? ''}',
                  child: Text(
                    aiOn
                        ? '${status?['label']} · ${status?['model']}'
                        : 'Built-in helper',
                    style: TextStyle(color: t.faint, fontSize: DjType.caption),
                  ),
                ),
                IconButton(
                  tooltip: mode == 'full' ? 'Make smaller' : 'Make larger',
                  onPressed: () => ref
                      .read(chatModeProvider.notifier)
                      .set(mode == 'full' ? 'open' : 'full'),
                  icon: Icon(
                    mode == 'full'
                        ? Icons.close_fullscreen
                        : Icons.open_in_full,
                    size: 18,
                  ),
                ),
                IconButton(
                  tooltip: 'Hide assistant (Ctrl+J)',
                  onPressed: () =>
                      ref.read(chatModeProvider.notifier).set('hidden'),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          if (!aiOn && status != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                '${status!['reason'] ?? ''}',
                style: TextStyle(color: t.faint, fontSize: DjType.small),
              ),
            ),
          const Divider(),
          Expanded(
            child: msgs.isEmpty
                ? ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      Text(
                        aiOn
                            ? 'Ask about your library or the app. Changes always wait for you to press Run.'
                            : "I'm the built-in helper (not an AI model). I turn requests into library filters and open screens. Everything stays on this computer.",
                        style: TextStyle(color: t.muted),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final s
                              in aiOn ? _aiSuggestions : _ruleSuggestions)
                            ActionChip(
                              label: Text(s),
                              onPressed: () => _send(s),
                            ),
                        ],
                      ),
                    ],
                  )
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: msgs.length + (busy ? 1 : 0),
                    itemBuilder: (c, i) => i == msgs.length
                        ? const Padding(
                            padding: EdgeInsets.all(8),
                            child: LinearProgressIndicator(),
                          )
                        : _bubble(context, msgs[i]),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: TextField(
              controller: input,
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: aiOn
                    ? 'Ask the assistant… (/ for commands)'
                    : 'Try “house 120-128 bpm” (/ for commands)',
                suffixIcon: IconButton(
                  onPressed: busy ? null : _send,
                  icon: const Icon(Icons.send),
                ),
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, _Msg m) {
    final t = DjTokens.of(context);
    final user = m.role == 'user';
    final turn = m.turn;
    final open =
        turn?.pending.where((p) => !m.decided.containsKey(p.id)).toList() ??
        const [];
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: user ? t.accent.withValues(alpha: 0.16) : t.panel2,
          borderRadius: BorderRadius.circular(12),
          border: m.error ? Border.all(color: t.danger) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m.text.isNotEmpty) RichReply(m.text, mono: m.role == 'cmd'),
            if (m.reply != null && m.reply!.understood.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Understood: ${m.reply!.understood.join(' · ')}',
                  style: TextStyle(color: t.faint, fontSize: DjType.caption),
                ),
              ),
            if (turn != null && turn.lookedUp.isNotEmpty)
              Text(
                'Looked up: ${turn.lookedUp.toSet().join(', ')}',
                style: TextStyle(color: t.faint, fontSize: DjType.caption),
              ),
            if (turn != null)
              for (final d in turn.done)
                Text(
                  '${d['ok'] == true ? '✓' : (d['skipped'] == true ? '–' : '✗')} ${d['summary']}${d['error'] != null ? ' (${d['error']})' : ''}',
                  style: TextStyle(
                    color: d['ok'] == true ? t.ok : t.faint,
                    fontSize: DjType.small,
                  ),
                ),
            if (turn != null && turn.pending.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final p in turn.pending)
                Card(
                  color: t.panel,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.play_circle_outline,
                          color: t.accent,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(child: Text(p.summary)),
                        if (m.decided.containsKey(p.id))
                          Text(
                            m.decided[p.id]! ? 'Run' : 'Skipped',
                            style: TextStyle(color: t.faint),
                          )
                        else ...[
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => _decide(m, {
                                    for (final x in open) x.id: x.id == p.id,
                                  }),
                            child: const Text('Skip others, run'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              if (open.isNotEmpty)
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy
                          ? null
                          : () =>
                                _decide(m, {for (final x in open) x.id: true}),
                      child: Text(
                        open.length == 1 ? 'Run' : 'Run all ${open.length}',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: busy
                          ? null
                          : () =>
                                _decide(m, {for (final x in open) x.id: false}),
                      child: const Text('Skip'),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Minimal, safe rendering of the model's text: paragraphs, lists, **bold**, `code`.
class RichReply extends StatelessWidget {
  const RichReply(this.src, {super.key, this.mono = false});
  final String src;
  final bool mono;
  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    List<InlineSpan> inline(String s) {
      final out = <InlineSpan>[];
      for (final m in RegExp(
        r'(\*\*[^*]+\*\*|`[^`]+`|[^*`]+|[*`])',
      ).allMatches(s)) {
        final p = m[0]!;
        if (p.length > 4 && p.startsWith('**') && p.endsWith('**')) {
          out.add(
            TextSpan(
              text: p.substring(2, p.length - 2),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          );
        } else if (p.length > 2 && p.startsWith('`') && p.endsWith('`')) {
          out.add(
            TextSpan(
              text: p.substring(1, p.length - 1),
              style: TextStyle(fontFamily: 'Consolas', color: t.accent),
            ),
          );
        } else {
          out.add(TextSpan(text: p));
        }
      }
      return out;
    }

    final paras = src.split(RegExp(r'\n{2,}'));
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final para in paras)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text.rich(
                TextSpan(
                  children: [
                    for (final (i, l)
                        in para
                            .split('\n')
                            .where((l) => l.trim().isNotEmpty)
                            .indexed) ...[
                      if (i > 0) const TextSpan(text: '\n'),
                      ...inline(
                        l
                            .replaceFirst(RegExp(r'^\s*[-*•]\s+'), '• ')
                            .replaceFirst(RegExp(r'^#+\s*'), ''),
                      ),
                    ],
                  ],
                ),
                style: TextStyle(
                  fontFamily: mono ? 'Consolas' : null,
                  fontSize: mono ? 12 : 13.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
