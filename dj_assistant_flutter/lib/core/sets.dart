import 'dart:convert';

import 'catalogue.dart';
import 'crates.dart';
import 'keys.dart';
import 'library.dart';
import 'library_edit.dart';
import 'next_track.dart' show KeyGate;
import 'profile.dart';
import 'set_check.dart';
import 'text.dart';

/// Set Studio (1.x `sets.rs`): an editable running order for an event, length
/// and energy journey. Every pick and transition comes with its reasons; plans
/// are suggestions, never guaranteed to mix well.
class SetException implements Exception {
  SetException(this.message);
  final String message;
  @override
  String toString() => message;
}

Never _no(String m) => throw SetException(m);

class SetParams {
  SetParams({
    required this.durationMin,
    this.name,
    this.eventType,
    this.audience,
    this.genres = const [],
    this.mustPlay = const [],
    this.exclude = const [],
    this.excludeTags = const [],
    this.cleanOnly = false,
    this.curve,
    this.customCurve = const [],
    this.bpmMin,
    this.bpmMax,
    this.crateId,
    this.harmonic,
    this.minTrackSeconds,
    this.keyMode,
    this.halfDouble = true,
    this.startBpm,
    this.endBpm,
    this.openingTrackId,
    this.artistGapMin = 20,
    this.energyFloor,
    this.energyCeiling,
  });
  final int durationMin;
  final String? name, eventType, audience, curve;
  final List<String> genres, excludeTags;
  final List<int> mustPlay, exclude;
  final bool cleanOnly;
  final List<double> customCurve;
  final double? bpmMin, bpmMax;
  final int? crateId, minTrackSeconds;
  final bool? harmonic;

  /// 'off', 'loose' or 'strict'; null follows [harmonic] (off when false).
  final String? keyMode;
  final bool halfDouble;

  /// A tempo ramp: the set starts near [startBpm] and ends near [endBpm].
  final double? startBpm, endBpm;

  /// Played first when it is in the library.
  final int? openingTrackId;

  /// Minutes before the same artist plays again.
  final int artistGapMin;

  /// The curve is squeezed between these energies (1–10) when set.
  final double? energyFloor, energyCeiling;

  KeyGate get keyRule => switch (keyMode) {
    'off' => KeyGate.off,
    'strict' => KeyGate.strict,
    'loose' => KeyGate.loose,
    _ => harmonic == false ? KeyGate.off : KeyGate.loose,
  };

  SetRules get rules => SetRules(
    key: keyRule,
    halfDouble: halfDouble,
    artistGapMin: artistGapMin,
    startBpm: startBpm,
    endBpm: endBpm,
  );

  /// The curve's value at [t], scaled into the floor–ceiling band.
  double energyAt(List<double> pts, double t) {
    final v = _targetAt(pts, t);
    final lo = energyFloor, hi = energyCeiling;
    if (lo == null || hi == null || hi <= lo) return v;
    return lo + (v - 1) / 9 * (hi - lo);
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'event_type': eventType,
    'audience': audience,
    'duration_min': durationMin,
    'genres': genres, //
    'must_play': mustPlay,
    'exclude': exclude,
    'exclude_tags': excludeTags,
    'clean_only': cleanOnly,
    'curve': curve,
    'custom_curve': customCurve,
    'bpm_min': bpmMin,
    'bpm_max': bpmMax,
    'crate_id': crateId,
    'harmonic': harmonic,
    'min_track_seconds': minTrackSeconds,
    'key_mode': keyRule.name,
    'half_double': halfDouble,
    'start_bpm': startBpm,
    'end_bpm': endBpm,
    'opening_track_id': openingTrackId,
    'artist_gap_min': artistGapMin,
    'energy_floor': energyFloor,
    'energy_ceiling': energyCeiling,
  };
}

List<double> curvePoints(SetParams p) => switch (p.curve ?? 'journey') {
  'warmup' => [3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0],
  'peak' => [7.0, 8.0, 8.5, 9.0, 9.0, 9.5, 8.5],
  'wedding' => [4.0, 5.0, 6.0, 7.5, 8.5, 9.0, 8.0, 6.0],
  'lounge' => [3.0, 3.5, 4.0, 4.0, 4.5, 4.0, 3.5],
  'custom' when p.customCurve.length >= 2 => [
    for (final v in p.customCurve) v.clamp(1.0, 10.0),
  ],
  _ => [4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 8.5, 6.5],
};

