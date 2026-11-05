import 'dart:io';

import 'blake3.dart';
import 'catalogue.dart';
import 'jobs.dart';
import 'library.dart';

/// Conservative duplicate review (1.x `duplicates.rs`). Nothing here deletes,
/// merges or changes files.
///
/// * `exact`: identical full-file BLAKE3 hash.
/// * `possible`: same normalised artist + title, same version label, durations
///   within [durationToleranceMs]. Needs the DJ's review.
/// * `alternate`: same artist + title, different version labels (remix, live,
///   clean, radio edit…). Probably intentional.
const durationToleranceMs = 2000;
const dupDecisions = [
  'not_duplicate',
  'intentional_version',
  'confirmed_duplicate',
];

class DupGroup {
  DupGroup(this.kind, this.key, this.reason, this.decision, this.tracks);
  final String kind, key, reason;
  final String? decision;
  final List<TrackRow> tracks;
}

class DuplicateException implements Exception {
  DuplicateException(this.message);
  final String message;
  @override
  String toString() => message;
}

String groupKey(String kind, List<int> ids) =>
    '$kind:${([...ids]..sort()).join(',')}';

class DuplicatesService {
  DuplicatesService(this.cat);
  final Catalogue cat;

  /// Files that share their exact size with another file and have no current
  /// hash: only those can be byte-identical.
  List<(int, String, int, int?)> hashCandidates() => cat.db
      .select(
        'SELECT t.id, t.path, t.file_size, t.file_mtime FROM tracks t JOIN library_roots r ON r.id=t.root_id '
        "WHERE t.presence='present' AND r.status<>'offline' AND t.file_size > 0 "
        "AND t.file_size IN (SELECT file_size FROM tracks WHERE presence='present' GROUP BY file_size HAVING COUNT(*) > 1) "
        'AND (t.content_hash IS NULL OR t.hash_size IS NOT t.file_size OR t.hash_mtime IS NOT t.file_mtime)',
      )
      .map(
        (r) => (
          r['id'] as int,
          r['path'] as String,
          r['file_size'] as int,
          r['file_mtime'] as int?,
        ),
      )
      .toList();

  /// Hashes one candidate (read-only); false when the file changed since the scan.
  bool hashOne(
    int id,
    String path,
    int size,
    int? mtime, {
    bool Function()? cancelled,
  }) {
    final st = File(path).statSync();
    if (st.type != FileSystemEntityType.file || st.size != size) return false;
    final h = blake3File(path, cancelled: cancelled);
    if (h == null) return false;
    cat.db.execute(
      'UPDATE tracks SET content_hash=?, hash_size=?, hash_mtime=? WHERE id=?',
      [h, size, mtime, id],
    );
    return true;
  }

