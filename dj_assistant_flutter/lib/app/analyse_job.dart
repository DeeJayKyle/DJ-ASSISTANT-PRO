import 'dart:convert';

import 'package:path/path.dart' as p;

import '../core/analysis_store.dart';
import '../core/catalogue.dart';
import '../core/file_sync.dart';
import '../core/jobs.dart';
import '../core/serato_library.dart';
import '../core/serato_sync.dart';
import '../core/suggestions.dart';
import '../core/taggers.dart';
import '../online/consensus.dart';
import '../online/online.dart';

/// The one Analyse button (and what runs by itself after new music is
/// scanned). In order:
///
/// 1. **Names**: tracks with no artist or title get them from the file name.
/// 2. **Serato**: BPM and key from Serato DJ's own database (no audio read).
/// 3. **This computer**: a 1–10 energy score from the audio (switchable),
///    and BPM/key for tracks Serato hasn't analysed, on every CPU core and
///    at the same time as steps 4–5.
/// 4. **OneTagger** (when installed and on) works on temporary copies, which
///    are deleted afterwards; its findings count as one vote.
/// 5. **Online analysers**: many tracks at once, only tracks still missing
///    something; the majority decides genre, year, album and label (see
///    consensus.dart).
/// 6. **Write**: every change goes into the original music files, the tags
///    as soon as step 5 is done and energy when step 3 is.
///
/// Everything it changes is listed under Analysis → Changes and can be undone.
class AnalysePlan {
  const AnalysePlan({
    required this.dbPath,
    required this.dataDir,
    this.scope = 'new',
    this.ids,
    this.seratoDirs = const [],
    this.oneTaggerExe,
    this.oneTaggerPlatforms,
    this.energy = true,
    this.oneTaggerLimit = 200,
  });
  final String dbPath, dataDir, scope;
  final List<int>? ids;
  final List<String> seratoDirs;
  final String? oneTaggerExe, oneTaggerPlatforms;
  final bool energy;
  final int oneTaggerLimit;
}

/// What Analyse can work on.
const analyseScopes = {
  'new': 'New and incomplete tracks',
  'all': 'Every track (check all again)',
  'ids': 'The tracks you chose',
};

const _present =
    "t.presence='present' AND t.read_status='ok' AND t.media_kind IS NOT 'video'";

List<int> _ids(Catalogue cat, String where) => [
  for (final r in cat.db.select(
    'SELECT t.id FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
    'WHERE $_present AND ($where) ORDER BY t.id',
  ))
    r['id'] as int,
];

/// The tracks a run covers.
List<int> analyseScope(
  Catalogue cat,
  String scope,
  List<int>? chosen,
) => switch (scope) {
  'ids' => [
    for (final i in _ids(cat, '1'))
      if (chosen?.contains(i) ?? false) i,
  ],
  'all' => _ids(cat, '1'),
  _ => _ids(
    cat,
    't.id NOT IN (SELECT track_id FROM catalog_checked) OR '
    't.id NOT IN (SELECT track_id FROM analysis) OR '
    'COALESCE(u.title, t.title) IS NULL OR COALESCE(u.artist, t.artist) IS NULL OR '
    'COALESCE(u.genre, t.genre) IS NULL OR COALESCE(u.year, t.year) IS NULL OR '
    'COALESCE(u.bpm, t.bpm_tag) IS NULL OR COALESCE(u.musical_key, t.key_tag) IS NULL',
  ),
};

/// Fills empty artist and title fields from file names. Returns how many.
int fillFromNames(Catalogue cat, List<int> ids) {
  final svc = SuggestionsService(cat)..generateLocal();
  if (ids.isEmpty) return 0;
  final inScope = ids.toSet();
  var n = 0;
  for (final r in cat.db.select(
    "SELECT id, track_id FROM suggestions WHERE status='pending' "
    "AND field IN ('artist','title') AND current_value IS NULL "
    "AND source IN ('File name','Folder name') ORDER BY confidence DESC",
  )) {
    if (!inScope.contains(r['track_id'])) continue;
    final still = cat.db.select(
      "SELECT 1 FROM suggestions WHERE id=? AND status='pending'",
      [r['id']],
    );
    if (still.isEmpty) continue;
    try {
      svc.accept(r['id'] as int, by: 'auto');
      n++;
    } on Object {
      // left for the DJ
    }
  }
  return n;
}

