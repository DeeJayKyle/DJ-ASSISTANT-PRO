//! Read-only probing of DJ video files (music videos, visuals, loops).
//!
//! Small, bounded parsers for the container formats DJs use with Serato
//! Video and similar tools: MP4 / M4V / MOV (ISO-BMFF boxes), Matroska /
//! WebM (EBML) and AVI (RIFF). They read the container's headers only —
//! never the video frames — and never open a file for writing.
//!
//! Every length read from a file is checked against the file size and a
//! hard cap, so a corrupt or hostile file cannot make us allocate or seek
//! without bound.
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Largest header region we will read into memory (moov box, Matroska
/// Tracks/Tags, AVI hdrl/INFO). Real files use a few KB to a few MB.
const MAX_HEADER: u64 = 32 * 1024 * 1024;

#[derive(Debug, Default, Clone, PartialEq)]
pub struct VideoInfo {
    /// Short container name shown in the Format column: MP4, MOV, MKV, WebM, AVI.
    pub container: String,
    /// True when the file has at least one video track.
    pub has_video: bool,
    pub video_codec: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub frame_rate: Option<f64>,
    pub duration_ms: Option<i64>,
    pub audio_codec: Option<String>,
    pub sample_rate: Option<i64>,
    pub channels: Option<i64>,
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub genre: Option<String>,
    pub date: Option<String>,
    pub comment: Option<String>,
}

fn clean(s: &str) -> Option<String> {
    let t = s.trim().trim_matches('\0').trim();
    (!t.is_empty()).then(|| t.to_string())
}

fn round_fps(f: f64) -> Option<f64> {
    (f.is_finite() && f > 0.5 && f < 1000.0).then(|| (f * 1000.0).round() / 1000.0)
}

fn be_u16(b: &[u8], o: usize) -> Option<u16> {
    Some(u16::from_be_bytes(b.get(o..o + 2)?.try_into().ok()?))
}
fn be_u32(b: &[u8], o: usize) -> Option<u32> {
    Some(u32::from_be_bytes(b.get(o..o + 4)?.try_into().ok()?))
}
fn be_u64(b: &[u8], o: usize) -> Option<u64> {
    Some(u64::from_be_bytes(b.get(o..o + 8)?.try_into().ok()?))
}
fn le_u16(b: &[u8], o: usize) -> Option<u16> {
    Some(u16::from_le_bytes(b.get(o..o + 2)?.try_into().ok()?))
}
fn le_u32(b: &[u8], o: usize) -> Option<u32> {
    Some(u32::from_le_bytes(b.get(o..o + 4)?.try_into().ok()?))
}

/// Probe a video container by extension. Errors mean the file is not a
/// readable container of that kind (corrupt, truncated or mislabelled).
pub fn probe(path: &Path, ext: &str) -> Result<VideoInfo, String> {
    let mut f = File::open(path).map_err(|e| format!("cannot open: {e}"))?;
    let len = f.metadata().map_err(|e| format!("cannot read: {e}"))?.len();
    match ext {
        "mp4" | "m4v" | "mov" => probe_mp4(&mut f, len, ext),
        "mkv" | "webm" => probe_mkv(&mut f, len),
        "avi" => probe_avi(&mut f, len),
        _ => Err(format!("{ext} video files are not supported")),
    }
}

// ---------------------------------------------------------------- MP4 / MOV

fn mp4_video_codec(fourcc: &[u8]) -> String {
    match fourcc {
        b"avc1" | b"avc3" => "H.264".into(),
        b"hvc1" | b"hev1" => "HEVC (H.265)".into(),
        b"av01" => "AV1".into(),
        b"vp09" => "VP9".into(),
        b"vp08" => "VP8".into(),
        b"mp4v" => "MPEG-4 Part 2".into(),
        b"apcn" | b"apch" | b"apcs" | b"apco" | b"ap4h" | b"ap4x" => "Apple ProRes".into(),
        b"jpeg" | b"mjpa" | b"mjpb" => "Motion JPEG".into(),
        b"hap1" | b"hap5" | b"hapy" | b"hapm" | b"hapa" => "HAP".into(),
        b"dvh1" | b"dvhe" => "Dolby Vision".into(),
        other => String::from_utf8_lossy(other).trim().to_string(),
    }
}

fn mp4_audio_codec(fourcc: &[u8]) -> String {
    match fourcc {
        b"mp4a" => "AAC".into(),
        b"alac" => "ALAC".into(),
        b".mp3" | b"mp3 " => "MP3".into(),
        b"ac-3" => "AC-3".into(),
        b"ec-3" => "E-AC-3".into(),
        b"Opus" => "Opus".into(),
        b"fLaC" => "FLAC".into(),
        b"lpcm" | b"sowt" | b"twos" | b"in24" | b"in32" | b"fl32" | b"raw " => "PCM".into(),
        other => String::from_utf8_lossy(other).trim().to_string(),
    }
}

/// Iterate the child boxes in `b`: yields (type, payload).
fn boxes(b: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = vec![];
    let mut o = 0usize;
    while o + 8 <= b.len() {
        let Some(size32) = be_u32(b, o) else { break };
        let typ: [u8; 4] = b[o + 4..o + 8].try_into().unwrap_or([0; 4]);
        let (hdr, size) = match size32 {
            0 => (8usize, (b.len() - o) as u64),
            1 => match be_u64(b, o + 8) {
                Some(s) => (16usize, s),
                None => break,
            },
            s => (8usize, s as u64),
        };
        if size < hdr as u64 || o as u64 + size > b.len() as u64 {
            break;
        }
        let end = o + size as usize;
        out.push((typ, &b[o + hdr..end]));
        o = end;
    }
    out
}

fn child<'a>(b: &'a [u8], typ: &[u8; 4]) -> Option<&'a [u8]> {
    boxes(b).into_iter().find(|(t, _)| t == typ).map(|(_, p)| p)
}

