import 'package:dj_assistant/core/suggestions.dart';
import 'package:flutter_test/flutter_test.dart';

/// File-name parsing on the names DJ libraries really hold.
void main() {
  final cases = <String, (String, String, String?, double?)?>{
    'Lagos Lights - Sunrise Groove': (
      'Lagos Lights',
      'Sunrise Groove',
      null,
      null,
    ),
    '01 - Lagos Lights - Sunrise Groove': (
      'Lagos Lights',
      'Sunrise Groove',
      null,
      null,
    ),
    '07. Deep Tenant - Warehouse 94 (Extended Mix)': (
      'Deep Tenant',
      'Warehouse 94 (Extended Mix)',
      null,
      null,
    ),
    '8A - 124 - Deep Tenant - Warehouse 94': (
      'Deep Tenant',
      'Warehouse 94',
      '8A',
      124,
    ),
    '124 - 8A - Deep Tenant - Warehouse 94': (
      'Deep Tenant',
      'Warehouse 94',
      '8A',
      124,
    ),
    '11b - Ama Velvet - Golden Hour': (
      'Ama Velvet',
      'Golden Hour',
      '11B',
      null,
    ),
    '8A - Energy 7 - Kito Lagoon - Danfo Ride': (
      'Kito Lagoon',
      'Danfo Ride',
      '8A',
      null,
    ),
    'A1 - Velvet Arcade - Roller Rink': (
      'Velvet Arcade',
      'Roller Rink',
      null,
      null,
    ),
    'Kito Lagoon - Danfo Ride (Official Video)': (
      'Kito Lagoon',
      'Danfo Ride',
      null,
      null,
    ),
    'Kito Lagoon - Danfo Ride (Official Music Video) [HQ]': (
      'Kito Lagoon',
      'Danfo Ride',
      null,
      null,
    ),
    'Kito Lagoon - Danfo Ride (Lyrics) (320 kbps)': (
      'Kito Lagoon',
      'Danfo Ride',
      null,
      null,
    ),
    'Kito Lagoon - Danfo Ride (Clean)': (
      'Kito Lagoon',
      'Danfo Ride (Clean)',
      null,
      null,
    ),
    'Kito Lagoon ft. Ada - Danfo Ride (Radio Edit)': (
      'Kito Lagoon ft. Ada',
      'Danfo Ride (Radio Edit)',
      null,
      null,
    ),
    'Kito_Lagoon_-_Danfo_Ride': ('Kito Lagoon', 'Danfo Ride', null, null),
    'Kito Lagoon – Danfo Ride': ('Kito Lagoon', 'Danfo Ride', null, null),
    'Kito Lagoon - Danfo Ride www.afrohits.com': (
      'Kito Lagoon',
      'Danfo Ride',
      null,
      null,
    ),
    'Quiet Harbour - Coastline - 03 - Low Tide': (
      'Quiet Harbour',
      'Low Tide',
      null,
      null,
    ),
    'Song Title - Remix - Part 2': ('Song Title', 'Remix - Part 2', null, null),
    '50 Cent - In Da Club': ('50 Cent', 'In Da Club', null, null),
    '01 Lagos Lights - Sunrise Groove': (
      'Lagos Lights',
      'Sunrise Groove',
      null,
      null,
    ),
    '7) Lagos Lights - Sunrise Groove': (
      'Lagos Lights',
      'Sunrise Groove',
      null,
      null,
    ),
    'untagged recording': null,
    '128 - 8A': null,
    '2019 - 01': null,
  };
  for (final MapEntry(key: name, value: want) in cases.entries) {
    test(name, () {
      final got = parseFileName(name);
      if (want == null) {
        expect(got, isNull);
      } else {
        expect(got, isNotNull);
        expect((got!.artist, got.title, got.camelot, got.bpm), want);
      }
    });
  }
}
