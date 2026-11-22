import 'dart:convert';

import '../analysis/analysis.dart' as an;
import '../analysis/beatgrid.dart' show foldBpmForGenre;
import 'analysis_store.dart';
import 'autoprep.dart';
import 'catalogue.dart';
import 'file_sync.dart';
import 'health.dart';
import 'jobs.dart';
import 'keys.dart';
import 'limits.dart';
import 'suggestions.dart';
import 'taggers.dart';

/// The Analysis Crew: every music analyser in DJ Assistant, run as one
/// function ([crewJob]) by a team of agents that each have one role and hand
/// their work to the next through a shared board (the catalogue):
///
/// 1. **Scout** works out what needs doing: which tracks are new, unanalysed
///    or missing tags, and briefs the others.
/// 2. **Listener** listens to the audio: BPM, key, energy, loudness, cues.
/// 3. **Detective** reads the evidence already on disk: file and folder names,
///    albums, spellings across the library.
/// 4. **Librarian** asks the online catalogues the DJ switched on.
/// 5. **Taggers** send OneTagger and beets to work on copies of the tracks
///    still missing details (Picard and Mp3tag stay on call in Taggers).
/// 6. **Judge** cross-examines everything: where agents agree, confidence
///    rises; where a tag disagrees with what the Listener heard, it falls,
///    with the reason written into the evidence.
/// 7. **Clerk** files the verdicts: review-first by default, or fills gaps /
///    applies confident fixes when the DJ chose that (Settings → Library).
///
/// Every agent can be switched off; each says why it skipped. Nothing is ever
/// written to a music file: findings land in Suggestions and the catalogue.
class CrewAgent {
  const CrewAgent(this.id, this.name, this.role, this.detail);
  final String id, name, role, detail;
}

const crewAgents = <CrewAgent>[
  CrewAgent(
    'scout',
    'Scout',
    'Finds what needs doing',
    'Checks which tracks are new, unanalysed or missing title, artist, '
        'genre, year, BPM, key or label, and briefs the crew.',
  ),
  CrewAgent(
    'listener',
    'Listener',
    'Hears BPM, key and energy',
    'Analyses the audio on this computer: tempo with half/double '
        'alternatives, key, energy, loudness, cues, waveform, fingerprint.',
  ),
  CrewAgent(
    'detective',
    'Detective',
    'Reads names and folders',
    'Finds artist, title, genre and year in file names, folder names, '
        'albums and consistent spellings across your library.',
  ),
  CrewAgent(
    'librarian',
    'Librarian',
    'Asks online catalogues',
    'Looks tracks still missing details up in the online services you '
        'switched on (MusicBrainz, Deezer, Apple Music, Spotify, GetSongBPM…).',
  ),
  CrewAgent(
    'taggers',
    'Taggers',
    'OneTagger + beets on copies',
    'Runs the installed automatic taggers on copies of tracks still missing '
        'details. Picard and Mp3tag stay on call on the Taggers tab.',
  ),
  CrewAgent(
    'judge',
    'Judge',
    'Cross-checks every finding',
    'Raises confidence where agents agree, lowers it where a tag disagrees '
        'with the audio (half/double tempo and relative keys are understood).',
  ),
  CrewAgent(
    'clerk',
    'Clerk',
    'Files the verdicts',
    'Review first: everything waits in Suggestions. Or, if you chose it, '
        'fills empty fields / applies confident fixes, all undoable.',
  ),
];

CrewAgent? crewAgentById(String id) =>
    crewAgents.where((a) => a.id == id).firstOrNull;

/// What the crew works on.
const crewScopes = {
  'new': 'New, unanalysed or incomplete tracks',
  'all': 'Every track (re-check all)',
  'ids': 'The tracks you chose',
};

/// The crew's orders: sendable values only (it runs in a job isolate).
class CrewPlan {
  const CrewPlan({
    required this.dbPath,
    required this.dataDir,
    this.scope = 'new',
    this.ids,
    this.off = const {},
    this.taggerExe = const {},
    this.platforms,
    this.beetsPlugins,
    this.taggerLimit = 50,
  });
  final String dbPath, dataDir, scope;
  final List<int>? ids;

  /// Agents the DJ switched off.
  final Set<String> off;

