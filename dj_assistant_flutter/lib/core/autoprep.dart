import 'package:path/path.dart' as p;

import 'catalogue.dart';
import 'crew.dart';
import 'jobs.dart';

/// Auto-prep (1.x `autoprep.rs`), what happens by itself after new music is
/// scanned: the Analysis Crew (crew.dart) runs every analyser as one team —
/// audio analysis, local evidence, the online services the DJ switched on,
/// the installed taggers — then the Judge cross-checks their findings.
/// What happens to the suggestions depends on [fixMode]:
///    * `review` (default): nothing is accepted; every suggestion waits in
///      Suggestions for the DJ to approve one by one or in batches.
///    * `fill_empty`: empty fields are filled from the best evidence; existing
///      values are never replaced.
///    * `auto` (the behaviour before 2.4): empty fields are filled, and existing
///      values are replaced at or above [autoFixMin].
///
/// Everything lands in the catalogue only; writing fixes into files is a separate,
/// previewed step the DJ approves. Every automatic change is recorded and can be
/// undone exactly (Suggestions → Accepted → Undo).
typedef OnlineStep = Future<int> Function(Catalogue cat, JobContext ctx);

bool autoPrepEnabled(Catalogue cat) =>
    (cat.getSetting('auto_prep') ?? '1') == '1';

const fixModes = ['review', 'fill_empty', 'auto'];

/// How auto-prep treats its suggestions; review-first unless the DJ chose otherwise.
String fixMode(Catalogue cat) {
  final v = cat.getSetting('fix_mode');
  return fixModes.contains(v) ? v! : 'review';
}

double autoFixMin(Catalogue cat) {
  final v = double.tryParse(cat.getSetting('auto_fix_min') ?? '');
  return (v != null && v >= 0.5 && v <= 1.0) ? v : 0.85;
}

/// Auto-prep is the Analysis Crew working on new, unanalysed and incomplete
/// tracks (see crew.dart): one function for every analyser. [onlineSteps] are
/// the Librarian's lookups, [taggerExe] the Taggers' installed programs.
JobBody autoPrepJob(
  String dbPath, {
  List<OnlineStep> onlineSteps = const [],
  String? dataDir,
  Map<String, String> taggerExe = const {},
  Set<String> off = const {},
}) => crewJob(
  CrewPlan(
    dbPath: dbPath,
    dataDir: dataDir ?? p.dirname(dbPath),
    off: off,
    taggerExe: taggerExe,
  ),
  onlineSteps: onlineSteps,
);
