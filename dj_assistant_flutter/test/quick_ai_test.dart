import 'package:dj_assistant/assistant/quick_ai.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ports of 1.x `quick.rs` tests.
void main() {
  test('parses answers defensively', () {
    final r = parseTidy(
      '```json\n{"tracks":[{"id":"1","artist":"DJ Kozi","title":"Sunset Drive","mix":"Original Mix","genre":"deep house"},{"id":"99","title":"x"},{"id":2,"title":""},{"id":1,"title":"dup"}]}\n```',
      {1, 2},
      ['Deep House', 'Techno'],
    );
    expect(r, [
      TidyResult(1, 'DJ Kozi', 'Sunset Drive', 'Original Mix', 'Deep House'),
    ]);
    expect(parseTidy("sorry, I can't", {1, 2}, ['Techno']), isEmpty);
    final (order, note) = parseOrder(
      'Here you go: {"order":["3","1","1","42"],"note":"Deep first."}',
      [1, 2, 3],
    )!;
    expect(order, [3, 1, 2]);
    expect(note, 'Deep first.');
    expect(parseOrder('{"nope":1}', [1]), isNull);
  });

  test('reads reply text and writes sorted JSON like 1.x', () {
    expect(
      replyText({
        'content': [
          {'type': 'text', 'text': '{"order":[]}'},
        ],
      }),
      '{"order":[]}',
    );
    expect(replyText(<String, Object?>{}), '');
    expect(
      canonicalJson({
        'b': 1,
        'a': {'d': 2, 'c': 3},
      }),
      '{"a":{"c":3,"d":2},"b":1}',
    );
  });
}
