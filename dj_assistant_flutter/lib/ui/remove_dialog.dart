import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/organize.dart' show organiseModeOn;
import 'format.dart';
import 'organise_preview.dart';
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
  final filesAllowed = organiseModeOn(s.cat);
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
                            ? 'You see every file first and approve them. They leave your music folders for the restorable Removed files area. Undo from Organise Files.'
                            : 'Turn on Organise Files mode in Settings → Changes to music files to use this.',
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
  if (moveFiles) {
    // The files move only after the full preview, with each one approved.
    final plan = await guard(() => s.organize.previewRemove(ids));
    if (plan == null || !context.mounted) return false;
    final r = await showOrganisePreview(
      context,
      ref,
      plan,
      title: 'Move ${plural(ids.length, 'file')} to Removed files',
    );
    return r != null && r.done > 0;
  }
  final r = await guard(() {
    final n = s.removal.removeFromLibrary(ids);
    return 'Removed ${plural(n, 'song')} from the library. The files are untouched.';
  }, bump: ref);
  if (r != null) toast(r);
  return r != null;
}
