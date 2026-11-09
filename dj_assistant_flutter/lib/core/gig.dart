import 'catalogue.dart';
import 'jobs.dart';
import 'serato.dart';
import 'track_match.dart';

/// Gig mode (1.x `gig.rs`): an offline-first session with a request queue, notes
/// and a play log, then a recap. While a gig runs, background work is paused.
class GigException implements Exception {
  GigException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw GigException(m);

class GigService {
  GigService(this.cat, {this.jobs});
  final Catalogue cat;
  final JobsController? jobs;

  bool get active => cat.getSetting('gig_mode') == '1';

  Map<String, Object?>? current() {
    final r = cat.db.select(
      'SELECT id, name, set_plan_id, started_at FROM gigs WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1',
    );
    if (r.isEmpty) return null;
    final g = r.first;
    return {
      'id': g['id'],
      'name': g['name'],
      'set_plan_id': g['set_plan_id'],
      'started_at': g['started_at'],
      'events': _events(g['id'] as int),
    };
  }

  int start(String name, {int? setPlanId}) {
    if (current() != null) _no('a gig is already running; end it first');
    final n = name.trim().isEmpty
        ? 'Gig'
        : String.fromCharCodes(name.trim().runes.take(120));
    cat.db.execute(
      'INSERT INTO gigs(name, set_plan_id, started_at) VALUES (?,?,?)',
      [n, setPlanId, nowMs()],
    );
    final id = cat.db.lastInsertRowId;
    cat.setSetting('gig_mode', '1');
    jobs?.pauseAll(true);
    return id;
  }

  int? end() {
    final r = cat.db.select(
      'SELECT id FROM gigs WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1',
    );
    final id = r.isEmpty ? null : r.first['id'] as int;
    if (id != null) {
      cat.db.execute('UPDATE gigs SET ended_at=? WHERE id=?', [nowMs(), id]);
    }
    cat.setSetting('gig_mode', '0');
    jobs?.pauseAll(false);
    return id;
  }

  int addEvent(String kind, {int? trackId, String? text}) {
    if (!['played', 'request', 'note'].contains(kind)) _no('unknown event');
    final r = cat.db.select(
      'SELECT id FROM gigs WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1',
    );
    if (r.isEmpty) _no('start a gig first');
    final t0 = text?.trim();
    final t = (t0 == null || t0.isEmpty)
        ? null
        : String.fromCharCodes(t0.runes.take(2000));
    if (kind != 'played' && t == null && trackId == null) {
      _no('write something first');
    }
    cat.db.execute(
      'INSERT INTO gig_events(gig_id, kind, track_id, text, status, at) VALUES (?,?,?,?,?,?)',
      [
        r.first['id'],
        kind,
        trackId,
        t,
        kind == 'request' ? 'pending' : null,
        nowMs(),
      ],
    );
    return cat.db.lastInsertRowId;
  }

  void setRequest(int id, String status, {int? trackId}) {
    if (!['pending', 'played', 'declined', 'queued'].contains(status)) {
      _no('bad status');
    }
    cat.db.execute(
      "UPDATE gig_events SET status=?, track_id=COALESCE(?, track_id) WHERE id=? AND kind='request'",
      [status, trackId, id],
    );
    if (status == 'played') {
      final t =
          trackId ??
          cat.db.select('SELECT track_id FROM gig_events WHERE id=?', [
                id,
              ]).firstOrNull?['track_id']
              as int?;
      if (t != null) addEvent('played', trackId: t, text: 'Request');
    }
  }

  /// Logs as played, in order, each track Serato played since the gig
  /// started (or since the last one logged this way) that is in the
  /// library. Returns the ids logged. Serato's database is only read, from
  /// a copy.
  List<int> followSerato(String dbPath) {
    final r = cat.db.select(
      'SELECT id, started_at FROM gigs WHERE ended_at IS NULL ORDER BY id DESC LIMIT 1',
    );
    if (r.isEmpty) return const [];
    final gig = r.first['id'] as int;
    final last =
        cat.db.select(
              "SELECT MAX(at) AS at FROM gig_events WHERE gig_id=? AND kind='played' AND text='Serato'",
              [gig],
            ).first['at']
            as int?;
    final since = last == null ? r.first['started_at'] as int : last + 1;
    final plays = SeratoService(cat).seratoPlaysSince(dbPath, since);
    if (plays.isEmpty) return const [];
    final matcher = TrackMatcher(libraryMatchTracks(cat));
    final logged = <int>[];
    for (final pl in plays) {
      final m = matcher.match(
        MatchEntry(path: pl.path, artist: pl.artist, title: pl.title),
      );
      if (m == null) continue;
      cat.db.execute(
        "INSERT INTO gig_events(gig_id, kind, track_id, text, status, at) VALUES (?, 'played', ?, 'Serato', NULL, ?)",
        [gig, m.trackId, pl.atMs < since ? since : pl.atMs],
      );
      logged.add(m.trackId);
    }
    return logged;
  }