/// Tracks the online analysers still need to see. "New" runs skip tracks
/// whose genre, year, album and label are all filled, and tracks checked in
/// the last 90 days (a track no catalogue knew is tried again after that,
/// in case it has been added since). "Every track" and chosen tracks are
/// always asked.
List<int> onlineScope(Catalogue cat, String scope, List<int> ids) {
  if (scope != 'new' || ids.isEmpty) return ids;
  final since = nowMs() - 90 * 24 * 3600 * 1000;
  final want = ids.toSet();
  return [
    for (final r in cat.db.select(
      'SELECT t.id FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
      'WHERE t.id NOT IN (SELECT track_id FROM catalog_checked WHERE checked_at>?) '
      "AND (NULLIF(TRIM(COALESCE(u.genre, t.genre)), '') IS NULL "
      'OR COALESCE(u.year, t.year) IS NULL '
      "OR NULLIF(TRIM(COALESCE(u.album, t.album)), '') IS NULL "
      "OR NULLIF(TRIM(COALESCE(u.record_label, t.label)), '') IS NULL) "
      'ORDER BY t.id',
      [since],
    ))
      if (want.contains(r['id'])) r['id'] as int,
  ];
}

/// Two parts of one job reporting into one progress bar: the online
/// analysers and the audio analysis run side by side.
class _Part implements JobProgress {
  _Part(this.job, this.label, this.show);
  final JobProgress job;
  final String label;
  final void Function() show;
  int count = 0, done = 0;
  String note = '';
  @override
  set total(int n) => count = n;
  @override
  void tick({bool ok = true}) {
    done++;
    job.tick(ok: ok);
    show();
  }

  @override
  set message(String m) {
    note = m;
    show();
  }

  @override
  Future<bool> checkpoint() => job.checkpoint();
  bool get active => count > 0 && done < count;
  @override
  String toString() => '$done of $count';
}

