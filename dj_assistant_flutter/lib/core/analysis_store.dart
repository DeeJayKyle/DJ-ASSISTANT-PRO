import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/analysis.dart' as an;
import '../analysis/beatgrid.dart';
import 'catalogue.dart';
import 'serato_tags.dart';
import 'limits.dart';
import 'jobs.dart';
import 'suggestions.dart';

/// Stores analysis estimates and runs analysis as a background job (1.x
/// `analysis_store.rs`). Only the catalogue is written; music files are only read.
class AnalysisStore {
  AnalysisStore(this.cat);
  final Catalogue cat;

  Map<String, Object?>? get(int trackId) {
    final rows = cat.db.select(
      'SELECT method, version, analysed_at, status, error, bpm, bpm_confidence, bpm_alt, musical_key, camelot, '
      'key_confidence, energy, loudness_lufs, peak_dbfs, clipped_runs, silence_start_ms, silence_end_ms, '
      'intro_end_ms, outro_start_ms, tempo_stable, cues_json, warnings_json, waveform, duration_ms, '
      'fingerprint_encoded IS NOT NULL AS has_fp, beatgrid_json FROM analysis WHERE track_id=?',
      [trackId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    List<Object?> js(Object? s) =>
        s == null ? [] : (jsonDecode(s as String) as List);
    return {
      'method': r['method'],
      'version': r['version'],
      'analysed_at': r['analysed_at'],
      'status': r['status'],
      'error': r['error'],
      'bpm': r['bpm'],
      'bpm_confidence': r['bpm_confidence'],
      'bpm_alt': r['bpm_alt'],
      'key': r['musical_key'],
      'camelot': r['camelot'],
      'key_confidence': r['key_confidence'],
      'energy': r['energy'],
      'loudness_lufs': r['loudness_lufs'],
      'peak_dbfs': r['peak_dbfs'],
      'clipped_runs': r['clipped_runs'],
      'silence_start_ms': r['silence_start_ms'],
      'silence_end_ms': r['silence_end_ms'],
      'intro_end_ms': r['intro_end_ms'],
      'outro_start_ms': r['outro_start_ms'],
      'tempo_stable': r['tempo_stable'] == null ? null : r['tempo_stable'] == 1,
      'cues': js(r['cues_json']),
      'warnings': js(r['warnings_json']),
      'waveform': (r['waveform'] as List<int>?) ?? const <int>[],
      'duration_ms': r['duration_ms'],
      'has_fingerprint': r['has_fp'] == 1,
      'beatgrid': r['beatgrid_json'] == null
          ? null
          : jsonDecode(r['beatgrid_json'] as String),
    };
  }

  void storeResult(int id, int size, int? mtime, an.Analysis a) {
    final fp = a.fingerprint;
    Uint8List? blob;
    if (fp.isNotEmpty) {
      final b = ByteData(fp.length * 4);
      for (var i = 0; i < fp.length; i++) {
        b.setUint32(i * 4, fp[i], Endian.little);
      }
      blob = b.buffer.asUint8List();
    }
    cat.db.execute(
      'INSERT OR REPLACE INTO analysis (track_id, method, version, analysed_at, file_size, file_mtime, status, error, '
      'bpm, bpm_confidence, bpm_alt, musical_key, camelot, key_confidence, energy, loudness_lufs, peak_dbfs, '
      'clipped_runs, silence_start_ms, silence_end_ms, intro_end_ms, outro_start_ms, tempo_stable, cues_json, '
      'warnings_json, waveform, fingerprint, fingerprint_encoded, duration_ms, energy_raw, beatgrid_json) '
      "VALUES (?,?,?,?,?,?,'ok',NULL,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      [
        id, an.method, an.version, nowMs(), size, mtime, //
        a.bpm,
        a.bpmConfidence,
        a.bpmAlt,
        a.key,
        a.camelot,
        a.keyConfidence,
        a.energy,
        a.loudnessLufs,
        a.peakDbfs,
        a.clippedRuns,
        a.silenceStartMs,
        a.silenceEndMs,
        a.introEndMs,
        a.outroStartMs,
        a.tempoStable == null ? null : (a.tempoStable! ? 1 : 0),
        jsonEncode([for (final c in a.cues) c.toJson()]),
        jsonEncode(a.warnings),
        a.waveform,
        blob,
        a.fingerprintEncoded,
        a.durationMs,
        a.energyRaw,
        a.beatgrid == null ? null : jsonEncode(a.beatgrid!.toJson()),
      ],
    );
    _suggest(id, a);
  }

  /// The best beatgrid for a track: Serato's own (read from the file's tags,
  /// never written) when the DJ has analysed it in Serato, else this app's.
  BeatGrid? beatgridFor(int trackId, String path) {
    final serato = readSeratoAnalysis(path).beatgrid;
    if (serato != null) return serato;
    final r = cat.db.select(
      'SELECT beatgrid_json FROM analysis WHERE track_id=?',
      [trackId],
    );
    final j = r.isEmpty ? null : r.first['beatgrid_json'] as String?;
    return j == null ? null : BeatGrid.fromJson(jsonDecode(j));
  }

  void storeError(int id, int size, int? mtime, String error) {
    cat.db.execute(
      'INSERT OR REPLACE INTO analysis (track_id, method, version, analysed_at, file_size, file_mtime, status, error) '
      "VALUES (?,?,?,?,?,?,'error',?)",
      [id, an.method, an.version, nowMs(), size, mtime, error],
    );
  }

  /// BPM and key from this computer fill only what nothing else has given:
  /// Serato's own analysis (read first) and the file's tags win. Filled
  /// values are applied at once as automatic changes, so they show under
  /// Changes, go into the file and Serato, and can be undone.
  void _suggest(int id, an.Analysis a) {
    final t = cat.db.select(
      'SELECT COALESCE(u.bpm, t.bpm_tag) AS bpm, '
      'COALESCE(u.musical_key, t.key_tag) AS k '
      'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?',
      [id],
    ).first;
    final sugg = SuggestionsService(cat);
    void fill(String field, String value, String evidence, double conf) {
      insertSuggestion(
        cat,
        id,
        field,
        null,
        value,
        'This computer',
        evidence,
        conf,
      );
      final r = cat.db.select(
        "SELECT id FROM suggestions WHERE track_id=? AND field=? AND "
        "suggested_value=? AND source='This computer' AND status='pending'",
        [id, field, value],
      );
      if (r.isEmpty) return;
      try {
        sugg.accept(r.first['id'] as int, by: 'auto');
      } on Object {
        // left for the DJ under Changes
      }
    }

    final bpm = a.bpm;
    if (t['bpm'] == null && bpm != null) {
      final alt = a.bpmAlt == null
          ? ''
          : ' It could also be heard as ${a.bpmAlt!.toStringAsFixed(1)} BPM (half/double time).';
      fill(
        'bpm',
        bpm.toStringAsFixed(1),
        'Serato has not analysed this track; tempo estimated from the audio.$alt',
        a.bpmConfidence,
      );
    }
    final k = a.key, cam = a.camelot;
    if (t['k'] == null && k != null && cam != null) {
      fill(
        'key',
        cam,
        'Serato has not analysed this track; key estimated from the audio: $k ($cam).',
        a.keyConfidence,
      );
    }
  }

  /// Scales energy 1–10 against the DJ's own library: half percentile rank, half
  /// absolute score. Needs at least 8 analysed tracks. Ties are ranked by track
  /// (1.x leaves their order to the database, so tied tracks could swap).
  int rescaleEnergy() {
    final rows = cat.db.select(
      "SELECT track_id, energy_raw FROM analysis WHERE status='ok' AND energy_raw IS NOT NULL ORDER BY energy_raw, track_id",
    );
    if (rows.length < 8) return 0;
    final n = rows.length.toDouble();
    cat.db.execute('BEGIN');
    try {
      final st = cat.db.prepare(
        'UPDATE analysis SET energy=? WHERE track_id=?',
      );
      for (var i = 0; i < rows.length; i++) {
        final raw = (rows[i]['energy_raw'] as num).toDouble();
        final pct = i / (n - 1);
        st.execute([
          (1 + (0.5 * pct + 0.5 * raw) * 9).round().clamp(1, 10),
          rows[i]['track_id'],
        ]);
      }
      st.close();
      cat.db.execute('COMMIT');
    } catch (_) {
      cat.db.execute('ROLLBACK');
      rethrow;
    }
    return rows.length;
  }

  bool isCurrent(int id) => cat.db.select(
    'SELECT 1 FROM analysis a JOIN tracks t ON t.id=a.track_id WHERE a.track_id=? AND a.version=? '
    'AND a.file_size=t.file_size AND a.file_mtime IS t.file_mtime',
    [id, an.version],
  ).isNotEmpty;

  /// Tracks needing analysis: readable, present, online, and not analysed with the
  /// current version for the current file contents.
  List<(int, String, int, int?)> pending({
    List<int>? only,
    bool force = false,
  }) {
    final want = only?.toSet();
    return cat.db
        .select(
          'SELECT t.id, t.path, t.file_size, t.file_mtime FROM tracks t JOIN library_roots r ON r.id=t.root_id '
          'LEFT JOIN analysis a ON a.track_id=t.id '
          "WHERE t.presence='present' AND t.read_status='ok' AND r.status<>'offline' "
          'AND (? OR a.track_id IS NULL OR a.version<>? OR a.file_size<>t.file_size OR a.file_mtime IS NOT t.file_mtime) '
          'ORDER BY t.id',
          [force ? 1 : 0, an.version],
        )
        .map(
          (r) => (
            r['id'] as int,
            r['path'] as String,
            r['file_size'] as int,
            r['file_mtime'] as int?,
          ),
        )
        .where((r) => want == null || want.contains(r.$1))
        .toList();
  }

  /// The track's genre as the DJ sees it (catalogue, else file tag): the
  /// tempo hint for half/double time.
  String? genreOf(int id) =>
      cat.db.select(
            'SELECT COALESCE(u.genre, t.genre) AS g FROM tracks t '
            'LEFT JOIN track_user u ON u.track_id=t.id WHERE t.id=?',
            [id],
          ).firstOrNull?['g']
          as String?;

  Map<String, Object?> summary() {
    final r = cat.db
        .select(
          "SELECT SUM(status='ok') AS ok, SUM(status='error') AS err FROM analysis",
        )
        .first;
    return {
      'analysed': r['ok'] ?? 0,
      'errors': r['err'] ?? 0,
      'pending': pending().length,
      'method': an.method,
      'version': an.version,
    };
  }
}

/// How many tracks are decoded at once: one per CPU core, keeping one core
/// free for the app, at most 6 (each decode holds a few minutes of audio
/// in memory).
int analysisWorkers() =>
    math.max(1, math.min(6, Platform.numberOfProcessors - 1));

/// Decodes and analyses one file on a worker isolate. A top-level function,
/// so the isolate gets only these plain values (never the database).
Future<an.Analysis> _analyseOff(
  String path,
  double? seconds,
  String bpmRange,
  String? genre,
) => Isolate.run(
  () =>
      an.analyseFile(path, seconds: seconds, bpmRange: bpmRange, genre: genre),
);

/// Analyses [todo] (from [AnalysisStore.pending]) on [workers] cores at
/// once and stores each result as it arrives. Returns the tracks analysed.
/// Damaged files are recorded and skipped; they never stop the run.
Future<List<int>> analyseTracks(
  AnalysisStore store,
  List<(int, String, int, int?)> todo,
  JobProgress p, {
  int? workers,
}) async {
  final cat = store.cat;
  // Settings → Limits: minutes read per track, or the whole file
  final minutes = limitOf(cat, 'analysis_minutes');
  final seconds = minutes == null ? null : minutes * 60.0;
  // Settings → Library: BPM range (Serato's ranges, or automatic)
  final range = cat.getSetting('bpm_range');
  final bpmRange = bpmRanges.containsKey(range) ? range! : 'auto';
  final done = <int>[];
  var next = 0;
  var stop = false;
  Future<void> worker() async {
    while (!stop && next < todo.length) {
      if (await p.checkpoint()) {
        stop = true;
        return;
      }
      if (next >= todo.length) return;
      final (id, path, size, mtime) = todo[next++];
      try {
        final a = await _analyseOff(path, seconds, bpmRange, store.genreOf(id));
        store.storeResult(id, size, mtime, a);
        done.add(id);
        p.tick();
      } catch (e) {
        store.storeError(
          id,
          size,
          mtime,
          e is Exception ? '$e' : 'analysis failed on this file',
        );
        p.tick(ok: false);
      }
    }
  }

  await Future.wait([
    for (var i = 0; i < (workers ?? analysisWorkers()); i++) worker(),
  ]);
  store.rescaleEnergy();
  return done;
}

/// The analysis job body: runs in a [JobsController] isolate with its own
/// connection to the account's catalogue; the audio itself is decoded on
/// every core at once (see [analyseTracks]).
JobBody analysisJob(String dbPath, {List<int>? only, bool force = false}) =>
    (ctx) async {
      final cat = Catalogue.open(dbPath);
      try {
        final store = AnalysisStore(cat);
        final todo = store.pending(only: only, force: force);
        ctx.total = todo.length;
        await analyseTracks(store, todo, ctx);
      } finally {
        cat.close();
      }
    };
