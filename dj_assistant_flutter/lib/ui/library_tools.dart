import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/health.dart';
import '../core/limits.dart' show upTo;
import '../core/json.dart';
import '../core/library.dart';
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
            subtitle: 'BPM, key, energy, loudness, intro/outro, cue ideas and a fingerprint, estimated on this computer. Files are only read.',
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
                ] else
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: () => guard(
                          () => s.startAnalysis(),
                          done: s.gig.active
                              ? 'Analysis queued — paused while gig mode is on.'
                              : 'Analysis started. Files are only read.',
                          bump: ref,
                        ),
                        child: const Text('Analyse new tracks'),
                      ),
                      OutlinedButton(
                        onPressed: () => guard(
                          () => s.startAnalysis(force: true),
                          done: 'Re-checking every track.',
                          bump: ref,
                        ),
                        child: const Text('Re-check library'),
                      ),
                    ],
                  ),
                const SizedBox(height: 6),
                HintText(
                  'Ogg Vorbis and Opus files are catalogued and tagged, but not analysed yet in 2.0 (method ${summary['method']} v${summary['version']}).',
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
          gap,
          Panel(
            title: 'Serato (read-only import)',
            subtitle: "Bring your Serato crates and play history into DJ Assistant. Serato's own files are only read.",
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final dir = await getDirectoryPath(
                      confirmButtonText: 'Choose _Serato_ folder',
                    );
                    if (dir == null) return;
                    final r = await guard(
                      () => s.serato.importCrates(dir),
                      bump: ref,
                    );
                    if (r != null) {
                      toast(
                        'Imported ${(r['crates'] as List).length} crate(s). ${r['note']}',
                      );
                    }
                  },
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: const Text('Import Serato crates…'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    final f = await openFile(
                      acceptedTypeGroups: const [
                        XTypeGroup(label: 'CSV', extensions: ['csv']),
                      ],
                    );
                    if (f == null) return;
                    final text = await f.readAsString();
                    final r = await guard(
                      () => s.serato.importHistoryCsv(text, f.name),
                      bump: ref,
                    );
                    if (r != null) {
                      toast(
                        'Imported ${r['matched']} plays (${r['unmatched']} not in your library).',
                      );
                    }
                  },
                  icon: const Icon(Icons.history, size: 18),
                  label: const Text('Import Serato history CSV…'),
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
      subtitle: "Fill in what's missing. Values are saved to DJ Assistant's catalogue only — your music files and Serato are not changed.",
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
            () => s.lookupCatalogs([for (final r in rows) r.track.id]),
            done: 'Looking up BPM, key, year and genre in the catalogues you turned on.',
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

/// Duplicate review: exact, possible and alternate versions. Nothing is deleted.
class DuplicatesScreen extends ConsumerWidget {
  const DuplicatesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final groups = s.duplicates.findGroups();
    final hash = s.jobs.status('hash');
    final live = hash.state == 'running' || hash.state == 'paused';
    String kindLabel(String k) => switch (k) {
      'exact' => 'Exact (identical file contents)',
      'possible' => 'Possible duplicate',
      _ => 'Alternate versions',
    };
    return PageFrame(
      title: 'Duplicate Review',
      subtitle: 'Exact matches are confirmed by comparing file contents. Possible matches and alternate versions need your ear. Nothing is deleted.',
      actions: [
        FilledButton.icon(
          onPressed: live
              ? null
              : () => guard(
                  () => s.startHash(),
                  done:
                      'Comparing file contents in the background (read-only).',
                  bump: ref,
                ),
          icon: const Icon(Icons.fingerprint),
          label: const Text('Find exact duplicates'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (live)
            ProgressLine(
              label: 'Comparing files…',
              done: hash.done,
              total: hash.total,
              message: hash.message,
            ),
          if (groups.isEmpty)
            const EmptyState(
              icon: Icons.done_all,
              title: 'No duplicates found',
              message: 'Run “Find exact duplicates” to compare file contents.',
            ),
          for (final g in groups)
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Pill(
                          kindLabel(g.kind),
                          color: g.kind == 'exact' ? t.warn : t.accent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            g.reason,
                            style: TextStyle(
                              color: t.faint,
                              fontSize: DjType.small,
                            ),
                          ),
                        ),
                        if (g.decision != null) Pill(g.decision!),
                        MenuAnchor(
                          builder: (c, ctl, _) => TextButton(
                            onPressed: ctl.open,
                            child: const Text('Mark…'),
                          ),
                          menuChildren: [
                            for (final (d, l) in [
                              ('keep_all', 'Keep all (not duplicates)'),
                              ('reviewed', 'Reviewed'),
                              (null, 'Clear decision'),
                            ])
                              MenuItemButton(
                                onPressed: () => guard(
                                  () => s.duplicates.setDecision(g.key, d),
                                  bump: ref,
                                ),
                                child: Text(l),
                              ),
                          ],
                        ),
                      ],
                    ),
                    for (final tr in g.tracks)
                      ListTile(
                        dense: true,
                        title: Text(
                          '${tr.artist ?? unknown} — ${tr.title ?? tr.fileName}',
                        ),
                        subtitle: Text(
                          '${tr.format ?? ''} · ${tr.bitrateKbps ?? '?'} kbps · ${fmtDuration(tr.durationMs)} · ${tr.path}',
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: SizedBox(
                          width: 220,
                          child: PreviewPlayer(
                            path: tr.path,
                            durationMs: tr.durationMs,
                          ),
                        ),
                      ),
                    const HintText(
                      'To remove or merge copies, use Organise Files → Replace duplicates: moves go to a removed-files area you can undo.',
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

/// Metadata suggestions to review before they reach the catalogue.
class SuggestionsScreen extends ConsumerStatefulWidget {
  const SuggestionsScreen({super.key});
  @override
  ConsumerState<SuggestionsScreen> createState() => _SuggestionsScreenState();
}

class _SuggestionsScreenState extends ConsumerState<SuggestionsScreen> {
  String status = 'pending';
  double min = 0.85;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final counts = s.suggestions.counts();
    final list = s.suggestions.list(
      status: status,
      limit: userLimit(ref, 'suggestions_shown'),
    );
    final on = s.settings.services();
    bool svc(String id) => on.any((x) => x['id'] == id && x['enabled'] == true);
    return PageFrame(
      title: 'Suggestions',
      subtitle: 'Fixes found in file names, folders, spellings and the online services you turned on. Nothing reaches your catalogue until you accept it; files are not changed.',
      actions: [
        OutlinedButton(
          onPressed: () => guard(
            () => toast(
              'Found ${s.suggestions.generateLocal()} new suggestion(s).',
            ),
            bump: ref,
          ),
          child: const Text('Find local suggestions'),
        ),
        OutlinedButton(
          onPressed: !svc('musicbrainz')
              ? () => toast(
                  'Turn on MusicBrainz in Settings → Online services',
                  error: true,
                )
              : () => guard(
                  () => s.lookupMusicbrainz(
                    s.library.trackIds(
                      const TrackQuery(),
                      max: userLimit(ref, 'lookup_musicbrainz'),
                    ),
                  ),
                  done: 'Looking up on MusicBrainz (one track a second).',
                ),
          child: const Text('MusicBrainz'),
        ),
        FilledButton.tonal(
          onPressed: () => guard(
            () => s.lookupCatalogs(
              s.library.trackIds(
                const TrackQuery(),
                max: userLimit(ref, 'lookup_catalogs'),
              ),
            ),
            done: 'Checking the online catalogues you turned on.',
          ),
          child: const Text('Online catalogues'),
        ),
      ],
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
                  for (final k in [
                    'pending',
                    'accepted',
                    'rejected',
                    'superseded',
                  ])
                    ButtonSegment(
                      value: k,
                      label: Text('$k (${counts[k] ?? 0})'),
                    ),
                ],
                selected: {status},
                onSelectionChanged: (v) => setState(() => status = v.first),
              ),
              if (status == 'pending') ...[
                const SizedBox(width: 16),
                Text(
                  'Accept all at or above',
                  style: TextStyle(color: t.faint),
                ),
                SizedBox(
                  width: 160,
                  child: Slider(
                    value: min,
                    min: 0.5,
                    max: 1,
                    divisions: 10,
                    label: '${(min * 100).round()}%',
                    onChanged: (v) => setState(() => min = v),
                  ),
                ),
                FilledButton(
                  onPressed: () => guard(
                    () => toast(
                      'Accepted ${s.suggestions.acceptBulk(min)} suggestion(s).',
                    ),
                    bump: ref,
                  ),
                  child: Text('Accept ≥ ${(min * 100).round()}%'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          if (list.isEmpty)
            const EmptyState(
              icon: Icons.auto_fix_high_outlined,
              title: 'Nothing here',
              message: 'Find suggestions from file names and folders, or turn on an online service in Settings.',
            ),
          for (final x in list)
            Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                title: Text(
                  '${x.track} — ${x.field}: ${x.currentValue ?? '∅'} → ${x.suggestedValue}',
                ),
                subtitle: Text(
                  '${x.source} · ${((x.confidence ?? 0) * 100).round()}% · ${x.evidence ?? ''}',
                  style: const TextStyle(fontSize: DjType.small),
                ),
                trailing: status == 'pending'
                    ? Wrap(
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
                            onPressed: () => guard(
                              () => s.suggestions.accept(x.id),
                              bump: ref,
                            ),
                            child: const Text('Accept'),
                          ),
                          IconButton(
                            tooltip: 'Reject',
                            onPressed: () => guard(
                              () => s.suggestions.reject(x.id),
                              bump: ref,
                            ),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      )
                    : TextButton(
                        onPressed: () =>
                            guard(() => s.suggestions.reset(x.id), bump: ref),
                        child: const Text('Back to pending'),
                      ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Rows as plain JSON for previews.
List<Map<String, Object?>> rowsAsJson(List<TrackRow> rows) => [
  for (final r in rows) r.toJson(),
];
