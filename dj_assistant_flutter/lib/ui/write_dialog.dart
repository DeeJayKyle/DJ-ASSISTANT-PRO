import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/safe_write.dart';
import 'state.dart';
import 'theme.dart';

const _fields = [
  ('title', 'Title'),
  ('artist', 'Artist'),
  ('album', 'Album'),
  ('genre', 'Genre'),
  ('year', 'Year'),
  ('bpm', 'BPM'),
  ('key', 'Key'),
  ('comment', 'Comment'),
];

/// Opt-in, previewed, backed-up tag writing to music files (1.x WriteDialog).
Future<void> showWriteDialog(
  BuildContext context,
  WidgetRef ref,
  List<int> ids, {
  Map<String, String> initial = const {},
}) async {
  final s = ref.read(sessionProvider);
  if (!s.safeWrite.enabled) {
    toast(
      'Writing tags to files is turned off. Turn on “Allow file changes” in Settings first.',
      error: true,
    );
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (c) => _WriteDialog(ids: ids, initial: initial, ref: ref),
  );
}

class _WriteDialog extends StatefulWidget {
  const _WriteDialog({
    required this.ids,
    required this.initial,
    required this.ref,
  });
  final List<int> ids;
  final Map<String, String> initial;
  final WidgetRef ref;
  @override
  State<_WriteDialog> createState() => _WriteDialogState();
}

class _WriteDialogState extends State<_WriteDialog> {
  late final vals = {
    for (final (k, _) in _fields)
      k: TextEditingController(text: widget.initial[k] ?? ''),
  };
  late final use = {
    for (final (k, _) in _fields) k: widget.initial.containsKey(k),
  };
  List<PlannedChange>? plan;
  String? err;
  bool busy = false;
  (int, int)? done;

  SafeWriteService get svc => widget.ref.read(sessionProvider).safeWrite;

  void _preview() {
    final values = <String, String?>{
      for (final (k, _) in _fields)
        if (use[k]!)
          k: vals[k]!.text.trim().isEmpty ? null : vals[k]!.text.trim(),
    };
    if (values.isEmpty) {
      setState(() => err = 'Choose at least one field to write.');
      return;
    }
    try {
      setState(() {
        plan = svc.preview(widget.ids, values);
        err = null;
      });
    } on Object catch (e) {
      setState(() => err = '$e');
    }
  }

  void _apply() {
    setState(() => busy = true);
    try {
      final res = svc.apply(plan!);
      final ok = res.where((r) => r['status'] == 'done').length;
      final failed = res.where((r) => r['status'] == 'failed').toList();
      if (failed.isNotEmpty) toast('${failed.first['message']}', error: true);
      widget.ref.read(versionProvider.notifier).bump();
      setState(() => done = (ok, failed.length));
    } on Object catch (e) {
      setState(() => err = '$e');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = DjTokens.of(context);
    final changes = plan?.where((p) => p.blocked == null).toList() ?? const [];
    Widget body;
    if (done != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, color: t.ok, size: 48),
          const SizedBox(height: 8),
          Text(
            '${done!.$1} file${done!.$1 == 1 ? '' : 's'} updated',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Each original was backed up and verified first. You can undo any change in Settings → Change log.',
            style: TextStyle(color: t.faint),
            textAlign: TextAlign.center,
          ),
        ],
      );
    } else if (plan == null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Card(
            color: t.warn.withValues(alpha: 0.1),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                "This changes the files on disk. Serato keeps cues, loops and beatgrids inside the file tags — DJ Assistant preserves every tag it isn't asked to change and verifies the audio is untouched. "
                'Each file is backed up and verified before writing, nothing is written if the file changed since the preview, and every change can be rolled back.',
                style: TextStyle(color: t.warn),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${widget.ids.length} track${widget.ids.length == 1 ? '' : 's'} selected. Tick the fields to write; leave a value empty to remove that tag.',
            style: TextStyle(color: t.faint),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              for (final (k, label) in _fields)
                SizedBox(
                  width: 260,
                  child: Row(
                    children: [
                      Checkbox(
                        value: use[k],
                        onChanged: (v) => setState(() => use[k] = v!),
                      ),
                      Expanded(
                        child: TextField(
                          controller: vals[k],
                          enabled: use[k],
                          decoration: InputDecoration(labelText: label),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Exact changes. Nothing has been written yet.',
            style: TextStyle(color: t.faint),
          ),
          const SizedBox(height: 8),
          for (final p in plan!)
            ListTile(
              dense: true,
              title: Text(
                p.path,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12),
              ),
              subtitle: p.blocked != null
                  ? Text(p.blocked!, style: TextStyle(color: t.danger))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final e in p.changes.entries)
                          Text(
                            '${e.key}: ${e.value.$1 ?? '∅'} → ${e.value.$2 ?? '(removed)'}',
                          ),
                        for (final w in p.warnings)
                          Text(w, style: TextStyle(color: t.warn)),
                      ],
                    ),
            ),
        ],
      );
    }
    return AlertDialog(
      title: const Text('Write tags to music files'),
      content: SizedBox(
        width: 640,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              body,
              if (err != null) ...[
                const SizedBox(height: 8),
                Text(err!, style: TextStyle(color: t.danger)),
              ],
            ],
          ),
        ),
      ),
      actions: done != null
          ? [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ]
          : plan != null
          ? [
              TextButton(
                onPressed: () => setState(() => plan = null),
                child: const Text('Back'),
              ),
              FilledButton(
                onPressed: changes.isEmpty || busy ? null : _apply,
                child: Text(
                  busy
                      ? 'Writing…'
                      : 'Back up and write ${changes.length} file${changes.length == 1 ? '' : 's'}',
                ),
              ),
            ]
          : [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: _preview,
                child: const Text('Preview changes'),
              ),
            ],
    );
  }
}
