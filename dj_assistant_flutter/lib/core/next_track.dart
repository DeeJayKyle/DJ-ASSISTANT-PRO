import 'dart:math' as math;

import 'catalogue.dart';
import 'keys.dart';
import 'snapshot.dart';

/// "Next up" for gig mode: given what has just been played, rank the library
/// by what mixes in next.
///
/// 1. **Mix gate.** A track passes when its tempo is inside a BPM window of
///    the last track (optionally at half or double time) and its key works on
///    the Camelot wheel (same code, one step round, or the relative
///    major/minor). In *loose* mode a one-semitone lift is let through too and
///    marked as a key change. A track with no BPM or key is let through but
///    flagged, rather than hidden.
/// 2. **Energy direction.** The target energy is the average of the last ten
///    played tracks, moved one step up (*Lift*), down (*Cool*) or not at all
///    (*Hold*), kept within 1–10.
/// 3. **Score.** Each scored quantity (closeness to the target energy, and
///    any extra measures such as loudness compared with the last track
///    *after* allowing for energy) is turned into a z-score over the tracks
///    that have it, then summed with its weight. Tracks without any score
///    keep library order after the scored ones.
/// 4. **Nothing mixes?** Each way of loosening the gate is offered with the
///    number of tracks it would open up.
///
/// Pure functions plus a small reader over the catalogue; nothing is written.
enum KeyGate { off, loose, strict }

enum EnergyDirection { cool, hold, lift }

/// BPM windows the gate steps through when loosened: exact, ±3, any tempo.
const bpmWindowSteps = <double?>[0, 3, null];
const defaultBpmWindow = 3.0;
const maxBpmWindow = 16.0;

/// How many recent plays set the target energy.
const energyTrailLength = 10;

class MixRules {
  const MixRules({
    this.bpmWindow = defaultBpmWindow,
    this.halfDouble = true,
    this.key = KeyGate.loose,
  });

  /// ± BPM; null lets any tempo through, 0 means the same rounded BPM.
  final double? bpmWindow;
  final bool halfDouble;
  final KeyGate key;

  MixRules copyWith({
    double? Function()? bpmWindow,
    bool? halfDouble,
    KeyGate? key,
  }) => MixRules(
    bpmWindow: bpmWindow == null ? this.bpmWindow : bpmWindow(),
    halfDouble: halfDouble ?? this.halfDouble,
    key: key ?? this.key,
  );
}

class NextTrackCandidate {
  const NextTrackCandidate({
    required this.id,
    this.bpm,
    this.camelot,
    this.energy,
    this.extras = const {},
    this.label = '',
  });
  final int id;
  final double? bpm;

  /// Camelot code such as "8A"; anything [normalizeKey] understands is fine.
  final String? camelot;

  /// 1–10.
  final double? energy;

  /// Extra measures compared with the last track after allowing for energy,
  /// by name (e.g. `loudness`).
  final Map<String, double> extras;
  final String label;
}

class GateResult {
  const GateResult(this.pass, {this.flagged = false, this.keyChange = false});
  final bool pass;

  /// BPM or key unknown, so the gate could not judge it.
  final bool flagged;

  /// Passes only as a one-semitone key change (loose mode).
  final bool keyChange;
}

class NextTrackSuggestion {
  const NextTrackSuggestion({
    required this.candidate,
    required this.score,
    required this.scored,
    required this.reasons,
    this.flagged = false,
    this.keyChange = false,
  });
  final NextTrackCandidate candidate;
  final double score;
  final bool scored;
  final List<String> reasons;
  final bool flagged;
  final bool keyChange;
}

class LoosenOption {
  const LoosenOption(
    this.label,
    this.opensUp,
    this.gate, {
    this.clashes = false,
  });
  final String label;
  final int opensUp;
  final MixRules gate;

  /// Loosening the key gate lets key clashes through.
  final bool clashes;
}

class NextTrackResult {
  const NextTrackResult({
    required this.suggestions,
    required this.mixable,
    required this.total,
    required this.targetEnergy,
    this.loosen = const [],
  });
  final List<NextTrackSuggestion> suggestions;
  final int mixable;
  final int total;
  final double? targetEnergy;
  final List<LoosenOption> loosen;
}

// --- Camelot -------------------------------------------------------------

/// (number 1–12, minor) for a key in any notation, or null.
(int, bool)? camelotParts(String? key) {
  if (key == null || key.trim().isEmpty) return null;
  final c = normalizeKey(key);
  if (c == null) return null;
  final n = int.tryParse(c.substring(0, c.length - 1));
  if (n == null) return null;
  return (n, c.endsWith('A'));
}

