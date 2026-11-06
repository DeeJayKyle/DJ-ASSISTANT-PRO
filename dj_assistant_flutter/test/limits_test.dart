import 'package:dj_assistant/core/catalogue.dart';
import 'package:dj_assistant/core/limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Catalogue c;
  setUp(() => c = Catalogue.inMemory());
  tearDown(() => c.close());

  test('nothing is limited until the DJ sets a limit', () {
    for (final d in limitDefs) {
      expect(limitOf(c, d.key), isNull, reason: d.key);
    }
    expect(sqlLimit(null), '');
    expect(upTo([1, 2, 3], null), [1, 2, 3]);
  });

  test('a limit can be set, changed and removed', () {
    setLimit(c, 'autoprep_musicbrainz', 5000);
    expect(limitOf(c, 'autoprep_musicbrainz'), 5000);
    expect(sqlLimit(5000), ' LIMIT 5000');
    expect(upTo([1, 2, 3], 2), [1, 2]);
    setLimit(c, 'autoprep_musicbrainz', null);
    expect(limitOf(c, 'autoprep_musicbrainz'), isNull);
  });

  test('values below the minimum and unknown limits are refused', () {
    expect(() => setLimit(c, 'assistant_tokens', 10), throwsArgumentError);
    expect(() => setLimit(c, 'no_such_limit', 3), throwsArgumentError);
  });
}
