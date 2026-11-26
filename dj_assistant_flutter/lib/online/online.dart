/// Optional online services (1.x `dj_core::online`).
///
/// Nothing in DJ Assistant talks to the internet except an [Online]
/// implementation, and the services only call it after the DJ switched the
/// matching service on in Settings. Tests use fakes.
library;

class OnlineException implements Exception {
  OnlineException(this.message);
  final String message;
  @override
  String toString() => message;
}

class MbRecording {
  MbRecording({
    required this.mbid,
    required this.title,
    required this.artist,
    required this.score,
    this.firstReleaseDate,
    this.releaseTitle,
    this.label,
    this.tags = const [],
    this.isrcs = const [],
    this.lengthMs,
    this.disambiguation,
  });
  final String mbid, title, artist;
  final double score;
  final String? firstReleaseDate, releaseTitle, label, disambiguation;
  final List<String> tags, isrcs;
  final int? lengthMs;
}

/// A track found in a public music catalogue (Deezer, Apple Music, Spotify,
/// GetSongBPM, YouTube Music).
class CatalogMatch {
  CatalogMatch({
    required this.source,
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
    this.bpm,
    this.releaseDate,
    this.genres = const [],
    this.label,
    this.isrc,
    this.key,
  });
  final String source, title, artist;
  String? album, releaseDate, label, isrc;

  /// Musical key in any notation ("Am", "8A", "1m").
  String? key;
  int? durationMs;
  double? bpm;
  List<String> genres;
}

/// Everything DJ Assistant can ask the internet. Each method throws
/// [OnlineException] with a plain-language message on failure.
abstract class Online {
  Never _na(String what) =>
      throw OnlineException('$what are not available in this build');

  Future<List<MbRecording>> musicbrainzRecordings(
    String artist,
    String title,
  ) async => _na('online services');

  /// Free Deezer and Apple Music catalogues (no key).
  Future<List<CatalogMatch>> catalogLookup(String artist, String title) async =>
      _na('music catalogue lookups');

  /// True when Deezer and Apple Music can be asked separately
  /// ([deezerLookup], [appleLookup]), so Apple Music's slow speed limit is
  /// only paid when its vote is needed.
  bool get separateCatalogs => false;

  /// Deezer alone (fast: about ten requests a second).
  Future<List<CatalogMatch>> deezerLookup(String artist, String title) async =>
      _na('music catalogue lookups');

  /// Apple Music alone (slow: about 20 requests a minute).
  Future<List<CatalogMatch>> appleLookup(String artist, String title) async =>
      _na('music catalogue lookups');

  /// Spotify Web API; [creds] is "client_id:client_secret".
  Future<List<CatalogMatch>> spotifyLookup(
    String creds,
    String artist,
    String title,
  ) async => _na('Spotify lookups');
  Future<List<CatalogMatch>> youtubeLookup(
    String apiKey,
    String artist,
    String title,
  ) async => _na('YouTube lookups');

  /// Discogs database search; [token] is a personal access token.
  Future<List<CatalogMatch>> discogsLookup(
    String token,
    String artist,
    String title,
  ) async => _na('Discogs lookups');

  /// Downloads [url] into [dest], resuming what is there. [progress] gets the
  /// bytes in the file and returns false to stop.
  Future<void> download(
    String url,
    String dest,
    bool Function(int bytes) progress,
  ) async => _na('downloads');
}

/// Used when no online implementation is installed.
class NoOnline extends Online {}

/// Credential storage. Secrets never go back to the UI; it can only ask whether
/// one is set.
abstract class Secrets {
  String? get(String service);
  void set(String service, String value);
  void delete(String service);
}

class MemorySecrets implements Secrets {
  final _m = <String, String>{};
  @override
  String? get(String service) => _m[service];
  @override
  void set(String service, String value) => _m[service] = value;
  @override
  void delete(String service) => _m.remove(service);
}

class ServiceInfo {
  const ServiceInfo(this.id, this.name, this.gives, this.sends);
  final String id, name, gives, sends;
}

/// Every online service, what it gives and exactly what it sends (shown in
/// Settings next to its switch). All are off until the DJ turns them on.
const onlineServices = <ServiceInfo>[
  ServiceInfo(
    'musicbrainz',
    'MusicBrainz',
    'Original release year, album and label, plus community genre tags.',
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history.',
  ),
  ServiceInfo(
    'catalogs',
    'Deezer & Apple Music',
    'Genre, release year, album and label from two free music catalogues (no key needed). Each counts as its own vote.',
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history.',
  ),
  ServiceInfo(
    'spotify',
    'Spotify',
    'Release date, album and artist genres.',
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free Spotify developer app (developer.spotify.com/dashboard): its Client ID and Client secret.',
  ),
  ServiceInfo(
    'youtube',
    'YouTube Music',
    'Release date, label and album from the official YouTube Music release of each track. The free quota covers about 100 tracks a day.',
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free YouTube Data API key (console.cloud.google.com → APIs → YouTube Data API v3 → Credentials).',
  ),
  ServiceInfo(
    'discogs',
    'Discogs',
    'Style (Deep House, Afro House…), original release year, album and label from the Discogs database.',
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free Discogs personal access token (discogs.com → Settings → Developers).',
  ),
  ServiceInfo(
    'updates',
    'App updates',
    'Checks GitHub for a newer DJ Assistant and installs it when you agree.',
    'Your app version and Windows platform, sent to GitHub when checking.',
  ),
];
