import 'package:dj_assistant/core/track_match.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const lib = [
    MatchTrack(
      id: 1,
      path: r'C:\Music\House\Deep Tenant - Warehouse 94.mp3',
      artist: 'Deep Tenant',
      title: 'Warehouse 94',
      durationSec: 312,
    ),
    MatchTrack(
      id: 2,
      path: r'D:\Edits\Warehouse 94.mp3',
      artist: 'Deep Tenant',
      title: 'Warehouse 94',
      durationSec: 200,
    ),
    MatchTrack(
      id: 3,
      path: '/music/Beyoncé - Halo.flac',
      artist: 'Beyoncé',
      title: 'Halo',
      durationSec: 261,
    ),
    MatchTrack(
      id: 4,
      path: '/music/x.mp3',
      artist: 'Ada & The Lagos Lights',
      title: 'Sunrise',
      durationSec: 240,
    ),
  ];

  test('path, file name, then artist and title', () {
    final m = TrackMatcher(lib);
    final a = m.match(
      const MatchEntry(path: 'c:/music/house/deep tenant - warehouse 94.mp3'),
    )!;
    expect((a.trackId, a.kind), (1, MatchKind.path));
    final b = m.match(const MatchEntry(path: '/Volumes/USB/Warehouse 94.mp3'))!;
    expect((b.trackId, b.kind), (2, MatchKind.fileName));
    final c = m.match(const MatchEntry(artist: 'BEYONCE', title: 'halo'))!;
    expect((c.trackId, c.kind, c.sure), (3, MatchKind.artistTitle, true));
  });

  test('the closest length wins among equal keys', () {
    final m = TrackMatcher(lib);
    expect(
      m
          .match(
            const MatchEntry(
              artist: 'Deep Tenant',
              title: 'Warehouse 94',
              durationSec: 205,
            ),
          )!
          .trackId,
      2,
    );
  });

  test('likely matches on title with agreeing artists', () {
    final m = TrackMatcher(lib);
    final a = m.match(
      const MatchEntry(artist: 'Lagos Lights', title: 'Sunrise'),
    )!;
    expect((a.trackId, a.kind), (4, MatchKind.likely));
    expect(a.reason, contains('artists match'));
    final b = m.match(const MatchEntry(artist: 'Ada Obi', title: 'Sunrise'))!;
    expect(b.reason, contains('partly'));
    expect(
      m.match(const MatchEntry(artist: 'Someone Else', title: 'Sunrise')),
      isNull,
    );
    expect(
      m
          .match(
            const MatchEntry(
              artist: 'Someone Else',
              title: 'Sunrise',
              durationSec: 243,
            ),
          )!
          .reason,
      'Same title and length',
    );
    expect(m.match(const MatchEntry(title: 'Sunrise'))!.reason, 'Same title');
  });

  test('claimOnce lets each library track answer only once', () {
    final m = TrackMatcher(lib, const MatchOptions(claimOnce: true));
    const e = MatchEntry(artist: 'Beyonce', title: 'Halo');
    expect(m.match(e)?.trackId, 3);
    expect(m.match(e), isNull);
    final h = TrackMatcher(lib);
    expect(h.match(e)?.trackId, 3);
    expect(h.match(e)?.trackId, 3, reason: 'a history can repeat a track');
  });

  test('helpers', () {
    expect(parseLength('4:05'), 245);
    expect(parseLength('1:02:03'), 3723);
    expect(parseLength('x'), isNull);
    expect(compareArtists('A & B', 'b a'), ArtistOverlap.same);
    expect(compareArtists('A', 'A feat. C'), ArtistOverlap.subset);
    expect(compareArtists('A B', 'B C'), ArtistOverlap.overlap);
    expect(matchKey('Señor (Remix)!'), 'senorremix');
  });
}
