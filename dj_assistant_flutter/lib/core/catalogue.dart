import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'keys.dart';
import 'migrations.g.dart';
import 'text.dart';

int nowMs() => DateTime.now().millisecondsSinceEpoch;

/// The catalogue database of one account. Same file and schema as DJ Assistant 1.x
/// (`catalogue.sqlite3`), so an existing library opens unchanged.
class Catalogue {
  Catalogue._(this.db);
  final Database db;

  /// Opens (creating if needed) the catalogue at [path] and applies migrations.
  factory Catalogue.open(String path) {
    Directory(File(path).parent.path).createSync(recursive: true);
    return Catalogue._configure(sqlite3.open(path));
  }

  factory Catalogue.inMemory() => Catalogue._configure(sqlite3.openInMemory());

  factory Catalogue._configure(Database db) {
    db.execute('PRAGMA busy_timeout = 10000');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA foreign_keys = ON');
    // Defence in depth: user text is always bound; also refuse untrusted schema code.
    db.execute('PRAGMA trusted_schema = OFF');
    db.createFunction(
      functionName: 'fold',
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
      directOnly: false,
      function: (args) => args[0] == null ? null : fold(args[0].toString()),
    );
    // keynorm(x): any key spelling -> Camelot code, or the text unchanged.
    db.createFunction(
      functionName: 'keynorm',
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
      directOnly: false,
      function: (args) {
        final v = args[0];
        if (v == null) return null;
        final s = v.toString();
        return normalizeKey(s) ?? s;
      },
    );
    final c = Catalogue._(db);
    c._migrate();
    return c;
  }

  int get schemaVersion =>
      db.select('PRAGMA user_version').first.columnAt(0) as int;

  void _migrate() {
    final current = schemaVersion;
    for (var i = 0; i < migrations.length; i++) {
      final version = i + 1;
      if (version <= current) continue;
      db.execute('BEGIN');
      try {
        db.execute(migrations[i]);
        db.execute('PRAGMA user_version = $version');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }
    // Songs the DJ removed from the library (scans skip these paths). Kept
    // outside the numbered migrations, like the indexes below.
    db.execute(
      'CREATE TABLE IF NOT EXISTS hidden_tracks (path_key TEXT PRIMARY KEY, '
      'path TEXT, artist TEXT, title TEXT, hidden_at INTEGER NOT NULL)',
    );
    // What each accepted suggestion replaced, so it can be undone exactly, and
    // who accepted it (the DJ or auto-prep). Outside the numbered migrations,
    // so 1.x can still open the catalogue.
    db.execute(
      'CREATE TABLE IF NOT EXISTS suggestion_decisions (suggestion_id INTEGER PRIMARY KEY, '
      'track_id INTEGER NOT NULL, field TEXT NOT NULL, had_override INTEGER NOT NULL, '
      "previous_value TEXT, applied_value TEXT, decided_by TEXT NOT NULL CHECK (decided_by IN ('you','auto')), "
      'at INTEGER NOT NULL, undone_at INTEGER)',
    );
    // Speed-only indexes, created outside the numbered migrations so the
    // schema version stays the one 1.x knows (it ignores extra indexes).
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_gig_events_track ON gig_events(track_id, kind)',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_gig_events_gig ON gig_events(gig_id, kind, at)',
    );
    // A scan still marked running belongs to a session that was interrupted (crash,
    // power loss): say so honestly.
    db.execute(
      "UPDATE scans SET status='interrupted', finished_at=?, message=COALESCE(message,"
      "'App closed or crashed during scan; rows written before the interruption are intact.') "
      "WHERE status='running'",
      [nowMs()],
    );
  }

  String? getSetting(String key) {
    final r = db.select('SELECT value FROM settings WHERE key=?', [key]);
    return r.isEmpty ? null : r.first['value'] as String?;
  }

  void setSetting(String key, String value) => db.execute(
    'INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );

  void close() => db.close();
}
