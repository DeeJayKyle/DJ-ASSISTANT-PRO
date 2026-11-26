import 'dart:io';

import 'package:file_selector/file_selector.dart' show getDirectoryPath;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/diag_log.dart';
import '../core/folders.dart' show openFolder;
import '../core/file_sync.dart';
import '../core/updater.dart';
import 'updates.dart';
import '../online/http_online.dart';
import 'format.dart';
import 'shortcuts_sheet.dart';
import 'state.dart';
import 'theme.dart';
import 'widgets.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  UpdateInfo? update;
  String? updateMsg;

  void _set(String k, Object? v) => guard(() {
    final s = ref.read(sessionProvider);
    s.settings.set(k, v);
    if (k == 'watch_enabled') v == true ? s.watcher.start() : s.watcher.stop();
  }, bump: ref);

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final t = DjTokens.of(context);
    final st = ref.watch(settingsProvider);
    final base = ref.watch(accountsProvider).base;
    Widget sw(String key, String title, {String? sub}) => SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: sub == null
          ? null
          : Text(
              sub,
              style: TextStyle(color: t.faint, fontSize: DjType.small),
            ),
      value: st[key] == true,
      onChanged: (v) => _set(key, v),
    );
    Widget choice(String key, String title, List<(String, String)> opts) =>
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.x1 + 2),
          child: SizedBox(
            width: double.infinity,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: Space.x3,
              runSpacing: Space.x2,
              children: [
                Text(title),
                SegmentedButton<String>(
                  segments: [
                    for (final (v, l) in opts)
                      ButtonSegment(value: v, label: Text(l)),
                  ],
                  selected: {'${st[key]}'},
                  onSelectionChanged: (v) => _set(key, v.first),
                ),
              ],
            ),
          ),
        );
    final serato = s.seratoDirs;
    return PageFrame(
      title: 'Settings',
      subtitle: 'Everything here is stored on this computer, per account.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Panel(
            title: 'Appearance',
            child: Column(
              children: [
                choice('theme', 'Theme', [
                  ('dark', 'Dark'),
                  ('light', 'Light'),
                ]),
                choice('key_notation', 'Keys', [
                  ('camelot', 'Camelot (8A)'),
                  ('musical', 'Musical (Am)'),
                ]),
                choice('accent', 'Accent', [
                  ('mint', 'Mint'),
                  ('cyan', 'Cyan'),
                  ('violet', 'Violet'),
                  ('amber', 'Amber'),
                  ('rose', 'Rose'),
                ]),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Library',
            child: Column(
              children: [
                sw(
                  'auto_prep',
                  'Analyse new songs automatically',
                  sub: 'After every scan, new songs get their artist and title from the file name if missing, BPM and key from Serato, then genre, year, album and label from the online analysers (majority wins), written into the files.',
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.undo),
                    label: const Text('Undo every automatic change…'),
                    onPressed: () async {
                      final ok = await confirm(
                        context,
                        title: 'Undo every automatic change?',
                        message: 'Every value the analysers changed goes back to what it was before, in the catalogue and in the files. Values you have changed since are left as they are.',
                        ok: 'Undo them',
                      );
                      if (!ok) return;
                      await guard(() {
                        final (n, kept) = s.suggestions.undoAuto();
                        return toast(
                          'Undid ${plural(n, 'automatic change')}${kept == 0 ? '' : '; ${plural(kept, 'value')} changed since were kept'}.',
                        );
                      }, bump: ref);
                    },
                  ),
                ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Serato',
            subtitle: 'Where Serato DJ keeps its crates and library. Used for BPM, key and crates.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  serato.isEmpty
                      ? 'No _Serato_ folder found.'
                      : 'Using: ${serato.join(', ')}',
                  style: TextStyle(color: t.muted),
                ),
                const SizedBox(height: Space.x2),
                Wrap(
                  spacing: Space.x2,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Choose the _Serato_ folder…'),
                      onPressed: () async {
                        final d = await getDirectoryPath(
                          confirmButtonText: 'Use this _Serato_ folder',
                        );
                        if (d != null) _set('serato_dir', d);
                      },
                    ),
                    if ('${st['serato_dir']}'.isNotEmpty)
                      TextButton(
                        onPressed: () => _set('serato_dir', ''),
                        child: const Text('Find it automatically'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'Changes to music files',
            subtitle: 'Fixes are written straight into your original files. No copies are made.',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sw(
                  'sync_to_files',
                  'Write changes into the music files',
                  sub: 'Title, artist, album, genre, year, label, BPM, key and Grouping (energy and mood, like "E7 · Uplifting") go into the file\'s own tags, and then into Serato\'s library so Serato shows them without a rescan. The audio is checked bit for bit and Serato\'s cues and beatgrids are kept. MP3 and FLAC get every field; M4A all but BPM, key and label; WAV, AIFF and Ogg keep their values in DJ Assistant only.',
                ),
                sw(
                  'energy_to_comment',
                  'Also write energy and mood into Comments',
                  sub: 'Off: Comments are left alone (Mixed In Key and many DJs keep "8A - Energy 6" there). On: Comments get the same text as Grouping.',
                ),
                sw(
                  'write_backups',
                  'Keep a backup copy before each write',
                  sub: 'Off: the original file is changed in place and no copy is kept; Undo writes the previous values back. On: a verified copy is kept in the app\'s data folder and can be restored.',
                ),
                Builder(
                  builder: (_) {
                    final queued = fileSyncQueued(s.cat);
                    final last = lastFileSync(s.cat);
                    final job = s.jobs.status('file_sync');
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Space.x3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (job.state == 'running')
                            ProgressLine(
                              label: 'Writing to music files…',
                              done: job.done,
                              total: job.total,
                            ),
                          Text(
                            [
                              if (queued > 0)
                                '$queued track(s) waiting to be written.',
                              if (last != null)
                                'Last: ${last['written']} written, ${last['skipped']} already up to date or not writable, ${last['failed']} failed · ${fmtDateTime(last['at'] as int?)}.',
                              if (queued == 0 && last == null)
                                'Nothing written yet.',
                            ].join(' '),
                            style: TextStyle(
                              color: t.muted,
                              fontSize: DjType.small,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const Text(
                  'Change log',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                for (final c in s.safeWrite.log(limit: listRows(ref)))
                  ListTile(
                    dense: true,
                    title: Text(
                      '${c['path']}',
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${c['action']} · ${c['status']} · ${fmtDateTime(c['at'] as int?)}',
                    ),
                    trailing: c['status'] == 'done'
                        ? TextButton(
                            onPressed: () => guard(
                              () => s.safeWrite.rollback(c['id']! as int),
                              done:
                                  'Restored the original file from its backup.',
                              bump: ref,
                            ),
                            child: const Text('Roll back'),
                          )
                        : null,
                  ),
              ],
            ),
          ),
          gap,
          const RemovedSongsPanel(),
          gap,
          const ResetPanel(),
          gap,
          Panel(
            title: 'Updates',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                sw(
                  'auto_update',
                  'Check for updates automatically',
                  sub: 'When the app starts and every few hours. Sends only the request for the release manifest to GitHub.',
                ),
                if (st['auto_update'] == true)
                  sw(
                    'auto_install_update',
                    'Install updates automatically',
                    sub: 'A new version is downloaded in the background, its signature is checked, and it installs when you close DJ Assistant. Your library, crates and settings are kept.',
                  ),
                Row(
                  children: [
                    Text('DJ Assistant $appVersion'),
                    const Spacer(),
                    ValueListenableBuilder(
                      valueListenable: waitingUpdate,
                      builder: (context, w, _) => w == null
                          ? const SizedBox.shrink()
                          : FilledButton.icon(
                              onPressed: () => guard(restartToUpdate),
                              icon: const Icon(Icons.restart_alt, size: 18),
                              label: Text('Restart and update to ${w.version}'),
                            ),
                    ),
                    if (update != null &&
                        waitingUpdate.value?.version != update!.version)
                      FilledButton(
                        onPressed: () => guard(() async {
                          final dest =
                              '${Directory.systemTemp.path}${Platform.pathSeparator}DJ-Assistant-${update!.version}-setup.exe';
                          final path = await downloadUpdate(
                            HttpOnline().web,
                            update!,
                            dest,
                          );
                          // passive install, then start the new version
                          // (the switches 1.x's updater used)
                          await Process.start(path, const [
                            '/P',
                            '/UPDATE',
                            '/R',
                          ], mode: ProcessStartMode.detached);
                          exit(0);
                        }),
                        child: Text('Install ${update!.version}'),
                      ),
                    TextButton(
                      onPressed: () => guard(() async {
                        final u = await checkForUpdate(
                          HttpOnline().web,
                          appVersion,
                        );
                        setState(() {
                          update = u;
                          updateMsg = u == null
                              ? "You're up to date."
                              : 'Version ${u.version} is available.';
                        });
                      }),
                      child: const Text('Check now'),
                    ),
                  ],
                ),
                if (updateMsg != null)
                  Text(updateMsg!, style: TextStyle(color: t.faint)),
              ],
            ),
          ),
          gap,
          Panel(
            title: 'About',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  'Data folder: $base\nCatalogue: ${s.dbPath}\nNo telemetry. Nothing is sent online unless you turn a service on.',
                  style: TextStyle(color: t.muted),
                ),
                const SizedBox(height: Space.x2),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.keyboard_outlined, size: 16),
                    label: const Text('Keyboard shortcuts (F1)'),
                    onPressed: () => showShortcuts(context),
                  ),
                ),
                if (DiagLog.folder case final logs?) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('Open log folder'),
                        onPressed: () => openFolder(logs),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Errors are logged on this PC only, to help fix problems. Nothing is sent.',
                          style: TextStyle(color: t.faint),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Reset and delete: crates, settings, the whole account, or all app data.
class ResetPanel extends ConsumerWidget {
  const ResetPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    final t = DjTokens.of(context);
    Widget item(
      IconData icon,
      String title,
      String sub,
      String button,
      Future<void> Function() run,
    ) => ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: t.danger),
      title: Text(title),
      subtitle: Text(
        sub,
        style: TextStyle(color: t.faint, fontSize: DjType.small),
      ),
      trailing: OutlinedButton(
        style: OutlinedButton.styleFrom(foregroundColor: t.danger),
        onPressed: run,
        child: Text(button),
      ),
    );
    Future<bool> ask(String title, String message, String ok) =>
        confirm(context, title: title, message: message, ok: ok, danger: true);

    return Panel(
      title: 'Reset and delete',
      subtitle: 'Your music files are never deleted by any of these.',
      child: Column(
        children: [
          item(
            Icons.inventory_2_outlined,
            'Delete all crates in DJ Assistant',
            'Every crate and crate folder made in the Crate builder.',
            'Delete crates',
            () async {
              if (!await ask(
                'Delete all crates?',
                'Every crate in DJ Assistant is deleted. Crates saved in Serato stay until you delete them there (Crates → Serato crates).',
                'Delete crates',
              )) {
                return;
              }
              await guard(
                () {
                  var n = 0;
                  for (final c in s.crates.list()) {
                    if (c.parentId == null) {
                      s.crates.delete(c.id);
                      n++;
                    }
                  }
                  return n;
                },
                done: 'All crates deleted.',
                bump: ref,
              );
            },
          ),
          item(Icons.album_outlined, 'Delete all Serato crates', 'Every .crate file in your _Serato_ folder(s). Close Serato first.', 'Delete in Serato', () async {
            final dirs = s.seratoDirs;
            if (dirs.isEmpty) {
              toast('No _Serato_ folder found.', error: true);
              return;
            }
            if (!await ask(
              'Delete every Serato crate?',
              'All crates in ${dirs.join(', ')} are deleted. Serato\'s library and your music stay.',
              'Delete Serato crates',
            )) {
              return;
            }
            await guard(() {
              var n = 0;
              for (final d in dirs) {
                n += s.seratoLibraryFor(d).deleteAll();
              }
              toast('Deleted ${plural(n, 'Serato crate')}.');
            }, bump: ref);
          }),
          item(
            Icons.settings_backup_restore,
            'Reset settings',
            'Every setting back to its default; saved API keys are removed.',
            'Reset settings',
            () async {
              if (!await ask(
                'Reset all settings?',
                'Every setting goes back to its default and saved API keys are removed. Your library and crates stay.',
                'Reset settings',
              )) {
                return;
              }
              await guard(
                () => s.settings.resetAll(),
                done: 'Settings reset.',
                bump: ref,
              );
            },
          ),
          item(Icons.cleaning_services_outlined, 'Empty this account', 'Library list, crates, analysis, change history and settings of this account.', 'Empty account', () async {
            if (!await ask(
              'Empty this account?',
              'Everything DJ Assistant stored for this account is deleted. Your music files are not touched; scan your folders again to start over.',
              'Empty account',
            )) {
              return;
            }
            await guard(
              () => ref.read(sessionProvider.notifier).resetAccount(),
              done: 'The account is empty.',
            );
            ref.read(viewProvider.notifier).go('home');
          }),
          item(Icons.delete_forever_outlined, 'Delete all app data', 'Every account, crate, setting, API key and backup. DJ Assistant starts as new.', 'Delete everything', () async {
            if (!await ask(
              'Delete all DJ Assistant data?',
              'Every account with its library list, crates, analysis, settings, API keys and backups is deleted. This cannot be undone. Your music files and Serato are not touched.',
              'Delete everything',
            )) {
              return;
            }
            await guard(() async {
              s.settings.resetAll();
              await ref.read(sessionProvider.notifier).resetEverything();
            }, done: 'All app data deleted. DJ Assistant starts fresh.');
            ref.read(viewProvider.notifier).go('home');
          }),
        ],
      ),
    );
  }
}