fn probe_mp4(f: &mut File, len: u64, ext: &str) -> Result<VideoInfo, String> {
    // Walk the top level to find ftyp and moov without reading media data.
    let mut pos = 0u64;
    let mut moov: Option<Vec<u8>> = None;
    let mut saw_ftyp = false;
    let mut brand = [0u8; 4];
    while pos + 8 <= len {
        f.seek(SeekFrom::Start(pos)).map_err(|e| e.to_string())?;
        let mut h = [0u8; 16];
        let n = f.read(&mut h).map_err(|e| e.to_string())?;
        if n < 8 {
            break;
        }
        let size32 = u32::from_be_bytes(h[0..4].try_into().unwrap());
        let typ: [u8; 4] = h[4..8].try_into().unwrap();
        let (hdr, size) = match size32 {
            0 => (8u64, len - pos),
            1 if n >= 16 => (16u64, u64::from_be_bytes(h[8..16].try_into().unwrap())),
            1 => break,
            s => (8u64, s as u64),
        };
        if size < hdr || pos + size > len {
            break;
        }
        // The first box must be a known top-level type, otherwise this is not ISO-BMFF.
        if pos == 0
            && !matches!(
                &typ,
                b"ftyp" | b"moov" | b"wide" | b"mdat" | b"free" | b"skip" | b"pnot"
            )
        {
            return Err("not a recognised MP4/MOV file (contents do not match)".into());
        }
        if &typ == b"ftyp" {
            saw_ftyp = true;
            brand.copy_from_slice(&h[8..12]);
        }
        if &typ == b"moov" {
            let body = size - hdr;
            if body > MAX_HEADER {
                return Err("movie header is unreasonably large; file skipped".into());
            }
            let mut buf = vec![0u8; body as usize];
            f.seek(SeekFrom::Start(pos + hdr))
                .map_err(|e| e.to_string())?;
            f.read_exact(&mut buf)
                .map_err(|_| "file is truncated (movie header incomplete)".to_string())?;
            moov = Some(buf);
            break;
        }
        pos += size;
    }
    let moov = moov.ok_or_else(|| {
        if saw_ftyp {
            "no movie header found (file may be incomplete)".to_string()
        } else {
            "not a recognised MP4/MOV file (contents do not match)".to_string()
        }
    })?;
    let container = if ext == "mov" || &brand == b"qt  " {
        "MOV"
    } else if ext == "m4v" {
        "M4V"
    } else {
        "MP4"
    };
    let mut v = VideoInfo {
        container: container.into(),
        ..Default::default()
    };
    if let Some(mvhd) = child(&moov, b"mvhd") {
        let (ts, dur) = if mvhd.first() == Some(&1) {
            (be_u32(mvhd, 20), be_u64(mvhd, 24))
        } else {
            (be_u32(mvhd, 12), be_u32(mvhd, 16).map(|d| d as u64))
        };
        if let (Some(ts), Some(d)) = (ts, dur) {
            if ts > 0 && d > 0 && d != u32::MAX as u64 {
                v.duration_ms = Some((d as f64 * 1000.0 / ts as f64).round() as i64);
            }
        }
    }
    for (t, trak) in boxes(&moov) {
        if &t != b"trak" {
            continue;
        }
        let Some(mdia) = child(trak, b"mdia") else {
            continue;
        };
        let handler = child(mdia, b"hdlr")
            .and_then(|h| h.get(8..12))
            .unwrap_or(&[]);
        let (mdhd_ts, mdhd_dur) = child(mdia, b"mdhd")
            .map(|m| {
                if m.first() == Some(&1) {
                    (
                        be_u32(m, 20).unwrap_or(0) as u64,
                        be_u64(m, 24).unwrap_or(0),
                    )
                } else {
                    (
                        be_u32(m, 12).unwrap_or(0) as u64,
                        be_u32(m, 16).unwrap_or(0) as u64,
                    )
                }
            })
            .unwrap_or((0, 0));
        let stbl = child(mdia, b"minf").and_then(|m| child(m, b"stbl"));
        let entry = stbl
            .and_then(|s| child(s, b"stsd"))
            .and_then(|s| s.get(8..))
            .filter(|e| e.len() >= 8);
        if handler == b"vide" && !v.has_video {
            v.has_video = true;
            if let Some(e) = entry {
                v.video_codec = Some(mp4_video_codec(&e[4..8]));
                // Visual sample entry: 8 header + 6 reserved + 2 dref + 16 = width at 32.
                let w = be_u16(e, 32).unwrap_or(0) as i64;
                let h = be_u16(e, 34).unwrap_or(0) as i64;
                if w > 0 && h > 0 {
                    v.width = Some(w);
                    v.height = Some(h);
                }
            }
            if v.width.is_none() {
                if let Some(tkhd) = child(trak, b"tkhd") {
                    let n = tkhd.len();
                    if n >= 8 {
                        let w = (be_u32(tkhd, n - 8).unwrap_or(0) >> 16) as i64;
                        let h = (be_u32(tkhd, n - 4).unwrap_or(0) >> 16) as i64;
                        if w > 0 && h > 0 {
                            v.width = Some(w);
                            v.height = Some(h);
                        }
                    }
                }
            }
            if let Some(stts) = stbl.and_then(|s| child(s, b"stts")) {
                let count = be_u32(stts, 4).unwrap_or(0).min(1_000_000) as usize;
                let mut frames = 0u64;
                for i in 0..count {
                    frames += be_u32(stts, 8 + i * 8).unwrap_or(0) as u64;
                }
                if frames > 0 && mdhd_ts > 0 && mdhd_dur > 0 {
                    v.frame_rate = round_fps(frames as f64 * mdhd_ts as f64 / mdhd_dur as f64);
                }
            }
        } else if handler == b"soun" && v.audio_codec.is_none() {
            if let Some(e) = entry {
                v.audio_codec = Some(mp4_audio_codec(&e[4..8]));
                // Sound sample entry: channels at 24, sample rate (16.16) at 32.
                v.channels = be_u16(e, 24).map(|c| c as i64).filter(|c| *c > 0);
                v.sample_rate = be_u32(e, 32).map(|r| (r >> 16) as i64).filter(|r| *r > 0);
            }
        }
    }
    // QuickTime-style user data (©nam, ©ART…) used by .mov files.
    if let Some(udta) = child(&moov, b"udta") {
        for (t, p) in boxes(udta) {
            let text = || {
                let n = be_u16(p, 0)? as usize;
                p.get(4..4 + n)
                    .and_then(|s| clean(&String::from_utf8_lossy(s)))
            };
            match &t {
                b"\xa9nam" => v.title = v.title.take().or_else(text),
                b"\xa9ART" => v.artist = v.artist.take().or_else(text),
                b"\xa9alb" => v.album = v.album.take().or_else(text),
                b"\xa9gen" => v.genre = v.genre.take().or_else(text),
                b"\xa9day" => v.date = v.date.take().or_else(text),
                b"\xa9cmt" => v.comment = v.comment.take().or_else(text),
                _ => {}
            }
        }
    }
    Ok(v)
}

