import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/session.dart';
import '../core/gigpack.dart';
import '../core/json.dart';
import '../core/library.dart';
import '../core/library_edit.dart';
import '../online/http_online.dart' show appVersion;
import 'format.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

const _curves = [
  ('journey', 'Journey (build to peak)'),
  ('warmup', 'Warm-up (gentle rise)'),
  ('peak', 'Peak time (high and steady)'),
  ('wedding', 'Wedding (dinner → party → last dance)'),
  ('lounge', 'Lounge (low and even)'),
];

/// Builds an editable running order (1.x SetStudioView).
class SetStudioScreen extends ConsumerStatefulWidget {
  const SetStudioScreen({super.key, this.params});
  final Map<String, Object?>? params;
  @override
  ConsumerState<SetStudioScreen> createState() => _SetStudioScreenState();
}

class _SetStudioScreenState extends ConsumerState<SetStudioScreen> {
  late final name = TextEditingController(
    text: '${widget.params?['name'] ?? ''}',
  );
  late final minutes = TextEditingController(
    text: '${widget.params?['duration_min'] ?? 60}',
  );
  late final genres = TextEditingController(
    text: ((widget.params?['genres'] as List?) ?? const []).join(', '),
  );
  late final event = TextEditingController(
    text: '${widget.params?['event_type'] ?? ''}',
  );
  final bpmMin = TextEditingController(),
      bpmMax = TextEditingController(),
      minSec = TextEditingController(text: '30');
  late String curve = '${widget.params?['curve'] ?? 'journey'}';
  late bool clean = widget.params?['clean_only'] == true;
  bool harmonic = true;
  int? crateId, savedId;
  Map<String, Object?>? plan;

