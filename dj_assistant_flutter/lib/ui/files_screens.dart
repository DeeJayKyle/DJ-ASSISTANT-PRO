import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/session.dart';
import '../core/crates.dart' show Crate;
import '../core/docs.dart';
import '../core/duplicates.dart' show DupGroup;
import '../core/limits.dart' show upTo;
import '../core/library.dart';
import '../core/library_edit.dart';
import '../core/export.dart' show revealInFolder;
import '../core/organize.dart';
import 'format.dart';
import 'organise_preview.dart';
import 'write_dialog.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Organise Files: auto-prep for the catalogue, then (opt-in, off by default)
/// tags, names, folders, replacements, duplicates and bad files on disk. Every
/// file change is listed in a preview, approved item by item or in batches,
/// verified, kept restorable and undoable.
class OrganiseScreen extends ConsumerStatefulWidget {
  const OrganiseScreen({super.key});
  @override
  ConsumerState<OrganiseScreen> createState() => _OrganiseScreenState();
}

class _OrganiseScreenState extends ConsumerState<OrganiseScreen> {
  final rename = TextEditingController(text: '{artist} - {title}');
  final move = TextEditingController(text: '{genre}');

  /// `sent` (from the Library), `crate:ID` or `all`.
  String? scope;
  bool showRemoved = false;

  @override
  void dispose() {
    rename.dispose();
    move.dispose();
    super.dispose();
  }

  (String, List<int>)? _scope(AppSession s, List<Crate> crates) {
    final sent = ref.read(organiseTargetProvider);
    final sc = scope ?? (sent != null ? 'sent' : null);
    if (sc == 'sent' && sent != null) return sent;
    if (sc == 'all') {
      return ('every track', s.library.trackIds(const TrackQuery()));
    }
    if (sc != null && sc.startsWith('crate:')) {
      final id = int.tryParse(sc.substring(6));
      final c = crates.where((c) => c.id == id).firstOrNull;
      if (c != null) {
        return (
          '“${c.name}”',
          s.library.trackIds(TrackQuery(extraWhere: s.crates.membership(c.id))),
        );
      }
    }
    return null;
  }

