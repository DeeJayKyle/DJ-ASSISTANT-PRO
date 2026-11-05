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

class AcoustidMatch {
  AcoustidMatch({
    required this.score,
    required this.recordingMbid,
    this.title,
    this.artist,
    this.firstYear,
  });
  final double score;
  final String recordingMbid;
  final String? title, artist;
  final int? firstYear;
}

class SimilarItem {
  SimilarItem({required this.artist, this.title, this.score = 0, this.url});
  final String artist;
  final String? title, url;
  final double score;
  Map<String, Object?> toJson() => {
    'artist': artist,
    'title': title,
    'score': score,
    'url': url,
  };
}

class ReleaseItem {
  ReleaseItem({
    required this.artist,
    required this.title,
    this.date,
    required this.kind,
    this.url,
  });
  final String artist, title, kind;
  final String? date, url;
  Map<String, Object?> toJson() => {
    'artist': artist,
    'title': title,
    'date': date,
    'kind': kind,
    'url': url,
  };
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

/// Ollama: is it installed, is its server answering, which models does it have?
class LocalProbe {
  LocalProbe({
    this.installed = false,
    this.running = false,
    this.details = const [],
  });
  final bool installed, running;
  final List<LocalModel> details;
  List<String> get models => [for (final m in details) m.name];
  Map<String, Object?> toJson() => {
    'installed': installed,
    'running': running,
    'models': models,
    'details': [for (final d in details) d.toJson()],
  };
}

class LocalModel {
  LocalModel({
    required this.name,
    this.size = 0,
    this.family = '',
    this.parameters = '',
    this.canChat = true,
  });
  final String name, family, parameters;
  final int size;
  final bool canChat;
  Map<String, Object?> toJson() => {
    'name': name,
    'size': size,
    'family': family,
    'parameters': parameters,
    'can_chat': canChat,
  };
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
  Future<List<ReleaseItem>> musicbrainzArtistReleases(String artist) async =>
      _na('online services');
  Future<List<AcoustidMatch>> acoustidLookup(
    String apiKey,
    int durationS,
    String fingerprint,
  ) async => _na('online services');
  Future<List<SimilarItem>> lastfmSimilarArtists(
    String apiKey,
    String artist,
  ) async => _na('online services');
  Future<List<SimilarItem>> lastfmSimilarTracks(
    String apiKey,
    String artist,
    String title,
  ) async => _na('online services');

  /// Free Deezer and Apple Music catalogues (no key).
  Future<List<CatalogMatch>> catalogLookup(String artist, String title) async =>
      _na('music catalogue lookups');

  /// Spotify Web API; [creds] is "client_id:client_secret".
  Future<List<CatalogMatch>> spotifyLookup(
    String creds,
    String artist,
    String title,
  ) async => _na('Spotify lookups');
  Future<List<CatalogMatch>> getsongbpmLookup(
    String apiKey,
    String artist,
    String title,
  ) async => _na('GetSongBPM lookups');
  Future<List<CatalogMatch>> youtubeLookup(
    String apiKey,
    String artist,
    String title,
  ) async => _na('YouTube lookups');

  /// Downloads [url] into [dest], resuming what is there. [progress] gets the
  /// bytes in the file and returns false to stop.
  Future<void> download(
    String url,
    String dest,
    bool Function(int bytes) progress,
  ) async => _na('downloads');

  /// One model turn for the assistant, in the Anthropic Messages format
  /// (`{"content": [...], "stop_reason", "model"}`).
  Future<Map<String, Object?>> llmChat(
    LlmConfig cfg,
    String system,
    List<Map<String, Object?>> tools,
    List<Map<String, Object?>> messages,
  ) async => _na('AI models');
  Future<List<String>> llmListModels(LlmConfig cfg) async => _na('AI models');
  Future<List<String>> llmLocalModels(String url) async => _na('AI models');
  Future<LocalProbe> llmLocalProbe(String url) async => LocalProbe();
  Future<void> llmLocalInstall(bool Function(int done, int total) progress) =>
      throw OnlineException(
        'installing Ollama automatically is not available in this build; '
        'get it free from ollama.com',
      );
  Future<void> llmLocalStart() async => _na('starting a local model server');
  Future<void> llmLocalPull(
    String url,
    String model,
    bool Function(int done, int total, String status) progress,
  ) async => _na('local model downloads');
}

/// Used when no online implementation is installed.
class NoOnline extends Online {}

/// Settings for one AI model service (1.x `agent::LlmConfig`).
class LlmConfig {
  LlmConfig({
    required this.provider,
    required this.model,
    this.apiKey,
    this.localUrl = 'http://127.0.0.1:11434',
    this.baseUrl = '',
    this.label = '',
  });

  /// "claude", "local", or an OpenAI-compatible preset id.
  final String provider, model, localUrl, baseUrl, label;
  final String? apiKey;
}

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
    'Recording, artist, release and original-year information; new releases from artists you follow.',
    'The artist and title text of tracks you choose to look up (or artist names you follow). Never audio, file paths or listening history.',
  ),
  ServiceInfo(
    'catalogs',
    'Deezer & Apple Music catalogues',
    'Exact BPM, release year, genre and label for your tracks from two free music catalogues (no key needed). Auto-prep checks new music against them and fixes values the catalogues agree on.',
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history.',
  ),
  ServiceInfo(
    'spotify',
    'Spotify',
    'Release date, artist credits, album and genres for your tracks (and BPM and key where Spotify still allows it). Checked together with the other catalogues.',
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free Spotify developer app (developer.spotify.com/dashboard): its Client ID and Client secret.',
  ),
  ServiceInfo(
    'getsongbpm',
    'GetSongBPM',
    "Tempo and musical key for your tracks, checked against this computer's audio analysis. Data from GetSongBPM.com.",
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free GetSongBPM API key (getsongbpm.com/api).',
  ),
  ServiceInfo(
    'youtube',
    'YouTube & YouTube Music',
    'Exact release date, label and album from the official YouTube Music release of each track (its "Artist - Topic" video). The free quota covers about 100 tracks a day.',
    'The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free YouTube Data API key (console.cloud.google.com → APIs → YouTube Data API v3 → Credentials).',
  ),
  ServiceInfo(
    'acoustid',
    'AcoustID',
    'Possible identification of tracks from an audio fingerprint.',
    'A compact audio fingerprint and the track duration, only after you confirm each lookup. Never the audio itself. Needs your free AcoustID application key.',
  ),
  ServiceInfo(
    'lastfm',
    'Last.fm',
    'Similar artists and tracks for discovery.',
    'Artist and track names from the crate or tracks you choose. Needs your Last.fm API key.',
  ),
  ServiceInfo(
    'anthropic',
    'AI assistant (online)',
    'Answers questions about your library and the app, and proposes actions you approve. Choose Claude, ChatGPT, Gemini, Grok, Mistral, DeepSeek and more.',
    'Your messages to the assistant and the catalogue details its tools look up (titles, artists, genres, ratings and similar), to the AI service you choose. Never audio, file paths or personal documents. Needs that service\'s API key.',
  ),
  ServiceInfo(
    'updates',
    'App updates',
    'Checks GitHub for a newer DJ Assistant and installs it when you agree.',
    'Your app version and Windows platform, sent to GitHub when checking.',
  ),
];
