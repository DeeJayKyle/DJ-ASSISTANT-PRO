import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/library_edit.dart';
import '../core/paths.dart';
import '../core/serato_library.dart';
import 'format.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Crates → Serato crates: the crates saved in Serato DJ, detected from the
/// `_Serato_` folder, and changed in place: rename, move under another crate,
/// sort, merge, remove missing or single tracks, delete.
class SeratoCratesScreen extends ConsumerStatefulWidget {
  const SeratoCratesScreen({super.key});
  @override
  ConsumerState<SeratoCratesScreen> createState() => _SeratoCratesState();
}

class _SeratoCratesState extends ConsumerState<SeratoCratesScreen> {
  String? _dir;
  String? _open;
  final _collapsed = <String>{};

  SeratoLibrary? _lib() {
    final s = ref.read(sessionProvider);
    final dirs = s.seratoDirs;
    final d = _dir != null && dirs.contains(_dir) ? _dir : dirs.firstOrNull;
    return d == null ? null : s.seratoLibraryFor(d);
  }

  /// Runs a change to Serato's crates (refused while Serato is open, and
  /// backed up first).
  Future<void> _change(String done, void Function(SeratoLibrary lib) f) async {
    final lib = _lib();
    if (lib == null) return;
    await guard(() => f(lib), done: done, bump: ref);
    if (mounted) setState(() {});
  }

  Future<void> _chooseFolder() async {
    final d = await getDirectoryPath(confirmButtonText: 'Use this _Serato_ folder');
    if (d == null) return;
    final s = ref.read(sessionProvider);
    await guard(() => s.settings.set('serato_dir', d), bump: ref);
    setState(() {
      _dir = d;
      _open = null;
    });
  }

  Future<void> _rename(SeratoCrate c) async {
    final n = await askText(
      context,
      title: 'Rename crate',
      label: 'Name',
      initial: c.label,
      ok: 'Rename',
    );
    if (n == null || n.trim().isEmpty) return;
    final to = c.parent == null ? n.trim() : '${c.parent}%%${n.trim()}';
    await _change('Renamed to “${n.trim()}”.', (lib) => lib.rename(c.name, to));
    setState(() => _open = to);
  }

