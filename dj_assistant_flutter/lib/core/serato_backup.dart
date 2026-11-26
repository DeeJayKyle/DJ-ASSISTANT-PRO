import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'paths.dart';
import 'serato_library.dart';

/// One ZIP backup of a `_Serato_` folder's crates and library.
class SeratoBackup {
  SeratoBackup(this.file, this.at, this.bytes, this.source, this.reason);
  final String file;
  final DateTime at;
  final int bytes;

  /// The `_Serato_` folder it was taken from.
  final String source;

  /// What was about to change ("Rename crate", "Write templates"…).
  final String reason;
}

/// Timestamped ZIP backups of `_Serato_/Subcrates` and `database V2`, taken
/// before every change the app makes to Serato's files. The newest [keep]
/// are kept.
class SeratoBackups {
  SeratoBackups(this.dir, {this.keep = 20});
  final String dir;
  final int keep;

  static const _manifest = 'dj-assistant-backup.txt';
  static const _db = 'database V2';

  /// Zips the crates and library of [seratoDir]. Returns the backup.
  SeratoBackup create(String seratoDir, {String reason = ''}) {
    final archive = Archive();
    final sub = Directory(p.join(seratoDir, 'Subcrates'));
    if (sub.existsSync()) {
      for (final f in sub.listSync().whereType<File>()) {
        if (!f.path.toLowerCase().endsWith('.crate')) continue;
        archive.addFile(
          ArchiveFile.bytes(
            'Subcrates/${p.basename(f.path)}',
            f.readAsBytesSync(),
          ),
        );
      }
    }
    final db = File(p.join(seratoDir, _db));
    if (db.existsSync()) {
      archive.addFile(ArchiveFile.bytes(_db, db.readAsBytesSync()));
    }
    final at = DateTime.now();
    archive.addFile(
      ArchiveFile.bytes(
        _manifest,
        utf8.encode(
          'source=${p.absolute(seratoDir)}\n'
          'at=${at.toIso8601String()}\n'
          'reason=${reason.replaceAll('\n', ' ')}\n',
        ),
      ),
    );
    final bytes = ZipEncoder().encode(archive);
    Directory(dir).createSync(recursive: true);
    final stamp = at
        .toIso8601String()
        .replaceAll(RegExp(r'[-:]'), '')
        .replaceAll('T', '-')
        .replaceAll('.', '-');
    var file = p.join(dir, 'serato-$stamp.zip');
    for (var i = 2; File(file).existsSync(); i++) {
      file = p.join(dir, 'serato-$stamp-$i.zip');
    }
    final tmp = '$file.part';
    File(tmp).writeAsBytesSync(bytes, flush: true);
    File(tmp).renameSync(file);
    prune();
    return SeratoBackup(file, at, bytes.length, p.absolute(seratoDir), reason);
  }

  /// Every backup, newest first. With [seratoDir], only that folder's.
  List<SeratoBackup> list({String? seratoDir}) {
    final d = Directory(dir);
    if (!d.existsSync()) return const [];
    final out = <SeratoBackup>[];
    for (final f in d.listSync().whereType<File>()) {
      if (!f.path.endsWith('.zip')) continue;
      final b = _read(f);
      if (b == null) continue;
      if (seratoDir != null && pathKey(b.source) != pathKey(seratoDir)) {
        continue;
      }
      out.add(b);
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }

  SeratoBackup? _read(File f) {
    try {
      final a = ZipDecoder().decodeBytes(f.readAsBytesSync());
      final m = a.findFile(_manifest);
      if (m == null) return null;
      final fields = <String, String>{};
      for (final line
          in utf8.decode(m.content, allowMalformed: true).split('\n')) {
        final i = line.indexOf('=');
        if (i > 0) fields[line.substring(0, i)] = line.substring(i + 1);
      }
      return SeratoBackup(
        f.path,
        DateTime.tryParse(fields['at'] ?? '') ?? f.lastModifiedSync(),
        f.lengthSync(),
        fields['source'] ?? '',
        fields['reason'] ?? '',
      );
    } on Object {
      return null;
    }
  }

  /// Deletes all but the newest [keep] backups.
  void prune() {
    final all = list();
    for (final b in all.skip(keep)) {
      try {
        File(b.file).deleteSync();
      } on FileSystemException {
        // in use: removed next time
      }
    }
  }

  /// Puts [backup]'s crates and library back into [seratoDir]: every crate
  /// there now is replaced by the backup's. Call through
  /// [SeratoLibrary.restore], which checks Serato is closed and backs up the
  /// current state first.
  void restoreInto(SeratoBackup backup, String seratoDir) {
    final a = ZipDecoder().decodeBytes(File(backup.file).readAsBytesSync());
    final crates = <String, Uint8List>{};
    Uint8List? db;
    for (final f in a.files) {
      if (!f.isFile) continue;
      if (f.name == _db) {
        db = f.content;
      } else if (f.name.startsWith('Subcrates/') &&
          f.name.toLowerCase().endsWith('.crate') &&
          !f.name.substring(10).contains('/') &&
          !f.name.contains('..')) {
        crates[f.name.substring(10)] = f.content;
      }
    }
    final sub = Directory(p.join(seratoDir, 'Subcrates'))
      ..createSync(recursive: true);
    for (final f in sub.listSync().whereType<File>()) {
      if (f.path.toLowerCase().endsWith('.crate')) f.deleteSync();
    }
    for (final e in crates.entries) {
      _atomic(p.join(sub.path, e.key), e.value);
    }
    if (db != null) _atomic(p.join(seratoDir, _db), db);
  }
}

void _atomic(String path, List<int> bytes) {
  final tmp = '$path.djassistant-tmp';
  File(tmp).writeAsBytesSync(bytes, flush: true);
  File(tmp).renameSync(path);
}
