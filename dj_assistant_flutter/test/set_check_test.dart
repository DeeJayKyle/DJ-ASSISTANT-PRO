import 'package:dj_assistant/core/json.dart';
import 'package:dj_assistant/core/next_track.dart' show KeyGate;
import 'package:dj_assistant/core/profile.dart';
import 'package:dj_assistant/core/set_check.dart';
import 'package:flutter_test/flutter_test.dart';

Tp tp(
  int id, {
  String artist = 'A',
  double? bpm = 124,
  String? key = '8A',
  int? energy = 5,
}) => Tp({
  'id': id,
  'artist': artist,
  'title': 'T$id',
  'bpm': bpm,
  'key': key,
  'energy': energy,
  'plays': 0,
});

void main() {
  const r = SetRules();

  test('grades by key move and tempo change', () {
    expect(gradeMix(tp(1), tp(2, bpm: 125), r), MixGrade.smooth); // 0.8 %
    expect(gradeMix(tp(1), tp(2, bpm: 128, key: '9A'), r), MixGrade.good);
    expect(gradeMix(tp(1), tp(2, bpm: 131, key: '10A'), r), MixGrade.workable);
    expect(gradeMix(tp(1), tp(2, key: '3A'), r), MixGrade.workable); // semitone
    expect(
      gradeMix(tp(1), tp(2, key: '3A'), const SetRules(key: KeyGate.strict)),
      MixGrade.clash,
    );
    expect(gradeMix(tp(1), tp(2, key: '2B'), r), MixGrade.clash);
    expect(gradeMix(tp(1), tp(2, bpm: 140), r), MixGrade.clash);
    expect(gradeMix(tp(1), tp(2, bpm: 62), r), MixGrade.smooth);
    expect(
      gradeMix(tp(1), tp(2, bpm: 62), const SetRules(halfDouble: false)),
      MixGrade.clash,
    );
    expect(
      gradeMix(tp(1), tp(2, key: '2B'), const SetRules(key: KeyGate.off)),
      MixGrade.smooth,
    );
    expect(gradeMix(tp(1), tp(2, bpm: null), r), MixGrade.unknown);
  });

  test('issues on each slot', () {
    final order = [
      tp(1, artist: 'Ada', energy: 4),
      tp(2, artist: 'Bo', bpm: 140, key: '2B', energy: 9),
      tp(3, artist: 'Ada', bpm: 126, energy: 5),
      tp(4, artist: 'Cy', bpm: null, energy: 5),
      null,
    ];
    final c = checkSet(
      order,
      const SetRules(startBpm: 120, endBpm: 128),
      startMs: [0, 240000, 480000, 720000, 960000],
      targets: [4, 5, 6, 7, 8],
    );
    expect(c[0].grade, isNull);
    expect(c[1].grade, MixGrade.clash);
    expect(c[1].issues, contains(startsWith('Tempo jump 124 → 140')));
    expect(c[1].issues, contains(startsWith('Key clash')));
    expect(c[1].issues, contains(startsWith('Off the tempo path')));
    expect(c[1].issues, contains('Energy 9 where 5.0 is planned'));
    expect(c[2].issues, contains('Same artist 8 min ago'));
    expect(c[3].grade, MixGrade.unknown);
    expect(c[3].issues, contains(startsWith('BPM or key unknown')));
    expect(c[4].issues, ['Track no longer in the library']);
    expect(gradeCounts(c), {'clash': 2, 'unknown': 1});
  });

  test('new set options round-trip through JSON', () {
    final p = setParamsFromJson({
      'duration_min': 90,
      'key_mode': 'strict',
      'half_double': false,
      'start_bpm': 118,
      'end_bpm': 126,
      'opening_track_id': 7,
      'artist_gap_min': 30,
      'energy_floor': 3,
      'energy_ceiling': 8,
    });
    expect(p.keyRule, KeyGate.strict);
    expect(p.rules.halfDouble, isFalse);
    expect(p.rules.bpmAt(0.5), 122);
    expect(p.openingTrackId, 7);
    expect(p.energyAt([1, 10], 0), 3);
    expect(p.energyAt([1, 10], 1), 8);
    expect(p.toJson()['key_mode'], 'strict');
    expect(setParamsFromJson({'harmonic': false}).keyRule, KeyGate.off);
  });
}
