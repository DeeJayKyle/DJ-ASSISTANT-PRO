import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/diag_log.dart';
import '../core/updater.dart';
import '../online/http_online.dart' show HttpOnline, appVersion;
import 'state.dart';

/// Automatic updates (Windows builds): a newer release is downloaded and its
/// signature checked in the background, then installed when the app closes,
/// or straight away with "Restart now". The library, crates and settings
/// are kept, as with any update.
String updatesDir() => p.join(defaultDataDir(), 'updates');

/// The update downloaded and waiting to be installed, if any.
final waitingUpdate = ValueNotifier<StagedUpdate?>(null);

bool get canAutoInstall => Platform.isWindows;

/// Checks GitHub for a newer release. With [install] (and on Windows) it is
/// downloaded and made ready; otherwise the DJ is only told about it.
Future<void> autoUpdate({required bool install}) async {
  if (!canAutoInstall) return;
  waitingUpdate.value ??= stagedUpdate(updatesDir(), appVersion);
  try {
    final u = await checkForUpdate(HttpOnline().web, appVersion);
    if (u == null) return;
    if (!install) {
      toast('DJ Assistant ${u.version} is available. Settings → Updates.');
      return;
    }
    if (waitingUpdate.value?.version == u.version) return;
    waitingUpdate.value = await stageUpdate(HttpOnline().web, u, updatesDir());
    toast(
      'DJ Assistant ${u.version} is ready. It installs when you close the '
      'app, or restart now in Settings → Updates.',
    );
  } on Object catch (e) {
    // offline or GitHub unreachable: tried again later
    DiagLog.info('update', 'automatic update check failed: $e');
  }
}

/// Installs the waiting update and quits; the new version opens by itself.
Future<void> restartToUpdate() async {
  final s = waitingUpdate.value;
  if (s == null) return;
  await installStaged(s);
  exit(0);
}

/// Called as the app closes: installs a waiting update quietly (without
/// reopening the app). Never stops the app from closing.
Future<void> installOnExit() async {
  final s = waitingUpdate.value;
  if (s == null || !canAutoInstall) return;
  try {
    await installStaged(s, restart: false);
  } on Object catch (e) {
    DiagLog.info('update', 'update not installed on exit: $e');
  }
}
