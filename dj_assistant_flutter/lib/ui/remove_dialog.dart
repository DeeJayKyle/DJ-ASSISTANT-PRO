import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'state.dart';

/// Asks how to delete [ids] and does it. By default songs leave the library
/// only (the files stay on disk and later scans skip them). When changes to
/// music files are allowed in Settings, the files can also be moved to the
/// restorable "Removed files" area (undo from Organise Files). Returns true
/// when something was removed.
Future<bool> showRemoveDialog(
  BuildContext context,
  WidgetRef ref,
  List<int> ids,
) async {
  if (ids.isEmpty) return false;
  final s = ref.read(sessionProvider);
  final filesAllowed = s.cat.getSetting('allow_file_changes') == '1';
  var moveFiles = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, set) => AlertDialog(
        title: Text('Delete ${plural(ids.length, 'song')}?'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RadioGroup<bool>(
                groupValue: moveFiles,
                onChanged: (v) => set(() => moveFiles = v ?? false),
                child: Column(
                  children: [
                    const RadioListTile<bool>(
                      value: false,
                      title: Text('Remove from the library'),
                      subtitle: Text(
                        'Crates, tags, ratings and analysis for these songs are removed. '
                        'The files stay on disk and scans skip them. Bring them back from Settings → Library.',
                      ),
                    ),
                    RadioListTile<bool>(
                      value: true,
                      enabled: filesAllowed,
                      title: const Text(
                        'Also move the files to “Removed files”',
                      ),
                      subtitle: Text(
                        filesAllowed
                            ? 'The files leave your music folders. Undo from Organise Files.'
                            : 'Turn on "Allow changes to music files" in Settings → Safety to use this.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  final r = await guard(() {
    if (moveFiles) {
      final plan = s.organize.previewRemove(ids);
      final done = s.organize.apply(plan);
      return 'Moved ${plural(done.done, 'file')} to Removed files'
          '${done.skipped.isEmpty ? '' : ' (${done.skipped.length} skipped)'}. Undo from Organise Files.';
    }
    final n = s.removal.removeFromLibrary(ids);
    return 'Removed ${plural(n, 'song')} from the library. The files are untouched.';
  }, bump: ref);
  if (r != null) toast(r);
  return r != null;
}