// ------------------------------------------------------------ Matroska/WebM

const EBML: u32 = 0x1A45_DFA3;
const DOCTYPE: u32 = 0x4282;
const SEGMENT: u32 = 0x1853_8067;
const INFO: u32 = 0x1549_A966;
const TIMECODE_SCALE: u32 = 0x2A_D7B1;
const DURATION: u32 = 0x4489;
const SEG_TITLE: u32 = 0x7BA9;
const TRACKS: u32 = 0x1654_AE6B;
const TRACK_ENTRY: u32 = 0xAE;
const TRACK_TYPE: u32 = 0x83;
const CODEC_ID: u32 = 0x86;
const DEFAULT_DURATION: u32 = 0x23_E383;
const VIDEO: u32 = 0xE0;
const PIXEL_WIDTH: u32 = 0xB0;
const PIXEL_HEIGHT: u32 = 0xBA;
const AUDIO: u32 = 0xE1;
const SAMPLING_FREQ: u32 = 0xB5;
const CHANNELS: u32 = 0x9F;
const TAGS: u32 = 0x1254_C367;
const TAG: u32 = 0x7373;
const TARGETS: u32 = 0x63C0;
const SIMPLE_TAG: u32 = 0x67C8;
const TAG_NAME: u32 = 0x45A3;
const TAG_STRING: u32 = 0x4487;
const CLUSTER: u32 = 0x1F43_B675;