/// The whole Analyse run as one background job. [makeOnline] and
/// [makeSecrets] build the online side inside the job's isolate.
///
/// Built for big libraries: the audio (energy, and BPM/key Serato hasn't
/// got) is decoded on every CPU core *while* the online analysers work, so
/// neither waits for the other; the online part only asks about tracks
/// that still miss something (see [onlineScope]) and many at once; tags go
/// into the files as soon as the online part is done, energy when the audio
/// part is.
JobBody analyseJob(
  AnalysePlan plan, {
  required Online Function() makeOnline,
  required Secrets Function() makeSecrets,
}) => (ctx) async {
  final cat = Catalogue.open(plan.dbPath);
  final steps = <String>[];
  final started = DateTime.now();
  try {
    final ids = analyseScope(cat, plan.scope, plan.ids);
    if (ids.isEmpty) {
      ctx
        ..message = 'Nothing to do: every track is analysed and tagged.'
        ..result = {
          'summary': 'Nothing to do: every track is analysed and tagged.',
        };
      return;
    }

    // 1. names
    ctx.message = 'Reading artist and title from file names…';
    final named = fillFromNames(cat, ids);
    if (named > 0) steps.add('$named field(s) filled from file names');

    // 2. Serato: from its database, no audio read
    if (await ctx.checkpoint()) return;
    ctx.message = "Reading Serato's BPM and key…";
    final (fromSerato, notInSerato) = syncSeratoAnalysis(
      cat,
      plan.seratoDirs,
      ids: ids,
    );
    steps.add(
      'Serato BPM/key for $fromSerato track(s)'
      '${notInSerato > 0 ? ' ($notInSerato not analysed in Serato yet)' : ''}',
    );

    // what each part will do
    final noBpmKey = _ids(
      cat,
      't.id IN (${ids.join(',')}) AND (COALESCE(u.bpm, t.bpm_tag) IS NULL '
      'OR COALESCE(u.musical_key, t.key_tag) IS NULL)',
    );
    final store = AnalysisStore(cat);
    final audioTodo = noBpmKey.isEmpty && !plan.energy
        ? const <(int, String, int, int?)>[]
        : store.pending(only: plan.energy ? ids : noBpmKey);
    final onlineIds = onlineScope(cat, plan.scope, ids);
    final secrets = makeSecrets();

    late final _Part audio, online;
    void show() {
      final parts = [
        if (online.count > 0) 'online $online',
        if (audio.count > 0) '${plan.energy ? 'energy' : 'BPM/key'} $audio',
      ];
      final now = online.active ? online.note : audio.note;
      ctx.message = [parts.join(' · '), if (now.isNotEmpty) now].join(' — ');
    }

    audio = _Part(ctx, 'audio', show);
    online = _Part(ctx, 'online', show);
    final voters = activeAnalysers(cat, secrets);
    ctx.total =
        audioTodo.length +
        (voters.isEmpty && plan.oneTaggerExe == null ? 0 : onlineIds.length);

    // 3. this computer, on every core, alongside the online part
    audio
      ..count = audioTodo.length
      ..note = 'measuring the audio on ${analysisWorkers()} core(s)';
    final audioRun = audioTodo.isEmpty
        ? Future.value(const <int>[])
        : analyseTracks(store, audioTodo, audio);

    // 4. OneTagger on temporary copies
    Findings oneTagger = const {};
    final exe = plan.oneTaggerExe;
    if (exe != null && onlineIds.isNotEmpty && !await ctx.checkpoint()) {
      final svc = TaggerService(cat, plan.dataDir);
      TaggerWorkspace? ws;
      try {
        online.message = 'OneTagger is looking tracks up…';
        ws = svc.create(
          onlineIds.take(plan.oneTaggerLimit).toList(),
          label: 'Analyse',
        );
        oneTagger = await runAutomaticTool(
          ws,
          'onetagger',
          exe,
          platforms: plan.oneTaggerPlatforms,
        );
      } on Object catch (e) {
        steps.add('OneTagger could not run (${'$e'.split('\n').first})');
      } finally {
        if (ws != null) {
          try {
            svc.remove(ws); // the copies are only temporary
          } on Object {
            // left for the next reset
          }
        }
      }
    }

    // 5. online analysers: many tracks at once, majority wins
    final allVoters = activeAnalysers(
      cat,
      secrets,
      oneTagger: oneTagger.isNotEmpty,
    );
    if (allVoters.isEmpty || onlineIds.isEmpty) {
      ctx.total = audioTodo.length; // no online part after all
    }
    if (allVoters.isEmpty) {
      steps.add('no online analysers are switched on');
    } else if (onlineIds.isEmpty) {
      steps.add('online: every track is already complete or checked');
    } else if (!await ctx.checkpoint()) {
      final res = await analyseOnline(
        cat,
        makeOnline(),
        secrets,
        onlineIds,
        online,
        oneTagger: oneTagger,
        reuseAlbums: plan.scope != 'all',
      );
      steps.add(
        '${allVoters.length} online analyser(s) checked ${res.tracks} track(s) '
        'and fixed ${res.fields} tag(s) on ${res.changed} track(s)'
        '${res.noMatch > 0 ? ' (${res.noMatch} not found online)' : ''}'
        '${res.albumHits > 0 ? '; ${res.albumHits} answered from their album' : ''}',
      );
      if (res.errors.isNotEmpty) {
        steps.add('problems: ${res.errors.take(3).join('; ')}');
      }
    }
    final skippedOnline = ids.length - onlineIds.length;
    if (skippedOnline > 0 && allVoters.isNotEmpty) {
      steps.add('$skippedOnline complete or recently checked track(s) skipped');
    }

    // 6. the tags into the files now, without waiting for the audio part
    var written = 0, failed = 0;
    Future<void> flush() async {
      if (!fileSyncOn(cat) || fileSyncQueued(cat) == 0) return;
      final (w, _, f) = await flushFileSync(cat, dataDir: plan.dataDir);
      written += w;
      failed += f;
    }

    if (audio.active) {
      online.message = 'writing the changes into your music files';
    } else {
      ctx.message = 'Writing the changes into your music files…';
    }
    await flush();

    // 7. the audio part, then its energy into the Grouping tag
    final analysed = await audioRun;
    if (analysed.isNotEmpty) {
      steps.add(
        '${plan.energy ? 'energy' : 'BPM/key'} for ${analysed.length} '
        'track(s) on ${analysisWorkers()} core(s)',
      );
      if (fileSyncOn(cat)) {
        enqueueFileSync(cat, analysed, const ['energy']);
        ctx.message = 'Writing energy into your music files…';
        await flush();
      }
    }
    if (written > 0 || failed > 0) {
      steps.add(
        'wrote $written file(s)${failed > 0 ? ' ($failed could not be written)' : ''}',
      );
    }
    if (seratoSyncQueued(cat) > 0) {
      ctx.message = "Updating Serato's library…";
      final (st, sf, note) = flushSeratoSync(
        cat,
        plan.seratoDirs,
        backupsDir: p.join(plan.dataDir, 'serato_backups'),
      );
      if (note != null) {
        steps.add('Serato\'s library waits until Serato DJ is closed ($note)');
      } else if (st > 0) {
        steps.add('updated $sf field(s) of $st track(s) in Serato');
      }
    }

    final secs = DateTime.now().difference(started).inSeconds;
    final took = secs < 90 ? '$secs s' : '${(secs / 60).round()} min';
    final summary =
        'Analysed ${ids.length} track(s) in $took: ${steps.join('; ')}.';
    final report = {
      'finished_at': nowMs(),
      'tracks': ids.length,
      'online_tracks': onlineIds.length,
      'seconds': secs,
      'summary': summary,
      'files_written': written,
      'files_failed': failed,
    };
    cat.setSetting('analyse_report', jsonEncode(report));
    ctx
      ..message = summary
      ..result = report;
  } finally {
    cat.close();
  }
};

/// The last run's report, if any.
Map<String, Object?>? lastAnalyseReport(Catalogue cat) {
  final raw = cat.getSetting('analyse_report');
  if (raw == null) return null;
  try {
    return Map<String, Object?>.from(jsonDecode(raw) as Map);
  } on Object {
    return null;
  }
}