  /// Automatic tagger → its program (installed and switched on).
  final Map<String, String> taggerExe;
  final String? platforms, beetsPlugins;

  /// At most this many tracks go to the external taggers per run.
  final int taggerLimit;
}

/// One agent's part in a run.
class AgentReport {
  AgentReport(this.id);
  final String id;
  String status = 'waiting'; // waiting | working | done | skipped | failed
  String summary = '';
  int ms = 0;
  Map<String, Object?> toJson() => {
    'id': id,
    'status': status,
    'summary': summary,
    'ms': ms,
  };
}

/// The board the agents share during a run.
class CrewBoard {
  CrewBoard(this.cat, this.plan);
  final Catalogue cat;
  final CrewPlan plan;

  /// Tracks in scope.
  List<int> scope = const [];

  /// Of those: not analysed yet, and missing at least one tag.
  List<int> unanalysed = const [], incomplete = const [];
  int suggestionsBefore = 0;
  int clues = 0, onlineChecked = 0, applied = 0;
  int filesWritten = 0, filesSkipped = 0, filesFailed = 0;
  Map<String, int> missingBefore = const {};
  final reports = {for (final a in crewAgents) a.id: AgentReport(a.id)};
}

/// The message prefix that tells the UI which agent is speaking.
String crewMessage(String agent, String text) => '$agent|$text';

/// (agent id, text) from a crew job message, or null.
(String, String)? parseCrewMessage(String? m) {
  if (m == null) return null;
  final i = m.indexOf('|');
  if (i <= 0 || crewAgentById(m.substring(0, i)) == null) return null;
  return (m.substring(0, i), m.substring(i + 1));
}

/// The whole crew as one job. [onlineSteps] are the Librarian's lookups,
/// prepared by the app with the DJ's switched-on services.
JobBody crewJob(CrewPlan plan, {List<OnlineStep> onlineSteps = const []}) =>
    (ctx) async {
      final cat = Catalogue.open(plan.dbPath);
      try {
        final board = CrewBoard(cat, plan);
        await runCrew(board, ctx, onlineSteps: onlineSteps);
        final report = crewReport(board);
        cat.setSetting('crew_report', jsonEncode(report));
        ctx
          ..result = report
          ..message = '${report['summary']}';
      } finally {
        cat.close();
      }
    };

/// Runs each agent in turn. A failing agent is reported and the rest carry on.
Future<void> runCrew(
  CrewBoard b,
  JobProgress ctx, {
  List<OnlineStep> onlineSteps = const [],
  Future<void> Function(List<int> ids, JobProgress ctx)? listen,
}) async {
  final steps = <String, Future<String?> Function()>{
    'scout': () async => _scout(b),
    'listener': () => _listener(b, ctx, listen),
    'detective': () async => _detective(b),
    'librarian': () => _librarian(b, ctx, onlineSteps),
    'taggers': () => _taggers(b, ctx),
    'judge': () async => _judge(b),
    'clerk': () => _clerk(b),
  };
  for (final MapEntry(key: id, value: step) in steps.entries) {
    final r = b.reports[id]!;
    if (await ctx.checkpoint()) {
      r
        ..status = 'skipped'
        ..summary = 'Stopped before this step.';
      continue;
    }
    if (b.plan.off.contains(id) && id != 'scout') {
      r
        ..status = 'skipped'
        ..summary = 'Switched off.';
      continue;
    }
    final start = nowMs();
    r.status = 'working';
    ctx.message = crewMessage(id, '${crewAgentById(id)!.role}…');
    try {
      final skip = await step();
      if (skip != null && r.summary.isEmpty) {
        r
          ..status = 'skipped'
          ..summary = skip;
      } else {
        r.status = 'done';
      }
    } on Object catch (e) {
      r
        ..status = 'failed'
        ..summary = '$e'.replaceFirst('Exception: ', '');
    }
    r.ms = nowMs() - start;
  }
}

int _count(Catalogue cat, String sql, [List<Object?> args = const []]) =>
    cat.db.select(sql, args).first['n'] as int;