/// Read an EBML element ID (marker bits kept). Returns (id, length).
fn ebml_id(b: &[u8]) -> Option<(u32, usize)> {
    let first = *b.first()?;
    let n = first.leading_zeros() as usize + 1;
    if n > 4 || b.len() < n {
        return None;
    }
    Some((b[..n].iter().fold(0u32, |a, x| (a << 8) | *x as u32), n))
}

/// Read an EBML size. Returns (size or None for "unknown", length).
fn ebml_size(b: &[u8]) -> Option<(Option<u64>, usize)> {
    let first = *b.first()?;
    let n = first.leading_zeros() as usize + 1;
    if n > 8 || b.len() < n {
        return None;
    }
    let mut v = (first as u64) & ((1u64 << (8 - n)) - 1);
    let mut all_ones = v == (1u64 << (8 - n)) - 1;
    for x in &b[1..n] {
        v = (v << 8) | *x as u64;
        all_ones &= *x == 0xFF;
    }
    Some((if all_ones { None } else { Some(v) }, n))
}

/// Child elements of an in-memory EBML master element.
fn ebml_children(b: &[u8]) -> Vec<(u32, &[u8])> {
    let mut out = vec![];
    let mut o = 0usize;
    while o < b.len() {
        let Some((id, il)) = ebml_id(&b[o..]) else {
            break;
        };
        let Some((size, sl)) = ebml_size(&b[o + il..]) else {
            break;
        };
        let start = o + il + sl;
        let end = match size {
            Some(s) if (start as u64 + s) <= b.len() as u64 => start + s as usize,
            _ => b.len(),
        };
        out.push((id, &b[start..end]));
        o = end;
    }
    out
}

fn ebml_uint(b: &[u8]) -> u64 {
    b.iter().take(8).fold(0u64, |a, x| (a << 8) | *x as u64)
}