double _targetAt(List<double> pts, double t) {
  final x = t.clamp(0.0, 1.0) * (pts.length - 1);
  final i = x.floor();
  final j = (i + 1).clamp(0, pts.length - 1);
  return pts[i] + (pts[j] - pts[i]) * (x - i);
}

String _signed(double v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}';

final _keyCompat = <String, bool>{};

/// The score part of [transitionNotes] without building any text; the key
/// check is remembered per pair of keys. Used to rank thousands of
/// candidates quickly; [transitionNotes] is then called for the pick only.
double transitionScore(Tp a, Tp b) {
  var s = 0.0;
  final x = a.bpm, y = b.bpm;
  if (x != null && y != null) {
    final d = bpmDistance(y, x);
    s += d <= 0.03 ? 2 : (d <= 0.06 ? 1 : -3);
  }
  final ka = a.key, kb = b.key;
  if (ka != null && kb != null) {
    if (_keyCompat.length > 4096) _keyCompat.clear();
    if (_keyCompat.putIfAbsent(
      '$ka|$kb',
      () => camelotCompatible(ka, kb) != null,
    )) {
      s += 1.5;
    }
  }
  return s;
}

(double, List<String>) transitionNotes(Tp a, Tp b) {
  var s = 0.0;
  final notes = <String>[];
  final x = a.bpm, y = b.bpm;
  if (x != null && y != null) {
    final d = bpmDistance(y, x);
    if (d <= 0.03) {
      s += 2;
      notes.add(
        'BPM ${x.toStringAsFixed(0)} → ${y.toStringAsFixed(0)} (${_signed((y - x) / x * 100)}%)',
      );
    } else if (d <= 0.06) {
      s += 1;
      notes.add(
        'BPM ${x.toStringAsFixed(0)} → ${y.toStringAsFixed(0)} (needs a ${(d * 100).toStringAsFixed(0)}% pitch change)',
      );
    } else {
      s -= 3;
      notes.add(
        'BPM jump ${x.toStringAsFixed(0)} → ${y.toStringAsFixed(0)}: plan a cut, echo-out or bridge track',
      );
    }
  } else {
    notes.add('BPM unknown for one of the tracks');
  }
  final ka = a.key, kb = b.key;
  if (ka != null && kb != null) {
    final why = camelotCompatible(ka, kb);
    if (why != null) {
      s += 1.5;
      notes.add('Key $ka → $kb ($why)');
    } else {
      notes.add('Key $ka → $kb is not a standard harmonic move');
    }
  } else {
    notes.add('Key unknown for one of the tracks');
  }
  return (s, notes);
}

class SetsService {
  SetsService(this.cat);
  final Catalogue cat;

  bool _eligible(Tp t, SetParams p, Set<int> excluded, Set<int>? allowed) {
    if (excluded.contains(t.id) ||
        (t.durationMs ?? 0) < (p.minTrackSeconds ?? 30) * 1000) {
      return false;
    }
    if (allowed != null &&
        !allowed.contains(t.id) &&
        !p.mustPlay.contains(t.id)) {
      return false;
    }
    if (p.cleanOnly && t.clean != 'clean') {
      return false; // explicit or unknown are left out
    }
    if (p.excludeTags.any((x) => t.tags.contains(fold(x)))) return false;
    if (p.genres.isNotEmpty && !p.mustPlay.contains(t.id)) {
      final g = t.genreFold;
      if (!p.genres.any((w) => g.isNotEmpty && g.contains(fold(w)))) {
        return false;
      }
    }
    final b = t.bpm;
    if (b != null) {
      if ((p.bpmMin != null && b < p.bpmMin! && b * 2 < p.bpmMin!) ||
          (p.bpmMax != null && b > p.bpmMax! && b / 2 > p.bpmMax!)) {
        return false;
      }
    }
    return true;
  }