  Map<String, Object?> _params() => {
    'name': name.text.trim().isEmpty ? null : name.text.trim(),
    'duration_min': int.tryParse(minutes.text) ?? 60,
    'event_type': event.text.trim().isEmpty ? null : event.text.trim(),
    'genres': [
      for (final g in genres.text.split(','))
        if (g.trim().isNotEmpty) g.trim(),
    ],
    'curve': curve,
    'clean_only': clean,
    'bpm_min': double.tryParse(bpmMin.text),
    'bpm_max': double.tryParse(bpmMax.text),
    'crate_id': crateId,
    'harmonic': harmonic,
    'min_track_seconds': int.tryParse(minSec.text),
  };

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final notation = '${ref.watch(settingsProvider)['key_notation']}';
    final crates = ref
        .watch(cratesProvider)
        .where((c) => c.kind != 'folder')
        .toList();
    final saved = s.sets.list();
    final slots = (plan?['slots'] as List?)?.cast<Map>() ?? const [];
    final emergency = (plan?['emergency'] as List?)?.cast<Map>() ?? const [];
    return PageFrame(
      title: 'Set Studio',
      subtitle: 'Build an editable running order. Suggestions consider energy, tempo and key — always check transitions by ear.',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 340,
            child: Column(
              children: [
                Panel(
                  title: 'The gig',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(
                          labelText: 'Name (optional)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: minutes,
                        decoration: const InputDecoration(
                          labelText: 'Length (minutes)',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: event,
                        decoration: const InputDecoration(
                          labelText: 'Event (wedding, club, lounge…)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: curve,
                        decoration: const InputDecoration(
                          labelText: 'Energy curve',
                        ),
                        items: [
                          for (final (k, l) in _curves)
                            DropdownMenuItem(value: k, child: Text(l)),
                        ],
                        onChanged: (v) => curve = v!,
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: genres,
                        decoration: const InputDecoration(
                          labelText: 'Genres (comma separated, optional)',
                        ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int?>(
                        initialValue: crateId,
                        decoration: const InputDecoration(
                          labelText: 'Only from crate (optional)',
                        ),
                        items: [
                          const DropdownMenuItem(
                            value: null,
                            child: Text('Whole library'),
                          ),
                          for (final c in crates)
                            DropdownMenuItem(value: c.id, child: Text(c.name)),
                        ],
                        onChanged: (v) => crateId = v,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: bpmMin,
                              decoration: const InputDecoration(
                                labelText: 'BPM from',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: bpmMax,
                              decoration: const InputDecoration(
                                labelText: 'BPM to',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: minSec,
                        decoration: const InputDecoration(
                          labelText: 'Skip tracks shorter than (seconds)',
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: clean,
                        onChanged: (v) => setState(() => clean = v),
                        title: const Text('Clean versions only'),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: harmonic,
                        onChanged: (v) => setState(() => harmonic = v),
                        title: const Text('Prefer harmonic mixes'),
                      ),
                      FilledButton(
                        onPressed: () => guard(
                          () => setState(() {
                            plan = s.sets.plan(setParamsFromJson(_params()));
                            savedId = null;
                          }),
                        ),
                        child: const Text('Generate running order'),
                      ),
                    ],
                  ),
                ),
                gap,
                Panel(
                  title: 'Saved sets',
                  child: saved.isEmpty
                      ? Text('None yet.', style: TextStyle(color: t.faint))
                      : Column(
                          children: [
                            for (final x in saved)
                              ListTile(
                                dense: true,
                                title: Text('${x['name']}'),
                                subtitle: Text(
                                  '${x['slots'] ?? x['track_count'] ?? ''} tracks · ${fmtDateTime(x['updated_at'] as int? ?? x['created_at'] as int?)}',
                                ),
                                onTap: () => guard(
                                  () => setState(() {
                                    final g = s.sets.get(x['id']! as int);
                                    plan =
                                        (g['plan'] as Map?)
                                            ?.cast<String, Object?>() ??
                                        g;
                                    savedId = x['id'] as int?;
                                    name.text = '${x['name']}';
                                  }),
                                ),
                                trailing: IconButton(
                                  tooltip: 'Delete set',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                  onPressed: () => guard(
                                    () => s.sets.delete(x['id']! as int),
                                    bump: ref,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          gap,
          Expanded(
            child: plan == null
                ? const Panel(
                    child: EmptyState(
                      icon: Icons.queue_music_outlined,
                      title: 'Choose the gig on the left and press Generate',
                      message: 'Unknown energy or BPM values are treated cautiously — analyse your library for better plans.',
                    ),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Panel(
                        title:
                            '${slots.length} tracks · ${fmtLongDuration(slots.fold<int>(0, (a, x) => a + ((x['planned_ms'] as int?) ?? 0)))}',
                        trailing: Wrap(
                          spacing: 8,
                          children: [
                            FilledButton(
                              onPressed: () => guard(
                                () {
                                  final id = s.sets.save(
                                    name.text.trim().isEmpty
                                        ? '${minutes.text} min set'
                                        : name.text.trim(),
                                    plan!,
                                    id: savedId,
                                  );
                                  setState(() => savedId = id);
                                },
                                done: 'Set saved.',
                                bump: ref,
                              ),
                              child: Text(
                                savedId == null ? 'Save set' : 'Save changes',
                              ),
                            ),
                            OutlinedButton(
                              onPressed: savedId == null
                                  ? null
                                  : () => guard(
                                      () {
                                        final c = s.sets.toCrate(
                                          savedId!,
                                          name.text.trim().isEmpty
                                              ? 'Set'
                                              : name.text.trim(),
                                        );
                                        ref
                                            .read(viewProvider.notifier)
                                            .go('crate', crateId: c.id);
                                      },
                                      done: 'Made a crate from the set.',
                                      bump: ref,
                                    ),
                              child: const Text('Make a crate'),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            for (final w
                                in (plan!['warnings'] as List?) ?? const [])
                              HintText('$w', icon: Icons.info_outline),
                            for (var i = 0; i < slots.length; i++)
                              ListTile(
                                dense: true,
                                leading: Text(
                                  '${i + 1}',
                                  style: TextStyle(color: t.faint),
                                ),
                                title: Text('${slots[i]['track']}'),
                                subtitle: Text(
                                  [
                                    'energy ${slots[i]['energy'] ?? '?'} (target ${(slots[i]['target_energy'] as num?)?.toStringAsFixed(1) ?? '?'})',
                                    'BPM ${fmtBpm(slots[i]['bpm'] as num?)}',
                                    'key ${fmtKey(slots[i]['key'] as String?, notation)}',
                                    if (slots[i]['transition'] != null)
                                      '${slots[i]['transition']}',
                                  ].join(' · '),
                                ),
                                trailing: IconButton(
                                  tooltip: 'Remove from the plan',
                                  icon: const Icon(
                                    Icons.remove_circle_outline,
                                    size: 18,
                                  ),
                                  onPressed: () => setState(
                                    () => (plan!['slots']! as List).removeAt(i),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (emergency.isNotEmpty) ...[
                        gap,
                        Panel(
                          title: 'Emergency tracks',
                          subtitle: 'Dependable floor-fillers (4–5★ or tagged “banger”) kept out of the plan in case you need to rescue the floor.',
                          child: Column(
                            children: [
                              for (final e in emergency)
                                ListTile(
                                  dense: true,
                                  title: Text('${e['track']}'),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Offline set list, requests and notes (1.x GigView).
class GigScreen extends ConsumerStatefulWidget {
  const GigScreen({super.key});
  @override
  ConsumerState<GigScreen> createState() => _GigScreenState();
}

class _GigScreenState extends ConsumerState<GigScreen> {
  final name = TextEditingController(),
      request = TextEditingController(),
      note = TextEditingController(),
      search = TextEditingController();
  int? setId;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final g = s.gig.current();
    if (g == null) {
      final past = s.gig.list();
      return PageFrame(
        title: 'Gig Mode',
        subtitle: 'An offline set list, request queue and notes. Background scanning, analysis and the folder watcher pause while a gig runs.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Panel(
              title: 'Start a gig',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'Saturday — Club Rouge',
                    ),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int?>(
                    initialValue: setId,
                    decoration: const InputDecoration(
                      labelText: 'Set list (optional)',
                    ),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('No set list — use quick search'),
                      ),
                      for (final x in s.sets.list())
                        DropdownMenuItem(
                          value: x['id'] as int?,
                          child: Text('${x['name']}'),
                        ),
                    ],
                    onChanged: (v) => setId = v,
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: () => guard(
                        () => s.gig.start(
                          name.text.trim().isEmpty ? 'Gig' : name.text.trim(),
                          setPlanId: setId,
                        ),
                        done: 'Gig mode on. Background work paused.',
                        bump: ref,
                      ),
                      icon: const Icon(Icons.sensors),
                      label: const Text('Start gig mode'),
                    ),
                  ),
                ],
              ),
            ),
            gap,
            Panel(
              title: 'Past gigs',
              child: Column(
                children: [
                  for (final x in past)
                    ListTile(
                      dense: true,
                      title: Text('${x['name']}'),
                      subtitle: Text(
                        '${fmtDateTime(x['started_at'] as int?)} · ${x['played']} played',
                      ),
                      trailing: TextButton(
                        onPressed: () => _recap(context, s, x['id']! as int),
                        child: const Text('Recap'),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final events = (g['events'] as List).cast<Map>();
    final played = events.where((e) => e['kind'] == 'played').toList();
    final requests = events.where((e) => e['kind'] == 'request').toList();
    final notes = events.where((e) => e['kind'] == 'note').toList();
    final setPlan = g['set_plan_id'] == null
        ? null
        : s.sets.get(g['set_plan_id']! as int);
    final slots =
        ((setPlan?['plan'] as Map?)?['slots'] as List? ??
                setPlan?['slots'] as List? ??
                const [])
            .cast<Map>();
    final results = search.text.trim().isEmpty
        ? const <TrackRow>[]
        : s.library.search(TrackQuery(text: search.text.trim(), limit: 8)).rows;
    void play(int id) =>
        guard(() => s.gig.addEvent('played', trackId: id), bump: ref);
    return PageFrame(
      title: '${g['name']}',
      subtitle:
          'Gig mode on since ${fmtDateTime(g['started_at'] as int?)} · background work paused',
      actions: [
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: t.danger),
          onPressed: () async {
            final id = s.gig.end();
            ref.read(versionProvider.notifier).bump();
            if (id != null && context.mounted) await _recap(context, s, id);
          },
          icon: const Icon(Icons.stop),
          label: const Text('End gig'),
        ),
      ],
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          SizedBox(
            width: 520,
            child: Panel(
              title: slots.isEmpty ? 'Quick search' : 'Set list',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final x in slots)
                    ListTile(
                      dense: true,
                      title: Text('${x['track']}'),
                      trailing:
                          played.any((p) => p['track_id'] == x['track_id'])
                          ? Icon(Icons.check, color: t.ok)
                          : TextButton(
                              onPressed: () => play(x['track_id']! as int),
                              child: const Text('Played'),
                            ),
                    ),
                  TextField(
                    controller: search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Find a track',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  for (final r in results)
                    ListTile(
                      dense: true,
                      title: Text(
                        '${r.artist ?? unknown} — ${r.title ?? r.fileName}',
                      ),
                      trailing: TextButton(
                        onPressed: () => play(r.id),
                        child: const Text('Played'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 420,
            child: Column(
              children: [
                Panel(
                  title: 'Requests',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: request,
                        decoration: const InputDecoration(
                          hintText: 'Song or artist someone asked for',
                        ),
                        onSubmitted: (v) {
                          if (v.trim().isEmpty) return;
                          guard(
                            () => s.gig.addEvent('request', text: v.trim()),
                            bump: ref,
                          );
                          request.clear();
                        },
                      ),
                      for (final r in requests)
                        ListTile(
                          dense: true,
                          title: Text('${r['text'] ?? r['track']}'),
                          subtitle: Text('${r['status'] ?? 'pending'}'),
                          trailing: Wrap(
                            children: [
                              IconButton(
                                tooltip: 'Played',
                                icon: const Icon(Icons.check, size: 18),
                                onPressed: () => guard(
                                  () => s.gig.setRequest(
                                    r['id']! as int,
                                    'played',
                                  ),
                                  bump: ref,
                                ),
                              ),
                              IconButton(
                                tooltip: 'Declined',
                                icon: const Icon(Icons.close, size: 18),
                                onPressed: () => guard(
                                  () => s.gig.setRequest(
                                    r['id']! as int,
                                    'declined',
                                  ),
                                  bump: ref,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                gap,
                Panel(
                  title: 'Notes',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: note,
                        decoration: const InputDecoration(
                          hintText: 'Crowd loved the throwbacks…',
                        ),
                        onSubmitted: (v) {
                          if (v.trim().isEmpty) return;
                          guard(
                            () => s.gig.addEvent('note', text: v.trim()),
                            bump: ref,
                          );
                          note.clear();
                        },
                      ),
                      for (final n in notes)
                        ListTile(
                          dense: true,
                          title: Text('${n['text']}'),
                          subtitle: Text(fmtDateTime(n['at'] as int?)),
                        ),
                    ],
                  ),
                ),
                gap,
                Panel(
                  title: 'Played (${played.length})',
                  child: Column(
                    children: [
                      for (final p in played.reversed)
                        ListTile(
                          dense: true,
                          title: Text('${p['track']}'),
                          subtitle: Text(fmtDateTime(p['at'] as int?)),
                          trailing: IconButton(
                            tooltip: 'Undo',
                            icon: const Icon(Icons.undo, size: 18),
                            onPressed: () => guard(
                              () => s.gig.deleteEvent(p['id']! as int),
                              bump: ref,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _recap(BuildContext context, AppSession s, int id) async {
    final md = s.gig.recapMarkdown(id);
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Gig recap'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: SelectableText(md)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final loc = await getSaveLocation(
                suggestedName: 'Gig recap.md',
                acceptedTypeGroups: const [
                  XTypeGroup(label: 'Markdown', extensions: ['md']),
                ],
              );
              if (loc != null) {
                await guard(
                  () => s.exports.writeText(loc.path, md),
                  done: 'Recap saved.',
                );
              }
            },
            child: const Text('Save…'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Verified copies of a crate or set onto a USB stick or drive (1.x GigPackView).
class GigPackScreen extends ConsumerStatefulWidget {
  const GigPackScreen({super.key});
  @override
  ConsumerState<GigPackScreen> createState() => _GigPackScreenState();
}

class _GigPackScreenState extends ConsumerState<GigPackScreen> {
  String? source; // crate:<id> | set:<id>
  String? dest;
  final name = TextEditingController(text: 'DJ Assistant pack');
  bool zip = false;
  PackPlan? plan;

  List<int> _ids(AppSession s) {
    if (source == null) return const [];
    final id = int.parse(source!.split(':')[1]);
    return source!.startsWith('crate:')
        ? s.library.trackIds(TrackQuery(extraWhere: s.crates.membership(id)))
        : s.sets.trackIds(id);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final job = s.jobs.status('gigpack');
    final live = job.state == 'running' || job.state == 'paused';
    final crates = ref.watch(cratesProvider).where((c) => c.kind != 'folder');
    return PageFrame(
      title: 'Gig Pack',
      subtitle: 'Copy a crate or set to a USB stick or drive, verify every copy, and get a manifest, playlist and missing-file report.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: source,
                  decoration: const InputDecoration(labelText: 'What to copy'),
                  hint: const Text('Choose a crate or saved set…'),
                  items: [
                    for (final c in crates)
                      DropdownMenuItem(
                        value: 'crate:${c.id}',
                        child: Text('Crate: ${c.name}'),
                      ),
                    for (final x in s.sets.list())
                      DropdownMenuItem(
                        value: 'set:${x['id']}',
                        child: Text('Set: ${x['name']}'),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    source = v;
                    plan = null;
                  }),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        dest ?? 'No drive chosen',
                        style: TextStyle(color: dest == null ? t.faint : null),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () async {
                        final d = await getDirectoryPath(
                          confirmButtonText: 'Choose the USB stick or folder',
                        );
                        if (d != null) setState(() => dest = d);
                      },
                      child: const Text('Choose the USB stick or folder'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Pack folder name',
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: zip,
                  onChanged: (v) => setState(() => zip = v),
                  title: const Text('One ZIP file instead of a folder'),
                ),
                const HintText(
                  'Your originals are only read. The pack goes into a new folder; existing files are never overwritten. Serato crates and library links are not copied; cue points stored inside the files travel with them, but check on the gig laptop before relying on them.',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: source == null || dest == null
                          ? null
                          : () => guard(
                              () => setState(
                                () => plan = s.gigPack.preview(
                                  _ids(s),
                                  dest!,
                                  name.text,
                                  opts: PackOptions(zip: zip),
                                ),
                              ),
                            ),
                      child: const Text('Preview'),
                    ),
                    FilledButton(
                      onPressed: plan == null || live || !plan!.fits
                          ? null
                          : () {
                              final pl = plan!, path = s.dbPath;
                              s.jobs
                                  .start(
                                    'gigpack',
                                    gigPackJob(
                                      path,
                                      pl,
                                      appVersion: appVersion,
                                    ),
                                  )
                                  .ignore();
                              toast('Copying and verifying…');
                              ref.read(versionProvider.notifier).bump();
                            },
                      child: const Text('Copy and verify'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (live) ...[
            gap,
            ProgressLine(
              label: 'Copying and verifying…',
              done: job.done,
              total: job.total,
              message: job.message,
            ),
          ],
          if (job.state == 'completed' && job.result is Map) ...[
            gap,
            Panel(
              title: 'Done',
              child: Text(
                'Pack ready at ${(job.result! as Map)['pack'] ?? plan?.packDir ?? ''}. ${(job.result! as Map)['copied'] ?? ''} files copied and verified.',
              ),
            ),
          ],
          if (plan != null) ...[
            gap,
            Panel(
              title:
                  '${plural(plan!.files.length, 'file')} · ${fmtBytes(plan!.totalBytes)}${plan!.freeBytes != null ? ' (free: ${fmtBytes(plan!.freeBytes)})' : ''}',
              subtitle: plan!.packDir,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!plan!.fits)
                    Text(
                      'Not enough space on that drive.',
                      style: TextStyle(color: t.danger),
                    ),
                  for (final w in plan!.warnings)
                    HintText(w, icon: Icons.info_outline),
                  for (final f in plan!.files.take(200))
                    ListTile(
                      dense: true,
                      title: Text(f.relPath),
                      subtitle: f.problem != null
                          ? Text(f.problem!, style: TextStyle(color: t.warn))
                          : Text(fmtBytes(f.size)),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Recommendations with reasons (1.x DiscoveryView).
class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});
  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  int? crateId;
  final tracklist = TextEditingController(), follow = TextEditingController();
  Map<String, Object?>? matched;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final crates = ref
        .watch(cratesProvider)
        .where((c) => c.kind != 'folder')
        .toList();
    List<Map<String, Object?>> fit = const [];
    Map<String, Object?>? gaps;
    String? fitError;
    if (crateId != null) {
      try {
        fit = [
          for (final r in s.discovery.crateFit(crateId!, limit: 30)) r.toJson(),
        ];
        gaps = s.discovery.gaps(crateId!);
      } on Object catch (e) {
        fitError = '$e';
      }
    }
    final items = s.discovery.items();
    final followed = s.discovery.followed();
    return PageFrame(
      title: 'Discovery',
      subtitle: 'Every recommendation shows why, where it came from and when. Listening similarity is not proof two tracks mix well.',
      child: Wrap(
        spacing: 16,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.start,
        children: [
          SizedBox(
            width: 560,
            child: Panel(
              title: 'From your library',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<int?>(
                    initialValue: crateId,
                    decoration: const InputDecoration(labelText: 'Crate'),
                    hint: const Text('Pick a crate with a few tracks.'),
                    items: [
                      for (final c in crates)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setState(() => crateId = v),
                  ),
                  if (fitError != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(fitError, style: TextStyle(color: t.warn)),
                    ),
                  if (crateId != null && fitError == null && fit.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'No strong matches yet. Rate energy or analyse tracks for better results.',
                      ),
                    ),
                  for (final r in fit)
                    ListTile(
                      dense: true,
                      title: Text('${r['track']}'),
                      subtitle: Text(
                        (r['reasons'] as List).join(' · '),
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: TextButton(
                        onPressed: () => guard(
                          () => s.crates.addTracks(crateId!, [
                            r['track_id']! as int,
                          ]),
                          done: 'Added to the crate.',
                          bump: ref,
                        ),
                        child: const Text('Add'),
                      ),
                    ),
                  if (gaps != null && (gaps['artists'] as List).isNotEmpty) ...[
                    const Divider(height: 24),
                    const Text(
                      'Artists you own more of',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    for (final a in (gaps['artists'] as List).cast<Map>().take(
                      10,
                    ))
                      Text('${a['reason']}', style: TextStyle(color: t.muted)),
                  ],
                  if (crateId != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () async {
                          final n = await guard(
                            () => s.discovery.lastfmForCrate(
                              s.online,
                              s.secrets,
                              crateId!,
                            ),
                            bump: ref,
                          );
                          if (n != null) {
                            toast('Found $n similar artists on Last.fm.');
                          }
                        },
                        icon: const Icon(Icons.travel_explore, size: 18),
                        label: const Text('Similar artists on Last.fm'),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 460,
            child: Panel(
              title: 'Paste a tracklist',
              subtitle: 'From a radio show, a DJ mix or a festival set. One track per line, “Artist - Title”. “ID - ID” stays as unknown.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: tracklist,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      hintText: '01. Artist - Title',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: () => guard(
                        () => setState(
                          () => matched = s.discovery.matchTracklist(
                            tracklist.text,
                          ),
                        ),
                      ),
                      child: const Text('Match against my library'),
                    ),
                  ),
                  if (matched != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      '${matched!['owned']} owned · ${matched!['possibly_owned']} possibly · ${matched!['missing']} missing · ${matched!['unknown']} unknown',
                    ),
                    for (final l in (matched!['lines'] as List).cast<Map>())
                      ListTile(
                        dense: true,
                        leading: Icon(
                          switch (l['status']) {
                            'owned' => Icons.check_circle,
                            'possibly_owned' => Icons.help_outline,
                            'missing' => Icons.add_shopping_cart,
                            _ => Icons.question_mark,
                          },
                          color: l['status'] == 'owned'
                              ? t.ok
                              : (l['status'] == 'missing' ? t.warn : t.faint),
                          size: 18,
                        ),
                        title: Text('${l['text']}'),
                        subtitle: l['note'] != null
                            ? Text('${l['note']}')
                            : (l['match'] != null
                                  ? Text('${l['match']}')
                                  : null),
                      ),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(
            width: 560,
            child: Panel(
              title: 'Recommendations',
              subtitle: 'From Last.fm (similar artists/tracks) and MusicBrainz (new releases from artists you follow). Online services must be on in Settings.',
              trailing: TextButton(
                onPressed: () async {
                  final n = await guard(
                    () => s.discovery.refreshReleases(s.online),
                    bump: ref,
                  );
                  if (n != null) toast('Found $n new release(s).');
                },
                child: const Text('Check new releases'),
              ),
              child: Column(
                children: [
                  if (items.isEmpty)
                    Text(
                      'Results appear here.',
                      style: TextStyle(color: t.faint),
                    ),
                  for (final it in items.take(100))
                    ListTile(
                      dense: true,
                      title: Text(
                        '${it['artist']}${(it['title'] as String?)?.isNotEmpty == true ? ' — ${it['title']}' : ''}',
                      ),
                      subtitle: Text(
                        '${it['reason']} · ${it['source']} · ${it['ownership']}${it['released'] != null ? ' · ${it['released']}' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: Wrap(
                        children: [
                          IconButton(
                            tooltip: 'Wishlist',
                            icon: const Icon(
                              Icons.bookmark_add_outlined,
                              size: 18,
                            ),
                            onPressed: () => guard(
                              () => s.discovery.setItemStatus(
                                it['id']! as int,
                                'wishlist',
                              ),
                              bump: ref,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Dismiss',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => guard(
                              () => s.discovery.setItemStatus(
                                it['id']! as int,
                                'dismissed',
                              ),
                              bump: ref,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 460,
            child: Panel(
              title: 'Artists you follow',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: follow,
                    decoration: const InputDecoration(hintText: 'Artist name'),
                    onSubmitted: (v) {
                      guard(() => s.discovery.follow('artist', v), bump: ref);
                      follow.clear();
                    },
                  ),
                  for (final f in followed)
                    ListTile(
                      dense: true,
                      title: Text('${f['name']}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => guard(
                          () => s.discovery.unfollow(f['id']! as int),
                          bump: ref,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
