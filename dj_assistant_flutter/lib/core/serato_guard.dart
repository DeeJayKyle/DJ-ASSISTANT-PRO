import 'dart:io';

import 'serato_library.dart';

/// Is Serato DJ Pro or Serato DJ Lite open?
///
/// Serato keeps its crates and library in memory and writes them back when
/// it quits, so anything changed under it is lost (or worse, half-merged).
/// The check is strict: when the process list can't be read the answer is
/// "maybe", and every write is refused.
bool seratoRunningNow() {
  if (Platform.isWindows) {
    final ProcessResult r;
    try {
      r = Process.runSync('tasklist', ['/FO', 'CSV', '/NH']);
    } on Object {
      throw SeratoLibraryException(_unknown);
    }
    if (r.exitCode != 0) throw SeratoLibraryException(_unknown);
    return seratoInProcessList('${r.stdout}');
  }
  if (Platform.isMacOS) {
    final ProcessResult r;
    try {
      r = Process.runSync('ps', ['-axco', 'comm']);
    } on Object {
      throw SeratoLibraryException(_unknown);
    }
    if (r.exitCode != 0) throw SeratoLibraryException(_unknown);
    return seratoInProcessList('${r.stdout}');
  }
  // Serato DJ only runs on Windows and macOS.
  return false;
}

const _unknown =
    "Couldn't check whether Serato DJ is open, so nothing was changed. "
    'Close Serato DJ and try again.';

/// Whether a process listing (Windows `tasklist /FO CSV`, or one process
/// name per line) shows Serato DJ Pro, Serato DJ Lite or older Serato DJ.
bool seratoInProcessList(String listing) {
  for (final raw in listing.split('\n')) {
    var name = raw.trim();
    if (name.startsWith('"')) {
      final end = name.indexOf('"', 1);
      name = end > 0 ? name.substring(1, end) : name.substring(1);
    }
    name = name.toLowerCase();
    if (name.endsWith('.exe')) name = name.substring(0, name.length - 4);
    final base = name.split(RegExp(r'[\\/]')).last;
    if (base == 'serato dj pro' ||
        base == 'serato dj lite' ||
        base == 'serato dj' ||
        base == 'serato dj intro') {
      return true;
    }
  }
  return false;
}
