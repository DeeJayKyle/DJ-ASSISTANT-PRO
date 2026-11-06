import 'dart:io';

import 'package:path/path.dart' as p;

/// The diagnostics log: `<data>/logs/dj-assistant.log` (on Windows
/// `%APPDATA%\com.deejaykyle.djassistant\logs`). Studio errors with their
/// stack traces, the decoder used, isolate and ONNX Runtime messages, and
/// any uncaught error. It stays on this PC: nothing is ever sent anywhere.
///
/// The file is rotated at [maxBytes], keeping [keep] older files. Logging
/// never throws, and does nothing until [init] (tests, isolates).
class DiagLog {
  DiagLog._();

  static const maxBytes = 1024 * 1024;
  static const keep = 3;
  static String? _dir;

  /// The log folder, or null before [init].
  static String? get folder => _dir;
  static String? get file =>
      _dir == null ? null : p.join(_dir!, 'dj-assistant.log');

  static void init(String dataDir) {
    try {
      final d = p.join(dataDir, 'logs');
      Directory(d).createSync(recursive: true);
      _dir = d;
      info(
        'app',
        'started (${Platform.operatingSystemVersion}, '
            '${Platform.numberOfProcessors} cores)',
      );
    } on Object {
      _dir = null;
    }
  }

  /// Stops logging (tests).
  static void reset() => _dir = null;

  static void info(String area, String message) =>
      _write('INFO', area, message);

  static void error(String area, Object error, [StackTrace? stack]) {
    final s = stack == null || '$stack'.trim().isEmpty ? '' : '\n$stack';
    _write('ERROR', area, '$error$s');
  }

  static void _write(String level, String area, String message) {
    final f = file;
    if (f == null) return;
    try {
      final log = File(f);
      if (log.existsSync() && log.lengthSync() > maxBytes) _rotate(f);
      final t = DateTime.now().toIso8601String();
      log.writeAsStringSync(
        '$t $level [$area] ${message.trimRight()}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object {
      // a full disk or a locked file must never break the app
    }
  }

  static void _rotate(String f) {
    for (var i = keep; i >= 1; i--) {
      final from = i == 1 ? File(f) : File('$f.${i - 1}');
      final to = File('$f.$i');
      if (i == keep && to.existsSync()) to.deleteSync();
      if (from.existsSync()) from.renameSync(to.path);
    }
  }
}