  Future<void> _move(SeratoCrate c, List<SeratoCrate> all) async {
    const top = '\u0000top';
    final pick = await showDialog<String>(
      context: context,
      builder: (d) => SimpleDialog(
        title: Text('Move “${c.label}” to…'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(d, top),
            child: const Text('Top level'),
          ),
          for (final x in all)
            if (x.name != c.name &&
                !x.name.startsWith('${c.name}%%') &&
                x.name != c.parent)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(d, x.name),
                child: Padding(
                  padding: EdgeInsets.only(left: 14.0 * x.depth),
                  child: Text(x.label),
                ),
              ),
        ],
      ),
    );
    if (pick == null) return;
    final parent = pick == top ? null : pick;
    await _change(
      'Moved “${c.label}”.',
      (lib) => lib.move(c.name, parent),
    );
    setState(
      () => _open = parent == null ? c.label : '$parent%%${c.label}',
    );
  }

  Future<void> _sort(SeratoCrate c) async {
    final pick = await showDialog<(String, bool)>(
      context: context,
      builder: (d) => SimpleDialog(
        title: Text('Sort “${c.label}” by…'),
        children: [
          for (final e in crateSorts.entries) ...[
            SimpleDialogOption(
              onPressed: () => Navigator.pop(d, (e.key, false)),
              child: Text(e.value),
            ),
            if (e.key == 'bpm' || e.key == 'energy' || e.key == 'year')
              SimpleDialogOption(
                onPressed: () => Navigator.pop(d, (e.key, true)),
                child: Text('${e.value} (high to low)'),
              ),
          ],
        ],
      ),
    );
    if (pick == null) return;
    final s = ref.read(sessionProvider);
    await _change(
      'Sorted by ${crateSorts[pick.$1]!.toLowerCase()}. Serato shows this order when the crate is sorted by #.',
      (lib) => lib.setTracks(
        c.name,
        sortCratePaths(s.cat, lib, c.paths, pick.$1, descending: pick.$2),
      ),
    );
  }

  Future<void> _merge(SeratoCrate c, List<SeratoCrate> all) async {
    final pick = await showDialog<String>(
      context: context,
      builder: (d) => SimpleDialog(
        title: Text('Merge “${c.label}” into…'),
        children: [
          for (final x in all)
            if (x.name != c.name)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(d, x.name),
                child: Padding(
                  padding: EdgeInsets.only(left: 14.0 * x.depth),
                  child: Text(x.label),
                ),
              ),
        ],
      ),
    );
    if (pick == null || !mounted) return;
    final remove = await confirm(
      context,
      title: 'Delete “${c.label}” after merging?',
      message:
          'Its tracks are added to “${pick.split('%%').last}” either way. Choose Delete to remove “${c.label}” afterwards, or Cancel to keep both.',
      ok: 'Delete',
    );
    await _change(
      'Merged into “${pick.split('%%').last}”.',
      (lib) => lib.merge([c.name], pick, removeSources: remove),
    );
    setState(() => _open = pick);
  }

  Future<void> _delete(SeratoCrate c, int subs) async {
    final ok = await confirm(
      context,
      title: 'Delete “${c.label}” from Serato?',
      message:
          'The crate file${subs > 0 ? ' and its $subs sub-crate(s)' : ''} '
          'are deleted from your _Serato_ folder. Your music files are not touched.',
      ok: 'Delete',
      danger: true,
    );
    if (!ok) return;
    await _change('Deleted “${c.label}”.', (lib) => lib.delete(c.name));
    setState(() => _open = null);
  }

  Future<void> _deleteAll(int n) async {
    final ok = await confirm(
      context,
      title: 'Delete all $n Serato crates?',
      message:
          'Every crate in this _Serato_ folder is deleted. Your music files and Serato\'s library stay.',
      ok: 'Delete all',
      danger: true,
    );
    if (!ok) return;
    await _change('Deleted every Serato crate.', (lib) => lib.deleteAll());
    setState(() => _open = null);
  }

  Future<void> _newCrate() async {
    final n = await askText(
      context,
      title: 'New Serato crate',
      label: 'Name (use %% to place it under another crate)',
      ok: 'Create',
    );
    if (n == null || n.trim().isEmpty) return;
    await _change('Created “${n.trim()}”.', (lib) => lib.save(n.trim(), []));
  }

  Future<void> _import(SeratoLibrary lib) async {
    final s = ref.read(sessionProvider);
    await guard(
      () => s.serato.importCrates(lib.dir),
      done: 'Copied into the Crate builder, where rules and templates can reshape them.',
      bump: ref,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final dirs = s.seratoDirs;
    final lib = _lib();
    if (lib == null) {
      return PageFrame(
        title: 'Serato crates',
        child: Panel(
          child: EmptyState(
            icon: Icons.album_outlined,
            title: 'No _Serato_ folder found',
            message:
                'Serato keeps its crates in a _Serato_ folder in your Music folder or at the top of an external drive.',
            action: FilledButton.icon(
              onPressed: _chooseFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Choose the _Serato_ folder…'),
            ),
          ),
        ),
      );
    }
    List<SeratoCrate> all;
    String? error;
    try {
      all = lib.crates();
    } on Object catch (e) {
      all = const [];
      error = '$e';
    }
    final open = all.where((c) => c.name == _open).firstOrNull;
    bool hidden(SeratoCrate c) {
      for (var i = 1; i < c.parts.length; i++) {
        if (_collapsed.contains(c.parts.sublist(0, i).join('%%'))) return true;
      }
      return false;
    }

    final header = Panel(
      child: Wrap(
        spacing: Space.x3,
        runSpacing: Space.x2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (dirs.length > 1)
            SizedBox(
              width: 320,
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: lib.dir,
                decoration: const InputDecoration(labelText: '_Serato_ folder'),
                items: [
                  for (final d in dirs)
                    DropdownMenuItem(value: d, child: Text(d)),
                ],
                onChanged: (v) => setState(() {
                  _dir = v;
                  _open = null;
                }),
              ),
            )
          else
            Text(lib.dir, style: TextStyle(color: t.muted)),
          TextButton.icon(
            onPressed: _chooseFolder,
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('Other folder…'),
          ),
          FilledButton.icon(
            onPressed: _newCrate,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('New crate'),
          ),
          OutlinedButton.icon(
            onPressed: () => setState(() {}),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Detect again'),
          ),
          OutlinedButton.icon(
            onPressed: all.isEmpty ? null : () => _import(lib),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: const Text('Copy into Crate builder'),
          ),
          TextButton.icon(
            onPressed: all.isEmpty ? null : () => _deleteAll(all.length),
            icon: Icon(Icons.delete_sweep_outlined, size: 18, color: t.danger),
            label: Text('Delete all', style: TextStyle(color: t.danger)),
          ),
        ],
      ),
    );

    final list = Panel(
      title: plural(all.length, 'crate'),
      child: all.isEmpty
          ? HintText(error ?? 'Serato has no crates here yet.')
          : Column(
              children: [
                for (final c in all)
                  if (!hidden(c))
                    ListTile(
                      dense: true,
                      selected: c.name == _open,
                      contentPadding: EdgeInsets.only(left: 14.0 * c.depth),
                      leading: all.any((x) => x.parent == c.name)
                          ? IconButton(
                              visualDensity: VisualDensity.compact,
                              iconSize: 18,
                              onPressed: () => setState(
                                () => _collapsed.contains(c.name)
                                    ? _collapsed.remove(c.name)
                                    : _collapsed.add(c.name),
                              ),
                              icon: Icon(
                                _collapsed.contains(c.name)
                                    ? Icons.chevron_right
                                    : Icons.expand_more,
                              ),
                            )
                          : const Icon(Icons.album_outlined, size: 18),
                      title: Text(c.label, overflow: TextOverflow.ellipsis),
                      trailing: Text(
                        '${c.paths.length}',
                        style: TextStyle(color: t.faint, fontSize: DjType.small),
                      ),
                      onTap: () => setState(() => _open = c.name),
                    ),
              ],
            ),
    );

    final detail = open == null
        ? const Panel(child: HintText('Choose a crate to see and change it.'))
        : _CrateDetail(
            crate: open,
            lib: lib,
            subs: all.where((x) => x.name.startsWith('${open.name}%%')).length,
            onRename: () => _rename(open),
            onMove: () => _move(open, all),
            onSort: () => _sort(open),
            onMerge: () => _merge(open, all),
            onDelete: () => _delete(
              open,
              all.where((x) => x.name.startsWith('${open.name}%%')).length,
            ),
            onRemoveMissing: () => _change(
              'Removed missing tracks.',
              (l) => l.removeMissing(open.name),
            ),
            onRemoveTrack: (x) => _change(
              'Removed from “${open.label}”. The file is untouched.',
              (l) => l.setTracks(open.name, [
                for (final y in open.paths)
                  if (y != x) y,
              ]),
            ),
          );

    return PageFrame(
      title: 'Serato crates',
      subtitle:
          'The crates saved in Serato DJ. Changes are made in your _Serato_ '
          'folder directly, so close Serato first.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          const SizedBox(height: Space.x3),
          LayoutBuilder(
            builder: (context, box) => box.maxWidth < 760
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [list, const SizedBox(height: Space.x3), detail],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 300, child: list),
                      const SizedBox(width: Space.x3),
                      Expanded(child: detail),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _CrateDetail extends ConsumerWidget {
  const _CrateDetail({
    required this.crate,
    required this.lib,
    required this.subs,
    required this.onRename,
    required this.onMove,
    required this.onSort,
    required this.onMerge,
    required this.onDelete,
    required this.onRemoveMissing,
    required this.onRemoveTrack,
  });
  final SeratoCrate crate;
  final SeratoLibrary lib;
  final int subs;
  final VoidCallback onRename, onMove, onSort, onMerge, onDelete;
  final VoidCallback onRemoveMissing;
  final ValueChanged<String> onRemoveTrack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final t = DjTokens.of(context);
    final notation = '${ref.watch(settingsProvider)['key_notation']}';
    final missing = <String>{
      for (final x in crate.paths)
        if (!File(lib.absolute(x)).existsSync()) x,
    };
    final rows = [
      for (final x in crate.paths)
        (x, () {
          final r = s.cat.db.select('SELECT id FROM tracks WHERE path_key=?', [
            pathKey(lib.absolute(x)),
          ]);
          return r.isEmpty ? null : s.library.row(r.first['id'] as int);
        }()),
    ];
    return Panel(
      title: crate.parts.join(' › '),
      subtitle:
          '${plural(crate.paths.length, 'track')}'
          '${subs > 0 ? ' · ${plural(subs, 'sub-crate')}' : ''}'
          '${missing.isEmpty ? '' : ' · ${missing.length} missing'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Space.x2,
            runSpacing: Space.x2,
            children: [
              OutlinedButton.icon(
                onPressed: onRename,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Rename'),
              ),
              OutlinedButton.icon(
                onPressed: onMove,
                icon: const Icon(Icons.drive_file_move_outline, size: 18),
                label: const Text('Move'),
              ),
              OutlinedButton.icon(
                onPressed: crate.paths.length < 2 ? null : onSort,
                icon: const Icon(Icons.sort, size: 18),
                label: const Text('Sort'),
              ),
              OutlinedButton.icon(
                onPressed: onMerge,
                icon: const Icon(Icons.merge_type, size: 18),
                label: const Text('Merge'),
              ),
              if (missing.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: onRemoveMissing,
                  icon: const Icon(Icons.link_off, size: 18),
                  label: Text('Remove ${missing.length} missing'),
                ),
              TextButton.icon(
                onPressed: onDelete,
                icon: Icon(Icons.delete_outline, size: 18, color: t.danger),
                label: Text('Delete', style: TextStyle(color: t.danger)),
              ),
            ],
          ),
          const SizedBox(height: Space.x3),
          if (rows.isEmpty)
            const HintText('No tracks in this crate.')
          else
            for (final (x, r) in rows)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  missing.contains(x)
                      ? Icons.error_outline
                      : Icons.music_note_outlined,
                  size: 18,
                  color: missing.contains(x) ? t.warn : t.faint,
                ),
                title: Text(
                  r == null
                      ? p.basenameWithoutExtension(x)
                      : '${r.artist ?? unknown} - ${r.title ?? p.basenameWithoutExtension(x)}',
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  missing.contains(x)
                      ? 'File not found: $x'
                      : r == null
                      ? 'Not in your DJ Assistant library yet'
                      : [
                          if (r.bpm != null) '${fmtBpm(r.bpm)} BPM',
                          if (r.key != null) fmtKey(r.key, notation),
                          ?r.genre,
                          if (r.year != null) '${r.year}',
                        ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  tooltip: 'Remove from this crate',
                  iconSize: 18,
                  onPressed: () => onRemoveTrack(x),
                  icon: const Icon(Icons.close),
                ),
              ),
        ],
      ),
    );
  }
}
