import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'blake3.dart';
import 'catalogue.dart';
import 'crates.dart';
import 'jobs.dart';
import 'paths.dart';
import 'roots.dart';
import 'tags.dart';

/// Auto-import: music the DJ buys or downloads (Beatport, Bandcamp, Juno,
/// promo and record pools…) is picked up from a downloads folder as soon as
/// it has finished downloading, copied into the library's Inbox folder,
/// scanned, analysed by auto-prep and added to an "Inbox" crate.
///
/// The downloads folder is only read: files there are copied (verified byte
/// for byte), never moved, changed or deleted. ZIPs (Bandcamp and Beatport
/// bundles) are unpacked into the Inbox folder, audio only, with every name
/// reduced to a plain file name so nothing can land outside it. Each source
/// file is recorded so it is never imported twice.
class InboxException implements Exception {
  InboxException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Name of the crate new imports are added to.
const inboxCrateName = 'Inbox';

/// Extensions browsers and download managers use while a file is still
/// downloading: such files are left alone until they are renamed.
const partialExtensions = {
  'crdownload',
  'part',
  'partial',
  'tmp',
  'download',
  'opdownload',
  '!ut',
  'downloading',
};

/// A file must have been unchanged this long before it is imported.
const settleMs = 5000;

/// Limits on what a ZIP may unpack (protects the drive from damaged or
/// hostile archives).
const maxZipEntries = 2000;
const maxEntryBytes = 2 * 1024 * 1024 * 1024;
const maxZipBytes = 8 * 1024 * 1024 * 1024;

String _home() =>
    Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';

String defaultDownloadsFolder() => p.join(_home(), 'Downloads');

String defaultInboxFolder() => p.join(_home(), 'Music', 'DJ Assistant Inbox');

bool _isAudio(String path) => supportedExtensions.contains(
  p.extension(path).replaceFirst('.', '').toLowerCase(),
);

bool _isZip(String path) => p.extension(path).toLowerCase() == '.zip';

/// A file name that is safe to create: no folders, no reserved characters,
/// no leading dots, not empty.
String safeFileName(String name) {
  var n = p.basename(name.replaceAll('\\', '/'));
  n = n.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  while (n.startsWith('.')) {
    n = n.substring(1);
  }
  n = n.replaceAll(RegExp(r'[. ]+$'), '');
  return n.isEmpty ? 'track' : n;
}

/// [dir]/[name], or "[name] (2)" etc. when that is taken: never overwrites.
String uniquePath(String dir, String name) {
  final base = p.basenameWithoutExtension(name), ext = p.extension(name);
  var candidate = p.join(dir, name);
  for (
    var i = 2;
    FileSystemEntity.typeSync(candidate) != FileSystemEntityType.notFound;
    i++
  ) {
    candidate = p.join(dir, '$base ($i)$ext');
  }
  return candidate;
}

class InboxSettings {
  InboxSettings({
    required this.enabled,
    required this.downloads,
    required this.inbox,
  });
  final bool enabled;
  final String downloads, inbox;

  static InboxSettings of(Catalogue cat) => InboxSettings(
    enabled: cat.getSetting('inbox_enabled') == '1',
    downloads: cat.getSetting('inbox_downloads') ?? defaultDownloadsFolder(),
    inbox: cat.getSetting('inbox_folder') ?? defaultInboxFolder(),
  );
}

class InboxService {
  InboxService(this.cat);
  final Catalogue cat;

  InboxSettings get settings => InboxSettings.of(cat);

  /// Checks the two folders make sense together; throws with a plain reason.
  void validate(InboxSettings s) {
    if (!p.isAbsolute(s.downloads) || !p.isAbsolute(s.inbox)) {
      throw InboxException('Choose full folder paths for both folders.');
    }
    final d = pathKey(s.downloads), i = pathKey(s.inbox);
    if (d == i || keyIsWithin(i, d) || keyIsWithin(d, i)) {
      throw InboxException(
        'The Inbox folder must be separate from the downloads folder (not the same, and not inside it).',
      );
    }
  }

  bool _done(File f, FileStat st, [String entry = '']) => cat.db.select(
    'SELECT 1 FROM inbox_imports WHERE source_path=? AND source_size=? AND source_mtime=? AND entry=?',
    [f.path, st.size, st.modified.millisecondsSinceEpoch, entry],
  ).isNotEmpty;

  void _record(
    File f,
    FileStat st,
    String status, {
    String entry = '',
    String? dest,
    String? message,
  }) => cat.db.execute(
    'INSERT OR REPLACE INTO inbox_imports (source_path, source_size, source_mtime, entry, dest_path, status, message, imported_at) '
    'VALUES (?,?,?,?,?,?,?,?)',
    [
      f.path,
      st.size,
      st.modified.millisecondsSinceEpoch,
      entry,
      dest,
      status,
      message,
      nowMs(),
    ],
  );

