import 'package:dj_assistant/audio/media_foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Ogg and Opus point to the free Windows codec', () {
    const unsupported = 0xC00D36C4 - 0x100000000; // HRESULT as a signed int
    expect(
      unsupportedMessage(r'C:\Music\Mirrorball.ogg', unsupported),
      contains('Web Media Extensions'),
    );
    expect(
      unsupportedMessage(r'C:\Music\Roller Rink.opus', unsupported),
      contains('.opus'),
    );
    expect(
      unsupportedMessage(r'C:\Music\song.mp3', unsupported),
      'cannot open this file (0xc00d36c4)',
    );
  });
}
