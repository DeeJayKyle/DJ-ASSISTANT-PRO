import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/folders.dart' show openFolder;
import '../core/serato_backup.dart';
import 'format.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

/// Backups & Settings → Backups: the ZIPs of Serato's crates and library
/// taken before every change, with Restore.
class BackupsScreen extends ConsumerWidget {
  const BackupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final dirs = s.seratoDirs;
    final all = s.seratoBackups.list();

    Future<void> backUpNow() async {
      if (dirs.isEmpty) {
        toast('No _Serato_ folder found.', error: true);
        return;
      }
      await guard(
        () {
          for (final d in dirs) {
            s.seratoBackups.create(d, reason: 'Backed up by hand');
          }
        },
        done: 'Backed up.',
        bump: ref,
      );
    }

    Future<void> restore(SeratoBackup b) async {
      if (!Directory(b.source).existsSync()) {
        toast('${b.source} is not connected.', error: true);
        return;
      }
      if (!await confirm(
        context,
        title: 'Restore this backup?',
        message:
            'Every crate in ${b.source} is replaced by the ones saved on '
            '${fmtDateTime(b.at.millisecondsSinceEpoch)}, and Serato\'s '
            'library goes back to that moment. What is there now is backed '
            'up first, so this can be undone.',
        ok: 'Restore',
        danger: true,
      )) {
        return;
      }
      await guard(
        () => s.seratoLibraryFor(b.source).restore(b),
        done: 'Restored. Start Serato DJ to see it.',
        bump: ref,
      );
    }

    return PageFrame(
      title: 'Serato backups',
      subtitle:
          "Before every change to Serato's crates or library, a ZIP of "
          '_Serato_/Subcrates and database V2 is saved here. The newest '
          '${s.seratoBackups.keep} are kept.',
      actions: [
        OutlinedButton.icon(
          onPressed: () => openFolder(s.seratoBackups.dir),
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('Open folder'),
        ),
        FilledButton.icon(
          onPressed: backUpNow,
          icon: const Icon(Icons.archive_outlined),
          label: const Text('Back up now'),
        ),
      ],
      child: all.isEmpty
          ? const EmptyState(
              icon: Icons.archive_outlined,
              title: 'No backups yet',
              message:
                  'One is made automatically the first time the app changes '
                  "Serato's crates or library.",
            )
          : Panel(
              child: Column(
                children: [
                  for (final b in all)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.archive_outlined, color: t.accent),
                      title: Text(
                        b.reason.isEmpty ? 'Backup' : b.reason,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${fmtDateTime(b.at.millisecondsSinceEpoch)} · '
                        '${fmtBytes(b.bytes)} · ${b.source}',
                        style: TextStyle(
                          color: t.faint,
                          fontSize: DjType.small,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: TextButton(
                        onPressed: () => restore(b),
                        child: const Text('Restore'),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}