  void deleteEvent(int id) =>
      cat.db.execute('DELETE FROM gig_events WHERE id=?', [id]);

  List<Map<String, Object?>> _events(int gig) => [
    for (final r in cat.db.select(
      'SELECT e.id, e.kind, e.track_id, e.text, e.status, e.at, '
      "COALESCE(COALESCE(u.artist,t.artist) || ' — ', '') || COALESCE(u.title,t.title,t.file_name) AS track "
      'FROM gig_events e LEFT JOIN tracks t ON t.id=e.track_id LEFT JOIN track_user u ON u.track_id=t.id WHERE e.gig_id=? ORDER BY e.at, e.id',
      [gig],
    ))
      Map<String, Object?>.of(r),
  ];

  List<Map<String, Object?>> list() => [
    for (final r in cat.db.select(
      "SELECT g.id, g.name, g.started_at, g.ended_at, (SELECT COUNT(*) FROM gig_events e WHERE e.gig_id=g.id AND e.kind='played') AS played FROM gigs g ORDER BY g.id DESC LIMIT 100",
    ))
      Map<String, Object?>.of(r),
  ];

  Map<String, Object?> recap(int id) {
    final r = cat.db.select(
      'SELECT name, started_at, ended_at FROM gigs WHERE id=?',
      [id],
    );
    if (r.isEmpty) _no('gig not found');
    final evs = _events(id);
    final played = evs.where((e) => e['kind'] == 'played').toList();
    final genres = <String, int>{};
    final energy = <Map<String, Object?>>[];
    for (final e in played) {
      final tid = e['track_id'] as int?;
      if (tid == null) continue;
      final x = cat.db.select(
        'SELECT COALESCE(u.genre,t.genre) AS g, COALESCE(u.energy,a.energy) AS en FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id LEFT JOIN analysis a ON a.track_id=t.id WHERE t.id=?',
        [tid],
      ).firstOrNull;
      final g = (x?['g'] as String?) ?? 'Unknown';
      genres[g] = (genres[g] ?? 0) + 1;
      energy.add({'at': e['at'], 'energy': x?['en']});
    }
    final requests = evs.where((e) => e['kind'] == 'request').toList();
    final started = r.first['started_at'] as int,
        ended = r.first['ended_at'] as int?;
    final g = genres.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      'id': id,
      'name': r.first['name'],
      'started_at': started,
      'ended_at': ended,
      'duration_ms': (ended ?? nowMs()) - started, //
      'played': played,
      'played_count': played.length,
      'genres': [
        for (final e in g) {'genre': e.key, 'count': e.value},
      ],
      'energy': energy, 'requests': requests, 'requests_total': requests.length,
      'requests_fulfilled': requests
          .where((x) => x['status'] == 'played')
          .length,
      'notes': evs.where((e) => e['kind'] == 'note').toList(),
    };
  }

  String recapMarkdown(int id) {
    final r = recap(id);
    final s = StringBuffer('# ${r['name'] ?? 'Gig'}\n\n')
      ..write(
        '- Duration: ${(r['duration_ms'] as int) ~/ 60000} min\n- Tracks played: ${r['played_count']}\n',
      )
      ..write(
        '- Requests: ${r['requests_total']} (${r['requests_fulfilled']} played)\n\n## Played\n\n',
      );
    final played = r['played'] as List;
    for (var i = 0; i < played.length; i++) {
      s.write('${i + 1}. ${(played[i] as Map)['track'] ?? '(unknown)'}\n');
    }
    s.write('\n## Genres\n\n');
    for (final g in r['genres'] as List) {
      s.write('- ${(g as Map)['genre']}: ${g['count']}\n');
    }
    final notes = r['notes'] as List;
    if (notes.isNotEmpty) {
      s.write('\n## Notes\n\n');
      for (final n in notes) {
        s.write('- ${(n as Map)['text'] ?? ''}\n');
      }
    }
    return s.toString();
  }
}
