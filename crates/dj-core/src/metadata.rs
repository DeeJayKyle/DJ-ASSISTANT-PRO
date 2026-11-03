//! Read-only metadata extraction. Files are opened for reading only; no
//! tag-writing API from lofty is ever called in this crate.
use lofty::config::ParseOptions;
use lofty::file::{AudioFile, FileType, TaggedFileExt};
use lofty::prelude::Accessor;
use lofty::probe::Probe;
use lofty::tag::{ItemKey, Tag};
use std::fs::File;
use std::path::Path;

/// Extensions treated as music. Files with other extensions are ignored.
pub const SUPPORTED_EXTENSIONS: &[&str] = &[
    "mp3", "flac", "wav", "wave", "aif", "aiff", "aifc", "m4a", "mp4", "aac", "ogg", "oga", "opus",
    "ape", "wv", "mpc", "spx", "alac",
];
/// Music-like extensions we recognise but cannot read reliably yet.
/// They are listed in Library Health as unsupported rather than silently ignored.
pub const UNSUPPORTED_MUSIC_EXTENSIONS: &[&str] = &[
    "wma", "dsf", "dff", "m4p", "ra", "rm", "ac3", "mka", "amr", "mid", "midi",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExtKind {
    Supported,
    UnsupportedMusic,
    Other,
}

pub fn classify_extension(ext: &str) -> ExtKind {
    let e = ext.to_ascii_lowercase();
    if SUPPORTED_EXTENSIONS.contains(&e.as_str()) {
        ExtKind::Supported
    } else if UNSUPPORTED_MUSIC_EXTENSIONS.contains(&e.as_str()) {
        ExtKind::UnsupportedMusic
    } else {
        ExtKind::Other
    }
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct AudioMeta {
    pub format: Option<String>,
    pub codec: Option<String>,
    /// Some(true) lossless, Some(false) lossy, None unknown.
    pub lossless: Option<bool>,
    pub duration_ms: Option<i64>,
    /// Average/nominal audio bitrate as reported by the container. May be an
    /// average for VBR files; None when not reported.
    pub bitrate_kbps: Option<i64>,
    pub sample_rate: Option<i64>,
    pub bit_depth: Option<i64>,
    pub channels: Option<i64>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub album_artist: Option<String>,
    pub genre: Option<String>,
    pub year: Option<i64>,
    pub date_text: Option<String>,
    pub original_year: Option<i64>,
    pub track_no: Option<i64>,
    pub disc_no: Option<i64>,
    pub composer: Option<String>,
    pub label: Option<String>,
    pub comment: Option<String>,
    pub isrc: Option<String>,
    pub bpm: Option<f64>,
    pub key: Option<String>,
}

fn clean(s: Option<&str>) -> Option<String> {
    s.map(|v| v.trim().trim_matches('\0').trim().to_string())
        .filter(|v| !v.is_empty())
}

fn parse_year(s: &str) -> Option<i64> {
    let digits: String = s.trim().chars().take(4).collect();
    if digits.len() == 4 && digits.chars().all(|c| c.is_ascii_digit()) {
        let y: i64 = digits.parse().ok()?;
        if (1000..=9999).contains(&y) && y != 0 {
            return Some(y);
        }
    }
    None
}

fn parse_bpm(s: &str) -> Option<f64> {
    let v: f64 = s.trim().replace(',', ".").parse().ok()?;
    if v.is_finite() && v > 0.0 && v < 1000.0 {
        Some(v)
    } else {
        None
    }
}

fn read_tag(tag: &Tag, m: &mut AudioMeta) {
    m.title = m.title.take().or_else(|| clean(tag.title().as_deref()));
    m.artist = m.artist.take().or_else(|| clean(tag.artist().as_deref()));
    m.album = m.album.take().or_else(|| clean(tag.album().as_deref()));
    m.genre = m.genre.take().or_else(|| clean(tag.genre().as_deref()));
    m.comment = m.comment.take().or_else(|| clean(tag.comment().as_deref()));
    m.album_artist = m
        .album_artist
        .take()
        .or_else(|| clean(tag.get_string(ItemKey::AlbumArtist)));
    m.composer = m
        .composer
        .take()
        .or_else(|| clean(tag.get_string(ItemKey::Composer)));
    m.label = m
        .label
        .take()
        .or_else(|| clean(tag.get_string(ItemKey::Label)))
        .or_else(|| clean(tag.get_string(ItemKey::Publisher)));
    m.isrc = m
        .isrc
        .take()
        .or_else(|| clean(tag.get_string(ItemKey::Isrc)));
    m.key = m
        .key
        .take()
        .or_else(|| clean(tag.get_string(ItemKey::InitialKey)));
    if m.bpm.is_none() {
        m.bpm = tag
            .get_string(ItemKey::Bpm)
            .and_then(parse_bpm)
            .or_else(|| tag.get_string(ItemKey::IntegerBpm).and_then(parse_bpm));
    }
    if m.date_text.is_none() {
        let d = tag
            .get_string(ItemKey::RecordingDate)
            .or_else(|| tag.get_string(ItemKey::Year));
        m.date_text = clean(d);
        m.year = m.date_text.as_deref().and_then(parse_year);
    }
    if m.original_year.is_none() {
        m.original_year = tag
            .get_string(ItemKey::OriginalReleaseDate)
            .and_then(parse_year);
    }
    if m.track_no.is_none() {
        m.track_no = tag.track().map(|v| v as i64);
    }
    if m.disc_no.is_none() {
        m.disc_no = tag.disk().map(|v| v as i64);
    }
}

fn file_type_name(ft: &FileType) -> &'static str {
    match ft {
        FileType::Aac => "AAC",
        FileType::Aiff => "AIFF",
        FileType::Ape => "APE",
        FileType::Flac => "FLAC",
        FileType::Mpeg => "MP3",
        FileType::Mp4 => "MP4",
        FileType::Mpc => "Musepack",
        FileType::Opus => "Opus",
        FileType::Vorbis => "Ogg Vorbis",
        FileType::Speex => "Speex",
        FileType::Wav => "WAV",
        FileType::WavPack => "WavPack",
        _ => "Other",
    }
}

/// Determine codec and losslessness, opening the file again read-only for
/// container types whose codec is not visible from generic properties.
fn codec_info(path: &Path, ft: &FileType) -> (Option<String>, Option<bool>) {
    let opts = ParseOptions::new().read_tags(false).read_cover_art(false);
    match ft {
        FileType::Flac => (Some("FLAC".into()), Some(true)),
        FileType::Ape => (Some("Monkey's Audio".into()), Some(true)),
        FileType::Mpeg => (Some("MP3".into()), Some(false)),
        FileType::Aac => (Some("AAC".into()), Some(false)),
        FileType::Opus => (Some("Opus".into()), Some(false)),
        FileType::Vorbis => (Some("Vorbis".into()), Some(false)),
        FileType::Speex => (Some("Speex".into()), Some(false)),
        FileType::Mpc => (Some("Musepack".into()), Some(false)),
        FileType::Wav => {
            let r = File::open(path)
                .ok()
                .and_then(|mut f| lofty::iff::wav::WavFile::read_from(&mut f, opts).ok());
            match r.map(|w| *w.properties().format()) {
                Some(lofty::iff::wav::WavFormat::PCM) => (Some("PCM".into()), Some(true)),
                Some(lofty::iff::wav::WavFormat::IEEE_FLOAT) => {
                    (Some("PCM float".into()), Some(true))
                }
                Some(other) => (Some(format!("{:?}", other)), None),
                None => (None, None),
            }
        }
        FileType::Aiff => {
            use lofty::iff::aiff::AiffCompressionType as C;
            let r = File::open(path)
                .ok()
                .and_then(|mut f| lofty::iff::aiff::AiffFile::read_from(&mut f, opts).ok());
            match r.map(|a| a.properties().compression_type().cloned()) {
                Some(None) | Some(Some(C::None)) | Some(Some(C::sowt)) => {
                    (Some("PCM".into()), Some(true))
                }
                Some(Some(C::fl32)) | Some(Some(C::fl64)) => (Some("PCM float".into()), Some(true)),
                Some(Some(other)) => (Some(format!("{:?}", other)), None),
                None => (None, None),
            }
        }
        FileType::Mp4 => {
            use lofty::mp4::Mp4Codec as C;
            let r = File::open(path)
                .ok()
                .and_then(|mut f| lofty::mp4::Mp4File::read_from(&mut f, opts).ok());
            match r.and_then(|m| m.properties().codec()) {
                Some(C::AAC) => (Some("AAC".into()), Some(false)),
                Some(C::MP3) => (Some("MP3".into()), Some(false)),
                Some(C::ALAC) => (Some("ALAC".into()), Some(true)),
                Some(C::FLAC) => (Some("FLAC".into()), Some(true)),
                _ => (None, None),
            }
        }
        FileType::WavPack => {
            let r = File::open(path)
                .ok()
                .and_then(|mut f| lofty::wavpack::WavPackFile::read_from(&mut f, opts).ok());
            match r.map(|w| w.properties().is_lossless()) {
                Some(true) => (Some("WavPack".into()), Some(true)),
                Some(false) => (Some("WavPack hybrid (lossy)".into()), Some(false)),
                None => (Some("WavPack".into()), None),
            }
        }
        _ => (None, None),
    }
}

/// Read metadata and technical properties. Returns Err with a readable
/// message if the file is unreadable or not a valid audio file.
pub fn read_audio_meta(path: &Path) -> Result<AudioMeta, String> {
    let opts = ParseOptions::new().read_cover_art(false);
    let probe = Probe::open(path)
        .map_err(|e| format!("cannot open: {e}"))?
        .options(opts);
    let probe = probe
        .guess_file_type()
        .map_err(|e| format!("cannot read: {e}"))?;
    let ft = match probe.file_type() {
        Some(ft) => ft,
        None => {
            return Err(
                "not a recognised audio file (contents do not match a supported format)".into(),
            )
        }
    };
    let tagged = probe
        .read()
        .map_err(|e| format!("could not parse audio data: {e}"))?;
    let props = tagged.properties();
    let mut m = AudioMeta {
        format: Some(file_type_name(&ft).to_string()),
        ..Default::default()
    };
    let dur = props.duration().as_millis() as i64;
    m.duration_ms = if dur > 0 { Some(dur) } else { None };
    m.bitrate_kbps = props.audio_bitrate().filter(|b| *b > 0).map(|b| b as i64);
    m.sample_rate = props.sample_rate().filter(|v| *v > 0).map(|v| v as i64);
    m.bit_depth = props.bit_depth().filter(|v| *v > 0).map(|v| v as i64);
    m.channels = props.channels().filter(|v| *v > 0).map(|v| v as i64);
    if let Some(t) = tagged.primary_tag() {
        read_tag(t, &mut m);
    }
    for t in tagged.tags() {
        read_tag(t, &mut m);
    }
    let (codec, lossless) = codec_info(path, &ft);
    m.codec = codec;
    m.lossless = lossless;
    if ft == FileType::Mp4 {
        if let Some(c) = &m.codec {
            m.format = Some(format!("M4A ({c})"));
        }
    }
    Ok(m)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn years_and_bpm_parse_conservatively() {
        assert_eq!(parse_year("2014-05-01"), Some(2014));
        assert_eq!(parse_year("14"), None);
        assert_eq!(parse_year("0000"), None);
        assert_eq!(parse_bpm("124.5"), Some(124.5));
        assert_eq!(parse_bpm("0"), None);
        assert_eq!(parse_bpm("abc"), None);
    }
    #[test]
    fn extensions_are_classified() {
        assert_eq!(classify_extension("MP3"), ExtKind::Supported);
        assert_eq!(classify_extension("wma"), ExtKind::UnsupportedMusic);
        assert_eq!(classify_extension("jpg"), ExtKind::Other);
    }
}
