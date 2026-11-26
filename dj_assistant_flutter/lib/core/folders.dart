import 'dart:io';

import 'package:path/path.dart' as p;

/// Opens a folder in Explorer (or the platform's file manager).
Future<void> openFolder(String dir) async {
  if (Platform.isWindows) {
    await Process.run('explorer', [dir]);
  } else if (Platform.isMacOS) {
    await Process.run('open', [dir]);
  } else {
    await Process.run('xdg-open', [dir]);
  }
}

/// Shows a file in Explorer (or the platform's file manager).
Future<void> revealInFolder(String path) async {
  if (Platform.isWindows) {
    await Process.run('explorer', ['/select,', path]);
  } else if (Platform.isMacOS) {
    await Process.run('open', ['-R', path]);
  } else {
    await Process.run('xdg-open', [p.dirname(path)]);
  }
}
