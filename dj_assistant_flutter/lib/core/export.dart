import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'library.dart';
import 'library_edit.dart';
import 'tags.dart';

/// Exports (1.x `export.rs`): M3U8 playlists, CSV lists and text, plus the
/// Studio's own files. They write only the new file the DJ chose; music files are
/// never touched and an existing file is never replaced unless the save dialog
/// asked (and an existing WAV is never replaced at all, since it could be music).
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

/// File types the Studio saves (stems, remixes, MIDI, instruments and kits).
const studioExtensions = ['wav', 'mid', 'sfz', 'json'];

void _studioGuard(String path, bool overwrite) {
  final ext = _ext(path);
  if (!studioExtensions.contains(ext)) {
    _no('file must end with .${studioExtensions.join(' or .')}');
  }
  if (File(path).existsSync() && (!overwrite || ext == 'wav')) {
    _no('a file with that name already exists; choose another name');
  }
}

/// Saves one Studio file the DJ chose in a save dialog, beside the target first
/// and then renamed, so a half-written file is never left behind.
void studioSave(String path, List<int> bytes, {bool overwrite = false}) {
  _studioGuard(path, overwrite);
  final part = '$path.part';
  try {
    File(part).writeAsBytesSync(bytes, flush: true);
    File(part).renameSync(path);
  } catch (_) {
    if (File(part).existsSync()) File(part).deleteSync();
    rethrow;
  }
}

String _safeSegment(String s) {
  var t = String.fromCharCodes(
    s.runes.map(
      (r) =>
          r < 0x20 ||
              (r >= 0x7F && r <= 0x9F) ||
              '<>:"/\\|?*'.contains(String.fromCharCode(r))
          ? 0x20
          : r,
    ),
  );
  t = t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
  t = t.replaceAll(RegExp(r'^[. ]+|[. ]+$'), '');
  return t.isEmpty ? 'Untitled' : String.fromCharCodes(t.runes.take(120));
}

/// Makes a NEW folder [name] in [parent] (" (2)", " (3)"… when taken).
String studioNewFolder(String parent, String name) {
  if (!Directory(parent).existsSync()) _no('choose a folder that exists');
  final base = _safeSegment(name);
  var dir = p.join(parent, base);
  var n = 2;
  while (FileSystemEntity.typeSync(dir) != FileSystemEntityType.notFound) {
    dir = p.join(parent, '$base ($n)');
    n++;
  }
  Directory(dir).createSync();
  return dir;
}

/// Writes a new file inside a folder made by [studioNewFolder] (never outside it).
String studioWriteInto(String folder, String rel, List<int> bytes) {
  var path = folder;
  for (final seg
      in rel
          .split(RegExp(r'[/\\]'))
          .where((s) => s.isNotEmpty && s != '.' && s != '..')) {
    path = p.join(path, _safeSegment(seg));
  }
  if (path == folder) _no('missing file name');
  _studioGuard(path, false);
  File(path).parent.createSync(recursive: true);
  final f = File(path).openSync(mode: FileMode.writeOnlyAppend);
  try {
    if (f.lengthSync() != 0) {
      _no('a file with that name already exists; choose another name');
    }
    f.writeFromSync(bytes);
    f.flushSync();
  } finally {
    f.closeSync();
  }
  return path;
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
