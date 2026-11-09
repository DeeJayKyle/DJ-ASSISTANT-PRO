import 'next_track.dart' show KeyGate, camelotParts, wheelSteps;
import 'profile.dart';
import 'text.dart';

/// Checks a running order the way a DJ would before a gig: how hard each
/// mix is (a grade), and what to look at on each slot (issues).
///
/// Grades, from the tempo change (as a percentage, half/double time counted
/// when allowed) and the key move on the Camelot wheel:
///
/// | grade    | key move                          | tempo change |
/// |----------|-----------------------------------|--------------|
/// | smooth   | same key, ±1 or relative          | ≤ 2 %        |
/// | good     | same key, ±1 or relative          | ≤ 4 %        |
/// | workable | also ±2 or a one-semitone lift    | ≤ 6 %        |
/// | clash    | anything else                     |              |
///
/// With the key rule off, only tempo grades the mix. Unknown BPM or key
/// grades as "unknown" rather than guessing.
enum MixGrade { smooth, good, workable, clash, unknown }

class SetRules {
  const SetRules({
    this.key = KeyGate.loose,
    this.halfDouble = true,
    this.artistGapMin = 20,
    this.startBpm,
    this.endBpm,
    this.bpmPathTolerance = 4,
    this.energyTolerance = 2.5,
  });
  final KeyGate key;
  final bool halfDouble;

  /// Minutes before the same artist may play again.
  final int artistGapMin;

  /// A tempo ramp across the set; null keeps any tempo.
  final double? startBpm, endBpm;
  final double bpmPathTolerance;
  final double energyTolerance;

  bool get hasRamp => startBpm != null && endBpm != null;

  /// The ramp's tempo at [t] (0–1 through the set).
  double? bpmAt(double t) =>
      hasRamp ? startBpm! + (endBpm! - startBpm!) * t.clamp(0.0, 1.0) : null;

  Map<String, Object?> toJson() => {
    'key_mode': key.name,
    'half_double': halfDouble,
    'artist_gap_min': artistGapMin,
    'start_bpm': startBpm,
    'end_bpm': endBpm,
  };
}

/// Tempo change from [a] to [b] as a fraction, using half or double time
/// when that is closer and allowed.
double tempoChange(double a, double b, {bool halfDouble = true}) {
  var best = (b - a).abs() / a;
  if (halfDouble) {
    for (final m in [0.5, 2.0]) {
      final d = (b * m - a).abs() / a;
      if (d < best) best = d;
    }
  }
  return best;
}

/// Key move cost: 0 same key, 1 for ±1 or relative, 2 for ±2 or (loose)
/// a one-semitone lift, 3 for anything else; null when a key is unknown.
int? keyMoveCost(String? from, String? to, KeyGate mode) {
  final a = camelotParts(from), b = camelotParts(to);
  if (a == null || b == null) return null;
  if (a == b) return 0;
  final steps = wheelSteps(a.$1, b.$1);
  if (a.$2 == b.$2) {
    if (steps == 1) return 1;
    if (steps == 2) return 2;
    if (steps == 5 && mode == KeyGate.loose) return 2;
    return 3;
  }
  return steps == 0 ? 1 : 3;
}

MixGrade gradeMix(Tp from, Tp to, SetRules r) {
  final x = from.bpm, y = to.bpm;
  if (x == null || y == null || x <= 0 || y <= 0) return MixGrade.unknown;
  final tempo = tempoChange(x, y, halfDouble: r.halfDouble);
  final key = r.key == KeyGate.off ? 0 : keyMoveCost(from.key, to.key, r.key);
  if (key == null) return MixGrade.unknown;
  if (key <= 1 && tempo <= 0.02) return MixGrade.smooth;
  if (key <= 1 && tempo <= 0.04) return MixGrade.good;
  if (key <= 2 && tempo <= 0.06) return MixGrade.workable;
  return MixGrade.clash;
}

class SlotCheck {
  const SlotCheck(this.grade, this.issues);

  /// The mix into this slot; null for the first track.
  final MixGrade? grade;
  final List<String> issues;

  Map<String, Object?> toJson() => {'grade': grade?.name, 'issues': issues};
}

/// Grades and issues for each track of a running order. [startMs] gives
/// each slot's start (for artist spacing); [targets] the planned energy.
List<SlotCheck> checkSet(
  List<Tp?> order,
  SetRules r, {
  List<int>? startMs,
  List<double?>? targets,
}) {
  final out = <SlotCheck>[];
  final lastSeen = <String, int>{}; // artist → slot index
  final n = order.length;
  for (var i = 0; i < n; i++) {
    final t = order[i];
    if (t == null) {
      out.add(const SlotCheck(null, ['Track no longer in the library']));
      continue;
    }
    final issues = <String>[];
    final prev = i > 0 ? order[i - 1] : null;
    MixGrade? grade;
    if (prev != null) {
      grade = gradeMix(prev, t, r);
      final x = prev.bpm, y = t.bpm;
      if (x != null && y != null && x > 0 && y > 0) {
        final c = tempoChange(x, y, halfDouble: r.halfDouble);
        if (c > 0.06) {
          issues.add(
            'Tempo jump ${x.toStringAsFixed(0)} → ${y.toStringAsFixed(0)} BPM',
          );
        }
      }
      if (r.key != KeyGate.off &&
          (keyMoveCost(prev.key, t.key, r.key) ?? 0) >= 3) {
        issues.add('Key clash ${prev.key} → ${t.key}');
      }
    }
    if (t.bpm == null || t.key == null) {
      issues.add('BPM or key unknown: analyse this track');
    }
    final who = fold(t.artist).trim();
    if (who.isNotEmpty && lastSeen.containsKey(who)) {
      final j = lastSeen[who]!;
      final gapMin = startMs == null
          ? null
          : ((startMs[i] - startMs[j]) / 60000).round();
      final close = gapMin == null ? i - j <= 3 : gapMin < r.artistGapMin;
      if (close) {
        issues.add(
          gapMin == null
              ? 'Same artist ${i - j} tracks ago'
              : 'Same artist $gapMin min ago',
        );
      }
    }
    if (who.isNotEmpty) lastSeen[who] = i;
    final pos = n > 1 ? i / (n - 1) : 0.0;
    final want = r.bpmAt(pos);
    if (want != null && t.bpm != null) {
      final off = tempoChange(want, t.bpm!, halfDouble: r.halfDouble) * want;
      if (off > r.bpmPathTolerance) {
        issues.add(
          'Off the tempo path: ${t.bpm!.toStringAsFixed(0)} BPM where ${want.toStringAsFixed(0)} is planned',
        );
      }
    }
    final target = targets == null || i >= targets.length ? null : targets[i];
    if (target != null &&
        t.energy != null &&
        (t.energy! - target).abs() > r.energyTolerance) {
      issues.add(
        'Energy ${t.energy} where ${target.toStringAsFixed(1)} is planned',
      );
    }
    out.add(SlotCheck(grade, issues));
  }
  return out;
}

/// Counts of each grade, for a one-line summary.
Map<String, int> gradeCounts(List<SlotCheck> checks) {
  final m = <String, int>{};
  for (final c in checks) {
    final g = c.grade;
    if (g != null) m[g.name] = (m[g.name] ?? 0) + 1;
  }
  return m;
}