fn ebml_float(b: &[u8]) -> Option<f64> {
    match b.len() {
        4 => Some(f32::from_be_bytes(b.try_into().ok()?) as f64),
        8 => Some(f64::from_be_bytes(b.try_into().ok()?)),
        _ => None,
    }
}

fn ebml_str(b: &[u8]) -> Option<String> {
    clean(&String::from_utf8_lossy(b))
}

fn mkv_video_codec(id: &str) -> String {
    match id {
        "V_MPEG4/ISO/AVC" => "H.264".into(),
        "V_MPEGH/ISO/HEVC" => "HEVC (H.265)".into(),
        "V_VP8" => "VP8".into(),
        "V_VP9" => "VP9".into(),
        "V_AV1" => "AV1".into(),
        "V_MJPEG" => "Motion JPEG".into(),
        "V_PRORES" => "Apple ProRes".into(),
        "V_THEORA" => "Theora".into(),
        x if x.starts_with("V_MPEG4/ISO/") => "MPEG-4 Part 2".into(),
        x if x.starts_with("V_MPEG2") => "MPEG-2".into(),
        x => x.trim_start_matches("V_").to_string(),
    }
}

fn mkv_audio_codec(id: &str) -> String {
    match id {
        "A_OPUS" => "Opus".into(),
        "A_VORBIS" => "Vorbis".into(),
        "A_MPEG/L3" => "MP3".into(),
        "A_AC3" => "AC-3".into(),
        "A_EAC3" => "E-AC-3".into(),
        "A_FLAC" => "FLAC".into(),
        "A_ALAC" => "ALAC".into(),
        x if x.starts_with("A_AAC") => "AAC".into(),
        x if x.starts_with("A_PCM") => "PCM".into(),
        x => x.trim_start_matches("A_").to_string(),
    }
}

fn read_at(f: &mut File, pos: u64, n: usize) -> Result<Vec<u8>, String> {
    f.seek(SeekFrom::Start(pos)).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; n];
    let mut got = 0;
    while got < n {
        let r = f.read(&mut buf[got..]).map_err(|e| e.to_string())?;
        if r == 0 {
            break;
        }
        got += r;
    }
    buf.truncate(got);
    Ok(buf)
}

