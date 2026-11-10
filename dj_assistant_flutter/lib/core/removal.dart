import 'catalogue.dart';

/// Removing songs from the library. The song leaves the catalogue (with its
/// crates, tags, ratings and analysis) and its path is remembered, so later
/// scans skip the file. The music file itself is not touched; deleting the
/// file is a separate, opt-in step through Organise Files' restorable
/// "Removed files" area. Hidden songs can be brought back: they return on
/// the next scan.
class RemovalService {
  RemovalService(this.cat);
  final Catalogue cat;

  /// Removes [ids] from the library. Returns how many were removed.
  int removeFromLibrary(List<int> ids) {
    if (ids.isEmpty) return 0;
    var n = 0;
    cat.db.execute('BEGIN');
    try {
      for (final id in ids) {
        final r = cat.db.select(
          'SELECT t.path, t.path_key, COALESCE(u.artist,t.artist) AS artist, '
          'COALESCE(u.title,t.title,t.file_name) AS title FROM tracks t '
          'LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?',
          [id],
        );
        if (r.isEmpty) continue;
        cat.db.execute(
          'INSERT OR REPLACE INTO hidden_tracks(path_key, path, artist, title, hidden_at) VALUES (?,?,?,?,?)',
          [
            r.first['path_key'],
            r.first['path'],
            r.first['artist'],
            r.first['title'],
            nowMs(),
          ],
        );
        cat.db.execute('DELETE FROM tracks WHERE id=?', [id]);
        n++;
      }
      cat.db.execute('COMMIT');
    } catch (_) {
      cat.db.execute('ROLLBACK');
      rethrow;
    }
    return n;
  }

  /// Songs removed from the library, newest first.
  List<Map<String, Object?>> hidden({int limit = 1000}) => [
    for (final r in cat.db.select(
      'SELECT path_key, path, artist, title, hidden_at FROM hidden_tracks ORDER BY hidden_at DESC LIMIT ?',
      [limit],
    ))
      Map<String, Object?>.of(r),
  ];

  /// Lets these songs back in; they return on the next scan.
  int restore(List<String> pathKeys) {
    var n = 0;
    for (final k in pathKeys) {
      cat.db.execute('DELETE FROM hidden_tracks WHERE path_key=?', [k]);
      n += cat.db.updatedRows;
    }
    return n;
  }

  /// Path keys the scanner must skip.
  Set<String> hiddenKeys() => {
    for (final r in cat.db.select('SELECT path_key FROM hidden_tracks'))
      r['path_key'] as String,
  };
}
