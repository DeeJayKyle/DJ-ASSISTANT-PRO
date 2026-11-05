import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/docs.dart';
import '../core/library.dart';
import '../core/library_edit.dart';
import '../core/export.dart' show revealInFolder;
import '../core/organize.dart';
import 'format.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Auto-prep, then (opt-in) names, folders and bad files on disk — every
/// change previewed, approved and undoable (1.x OrganizeView).
class OrganiseScreen extends ConsumerStatefulWidget {
  const OrganiseScreen({super.key});
  @override
  ConsumerState<OrganiseScreen> createState() => _OrganiseScreenState();
}

class _OrganiseScreenState extends ConsumerState<OrganiseScreen> {
  final rename = TextEditingController(text: '{artist} - {title}');
  final move = TextEditingController(text: '{genre}');
  OrganizePlan? plan;
  String? planTitle;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final settings = ref.watch(settingsProvider);
    final allow = settings['allow_file_changes'] == true;
    final prep = s.jobs.status('auto_prep');
    final prepLive = prep.state == 'running' || prep.state == 'paused';
    final ids = s.library.trackIds(const TrackQuery(), max: 5000);
    final bad = allow ? s.organize.badFiles() : const <int>[];
    final removed = s.organize.removedSummary();
    final history = s.organize.history(limit: 50);
    void preview(String title, OrganizePlan Function() f) => guard(
      () => setState(() {
        plan = f();
        planTitle = title;
      }),
    );
    return PageFrame(
      title: 'Organise Files',
      subtitle: 'Auto-prep your catalogue, then — when you choose — fix tags, names, folders and bad files on disk. Every file change is previewed, needs your OK and can be undone.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: '1. Auto-prep your catalogue',
            subtitle: 'Analysis, suggestions from names and folders, online lookups for services you turned on, then the confident fixes — into DJ Assistant only.',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('After every scan'),
                Switch(
                  value: settings['auto_prep'] == true,
                  onChanged: (v) =>
                      guard(() => s.settings.set('auto_prep', v), bump: ref),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (prepLive)
                  ProgressLine(
                    label: 'Auto-prep…',
                    done: prep.done,
                    total: prep.total,
                    message: prep.message,
                  ),
                if (prep.state == 'completed' && prep.result is Map)
                  Text(
                    'Last run: ${(prep.result! as Map)['fixes_applied']} fixes applied, ${(prep.result! as Map)['to_review'] ?? 0} left to review.',
                    style: TextStyle(color: t.muted),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: prepLive
                          ? null
                          : () => guard(
                              () => s.runAutoPrep(),
                              done: 'Auto-prep started.',
                              bump: ref,
                            ),
                      child: const Text('Run auto-prep now'),
                    ),
                    OutlinedButton(
                      onPressed: () =>
                          ref.read(viewProvider.notifier).go('suggestions'),
                      child: const Text('Review remaining suggestions'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          gap,
          Panel(
            title: '2. Changes to music files',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(allow ? 'Changes to files: on' : 'Changes to files: off'),
                Switch(
                  value: allow,
                  onChanged: (v) async {
                    if (v &&
                        !await confirm(
                          context,
                          title: 'Allow writing to music files?',
                          message: 'Renames, moves, tag writes and removals will be possible — each one previewed, needing your OK, backed up and undoable. Serato data inside files is preserved.',
                          ok: 'Allow',
                        )) {
                      return;
                    }
                    await guard(
                      () => s.settings.set('allow_file_changes', v),
                      bump: ref,
                    );
                  },
                ),
              ],
            ),
            child: !allow
                ? const HintText(
                    'Changes to music files are off, so only your catalogue is changed. To rename, re-tag or remove files, turn on “Allow writing to music files”.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const HintText(
                        "Write tags copies your catalogue values (titles, artists, genres, years, keys, BPM) into each file's own tags so Serato and other software see them. Every file is backed up first and can be rolled back from Settings → Change log. MP3, FLAC and M4A.",
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: rename,
                              decoration: const InputDecoration(
                                labelText: 'Rename files to',
                                helperText: '{artist} {title} {album} {genre} {year} {bpm} {key} {version}',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () => preview(
                              'Rename files',
                              () => s.organize.previewRename(ids, rename.text),
                            ),
                            child: const Text('Preview renames'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: move,
                              decoration: const InputDecoration(
                                labelText: 'Move into folders (inside each music folder)',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            onPressed: () => preview(
                              'Move files',
                              () => s.organize.previewMove(ids, move.text),
                            ),
                            child: const Text('Preview moves'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed: () async {
                              final dir = await getDirectoryPath(
                                confirmButtonText: 'Rename this folder',
                              );
                              if (dir == null || !context.mounted) return;
                              final n = await askText(
                                context,
                                title: 'New folder name',
                                ok: 'Preview',
                              );
                              if (n != null) {
                                preview(
                                  'Rename folder',
                                  () => s.organize.previewFolderRename(dir, n),
                                );
                              }
                            },
                            child: const Text('Rename a folder…'),
                          ),
                        ],
                      ),
                      const HintText(
                        'For a folder inside one of your music folders. Its tracks, crates and analysis follow.',
                      ),
                    ],
                  ),
          ),
          if (allow) ...[
            gap,
            Panel(
              title: '3. Bad files',
              subtitle: 'Unreadable or empty files. Removing moves them to a removed-files area you can restore from.',
              child: bad.isEmpty
                  ? Text(
                      'No unreadable or empty files found.',
                      style: TextStyle(color: t.faint),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final id in bad.take(50))
                          if (s.library.row(id) case final r?)
                            ListTile(
                              dense: true,
                              title: Text(r.path),
                              subtitle: Text(
                                r.fileSize == 0 ? 'Empty file' : 'Unreadable',
                              ),
                            ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton(
                            onPressed: () => preview(
                              'Remove bad files',
                              () => s.organize.previewRemove(bad),
                            ),
                            child: const Text('Preview removal'),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
          if (plan != null) ...[
            gap,
            Panel(
              title:
                  '$planTitle — ${plan!.ready} ready, ${plan!.blocked} blocked',
              subtitle: plan!.warning,
              trailing: Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => setState(() => plan = null),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: plan!.ready == 0
                        ? null
                        : () => guard(() {
                            final r = s.organize.apply(plan!);
                            toast(
                              '${r.done} change(s) made${r.skipped.isEmpty ? '' : ', ${r.skipped.length} skipped'}. Undo from the history below.',
                            );
                            setState(() => plan = null);
                          }, bump: ref),
                    child: Text('Apply ${plan!.ready}'),
                  ),
                ],
              ),
              child: plan!.ops.isEmpty
                  ? Text(
                      'Nothing to change — everything already matches.',
                      style: TextStyle(color: t.faint),
                    )
                  : Column(
                      children: [
                        for (final o in plan!.ops.take(300))
                          ListTile(
                            dense: true,
                            title: Text(
                              o.from,
                              style: const TextStyle(fontSize: 12),
                            ),
                            subtitle: o.blocked != null
                                ? Text(
                                    o.blocked!,
                                    style: TextStyle(color: t.warn),
                                  )
                                : Text(
                                    '→ ${o.to}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                          ),
                      ],
                    ),
            ),
          ],
          gap,
          Panel(
            title: 'Removed files (restorable)',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${removed['files'] ?? 0} files, ${fmtBytes(removed['bytes'])} in ${s.organize.removedArea}',
                  style: TextStyle(color: t.muted),
                ),
                if ((removed['files'] ?? 0) > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () async {
                        if (await confirm(
                          context,
                          title: 'Empty the removed-files area?',
                          message: 'These files are deleted for good. They cannot be restored afterwards.',
                          ok: 'Delete for good',
                          danger: true,
                        )) {
                          await guard(
                            () => toast(
                              'Deleted ${s.organize.emptyRemoved()} file(s).',
                            ),
                            bump: ref,
                          );
                        }
                      },
                      child: Text(
                        'Empty removed files',
                        style: TextStyle(color: t.danger),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'History',
            child: history.isEmpty
                ? Text('No file changes yet.', style: TextStyle(color: t.faint))
                : Column(
                    children: [
                      for (final h in history)
                        ListTile(
                          dense: true,
                          title: Text(
                            '${h['op']}: ${h['from_path']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '→ ${h['to_path'] ?? ''} · ${h['status']} · ${fmtDateTime(h['at'] as int?)}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: h['status'] == 'done'
                              ? TextButton(
                                  onPressed: () => guard(
                                    () => toast(
                                      'Undid ${s.organize.undo(opId: h['id']! as int)} change(s).',
                                    ),
                                    bump: ref,
                                  ),
                                  child: const Text('Undo'),
                                )
                              : null,
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// Personal files: opt-in, separate from music (1.x FilesView).
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});
  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  final q = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final pf = PersonalFiles(s.cat);
    if (!pf.enabled) {
      return EmptyState(
        icon: Icons.description_outlined,
        title: 'Personal files are off',
        message: 'A separate, opt-in index of folders you choose. Searched locally, never changed, never used for music recommendations.',
        action: FilledButton(
          onPressed: () =>
              guard(() => s.settings.set('docs_enabled', true), bump: ref),
          child: const Text('Turn on'),
        ),
      );
    }
    final job = s.jobs.status('docs');
    final results = pf.search(q.text);
    final rep = pf.report();
    return PageFrame(
      title: 'Personal Files',
      subtitle: 'A separate, opt-in index of folders you choose. Searched locally, never changed, never used for music recommendations.',
      actions: [
        OutlinedButton(
          onPressed: () async {
            final d = await getDirectoryPath(
              confirmButtonText: 'Choose a documents folder',
            );
            if (d != null) await guard(() => pf.addRoot(d), bump: ref);
          },
          child: const Text('Add folder…'),
        ),
        FilledButton(
          onPressed: job.state == 'running'
              ? null
              : () => guard(
                  () => s.jobs.start('docs', docsScanJob(s.dbPath)).ignore(),
                  done: 'Indexing (read-only)…',
                  bump: ref,
                ),
          child: const Text('Index now'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final r in pf.roots())
                InputChip(
                  label: Text('${r['path']} (${r['count']})'),
                  onDeleted: () =>
                      guard(() => pf.removeRoot(r['id']! as int), bump: ref),
                ),
            ],
          ),
          if (job.state == 'running')
            ProgressLine(label: 'Indexing…', done: job.done, total: job.total),
          const SizedBox(height: 10),
          TextField(
            controller: q,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search file names, folders and text in .txt, .md, .csv, .docx…',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 10),
          if (results.isEmpty)
            Text('No files found.', style: TextStyle(color: t.faint)),
          for (final r in results.take(100))
            ListTile(
              dense: true,
              title: Text('${r['name']}'),
              subtitle: Text(
                '${r['folder']} · ${fmtBytes(r['size'] as int?)}${r['snippet'] != null ? '\n…${r['snippet']}…' : ''}',
              ),
              trailing: IconButton(
                tooltip: 'Show in folder',
                icon: const Icon(Icons.folder_open, size: 18),
                onPressed: () => revealInFolderSafe('${r['path']}'),
              ),
            ),
          gap,
          Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              SizedBox(
                width: 360,
                child: Panel(
                  title: 'Duplicates (identical contents)',
                  child: Column(
                    children: [
                      for (final d
                          in (rep['duplicates'] as List).cast<Map>().take(20))
                        Text(
                          (d['paths'] as List).join('\n'),
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 360,
                child: Panel(
                  title: 'Encrypted or unreadable',
                  child: Column(
                    children: [
                      for (final f in (rep['flagged'] as List).cast<Map>().take(
                        20,
                      ))
                        Text(
                          '${f['path']} (${f['status']})',
                          style: const TextStyle(fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 360,
                child: Panel(
                  title: 'Organisation ideas',
                  child: (rep['suggestions'] as List).isEmpty
                      ? Text(
                          'Nothing to suggest.',
                          style: TextStyle(color: t.faint),
                        )
                      : Column(
                          children: [
                            for (final x
                                in (rep['suggestions'] as List).cast<Map>())
                              Text(
                                '${x['folder']}: ${x['count']} files. ${x['note']}',
                                style: const TextStyle(fontSize: 12),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
          gap,
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                if (await confirm(
                  context,
                  title: 'Clear the personal files index?',
                  message: 'The index and folder list are removed. Your files are not touched.',
                  ok: 'Clear',
                )) {
                  await guard(pf.clear, bump: ref);
                }
              },
              child: const Text('Clear index'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reveals a path in Explorer (ignores errors).
Future<void> revealInFolderSafe(String path) async {
  try {
    await revealInFolder(path);
  } on Object {
    toast("Couldn't open the folder.", error: true);
  }
}
