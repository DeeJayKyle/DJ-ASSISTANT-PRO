import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../assistant/ai_config.dart';
import '../assistant/quick_ai.dart';
import '../core/catalogue.dart';
import '../core/packs.dart';
import '../core/updater.dart';
import '../online/http_online.dart';
import 'assistant_panel.dart';
import 'format.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

const safetyPoints = [
  'Your music is only read. DJ Assistant never renames, moves, replaces or deletes music files.',
  'Tag writing is off by default. If you turn it on, every change is previewed, the original is backed up and verified first, and you can roll it back.',
  "Serato's databases, crates, cues, beatgrids, history and settings are never written. Serato crates and history can be imported read-only.",
  "Your ratings, energy, tags, crates, sets and notes stay in DJ Assistant's own catalogue on this computer.",
  'Only folders you choose are scanned. Personal files are a separate, opt-in module.',
  'Core features work offline with no sign-in and no telemetry; accounts live only on this computer. Online services are off until you turn each one on, and each says exactly what it sends.',
];

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Map<String, Object?>? ai, local;
  UpdateInfo? update;
  String? updateMsg;

  @override
  void initState() {
    super.initState();
    _loadAi();
  }

  Future<void> _loadAi() async {
    final a = await ref.read(agentProvider).status();
    Map<String, Object?>? l;
    if (a['provider'] == 'local') {
      l = await AiHelpers(ref.read(sessionProvider)).localSetup();
    }
    if (mounted) {
      setState(() {
        ai = a;
        local = l;
      });
    }
  }

  void _set(String k, Object? v) => guard(() {
    final s = ref.read(sessionProvider);
    s.settings.set(k, v);
    if (k == 'watch_enabled') v == true ? s.watcher.start() : s.watcher.stop();
  }, bump: ref).then((_) => _loadAi());

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final st = ref.watch(settingsProvider);
    final services = s.settings.services();
    final base = ref.watch(accountsProvider).base;
    Widget sw(String key, String title, {String? sub}) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: sub == null
          ? null
          : Text(sub, style: TextStyle(color: t.faint, fontSize: 12)),
      value: st[key] == true,
      onChanged: (v) => _set(key, v),
    );
    Widget choice(String key, String title, List<(String, String)> opts) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: Text(title)),
              SegmentedButton<String>(
                segments: [
                  for (final (v, l) in opts)
                    ButtonSegment(value: v, label: Text(l)),
                ],
                selected: {'${st[key]}'},
                onSelectionChanged: (v) => _set(key, v.first),
              ),
            ],
          ),
        );
    return PageFrame(
      title: 'Settings',
      subtitle: 'Everything here is stored on this computer, per account.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: 'Your library is safe',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final p in safetyPoints)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: HintText(p, icon: Icons.verified_user_outlined),
                  ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Appearance',
            child: Column(
              children: [
                choice('theme', 'Theme', [
                  ('dark', 'Dark'),
                  ('light', 'Light'),
                ]),
                choice('key_notation', 'Keys', [
                  ('camelot', 'Camelot (8A)'),
                  ('musical', 'Musical (Am)'),
                ]),
                choice('surface', 'Panels', [
                  ('glass', 'Glass'),
                  ('solid', 'Solid'),
                ]),
                choice('motion', 'Motion', [
                  ('full', 'Full'),
                  ('reduced', 'Reduced'),
                ]),
                sw('premium_ui', 'Premium UI (Midnight Pro look)'),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Library',
            child: Column(
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('Low-bitrate warning below')),
                    SizedBox(
                      width: 120,
                      child: TextFormField(
                        key: ValueKey(st['low_bitrate_kbps']),
                        initialValue: '${st['low_bitrate_kbps']}',
                        decoration: const InputDecoration(suffixText: 'kbps'),
                        onFieldSubmitted: (v) =>
                            _set('low_bitrate_kbps', int.tryParse(v) ?? -1),
                      ),
                    ),
                  ],
                ),
                sw('scan_video', 'Include music videos when scanning'),
                sw(
                  'watch_enabled',
                  'Folder watcher',
                  sub: 'Notices new music in your folders; never moves anything.',
                ),
                sw(
                  'auto_prep',
                  'Auto-prep after every scan',
                  sub: 'Analysis, suggestions and confident fixes — into the catalogue only.',
                ),
                Row(
                  children: [
                    const Expanded(
                      child: Text('Auto-prep applies fixes at or above'),
                    ),
                    SizedBox(
                      width: 220,
                      child: Slider(
                        value: ((st['auto_fix_min'] as num?) ?? 0.85)
                            .toDouble(),
                        min: 0.5,
                        max: 1,
                        divisions: 10,
                        label:
                            '${((((st['auto_fix_min'] as num?) ?? 0.85) * 100)).round()}%',
                        onChanged: (v) =>
                            _set('auto_fix_min', (v * 100).round() / 100),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Online services',
            subtitle: 'All off until you turn one on. Each says exactly what it sends. Keys are kept in Windows Credential Manager and never shown again.',
            child: Column(
              children: [
                for (final x in services)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('${x['name']}'),
                    subtitle: Text(
                      '${x['provides']}',
                      style: TextStyle(color: t.faint, fontSize: 12),
                    ),
                    leading: Switch(
                      value: x['enabled'] == true,
                      onChanged: (v) => guard(
                        () => s.settings.setService('${x['id']}', v),
                        bump: ref,
                      ).then((_) => _loadAi()),
                    ),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Sends: ${x['sends']}',
                          style: TextStyle(color: t.muted, fontSize: 12.5),
                        ),
                      ),
                      if (x['needs_key'] == true && x['id'] != 'anthropic')
                        Row(
                          children: [
                            Text(
                              x['has_key'] == true ? 'Key saved' : 'No key yet',
                              style: TextStyle(
                                color: x['has_key'] == true ? t.ok : t.warn,
                              ),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: () async {
                                final v = await askText(
                                  context,
                                  title: '${x['name']} key',
                                  label: x['id'] == 'spotify'
                                      ? 'Client ID:Client secret'
                                      : 'API key',
                                  obscure: true,
                                );
                                if (v != null) {
                                  await guard(
                                    () => s.settings.setSecret('${x['id']}', v),
                                    done: 'Key saved.',
                                    bump: ref,
                                  );
                                }
                              },
                              child: Text(
                                x['has_key'] == true
                                    ? 'Replace key'
                                    : 'Add key',
                              ),
                            ),
                            if (x['has_key'] == true)
                              TextButton(
                                onPressed: () => guard(
                                  () => s.settings.deleteSecret('${x['id']}'),
                                  bump: ref,
                                ),
                                child: const Text('Remove key'),
                              ),
                          ],
                        ),
                    ],
                  ),
              ],
            ),
          ),
          gap,
          _aiPanel(context, s.cat),
          gap,
          _packsPanel(context, base),
          gap,
          Panel(
            title: 'Changes to music files',
            subtitle: 'Off by default. Every change is previewed, backed up, verified and can be rolled back.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sw('allow_file_changes', 'Allow writing to music files'),
                const Text(
                  'Change log',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                for (final c in s.safeWrite.log(limit: 50))
                  ListTile(
                    dense: true,
                    title: Text(
                      '${c['path']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${c['action']} · ${c['status']} · ${fmtDateTime(c['at'] as int?)}',
                    ),
                    trailing: c['status'] == 'done'
                        ? TextButton(
                            onPressed: () => guard(
                              () => s.safeWrite.rollback(c['id']! as int),
                              done: 'Restored the original file from its verified backup.',
                              bump: ref,
                            ),
                            child: const Text('Roll back'),
                          )
                        : null,
                  ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Learning and personal files',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sw(
                  'learning_enabled',
                  'Learn from ratings and plays',
                  sub: 'Used only for recommendations in Discovery.',
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => guard(
                      () => toast(
                        'Forgot ${s.discovery.resetLearning()} like(s)/dislike(s).',
                      ),
                      bump: ref,
                    ),
                    child: const Text('Reset what was learned'),
                  ),
                ),
                sw(
                  'docs_enabled',
                  'Personal files module',
                  sub: 'A separate, opt-in index of document folders.',
                ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Updates',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sw(
                  'auto_update',
                  'Check for updates when the app starts',
                  sub: 'Sends only the request for the release manifest to GitHub.',
                ),
                Row(
                  children: [
                    Text('DJ Assistant $appVersion'),
                    const Spacer(),
                    if (update != null)
                      FilledButton(
                        onPressed: () => guard(() async {
                          final dest =
                              '${Directory.systemTemp.path}${Platform.pathSeparator}DJ-Assistant-${update!.version}-setup.exe';
                          final path = await downloadUpdate(
                            HttpOnline().web,
                            update!,
                            dest,
                          );
                          // passive install, then start the new version
                          // (the switches 1.x's updater used)
                          await Process.start(path, const [
                            '/P',
                            '/UPDATE',
                            '/R',
                          ], mode: ProcessStartMode.detached);
                          exit(0);
                        }),
                        child: Text('Install ${update!.version}'),
                      ),
                    TextButton(
                      onPressed: () => guard(() async {
                        final u = await checkForUpdate(
                          HttpOnline().web,
                          appVersion,
                        );
                        setState(() {
                          update = u;
                          updateMsg = u == null
                              ? "You're up to date."
                              : 'Version ${u.version} is available.';
                        });
                      }),
                      child: const Text('Check now'),
                    ),
                  ],
                ),
                if (updateMsg != null)
                  Text(updateMsg!, style: TextStyle(color: t.faint)),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'About',
            child: SelectableText(
              'Data folder: $base\nCatalogue: ${s.dbPath}\nNo telemetry. Nothing is sent online unless you turn a service on.',
              style: TextStyle(color: t.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _aiPanel(BuildContext context, Catalogue cat) {
    final t = DjTokens.of(context);
    final a = ai;
    final s = ref.read(sessionProvider);
    if (a == null) {
      return const Panel(
        title: 'AI assistant',
        child: LinearProgressIndicator(),
      );
    }
    final provider = '${a['provider']}';
    final svcs = (a['services'] as List).cast<Map>();
    return Panel(
      title: 'AI assistant',
      subtitle: '${a['sends']}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: provider,
            decoration: const InputDecoration(labelText: 'Model service'),
            items: [
              const DropdownMenuItem(
                value: 'off',
                child: Text('Off — built-in helper only'),
              ),
              const DropdownMenuItem(
                value: 'local',
                child: Text('Local model on this computer (Ollama) — private'),
              ),
              const DropdownMenuItem(
                value: 'claude',
                child: Text('Claude (Anthropic)'),
              ),
              for (final x in svcs)
                DropdownMenuItem(
                  value: '${x['id']}',
                  child: Text('${x['label']}'),
                ),
            ],
            onChanged: (v) => _set('ai_provider', v),
          ),
          const SizedBox(height: 8),
          if (a['ready'] != true && a['reason'] != null)
            Text('${a['reason']}', style: TextStyle(color: t.warn)),
          if (provider == 'claude') ...[
            DropdownButtonFormField<String>(
              initialValue: '${a['model']}',
              decoration: const InputDecoration(labelText: 'Claude model'),
              items: [
                for (final m in (a['claude_models'] as List).cast<Map>())
                  DropdownMenuItem(
                    value: '${m['id']}',
                    child: Text('${m['label']}'),
                  ),
              ],
              onChanged: (v) => _set('ai_model', v),
            ),
            _keyRow(
              context,
              'anthropic',
              a['has_key'] == true,
              'Anthropic API key (sk-ant-…)',
            ),
          ],
          if (aiService(provider) != null) ...[
            TextFormField(
              key: ValueKey('model-$provider'),
              initialValue: '${a['model']}',
              decoration: InputDecoration(
                labelText: 'Model',
                helperText: 'Suggested: ${aiService(provider)!.model}',
              ),
              onFieldSubmitted: (v) => _set('ai_model_$provider', v),
            ),
            if (provider == 'custom')
              TextFormField(
                initialValue: '${a['custom_url']}',
                decoration: const InputDecoration(
                  labelText: 'Server address (https://… or http://127.0.0.1:…)',
                ),
                onFieldSubmitted: (v) => _set('ai_custom_url', v),
              ),
            _keyRow(
              context,
              'ai_$provider',
              svcs.firstWhere((x) => x['id'] == provider)['has_key'] == true,
              'API key',
            ),
            if (aiService(provider)!.keyUrl.isNotEmpty)
              TextButton(
                onPressed: () => openUrl(aiService(provider)!.keyUrl),
                child: const Text('Get a key'),
              ),
            TextButton(
              onPressed: () async {
                final m = await guard(() => AiHelpers(s).listModels());
                if (m != null && context.mounted) {
                  final pick = await showDialog<String>(
                    context: context,
                    builder: (c) => SimpleDialog(
                      title: const Text('Models'),
                      children: [
                        for (final x in m.take(200))
                          SimpleDialogOption(
                            onPressed: () => Navigator.pop(c, x),
                            child: Text(x),
                          ),
                      ],
                    ),
                  );
                  if (pick != null) _set('ai_model_$provider', pick);
                }
              },
              child: const Text('List models'),
            ),
          ],
          if (provider == 'local') _localPanel(context),
        ],
      ),
    );
  }

  Widget _keyRow(BuildContext context, String svc, bool has, String label) {
    final s = ref.read(sessionProvider);
    final t = DjTokens.of(context);
    return Row(
      children: [
        Text(
          has ? 'Key saved' : 'No key yet',
          style: TextStyle(color: has ? t.ok : t.warn),
        ),
        const Spacer(),
        TextButton(
          onPressed: () async {
            final v = await askText(context, title: label, obscure: true);
            if (v != null) {
              await guard(
                () => s.settings.setSecret(svc, v),
                done: 'Key saved.',
                bump: ref,
              );
            }
            await _loadAi();
          },
          child: Text(has ? 'Replace key' : 'Add key'),
        ),
        if (has)
          TextButton(
            onPressed: () => guard(
              () => s.settings.deleteSecret(svc),
              bump: ref,
            ).then((_) => _loadAi()),
            child: const Text('Remove key'),
          ),
      ],
    );
  }

  Widget _localPanel(BuildContext context) {
    final t = DjTokens.of(context);
    final s = ref.read(sessionProvider);
    final l = local;
    final h = AiHelpers(s);
    final pack = s.jobs.status('ai_pack'), pull = s.jobs.status('ai_model');
    final probe = (l?['probe'] as Map?) ?? const {};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          probe['running'] == true
              ? 'Ollama is running with ${(probe['models'] as List?)?.length ?? 0} model(s).'
              : (probe['installed'] == true
                    ? 'Ollama is installed but not running.'
                    : 'Ollama is not installed yet.'),
          style: TextStyle(color: t.muted),
        ),
        if (pack.state == 'running')
          ProgressLine(
            label: 'Setting up the private assistant…',
            done: pack.done,
            total: pack.total,
            message: pack.message,
          ),
        if (pull.state == 'running')
          ProgressLine(
            label: 'Downloading the model…',
            done: pull.done,
            total: pull.total,
            message: pull.message,
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              onPressed: () => guard(
                () => h.packSetup(),
                done: 'Setting up: install, start and download as needed.',
                bump: ref,
              ),
              child: const Text('One-click setup'),
            ),
            OutlinedButton(
              onPressed: () => guard(
                () async => toast(
                  await h.localStart()
                      ? 'Ollama is running.'
                      : "Ollama didn't answer yet.",
                ),
              ).then((_) => _loadAi()),
              child: const Text('Start Ollama'),
            ),
            for (final m
                in (l?['recommended'] as List?)?.cast<Map>() ?? const <Map>[])
              OutlinedButton(
                onPressed: () => guard(
                  () => h.localPull('${m['id']}'),
                  done: 'Downloading ${m['id']}…',
                  bump: ref,
                ),
                child: Text('Get ${m['id']} (${m['size']})'),
              ),
            TextButton(onPressed: _loadAi, child: const Text('Refresh')),
          ],
        ),
      ],
    );
  }

  Widget _packsPanel(BuildContext context, String base) {
    final s = ref.read(sessionProvider);
    final t = DjTokens.of(context);
    return Panel(
      title: 'Packs',
      subtitle: 'Big optional extras, downloaded once from DJ Assistant\'s GitHub releases, checked against known checksums, then offline. Shared by all accounts.',
      child: Column(
        children: [
          for (final p in listPacks(base, s.jobs))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${p['name']} (${fmtBytes(p['size'] as int?)})'),
              subtitle: Text(
                '${p['description']}\n${p['credits']}',
                style: TextStyle(color: t.faint, fontSize: 12),
              ),
              isThreeLine: true,
              trailing: p['installed'] == true
                  ? TextButton(
                      onPressed: () => guard(
                        () => removePack(base, '${p['id']}'),
                        done: 'Pack removed.',
                        bump: ref,
                      ),
                      child: const Text('Remove'),
                    )
                  : FilledButton(
                      onPressed: () {
                        final pack = packById('${p['id']}')!;
                        final make = s.onlineFactory;
                        s.jobs
                            .start(
                              'pack:${pack.id}',
                              (ctx) => installPack(
                                base,
                                pack,
                                (u, d, pr) => make().download(u, d, pr),
                                ctx,
                              ),
                            )
                            .ignore();
                        toast('Downloading ${pack.name}…');
                        ref.read(versionProvider.notifier).bump();
                      },
                      child: const Text('Get'),
                    ),
            ),
        ],
      ),
    );
  }
}
