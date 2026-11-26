import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'format.dart';
import 'state.dart';
import 'widgets.dart';

/// Asks before removing [ids] from the library. The songs leave the
/// catalogue (crates, ratings and analysis); the files stay on disk and later
/// scans skip them. Returns true when something was removed.
Future<bool> showRemoveDialog(
  BuildContext context,
  WidgetRef ref,
  List<int> ids,
) async {
  if (ids.isEmpty) return false;
  final s = ref.read(sessionProvider);
  final ok = await confirm(
    context,
    title: 'Remove ${plural(ids.length, 'song')} from the library?',
    message:
        'Crates, ratings and analysis for these songs are removed. The files '
        'stay on disk and scans skip them. Bring them back from Settings → Library.',
    ok: 'Remove',
    danger: true,
  );
  if (!ok) return false;
  final r = await guard(() {
    final n = s.removal.removeFromLibrary(ids);
    return 'Removed ${plural(n, 'song')} from the library. The files are untouched.';
  }, bump: ref);
  if (r != null) toast(r);
  return r != null;
}
