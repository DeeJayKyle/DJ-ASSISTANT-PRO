import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/organize.dart';
import '../core/tags.dart' show supportedExtensions;
import 'format.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// What each kind of change is called in a preview.
String opLabel(String op) => switch (op) {
  'rename' => 'Rename',
  'move' => 'Move',
  'folder_rename' => 'Rename folder',
  'remove' => 'Move to Removed files',
  'replace' => 'Replace with a better file',
  _ => op,
};

/// Shows every change in [plan], each with a tick, and applies only the ones
/// the DJ approves after a second confirmation. Serato's references are read
/// (never written) first, so each item says what it would mean in Serato.
/// Returns the result, or null when nothing was applied.
Future<OrganizeResult?> showOrganisePreview(
  BuildContext context,
  WidgetRef ref,
  OrganizePlan plan, {
  required String title,
}) async {
  final s = ref.read(sessionProvider);
  try {
    s.organize.checkSerato(plan);
  } on Object {
    // Serato's files couldn't be read: the general warning still shows.
  }
  return showDialog<OrganizeResult>(
    context: context,
    builder: (c) => OrganisePreviewDialog(plan: plan, title: title, ref: ref),
  );
}

class OrganisePreviewDialog extends StatefulWidget {
  const OrganisePreviewDialog({
    super.key,
    required this.plan,
    required this.title,
    required this.ref,
  });
  final OrganizePlan plan;
  final String title;
  final WidgetRef ref;
  @override
  State<OrganisePreviewDialog> createState() => _OrganisePreviewDialogState();
}

class _OrganisePreviewDialogState extends State<OrganisePreviewDialog> {
  late final Set<int> chosen = {
    for (var i = 0; i < widget.plan.ops.length; i++)
      if (widget.plan.ops[i].blocked == null) i,
  };
  bool busy = false;

  List<FileOp> get ops => widget.plan.ops;