  Map<String, Object?> plan(SetParams p) {
    if (p.durationMin < 5 || p.durationMin > 720) {
      _no('set length must be between 5 minutes and 12 hours');
    }
    final tps = loadProfiles(cat);
    final byId = {for (final t in tps) t.id: t};
    final excluded = p.exclude.toSet();
    final allowed = p.crateId == null
        ? null
        : LibraryService(cat)
              .trackIds(
                TrackQuery(
                  extraWhere: CratesService(cat).membership(p.crateId!),
                ),
              )
              .toSet();
    final pool = [
      for (final t in tps)
        if (_eligible(t, p, excluded, allowed)) t,
    ];
    final warnings = <String>[];
    if (pool.isEmpty) {
      _no(
        'no tracks match these settings. Try fewer genre filters, turn off clean-only, or add energy/BPM data by analysing tracks.',
      );
    }
    final unknownEnergy = pool.where((t) => t.energy == null).length;
    if (unknownEnergy * 2 > pool.length) {
      warnings.add(
        '$unknownEnergy of ${pool.length} candidate tracks have no energy value yet; analyse them or rate energy for better journeys.',
      );
    }
    final points = curvePoints(p);
    final totalMs = p.durationMin * 60000;
    final rules = p.rules;
    final harmonic = rules.key != KeyGate.off;
    final artistStart = <String, int>{}; // artist → last start (ms)
    final opening = p.openingTrackId == null ? null : byId[p.openingTrackId];
    if (p.openingTrackId != null && opening == null) {
      warnings.add('The opening track is not available.');
    }
    final used = <int>{};
    final slots = <Map<String, Object?>>[];
    var elapsed = 0;
    final must = [for (final id in p.mustPlay) ?byId[id]];
    for (final id in p.mustPlay) {
      if (!byId.containsKey(id)) {
        warnings.add(
          'Must-play track #$id is not available (missing, offline or unreadable).',
        );
      }
    }
    // Typical mixed length: ~70% of the full track, at least 2:30.
    int playedLen(Tp t) =>
        ((t.durationMs ?? 240000) * 0.7).floor().clamp(150000, 420000);

    while (elapsed < totalMs) {
      final target = p.energyAt(points, elapsed / totalMs);
      final wantBpm = rules.bpmAt(elapsed / totalMs);
      final prev = slots.isEmpty ? null : byId[slots.last['track_id']];
      final recent = [
        for (final s in slots.reversed.take(4)) ?byId[s['track_id']],
      ].map((x) => x.artistKey).toSet();
      final remaining = totalMs - elapsed;
      final mustLeft = must.fold<int>(0, (a, m) => a + playedLen(m));
      final mustIds = {for (final m in must) m.id};
      // reasons are text: built only for the tracks that are shown
      List<String> reasonsFor(Tp c) {
        final why = <String>[];
        if (mustIds.contains(c.id)) why.add('Must-play');
        if (c.energy != null) {
          why.add(
            'Energy ${c.energy} for a target of ${target.toStringAsFixed(1)}',
          );
        }
        final r = c.rating;
        if (r != null && r >= 4) why.add('Rated $r★');
        if (wantBpm != null && c.bpm != null) {
          final off =
              tempoChange(wantBpm, c.bpm!, halfDouble: rules.halfDouble) *
              wantBpm;
          if (off <= rules.bpmPathTolerance) {
            why.add('On the tempo path (${wantBpm.toStringAsFixed(0)} BPM)');
          }
        }
        return why;
      }

      double scoreOf(Tp c) {
        var s = 0.0;
        final e = (c.energy ?? 5).toDouble();
        s += 3 - (e - target).abs();
        if (c.energy == null) s -= 0.7;
        final r = c.rating;
        if (r != null) s += (r - 3) * 0.4;
        s -= (c.plays < 10 ? c.plays : 10) * 0.05;
        if (recent.contains(c.artistKey)) s -= 1.0;
        final lastStart = artistStart[c.artistKey];
        if (lastStart != null &&
            elapsed - lastStart < rules.artistGapMin * 60000) {
          s -= 2.5;
        }
        if (wantBpm != null && c.bpm != null) {
          final off =
              tempoChange(wantBpm, c.bpm!, halfDouble: rules.halfDouble) *
              wantBpm;
          s -= (off / rules.bpmPathTolerance).clamp(0.0, 3.0);
        }
        if (prev != null) {
          final ts = transitionScore(prev, c);
          s += harmonic ? ts : (ts < 2 ? ts : 2);
          if (rules.key == KeyGate.strict &&
              (keyMoveCost(prev.key, c.key, rules.key) ?? 0) >= 2) {
            s -= 2;
          }
          if (prev.genreFold == c.genreFold && c.genre != null) s += 0.5;
        }
        if (mustIds.contains(c.id)) {
          s += 1.5;
          if (mustLeft >= remaining - playedLen(c)) {
            s += 20; // every must-play must fit
          }
        }
        return s;
      }

      // The best few, highest score first and equal scores in pool order
      // (as a stable sort would give), without sorting every candidate.
      final keep = 4 + mustIds.length;
      final top = <(double, int, Tp)>[];
      var n = 0;
      void consider(Tp c) {
        if (used.contains(c.id)) return;
        final sc = scoreOf(c);
        final idx = n++;
        if (top.length == keep && sc <= top.last.$1) return;
        var at = top.length;
        while (at > 0 && top[at - 1].$1 < sc) {
          at--;
        }
        top.insert(at, (sc, idx, c));
        if (top.length > keep) top.removeLast();
      }

      if (slots.isEmpty && opening != null) {
        consider(opening);
      } else {
        for (final c in pool) {
          consider(c);
        }
        for (final c in must) {
          consider(c);
        }
      }
      if (top.isEmpty) {
        warnings.add(
          'Ran out of suitable tracks before reaching the requested length.',
        );
        break;
      }
      final pick = top.first.$3;
      final why = reasonsFor(pick);
      final trans = prev == null
          ? const <String>[]
          : transitionNotes(prev, pick).$2;
      final alternatives = [
        for (final x
            in top.skip(1).where((x) => !mustIds.contains(x.$3.id)).take(3))
          {
            'track_id': x.$3.id,
            'track': x.$3.label,
            'energy': x.$3.energy, //
            'bpm': x.$3.bpm,
            'key': x.$3.key,
            'score': (x.$1 * 10).round() / 10,
            'reasons': reasonsFor(x.$3),
          },
      ];
      used.add(pick.id);
      artistStart[pick.artistKey] = elapsed;
      must.removeWhere((m) => m.id == pick.id);
      slots.add({
        'track_id': pick.id,
        'track': pick.label,
        'start_ms': elapsed,
        'target_energy': (target * 10).round() / 10, //
        'energy': pick.energy,
        'bpm': pick.bpm,
        'key': pick.key,
        'must_play': p.mustPlay.contains(pick.id),
        'reasons': why, 'transition': trans, 'alternatives': alternatives,
      });
      elapsed += playedLen(pick);
      if (slots.length > 400) break;
    }
    // Emergency tracks: dependable floor-fillers not in the plan.
    final emergency =
        [
          for (final t in pool)
            if (!used.contains(t.id) &&
                ((t.rating ?? 0) >= 4 || t.tags.contains('banger')))
              t,
        ]..sort((a, b) {
          final r = (b.rating ?? 0).compareTo(a.rating ?? 0);
          return r != 0 ? r : (b.energy ?? 0).compareTo(a.energy ?? 0);
        });
    final checks = checkSet(
      [for (final x in slots) byId[x['track_id']]],
      rules,
      startMs: [for (final x in slots) x['start_ms']! as int],
      targets: [
        for (final x in slots) (x['target_energy'] as num?)?.toDouble(),
      ],
    );
    for (var i = 0; i < slots.length; i++) {
      slots[i]['grade'] = checks[i].grade?.name;
      slots[i]['issues'] = checks[i].issues;
    }
    final rough = slots
        .where(
          (s) => (s['transition'] as List<String>).any(
            (n) => n.startsWith('BPM jump'),
          ),
        )
        .length;
    if (rough > 0) {
      warnings.add(
        '$rough transition(s) have a large tempo jump; consider bridge tracks or a creative cut.',
      );
    }
    return {
      'params': p.toJson(),
      'curve': points,
      'slots': slots,
      'emergency': [
        for (final t in emergency.take(8))
          {
            'track_id': t.id,
            'track': t.label,
            'rating': t.rating,
            'energy': t.energy,
            'bpm': t.bpm,
          },
      ],
      'warnings': warnings,
      'grades': gradeCounts(checks),
      'planned_ms': elapsed,
      'note': 'This is a suggested running order. Tempo and key notes describe compatibility on paper only; always trust your ears.',
    };
  }

