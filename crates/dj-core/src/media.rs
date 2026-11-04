//! Read-only audio streaming for previews: answers HTTP-style range requests
//! for a catalogued track, so the player can start in the middle and seek.
//! Used by the desktop app's `track:` protocol and the dev bridge.
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

/// Largest piece returned for an open-ended range; the player asks again.
const CHUNK: u64 = 2 * 1024 * 1024;

pub struct Piece {
    pub status: u16,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
}

pub fn content_type(path: &Path) -> &'static str {
    match path
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase())
        .as_deref()
    {
        Some("mp3") => "audio/mpeg",
        Some("flac") => "audio/flac",
        Some("wav") => "audio/wav",
        Some("aif") | Some("aiff") => "audio/aiff",
        Some("m4a") | Some("aac") | Some("alac") => "audio/mp4",
        Some("ogg") | Some("oga") => "audio/ogg",
        Some("opus") => "audio/ogg; codecs=opus",
        Some("mp4") | Some("m4v") | Some("mov") => "video/mp4",
        Some("webm") => "video/webm",
        Some("mkv") => "video/x-matroska",
        _ => "application/octet-stream",
    }
}

fn parse_range(h: &str, size: u64) -> Option<(u64, u64)> {
    let r = h.trim().strip_prefix("bytes=")?;
    let (a, b) = r.split_once('-')?;
    let (start, end) = if a.is_empty() {
        let n: u64 = b.parse().ok()?;
        (size.saturating_sub(n), size.saturating_sub(1))
    } else {
        let s: u64 = a.parse().ok()?;
        let e = if b.is_empty() {
            (s + CHUNK - 1).min(size.saturating_sub(1))
        } else {
            b.parse::<u64>().ok()?.min(size.saturating_sub(1))
        };
        (s, e)
    };
    (start <= end && start < size).then_some((start, end))
}

/// Reads the requested bytes of `path` (never writes).
pub fn serve(path: &Path, range: Option<&str>) -> std::io::Result<Piece> {
    let mut f = std::fs::File::open(path)?;
    let size = f.metadata()?.len();
    let ty = content_type(path).to_string();
    let (status, start, end) = match range {
        Some(h) => match parse_range(h, size) {
            Some((s, e)) => (206, s, e),
            None => {
                return Ok(Piece {
                    status: 416,
                    headers: vec![("Content-Range", format!("bytes */{size}"))],
                    body: vec![],
                });
            }
        },
        // Without a range the whole file is sent; players normally ask for ranges.
        None => (200, 0, size.saturating_sub(1)),
    };
    let len = if size == 0 { 0 } else { end - start + 1 };
    let mut body = vec![0; len as usize];
    f.seek(SeekFrom::Start(start))?;
    f.read_exact(&mut body)?;
    let mut headers = vec![
        ("Content-Type", ty),
        ("Accept-Ranges", "bytes".into()),
        ("Content-Length", len.to_string()),
    ];
    if status == 206 {
        headers.push(("Content-Range", format!("bytes {start}-{end}/{size}")));
    }
    Ok(Piece {
        status,
        headers,
        body,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serves_ranges() {
        let mut tmp = tempfile::Builder::new().suffix(".mp3").tempfile().unwrap();
        std::io::Write::write_all(&mut tmp, &(0..100u8).collect::<Vec<_>>()).unwrap();
        let p = tmp.path().to_path_buf();
        let full = serve(&p, None).unwrap();
        assert_eq!((full.status, full.body.len()), (200, 100));
        let r = serve(&p, Some("bytes=10-19")).unwrap();
        assert_eq!(r.status, 206);
        assert_eq!(r.body, (10..20u8).collect::<Vec<_>>());
        assert!(r
            .headers
            .iter()
            .any(|(k, v)| *k == "Content-Range" && v == "bytes 10-19/100"));
        assert_eq!(serve(&p, Some("bytes=90-")).unwrap().body.len(), 10);
        assert_eq!(
            serve(&p, Some("bytes=-5")).unwrap().body,
            vec![95, 96, 97, 98, 99]
        );
        assert_eq!(serve(&p, Some("bytes=200-")).unwrap().status, 416);
        assert_eq!(content_type(&p), "audio/mpeg");
    }
}
