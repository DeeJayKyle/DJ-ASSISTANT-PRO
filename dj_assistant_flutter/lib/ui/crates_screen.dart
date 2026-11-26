import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/crates.dart' hide crateColors;
import '../core/serato_library.dart';
import '../core/templates.dart' show crateTemplates;
import 'format.dart';
import 'rules_ui.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

class CratesScreen extends ConsumerStatefulWidget {
  const CratesScreen({super.key});
  @override
  ConsumerState<CratesScreen> createState() => _CratesScreenState();
}

class _CratesScreenState extends ConsumerState<CratesScreen> {
  final genre = TextEditingController(text: 'Afrobeats');

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final crates = ref.watch(cratesProvider);
    final labels = s.templates.labels();
    final hyg = s.templates.hygiene();
    final issues = (hyg['issues'] as List?)?.cast<Map>() ?? const [];
    final untagged = hyg['untagged_unrated'] as int? ?? 0;
    final top = crates.where((c) => c.parentId == null).toList();
    return PageFrame(
      title: 'Virtual Crates',
      subtitle: 'Build crates by hand, by rules or from templates, then save them into Serato. Files are never copied or moved.',
      actions: [
        OutlinedButton.icon(
          onPressed: () => guard(() {
            final n = s.templates.colourByEnergy();
            toast('Coloured ${plural(n, 'track')} by energy.');
          }, bump: ref),
          icon: const Icon(Icons.palette_outlined, size: 18),
          label: const Text('Colour tracks by energy'),
        ),
        OutlinedButton.icon(
          onPressed: () => showExportCrates(context, ref),
          icon: const Icon(Icons.album_outlined, size: 18),
          label: const Text('Save to Serato…'),
        ),
        FilledButton.icon(
          onPressed: () => showCrateDialog(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('New crate'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (issues.isNotEmpty || untagged > 0) ...[
            Card(
              color: t.warn.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Avoid this: unorganised crates mean missed moments.',
                      style: TextStyle(
                        color: t.warn,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    for (final i in issues)
                      Text('“${i['crate']}” — ${i['issue']}. ${i['advice']}'),
                    if (untagged > 0)
                      Text(
                        '${plural(untagged, 'track')} have no tags or rating yet.',
                      ),
                  ],
                ),
              ),
            ),
            gap,
          ],
          Text(
            'Start from a template',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 10),
          AutoGrid(
            minWidth: 300,
            children: [
              for (final tp in crateTemplates())
                SizedBox(
                  width: 300,
                  child: Panel(
                    title: tp.name,
                    subtitle: tp.description,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final c in tp.crates.take(10))
                          Text(
                            '• $c',
                            style: TextStyle(
                              color: t.muted,
                              fontSize: DjType.small,
                            ),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (tp.needsGenre)
                              Expanded(
                                child: TextField(
                                  controller: genre,
                                  decoration: const InputDecoration(
                                    labelText: 'Genre',
                                  ),
                                ),
                              ),
                            if (tp.needsGenre) const SizedBox(width: 8),
                            FilledButton.tonal(
                              onPressed: () => guard(() {
                                final r = s.templates.apply(
                                  tp.id,
                                  genre: tp.needsGenre ? genre.text : null,
                                );
                                toast(
                                  (r['created'] as int) > 0
                                      ? 'Added ${plural(r['created']! as int, 'crate')} under “${r['parent']}”.'
                                      : '“${r['parent']}” already has these crates.',
                                );
                              }, bump: ref),
                              child: const Text('Add crates'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          gap,
          Wrap(
            spacing: 16,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [
              SizedBox(
                width: 520,
                child: Panel(
                  title: 'Your crates',
                  child: top.isEmpty
                      ? Text('No crates yet.', style: TextStyle(color: t.faint))
                      : Column(
                          children: [
                            for (final c in top)
                              ListTile(
                                dense: true,
                                leading: ColorDot(c.color),
                                title: Text(
                                  c.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: c.smart ? const Text('smart') : null,
                                trailing: Text(() {
                                  final kids = crates
                                      .where((k) => k.parentId == c.id)
                                      .length;
                                  return kids > 0
                                      ? plural(kids, 'sub-crate')
                                      : plural(c.trackCount, 'track');
                                }()),
                                onTap: () => ref
                                    .read(viewProvider.notifier)
                                    .go('crate', crateId: c.id),
                              ),
                          ],
                        ),
                ),
              ),
              SizedBox(width: 460, child: _labels(context, labels)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _labels(BuildContext context, Map<String, Object?> labels) {
    final t = DjTokens.of(context);
    final energy = (labels['energy'] as List?)?.cast<Map>() ?? const [];
    final rating = (labels['rating'] as Map?) ?? const {};
    final hint = (labels['rating_hint'] as Map?) ?? const {};
    final color = (labels['color'] as Map?) ?? const {};
    return Panel(
      title: 'Labels from the cheat sheet',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in energy)
            Text('${e['min']}–${e['max']}  ${e['label']} — ${e['hint']}'),
          const SizedBox(height: 10),
          for (final k
              in (rating.keys.toList()..sort((a, b) => '$b'.compareTo('$a'))))
            Text(
              '${'★' * int.parse('$k')}${'☆' * (5 - int.parse('$k'))}  ${rating[k]} — ${hint[k] ?? ''}',
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              for (final e in color.entries)
                if (e.value != null && '${e.value}'.isNotEmpty)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ColorDot('${e.key}'),
                      const SizedBox(width: 4),
                      Text('${e.value}'),
                    ],
                  ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Rename these in Settings → Labels.',
            style: TextStyle(color: t.faint, fontSize: DjType.small),
          ),
        ],
      ),
    );
  }
}

/// New or edit crate (1.x CrateDialog).
Future<void> showCrateDialog(
  BuildContext context,
  WidgetRef ref, {
  Crate? crate,
  Node? rules,
}) => showDialog<void>(
  context: context,
  builder: (_) => _CrateDialog(ref: ref, crate: crate, rules: rules),
);

class _CrateDialog extends StatefulWidget {
  const _CrateDialog({required this.ref, this.crate, this.rules});
  final WidgetRef ref;
  final Crate? crate;
  final Node? rules;
  @override
  State<_CrateDialog> createState() => _CrateDialogState();
}

class _CrateDialogState extends State<_CrateDialog> {
  late final name = TextEditingController(text: widget.crate?.name ?? '');
  late final category = TextEditingController(
    text: widget.crate?.category ?? '',
  );
  late String kind =
      widget.crate?.kind ?? (widget.rules != null ? 'smart' : 'manual');
  late String? color = widget.crate?.color;
  late int? parent = widget.crate?.parentId;
  late Node rules = widget.crate?.rules ?? widget.rules ?? emptyRuleSet();
  String? error;
  bool confirmDelete = false;

  CratesService get svc => widget.ref.read(sessionProvider).crates;

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final crates = widget.ref.read(cratesProvider);
    final clean = cleanRuleSet(rules);
    int? total;
    if (kind == 'smart' &&
        clean != null &&
        (clean['rules'] as List).isNotEmpty) {
      try {
        total = svc.previewRules(clean, limit: 1).total;
      } on Object catch (e) {
        error = '$e';
      }
    }
    final canSave =
        name.text.trim().isNotEmpty &&
        (kind != 'smart' ||
            (clean != null && (clean['rules'] as List).isNotEmpty));
    return AlertDialog(
      title: Text(widget.crate == null ? 'New crate' : 'Edit crate'),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 300,
                    child: TextField(
                      controller: name,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        hintText: 'e.g. Afrobeats 2010s peak time',
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: DropdownButtonFormField<int?>(
                      isExpanded: true,
                      style: Theme.of(context).textTheme.bodyMedium,
                      initialValue: parent,
                      decoration: const InputDecoration(
                        labelText: 'Inside folder (optional)',
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('Top level'),
                        ),
                        for (final c in crates.where(
                          (c) => c.id != widget.crate?.id,
                        ))
                          DropdownMenuItem(value: c.id, child: Text(c.name)),
                      ],
                      onChanged: (v) => parent = v,
                    ),
                  ),
                  SizedBox(
                    width: 180,
                    child: TextField(
                      controller: category,
                      decoration: const InputDecoration(
                        labelText: 'Category (optional)',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (widget.crate == null)
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'manual',
                      label: Text('Manual — you add tracks'),
                    ),
                    ButtonSegment(
                      value: 'smart',
                      label: Text('Smart — rules pick tracks'),
                    ),
                    ButtonSegment(value: 'folder', label: Text('Folder')),
                  ],
                  selected: {kind},
                  onSelectionChanged: (v) => setState(() => kind = v.first),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Text('Colour', style: TextStyle(color: t.faint)),
                  const SizedBox(width: 8),
                  for (final c in [null, ...crateColors.keys])
                    InkWell(
                      onTap: () => setState(() => color = c),
                      child: Container(
                        margin: const EdgeInsets.all(3),
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == c ? t.accent : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: ColorDot(c, size: 16),
                      ),
                    ),
                ],
              ),
              if (kind == 'smart') ...[
                const SizedBox(height: 12),
                RuleBuilder(
                  initial: rules,
                  onChanged: (v) => setState(() => rules = v),
                ),
                if (total != null)
                  Text(
                    '${plural(total, 'track')} match now. The crate updates itself as your library changes.',
                    style: TextStyle(color: t.accent),
                  ),
              ],
              if (error != null)
                Text(error!, style: TextStyle(color: t.danger)),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.crate != null)
          confirmDelete
              ? FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: t.danger),
                  onPressed: () {
                    final ok = guard(
                      () => svc.delete(widget.crate!.id),
                      done: 'Crate deleted. Tracks and files stay.',
                      bump: widget.ref,
                    );
                    widget.ref.read(viewProvider.notifier).go('crates');
                    ok.then((_) {
                      if (context.mounted) Navigator.pop(context);
                    });
                  },
                  child: const Text('Yes, delete crate'),
                )
              : TextButton(
                  onPressed: () => setState(() => confirmDelete = true),
                  child: Text(
                    'Delete crate',
                    style: TextStyle(color: t.danger),
                  ),
                ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: !canSave
              ? null
              : () {
                  final input = CrateInput(
                    name: name.text,
                    kind: kind,
                    color: color,
                    category: category.text.trim().isEmpty
                        ? null
                        : category.text.trim(),
                    parentId: parent,
                    rules: kind == 'smart' ? clean : null,
                  );
                  try {
                    final c = widget.crate == null
                        ? svc.create(input)
                        : svc.update(widget.crate!.id, input);
                    widget.ref.read(versionProvider.notifier).bump();
                    widget.ref
                        .read(viewProvider.notifier)
                        .go('crate', crateId: c.id);
                    Navigator.pop(context);
                  } on Object catch (e) {
                    setState(() => error = '$e');
                  }
                },
          child: Text(widget.crate == null ? 'Create crate' : 'Save changes'),
        ),
      ],
    );
  }
}

/// Saves crates into Serato (replacing Serato crates of the same name).
Future<void> showExportCrates(BuildContext context, WidgetRef ref) async {
  final s = ref.read(sessionProvider);
  final crates = ref
      .read(cratesProvider)
      .where((c) => c.kind != 'folder')
      .toList();
  final picked = {for (final c in crates) c.id};
  final lib = s.seratoLibrary;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: const Text('Save crates to Serato'),
        content: SizedBox(
          width: 520,
          child: ListView(
            shrinkWrap: true,
            children: [
              HintText(
                lib == null
                    ? 'No _Serato_ folder was found. Choose one on Crates → Serato crates.'
                    : 'Each crate is saved into ${lib.dir}. A Serato crate with the same name is replaced. Close Serato first.',
              ),
              const SizedBox(height: 8),
              for (final cr in crates)
                CheckboxListTile(
                  dense: true,
                  value: picked.contains(cr.id),
                  title: Text(cr.name),
                  subtitle: Text(plural(cr.trackCount, 'track')),
                  onChanged: (v) =>
                      set(() => v! ? picked.add(cr.id) : picked.remove(cr.id)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: lib == null || picked.isEmpty
                ? null
                : () async {
                    if (await SeratoLibrary.running()) {
                      toast('Close Serato DJ first.', error: true);
                      return;
                    }
                    final r = await guard(
                      () => s.djExport.saveToSerato(
                        lib,
                        crateIds: picked.toList(),
                      ),
                    );
                    if (r != null) {
                      toast(
                        'Saved ${(r['written'] as List).length} crate(s) to Serato. ${r['note']}',
                      );
                      if (c.mounted) Navigator.pop(c);
                    }
                  },
            child: const Text('Save to Serato'),
          ),
        ],
      ),
    ),
  );
}
