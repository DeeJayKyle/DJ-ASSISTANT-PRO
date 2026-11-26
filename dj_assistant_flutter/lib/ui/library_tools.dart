import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/health.dart';
import '../core/limits.dart' show upTo;
import '../core/library_edit.dart';
import '../core/scanner.dart';
import 'format.dart';
import 'library_screen.dart' show addMusicFolders;
import 'player.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Folders, scans, audio analysis, the folder watcher and Serato import.
class ActivityScreen extends ConsumerWidget {
  const ActivityScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final roots = ref.watch(rootsProvider);
    final ScanProgress? sc = s.lastScan;
    final scanning =
        sc != null && (sc.state == 'running' || sc.state == 'paused');
    final an = s.jobs.status('analysis');
    final anLive = an.state == 'running' || an.state == 'paused';
    final summary = s.analysis.summary();
    final watch = s.watcher;
    final events = watch.enabled
        ? watch.pending()
        : const <Map<String, Object?>>[];
    final last = s.health.health()['last_scan'] as Map?;
    return PageFrame(
      title: 'Scan Activity',
      subtitle: 'Folders, scans, audio analysis and the folder watcher. Your files are only read.',
      actions: [
        OutlinedButton.icon(
          onPressed: () => addMusicFolders(ref),
          icon: const Icon(Icons.create_new_folder_outlined, size: 18),
          label: const Text('Add folder…'),
        ),
        FilledButton.icon(
          onPressed: scanning || roots.isEmpty
              ? null
              : () => guard(
                  () => s.startScan(),
                  done: 'Read-only scan started.',
                  bump: ref,
                ),
          icon: const Icon(Icons.refresh),
          label: const Text('Scan all'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: 'Scan',
            child: sc == null
                ? Text(
                    last == null
                        ? 'Not run yet.'
                        : 'Last scan ${fmtDateTime(last['finished_at'] as int?)}: ${last['added']} new, ${last['updated']} updated, ${last['errors']} problems.',
                    style: TextStyle(color: t.faint),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ProgressLine(
                        label: switch (sc.state) {
                          'running' =>
                            sc.phase == 'discovering'
                                ? 'Finding music files…'
                                : 'Reading tags…',
                          'paused' => 'Paused',
                          'cancelled' => 'Cancelled. Everything read before cancelling was saved; nothing was marked missing.',
                          'completed' => 'Scan complete',
                          _ => 'Scan ${sc.state}',
                        },
                        done: sc.filesProcessed,
                        total: sc.filesToRead,
                        message:
                            '${sc.added} new · ${sc.updated} updated · ${sc.unchanged} unchanged · ${sc.missing} missing · ${sc.errors} problems',
                      ),
                      if (scanning)
                        Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: () => sc.state == 'paused'
                                  ? s.scan.resume()
                                  : s.scan.pause(),
                              child: Text(
                                sc.state == 'paused' ? 'Resume' : 'Pause',
                              ),
                            ),
                            OutlinedButton(
                              onPressed: s.scan.cancel,
                              child: Text(
                                'Cancel',
                                style: TextStyle(color: t.danger),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
          ),
          gap,
          Panel(
            title: 'Music folders',
            subtitle: 'Only folders you add are ever scanned. An unplugged drive is shown as offline; its tracks are kept.',
            child: roots.isEmpty
                ? Text(
                    'No folders yet. Only folders you add are ever scanned.',
                    style: TextStyle(color: t.faint),
                  )
                : Column(
                    children: [
                      for (final r in roots)
                        ListTile(
                          leading: Icon(
                            Icons.storage_outlined,
                            color: r.status == 'offline' ? t.warn : t.ok,
                          ),
                          title: Text(r.path),
                          subtitle: Text(
                            r.status == 'offline'
                                ? 'Offline — tracks kept, not deleted'
                                : (r.lastScanAt == null
                                      ? 'Not scanned yet'
                                      : 'Scanned ${fmtDateTime(r.lastScanAt)}'),
                          ),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              TextButton(
                                onPressed: scanning
                                    ? null
                                    : () => guard(
                                        () => s.startScan(rootIds: [r.id]),
                                        bump: ref,
                                      ),
                                child: const Text('Scan'),
                              ),
                              IconButton(
                                tooltip: 'Remove folder from library',
                                onPressed: () async {
                                  final ok = await confirm(
                                    context,
                                    title: 'Remove folder from library?',
                                    message: "Its tracks leave DJ Assistant's catalogue (crates lose them). The files on disk are not touched. If the drive is just unplugged, keep it — its tracks are shown as offline.",
                                    ok: 'Remove',
                                    danger: true,
                                  );
                                  if (ok) {
                                    await guard(
                                      () => s.roots.remove(r.id),
                                      done: 'Folder removed. Files on disk were not touched.',
                                      bump: ref,
                                    );
                                  }
                                },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          gap,
          Panel(
            title: 'Audio analysis',
            subtitle: 'Energy (1–10) and loudness, plus BPM and key for tracks Serato has not analysed, measured on this computer. Start it from the Analyse tab.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    StatTile(
                      'Analysed',
                      fmtNumber(summary['analysed'] as int? ?? 0),
                    ),
                    StatTile(
                      'Waiting',
                      fmtNumber(summary['pending'] as int? ?? 0),
                    ),
                    StatTile(
                      'Could not analyse',
                      fmtNumber(summary['errors'] as int? ?? 0),
                      warn: (summary['errors'] as int? ?? 0) > 0,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (anLive) ...[
                  ProgressLine(
                    label: an.state == 'paused'
                        ? 'Analysis paused'
                        : 'Analysing…',
                    done: an.done,
                    total: an.total,
                    message: an.message,
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: () =>
                            s.jobs.pause('analysis', an.state != 'paused'),
                        child: Text(an.state == 'paused' ? 'Resume' : 'Pause'),
                      ),
                      OutlinedButton(
                        onPressed: () => s.jobs.cancel('analysis'),
                        child: Text(
                          'Cancel',
                          style: TextStyle(color: t.danger),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                HintText(
                  'Ogg and Opus files need Microsoft\'s free Web Media Extensions to be analysed (method ${summary['method']} v${summary['version']}).',
                ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Folder watcher',
            subtitle: 'Notices new and changed music files in your folders and suggests where they belong. It never moves anything.',
            trailing: Switch(
              value: watch.enabled,
              onChanged: (v) => guard(() {
                s.settings.set('watch_enabled', v);
                v ? s.watcher.start() : s.watcher.stop();
              }, bump: ref),
            ),
            child: !watch.enabled
                ? Text('Not watching.', style: TextStyle(color: t.faint))
                : events.isEmpty
                ? Text(
                    'Watching — no new files yet.',
                    style: TextStyle(color: t.faint),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final e in upTo(events, listRows(ref)))
                        ListTile(
                          dense: true,
                          title: Text(
                            '${e['path']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${e['kind']}${e['suggested_folder'] != null ? ' · suggested folder: ${e['suggested_folder']}' : ''}',
                          ),
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          FilledButton(
                            onPressed: scanning
                                ? null
                                : () => guard(() {
                                    s.startScan();
                                    s.watcher.clear();
                                  }, bump: ref),
                            child: const Text('Scan now'),
                          ),
                          OutlinedButton(
                            onPressed: () => guard(s.watcher.clear, bump: ref),
                            child: const Text('Dismiss'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Library Health cards and the fixer.
class HealthScreen extends ConsumerStatefulWidget {
  const HealthScreen({super.key, this.fix});
  final String? fix;
  @override
  ConsumerState<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends ConsumerState<HealthScreen> {
  late String? fix = widget.fix;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    if (fix != null) {
      return HealthFix(
        category: fix!,
        onBack: () => setState(() => fix = null),
      );
    }
    final h = s.health.health();
    final items = (h['items'] as List).cast<HealthItem>();
    final errors = (h['recent_errors'] as List?)?.cast<Map>() ?? const [];
    return PageFrame(
      title: 'Library Health',
      subtitle: 'What needs attention. Every card opens the matching tracks; fixes go to the catalogue unless you choose to write tags.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AutoGrid(
            minWidth: 300,
            children: [
              for (final it in items)
                SizedBox(
                  width: 300,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  it.label,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                fmtNumber(it.count),
                                style: TextStyle(
                                  fontSize: DjType.heading,
                                  fontWeight: FontWeight.w700,
                                  color: it.count > 0 ? t.warn : t.ok,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            it.explanation,
                            style: TextStyle(
                              color: t.faint,
                              fontSize: DjType.small,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            children: [
                              TextButton(
                                onPressed: it.count == 0
                                    ? null
                                    : () {
                                        ref
                                            .read(libraryQueryProvider.notifier)
                                            .set(
                                              LibraryQuery(
                                                filters: it.filters,
                                                label: it.label,
                                              ),
                                            );
                                        ref
                                            .read(viewProvider.notifier)
                                            .go('library');
                                      },
                                child: const Text('Show tracks'),
                              ),
                              if (it.fixFields.isNotEmpty && it.count > 0)
                                FilledButton.tonal(
                                  onPressed: () => setState(() => fix = it.id),
                                  child: const Text('Fix…'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (errors.isNotEmpty) ...[
            gap,
            Panel(
              title: 'Last scan problems',
              child: Column(
                children: [
                  for (final e in upTo(errors, listRows(ref)))
                    ListTile(
                      dense: true,
                      title: Text(
                        '${e['path'] ?? e['file_name'] ?? ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${e['read_error'] ?? e['message'] ?? ''}',
                      ),
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

/// Fills in missing values with local evidence (1.x HealthFixView).
class HealthFix extends ConsumerStatefulWidget {
  const HealthFix({super.key, required this.category, required this.onBack});
  final String category;
  final VoidCallback onBack;
  @override
  ConsumerState<HealthFix> createState() => _HealthFixState();
}

class _HealthFixState extends ConsumerState<HealthFix> {
  final edits = <String, TextEditingController>{};
  final selected = <int>{};
  int offset = 0;

  String? _validate(String field, String v) {
    if (field == 'year') {
      final y = int.tryParse(v);
      if (y == null || y < 1900 || y > 2100) {
        return 'Year must be between 1900 and 2100';
      }
    }
    if (field == 'bpm') {
      final b = double.tryParse(v);
      if (b == null || b < 40 || b > 300) {
        return 'BPM must be between 40 and 300';
      }
    }
    return null;
  }

  Object? _value(String field, String v) => switch (field) {
    'year' => int.tryParse(v),
    'bpm' => double.tryParse(v),
    _ => v,
  };

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final (label, fields, total, rows) = s.health.fixList(
      widget.category,
      offset: offset,
    );
    TextEditingController ctl(int id, String f) =>
        edits['$id|$f'] ??= TextEditingController();
    void save(List<int> ids, String f, String v) {
      final err = _validate(f, v);
      if (err != null) return toast(err, error: true);
      guard(
        () => s.library.updateUserFields(ids, {f: _value(f, v)}),
        done: 'Saved ${plural(ids.length, 'track')} to your catalogue.',
        bump: ref,
      );
    }

    return PageFrame(
      title: label,
      subtitle: ref.watch(settingsProvider)['sync_to_files'] == true
          ? "Fill in what's missing. Values are saved to DJ Assistant and written into the music files (backed up first; Settings → Changes to music files)."
          : "Fill in what's missing. Values are saved to DJ Assistant's catalogue only — your music files and Serato are not changed.",
      actions: [
        TextButton.icon(
          onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back),
          label: const Text('Back to Library health'),
        ),
        OutlinedButton(
          onPressed: () => guard(() {
            final n = s.suggestions.generateLocal();
            toast(
              'Checked file names, folders and spellings: $n new suggestion(s).',
            );
          }, bump: ref),
          child: const Text('Find suggestions'),
        ),
        OutlinedButton(
          onPressed: () => guard(
            () => s.runAnalyse(
              scope: 'ids',
              ids: [for (final r in rows) r.track.id],
            ),
            done: 'Asking every online analyser about these tracks.',
          ),
          child: const Text('Look up online'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${plural(total, 'track')} · tip: select tracks to set one value on all of them (for example a whole album\'s year).',
            style: TextStyle(color: t.faint),
          ),
          if (selected.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text('${selected.length} selected'),
                    for (final f in fields)
                      SizedBox(
                        width: 220,
                        child: TextField(
                          decoration: InputDecoration(
                            labelText: 'Set $f on all',
                          ),
                          onSubmitted: (v) => v.trim().isEmpty
                              ? toast('Type a value to apply.', error: true)
                              : save(selected.toList(), f, v.trim()),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          for (final r in rows)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: selected.contains(r.track.id),
                      onChanged: (v) => setState(
                        () => v!
                            ? selected.add(r.track.id)
                            : selected.remove(r.track.id),
                      ),
                    ),
                    SizedBox(
                      width: 200,
                      child: PreviewPlayer(
                        path: r.track.path,
                        durationMs: r.track.durationMs,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            r.track.title ?? r.track.fileName,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            '${r.track.artist ?? unknown} · ${r.folder}',
                            style: TextStyle(
                              color: t.faint,
                              fontSize: DjType.small,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              for (final f in fields)
                                SizedBox(
                                  width: 240,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      TextField(
                                        controller: ctl(r.track.id, f),
                                        decoration: InputDecoration(
                                          labelText: f,
                                        ),
                                        onSubmitted: (v) => v.trim().isEmpty
                                            ? toast(
                                                'Nothing to save — type a value or pick a suggestion first.',
                                                error: true,
                                              )
                                            : save([r.track.id], f, v.trim()),
                                      ),
                                      Wrap(
                                        spacing: 4,
                                        children: [
                                          for (final h
                                              in r.hints
                                                  .where((h) => h.field == f)
                                                  .take(3))
                                            Tooltip(
                                              message:
                                                  '${h.source}: ${h.evidence}',
                                              child: ActionChip(
                                                label: Text(h.value),
                                                onPressed: () =>
                                                    ctl(r.track.id, f).text =
                                                        h.value,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    FilledButton.tonal(
                      onPressed: () {
                        final vals = {
                          for (final f in fields)
                            if (ctl(r.track.id, f).text.trim().isNotEmpty)
                              f: ctl(r.track.id, f).text.trim(),
                        };
                        if (vals.isEmpty) {
                          return toast(
                            'Nothing to save — type a value or pick a suggestion first.',
                            error: true,
                          );
                        }
                        for (final e in vals.entries) {
                          final err = _validate(e.key, e.value);
                          if (err != null) return toast(err, error: true);
                        }
                        guard(
                          () => s.library.updateUserFields(
                            [r.track.id],
                            {
                              for (final e in vals.entries)
                                e.key: _value(e.key, e.value),
                            },
                          ),
                          done: 'Saved to your catalogue.',
                          bump: ref,
                        );
                      },
                      child: const Text('Save'),
                    ),
                  ],
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: offset == 0
                    ? null
                    : () => setState(() => offset -= 100),
                child: const Text('Previous'),
              ),
              TextButton(
                onPressed: offset + 100 >= total
                    ? null
                    : () => setState(() => offset += 100),
                child: const Text('Next'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Analysis → Changes: every change the analysers made (with every source's
/// vote), undoable one by one or in batches; and the few findings that wait
/// for a decision (file-name clues that would replace a value you have).
class SuggestionsScreen extends ConsumerStatefulWidget {
  const SuggestionsScreen({super.key});
  @override
  ConsumerState<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends ConsumerState<SuggestionsScreen> {
  String status = 'accepted';
  String? field, source;
  double min = 0.85;
  final selected = <int>{};

  void _show(String st) => setState(() {
    status = st;
    selected.clear();
  });

  Future<void> _batch(String what, (int, int) Function() f) async {
    final r = await guard(f, bump: ref);
    if (r == null) return;
    final (ok, failed) = r;
    setState(selected.clear);
    toast(
      '$what ${plural(ok, 'suggestion')}'
      '${failed == 0 ? '' : '; ${plural(failed, 'was', 'were')} left as they are (changed since, or not valid)'}.',
      error: ok == 0 && failed > 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final counts = s.suggestions.counts();
    final all = s.suggestions.list(
      status: status,
      limit: userLimit(ref, 'suggestions_shown'),
    );
    final list = [
      for (final x in all)
        if ((field == null || x.field == field) &&
            (source == null || x.source == source))
          x,
    ];
    final fields = {for (final x in all) x.field}.toList()..sort();
    final sources = {for (final x in all) x.source}.toList()..sort();
    final by = status == 'accepted'
        ? s.suggestions.decidedBy(list.map((x) => x.id))
        : const <int, String>{};
    selected.retainWhere((id) => list.any((x) => x.id == id));
    final allSelected = list.isNotEmpty && selected.length == list.length;
    return PageFrame(
      title: 'Changes',
      subtitle: 'Every change the analysers made to your tracks, with the sources that agreed. Undo puts the old value back, in the files too.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<String>(
                segments: [
                  for (final (k, label) in const [
                    ('accepted', 'Applied'),
                    ('pending', 'Waiting'),
                    ('rejected', 'Not applied'),
                  ])
                    ButtonSegment(
                      value: k,
                      label: Text('$label (${fmtNumber(counts[k] ?? 0)})'),
                    ),
                ],
                selected: {status},
                onSelectionChanged: (v) => _show(v.first),
              ),
              _Filter(
                label: 'Field',
                value: field,
                options: fields,
                onChanged: (v) => setState(() => field = v),
              ),
              _Filter(
                label: 'Source',
                value: source,
                options: sources,
                onChanged: (v) => setState(() => source = v),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (list.isNotEmpty)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  label: 'Select all shown',
                  child: Checkbox(
                    tristate: true,
                    value: allSelected
                        ? true
                        : (selected.isEmpty ? false : null),
                    onChanged: (_) => setState(() {
                      if (allSelected) {
                        selected.clear();
                      } else {
                        selected.addAll(list.map((x) => x.id));
                      }
                    }),
                  ),
                ),
                Text(
                  selected.isEmpty
                      ? 'Select all ${fmtNumber(list.length)} shown'
                      : '${fmtNumber(selected.length)} of ${fmtNumber(list.length)} selected',
                  style: TextStyle(color: t.muted),
                ),
                if (status == 'pending') ...[
                  FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () => _batch(
                            'Approved',
                            () => s.suggestions.acceptMany(selected),
                          ),
                    child: const Text('Approve selected'),
                  ),
                  OutlinedButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () => _batch(
                            'Rejected',
                            () => s.suggestions.rejectMany(selected),
                          ),
                    child: const Text('Reject selected'),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      selected
                        ..clear()
                        ..addAll(
                          list
                              .where((x) => (x.confidence ?? 0) >= min)
                              .map((x) => x.id),
                        );
                    }),
                    child: Text('Select ≥ ${(min * 100).round()}%'),
                  ),
                  SizedBox(
                    width: 140,
                    child: Slider(
                      value: min,
                      min: 0.5,
                      max: 1,
                      divisions: 10,
                      label: '${(min * 100).round()}%',
                      semanticFormatterCallback: (v) =>
                          'Confidence ${(v * 100).round()} percent',
                      onChanged: (v) => setState(() => min = v),
                    ),
                  ),
                ],
                if (status == 'accepted')
                  OutlinedButton.icon(
                    icon: const Icon(Icons.undo),
                    onPressed: selected.isEmpty
                        ? null
                        : () => _batch(
                            'Undid',
                            () => s.suggestions.undoMany(selected),
                          ),
                    label: const Text('Undo selected'),
                  ),
                if (status == 'rejected')
                  OutlinedButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () => _batch('Moved back', () {
                            for (final id in selected) {
                              s.suggestions.reset(id);
                            }
                            return (selected.length, 0);
                          }),
                    child: const Text('Back to review'),
                  ),
              ],
            ),
          const SizedBox(height: 6),
          if (list.isEmpty)
            EmptyState(
              icon: Icons.auto_fix_high_outlined,
              title: status == 'pending' ? 'Nothing waiting' : 'No changes yet',
              message: 'Press Analyse to look your tracks up online. Every change it makes is listed here.',
            ),
          for (final x in list)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                leading: Checkbox(
                  value: selected.contains(x.id),
                  semanticLabel: 'Select ${x.field} for ${x.track}',
                  onChanged: (v) => setState(
                    () =>
                        v == true ? selected.add(x.id) : selected.remove(x.id),
                  ),
                ),
                title: Text(
                  x.track,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '${x.field}: ',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          TextSpan(
                            text: x.currentValue ?? '(empty)',
                            style: TextStyle(color: t.faint),
                          ),
                          const TextSpan(text: '  →  '),
                          TextSpan(text: x.suggestedValue),
                        ],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${x.source} · ${((x.confidence ?? 0) * 100).round()}% confident'
                      '${x.evidence == null || x.evidence!.isEmpty ? '' : ' · ${x.evidence}'}',
                      style: TextStyle(fontSize: DjType.small, color: t.faint),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                trailing: switch (status) {
                  'pending' => Wrap(
                    spacing: 4,
                    children: [
                      IconButton(
                        tooltip: 'Edit and accept',
                        onPressed: () async {
                          final v = await askText(
                            context,
                            title: 'Accept with a change',
                            label: x.field,
                            initial: x.suggestedValue,
                            ok: 'Accept',
                          );
                          if (v != null) {
                            await guard(
                              () => s.suggestions.accept(x.id, edited: v),
                              bump: ref,
                            );
                          }
                        },
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      FilledButton.tonal(
                        onPressed: () =>
                            guard(() => s.suggestions.accept(x.id), bump: ref),
                        child: const Text('Accept'),
                      ),
                      IconButton(
                        tooltip: 'Reject',
                        onPressed: () =>
                            guard(() => s.suggestions.reject(x.id), bump: ref),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  'accepted' => Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Pill(
                        switch (by[x.id]) {
                          'auto' => 'automatic',
                          'you' => 'by you',
                          _ => 'earlier',
                        },
                        color: by[x.id] == 'auto' ? t.warn : null,
                        tooltip: by[x.id] == null
                            ? 'Accepted before DJ Assistant kept the previous value; edit the track to change it.'
                            : null,
                      ),
                      TextButton(
                        onPressed: by[x.id] == null
                            ? null
                            : () => guard(
                                () => s.suggestions.undo(x.id),
                                done: 'Restored the previous value.',
                                bump: ref,
                              ),
                        child: const Text('Undo'),
                      ),
                    ],
                  ),
                  _ => TextButton(
                    onPressed: () =>
                        guard(() => s.suggestions.reset(x.id), bump: ref),
                    child: const Text('Back to review'),
                  ),
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _Filter extends StatelessWidget {
  const _Filter({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final String label;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButton<String?>(
    value: options.contains(value) ? value : null,
    hint: Text('$label: all'),
    items: [
      DropdownMenuItem(value: null, child: Text('$label: all')),
      for (final o in options)
        DropdownMenuItem(
          value: o,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text('$label: $o', overflow: TextOverflow.ellipsis),
          ),
        ),
    ],
    onChanged: onChanged,
  );
}