fn probe_mkv(f: &mut File, len: u64) -> Result<VideoInfo, String> {
    let not_mkv = || "not a recognised Matroska/WebM file (contents do not match)".to_string();
    let head = read_at(f, 0, 64)?;
    let (id, il) = ebml_id(&head).ok_or_else(not_mkv)?;
    if id != EBML {
        return Err(not_mkv());
    }
    let (hsize, sl) = ebml_size(&head[il..]).ok_or_else(not_mkv)?;
    let hsize = hsize.filter(|s| *s < 4096).ok_or_else(not_mkv)?;
    let hstart = (il + sl) as u64;
    let header = read_at(f, hstart, hsize as usize)?;
    let doctype = ebml_children(&header)
        .into_iter()
        .find(|(i, _)| *i == DOCTYPE)
        .and_then(|(_, b)| ebml_str(b))
        .unwrap_or_default();
    if doctype != "matroska" && doctype != "webm" {
        return Err(not_mkv());
    }
    let mut v = VideoInfo {
        container: if doctype == "webm" { "WebM" } else { "MKV" }.into(),
        ..Default::default()
    };
    // Segment header.
    let mut pos = hstart + hsize;
    let seg = read_at(f, pos, 12)?;
    let (sid, sil) = ebml_id(&seg).ok_or_else(not_mkv)?;
    if sid != SEGMENT {
        return Err("Matroska file has no segment (file may be incomplete)".into());
    }
    let (ssize, ssl) = ebml_size(&seg[sil..]).ok_or_else(not_mkv)?;
    pos += (sil + ssl) as u64;
    let seg_end = ssize.map(|s| (pos + s).min(len)).unwrap_or(len);
    let mut scale = 1_000_000u64;
    let mut duration: Option<f64> = None;
    let mut saw_tracks = false;
    // Walk the segment's top-level children, reading only the ones we need.
    let mut guard = 0;
    while pos + 2 <= seg_end && guard < 10_000 {
        guard += 1;
        let h = read_at(f, pos, 12)?;
        let Some((id, il)) = ebml_id(&h) else { break };
        let Some((size, sl)) = ebml_size(&h[il..]) else {
            break;
        };
        let body = pos + (il + sl) as u64;
        let Some(size) = size else {
            // Unknown-size element (live-streamed cluster): nothing more to read.
            break;
        };
        if body + size > len {
            if id == TRACKS || id == INFO {
                return Err("file is truncated (track header incomplete)".into());
            }
            break;
        }
        match id {
            INFO | TRACKS | TAGS if size <= MAX_HEADER => {
                let b = read_at(f, body, size as usize)?;
                match id {
                    INFO => {
                        for (cid, c) in ebml_children(&b) {
                            match cid {
                                TIMECODE_SCALE => scale = ebml_uint(c).max(1),
                                DURATION => duration = ebml_float(c),
                                SEG_TITLE => v.title = v.title.take().or_else(|| ebml_str(c)),
                                _ => {}
                            }
                        }
                    }
                    TRACKS => {
                        saw_tracks = true;
                        for (tid, t) in ebml_children(&b) {
                            if tid != TRACK_ENTRY {
                                continue;
                            }
                            let kids = ebml_children(t);
                            let ty = kids
                                .iter()
                                .find(|k| k.0 == TRACK_TYPE)
                                .map(|k| ebml_uint(k.1));
                            let codec = kids
                                .iter()
                                .find(|k| k.0 == CODEC_ID)
                                .and_then(|k| ebml_str(k.1))
                                .unwrap_or_default();
                            if ty == Some(1) && !v.has_video {
                                v.has_video = true;
                                v.video_codec = Some(mkv_video_codec(&codec));
                                if let Some(dd) = kids
                                    .iter()
                                    .find(|k| k.0 == DEFAULT_DURATION)
                                    .map(|k| ebml_uint(k.1))
                                    .filter(|d| *d > 0)
                                {
                                    v.frame_rate = round_fps(1e9 / dd as f64);
                                }
                                if let Some((_, vid)) = kids.iter().find(|k| k.0 == VIDEO) {
                                    for (vid_id, x) in ebml_children(vid) {
                                        match vid_id {
                                            PIXEL_WIDTH => {
                                                v.width =
                                                    Some(ebml_uint(x) as i64).filter(|w| *w > 0)
                                            }
                                            PIXEL_HEIGHT => {
                                                v.height =
                                                    Some(ebml_uint(x) as i64).filter(|h| *h > 0)
                                            }
                                            _ => {}
                                        }
                                    }
                                }
                            } else if ty == Some(2) && v.audio_codec.is_none() {
                                v.audio_codec = Some(mkv_audio_codec(&codec));
                                if let Some((_, au)) = kids.iter().find(|k| k.0 == AUDIO) {
                                    for (aid, x) in ebml_children(au) {
                                        match aid {
                                            SAMPLING_FREQ => {
                                                v.sample_rate = ebml_float(x)
                                                    .map(|r| r.round() as i64)
                                                    .filter(|r| *r > 0)
                                            }
                                            CHANNELS => {
                                                v.channels =
                                                    Some(ebml_uint(x) as i64).filter(|c| *c > 0)
                                            }
                                            _ => {}
                                        }
                                    }
                                }
                            }
                        }
                    }
                    _ => {
                        for (tid, tag) in ebml_children(&b) {
                            if tid != TAG {
                                continue;
                            }
                            // Only whole-file tags (no per-track target).
                            let per_track = ebml_children(tag).iter().any(|(k, t)| {
                                *k == TARGETS && ebml_children(t).iter().any(|(x, _)| *x == 0x63C5)
                            });
                            if per_track {
                                continue;
                            }
                            for (sid, st) in ebml_children(tag) {
                                if sid != SIMPLE_TAG {
                                    continue;
                                }
                                let kids = ebml_children(st);
                                let name = kids
                                    .iter()
                                    .find(|k| k.0 == TAG_NAME)
                                    .and_then(|k| ebml_str(k.1))
                                    .unwrap_or_default()
                                    .to_ascii_uppercase();
                                let Some(val) = kids
                                    .iter()
                                    .find(|k| k.0 == TAG_STRING)
                                    .and_then(|k| ebml_str(k.1))
                                else {
                                    continue;
                                };
                                let slot = match name.as_str() {
                                    "TITLE" => &mut v.title,
                                    "ARTIST" => &mut v.artist,
                                    "ALBUM" => &mut v.album,
                                    "GENRE" => &mut v.genre,
                                    "DATE" | "DATE_RELEASED" | "DATE_RECORDED" | "YEAR" => {
                                        &mut v.date
                                    }
                                    "COMMENT" => &mut v.comment,
                                    _ => continue,
                                };
                                if slot.is_none() {
                                    *slot = Some(val);
                                }
                            }
                        }
                    }
                }
            }
            CLUSTER if saw_tracks => {
                // Tags usually come before clusters; if not, skip over media data by size.
            }
            _ => {}
        }
        pos = body + size;
    }
    if !saw_tracks {
        return Err("no track information found (file may be incomplete)".into());
    }
    if let Some(d) = duration.filter(|d| d.is_finite() && *d > 0.0) {
        v.duration_ms = Some((d * scale as f64 / 1e6).round() as i64);
    }
    Ok(v)
}