  Future<void> _preview(String title, OrganizePlan Function() f) async {
    final plan = await guard(f);
    if (plan == null || !mounted) return;
    await showOrganisePreview(context, ref, plan, title: title);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final settings = ref.watch(settingsProvider);
    final on = settings['organise_mode'] == true;
    final prep = s.jobs.status('auto_prep');
    final prepLive = prep.state == 'running' || prep.state == 'paused';
    final crates = ref
        .watch(cratesProvider)
        .where((c) => c.kind != 'folder')
        .toList();
    final sent = ref.watch(organiseTargetProvider);
    final target = on ? _scope(s, crates) : null;
    final ids = target?.$2 ?? const <int>[];
    final bad = on ? s.organize.badFiles() : const <int>[];
    final removed = s.organize.removedSummary();
    final history = s.organize.history(limit: listRows(ref));
    final mode = settings['fix_mode'];
    return PageFrame(
      title: 'Organise Files',
      subtitle: 'Prepare your catalogue, then — only when you turn on Organise Files mode — edit tags, rename and move files or folders, replace tracks and remove duplicates. Every change is previewed, needs your OK, is verified and can be undone.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: '1. Auto-prep your catalogue',
            subtitle: mode == 'review'
                ? 'Analysis and suggestions from names, folders and the online services you turned on. Suggestions wait for your review; nothing changes until you approve it.'
                : 'Analysis and suggestions, then ${mode == 'auto' ? 'confident fixes' : 'empty fields filled'} — into DJ Assistant only, undoable. Change this in Settings → Library.',
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
                    'Last run: ${(prep.result! as Map)['fixes_applied']} applied, ${(prep.result! as Map)['left_to_review'] ?? 0} waiting for your review.',
                    style: TextStyle(color: t.muted),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
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
                      child: const Text('Review suggestions'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          gap,
          Panel(
            title: '2. Organise Files mode',
            subtitle: 'Off by default. Changes the files on disk, so test on copies of your music first and keep a backup.',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(on ? 'On' : 'Off'),
                Switch(
                  value: on,
                  onChanged: (v) async {
                    if (v &&
                        !await confirm(
                          context,
                          title: 'Turn on Organise Files mode?',
                          message: 'Tag edits, renames, moves, replacements and removals become possible. Nothing happens by itself: every change is listed in a preview, needs your OK, is checked again just before it runs, and can be undone. Removed and replaced files go to a restorable Removed files area; nothing is deleted for good unless you empty it.\n\nRenaming or moving files breaks Serato\'s links to them until you relocate them in Serato. Previews say which tracks Serato knows about.',
                          ok: 'Turn on',
                        )) {
                      return;
                    }
                    await guard(
                      () => s.settings.set('organise_mode', v),
                      bump: ref,
                    );
                  },
                ),
              ],
            ),
            child: !on
                ? const HintText(
                    'Organise Files mode is off, so your music files are only read. Your catalogue (titles, genres, crates…) can still be changed safely.',
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text('Work on'),
                          DropdownButton<String>(
                            value: scope ?? (sent != null ? 'sent' : null),
                            hint: const Text('Choose tracks…'),
                            items: [
                              if (sent != null)
                                DropdownMenuItem(
                                  value: 'sent',
                                  child: Text(
                                    '${sent.$1} (${fmtNumber(sent.$2.length)})',
                                  ),
                                ),
                              for (final c in crates)
                                DropdownMenuItem(
                                  value: 'crate:${c.id}',
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 320,
                                    ),
                                    child: Text(
                                      'Crate: ${c.name}',
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                              const DropdownMenuItem(
                                value: 'all',
                                child: Text('Every track in the library'),
                              ),
                            ],
                            onChanged: (v) => setState(() => scope = v),
                          ),
                          if (target != null)
                            Text(
                              plural(ids.length, 'track'),
                              style: TextStyle(color: t.muted),
                            ),
                        ],
                      ),
                      const HintText(
                        'Tip: select tracks in the Library and choose “Organise…” to work on just those.',
                      ),
                      const SizedBox(height: Space.x3),
                      _Action(
                        title: 'Edit tags in the files',
                        sub: "Writes catalogue values (titles, artists, genres, years, keys, BPM) into each file's own tags, after an exact preview and a verified backup. Serato's cue and beatgrid data in the file is kept byte for byte. Roll back from Settings → Change log.",
                        child: OutlinedButton(
                          onPressed: ids.isEmpty
                              ? null
                              : () => showWriteDialog(
                                  context,
                                  ref,
                                  ids,
                                  fromCatalogue: true,
                                ),
                          child: const Text('Preview tag edits…'),
                        ),
                      ),
                      _Action(
                        title: 'Rename files',
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: rename,
                                decoration: const InputDecoration(
                                  labelText: 'New names',
                                  helperText: '{artist} {title} {album} {genre} {year} {bpm} {key} {version}',
                                  helperMaxLines: 2,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: ids.isEmpty
                                  ? null
                                  : () => _preview(
                                      'Rename ${plural(ids.length, 'file')}',
                                      () => s.organize.previewRename(
                                        ids,
                                        rename.text,
                                      ),
                                    ),
                              child: const Text('Preview…'),
                            ),
                          ],
                        ),
                      ),
                      _Action(
                        title: 'Move files into folders',
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: move,
                                decoration: const InputDecoration(
                                  labelText: 'Folders inside each music folder',
                                  helperText: 'e.g. {genre}/{artist}',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton(
                              onPressed: ids.isEmpty
                                  ? null
                                  : () => _preview(
                                      'Move ${plural(ids.length, 'file')}',
                                      () => s.organize.previewMove(
                                        ids,
                                        move.text,
                                      ),
                                    ),
                              child: const Text('Preview…'),
                            ),
                          ],
                        ),
                      ),
                      _Action(
                        title: 'Rename a folder',
                        sub: 'For a folder inside one of your music folders. Its tracks, crates and analysis follow in DJ Assistant.',
                        child: OutlinedButton(
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
                              await _preview(
                                'Rename folder',
                                () => s.organize.previewFolderRename(dir, n),
                              );
                            }
                          },
                          child: const Text('Choose a folder…'),
                        ),
                      ),
                      _Action(
                        title: 'Replace a track with a better file',
                        sub: 'Right-click a track in the Library (or the Upgrades page) and choose “Replace with a better file…”. The old file is kept in Removed files.',
                        child: OutlinedButton(
                          onPressed: () =>
                              ref.read(viewProvider.notifier).go('upgrades'),
                          child: const Text('Open Upgrades'),
                        ),
                      ),
                      const _DuplicatesAction(),
                      _Action(
                        title: 'Bad files',
                        sub: bad.isEmpty
                            ? 'No unreadable or empty files found.'
                            : '${plural(bad.length, 'unreadable or empty file')}. Removing moves them to Removed files.',
                        child: OutlinedButton(
                          onPressed: bad.isEmpty
                              ? null
                              : () => _preview(
                                  'Remove bad files',
                                  () => s.organize.previewRemove(bad),
                                ),
                          child: const Text('Preview removal…'),
                        ),
                      ),
                    ],
                  ),
          ),
          gap,
          Panel(
            title: 'Removed files (restorable)',
            subtitle: 'Files you removed or replaced wait here, outside your music folders, until you empty it. Undo brings any of them back.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${plural(removed['files'] ?? 0, 'file')}, ${fmtBytes(removed['bytes'])} in ${s.organize.removedArea}',
                  style: TextStyle(color: t.muted),
                ),
                if ((removed['files'] ?? 0) > 0)
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () =>
                            setState(() => showRemoved = !showRemoved),
                        child: Text(showRemoved ? 'Hide list' : 'Show list'),
                      ),
                      TextButton(
                        onPressed: () => _emptyRemoved(context, s),
                        child: Text(
                          'Delete these for good…',
                          style: TextStyle(color: t.danger),
                        ),
                      ),
                    ],
                  ),
                if (showRemoved)
                  for (final f in upTo(
                    s.organize.removedFiles(),
                    listRows(ref),
                  ))
                    ListTile(
                      dense: true,
                      title: Text(
                        '${f['from']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${fmtBytes(f['bytes'] as int?)} · removed ${fmtDateTime(f['at'] as int?)}',
                      ),
                    ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'History',
            subtitle: 'Undo one change, or a whole batch. A replacement is always undone as a whole.',
            child: history.isEmpty
                ? Text('No file changes yet.', style: TextStyle(color: t.faint))
                : Column(
                    children: [
                      for (final h in history)
                        ListTile(
                          dense: true,
                          title: Text(
                            '${opLabel('${h['op']}')}: ${h['from']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '→ ${h['to'] ?? ''} · ${h['status']}${h['error'] == null ? '' : ' (${h['error']})'} · ${fmtDateTime(h['at'] as int?)}',
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          ),
                          trailing: h['status'] == 'done'
                              ? Wrap(
                                  children: [
                                    TextButton(
                                      onPressed: () => guard(
                                        () => toast(
                                          'Undid ${plural(s.organize.undo(opId: h['id']! as int), 'change')}.',
                                        ),
                                        bump: ref,
                                      ),
                                      child: const Text('Undo'),
                                    ),
                                    TextButton(
                                      onPressed: () => guard(
                                        () => toast(
                                          'Undid ${plural(s.organize.undo(batch: h['batch']! as String), 'change')}.',
                                        ),
                                        bump: ref,
                                      ),
                                      child: const Text('Undo batch'),
                                    ),
                                  ],
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

  Future<void> _emptyRemoved(BuildContext context, AppSession s) async {
    final files = s.organize.removedFiles();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete ${plural(files.length, 'file')} for good?'),
        content: SizedBox(
          width: 640,
          height: 360,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'These files are deleted permanently and cannot be undone or restored afterwards. Only files inside the Removed files area are deleted; nothing in your music folders is touched.',
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (c, i) => Text(
                    '${files[i]['from']} (${fmtBytes(files[i]['bytes'] as int?)})',
                    style: const TextStyle(fontSize: DjType.small),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep them'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DjTokens.of(c).danger,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text('Delete ${plural(files.length, 'file')} for good'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await guard(
      () => toast('Deleted ${plural(s.organize.emptyRemoved(), 'file')}.'),
      bump: ref,
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.title, this.sub, required this.child});
  final String title;
  final String? sub;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.x4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        if (sub != null) HintText(sub!),
        const SizedBox(height: Space.x1),
        Align(alignment: Alignment.centerLeft, child: child),
      ],
    ),
  );
}

/// Duplicates: pick the copy to keep; the others' crates, tags and values move
/// to it, and their files go to Removed files (after a preview).
class _DuplicatesAction extends ConsumerStatefulWidget {
  const _DuplicatesAction();
  @override
  ConsumerState<_DuplicatesAction> createState() => _DuplicatesActionState();
}

class _DuplicatesActionState extends ConsumerState<_DuplicatesAction> {
  bool open = false;
  final keep = <String, int>{};

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    final t = DjTokens.of(context);
    final groups = open
        ? s.duplicates
              .findGroups(maxGroups: listRows(ref))
              .where((g) => g.kind == 'exact' && g.tracks.length > 1)
              .toList()
        : const <DupGroup>[];
    return _Action(
      title: 'Remove duplicates',
      sub: 'Exact copies (same file contents, found by Duplicates → Find exact copies). Choose the one to keep; the others leave your music folders for Removed files.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton(
            onPressed: () => setState(() => open = !open),
            child: Text(open ? 'Hide duplicates' : 'Show exact duplicates'),
          ),
          if (open && groups.isEmpty)
            Text(
              'No exact duplicates found yet. Run Duplicates → Find exact copies first.',
              style: TextStyle(color: t.faint),
            ),
          for (final g in groups)
            Card(
              margin: const EdgeInsets.only(top: Space.x2),
              child: Padding(
                padding: const EdgeInsets.all(Space.x3),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(g.reason, style: TextStyle(color: t.muted)),
                    RadioGroup<int>(
                      groupValue: keep[g.key] ?? g.tracks.first.id,
                      onChanged: (v) => setState(() => keep[g.key] = v!),
                      child: Column(
                        children: [
                          for (final r in g.tracks)
                            RadioListTile<int>(
                              dense: true,
                              value: r.id,
                              title: Text(
                                r.path,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 2,
                              ),
                              subtitle: Text(
                                [
                                  r.format ?? '',
                                  if (r.bitrateKbps != null)
                                    '${r.bitrateKbps} kbps',
                                  fmtBytes(r.fileSize),
                                ].where((x) => x.isNotEmpty).join(' · '),
                              ),
                            ),
                        ],
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: () async {
                          final k = keep[g.key] ?? g.tracks.first.id;
                          final others = [
                            for (final r in g.tracks)
                              if (r.id != k) r.id,
                          ];
                          final plan = await guard(
                            () => s.organize.previewReplace(k, others),
                          );
                          if (plan == null || !context.mounted) return;
                          await showOrganisePreview(
                            context,
                            ref,
                            plan,
                            title:
                                'Keep one copy, remove ${plural(others.length, 'other')}',
                          );
                        },
                        child: const Text('Preview…'),
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
          for (final r in upTo(results, listRows(ref)))
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
                      for (final d in upTo(
                        (rep['duplicates'] as List).cast<Map>(),
                        listRows(ref),
                      ))
                        Text(
                          (d['paths'] as List).join('\n'),
                          style: const TextStyle(fontSize: DjType.small),
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
                          style: const TextStyle(fontSize: DjType.small),
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
                                style: const TextStyle(fontSize: DjType.small),
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
