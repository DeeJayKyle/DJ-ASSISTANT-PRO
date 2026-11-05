import 'analysis_store.dart';
import 'catalogue.dart';
import 'health.dart';
import 'jobs.dart';
import 'suggestions.dart';

/// Auto-prep (1.x `autoprep.rs`), what happens by itself after new music is scanned:
///
/// 1. Audio analysis of tracks not analysed yet.
/// 2. Local suggestions from file names, folders, albums and artists.
/// 3. Online lookups for tracks still missing details — only for services the DJ
///    switched on ([onlineSteps]).
/// 4. High-confidence suggestions are accepted into the catalogue.
///
/// Everything lands in the catalogue only; writing fixes into files is a separate,
/// previewed step the DJ approves.
typedef OnlineStep = Future<int> Function(Catalogue cat, JobContext ctx);

bool autoPrepEnabled(Catalogue cat) =>
    (cat.getSetting('auto_prep') ?? '1') == '1';

double autoFixMin(Catalogue cat) {
  final v = double.tryParse(cat.getSetting('auto_fix_min') ?? '');
  return (v != null && v >= 0.5 && v <= 1.0) ? v : 0.85;
}

Map<String, int> _missing(Catalogue cat) {
  final items = HealthService(cat).health()['items'] as List<HealthItem>;
  int get(String id) => items.firstWhere((i) => i.id == id).count;
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

/// The auto-prep job body. [onlineSteps] run only when their services are on.
JobBody autoPrepJob(
  String dbPath, {
  List<OnlineStep> onlineSteps = const [],
}) => (ctx) async {
  final cat = Catalogue.open(dbPath);
  try {
    final before = _missing(cat);
    final pending = AnalysisStore(cat).pending().length;
    ctx.message = 'Analysing $pending track(s)…';
    if (pending > 0) await analysisJob(dbPath)(ctx);
    if (await ctx.checkpoint()) return;
    ctx.message =
        'Looking for fixes in file names, folders, albums and artists…';
    final created = SuggestionsService(cat).generateLocal();
    var online = 0;
    for (final step in onlineSteps) {
      if (await ctx.checkpoint()) return;
      online += await step(cat, ctx);
    }
    final min = autoFixMin(cat);
    ctx.message = 'Applying recommended fixes to your catalogue…';
    // Fill gaps from the best evidence; replace existing values only when very sure.
    final applied = SuggestionsService(cat).acceptRecommended(0.35, min);
    final toReview =
        cat.db
                .select(
                  "SELECT COUNT(*) AS n FROM suggestions WHERE status='pending'",
                )
                .first['n']
            as int;
    ctx
      ..result = {
        'analysed': pending,
        'suggestions_found': created,
        'online_checked': online,
        'fixes_applied': applied, //
        'min_confidence': min,
        'left_to_review': toReview,
        'missing_before': before,
        'missing_after': _missing(cat),
      }
      ..message =
          'Done: analysed $pending, applied $applied fix(es); $toReview suggestion(s) left for you to review.';
  } finally {
    cat.close();
  }
};