/// Scout: scope, what is unanalysed, what is missing tags.
String? _scout(CrewBoard b) {
  final cat = b.cat;
  final present =
      "t.presence='present' AND t.read_status='ok' AND t.media_kind IS NOT 'video'";
  List<int> ids(String sql, [List<Object?> args = const []]) => [
    for (final r in cat.db.select(sql, args)) r['id'] as int,
  ];
  final all = ids('SELECT t.id FROM tracks t WHERE $present ORDER BY t.id');
  final pending = {for (final x in AnalysisStore(cat).pending()) x.$1};
  final missing = ids(
    'SELECT t.id FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
    'WHERE $present AND ('
    'COALESCE(u.title, t.title) IS NULL OR COALESCE(u.artist, t.artist) IS NULL OR '
    'COALESCE(u.genre, t.genre) IS NULL OR COALESCE(u.year, t.year) IS NULL OR '
    'COALESCE(u.bpm, t.bpm_tag) IS NULL OR COALESCE(u.musical_key, t.key_tag) IS NULL OR '
    'COALESCE(u.record_label, t.label) IS NULL) ORDER BY t.id',
  ).toSet();
  final chosen = b.plan.ids?.toSet();
  b.scope = switch (b.plan.scope) {
    'ids' => all.where((i) => chosen?.contains(i) ?? false).toList(),
    'all' => all,
    _ => all.where((i) => pending.contains(i) || missing.contains(i)).toList(),
  };
  final inScope = b.scope.toSet();
  b.unanalysed = [
    for (final i in b.scope)
      if (pending.contains(i) || b.plan.scope == 'all') i,
  ];
  b.incomplete = [
    for (final i in missing)
      if (inScope.contains(i)) i,
  ];
  b.missingBefore = missingCounts(cat);
  b.suggestionsBefore = _count(
    cat,
    "SELECT COUNT(*) AS n FROM suggestions WHERE status='pending'",
  );
  final r = b.reports['scout']!;
  if (b.scope.isEmpty) {
    r.summary = 'Nothing to do: every track is analysed and tagged.';
    return null;
  }
  r.summary =
      '${b.scope.length} track(s) in scope: ${b.unanalysed.length} to analyse, '
      '${b.incomplete.length} missing tags.';
  return null;
}

/// Listener: audio analysis of the tracks that need it.
Future<String?> _listener(
  CrewBoard b,
  JobProgress ctx,
  Future<void> Function(List<int>, JobProgress)? listen,
) async {
  if (b.unanalysed.isEmpty) return 'Every track in scope is already analysed.';
  final ids = b.unanalysed;
  if (listen != null) {
    await listen(ids, ctx);
  } else {
    await analysisJob(b.plan.dbPath, only: ids, force: b.plan.scope == 'all')(
      ctx as JobContext,
    );
  }
  ctx.message = crewMessage('listener', 'Listened to ${ids.length} track(s).');
  final ok = _count(
    b.cat,
    "SELECT COUNT(*) AS n FROM analysis WHERE status='ok' AND track_id IN "
    '(${List.filled(ids.length, '?').join(',')})',
    ids,
  );
  b.reports['listener']!.summary =
      'Analysed ${ids.length} track(s): BPM, key and energy for $ok.';
  return null;
}

/// Detective: suggestions from names, folders, albums and spellings.
String? _detective(CrewBoard b) {
  final n = b.clues = SuggestionsService(b.cat).generateLocal();
  b.reports['detective']!.summary = n == 0
      ? 'No new clues in file and folder names.'
      : 'Found $n clue(s) in file names, folders and spellings.';
  return null;
}

/// Librarian: the switched-on online services.
Future<String?> _librarian(
  CrewBoard b,
  JobProgress ctx,
  List<OnlineStep> steps,
) async {
  if (steps.isEmpty) return 'No online services are switched on.';
  if (b.incomplete.isEmpty) return 'No track in scope is missing details.';
  var n = 0;
  for (final step in steps) {
    if (await ctx.checkpoint()) break;
    n += await step(b.cat, ctx as JobContext);
  }
  b.onlineChecked = n;
  b.reports['librarian']!.summary = n == 0
      ? 'Checked the online catalogues; nothing new.'
      : 'Checked $n track(s) in the online catalogues.';
  return null;
}

