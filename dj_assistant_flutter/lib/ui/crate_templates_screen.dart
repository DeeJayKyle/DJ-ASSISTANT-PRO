import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crate_tree.dart';
import 'format.dart';
import 'rules_ui.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Serato Crates → Templates: the auto-reorganizer. Pick levels (Genre →
/// Decade → Energy…), see the tree with its track counts, then write it to
/// Serato in one go, every crate sorted harmonically.
class CrateTemplatesScreen extends ConsumerStatefulWidget {
  const CrateTemplatesScreen({super.key});
  @override
  ConsumerState<CrateTemplatesScreen> createState() =>
      _CrateTemplatesScreenState();
}

class _CrateTemplatesScreenState extends ConsumerState<CrateTemplatesScreen> {
  final _root = TextEditingController(text: 'Auto crates');
  var _levels = <TreeLevel>[...treePresets.values.first];
  Map<String, Object?>? _rules;
  var _includeUnknown = true;
  var _replace = true;
  final _open = <String>{};

  @override
  void dispose() {
    _root.dispose();
    super.dispose();
  }

  CrateTreePlan get _plan => CrateTreePlan(
    root: _root.text,
    levels: _levels,
    rules: _rules,
    includeUnknown: _includeUnknown,
  );

  void _load(CrateTreePlan p) => setState(() {
    _root.text = p.root;
    _levels = [...p.levels];
    _rules = p.rules;
    _includeUnknown = p.includeUnknown;
    _open.clear();
  });

