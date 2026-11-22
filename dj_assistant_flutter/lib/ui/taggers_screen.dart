import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/library.dart';
import '../core/library_edit.dart';
import '../core/taggers.dart';
import 'format.dart';
import 'hubs.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Each tool's colour on this page.
const _toolColors = {
  'onetagger': (Color(0xFF22D3EE), Color(0xFF0E7490)),
  'beets': (Color(0xFF34D399), Color(0xFF047857)),
  'picard': (Color(0xFFE879F9), Color(0xFFA21CAF)),
  'mp3tag': (Color(0xFF60A5FA), Color(0xFF1D4ED8)),
};

Color _toolColor(BuildContext c, String id) {
  final x = _toolColors[id]!;
  return Theme.of(c).brightness == Brightness.light ? x.$2 : x.$1;
}

/// Analysis → Taggers: Picard, OneTagger, Mp3tag and beets on copies of the
/// chosen tracks, merged into review-first Suggestions.
class TaggersScreen extends ConsumerStatefulWidget {
  const TaggersScreen({super.key});
  @override
  ConsumerState<TaggersScreen> createState() => _TaggersScreenState();
}

class _TaggersScreenState extends ConsumerState<TaggersScreen> {
  String source = 'incomplete'; // incomplete | sent | crate:<id>
  final limit = TextEditingController(text: '50');
  String? wsId;
  List<MergedSuggestion>? preview;

  @override
  void initState() {
    super.initState();
    if (ref.read(taggerTargetProvider) != null) source = 'sent';
  }

  @override
  void dispose() {
    limit.dispose();
    super.dispose();
  }

  TaggerWorkspace? _ws(List<TaggerWorkspace> all) =>
      all.where((w) => w.id == wsId).firstOrNull ?? all.firstOrNull;

  List<int> _ids() {
    final s = ref.read(sessionProvider);
    final n = int.tryParse(limit.text.trim());
    final max = (n == null || n < 1) ? 50 : n;
    if (source == 'sent') {
      return (ref.read(taggerTargetProvider)?.$2 ?? const [])
          .take(max)
          .toList();
    }
    if (source.startsWith('crate:')) {
      final id = int.parse(source.substring(6));
      return s.library
          .trackIds(TrackQuery(extraWhere: s.crates.membership(id)))
          .take(max)
          .toList();
    }
    return s.taggers.incompleteTracks(limit: max);
  }

  String _sourceLabel() {
    if (source == 'sent') {
      return ref.read(taggerTargetProvider)?.$1 ?? 'Tracks from the Library';
    }
    if (source.startsWith('crate:')) {
      final id = int.parse(source.substring(6));
      final c = ref.read(cratesProvider).where((c) => c.id == id).firstOrNull;
      return 'Crate: ${c?.name ?? id}';
    }
    return 'Tracks missing genre, BPM, key, year or label';
  }

  Future<void> _create() async {
    final s = ref.read(sessionProvider);
    final ws = await guard(
      () => s.taggers.create(_ids(), label: _sourceLabel()),
      bump: ref,
    );
    if (ws != null) {
      setState(() {
        wsId = ws.id;
        preview = null;
      });
      toast('Workspace ready: ${plural(ws.tracks.length, 'track')} to tag.');
    }
  }

  Future<void> _run(TaggerWorkspace ws, String tool) async {
    final s = ref.read(sessionProvider);
    final exe = s.taggers.path(tool);
    final def = taggerById(tool)!;
    if (exe == null) {
      toast('${def.name} was not found. Set its path first.', error: true);
      return;
    }
    toast('${def.name} is working on its copies…');
    final st = await guard(
      () => s.jobs.start(
        'tagger:$tool',
        taggerJob(
          ws.dir,
          tool,
          exe,
          platforms: s.taggers.oneTaggerPlatforms,
          beetsPlugins: s.taggers.beetsPlugins,
        ),
      ),
      bump: ref,
    );
    if (!mounted || st == null) return;
    if (st.state == 'completed') {
      final again = TaggerWorkspace.load(ws.dir);
      final n = again.findings[tool]?.length ?? 0;
      toast('${def.name} finished: changes on ${plural(n, 'track')}.');
    } else if (st.state == 'failed') {
      toast(st.message ?? '${def.name} stopped.', error: true);
    }
    setState(() => preview = null);
  }

