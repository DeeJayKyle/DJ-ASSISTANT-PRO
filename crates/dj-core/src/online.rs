//! Interfaces for optional online services and credential storage.
//!
//! dj-core contains no networking code. The desktop app injects an
//! implementation (crate `dj-online`); tests inject fakes. Each service must be
//! switched on by the DJ in Settings before it is ever called.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct MbRecording {
    pub mbid: String,
    pub title: String,
    pub artist: String,
    pub score: f64,
    pub first_release_date: Option<String>,
    pub release_title: Option<String>,
    pub label: Option<String>,
    pub tags: Vec<String>,
    pub isrcs: Vec<String>,
    pub length_ms: Option<i64>,
    pub disambiguation: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct AcoustidMatch {
    pub score: f64,
    pub recording_mbid: String,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub first_year: Option<i64>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct SimilarItem {
    pub artist: String,
    pub title: Option<String>,
    pub score: f64,
    pub url: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct ReleaseItem {
    pub artist: String,
    pub title: String,
    pub date: Option<String>,
    pub kind: String,
    pub url: Option<String>,
}

/// A track found in a public music catalogue (Deezer, Apple Music).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct CatalogMatch {
    /// "Deezer" or "Apple Music"
    pub source: String,
    pub title: String,
    pub artist: String,
    pub album: Option<String>,
    pub duration_ms: Option<i64>,
    /// Beats per minute as the catalogue lists it (Deezer only).
    pub bpm: Option<f64>,
    /// "YYYY-MM-DD" (or just the year)
    pub release_date: Option<String>,
    pub genres: Vec<String>,
    pub label: Option<String>,
    pub isrc: Option<String>,
    /// Musical key in any notation ("Am", "8A", "1m"); GetSongBPM and some Spotify apps.
    #[serde(default)]
    pub key: Option<String>,
}

pub trait Online: Send + Sync {
    fn musicbrainz_recordings(&self, artist: &str, title: &str)
        -> Result<Vec<MbRecording>, String>;
    fn musicbrainz_artist_releases(&self, artist: &str) -> Result<Vec<ReleaseItem>, String>;
    fn acoustid_lookup(
        &self,
        api_key: &str,
        duration_s: u32,
        fingerprint: &str,
    ) -> Result<Vec<AcoustidMatch>, String>;
    fn lastfm_similar_artists(
        &self,
        api_key: &str,
        artist: &str,
    ) -> Result<Vec<SimilarItem>, String>;
    fn lastfm_similar_tracks(
        &self,
        api_key: &str,
        artist: &str,
        title: &str,
    ) -> Result<Vec<SimilarItem>, String>;
    /// Download `url` into `dest`, appending to what is already there (resume).
    /// `progress(bytes_in_file)` returns false to stop early.
    fn download(
        &self,
        _url: &str,
        _dest: &std::path::Path,
        _progress: &mut dyn FnMut(u64) -> bool,
    ) -> Result<(), String> {
        Err("downloads are not available in this build".into())
    }
    /// Search the free Deezer and Apple Music catalogues (no key) for a track.
    fn catalog_lookup(&self, _artist: &str, _title: &str) -> Result<Vec<CatalogMatch>, String> {
        Err("music catalogue lookups are not available in this build".into())
    }
    /// Spotify Web API (client-credentials app: "client_id:client_secret").
    fn spotify_lookup(
        &self,
        _creds: &str,
        _artist: &str,
        _title: &str,
    ) -> Result<Vec<CatalogMatch>, String> {
        Err("Spotify lookups are not available in this build".into())
    }
    /// GetSongBPM API (free key): tempo and musical key.
    fn getsongbpm_lookup(
        &self,
        _api_key: &str,
        _artist: &str,
        _title: &str,
    ) -> Result<Vec<CatalogMatch>, String> {
        Err("GetSongBPM lookups are not available in this build".into())
    }
    /// YouTube Data API (free key): official "Artist - Topic" releases, i.e. YouTube Music.
    fn youtube_lookup(
        &self,
        _api_key: &str,
        _artist: &str,
        _title: &str,
    ) -> Result<Vec<CatalogMatch>, String> {
        Err("YouTube lookups are not available in this build".into())
    }
    /// One model turn for the AI assistant. `messages` and the returned value
    /// use the Anthropic Messages format ({"content": [...], "stop_reason", "model"}).
    fn llm_chat(
        &self,
        _cfg: &crate::agent::LlmConfig,
        _system: &str,
        _tools: &[serde_json::Value],
        _messages: &[serde_json::Value],
    ) -> Result<serde_json::Value, String> {
        Err("AI models are not available in this build".into())
    }
    /// Models an OpenAI-compatible service offers (GET /models with the key).
    fn llm_list_models(&self, _cfg: &crate::agent::LlmConfig) -> Result<Vec<String>, String> {
        Err("AI models are not available in this build".into())
    }
    /// Models installed in the local model server (Ollama).
    fn llm_local_models(&self, _url: &str) -> Result<Vec<String>, String> {
        Err("AI models are not available in this build".into())
    }
    /// Is Ollama installed on this computer, is its server answering, which models does it have?
    fn llm_local_probe(&self, _url: &str) -> LocalProbe {
        LocalProbe::default()
    }
    /// Download Ollama's installer and install it silently (Windows). `progress(done, total)`
    /// reports the download and returns false to stop.
    fn llm_local_install(&self, _progress: &mut dyn FnMut(u64, u64) -> bool) -> Result<(), String> {
        Err("installing Ollama automatically is not available in this build; get it free from ollama.com".into())
    }
    /// Start the installed Ollama in the background (no window).
    fn llm_local_start(&self) -> Result<(), String> {
        Err("starting a local model server is not available in this build".into())
    }
    /// Download a model into Ollama. `progress(done_bytes, total_bytes, status)`
    /// returns false to stop (Ollama keeps what it has and resumes next time).
    fn llm_local_pull(
        &self,
        _url: &str,
        _model: &str,
        _progress: &mut dyn FnMut(u64, u64, &str) -> bool,
    ) -> Result<(), String> {
        Err("downloading local models is not available in this build".into())
    }
}

#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct LocalProbe {
    /// Ollama's program was found on this computer.
    pub installed: bool,
    /// Its server answered at the configured address.
    pub running: bool,
    pub models: Vec<String>,
    /// Every installed model with its size and kind (found by scanning the server).
    pub details: Vec<LocalModel>,
}

