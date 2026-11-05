import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'tags.dart';

/// Optional folder watching (1.x `watcher.rs`): new or changed music files in
/// online library folders are noted — never touched — so the DJ can scan them,
/// with a suggested place to organise them. Paused in gig mode.
class FolderWatcher {
  FolderWatcher(this.cat);
  final Catalogue cat;
  final _subs = <StreamSubscription<FileSystemEvent>>[];
  final watched = <String>[];

  bool get enabled => cat.getSetting('watch_enabled') == '1';

  void start() {
    stop();
    final roots = cat.db.select(
      "SELECT id, path FROM library_roots WHERE status<>'offline'",
    );
    for (final r in roots) {
      final root = r['path'] as String;
      if (!Directory(root).existsSync()) continue;
      // Recursive watching is native on Windows and macOS; elsewhere each folder is watched.
      final dirs = Platform.isLinux
          ? [
              root,
              ...Directory(root)
                  .listSync(recursive: true, followLinks: false)
                  .whereType<Directory>()
                  .map((d) => d.path),
            ]
          : [root];
      for (final d in dirs) {
        try {
          _subs.add(
            Directory(d)
                .watch(recursive: !Platform.isLinux)
                .listen((e) => _event(r['id'] as int, e)),
          );
        } on FileSystemException {
          // a folder that cannot be watched is skipped
        }
      }
      watched.add(root);
    }
  }

  void _event(int rootId, FileSystemEvent e) {
    if (e is! FileSystemCreateEvent &&
        e is! FileSystemModifyEvent &&
        e is! FileSystemMoveEvent) {
      return;
    }
    if (cat.getSetting('gig_mode') == '1') return;
    final path = e is FileSystemMoveEvent ? (e.destination ?? e.path) : e.path;
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    final name = p.basename(path);
    if (classifyExtension(ext) == ExtKind.other || !File(path).existsSync()) {
      return;
    }
    if (name.startsWith('.') || name.contains('.djassistant-')) return;
    final known = cat.db.select('SELECT 1 FROM tracks WHERE path=?', [
      path,
    ]).isNotEmpty;
    cat.db.execute(
      'INSERT INTO watch_events(root_id, path, kind, at) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET at=excluded.at',
      [rootId, path, known ? 'changed' : 'new', nowMs()],
    );
  }

  void stop() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    watched.clear();
  }

  /// Files noticed since the last scan, with an organisation suggestion.
  List<Map<String, Object?>> pending() => [
    for (final r in cat.db.select(
      'SELECT w.id, w.root_id, w.path, w.kind, w.at, r.path AS root FROM watch_events w LEFT JOIN library_roots r ON r.id=w.root_id ORDER BY w.at DESC LIMIT 300',
    ))
      () {
        AudioMeta? m;
        try {
          m = readMediaMeta(r['path'] as String);
        } on Exception {
          m = null;
        }
        final suggested = m?.artist == null
            ? null
            : p.join(
                (r['root'] as String?) ?? '',
                m!.genre ?? 'Unsorted',
                m.artist,
              );
        return {
          'id': r['id'],
          'root_id': r['root_id'],
          'path': r['path'],
          'kind': r['kind'],
          'at': r['at'], //
          'artist': m?.artist,
          'title': m?.title,
          'genre': m?.genre,
          'suggested_folder': suggested,
          'note': "Suggestion only. DJ Assistant does not move files; moving them would break Serato's links to them.",
        };
      }(),
  ];

  int clear({int? rootId}) {
    if (rootId == null) {
      cat.db.execute('DELETE FROM watch_events');
    } else {
      cat.db.execute('DELETE FROM watch_events WHERE root_id=?', [rootId]);
    }
    return cat.db.updatedRows;
  }
}
