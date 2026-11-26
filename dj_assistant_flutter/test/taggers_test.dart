
import 'package:dj_assistant/core/taggers.dart';
import 'package:flutter_test/flutter_test.dart';


/// External taggers: every tool works on its own copies, the originals are
/// never written, and what the tools find is merged into review-first
/// suggestions with agreement raising confidence.
void main() {
  group('merging what the tools found', () {

    test('the same fact written differently agrees', () {
      void same(String f, String a, String b) =>
          expect(agreeKey(f, a), agreeKey(f, b), reason: '$f: $a = $b');
      void differ(String f, String a, String b) =>
          expect(agreeKey(f, a), isNot(agreeKey(f, b)), reason: '$f: $a ≠ $b');
      same('title', 'Danfo Ride (Original Mix)', 'Danfo Ride');
      same('title', 'Danfo Ride [Extended Mix]', 'Danfo Ride (Extended Mix)');
      same('title', 'Danfo Ride (feat. Ada)', 'Danfo Ride');
      same('title', 'Danfo Ride feat. Ada (Club Mix)', 'Danfo Ride (Club Mix)');
      differ('title', 'Danfo Ride (Extended Mix)', 'Danfo Ride');
      same('artist', 'Kito Lagoon feat. Ada', 'Kito Lagoon ft. Ada');
      same('artist', 'Kito Lagoon & Ada', 'Ada, Kito Lagoon');
      same('artist', 'Kito Lagoon x Ada', 'Kito Lagoon and Ada');
      differ('artist', 'Kito Lagoon', 'Kito Lagoon & Ada');
      same('genre', 'Hip-Hop', 'Hip Hop');
      same('genre', 'R&B', 'RnB');
      same('genre', 'Afro House', 'AfroHouse');
      differ('genre', 'House', 'Afro House');
      same('record_label', 'Defected Records', 'Defected');
      same('record_label', 'Mavin Music Ltd', 'Mavin');
      same('year', '2019-05-03', '2019');
    });

    test('values compare without case, accents or extra spaces', () {
      expect(agreeKey('genre', 'Afro  House'), agreeKey('genre', 'afro house'));
      expect(agreeKey('artist', 'Beyoncé'), agreeKey('artist', 'beyonce'));
      expect(agreeKey('key', 'A minor'), agreeKey('key', '8A'));
      expect(agreeKey('bpm', '127.9'), agreeKey('bpm', '128'));
    });
  });
}