int wheelSteps(int a, int b) {
  final d = (a - b).abs() % 12;
  return math.min(d, 12 - d);
}

bool _harmonic((int, bool) a, (int, bool) b) =>
    a.$2 == b.$2 ? wheelSteps(a.$1, b.$1) <= 1 : a.$1 == b.$1;

// --- Gates ---------------------------------------------------------------

GateResult checkTempo(double? candidate, double? anchor, MixRules g) {
  final w = g.bpmWindow;
  if (w == null || anchor == null || anchor <= 0) return const GateResult(true);
  if (candidate == null || candidate <= 0) {
    return const GateResult(true, flagged: true);
  }
  if (w <= 0) return GateResult(candidate.round() == anchor.round());
  bool near(double b) => (b - anchor).abs() <= w;
  return GateResult(
    near(candidate) ||
        (g.halfDouble && (near(candidate * 2) || near(candidate / 2))),
  );
}

GateResult checkKey(String? candidate, String? anchor, KeyGate mode) {
  if (mode == KeyGate.off) return const GateResult(true);
  final a = camelotParts(anchor);
  if (a == null) return const GateResult(true);
  final c = camelotParts(candidate);
  if (c == null) return const GateResult(true, flagged: true);
  if (_harmonic(c, a)) return const GateResult(true);
  // seven steps round the wheel (five the short way) is one semitone
  final semitone = c.$2 == a.$2 && wheelSteps(c.$1, a.$1) == 5;
  if (mode == KeyGate.loose && semitone) {
    return const GateResult(true, keyChange: true);
  }
  return const GateResult(false);
}

GateResult mixGate(
  NextTrackCandidate c,
  NextTrackCandidate? anchor,
  MixRules g,
) {
  final b = checkTempo(c.bpm, anchor?.bpm, g);
  final k = checkKey(c.camelot, anchor?.camelot, g.key);
  return GateResult(
    b.pass && k.pass,
    flagged: b.flagged || k.flagged,
    keyChange: k.keyChange,
  );
}

int _mixableCount(
  List<NextTrackCandidate> pool,
  NextTrackCandidate? anchor,
  MixRules g,
) => pool.where((c) => mixGate(c, anchor, g).pass).length;

List<LoosenOption> loosenOptions(
  List<NextTrackCandidate> pool,
  NextTrackCandidate? anchor,
  MixRules g,
) {
  final now = _mixableCount(pool, anchor, g);
  final out = <LoosenOption>[];
  final i = bpmWindowSteps.indexOf(g.bpmWindow);
  if (g.bpmWindow != null) {
    // the next step up the ladder; a custom window goes straight to "any"
    final wider = i >= 0 && i + 1 < bpmWindowSteps.length
        ? bpmWindowSteps[i + 1]
        : null;
    final ng = g.copyWith(bpmWindow: () => wider);
    final n = _mixableCount(pool, anchor, ng) - now;
    if (n > 0) {
      out.add(
        LoosenOption(
          wider == null ? 'Any tempo' : 'BPM ±${_num(wider)}',
          n,
          ng,
        ),
      );
    }
  }
  if (g.key == KeyGate.strict) {
    final ng = g.copyWith(key: KeyGate.loose);
    final n = _mixableCount(pool, anchor, ng) - now;
    if (n > 0) {
      out.add(LoosenOption('Allow key changes', n, ng, clashes: true));
    }
  }
  if (g.key != KeyGate.off) {
    final ng = g.copyWith(key: KeyGate.off);
    final n = _mixableCount(pool, anchor, ng) - now;
    if (n > 0) out.add(LoosenOption('Any key', n, ng, clashes: true));
  }
  return out;
}