// ---------------------------------------------------------------------- AVI

fn avi_video_codec(fourcc: &[u8]) -> String {
    let s = String::from_utf8_lossy(fourcc).to_ascii_uppercase();
    match s.trim() {
        "XVID" | "DIVX" | "DX50" | "FMP4" | "MP4V" | "DIV3" | "MP42" | "MP43" => {
            "MPEG-4 Part 2".into()
        }
        "H264" | "X264" | "AVC1" => "H.264".into(),
        "HEVC" | "H265" | "HVC1" => "HEVC (H.265)".into(),
        "MJPG" => "Motion JPEG".into(),
        "DVSD" | "DV25" | "DV50" => "DV".into(),
        "HAP1" | "HAP5" | "HAPY" => "HAP".into(),
        "" => "Uncompressed".into(),
        other => other.to_string(),
    }
}

fn avi_audio_codec(tag: u16) -> String {
    match tag {
        0x0001 => "PCM".into(),
        0x0003 => "PCM (float)".into(),
        0x0055 => "MP3".into(),
        0x0050 => "MPEG audio".into(),
        0x00FF | 0x1610 | 0x706D => "AAC".into(),
        0x2000 => "AC-3".into(),
        0x0161 | 0x0162 => "WMA".into(),
        other => format!("format 0x{other:04X}"),
    }
}

/// RIFF chunks in `b` (little-endian sizes, word-aligned).
fn riff_chunks(b: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = vec![];
    let mut o = 0usize;
    while o + 8 <= b.len() {
        let id: [u8; 4] = b[o..o + 4].try_into().unwrap_or([0; 4]);
        let size = le_u32(b, o + 4).unwrap_or(0) as usize;
        let start = o + 8;
        let end = start.saturating_add(size).min(b.len());
        out.push((id, &b[start..end]));
        o = end + (size & 1);
    }
    out
}