/// One model installed in the local model server.
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct LocalModel {
    pub name: String,
    /// Size on disk in bytes.
    pub size: u64,
    /// e.g. "llama", "qwen2"
    pub family: String,
    /// e.g. "7.6B"
    pub parameters: String,
    /// False for embedding-only models, which can't hold a conversation.
    pub can_chat: bool,
}

/// Used when no online implementation is installed.
pub struct NoOnline;
impl Online for NoOnline {
    fn musicbrainz_recordings(&self, _: &str, _: &str) -> Result<Vec<MbRecording>, String> {
        Err("online services are not available in this build".into())
    }
    fn musicbrainz_artist_releases(&self, _: &str) -> Result<Vec<ReleaseItem>, String> {
        Err("online services are not available in this build".into())
    }
    fn acoustid_lookup(&self, _: &str, _: u32, _: &str) -> Result<Vec<AcoustidMatch>, String> {
        Err("online services are not available in this build".into())
    }
    fn lastfm_similar_artists(&self, _: &str, _: &str) -> Result<Vec<SimilarItem>, String> {
        Err("online services are not available in this build".into())
    }
    fn lastfm_similar_tracks(&self, _: &str, _: &str, _: &str) -> Result<Vec<SimilarItem>, String> {
        Err("online services are not available in this build".into())
    }
}

/// Credential storage (Windows Credential Manager in the desktop app).
/// Secrets are never returned to the UI; it can only ask whether one is set.
pub trait Secrets: Send + Sync {
    fn get(&self, service: &str) -> Option<String>;
    fn set(&self, service: &str, value: &str) -> Result<(), String>;
    fn delete(&self, service: &str) -> Result<(), String>;
}

#[derive(Default)]
pub struct MemorySecrets(std::sync::Mutex<std::collections::HashMap<String, String>>);
impl Secrets for MemorySecrets {
    fn get(&self, s: &str) -> Option<String> {
        self.0.lock().ok()?.get(s).cloned()
    }
    fn set(&self, s: &str, v: &str) -> Result<(), String> {
        self.0
            .lock()
            .map_err(|_| "lock")?
            .insert(s.into(), v.into());
        Ok(())
    }
    fn delete(&self, s: &str) -> Result<(), String> {
        self.0.lock().map_err(|_| "lock")?.remove(s);
        Ok(())
    }
}

pub const SERVICES: &[(&str, &str, &str, &str)] = &[
    (
        "musicbrainz",
        "MusicBrainz",
        "Recording, artist, release and original-year information; new releases from artists you follow.",
        "The artist and title text of tracks you choose to look up (or artist names you follow). Never audio, file paths or listening history.",
    ),
    (
        "catalogs",
        "Deezer & Apple Music catalogues",
        "Exact BPM, release year, genre and label for your tracks from two free music catalogues (no key needed). Auto-prep checks new music against them and fixes values the catalogues agree on.",
        "The artist and title text of tracks being looked up. Never audio, file paths or listening history.",
    ),
    (
        "spotify",
        "Spotify",
        "Release date, artist credits, album and genres for your tracks (and BPM and key where Spotify still allows it). Checked together with the other catalogues.",
        "The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free Spotify developer app (developer.spotify.com/dashboard): its Client ID and Client secret.",
    ),
    (
        "getsongbpm",
        "GetSongBPM",
        "Tempo and musical key for your tracks, checked against this computer's audio analysis. Data from GetSongBPM.com.",
        "The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free GetSongBPM API key (getsongbpm.com/api).",
    ),
    (
        "youtube",
        "YouTube & YouTube Music",
        "Exact release date, label and album from the official YouTube Music release of each track (its \"Artist - Topic\" video). The free quota covers about 100 tracks a day.",
        "The artist and title text of tracks being looked up. Never audio, file paths or listening history. Needs a free YouTube Data API key (console.cloud.google.com → APIs → YouTube Data API v3 → Credentials).",
    ),
    (
        "acoustid",
        "AcoustID",
        "Possible identification of tracks from an audio fingerprint.",
        "A compact audio fingerprint and the track duration, only after you confirm each lookup. Never the audio itself. Needs your free AcoustID application key.",
    ),
    (
        "lastfm",
        "Last.fm",
        "Similar artists and tracks for discovery.",
        "Artist and track names from the crate or tracks you choose. Needs your Last.fm API key.",
    ),
    (
        "anthropic",
        "AI assistant (online)",
        "Answers questions about your library and the app, and proposes actions you approve. Choose Claude, ChatGPT, Gemini, Grok, Mistral, DeepSeek and more.",
        "Your messages to the assistant and the catalogue details its tools look up (titles, artists, genres, ratings and similar), to the AI service you choose. Never audio, file paths or personal documents. Needs that service's API key.",
    ),
    (
        "updates",
        "App updates",
        "Checks GitHub for a newer DJ Assistant and installs it when you agree.",
        "Your app version and Windows platform, sent to GitHub when checking.",
    ),
];