String _num(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

// --- Energy --------------------------------------------------------------

double? targetEnergy(List<double?> playedEnergies, EnergyDirection d) {
  final recent = playedEnergies.length > energyTrailLength
      ? playedEnergies.sublist(playedEnergies.length - energyTrailLength)
      : playedEnergies;
  final e = recent.whereType<double>().toList();
  if (e.isEmpty) return null;
  final mean = e.reduce((a, b) => a + b) / e.length;
  final step = switch (d) {
    EnergyDirection.lift => 1.0,
    EnergyDirection.cool => -1.0,
    EnergyDirection.hold => 0.0,
  };
  return (mean + step).clamp(1.0, 10.0);
}

// --- Scoring -------------------------------------------------------------

/// Population z-scores; all zero when the values barely vary.
Map<int, double> zScores(Map<int, double> values) {
  if (values.isEmpty) return const {};
  final n = values.length;
  final mean = values.values.reduce((a, b) => a + b) / n;
  var v = 0.0;
  for (final x in values.values) {
    v += (x - mean) * (x - mean);
  }
  final sd = math.sqrt(v / n);
  return {
    for (final e in values.entries)
      e.key: sd < 1e-6 ? 0 : (e.value - mean) / sd,
  };
}

/// How close each track is to the anchor on [axis] once the part explained by
/// energy is taken out (a straight-line fit of axis on energy over the pool
/// and the anchor). Higher is closer. Empty when there is too little data.
Map<int, double> residualCloseness(
  List<(int, double, double)> rows, // (id, energy, axis)
  (double, double) anchor,
) {
  if (rows.length < 3) return const {};
  final pts = [for (final r in rows) (r.$2, r.$3), anchor];
  final n = pts.length;
  final me = pts.map((p) => p.$1).reduce((a, b) => a + b) / n;
  final ma = pts.map((p) => p.$2).reduce((a, b) => a + b) / n;
  var cov = 0.0, ve = 0.0;
  for (final p in pts) {
    cov += (p.$1 - me) * (p.$2 - ma);
    ve += (p.$1 - me) * (p.$1 - me);
  }
  if (ve / n < 1e-9) return const {};
  final slope = cov / ve;
  double resid(double e, double a) => a - (ma + slope * (e - me));
  final target = resid(anchor.$1, anchor.$2);
  return {for (final r in rows) r.$1: -(resid(r.$2, r.$3) - target).abs()};
}

const extraWeight = 0.5;

NextTrackResult rankNextTracks({
  required List<NextTrackCandidate> library,
  required NextTrackCandidate? anchor,
  required List<double?> playedEnergies,
  Set<int> exclude = const {},
  EnergyDirection direction = EnergyDirection.hold,
  MixRules gate = const MixRules(),
  int limit = 12,
}) {
  final pool = [
    for (final c in library)
      if (!exclude.contains(c.id) && c.id != anchor?.id) c,
  ];
  final target = targetEnergy(playedEnergies, direction);
  final gated = <int, GateResult>{};
  final mixable = <NextTrackCandidate>[];
  for (final c in pool) {
    final r = mixGate(c, anchor, gate);
    if (r.pass) {
      gated[c.id] = r;
      mixable.add(c);
    }
  }

  // each scored quantity, z-scored over the whole pool so a score means the
  // same whatever the gate lets through
  final terms = <(double, Map<int, double>)>[];
  if (target != null) {
    terms.add((
      1.0,
      zScores({
        for (final c in pool)
          if (c.energy != null)
            c.id: math.max(0, 1 - (c.energy! - target).abs() / 5),
      }),
    ));
  }
  final ae = anchor?.energy;
  if (anchor != null && ae != null) {
    for (final name in anchor.extras.keys) {
      final rows = [
        for (final c in pool)
          if (c.energy != null && c.extras[name] != null)
            (c.id, c.energy!, c.extras[name]!),
      ];
      final m = residualCloseness(rows, (ae, anchor.extras[name]!));
      if (m.isNotEmpty) terms.add((extraWeight, zScores(m)));
    }
  }

  final scored = <(NextTrackCandidate, double, bool, int)>[];
  for (var i = 0; i < mixable.length; i++) {
    final c = mixable[i];
    var s = 0.0;
    var has = false;
    for (final (w, z) in terms) {
      final v = z[c.id];
      if (v == null) continue;
      has = true;
      s += w * v;
    }
    scored.add((c, s, has, i));
  }
  scored.sort((a, b) {
    if (a.$3 != b.$3) return a.$3 ? -1 : 1;
    if (!a.$3) return a.$4.compareTo(b.$4);
    final d = b.$2.compareTo(a.$2);
    return d != 0 ? d : a.$4.compareTo(b.$4);
  });

  return NextTrackResult(
    suggestions: [
      for (final (c, s, has, _) in scored.take(limit))
        NextTrackSuggestion(
          candidate: c,
          score: s,
          scored: has,
          flagged: gated[c.id]!.flagged,
          keyChange: gated[c.id]!.keyChange,
          reasons: _reasons(c, anchor, target, gated[c.id]!),
        ),
    ],
    mixable: mixable.length,
    total: pool.length,
    targetEnergy: target,
    loosen: mixable.isEmpty ? loosenOptions(pool, anchor, gate) : const [],
  );
}

List<String> _reasons(
  NextTrackCandidate c,
  NextTrackCandidate? anchor,
  double? target,
  GateResult g,
) {
  final out = <String>[];
  final a = camelotParts(anchor?.camelot), k = camelotParts(c.camelot);
  if (g.keyChange) {
    out.add('Key +1 semitone');
  } else if (a != null && k != null) {
    out.add(
      a == k
          ? 'Same key'
          : a.$2 != k.$2
          ? 'Relative key'
          : 'Key ±1',
    );
  }
  final ab = anchor?.bpm, cb = c.bpm;
  if (ab != null && cb != null && ab > 0 && cb > 0) {
    final d = (cb - ab).abs();
    if ((cb * 2 - ab).abs() < d || (cb / 2 - ab).abs() < d) {
      out.add(cb > ab ? 'Half time' : 'Double time');
    } else if (d < 0.5) {
      out.add('Same tempo');
    } else {
      out.add('${cb > ab ? '+' : '−'}${_num((d * 10).round() / 10)} BPM');
    }
  }
  if (target != null && c.energy != null) {
    final d = c.energy! - (anchor?.energy ?? target);
    if (d.abs() < 0.5) {
      out.add('Holds energy');
    } else {
      out.add(d > 0 ? 'Lifts energy' : 'Cools energy');
    }
  }
  if (g.flagged) out.add('BPM or key unknown');
  return out;
}

// --- Catalogue reader ----------------------------------------------------

/// Reads candidates from the catalogue: the DJ's own values win over the
/// analysis. Only present audio files are included.
class NextTrackService {
  NextTrackService(this.cat);
  final Catalogue cat;

  /// Cached until the catalogue changes (read-only).
  List<NextTrackCandidate> candidates({int max = 100000}) => snapshot(
    cat,
    'next-candidates-$max',
    () => List<NextTrackCandidate>.unmodifiable(_candidates(max)),
  );

  List<NextTrackCandidate> _candidates(int max) => [
    for (final r in cat.db.select(
      'SELECT t.id, COALESCE(u.bpm, a.bpm, t.bpm_tag) AS bpm, '
      'COALESCE(u.musical_key, a.camelot, a.musical_key, t.key_tag) AS k, '
      'COALESCE(u.energy, a.energy) AS en, a.loudness_lufs AS lufs, '
      "COALESCE(u.artist, t.artist, '') AS artist, "
      'COALESCE(u.title, t.title, t.file_name) AS title '
      'FROM tracks t LEFT JOIN track_user u ON u.track_id=t.id '
      'LEFT JOIN analysis a ON a.track_id=t.id '
      "WHERE t.presence='present' AND t.removed_at IS NULL "
      "AND t.media_kind='audio' ORDER BY t.id LIMIT ?",
      [max],
    ))
      NextTrackCandidate(
        id: r['id'] as int,
        bpm: (r['bpm'] as num?)?.toDouble(),
        camelot: r['k'] as String?,
        energy: (r['en'] as num?)?.toDouble(),
        extras: {
          if (r['lufs'] != null) 'loudness': (r['lufs'] as num).toDouble(),
        },
        label: (r['artist'] as String).isEmpty
            ? '${r['title']}'
            : '${r['artist']} — ${r['title']}',
      ),
  ];

  /// Suggestions after the [played] track ids (oldest first).
  NextTrackResult suggest(
    List<int> played, {
    EnergyDirection direction = EnergyDirection.hold,
    MixRules gate = const MixRules(),
    int limit = 12,
  }) {
    // the same question on an unchanged catalogue (a redraw) is answered
    // from the last result
    final ask =
        '${played.join(',')}|${direction.name}|${gate.bpmWindow}|'
        '${gate.halfDouble}|${gate.key.name}|$limit';
    final last = peekSnapshot(cat, 'next-up');
    if (last is (String, NextTrackResult) && last.$1 == ask) return last.$2;
    final r = _rank(played, direction, gate, limit);
    rememberSnapshot(cat, 'next-up', (ask, r));
    return r;
  }

  NextTrackResult _rank(
    List<int> played,
    EnergyDirection direction,
    MixRules gate,
    int limit,
  ) {
    final lib = candidates();
    final byId = {for (final c in lib) c.id: c};
    return rankNextTracks(
      library: lib,
      anchor: played.isEmpty ? null : byId[played.last],
      playedEnergies: [for (final id in played) byId[id]?.energy],
      exclude: played.toSet(),
      direction: direction,
      gate: gate,
      limit: limit,
    );
  }
}