  Future<void> _runAll(TaggerWorkspace ws) async {
    final s = ref.read(sessionProvider);
    for (final d in taggerDefs) {
      if (d.mode != TaggerMode.automatic) continue;
      if (!s.taggers.enabled(d.id) || s.taggers.path(d.id) == null) continue;
      await _run(ws, d.id);
      if (!mounted) return;
    }
  }

  Future<void> _setPath(String tool) async {
    final f = await openFile(
      confirmButtonText: 'Use this program',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Programs', extensions: ['exe', 'cmd', 'bat']),
        XTypeGroup(label: 'Any file'),
      ],
    );
    if (f == null) return;
    await guard(
      () => ref.read(sessionProvider).taggers.setPath(tool, f.path),
      done: 'Saved.',
      bump: ref,
    );
    setState(() {});
  }

  void _merge(TaggerWorkspace ws) async {
    final s = ref.read(sessionProvider);
    final n = await guard(
      () => s.taggers.merge(TaggerWorkspace.load(ws.dir)),
      bump: ref,
    );
    if (n == null) return;
    toast(
      n == 0
          ? 'Nothing new: the catalogue already has what the tools found.'
          : '${plural(n, 'suggestion')} ready for review in Suggestions.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final all = s.taggers.workspaces();
    final ws = _ws(all);
    final sent = ref.watch(taggerTargetProvider);
    final crates = ref.watch(cratesProvider).where((c) => c.kind != 'folder');
    final nav = ref.read(viewProvider.notifier);
    final analysis = hubs[1].color(context);

    Widget step(int n, String title, String sub, Widget child) => Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: t.tint(analysis, 0.22),
                child: Text(
                  '$n',
                  style: TextStyle(
                    color: analysis,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: Space.x3),
              Expanded(child: Text(title, style: text.titleMedium)),
            ],
          ),
          const SizedBox(height: Space.x1),
          Padding(
            padding: const EdgeInsets.only(left: 40),
            child: Text(sub, style: TextStyle(color: t.faint)),
          ),
          const SizedBox(height: Space.x3),
          child,
        ],
      ),
    );

    // 1 · tracks
    final choose = step(
      1,
      'Choose the tracks',
      'Each tool gets its own copies in DJ Assistant\'s data folder. Your '
          'music files are only read.',
      Wrap(
        spacing: Space.x3,
        runSpacing: Space.x3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 360,
            child: DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: source,
              decoration: const InputDecoration(labelText: 'Tracks'),
              items: [
                const DropdownMenuItem(
                  value: 'incomplete',
                  child: Text('Missing genre, BPM, key, year or label'),
                ),
                if (sent != null)
                  DropdownMenuItem(value: 'sent', child: Text(sent.$1)),
                for (final c in crates)
                  DropdownMenuItem(
                    value: 'crate:${c.id}',
                    child: Text('Crate: ${c.name}'),
                  ),
              ],
              onChanged: (v) => setState(() => source = v ?? 'incomplete'),
            ),
          ),
          SizedBox(
            width: 120,
            child: TextField(
              controller: limit,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'At most'),
            ),
          ),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: const Text('Make a workspace'),
          ),
          Tooltip(
            message:
                'In the Library, select tracks and choose “Tag with tools…” '
                'to send exactly those.',
            child: DjLink(
              label: 'Pick tracks in the Library',
              icon: Icons.library_music_outlined,
              color: hubs[0].color(context),
              onTap: () => nav.go('library'),
            ),
          ),
        ],
      ),
    );

    // workspace bar
    final bar = ws == null
        ? EmptyState(
            icon: Icons.auto_awesome_motion_outlined,
            title: 'No workspace yet',
            message:
                'Make one above. Then run the tools, and merge what they '
                'agree on into Suggestions.',
          )
        : Panel(
            child: Wrap(
              spacing: Space.x4,
              runSpacing: Space.x2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Icon(Icons.folder_copy_outlined, color: analysis),
                if (all.length > 1)
                  DropdownButton<String>(
                    value: ws.id,
                    items: [
                      for (final w in all)
                        DropdownMenuItem(
                          value: w.id,
                          child: Text(
                            '${w.label.isEmpty ? 'Workspace' : w.label} · '
                            '${fmtDateTime(w.createdAt)}',
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      wsId = v;
                      preview = null;
                    }),
                  )
                else
                  Text(
                    '${ws.label.isEmpty ? 'Workspace' : ws.label} · '
                    '${fmtDateTime(ws.createdAt)}',
                    style: text.titleSmall,
                  ),
                Text(
                  plural(ws.tracks.length, 'track'),
                  style: TextStyle(color: t.muted),
                ),
                TextButton.icon(
                  onPressed: () async {
                    final ok = await confirm(
                      context,
                      title: 'Remove this workspace?',
                      message:
                          'Its copies and the tools\' results are deleted. '
                          'Your music and any suggestions already made stay.',
                      ok: 'Remove',
                      danger: true,
                    );
                    if (!ok) return;
                    await guard(() => s.taggers.remove(ws), bump: ref);
                    setState(() {
                      wsId = null;
                      preview = null;
                    });
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Remove workspace'),
                ),
              ],
            ),
          );

    // 2 · tools
    final tools = step(
      2,
      'Run the tools',
      'OneTagger and beets run by themselves. Picard and Mp3tag open on their '
          'copies: check, save there, then press Collect.',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ws != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(bottom: Space.x3),
                child: FilledButton.icon(
                  onPressed: () => _runAll(ws),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run every automatic tool'),
                ),
              ),
            ),
          LayoutBuilder(
            builder: (context, box) {
              final cols = box.maxWidth >= 760 ? 2 : 1;
              final w = (box.maxWidth - Space.x3 * (cols - 1)) / cols;
              return Wrap(
                spacing: Space.x3,
                runSpacing: Space.x3,
                children: [
                  for (final d in taggerDefs)
                    SizedBox(
                      width: w,
                      child: _ToolTile(
                        def: d,
                        ws: ws,
                        onRun: ws == null ? null : () => _run(ws, d.id),
                        onOpen: ws == null
                            ? null
                            : () => guard(
                                () => s.taggers.openInteractive(ws, d.id),
                                done:
                                    '${d.name} is opening on its copies. Save '
                                    'there, then press Collect.',
                                bump: ref,
                              ),
                        onCollect: ws == null
                            ? null
                            : () {
                                final n = ws.collect(d.id).length;
                                toast(
                                  '${d.name}: changes on '
                                  '${plural(n, 'track')}.',
                                );
                                setState(() => preview = null);
                              },
                        onSetPath: () => _setPath(d.id),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: Space.x3),
          _OptionsRow(),
        ],
      ),
    );

    // 3 · merge
    final merged = ws == null
        ? const <MergedSuggestion>[]
        : (preview ??= mergeFindings(TaggerWorkspace.load(ws.dir).findings));
    final names = {
      if (ws != null)
        for (final x in ws.tracks) x['track_id']! as int: '${x['file_name']}',
    };
    final merge = step(
      3,
      'Merge into Suggestions',
      'Values several tools agree on score higher; disagreements are listed '
          'in the evidence. Nothing changes until you approve it.',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Space.x3,
            runSpacing: Space.x2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: ws == null || merged.isEmpty
                    ? null
                    : () => _merge(ws),
                icon: const Icon(Icons.merge_type),
                label: Text(
                  merged.isEmpty
                      ? 'Nothing found yet'
                      : 'Merge ${plural(merged.length, 'finding')}',
                ),
              ),
              DjLink(
                label: 'Review in Suggestions',
                icon: Icons.auto_fix_high_outlined,
                color: analysis,
                hint: tabOf('suggestions')!.hint,
                onTap: () => nav.go('suggestions'),
              ),
            ],
          ),
          if (merged.isNotEmpty) ...[
            const SizedBox(height: Space.x3),
            for (final m in merged.take(60))
              _MergedRow(m: m, track: names[m.trackId] ?? '#${m.trackId}'),
            if (merged.length > 60)
              Text(
                '…and ${merged.length - 60} more.',
                style: TextStyle(color: t.faint),
              ),
          ],
        ],
      ),
    );

    return PageFrame(
      title: 'Taggers',
      subtitle:
          'MusicBrainz Picard, OneTagger, Mp3tag and beets work together on '
          'copies of your tracks. What they find becomes Suggestions you '
          'approve; your music is never changed.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          choose,
          const SizedBox(height: Space.x3),
          bar,
          const SizedBox(height: Space.x3),
          tools,
          const SizedBox(height: Space.x3),
          merge,
        ],
      ),
    );
  }
}

