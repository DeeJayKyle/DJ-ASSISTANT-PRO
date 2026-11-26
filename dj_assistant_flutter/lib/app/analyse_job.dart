import 'dart:convert';

import '../core/analysis_store.dart';
import '../core/catalogue.dart';
import '../core/file_sync.dart';
import '../core/jobs.dart';
import '../core/serato_library.dart';
import '../core/suggestions.dart';
import '../core/taggers.dart';
import '../online/consensus.dart';
import '../online/online.dart';

/// The one Analyse button (and what runs by itself after new music is
/// scanned). In order:
///
/// 1. **Names**: tracks with no artist or title get them from the file name.
/// 2. **Serato**: BPM and key from Serato DJ's own analysis.
/// 3. **Energy**: a 1–10 energy score from the audio (switchable).
/// 4. **OneTagger** (when installed and on) works on temporary copies, which
///    are deleted afterwards; its findings count as one vote.
/// 5. **Online analysers**: all of them at once per track; the majority
///    decides genre, year, album and label (see consensus.dart).
/// 6. **Write**: every change goes into the original music files.
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
List<int> analyseScope(Catalogue cat, String scope, List<int>? chosen) =>
    switch (scope) {
      'ids' => [
        for (final i in _ids(cat, '1')) if (chosen?.contains(i) ?? false) i,
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

/// The whole Analyse run as one background job. [makeOnline] and
/// [makeSecrets] build the online side inside the job's isolate.
JobBody analyseJob(
  AnalysePlan plan, {
  required Online Function() makeOnline,
  required Secrets Function() makeSecrets,
}) => (ctx) async {
  final cat = Catalogue.open(plan.dbPath);
  final steps = <String>[];
  try {
    final ids = analyseScope(cat, plan.scope, plan.ids);
    if (ids.isEmpty) {
      ctx
        ..message = 'Nothing to do: every track is analysed and tagged.'
        ..result = {'summary': 'Nothing to do: every track is analysed and tagged.'};
      return;
    }

    // 1. names
    ctx.message = 'Reading artist and title from file names…';
    final named = fillFromNames(cat, ids);
    if (named > 0) steps.add('$named field(s) filled from file names');

    // 2. Serato
    if (await ctx.checkpoint()) return;
    ctx
      ..message = "Reading Serato's BPM and key…"
      ..total = ids.length;
    final (fromSerato, notInSerato) = syncSeratoAnalysis(
      cat,
      plan.seratoDirs,
      ids: ids,
    );
    steps.add(
      'Serato BPM/key for $fromSerato track(s)'
      '${notInSerato > 0 ? ' ($notInSerato not analysed in Serato yet)' : ''}',
    );

    // 3. energy
    if (plan.energy && !await ctx.checkpoint()) {
      final todo = AnalysisStore(cat).pending(only: ids);
      if (todo.isNotEmpty) {
        ctx.message = 'Measuring energy of ${todo.length} track(s)…';
        await analysisJob(plan.dbPath, only: ids)(ctx);
        steps.add('energy for ${todo.length} track(s)');
      }
    }

    // 4. OneTagger on temporary copies
    Findings oneTagger = const {};
    final exe = plan.oneTaggerExe;
    if (exe != null && !await ctx.checkpoint()) {
      final svc = TaggerService(cat, plan.dataDir);
      TaggerWorkspace? ws;
      try {
        ctx.message = 'OneTagger is looking tracks up…';
        ws = svc.create(
          ids.take(plan.oneTaggerLimit).toList(),
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

    // 5. every online analyser at once, majority wins
    final secrets = makeSecrets();
    final voters = activeAnalysers(
      cat,
      secrets,
      oneTagger: oneTagger.isNotEmpty,
    );
    if (voters.isNotEmpty && !await ctx.checkpoint()) {
      final res = await analyseOnline(
        cat,
        makeOnline(),
        secrets,
        ids,
        ctx,
        oneTagger: oneTagger,
      );
      steps.add(
        '${voters.length} online analyser(s) checked ${res.tracks} track(s) '
        'and fixed ${res.fields} tag(s) on ${res.changed} track(s)'
        '${res.noMatch > 0 ? ' (${res.noMatch} not found online)' : ''}',
      );
      if (res.errors.isNotEmpty) {
        steps.add('problems: ${res.errors.take(3).join('; ')}');
      }
    } else if (voters.isEmpty) {
      steps.add('no online analysers are switched on');
    }

    // 6. into the files
    var written = 0, failed = 0;
    if (fileSyncOn(cat) && fileSyncQueued(cat) > 0) {
      ctx.message = 'Writing the changes into your music files…';
      final (w, _, f) = await flushFileSync(cat, dataDir: plan.dataDir);
      written = w;
      failed = f;
      steps.add(
        'wrote $w file(s)${f > 0 ? ' ($f could not be written)' : ''}',
      );
    }

    final summary =
        'Analysed ${ids.length} track(s): ${steps.join('; ')}.';
    final report = {
      'finished_at': nowMs(),
      'tracks': ids.length,
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