  Future<void> _write(List<TreeCrate> tree) async {
    final s = ref.read(sessionProvider);
    final lib = s.seratoLibrary;
    if (lib == null) {
      toast('No _Serato_ folder found. Choose it under Settings.', error: true);
      return;
    }
    if (!await confirm(
      context,
      title: 'Write ${plural(tree.length, 'crate')} to Serato?',
      message:
          '“${tree.first.name}” and the crates under it are written into '
          '${lib.dir}.${_replace ? ' Crates already under it that this template no longer makes are deleted.' : ''} '
          'Serato DJ must be closed. A backup is made first.',
      ok: 'Write to Serato',
    )) {
      return;
    }
    await guard(() {
      final (n, other, removed) = writeCrateTree(lib, tree, replace: _replace);
      toast(
        'Wrote ${plural(n, 'crate')} to Serato'
        '${removed > 0 ? ', removed $removed old one(s)' : ''}'
        '${other > 0 ? '; $other track(s) on another drive left out' : ''}.',
      );
    }, bump: ref);
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final text = Theme.of(context).textTheme;
    final saved = savedTreeTemplates(s.cat);

    List<TreeCrate> tree = const [];
    String? problem;
    try {
      tree = buildCrateTree(s.cat, _plan);
    } on CrateTreeException catch (e) {
      problem = e.message;
    } on Object catch (e) {
      problem = '$e';
    }

    Widget levelRow(int i) {
      final l = _levels[i];
      final ranged = l.field == 'energy' || l.field == 'bpm';
      return Padding(
        padding: const EdgeInsets.only(bottom: Space.x2),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '${i + 1}',
                style: TextStyle(color: t.faint, fontSize: DjType.small),
              ),
            ),
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: l.field,
                key: ValueKey('level$i${l.field}'),
                decoration: const InputDecoration(isDense: true),
                items: [
                  for (final e in treeFields.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) =>
                    setState(() => _levels[i] = TreeLevel(v ?? l.field)),
              ),
            ),
            if (ranged) ...[
              const SizedBox(width: Space.x2),
              SizedBox(
                width: 92,
                child: DropdownButtonFormField<int>(
                  initialValue: l.step ?? (l.field == 'bpm' ? 5 : 2),
                  key: ValueKey('step$i${l.field}'),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Range',
                  ),
                  items: [
                    for (final n
                        in l.field == 'bpm'
                            ? const [2, 4, 5, 10, 20]
                            : const [1, 2, 3, 5])
                      DropdownMenuItem(value: n, child: Text('$n')),
                  ],
                  onChanged: (v) =>
                      setState(() => _levels[i] = TreeLevel(l.field, step: v)),
                ),
              ),
            ],
            IconButton(
              tooltip: 'Remove this level',
              onPressed: _levels.length < 2
                  ? null
                  : () => setState(() => _levels.removeAt(i)),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      );
    }

    final builder = Panel(
      title: 'Template',
      subtitle:
          'Each level splits the crate above it. Tracks are sorted by '
          'Camelot key round the wheel, then BPM.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _root,
            decoration: const InputDecoration(labelText: 'Top crate in Serato'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.x3),
          Wrap(
            spacing: Space.x2,
            runSpacing: Space.x2,
            children: [
              for (final e in treePresets.entries)
                ActionChip(
                  label: Text(e.key),
                  onPressed: () => setState(() => _levels = [...e.value]),
                ),
            ],
          ),
          const SizedBox(height: Space.x3),
          for (var i = 0; i < _levels.length; i++) levelRow(i),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _levels.length >= 5
                  ? null
                  : () => setState(() => _levels.add(const TreeLevel('key'))),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add a level'),
            ),
          ),
          const Divider(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.filter_alt_outlined),
            title: Text(
              _rules == null
                  ? 'Every track'
                  : 'Only tracks matching your rules',
            ),
            subtitle: const Text(
              'Genre, energy, BPM, year, mood, event, key, label… with AND / OR groups.',
            ),
            trailing: Wrap(
              children: [
                if (_rules != null)
                  TextButton(
                    onPressed: () => setState(() => _rules = null),
                    child: const Text('Clear'),
                  ),
                TextButton(
                  onPressed: () async {
                    final r = await editRules(
                      context,
                      _rules,
                      title: 'Which tracks go in',
                    );
                    if (r != null) setState(() => _rules = r);
                  },
                  child: Text(_rules == null ? 'Add rules…' : 'Edit rules…'),
                ),
              ],
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _includeUnknown,
            onChanged: (v) => setState(() => _includeUnknown = v),
            title: const Text('Crates for missing values'),
            subtitle: const Text(
              'On: tracks with no genre (or year, energy…) go into "No genre". '
              'Off: they are left out.',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _replace,
            onChanged: (v) => setState(() => _replace = v),
            title: const Text('Replace the old tree'),
            subtitle: const Text(
              'On: crates under the top crate that this template no longer '
              'makes are deleted. Off: they stay.',
            ),
          ),
          const SizedBox(height: Space.x2),
          Wrap(
            spacing: Space.x2,
            runSpacing: Space.x2,
            children: [
              FilledButton.icon(
                onPressed: tree.isEmpty ? null : () => _write(tree),
                icon: const Icon(Icons.publish_outlined),
                label: const Text('Write to Serato'),
              ),
              OutlinedButton.icon(
                onPressed: problem != null
                    ? null
                    : () => guard(
                        () => saveTreeTemplate(s.cat, _plan),
                        done: 'Template saved.',
                        bump: ref,
                      ),
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Save template'),
              ),
            ],
          ),
          if (saved.isNotEmpty) ...[
            const SizedBox(height: Space.x3),
            Text('Saved', style: text.labelSmall),
            const SizedBox(height: Space.x1),
            Wrap(
              spacing: Space.x2,
              runSpacing: Space.x2,
              children: [
                for (final e in saved.entries)
                  InputChip(
                    label: Text(e.key),
                    onPressed: () => _load(e.value),
                    onDeleted: () => guard(
                      () => deleteTreeTemplate(s.cat, e.key),
                      bump: ref,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );

    // the preview: collapsed below the second level until opened
    final visible = <TreeCrate>[
      for (final c in tree)
        if (c.depth <= 1 ||
            _open.contains(c.name.substring(0, c.name.lastIndexOf('%%'))))
          c,
    ];
    final preview = Panel(
      title: 'Preview',
      subtitle:
          problem ??
          (tree.isEmpty
              ? 'No tracks match.'
              : '${plural(tree.length, 'crate')}, '
                    '${plural(tree.first.paths.length, 'track')}. Nothing is written until you press Write to Serato.'),
      child: Column(
        children: [
          for (final c in visible)
            InkWell(
              onTap: () => setState(
                () => _open.contains(c.name)
                    ? _open.removeWhere(
                        (x) => x == c.name || x.startsWith('${c.name}%%'),
                      )
                    : _open.add(c.name),
              ),
              child: Padding(
                padding: EdgeInsets.only(
                  left: c.depth * 18.0,
                  top: 6,
                  bottom: 6,
                ),
                child: Row(
                  children: [
                    Icon(
                      tree.any((x) => x.name.startsWith('${c.name}%%'))
                          ? (_open.contains(c.name) || c.depth == 0
                                ? Icons.folder_open_outlined
                                : Icons.folder_outlined)
                          : Icons.album_outlined,
                      size: 18,
                      color: c.depth == 0 ? t.accent : t.muted,
                    ),
                    const SizedBox(width: Space.x2),
                    Expanded(
                      child: Text(c.label, overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      fmtNumber(c.paths.length),
                      style: TextStyle(color: t.faint, fontSize: DjType.small),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );

    return PageFrame(
      title: 'Crate templates',
      subtitle:
          'Sort the whole library into nested Serato crates by genre, decade, '
          'energy, BPM, key, mood, event or label.',
      child: LayoutBuilder(
        builder: (context, c) => c.maxWidth < 900
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  builder,
                  const SizedBox(height: Space.x3),
                  preview,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: builder),
                  const SizedBox(width: Space.x3),
                  Expanded(flex: 4, child: preview),
                ],
              ),
      ),
    );
  }
}