  /// Finished downloads in the downloads folder not imported yet: audio
  /// files and ZIPs at its top level, unchanged for [settleMs]. Files still
  /// downloading (partial names, or changed moments ago) wait for a later
  /// check.
  List<File> ready({int? now}) {
    final s = settings;
    final dir = Directory(s.downloads);
    if (!dir.existsSync()) return const [];
    final t = now ?? DateTime.now().millisecondsSinceEpoch;
    final out = <File>[];
    for (final e in dir.listSync(followLinks: false)) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (name.startsWith('.') || name.startsWith('~')) continue;
      final ext = p.extension(name).replaceFirst('.', '').toLowerCase();
      if (partialExtensions.contains(ext)) continue;
      if (!_isAudio(name) && !_isZip(name)) continue;
      final FileStat st;
      try {
        st = e.statSync();
      } on FileSystemException {
        continue;
      }
      if (st.size == 0) continue;
      if (t - st.modified.millisecondsSinceEpoch < settleMs) continue;
      if (_done(e, st)) continue;
      out.add(e);
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Copies [src] to [dest] (a new file) and checks the copy byte for byte.
  static void _verifiedCopy(String src, String dest) {
    final part = '$dest.djassistant-part';
    try {
      File(src).copySync(part);
      final a = blake3File(src), b = blake3File(part);
      if (a == null || a != b) {
        throw InboxException('the copy of ${p.basename(src)} did not verify');
      }
      if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
        throw InboxException('${p.basename(dest)} appeared while copying');
      }
      File(part).renameSync(dest);
    } finally {
      final f = File(part);
      if (f.existsSync()) f.deleteSync();
    }
  }

  static void _discard(List<(String, String)> made) {
    for (final (_, path) in made) {
      try {
        File(path).deleteSync();
      } on FileSystemException {
        // already gone
      }
    }
  }

  /// Audio files unpacked from [zip] into [destDir]: (entry, new path).
  static List<(String, String)> _unzip(String zip, String destDir) {
    final input = InputFileStream(zip);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final files = archive.files.where((f) => f.isFile).toList();
      if (files.isEmpty) {
        throw InboxException('the ZIP is empty or damaged');
      }
      if (files.length > maxZipEntries) {
        throw InboxException('the ZIP has too many files (${files.length})');
      }
      var total = 0;
      for (final f in files) {
        if (f.size > maxEntryBytes) {
          throw InboxException('${f.name} in the ZIP is too large');
        }
        total += f.size;
      }
      if (total > maxZipBytes) {
        throw InboxException('the ZIP unpacks to more than 8 GB');
      }
      final out = <(String, String)>[];
      for (final f in files) {
        if (!_isAudio(f.name)) continue; // covers, PDFs, readme files
        final name = safeFileName(f.name);
        Directory(destDir).createSync(recursive: true);
        final dest = uniquePath(destDir, name);
        final part = '$dest.djassistant-part';
        final bytes = f.readBytes();
        if (bytes == null || bytes.length != f.size) {
          throw InboxException('${f.name} could not be read from the ZIP');
        }
        try {
          File(part).writeAsBytesSync(bytes, flush: true);
          if (blake3File(part) != blake3Hex(bytes)) {
            throw InboxException('${f.name} did not unpack correctly');
          }
          File(part).renameSync(dest);
        } finally {
          final pf = File(part);
          if (pf.existsSync()) pf.deleteSync();
        }
        out.add((f.name, dest));
      }
      return out;
    } finally {
      input.closeSync();
    }
  }

  /// The Inbox folder as a library folder (added once). A folder already
  /// inside a library folder is used as it is.
  int ensureRoot(String inbox) {
    Directory(inbox).createSync(recursive: true);
    final key = pathKey(inbox);
    for (final r in RootsService(cat).list()) {
      final rk = pathKey(r.path);
      if (rk == key || keyIsWithin(key, rk)) return r.id;
    }
    try {
      return RootsService(cat).add(inbox).id;
    } on RootException catch (e) {
      throw InboxException(
        'The Inbox folder can’t be added to your library: $e',
      );
    }
  }