/// Taggers: OneTagger and beets on copies of tracks still missing details.
Future<String?> _taggers(CrewBoard b, JobProgress ctx) async {
  if (b.plan.taggerExe.isEmpty) {
    return 'OneTagger and beets are not installed or are switched off '
        '(see Analysis → Taggers).';
  }
  if (b.incomplete.isEmpty) return 'No track in scope is missing details.';
  final svc = TaggerService(b.cat, b.plan.dataDir);
  final ids = b.incomplete.take(b.plan.taggerLimit).toList();
  final ws = svc.create(ids, label: 'Analysis Crew');
  final ran = <String>[], failed = <String>[];
  for (final MapEntry(key: tool, value: exe) in b.plan.taggerExe.entries) {
    if (await ctx.checkpoint()) break;
    final name = taggerById(tool)?.name ?? tool;
    ctx.message = crewMessage('taggers', '$name is working on copies…');
    try {
      await runAutomaticTool(
        ws,
        tool,
        exe,
        platforms: b.plan.platforms,
        beetsPlugins: b.plan.beetsPlugins,
      );
      ran.add(name);
    } on Object catch (e) {
      failed.add('$name (${'$e'.split('\n').first})');
    }
  }
  final merged = svc.merge(TaggerWorkspace.load(ws.dir));
  b.reports['taggers']!.summary = [
    if (ran.isNotEmpty)
      '${ran.join(' and ')} tagged copies of ${ids.length} track(s): '
          '$merged finding(s).',
    if (failed.isNotEmpty) 'Could not finish: ${failed.join('; ')}.',
  ].join(' ');
  if (ran.isEmpty && failed.isNotEmpty) throw TaggerException(failed.first);
  return null;
}

const _judgeMark = ' · Judge: ';

/// Half/double time can't be heard, but the genre settles it: tracks whose
/// analysed tempo sits outside their genre's range (when an octave fits)
/// are analysed again with the genre as a hint, so tempo and beatgrid stay
/// consistent. Only with Settings → BPM range on automatic.
int _relisten(CrewBoard b) {
  final cat = b.cat;
  final range = cat.getSetting('bpm_range');
  if (range != null && range != 'auto') return 0;
  final rows = cat.db.select(
    'SELECT a.track_id AS id, a.bpm, t.path, t.file_size, t.file_mtime, '
    'COALESCE(u.genre, t.genre) AS genre FROM analysis a '
    'JOIN tracks t ON t.id=a.track_id LEFT JOIN track_user u ON u.track_id=t.id '
    "WHERE a.status='ok' AND a.bpm IS NOT NULL AND t.presence='present' "
    'AND COALESCE(u.genre, t.genre) IS NOT NULL',
  );
  final store = AnalysisStore(cat);
  final minutes = limitOf(cat, 'analysis_minutes');
  var n = 0;
  for (final r in rows) {
    final bpm = (r['bpm'] as num).toDouble(), genre = r['genre'] as String;
    if (foldBpmForGenre(bpm, genre) == null) continue;
    try {
      store.storeResult(
        r['id'] as int,
        r['file_size'] as int,
        r['file_mtime'] as int?,
        an.analyseFile(
          r['path'] as String,
          seconds: minutes == null ? null : minutes * 60.0,
          genre: genre,
        ),
      );
      n++;
    } on Object {
      // unreadable now (drive gone): keep what we had
    }
  }
  if (n > 0) store.rescaleEnergy();
  return n;
}

/// Whether two BPMs are the same tempo, allowing half/double time.
bool sameTempo(double a, double b) {
  for (final f in const [1.0, 2.0, 0.5]) {
    if ((a * f - b).abs() <= 1.5) return true;
  }
  return false;
}

