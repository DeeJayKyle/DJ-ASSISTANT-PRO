import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'library.dart';
import 'library_edit.dart';
import 'tags.dart';

/// Exports (1.x `export.rs`): M3U8 playlists, CSV lists and text. They write
/// only the new file the DJ chose; music files are never touched and an
/// existing file is never replaced unless the save dialog asked.
class ExportException implements Exception {
  ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw ExportException(m);

String _ext(String path) =>
    p.extension(path).replaceFirst('.', '').toLowerCase();

void _guard(String path, bool overwrite, List<String> allowed) {
  final ext = _ext(path);
  if (!allowed.contains(ext)) {
    _no('file must end with .${allowed.join(' or .')}');
  }
  if (classifyExtension(ext) != ExtKind.other) {
    _no('refusing to write to an audio file');
  }
  if (File(path).existsSync() && !overwrite) {
    _no('a file with that name already exists');
  }
}

class ExportService {
  ExportService(this.cat);
  final Catalogue cat;

  List<TrackRow> _rows(List<int> ids) {
    final lib = LibraryService(cat);
    return [for (final id in ids) ?lib.row(id)];
  }

  void _write(String path, String text) {
    final f = File(path).openSync(mode: FileMode.writeOnly);
    try {
      f.truncateSync(0);
      f.writeStringSync(text);
      f.flushSync();
    } finally {
      f.closeSync();
    }
  }

  /// An extended M3U8 playlist.
  int writeM3u(List<int> ids, String path, {bool overwrite = false}) {
    _guard(path, overwrite, ['m3u8', 'm3u']);
    final rows = _rows(ids);
    final b = StringBuffer('#EXTM3U\n');
    for (final r in rows) {
      final secs = r.durationMs == null ? -1 : r.durationMs! ~/ 1000;
      b
        ..write(
          '#EXTINF:$secs,${r.artist ?? 'Unknown artist'} - ${r.title ?? r.fileName}\n',
        )
        ..write('${r.path}\n');
    }
    _write(path, b.toString());
    return rows.length;
  }

  static String _csv(String s) =>
      (s.contains(',') ||
          s.contains('"') ||
          s.contains('\n') ||
          s.contains('\r'))
      ? '"${s.replaceAll('"', '""')}"'
      : s;

  int writeCsv(List<int> ids, String path, {bool overwrite = false}) {
    _guard(path, overwrite, ['csv']);
    final rows = _rows(ids);
    final b = StringBuffer(
      '#,Artist,Title,Version,Genre,Year,BPM,Key,Energy,Rating,Duration,Format,Bitrate,Path\n',
    );
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      final d = r.durationMs;
      b.write(
        '${[
          '${i + 1}', r.artist ?? '', r.title ?? '', r.version ?? '', r.genre ?? '', r.year?.toString() ?? '', //
          r.bpm?.toStringAsFixed(1) ?? '', r.key ?? '', r.energy?.toString() ?? '', r.rating?.toString() ?? '',
          d == null ? '' : '${d ~/ 60000}:${((d ~/ 1000) % 60).toString().padLeft(2, '0')}',
          r.format ?? '', r.bitrateKbps?.toString() ?? '', r.path,
        ].map(_csv).join(',')}\n',
      );
    }
    _write(path, b.toString());
    return rows.length;
  }

  void writeText(String path, String text, {bool overwrite = false}) {
    _guard(path, overwrite, ['txt', 'md']);
    _write(path, text);
  }
}

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