  int save(String name, Map<String, Object?> plan, {int? id}) {
    final n = name.trim();
    if (n.isEmpty || n.length > 120) _no('give the set a name');
    final slots = (plan['slots'] as List?) ?? const [];
    for (final s in slots) {
      final tid = (s as Map)['track_id'];
      if (tid is! int) _no('each slot needs a track');
      if (cat.db.select('SELECT id FROM tracks WHERE id=?', [tid]).isEmpty) {
        _no('track #$tid is not in the library');
      }
    }
    final full = jsonEncode({
      'slots': slots,
      'emergency': plan['emergency'] ?? const [],
      'curve': plan['curve'] ?? const [],
    });
    final params = jsonEncode(plan['params'] ?? const {});
    final now = nowMs();
    if (id != null) {
      cat.db.execute(
        'UPDATE set_plans SET name=?, params_json=?, slots_json=?, updated_at=? WHERE id=?',
        [n, params, full, now, id],
      );
      return id;
    }
    cat.db.execute(
      'INSERT INTO set_plans(name, params_json, slots_json, created_at, updated_at) VALUES (?,?,?,?,?)',
      [n, params, full, now, now],
    );
    return cat.db.lastInsertRowId;
  }

  List<Map<String, Object?>> list() => [
    for (final r in cat.db.select(
      'SELECT id, name, params_json, slots_json, created_at, updated_at FROM set_plans ORDER BY updated_at DESC',
    ))
      {
        'id': r['id'],
        'name': r['name'],
        'params': jsonDecode(r['params_json'] as String), //
        'count':
            ((jsonDecode(r['slots_json'] as String) as Map)['slots'] as List?)
                ?.length ??
            0,
        'created_at': r['created_at'], 'updated_at': r['updated_at'],
      },
  ];

