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
    /// One chat completion from an OpenAI-compatible service (Quick Prep's
    /// optional AI help). `messages` are (role, content) pairs; returns the
    /// reply text.
    fn ai_chat(
        &self,
        _base_url: &str,
        _api_key: Option<&str>,
        _model: &str,
        _messages: &[(String, String)],
    ) -> Result<String, String> {
        Err("online services are not available in this build".into())
    }
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
        "ai",
        "AI help",
        "Sharper clean names and genres in Quick Prep, and set orders from a request you type.",
        "File names, tag text and the BPM, key and energy of the tracks you choose, to the AI service you pick (with your own key, or Ollama on this computer). Never audio, file paths or listening history.",
    ),
    (
        "updates",
        "App updates",
        "Checks GitHub for a newer DJ Assistant and installs it when you agree.",
        "Your app version and Windows platform, sent to GitHub when checking.",
    ),
];
