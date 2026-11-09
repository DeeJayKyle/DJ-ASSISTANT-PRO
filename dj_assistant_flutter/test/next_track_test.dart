import 'package:dj_assistant/core/next_track.dart';
import 'package:flutter_test/flutter_test.dart';

NextTrackCandidate c(
  int id, {
  double? bpm,
  String? key,
  double? energy,
  Map<String, double> extras = const {},
}) => NextTrackCandidate(
  id: id,
  bpm: bpm,
  camelot: key,
  energy: energy,
  extras: extras,
);

void main() {
  group('BPM gate', () {
    const g = MixRules(bpmWindow: 3);
    test('inside the window passes, outside fails', () {
      expect(checkTempo(126, 124, g).pass, isTrue);
      expect(checkTempo(128, 124, g).pass, isFalse);
    });
    test('half and double time pass unless turned off', () {
      expect(checkTempo(62, 124, g).pass, isTrue);
      expect(checkTempo(250, 124, g).pass, isTrue);
      expect(checkTempo(62, 124, g.copyWith(halfDouble: false)).pass, isFalse);
    });
    test('window 0 means the same rounded BPM', () {
      const z = MixRules(bpmWindow: 0);
      expect(checkTempo(124.4, 123.6, z).pass, isTrue);
      expect(checkTempo(125, 124, z).pass, isFalse);
    });
    test(
      'unknown BPM passes but is flagged; no anchor or any tempo passes',
      () {
        final r = checkTempo(null, 124, g);
        expect(r.pass && r.flagged, isTrue);
        expect(checkTempo(90, null, g).pass, isTrue);
        expect(
          checkTempo(90, 124, const MixRules(bpmWindow: null)).pass,
          isTrue,
        );
      },
    );
  });

  group('key gate', () {
    test('same, adjacent and relative keys mix', () {
      for (final k in ['8A', '7A', '9A', '8B', 'Am', 'C']) {
        expect(checkKey(k, '8A', KeyGate.strict).pass, isTrue, reason: k);
      }
      expect(checkKey('10A', '8A', KeyGate.strict).pass, isFalse);
      expect(checkKey('9B', '8A', KeyGate.strict).pass, isFalse);
    });
    test('wheel wraps round from 12 to 1', () {
      expect(checkKey('1A', '12A', KeyGate.strict).pass, isTrue);
    });
    test('loose lets a one-semitone lift through, marked', () {
      // 8A (Am) → 3A (Bbm) is seven steps round the wheel
      expect(checkKey('3A', '8A', KeyGate.strict).pass, isFalse);
      final r = checkKey('3A', '8A', KeyGate.loose);
      expect(r.pass && r.keyChange, isTrue);
    });
    test('off and unknown keys', () {
      expect(checkKey('3B', '8A', KeyGate.off).pass, isTrue);
      final r = checkKey(null, '8A', KeyGate.strict);
      expect(r.pass && r.flagged, isTrue);
      expect(checkKey('3B', null, KeyGate.strict).pass, isTrue);
    });
  });

  group('target energy', () {
    test('mean of the last ten, stepped and clamped', () {
      expect(targetEnergy([5, 7], EnergyDirection.hold), 6);
      expect(targetEnergy([5, 7], EnergyDirection.lift), 7);
      expect(targetEnergy([5, 7], EnergyDirection.cool), 5);
      expect(targetEnergy([10, 10], EnergyDirection.lift), 10);
      expect(targetEnergy([1], EnergyDirection.cool), 1);
      // only the last ten count
      expect(
        targetEnergy([1, 1, 1, ...List.filled(10, 8.0)], EnergyDirection.hold),
        8,
      );
      expect(targetEnergy([null, null], EnergyDirection.hold), isNull);
    });
  });

  test('z-scores are population z-scores, zero when flat', () {
    final z = zScores({1: 1, 2: 3});
    expect(z[1], closeTo(-1, 1e-9));
    expect(z[2], closeTo(1, 1e-9));
    expect(zScores({1: 4, 2: 4}).values, everyElement(0));
  });

  group('ranking', () {
    final lib = [
      c(1, bpm: 124, key: '8A', energy: 6), // anchor
      c(2, bpm: 125, key: '8A', energy: 6),
      c(3, bpm: 126, key: '9A', energy: 7),
      c(4, bpm: 123, key: '7A', energy: 5),
      c(5, bpm: 140, key: '8A', energy: 7), // too fast
      c(6, bpm: 124, key: '2B', energy: 6), // clashing key
      c(7, bpm: 124), // no key, no energy: unscored, flagged
    ];

    test('lift puts the higher-energy track first, cool the lower', () {
      List<int> order(EnergyDirection d) => [
        for (final s in rankNextTracks(
          library: lib,
          anchor: lib[0],
          playedEnergies: const [6],
          exclude: const {1},
          direction: d,
        ).suggestions)
          s.candidate.id,
      ];
      expect(order(EnergyDirection.lift).first, 3);
      expect(order(EnergyDirection.cool).first, 4);
      expect(order(EnergyDirection.hold).first, 2);
      // gated out, and the unscored track comes last
      expect(order(EnergyDirection.hold), isNot(contains(5)));
      expect(order(EnergyDirection.hold), isNot(contains(6)));
      expect(order(EnergyDirection.hold).last, 7);
    });

    test('reasons and flags', () {
      final r = rankNextTracks(
        library: lib,
        anchor: lib[0],
        playedEnergies: const [6],
        exclude: const {1},
      );
      final two = r.suggestions.firstWhere((s) => s.candidate.id == 2);
      expect(two.reasons, contains('Same key'));
      expect(two.reasons, contains('+1 BPM'));
      final seven = r.suggestions.firstWhere((s) => s.candidate.id == 7);
      expect(seven.flagged, isTrue);
      expect(seven.scored, isFalse);
      expect(r.mixable, 4);
      expect(r.total, 6);
    });

    test('when nothing mixes, loosening options say how many they open', () {
      final r = rankNextTracks(
        library: [
          c(1, bpm: 124, key: '8A'),
          c(2, bpm: 135, key: '3B'),
        ],
        anchor: c(1, bpm: 124, key: '8A'),
        playedEnergies: const [],
        gate: const MixRules(bpmWindow: 3, key: KeyGate.strict),
      );
      expect(r.suggestions, isEmpty);
      // tempo alone does not help (the key still clashes)
      expect(r.loosen.map((o) => o.label), isEmpty);
      final r2 = rankNextTracks(
        library: [c(2, bpm: 135, key: '8A')],
        anchor: c(1, bpm: 124, key: '8A'),
        playedEnergies: const [],
        gate: const MixRules(bpmWindow: 3, key: KeyGate.strict),
      );
      expect(r2.loosen.single.label, 'Any tempo');
      expect(r2.loosen.single.opensUp, 1);
      final r3 = rankNextTracks(
        library: [c(2, bpm: 124, key: '3B')],
        anchor: c(1, bpm: 124, key: '8A'),
        playedEnergies: const [],
        gate: const MixRules(key: KeyGate.strict),
      );
      expect(r3.loosen.map((o) => o.label), ['Any key']);
      expect(r3.loosen.single.clashes, isTrue);
    });

    test('an extra measure ranks by closeness after allowing for energy', () {
      // loudness rises with energy; track 3 sits on the same line as the
      // anchor, track 2 is far off it
      final pool = [
        c(2, bpm: 124, key: '8A', energy: 6, extras: {'loudness': -4}),
        c(3, bpm: 124, key: '8A', energy: 6, extras: {'loudness': -8}),
        c(4, bpm: 124, key: '8A', energy: 2, extras: {'loudness': -12}),
        c(5, bpm: 124, key: '8A', energy: 9, extras: {'loudness': -5}),
      ];
      final r = rankNextTracks(
        library: pool,
        anchor: c(1, bpm: 124, key: '8A', energy: 6, extras: {'loudness': -8}),
        playedEnergies: const [6],
      );
      final ids = [for (final s in r.suggestions) s.candidate.id];
      expect(ids.indexOf(3), lessThan(ids.indexOf(2)));
    });
  });
}
