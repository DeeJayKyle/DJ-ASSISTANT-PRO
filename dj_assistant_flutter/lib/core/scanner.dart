import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'catalogue.dart';
import 'paths.dart';
import 'tags.dart';
import 'text.dart';

/// Read-only library scanner, ported from 1.x `scanner.rs`. The same guarantees:
///
/// * Music files are only ever opened for reading.
/// * Links and junctions are not followed, so folder loops are impossible.
/// * Catalogue writes happen in short transactions, so a cancelled or interrupted
///   scan leaves a consistent catalogue.
/// * A folder that is unavailable (unplugged drive) is marked offline and its tracks
///   are kept; tracks are only marked missing after a completed scan of an online
///   folder, and never deleted.

/// Pause and cancel flags. The scan checks them between files.
class ScanControl {
  bool cancelled = false;
  bool paused = false;

  /// Lets control messages in, then waits while paused.
  Future<void> checkpoint() async {
    await Future<void>.delayed(Duration.zero);
    while (paused && !cancelled) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

class ScanProgress {
  String state =
      'idle'; // idle | running | paused | completed | cancelled | failed
  int? scanId;
  String phase = 'discovering'; // discovering | reading | finalising | done
  String? currentRoot, currentPath;
  int filesFound = 0, filesToRead = 0, filesProcessed = 0;
  int added = 0,
      updated = 0,
      unchanged = 0,
      missing = 0,
      errors = 0,
      offlineRoots = 0;
  int? startedAt, finishedAt;
  String? message;

  Map<String, Object?> toJson() => {
    'state': state,
    'scan_id': scanId,
    'phase': phase,
    'current_root': currentRoot,
    'current_path': currentPath,
    'files_found': filesFound,
    'files_to_read': filesToRead,
    'files_processed': filesProcessed,
    'added': added,
    'updated': updated,
    'unchanged': unchanged,
    'missing': missing,
    'errors': errors,
    'offline_roots': offlineRoots,
    'started_at': startedAt,
    'finished_at': finishedAt,
    'message': message,
  };

  static ScanProgress fromJson(Map<String, Object?> j) => ScanProgress()
    ..state = j['state'] as String
    ..scanId = j['scan_id'] as int?
    ..phase = j['phase'] as String
    ..currentRoot = j['current_root'] as String?
    ..currentPath = j['current_path'] as String?
    ..filesFound = j['files_found'] as int
    ..filesToRead = j['files_to_read'] as int
    ..filesProcessed = j['files_processed'] as int
    ..added = j['added'] as int
    ..updated = j['updated'] as int
    ..unchanged = j['unchanged'] as int
    ..missing = j['missing'] as int
    ..errors = j['errors'] as int
    ..offlineRoots = j['offline_roots'] as int
    ..startedAt = j['started_at'] as int?
    ..finishedAt = j['finished_at'] as int?
    ..message = j['message'] as String?;
}

class _Candidate {
  _Candidate(
    this.path,
    this.key,
    this.rel,
    this.fileName,
    this.ext,
    this.size,
    this.mtime,
    this.unsupported,
    this.existingId,
  );
  final String path, key, rel, fileName, ext;
  final int size;
  final int? mtime;
  final bool unsupported;
  final int? existingId;
}

sealed class _Outcome {}

class _Read extends _Outcome {
  _Read(this.meta);
  final AudioMeta meta;
}

class _Failed extends _Outcome {
  _Failed(this.message);
  final String message;
}

class _Unsupported extends _Outcome {}

var _uidCounter = 0;

/// A new 20-character track uid (random enough; never derived from content).
String newUid(String seed) {
  _uidCounter++;
  final s = '$seed|${DateTime.now().microsecondsSinceEpoch}|$_uidCounter|$pid';
  return sha256.convert(utf8.encode(s)).toString().substring(0, 20);
}

class _Scan {
  _Scan(
    this.db,
    this.scanId,
    this.ctl,
    this.progress,
    this.onProgress,
    this.scanVideo,
  );
  final Database db;
  final int scanId;
  final ScanControl ctl;
  final ScanProgress progress;
  final void Function(ScanProgress)? onProgress;
  final bool scanVideo;
  var _lastEmit = 0;

  void emit({bool force = false}) {
    progress.state = ctl.paused ? 'paused' : 'running';
    final now = nowMs();
    if (force || now - _lastEmit >= 100) {
      _lastEmit = now;
      onProgress?.call(progress);
    }
  }

  void error(int? rootId, String path, String kind, String msg) {
    db.execute(
      'INSERT INTO scan_errors(scan_id, root_id, path, kind, message, at) VALUES (?,?,?,?,?,?)',
      [scanId, rootId, path, kind, msg, nowMs()],
    );
    progress.errors++;
    emit();
  }

  void tx(void Function() body) {
    db.execute('BEGIN IMMEDIATE');
    try {
      body();
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

bool _rootAvailable(String path) =>
    FileSystemEntity.typeSync(path, followLinks: true) ==
    FileSystemEntityType.directory;

/// Scans [rootIds] (or every folder) into [cat]. Completes when the scan ends.
Future<ScanProgress> runScan(
  Catalogue cat, {
  List<int>? rootIds,
  ScanControl? control,
  void Function(ScanProgress)? onProgress,
}) async {
  final ctl = control ?? ScanControl();
  final db = cat.db;
  final started = nowMs();
  db.execute("INSERT INTO scans(started_at, status) VALUES (?, 'running')", [
    started,
  ]);
  final progress = ScanProgress()
    ..state = 'running'
    ..scanId = db.lastInsertRowId
    ..startedAt = started;
  final scan = _Scan(
    db,
    progress.scanId!,
    ctl,
    progress,
    onProgress,
    (cat.getSetting('scan_video') ?? '1') == '1',
  );
  scan.emit(force: true);

  final roots = db
      .select('SELECT id, path FROM library_roots ORDER BY id')
      .map((r) => (r['id'] as int, r['path'] as String))
      .where((r) => rootIds == null || rootIds.contains(r.$1))
      .toList();

  Object? failure;
  for (final (id, path) in roots) {
    if (ctl.cancelled) break;
    try {
      await _scanRoot(scan, id, path);
    } catch (e) {
      scan.error(id, path, 'scan', '$e');
      failure = e;
      break;
    }
  }

  final status = failure != null
      ? 'failed'
      : ctl.cancelled
      ? 'cancelled'
      : 'completed';
  final finished = nowMs();
  db.execute(
    'UPDATE scans SET finished_at=?, status=?, files_seen=?, tracks_added=?, tracks_updated=?, '
    'tracks_unchanged=?, tracks_missing=?, error_count=?, message=? WHERE id=?',
    [
      finished,
      status,
      progress.filesFound,
      progress.added,
      progress.updated,
      progress.unchanged,
      progress.missing,
      progress.errors,
      failure?.toString(),
      scan.scanId,
    ],
  );
  progress
    ..state = status
    ..phase = 'done'
    ..finishedAt = finished
    ..currentPath = null
    ..message = failure?.toString();
  onProgress?.call(progress);
  return progress;
}

Future<void> _scanRoot(_Scan s, int rootId, String rootPath) async {
  final db = s.db;
  s.progress
    ..currentRoot = rootPath
    ..phase = 'discovering';
  s.emit(force: true);
  if (!_rootAvailable(rootPath)) {
    db.execute(
      "UPDATE library_roots SET status='offline', last_scan_at=?, last_scan_status='offline' WHERE id=?",
      [nowMs(), rootId],
    );
    s.error(
      rootId,
      rootPath,
      'offline',
      'Folder or drive is not available. Its tracks are kept and shown as offline, not deleted.',
    );
    s.progress.offlineRoots++;
    return;
  }
  db.execute("UPDATE library_roots SET status='online' WHERE id=?", [rootId]);

  // What the catalogue already knows about this folder.
  final existing = <String, (int, int, int?, String)>{};
  for (final r in db.select(
    'SELECT path_key, id, file_size, file_mtime, read_status FROM tracks WHERE root_id=?',
    [rootId],
  )) {
    existing[r['path_key'] as String] = (
      r['id'] as int,
      r['file_size'] as int,
      r['file_mtime'] as int?,
      r['read_status'] as String,
    );
  }

  // Songs the DJ removed from the library stay out.
  final hidden = {
    for (final r in db.select('SELECT path_key FROM hidden_tracks'))
      r['path_key'] as String,
  };

  // Phase 1: discover files (file-system metadata only, no file contents).
  final toRead = <_Candidate>[];
  final unchangedIds = <int>[];
  final seen = <String>{};
  final dirs = <String>[rootPath];
  var n = 0;
  while (dirs.isNotEmpty) {
    if (s.ctl.cancelled) return;
    final dir = dirs.removeLast();
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync(followLinks: false);
    } on FileSystemException catch (e) {
      s.error(rootId, dir, 'walk', 'Could not read folder entry: ${e.message}');
      continue;
    }
    for (final e in entries) {
      if (++n % 200 == 0) {
        await s.ctl.checkpoint();
        if (s.ctl.cancelled) return;
      }
      if (e is Link) continue; // links and junctions are never followed
      if (e is Directory) {
        dirs.add(e.path);
        continue;
      }
      if (e is! File) continue;
      final path = e.path;
      final fileName = p.basename(path);
      if (fileName.startsWith('._')) continue; // macOS resource-fork sidecars
      final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
      final kind = classifyExtension(ext);
      if (kind == ExtKind.other ||
          (!s.scanVideo &&
              (kind == ExtKind.video || kind == ExtKind.unsupportedVideo))) {
        continue;
      }
      final key = pathKey(path);
      if (!seen.add(key) || hidden.contains(key)) continue;
      final FileStat st;
      try {
        st = e.statSync();
        if (st.type == FileSystemEntityType.notFound) {
          throw FileSystemException('file disappeared', path);
        }
      } on FileSystemException catch (err) {
        s.error(
          rootId,
          path,
          'stat',
          'Could not read file information: ${err.message}',
        );
        continue;
      }
      final size = st.size;
      final mtime = st.modified.millisecondsSinceEpoch;
      s.progress.filesFound++;
      s.emit();
      final prev = existing[key];
      if (prev != null &&
          prev.$2 == size &&
          prev.$3 == mtime &&
          prev.$4 != 'error') {
        unchangedIds.add(prev.$1);
        continue;
      }
      toRead.add(
        _Candidate(
          path,
          key,
          p.isWithin(rootPath, path)
              ? p.relative(path, from: rootPath)
              : fileName,
          fileName,
          ext,
          size,
          mtime,
          kind == ExtKind.unsupportedMusic || kind == ExtKind.unsupportedVideo,
          prev?.$1,
        ),
      );
    }
  }

  // Unchanged files: confirm presence in short batches.
  for (var i = 0; i < unchangedIds.length; i += 500) {
    final chunk = unchangedIds.sublist(
      i,
      (i + 500).clamp(0, unchangedIds.length),
    );
    s.tx(() {
      final st = db.prepare(
        "UPDATE tracks SET presence='present', last_seen_at=?, last_scan_id=? WHERE id=?",
      );
      final now = nowMs();
      for (final id in chunk) {
        st.execute([now, s.scanId, id]);
      }
      st.close();
    });
    s.progress.unchanged += chunk.length;
    s.emit();
  }

  // Phase 2: read tags, writing in batches of 100.
  s.progress
    ..phase = 'reading'
    ..filesToRead += toRead.length;
  s.emit(force: true);
  final batch = <(_Candidate, _Outcome)>[];
  for (final c in toRead) {
    await s.ctl.checkpoint();
    if (s.ctl.cancelled) break;
    s.progress.currentPath = c.path;
    _Outcome out;
    if (c.unsupported) {
      out = _Unsupported();
    } else {
      try {
        out = _Read(readMediaMeta(c.path));
      } on TagReadException catch (e) {
        out = _Failed(e.message);
      } catch (_) {
        // A malformed file must never stop the scan.
        out = _Failed('parser failed on this file (possibly corrupt)');
      }
    }
    batch.add((c, out));
    if (batch.length >= 100) _writeBatch(s, rootId, batch);
  }
  _writeBatch(s, rootId, batch);

  if (s.ctl.cancelled) {
    db.execute(
      "UPDATE library_roots SET last_scan_at=?, last_scan_status='cancelled' WHERE id=?",
      [nowMs(), rootId],
    );
    return;
  }

  // Phase 3: only mark files missing if the folder is still reachable (a drive
  // unplugged mid-scan must not look like deletions).
  s.progress.phase = 'finalising';
  s.emit(force: true);
  if (!_rootAvailable(rootPath)) {
    db.execute(
      "UPDATE library_roots SET status='offline', last_scan_at=?, last_scan_status='offline' WHERE id=?",
      [nowMs(), rootId],
    );
    s.error(
      rootId,
      rootPath,
      'offline',
      'Folder became unavailable during the scan; no tracks were marked missing.',
    );
    s.progress.offlineRoots++;
    return;
  }
  db.execute(
    "UPDATE tracks SET presence='missing' WHERE root_id=? AND presence='present' "
    'AND (last_scan_id IS NULL OR last_scan_id<>?)',
    [rootId, s.scanId],
  );
  s.progress.missing += db.updatedRows;
  db.execute(
    "UPDATE library_roots SET last_scan_at=?, last_scan_status='completed' WHERE id=?",
    [nowMs(), rootId],
  );
}

const _insertSql =
    'INSERT INTO tracks (uid, root_id, path, path_key, rel_path, file_name, extension, file_size, '
    'file_mtime, read_status, read_error, presence, format, codec, lossless, duration_ms, '
    'bitrate_kbps, sample_rate, bit_depth, channels, title, artist, album, album_artist, genre, '
    'year, date_text, original_year, track_no, disc_no, composer, label, comment, isrc, bpm_tag, '
    'key_tag, version_hint, clean_hint, work_key, search_text, first_seen_at, last_seen_at, '
    'last_scan_id) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,\'present\',?12,?13,?14,?15,?16,?17,'
    '?18,?19,?20,?21,?22,?23,?24,?25,?26,?27,?28,?29,?30,?31,?32,?33,?34,?35,?36,?37,?38,?39,?40,'
    '?40,?41)';

const _updateSql =
    'UPDATE tracks SET root_id=?2, path=?3, rel_path=?5, file_name=?6, extension=?7, file_size=?8, '
    "file_mtime=?9, read_status=?10, read_error=?11, presence='present', format=?12, codec=?13, "
    'lossless=?14, duration_ms=?15, bitrate_kbps=?16, sample_rate=?17, bit_depth=?18, channels=?19, '
    'title=?20, artist=?21, album=?22, album_artist=?23, genre=?24, year=?25, date_text=?26, '
    'original_year=?27, track_no=?28, disc_no=?29, composer=?30, label=?31, comment=?32, isrc=?33, '
    'bpm_tag=?34, key_tag=?35, version_hint=?36, clean_hint=?37, work_key=?38, search_text=?39, '
    'last_seen_at=?40, last_scan_id=?41, '
    'content_hash=CASE WHEN file_size=?8 AND file_mtime IS ?9 THEN content_hash ELSE NULL END '
    'WHERE id=?1 AND path_key=?4';

const _mediaSql =
    'UPDATE tracks SET media_kind=?, video_codec=?, width=?, height=?, frame_rate=? WHERE path_key=?';

void _writeBatch(_Scan s, int rootId, List<(_Candidate, _Outcome)> batch) {
  if (batch.isEmpty) return;
  final now = nowMs();
  var added = 0, updated = 0;
  final errs = <(String, String)>[];
  s.tx(() {
    final ins = s.db.prepare(_insertSql);
    final upd = s.db.prepare(_updateSql);
    final media = s.db.prepare(_mediaSql);
    try {
      for (final (c, out) in batch) {
        final String status;
        String? err;
        var m = AudioMeta();
        switch (out) {
          case _Read(:final meta):
            status = 'ok';
            m = meta;
          case _Failed(:final message):
            status = 'error';
            err = message;
            errs.add((c.path, message));
          case _Unsupported():
            status = 'unsupported';
            err =
                '${c.ext.toUpperCase()} files are not supported in this version';
        }
        final labelSrc =
            '${m.title ?? ''} ${m.title == null ? c.fileName : ''}';
        final versionHint = detectVersionLabels(labelSrc);
        final cleanHint = detectCleanExplicit(labelSrc);
        String? workKey;
        if (m.artist != null && m.title != null) {
          final a = baseArtist(m.artist!), t = baseTitle(m.title!);
          if (a.isNotEmpty && t.isNotEmpty) workKey = '$a|$t';
        }
        final searchText = fold(
          [
            m.title,
            m.artist,
            m.album,
            m.albumArtist,
            m.genre,
            m.label,
            m.composer,
            m.comment,
            c.fileName,
            versionHint,
          ].whereType<String>().join(' \u001f '),
        );
        final params = <Object?>[
          c.existingId ?? newUid(c.key),
          rootId,
          c.path,
          c.key,
          c.rel,
          c.fileName,
          c.ext,
          c.size,
          c.mtime,
          status,
          err,
          m.format,
          m.codec,
          m.lossless == null ? null : (m.lossless! ? 1 : 0),
          m.durationMs,
          m.bitrateKbps,
          m.sampleRate,
          m.bitDepth,
          m.channels,
          m.title,
          m.artist,
          m.album,
          m.albumArtist,
          m.genre,
          m.year,
          m.dateText,
          m.originalYear,
          m.trackNo,
          m.discNo,
          m.composer,
          m.label,
          m.comment,
          m.isrc,
          m.bpm,
          m.key,
          versionHint,
          cleanHint,
          workKey,
          searchText,
          now,
          s.scanId,
        ];
        if (c.existingId != null) {
          upd.execute(params);
          updated++;
        } else {
          ins.execute(params);
          added++;
        }
        final isVideo =
            videoExtensions.contains(c.ext) ||
            unsupportedVideoExtensions.contains(c.ext);
        media.execute([
          m.mediaKind ?? (isVideo ? 'video' : 'audio'),
          m.videoCodec,
          m.width,
          m.height,
          m.frameRate,
          c.key,
        ]);
      }
    } finally {
      ins.close();
      upd.close();
      media.close();
    }
  });
  for (final (path, e) in errs) {
    s.error(rootId, path, 'read', e);
  }
  s.progress
    ..added += added
    ..updated += updated
    ..filesProcessed += added + updated
    ..currentPath = null;
  s.emit();
  batch.clear();
}

// ------------------------------------------------------------------ isolate

/// Runs scans in a background isolate with its own connection to the catalogue,
/// so the interface never waits on file reads. One scan at a time.
class ScanService {
  ScanService(this.dbPath);
  final String dbPath;

  final _progress = StreamController<ScanProgress>.broadcast();
  SendPort? _control;
  Completer<ScanProgress>? _running;
  ScanProgress? last;

  Stream<ScanProgress> get progress => _progress.stream;
  bool get isRunning => _running != null;

  /// Starts a scan; the future completes with the final progress.
  Future<ScanProgress> start({List<int>? rootIds}) async {
    if (_running != null) throw StateError('a scan is already running');
    final done = _running = Completer<ScanProgress>();
    final port = ReceivePort();
    final errors = ReceivePort();
    port.listen((msg) {
      if (msg is SendPort) {
        _control = msg;
      } else if (msg is Map) {
        final pr = ScanProgress.fromJson(msg.cast<String, Object?>());
        last = pr;
        _progress.add(pr);
        if (pr.phase == 'done' && !done.isCompleted) {
          done.complete(pr);
          port.close();
          errors.close();
          _control = null;
          _running = null;
        }
      }
    });
    errors.listen((e) {
      if (done.isCompleted) return;
      done.completeError(StateError('scan stopped: $e'));
      port.close();
      errors.close();
      _control = null;
      _running = null;
    });
    await Isolate.spawn(_scanMain, (
      port.sendPort,
      dbPath,
      rootIds,
    ), onError: errors.sendPort);
    return done.future;
  }

  void pause() => _control?.send('pause');
  void resume() => _control?.send('resume');
  void cancel() => _control?.send('cancel');

  Future<void> dispose() => _progress.close();
}

Future<void> _scanMain((SendPort, String, List<int>?) args) async {
  final (out, dbPath, rootIds) = args;
  final ctl = ScanControl();
  final control = ReceivePort();
  out.send(control.sendPort);
  control.listen((m) {
    switch (m) {
      case 'pause':
        ctl.paused = true;
      case 'resume':
        ctl.paused = false;
      case 'cancel':
        ctl.cancelled = true;
    }
  });
  final cat = Catalogue.open(dbPath);
  try {
    await runScan(
      cat,
      rootIds: rootIds,
      control: ctl,
      onProgress: (pr) => out.send(pr.toJson()),
    );
  } finally {
    cat.close();
    control.close();
  }
}