  List<TrackRow> _rows(List<int> ids) {
    final page = LibraryService(cat).search(
      TrackQuery(
        includeMissing: true,
        limit: ids.length,
        extraWhere: (
          't.id IN (${List.filled(ids.length, '?').join(',')})',
          ids,
        ),
      ),
    );
    final byId = {for (final r in page.rows) r.id: r};
    return [
      for (final id in ids)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Every duplicate group: exact ones need a current full-file hash; possible and
  /// alternate ones are metadata candidates.
  List<DupGroup> findGroups({int maxGroups = 500}) {
    final dec = {
      for (final r in cat.db.select(
        'SELECT pair_key, decision FROM duplicate_reviews',
      ))
        r['pair_key'] as String: r['decision'] as String,
    };
    final groups = <DupGroup>[];
    final exactSets = <Set<int>>[];
    for (final r in cat.db.select(
      "SELECT content_hash, GROUP_CONCAT(id) AS ids FROM tracks WHERE presence='present' AND content_hash IS NOT NULL "
      'AND hash_size = file_size AND hash_mtime IS file_mtime GROUP BY content_hash HAVING COUNT(*) > 1 LIMIT ?',
      [maxGroups],
    )) {
      final ids = (r['ids'] as String).split(',').map(int.parse).toList();
      final key = groupKey('exact', ids);
      exactSets.add(ids.toSet());
      groups.add(
        DupGroup(
          'exact',
          key,
          'Identical file contents: full-file BLAKE3 hash ${(r['content_hash'] as String).substring(0, 12)}… matches for all ${ids.length} files.',
          dec[key],
          _rows(ids),
        ),
      );
    }

    final byKey = <String, List<(int, int?, String)>>{};
    for (final r in cat.db.select(
      "SELECT t.work_key, t.id, t.duration_ms, COALESCE(u.version_label, t.version_hint, '') AS ver FROM tracks t "
      "LEFT JOIN track_user u ON u.track_id=t.id WHERE t.presence='present' AND t.read_status='ok' AND t.work_key IS NOT NULL "
      "AND t.work_key IN (SELECT work_key FROM tracks WHERE presence='present' AND work_key IS NOT NULL GROUP BY work_key HAVING COUNT(*) > 1) "
      'ORDER BY t.work_key, t.id',
    )) {
      (byKey[r['work_key'] as String] ??= []).add((
        r['id'] as int,
        r['duration_ms'] as int?,
        r['ver'] as String,
      ));
    }
    for (final e in byKey.entries) {
      if (groups.length >= maxGroups) break;
      final k = e.key, members = e.value;
      final byVersion = <String, List<(int, int?, String)>>{};
      for (final m in members) {
        (byVersion[m.$3] ??= []).add(m);
      }
      final bar = k.indexOf('|');
      final artist = bar < 0 ? '' : k.substring(0, bar),
          title = bar < 0 ? k : k.substring(bar + 1);
      for (final v in byVersion.entries) {
        final ms = v.value;
        final used = List.filled(ms.length, false);
        for (var i = 0; i < ms.length; i++) {
          if (used[i]) continue;
          final di = ms[i].$2;
          if (di == null) continue;
          final cluster = [ms[i].$1];
          for (var j = i + 1; j < ms.length; j++) {
            final dj = ms[j].$2;
            if (!used[j] &&
                dj != null &&
                (di - dj).abs() <= durationToleranceMs) {
              used[j] = true;
              cluster.add(ms[j].$1);
            }
          }
          if (cluster.length < 2) continue;
          cluster.sort();
          // Skip when every member is already in one exact group.
          if (exactSets.any((s) => cluster.every(s.contains))) continue;
          final key = groupKey('possible', cluster);
          final vtxt = v.key.isEmpty
              ? 'no version label'
              : 'version label "${v.key}"';
          groups.add(
            DupGroup(
              'possible',
              key,
              'Same artist ("$artist") and title ("$title") after normalising case/accents/featuring credits, $vtxt, '
                  'and durations within ${durationToleranceMs ~/ 1000} s. Contents were not proven identical.',
              dec[key],
              _rows(cluster),
            ),
          );
        }
      }
      if (byVersion.length > 1) {
        final ids = [for (final m in members) m.$1]..sort();
        final labels = [
          for (final v in byVersion.keys) v.isEmpty ? 'unlabelled' : v,
        ]..sort();
        final key = groupKey('alternate', ids);
        groups.add(
          DupGroup(
            'alternate',
            key,
            'Same artist and title but different version labels (${labels.join(', ')}). These are probably intentional alternate versions — review before treating any as a duplicate.',
            dec[key],
            _rows(ids),
          ),
        );
      }
    }
    return groups;
  }

  void setDecision(String key, String? decision) {
    if (key.length > 4000 ||
        !(key.startsWith('exact:') ||
            key.startsWith('possible:') ||
            key.startsWith('alternate:'))) {
      throw DuplicateException('invalid group key');
    }
    if (decision == null) {
      cat.db.execute('DELETE FROM duplicate_reviews WHERE pair_key=?', [key]);
    } else if (dupDecisions.contains(decision)) {
      cat.db.execute(
        'INSERT INTO duplicate_reviews(pair_key, decision, decided_at) VALUES (?,?,?) '
        'ON CONFLICT(pair_key) DO UPDATE SET decision=excluded.decision, decided_at=excluded.decided_at',
        [key, decision, nowMs()],
      );
    } else {
      throw DuplicateException('unknown decision');
    }
  }
}

/// The hashing job body (runs in a JobsController isolate).
JobBody hashJob(String dbPath) => (ctx) async {
  final cat = Catalogue.open(dbPath);
  try {
    final svc = DuplicatesService(cat);
    final todo = svc.hashCandidates();
    ctx.total = todo.length;
    for (final (id, path, size, mtime) in todo) {
      if (await ctx.checkpoint()) break;
      bool ok;
      try {
        ok = svc.hashOne(id, path, size, mtime, cancelled: () => ctx.cancelled);
      } on FileSystemException {
        ok = false;
      }
      ctx.tick(ok: ok);
    }
  } finally {
    cat.close();
  }
};