  Future<void> _apply() async {
    final n = chosen.length;
    final serato = chosen.where((i) => ops[i].serato != null).length;
    final ok = await confirm(
      context,
      title: 'Make ${plural(n, 'change')} to your music files?',
      message: [
        'Only the ${plural(n, 'ticked item')} will change. Each file is checked again first and skipped if it changed since this preview.',
        if (serato > 0)
          '${plural(serato, 'item')} ${serato == 1 ? 'affects' : 'affect'} tracks Serato knows about (see the notes in the list).',
        'Removed and replaced files go to the Removed files area, not the bin, and nothing is permanently deleted. Undo any change from Organise Files → History.',
      ].join('\n\n'),
      ok: 'Make ${plural(n, 'change')}',
    );
    if (!ok || !mounted) return;
    setState(() => busy = true);
    final r = await guard(
      () => widget.ref
          .read(sessionProvider)
          .organize
          .apply(widget.plan, only: chosen),
      bump: widget.ref,
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r == null) return;
    toast(
      '${plural(r.done, 'change')} made'
      '${r.skipped.isEmpty ? '' : ', ${r.skipped.length} skipped (${r.skipped.first.$2})'}. Undo from Organise Files → History.',
      error: r.done == 0 && r.skipped.isNotEmpty,
    );
    Navigator.pop(context, r);
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final size = MediaQuery.sizeOf(context);
    final ready = widget.plan.ready;
    final allChosen = chosen.length == ready && ready > 0;
    final serato = ops.where((o) => o.serato != null).length;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: (size.width - 64).clamp(320, 980).toDouble(),
        height: (size.height * 0.72).clamp(260, 900).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${plural(ops.length, 'item')}: ${fmtNumber(ready)} ready, ${fmtNumber(widget.plan.blocked)} blocked'
              '${serato == 0 ? '' : ' · ${plural(serato, 'item')} with Serato notes'}.',
              style: TextStyle(color: t.muted),
            ),
            if (widget.plan.warning != null) ...[
              const SizedBox(height: Space.x2),
              HintText(widget.plan.warning!, icon: Icons.info_outline),
            ],
            const SizedBox(height: Space.x2),
            Row(
              children: [
                Checkbox(
                  tristate: true,
                  semanticLabel: 'Select every ready item',
                  value: allChosen ? true : (chosen.isEmpty ? false : null),
                  onChanged: ready == 0
                      ? null
                      : (_) => setState(() {
                          if (allChosen) {
                            chosen.clear();
                          } else {
                            for (var i = 0; i < ops.length; i++) {
                              if (ops[i].blocked == null) chosen.add(i);
                            }
                          }
                        }),
                ),
                Expanded(
                  child: Text(
                    '${fmtNumber(chosen.length)} of ${fmtNumber(ready)} ticked',
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: ops.isEmpty
                  ? Center(
                      child: Text(
                        'Nothing to change — everything already matches.',
                        style: TextStyle(color: t.faint),
                      ),
                    )
                  : ListView.builder(
                      itemCount: ops.length,
                      itemBuilder: (c, i) => _row(t, i, ops[i]),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy || chosen.isEmpty ? null : _apply,
          child: Text('Apply ${fmtNumber(chosen.length)} ticked…'),
        ),
      ],
    );
  }

  Widget _row(DjTokens t, int i, FileOp o) {
    final blocked = o.blocked != null;
    final small = TextStyle(fontSize: DjType.small, color: t.faint);
    return CheckboxListTile(
      dense: true,
      controlAffinity: ListTileControlAffinity.leading,
      value: chosen.contains(i),
      onChanged: blocked
          ? null
          : (v) => setState(() => v == true ? chosen.add(i) : chosen.remove(i)),
      title: Text(
        '${opLabel(o.op)}${o.op == 'folder_rename' ? ' (${plural(o.tracks, 'track')})' : ''}',
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _path('From', o.from, small),
          if (o.op == 'replace' && o.source != null)
            _path('With', o.source!, small),
          if (o.op != 'remove')
            _path(o.op == 'replace' ? 'As' : 'To', o.to, small)
          else
            Text('To: the Removed files area (restorable)', style: small),
          if (blocked)
            Text(
              'Blocked: ${o.blocked}',
              style: TextStyle(fontSize: DjType.small, color: t.danger),
            ),
          if (o.serato != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber, size: 14, color: t.warn),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      o.serato!,
                      style: TextStyle(fontSize: DjType.small, color: t.warn),
                    ),
                  ),
                ],
              ),
            ),
          for (final n in o.notes) Text(n, style: small),
        ],
      ),
    );
  }

  Widget _path(String label, String path, TextStyle style) => Tooltip(
    message: path,
    waitDuration: const Duration(milliseconds: 400),
    child: Text(
      '$label: $path',
      style: style,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
  );
}

/// Audio files a replacement can be.
const audioTypeGroup = XTypeGroup(
  label: 'Audio',
  extensions: supportedExtensions,
);

/// Replaces one track's file with a better copy the DJ picks, after the full
/// preview ([OrganizeService.previewReplaceFile]); then rescans that track's
/// music folder so the new file's details and analysis are refreshed. With
/// [source] the picker is skipped (the Upgrades page passes the chosen file).
Future<bool> replaceWithBetterFile(
  BuildContext context,
  WidgetRef ref,
  int trackId, {
  String? source,
}) async {
  final s = ref.read(sessionProvider);
  if (!organiseModeOn(s.cat)) {
    toast(
      'Turn on Organise Files mode (Organise Files, or Settings → Changes to music files) to replace files.',
      error: true,
    );
    return false;
  }
  var path = source;
  if (path == null) {
    final f = await openFile(
      acceptedTypeGroups: const [audioTypeGroup],
      confirmButtonText: 'Use this file',
    );
    if (f == null) return false;
    path = f.path;
  }
  final plan = await guard(() => s.organize.previewReplaceFile(trackId, path!));
  if (plan == null || !context.mounted) return false;
  final r = await showOrganisePreview(
    context,
    ref,
    plan,
    title: 'Replace a track with a better file',
  );
  if (r == null || r.done == 0) return false;
  final root =
      s.cat.db.select('SELECT root_id FROM tracks WHERE id=?', [
            trackId,
          ]).firstOrNull?['root_id']
          as int?;
  if (root != null) s.startScan(rootIds: [root]);
  return true;
}
