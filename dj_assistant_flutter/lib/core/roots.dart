import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'paths.dart';

class RootException implements Exception {
  RootException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A library folder (1.x `Root`).
class Root {
  Root(Map<String, Object?> r)
    : id = r['id'] as int,
      path = r['path'] as String,
      label = r['label'] as String?,
      status = r['status'] as String,
      addedAt = r['added_at'] as int,
      lastScanAt = r['last_scan_at'] as int?,
      lastScanStatus = r['last_scan_status'] as String?,
      trackCount = r['track_count'] as int;
  final int id;
  final String path;
  final String? label;
  final String status;
  final int addedAt;
  final int? lastScanAt;
  final String? lastScanStatus;
  final int trackCount;
}

/// Library folders. Adding or removing one changes only the catalogue: files on
/// disk are never touched.
class RootsService {
  RootsService(this.cat);
  final Catalogue cat;

  List<Root> list() => cat.db
      .select(
        "SELECT r.id, r.path, r.label, r.status, r.added_at, r.last_scan_at, r.last_scan_status, "
        "(SELECT COUNT(*) FROM tracks t WHERE t.root_id=r.id AND t.presence='present') AS track_count "
        'FROM library_roots r ORDER BY r.path',
      )
      .map(Root.new)
      .toList();

  /// Adds a folder without scanning it. Nested folders are refused so a file is
  /// never catalogued twice.
  Root add(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) throw RootException('folder path is empty');
    if (!p.isAbsolute(trimmed)) {
      throw RootException(
        r'please choose a full folder path (for example D:\Music)',
      );
    }
    final type = FileSystemEntity.typeSync(trimmed, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      throw RootException('cannot open folder: it does not exist');
    }
    if (type != FileSystemEntityType.directory) {
      throw RootException('that path is a file, not a folder');
    }
    final key = pathKey(trimmed);
    for (final r in list()) {
      final rk = pathKey(r.path);
      if (rk == key) {
        throw RootException('this folder is already in your library');
      }
      if (keyIsWithin(key, rk)) {
        throw RootException(
          'this folder is inside an existing library folder (${r.path})',
        );
      }
      if (keyIsWithin(rk, key)) {
        throw RootException(
          'this folder contains an existing library folder (${r.path}); remove that one first',
        );
      }
    }
    final name = p.basename(trimmed);
    cat.db.execute(
      "INSERT INTO library_roots(path, path_key, label, status, added_at) VALUES (?, ?, ?, 'online', ?)",
      [trimmed, key, name.isEmpty ? null : name, nowMs()],
    );
    final id = cat.db.lastInsertRowId;
    return list().firstWhere((r) => r.id == id);
  }

  /// Removes a folder and its catalogue rows. Returns the number of tracks removed.
  int remove(int id) {
    cat.db.execute('BEGIN');
    try {
      cat.db.execute('DELETE FROM tracks WHERE root_id=?', [id]);
      final n = cat.db.updatedRows;
      cat.db.execute('DELETE FROM library_roots WHERE id=?', [id]);
      cat.db.execute('COMMIT');
      return n;
    } catch (_) {
      cat.db.execute('ROLLBACK');
      rethrow;
    }
  }
}