  /// Imports every finished download: (copied or unpacked paths, notes).
  (List<String>, List<String>) importReady({
    bool Function()? cancelled,
    void Function(int done, int total, String name)? progress,
  }) {
    final s = settings;
    validate(s);
    final files = ready();
    final day = DateTime.now().toIso8601String().substring(0, 10);
    final destDir = p.join(s.inbox, day);
    final imported = <String>[], notes = <String>[];
    for (var i = 0; i < files.length; i++) {
      if (cancelled?.call() ?? false) break;
      final f = files[i];
      progress?.call(i, files.length, p.basename(f.path));
      final FileStat st;
      try {
        st = f.statSync();
      } on FileSystemException {
        continue;
      }
      // A file still growing (for example copied in by Explorer, which
      // keeps the original's time) is caught here: if it changed while we
      // read it, what we made is discarded and it is tried again later.
      bool changed() {
        try {
          final now = f.statSync();
          return now.size != st.size || now.modified != st.modified;
        } on FileSystemException {
          return true;
        }
      }

      final made = <(String, String)>[];
      try {
        if (_isZip(f.path)) {
          final sub = p.join(
            destDir,
            safeFileName(p.basenameWithoutExtension(f.path)),
          );
          made.addAll(_unzip(f.path, sub));
        } else {
          Directory(destDir).createSync(recursive: true);
          final dest = uniquePath(destDir, safeFileName(p.basename(f.path)));
          _verifiedCopy(f.path, dest);
          made.add(('', dest));
        }
      } on Object catch (e) {
        _discard(made);
        if (changed()) {
          notes.add(
            '${p.basename(f.path)}: still downloading, tried again later',
          );
          continue;
        }
        final msg = e is InboxException ? e.message : '$e';
        _record(f, st, 'error', message: msg);
        notes.add('${p.basename(f.path)}: $msg');
        continue;
      }
      if (changed()) {
        _discard(made);
        notes.add(
          '${p.basename(f.path)}: still downloading, tried again later',
        );
        continue;
      }
      if (_isZip(f.path)) {
        for (final (entry, dest) in made) {
          _record(f, st, 'imported', entry: entry, dest: dest);
        }
        _record(
          f,
          st,
          made.isEmpty ? 'skipped' : 'imported',
          message: made.isEmpty ? 'no audio in the ZIP' : null,
        );
        if (made.isEmpty) notes.add('${p.basename(f.path)}: no audio inside');
      } else {
        _record(f, st, 'imported', dest: made.single.$2);
      }
      imported.addAll([for (final (_, dest) in made) dest]);
    }
    progress?.call(files.length, files.length, '');
    return (imported, notes);
  }

  /// The "Inbox" crate (created the first time).
  Crate inboxCrate() {
    final crates = CratesService(cat);
    for (final c in crates.list()) {
      if (c.name == inboxCrateName && c.kind == 'manual') return c;
    }
    return crates.create(
      const CrateInput(name: inboxCrateName, kind: 'manual'),
    );
  }

  /// Adds the catalogued tracks at [paths] to the Inbox crate.
  int addToCrate(List<String> paths) {
    if (paths.isEmpty) return 0;
    final keys = {for (final x in paths) pathKey(x)};
    final ids = [
      for (final r in cat.db.select('SELECT id, path FROM tracks'))
        if (keys.contains(pathKey(r['path'] as String))) r['id'] as int,
    ];
    if (ids.isEmpty) return 0;
    return CratesService(cat).addTracks(inboxCrate().id, ids);
  }

  /// The latest imports, newest first (for Settings).
  List<Map<String, Object?>> recent({int limit = 20}) => [
    for (final r in cat.db.select(
      "SELECT source_path, entry, dest_path, status, message, imported_at FROM inbox_imports WHERE entry='' OR status<>'imported' "
      'ORDER BY imported_at DESC LIMIT ?',
      [limit],
    ))
      {
        'file': p.basename(r['source_path'] as String),
        'status': r['status'],
        'message': r['message'],
        'at': r['imported_at'],
      },
  ];
}

/// The import job: copies and unpacks finished downloads (in its isolate).
/// Its result lists the new files and the Inbox folder's library id.
JobBody inboxJob(String dbPath) => (ctx) async {
  final cat = Catalogue.open(dbPath);
  try {
    final svc = InboxService(cat);
    final s = svc.settings;
    svc.validate(s);
    final (paths, notes) = svc.importReady(
      cancelled: () => ctx.cancelled,
      progress: (done, total, name) {
        ctx.total = total;
        ctx.progressTo(done);
        ctx.message = name.isEmpty ? 'Imported' : 'Importing $name…';
      },
    );
    final root = paths.isEmpty ? null : svc.ensureRoot(s.inbox);
    ctx
      ..result = {'paths': paths, 'notes': notes, 'root_id': root}
      ..message = paths.isEmpty
          ? (notes.isEmpty ? 'No new downloads.' : notes.join('; '))
          : 'Imported ${paths.length} track(s)${notes.isEmpty ? '' : '; ${notes.length} problem(s)'}.';
  } finally {
    cat.close();
  }
};