fn probe_avi(f: &mut File, len: u64) -> Result<VideoInfo, String> {
    let not_avi = || "not a recognised AVI file (contents do not match)".to_string();
    let head = read_at(f, 0, 12)?;
    if head.len() < 12 || &head[0..4] != b"RIFF" || &head[8..12] != b"AVI " {
        return Err(not_avi());
    }
    let mut v = VideoInfo {
        container: "AVI".into(),
        ..Default::default()
    };
    let mut pos = 12u64;
    let mut saw_hdrl = false;
    let mut us_per_frame = 0u32;
    let mut total_frames = 0u32;
    let mut guard = 0;
    while pos + 12 <= len && guard < 1000 {
        guard += 1;
        let h = read_at(f, pos, 12)?;
        if h.len() < 12 {
            break;
        }
        let size = le_u32(&h, 4).unwrap_or(0) as u64;
        let is_list = &h[0..4] == b"LIST";
        let list_type = &h[8..12];
        if is_list && (list_type == b"hdrl" || list_type == b"INFO") {
            if size > MAX_HEADER || pos + 8 + size > len {
                if list_type == b"hdrl" {
                    return Err("file is truncated (header incomplete)".into());
                }
                break;
            }
            let b = read_at(f, pos + 12, (size - 4) as usize)?;
            if list_type == b"hdrl" {
                saw_hdrl = true;
                for (id, c) in riff_chunks(&b) {
                    if &id == b"avih" {
                        us_per_frame = le_u32(c, 0).unwrap_or(0);
                        total_frames = le_u32(c, 16).unwrap_or(0);
                        v.width = le_u32(c, 32).map(|w| w as i64).filter(|w| *w > 0);
                        v.height = le_u32(c, 36).map(|h| h as i64).filter(|h| *h > 0);
                    } else if &id == b"LIST" && c.get(0..4) == Some(b"strl") {
                        let parts = riff_chunks(&c[4..]);
                        let strh = parts.iter().find(|p| &p.0 == b"strh").map(|p| p.1);
                        let strf = parts.iter().find(|p| &p.0 == b"strf").map(|p| p.1);
                        let Some(strh) = strh else { continue };
                        match strh.get(0..4) {
                            Some(b"vids") if !v.has_video => {
                                v.has_video = true;
                                let compression = strf
                                    .and_then(|s| s.get(16..20))
                                    .unwrap_or(&strh[4..8.min(strh.len())]);
                                v.video_codec = Some(avi_video_codec(compression));
                                let scale = le_u32(strh, 20).unwrap_or(0);
                                let rate = le_u32(strh, 24).unwrap_or(0);
                                if scale > 0 && rate > 0 {
                                    v.frame_rate = round_fps(rate as f64 / scale as f64);
                                }
                            }
                            Some(b"auds") if v.audio_codec.is_none() => {
                                if let Some(sf) = strf {
                                    v.audio_codec = le_u16(sf, 0).map(avi_audio_codec);
                                    v.channels = le_u16(sf, 2).map(|c| c as i64).filter(|c| *c > 0);
                                    v.sample_rate =
                                        le_u32(sf, 4).map(|r| r as i64).filter(|r| *r > 0);
                                }
                            }
                            _ => {}
                        }
                    }
                }
            } else {
                for (id, c) in riff_chunks(&b) {
                    let val = clean(&String::from_utf8_lossy(c));
                    match &id {
                        b"INAM" => v.title = v.title.take().or(val),
                        b"IART" => v.artist = v.artist.take().or(val),
                        b"IPRD" => v.album = v.album.take().or(val),
                        b"IGNR" => v.genre = v.genre.take().or(val),
                        b"ICRD" => v.date = v.date.take().or(val),
                        b"ICMT" => v.comment = v.comment.take().or(val),
                        _ => {}
                    }
                }
            }
        }
        pos += 8 + size + (size & 1);
    }
    if !saw_hdrl {
        return Err("no AVI header found (file may be incomplete)".into());
    }
    if v.frame_rate.is_none() && us_per_frame > 0 {
        v.frame_rate = round_fps(1e6 / us_per_frame as f64);
    }
    if total_frames > 0 {
        if let Some(fps) = v.frame_rate {
            v.duration_ms = Some((total_frames as f64 / fps * 1000.0).round() as i64);
        }
    }
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ebml_varints() {
        assert_eq!(ebml_id(&[0x1A, 0x45, 0xDF, 0xA3]), Some((EBML, 4)));
        assert_eq!(ebml_id(&[0x83]), Some((0x83, 1)));
        assert_eq!(ebml_size(&[0x81]), Some((Some(1), 1)));
        assert_eq!(ebml_size(&[0x40, 0x02]), Some((Some(2), 2)));
        assert_eq!(ebml_size(&[0xFF]), Some((None, 1)));
        assert_eq!(
            ebml_size(&[0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
            Some((None, 8))
        );
        assert_eq!(ebml_size(&[0x00]), None);
    }
}