/// One tool: what it is good at, where it was found, what it sends, and its
/// actions (Run for automatic tools; Open and Collect for interactive ones).
class _ToolTile extends ConsumerWidget {
  const _ToolTile({
    required this.def,
    required this.ws,
    required this.onRun,
    required this.onOpen,
    required this.onCollect,
    required this.onSetPath,
  });
  final TaggerDef def;
  final TaggerWorkspace? ws;
  final VoidCallback? onRun, onOpen, onCollect, onSetPath;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final c = _toolColor(context, def.id);
    final path = s.taggers.path(def.id);
    final on = s.taggers.enabled(def.id);
    final auto = def.mode == TaggerMode.automatic;
    final job = s.jobs.status('tagger:${def.id}');
    final busy = job.state == 'running' || job.state == 'paused';
    final found = ws?.findings[def.id];
    final when = ws?.collected[def.id];
    final opened = ws?.opened[def.id];
    return Container(
      padding: const EdgeInsets.all(Space.x4),
      decoration: BoxDecoration(
        borderRadius: Radii.large,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.alphaBlend(t.tint(c, 0.18), t.panel),
            Color.alphaBlend(t.tint(c, 0.04), t.panel),
          ],
        ),
        border: Border.all(color: t.tint(c, 0.40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                auto ? Icons.smart_toy_outlined : Icons.touch_app_outlined,
                color: c,
              ),
              const SizedBox(width: Space.x2),
              Expanded(
                child: Text(
                  def.name,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Tooltip(
                message: auto
                    ? 'Runs by itself on its copies'
                    : 'Opens on its copies; you check and save there',
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.x2,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: t.tint(c, 0.18),
                    borderRadius: Radii.small,
                  ),
                  child: Text(
                    auto ? 'Automatic' : 'You check & save',
                    style: TextStyle(
                      color: c,
                      fontSize: DjType.small,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Switch(
                value: on,
                onChanged: (v) {
                  s.taggers.setEnabled(def.id, v);
                  ref.read(versionProvider.notifier).bump();
                },
              ),
            ],
          ),
          const SizedBox(height: Space.x2),
          Text(def.strength, style: TextStyle(color: t.muted)),
          const SizedBox(height: Space.x2),
          Row(
            children: [
              Icon(
                path == null ? Icons.error_outline : Icons.check_circle_outline,
                size: IconSizes.sm,
                color: path == null ? t.warn : t.ok,
              ),
              const SizedBox(width: Space.x1),
              Expanded(
                child: Tooltip(
                  message: path ?? 'Not found on this computer',
                  child: Text(
                    path == null ? 'Not found' : 'Found: $path',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: DjType.small, color: t.faint),
                  ),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: Space.x3,
            children: [
              DjLink(
                label: path == null ? 'Get ${def.name}' : 'Website',
                icon: Icons.open_in_new,
                color: c,
                hint: def.site,
                onTap: () => openUrl(def.site),
              ),
              DjLink(
                label: path == null ? 'I have it: set path…' : 'Change path…',
                icon: Icons.folder_open,
                color: c,
                onTap: onSetPath ?? () {},
              ),
            ],
          ),
          const SizedBox(height: Space.x1),
          Text(
            def.sends,
            style: TextStyle(fontSize: DjType.small, color: t.faint),
          ),
          if (busy) ...[
            const SizedBox(height: Space.x2),
            ProgressLine(
              label: '${def.name} working…',
              done: job.done,
              total: job.total,
              message: job.message,
            ),
          ],
          if (when != null) ...[
            const SizedBox(height: Space.x2),
            Text(
              'Changes on ${plural(found?.length ?? 0, 'track')} · '
              '${fmtDateTime(when)}',
              style: TextStyle(color: c, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: Space.x3),
          Wrap(
            spacing: Space.x2,
            runSpacing: Space.x2,
            children: [
              if (auto)
                FilledButton.icon(
                  onPressed: (ws == null || path == null || !on || busy)
                      ? null
                      : onRun,
                  style: FilledButton.styleFrom(backgroundColor: c),
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text(when == null ? 'Run' : 'Run again'),
                )
              else ...[
                FilledButton.icon(
                  onPressed: (ws == null || path == null || !on)
                      ? null
                      : onOpen,
                  style: FilledButton.styleFrom(backgroundColor: c),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text('Open in ${def.name.split(' ').last}'),
                ),
                OutlinedButton.icon(
                  onPressed: (ws == null || opened == null) ? null : onCollect,
                  icon: const Icon(Icons.download_done, size: 18),
                  label: const Text('Collect'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// OneTagger platforms and beets plugins.
class _OptionsRow extends ConsumerStatefulWidget {
  @override
  ConsumerState<_OptionsRow> createState() => _OptionsRowState();
}

class _OptionsRowState extends ConsumerState<_OptionsRow> {
  late final platforms = TextEditingController(
    text: ref.read(sessionProvider).taggers.oneTaggerPlatforms,
  );
  late final plugins = TextEditingController(
    text: ref.read(sessionProvider).taggers.beetsPlugins,
  );

  @override
  void dispose() {
    platforms.dispose();
    plugins.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.read(sessionProvider);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Tool options'),
      children: [
        Wrap(
          spacing: Space.x3,
          runSpacing: Space.x3,
          children: [
            SizedBox(
              width: 420,
              child: TextField(
                controller: platforms,
                decoration: const InputDecoration(
                  labelText: 'OneTagger platforms',
                  helperText:
                      'Comma separated: beatport, traxsource, junodownload, '
                      'musicbrainz, discogs (needs a token), bpmsupreme…',
                ),
                onSubmitted: (v) => guard(
                  () => s.taggers.oneTaggerPlatforms = v,
                  done: 'Saved.',
                ),
              ),
            ),
            SizedBox(
              width: 320,
              child: TextField(
                controller: plugins,
                decoration: const InputDecoration(
                  labelText: 'beets plugins',
                  helperText: 'e.g. lastgenre (adds genres from Last.fm)',
                ),
                onSubmitted: (v) =>
                    guard(() => s.taggers.beetsPlugins = v, done: 'Saved.'),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.x3),
      ],
    );
  }
}

/// One merged finding: track, field, value, which tools, confidence.
class _MergedRow extends StatelessWidget {
  const _MergedRow({required this.m, required this.track});
  final MergedSuggestion m;
  final String track;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(track, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            flex: 2,
            child: Text(m.field, style: TextStyle(color: t.muted)),
          ),
          Expanded(
            flex: 3,
            child: Text(
              m.value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            flex: 3,
            child: Wrap(
              spacing: 4,
              children: [
                for (final tool in m.tools)
                  Tooltip(
                    message: taggerById(tool)?.name ?? tool,
                    child: CircleAvatar(
                      radius: 6,
                      backgroundColor: _toolColor(context, tool),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(
            width: 56,
            child: Tooltip(
              message: m.evidence,
              child: Text(
                '${(m.confidence * 100).round()}%',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: m.confidence >= 0.85 ? t.ok : t.muted,
                  fontFeatures: DjType.tabular,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