class RemovedSongsPanel extends ConsumerWidget {
  const RemovedSongsPanel({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(sessionProvider);
    ref.watch(versionProvider);
    final hidden = s.removal.hidden(limit: 200);
    return Panel(
      title: 'Removed songs',
      subtitle: 'Songs you deleted from the library. Their files were left on disk; scans skip them until you bring them back.',
      trailing: hidden.isEmpty
          ? null
          : TextButton(
              onPressed: () => guard(
                () => s.removal.restore([
                  for (final h in s.removal.hidden(limit: 1 << 30))
                    h['path_key']! as String,
                ]),
                done: 'All removed songs will come back on the next scan.',
                bump: ref,
              ),
              child: const Text('Bring all back'),
            ),
      child: hidden.isEmpty
          ? const HintText('Nothing removed.', icon: Icons.check)
          : Column(
              children: [
                for (final h in hidden)
                  ListTile(
                    dense: true,
                    title: Text(
                      [h['artist'], h['title']]
                          .whereType<String>()
                          .where((x) => x.isNotEmpty)
                          .join(' — '),
                    ),
                    subtitle: Text('${h['path']}'),
                    trailing: TextButton(
                      onPressed: () => guard(
                        () => s.removal.restore([h['path_key']! as String]),
                        done: 'It will come back on the next scan.',
                        bump: ref,
                      ),
                      child: const Text('Bring back'),
                    ),
                  ),
              ],
            ),
    );
  }
}