  Map<String, Object?> get(int id) {
    final r = cat.db.select(
      'SELECT name, params_json, slots_json FROM set_plans WHERE id=?',
      [id],
    );
    if (r.isEmpty) _no('set not found');
    return {
      ...(jsonDecode(r.first['slots_json'] as String) as Map)
          .cast<String, Object?>(),
      'id': id,
      'name': r.first['name'],
      'params': jsonDecode(r.first['params_json'] as String),
    };
  }

  void delete(int id) =>
      cat.db.execute('DELETE FROM set_plans WHERE id=?', [id]);

  List<int> trackIds(int id) => [
    for (final s in (get(id)['slots'] as List?) ?? const [])
      ?((s as Map)['track_id'] as int?),
  ];

  /// Re-evaluates transitions after the DJ reorders or swaps tracks.
  List<Map<String, Object?>> review(
    List<int> ids, {
    SetRules rules = const SetRules(),
  }) {
    final byId = {for (final t in loadProfiles(cat)) t.id: t};
    final checks = checkSet([for (final id in ids) byId[id]], rules);
    final out = <Map<String, Object?>>[];
    for (var i = 0; i + 1 < ids.length; i++) {
      final a = byId[ids[i]], b = byId[ids[i + 1]];
      if (a == null || b == null) {
        out.add({
          'from': ids[i],
          'to': ids[i + 1],
          'score': 0,
          'notes': ['Track unavailable'],
        });
        continue;
      }
      final (score, notes) = transitionNotes(a, b);
      out.add({
        'from': ids[i],
        'to': ids[i + 1],
        'score': score,
        'notes': notes,
        'grade': checks[i + 1].grade?.name,
        'issues': checks[i + 1].issues,
      });
    }
    return out;
  }

  /// A manual crate holding the set's tracks, in order.
  Crate toCrate(int id, String name) {
    final c = CratesService(cat).create(CrateInput(name: name, kind: 'manual'));
    CratesService(cat).addTracks(c.id, trackIds(id));
    return CratesService(cat).get(c.id);
  }
}