/// Judge: cross-examines pending suggestions.
///  * The same value from several agents: confidence +0.06 per extra agent.
///  * Different values for the same field: −0.05 and the rivals are named.
///  * BPM and key against what the Listener heard: agreement +0.08, a
///    half/double tempo or relative key +0.02, a clash −0.15, each scaled
///    by how sure the Listener was (×0.5 at no confidence, ×1 when certain).
/// Each suggestion is judged once per evidence version (an agent refreshing a
/// suggestion resets its evidence, so it is judged afresh).
String? _judge(CrewBoard b) {
  final cat = b.cat;
  final relistened = _relisten(b);
  final rows = cat.db.select(
    'SELECT s.id, s.track_id, s.field, s.suggested_value, s.source, s.evidence, '
    's.confidence, a.bpm AS a_bpm, a.camelot AS a_key, a.status AS a_status, '
    'a.bpm_confidence AS a_bpm_conf, a.key_confidence AS a_key_conf '
    'FROM suggestions s LEFT JOIN analysis a ON a.track_id=s.track_id '
    "WHERE s.status='pending'",
  );
  // (track, field) → value key → sources
  final groups = <(int, String), Map<String, Set<String>>>{};
  for (final r in rows) {
    final field = r['field'] as String;
    final k = agreeKey(field, r['suggested_value'] as String);
    groups
        .putIfAbsent((r['track_id'] as int, field), () => {})
        .putIfAbsent(k, () => {})
        .add(r['source'] as String);
  }
  var raised = 0, lowered = 0, judged = 0;
  for (final r in rows) {
    final evidence = (r['evidence'] as String?) ?? '';
    if (evidence.contains(_judgeMark)) continue;
    final id = r['id'] as int, field = r['field'] as String;
    final value = r['suggested_value'] as String;
    final source = r['source'] as String;
    var conf = (r['confidence'] as num?)?.toDouble() ?? 0.5;
    final notes = <String>[];
    var delta = 0.0;

    final byValue = groups[(r['track_id'] as int, field)]!;
    final mine = byValue[agreeKey(field, value)]!;
    final others = mine.where((s) => s != source).toList()..sort();
    if (others.isNotEmpty) {
      delta += 0.06 * others.length;
      notes.add('also found by ${others.join(', ')}');
    }
    final rivals = byValue.length - 1;
    if (rivals > 0) {
      delta -= 0.05;
      notes.add('$rivals other value(s) suggested');
    }
    if (r['a_status'] == 'ok' && source != 'analysis') {
      // the audio's say counts as much as the Listener was sure of it
      double sure(Object? c) =>
          0.5 + 0.5 * ((c as num?)?.toDouble() ?? 0.5).clamp(0.0, 1.0);
      if (field == 'bpm' && r['a_bpm'] != null) {
        final heard = (r['a_bpm'] as num).toDouble();
        final w = sure(r['a_bpm_conf']);
        final said = double.tryParse(value);
        if (said != null) {
          if ((heard - said).abs() <= 1.5) {
            delta += 0.08 * w;
            notes.add('the audio agrees (${rustNumber(heard)} BPM)');
          } else if (sameTempo(heard, said)) {
            delta += 0.02 * w;
            notes.add('half/double of the audio (${rustNumber(heard)} BPM)');
          } else {
            delta -= 0.15 * w;
            notes.add('the audio says ${rustNumber(heard)} BPM');
          }
        }
      }
      if (field == 'key' && r['a_key'] != null) {
        final heard = r['a_key'] as String;
        final w = sure(r['a_key_conf']);
        final said = normalizeKey(value);
        if (said != null) {
          if (said == heard) {
            delta += 0.08 * w;
            notes.add('the audio agrees ($heard)');
          } else if (_relative(said, heard)) {
            delta += 0.02 * w;
            notes.add('relative key of the audio ($heard)');
          } else {
            delta -= 0.15 * w;
            notes.add('the audio hears $heard');
          }
        }
      }
    }
    judged++;
    if (notes.isEmpty) {
      notes.add('no other agent had an opinion');
    }
    if (delta > 0) raised++;
    if (delta < 0) lowered++;
    conf = (conf + delta).clamp(0.05, 0.98);
    cat.db.execute(
      'UPDATE suggestions SET confidence=?, evidence=? WHERE id=?',
      [conf, '$evidence$_judgeMark${notes.join('; ')}', id],
    );
  }
  b.reports['judge']!.summary = [
    judged == 0
        ? 'Nothing new to cross-check.'
        : 'Cross-checked $judged suggestion(s): $raised more certain, '
              '$lowered less certain.',
    if (relistened > 0)
      'Had the Listener re-time $relistened track(s) to their genre '
          '(half/double time).',
  ].join(' ');
  return null;
}

/// 8A ↔ 8B: same number, other letter.
bool _relative(String a, String b) =>
    a.length >= 2 &&
    b.length >= 2 &&
    a.substring(0, a.length - 1) == b.substring(0, b.length - 1) &&
    a != b;

/// Clerk: applies the DJ's fix mode and counts what waits for review.
Future<String?> _clerk(CrewBoard b) async {
  final cat = b.cat;
  final mode = fixMode(cat);
  var applied = 0;
  if (mode != 'review') {
    // Fill gaps from the best evidence; replace existing values only when
    // very sure, and only in `auto` mode.
    applied = SuggestionsService(cat).acceptRecommended(
      0.35,
      mode == 'auto' ? autoFixMin(cat) : 2.0,
      by: 'auto',
    );
  }
  b.applied = applied;
  // write-through: what was just accepted goes into the files too
  if (fileSyncOn(cat) && fileSyncQueued(cat) > 0) {
    final (w, sk, f) = await flushFileSync(cat, dataDir: b.plan.dataDir);
    b.filesWritten = w;
    b.filesSkipped = sk;
    b.filesFailed = f;
  }
  final waiting = _count(
    cat,
    "SELECT COUNT(*) AS n FROM suggestions WHERE status='pending'",
  );
  final files = b.filesWritten + b.filesSkipped + b.filesFailed == 0
      ? ''
      : ' Wrote ${b.filesWritten} music file(s)'
            '${b.filesSkipped > 0 ? '; ${b.filesSkipped} already up to date or not writable (WAV, AIFF, Ogg…)' : ''}'
            '${b.filesFailed > 0 ? '; ${b.filesFailed} could not be written' : ''}.';
  b.reports['clerk']!.summary = switch (mode) {
    'review' =>
      '$waiting suggestion(s) wait for your review. Nothing was changed.'
          '$files',
    _ => 'Applied $applied fix(es) (undoable); $waiting left for review.$files',
  };
  return null;
}

/// The run's report: each agent's part and a one-line summary.
Map<String, Object?> crewReport(CrewBoard b) {
  final waiting = _count(
    b.cat,
    "SELECT COUNT(*) AS n FROM suggestions WHERE status='pending'",
  );
  final mode = fixMode(b.cat);
  final summary = b.scope.isEmpty
      ? 'Nothing to do: your library is analysed and tagged.'
      : mode == 'review'
      ? 'The crew worked on ${b.scope.length} track(s) and analysed '
            '${b.unanalysed.length}; $waiting suggestion(s) wait for your '
            'review. Nothing was changed.'
      : 'The crew worked on ${b.scope.length} track(s), analysed '
            '${b.unanalysed.length} and applied ${b.applied} fix(es); '
            '$waiting suggestion(s) left for you to review.';
  return {
    'finished_at': nowMs(),
    'scope': b.plan.scope,
    'tracks': b.scope.length,
    'agents': [for (final a in crewAgents) b.reports[a.id]!.toJson()],
    'new_suggestions': (waiting - b.suggestionsBefore).clamp(0, 1 << 30),
    'summary': summary,
    // what auto-prep has always reported
    'analysed': b.unanalysed.length,
    'suggestions_found': b.clues,
    'online_checked': b.onlineChecked,
    'fixes_applied': b.applied,
    'min_confidence': autoFixMin(b.cat),
    'fix_mode': mode,
    'left_to_review': waiting,
    'missing_before': b.missingBefore,
    'missing_after': missingCounts(b.cat),
  };
}

/// How many tracks miss each core detail (Library Health's counts).
Map<String, int> missingCounts(Catalogue cat) {
  final items = HealthService(cat).health()['items'] as List<HealthItem>;
  int get(String id) => items.where((i) => i.id == id).firstOrNull?.count ?? 0;
  return {
    for (final k in [
      'missing_core',
      'missing_genre',
      'missing_year',
      'missing_album',
      'missing_bpm',
      'missing_key',
    ])
      k: get(k),
  };
}

/// The last run's report, if any.
Map<String, Object?>? lastCrewReport(Catalogue cat) {
  final raw = cat.getSetting('crew_report');
  if (raw == null) return null;
  try {
    return Map<String, Object?>.from(jsonDecode(raw) as Map);
  } on Object {
    return null;
  }
}

/// Agents the DJ switched off (saved).
Set<String> crewOff(Catalogue cat) => (cat.getSetting('crew_off') ?? '')
    .split(',')
    .where((x) => x.isNotEmpty)
    .toSet();

void setCrewOff(Catalogue cat, Set<String> off) =>
    cat.setSetting('crew_off', (off..remove('scout')).join(','));
