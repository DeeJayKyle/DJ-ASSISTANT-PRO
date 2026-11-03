//! Text helpers: Unicode-aware folding for search and conservative
//! version-label detection used by duplicate review.
use unicode_normalization::char::is_combining_mark;
use unicode_normalization::UnicodeNormalization;

/// Fold text for case- and accent-insensitive matching.
/// "Beyoncé" -> "beyonce", "ÆON" -> "æon". Never used to alter stored metadata.
pub fn fold(s: &str) -> String {
    s.nfd()
        .filter(|c| !is_combining_mark(*c))
        .flat_map(|c| c.to_lowercase())
        .collect::<String>()
}

/// Version labels that indicate a recording may be an intentional alternate
/// version rather than a duplicate. Order matters only for display.
pub const VERSION_MARKERS: &[(&str, &str)] = &[
    ("extended mix", "Extended"),
    ("extended version", "Extended"),
    ("extended", "Extended"),
    ("radio edit", "Radio Edit"),
    ("radio version", "Radio Edit"),
    ("club mix", "Club Mix"),
    ("dub mix", "Dub"),
    ("dub", "Dub"),
    ("remix", "Remix"),
    ("rmx", "Remix"),
    ("bootleg", "Bootleg"),
    ("mashup", "Mashup"),
    ("re-edit", "Edit"),
    ("edit", "Edit"),
    ("live", "Live"),
    ("acoustic", "Acoustic"),
    ("instrumental", "Instrumental"),
    ("acapella", "Acapella"),
    ("a cappella", "Acapella"),
    ("intro", "Intro"),
    ("outro", "Outro"),
    ("clean", "Clean"),
    ("dirty", "Explicit"),
    ("explicit", "Explicit"),
    ("vip", "VIP"),
    ("remaster", "Remaster"),
    ("remastered", "Remaster"),
    ("reprise", "Reprise"),
    ("version", "Version"),
    ("mix", "Mix"),
];

fn contains_word(hay: &str, needle: &str) -> bool {
    let mut start = 0;
    while let Some(pos) = hay[start..].find(needle) {
        let abs = start + pos;
        let before_ok = abs == 0
            || !hay[..abs]
                .chars()
                .last()
                .map(|c| c.is_alphanumeric())
                .unwrap_or(false);
        let end = abs + needle.len();
        let after_ok = end >= hay.len()
            || !hay[end..]
                .chars()
                .next()
                .map(|c| c.is_alphanumeric())
                .unwrap_or(false);
        if before_ok && after_ok {
            return true;
        }
        start = abs + needle.len().max(1);
        if start >= hay.len() {
            break;
        }
    }
    false
}

/// Detect version labels in a title (and optionally the file name).
/// Returns a sorted, de-duplicated, comma-separated list or None.
/// This is a hint derived from text, not proof of what the recording is.
pub fn detect_version_labels(text: &str) -> Option<String> {
    let f = fold(text);
    // Only look inside brackets/after dashes to avoid matching song names
    // like "Live Your Life" or "Intro to Love". If there are no brackets we
    // only accept multi-word markers or a trailing marker after " - ".
    let mut segments: Vec<String> = Vec::new();
    let mut depth = 0usize;
    let mut cur = String::new();
    for c in f.chars() {
        match c {
            '(' | '[' | '{' => {
                if depth == 0 {
                    cur.clear();
                }
                depth += 1;
            }
            ')' | ']' | '}' => {
                if depth > 0 {
                    depth -= 1;
                    if depth == 0 {
                        segments.push(cur.clone());
                        cur.clear();
                    }
                }
            }
            _ => {
                if depth > 0 {
                    cur.push(c);
                }
            }
        }
    }
    if let Some(idx) = f.rfind(" - ") {
        segments.push(f[idx + 3..].to_string());
    }
    let mut found: Vec<&str> = Vec::new();
    for seg in &segments {
        let mut seg_found: Vec<&str> = Vec::new();
        for (marker, label) in VERSION_MARKERS {
            if contains_word(seg, marker) && !seg_found.contains(label) {
                // Skip the generic "Mix"/"Version"/"Edit" if a more specific label already matched.
                let generic = matches!(*label, "Mix" | "Version" | "Edit");
                if generic && !seg_found.is_empty() {
                    continue;
                }
                seg_found.push(label);
            }
        }
        for l in seg_found {
            if !found.contains(&l) {
                found.push(l);
            }
        }
    }
    if found.is_empty() {
        return None;
    }
    found.sort_unstable();
    Some(found.join(", "))
}

/// Clean/explicit hint from title text only. None = unknown.
pub fn detect_clean_explicit(text: &str) -> Option<&'static str> {
    match detect_version_labels(text) {
        Some(l) if l.contains("Clean") => Some("clean"),
        Some(l) if l.contains("Explicit") => Some("explicit"),
        _ => None,
    }
}

/// A normalised "work key" for possible-duplicate matching: folded artist +
/// title with bracketed parts and featured-artist suffixes removed.
/// Two tracks sharing a work key are *candidates* only.
pub fn base_title(title: &str) -> String {
    let f = fold(title);
    let mut out = String::new();
    let mut depth = 0usize;
    for c in f.chars() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth = depth.saturating_sub(1),
            _ if depth == 0 => out.push(c),
            _ => {}
        }
    }
    let out = match out.find(" - ") {
        Some(i) => out[..i].to_string(),
        None => out,
    };
    let out = strip_feat(&out);
    normalise_ws(&out)
}

pub fn base_artist(artist: &str) -> String {
    let f = fold(artist);
    let f = strip_feat(&f);
    // Use the first credited artist only.
    let first = f
        .split([',', '&', ';', '/'])
        .next()
        .unwrap_or("")
        .split(" x ")
        .next()
        .unwrap_or("")
        .split(" and ")
        .next()
        .unwrap_or("");
    normalise_ws(first)
}

fn strip_feat(s: &str) -> String {
    for pat in [" feat. ", " feat ", " ft. ", " ft ", " featuring "] {
        if let Some(i) = s.find(pat) {
            return s[..i].to_string();
        }
    }
    s.to_string()
}

fn normalise_ws(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Escape a user string for use as a LIKE pattern with ESCAPE '\'.
pub fn like_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        if c == '\\' || c == '%' || c == '_' {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn folds_case_and_accents() {
        assert_eq!(fold("Beyoncé"), "beyonce");
        assert_eq!(fold("SIGUR RÓS"), "sigur ros");
    }

    #[test]
    fn detects_versions_in_brackets_only() {
        assert_eq!(detect_version_labels("Live Your Life"), None);
        assert_eq!(detect_version_labels("Intro to Love"), None);
        assert_eq!(
            detect_version_labels("Song (Live at Wembley)").as_deref(),
            Some("Live")
        );
        assert_eq!(
            detect_version_labels("Song (Radio Edit)").as_deref(),
            Some("Radio Edit")
        );
        assert_eq!(
            detect_version_labels("Song (Clean)").as_deref(),
            Some("Clean")
        );
        assert_eq!(
            detect_version_labels("Song - Extended Mix").as_deref(),
            Some("Extended")
        );
        assert_eq!(
            detect_version_labels("Song (Artist Remix)").as_deref(),
            Some("Remix")
        );
        assert_eq!(
            detect_version_labels("Song (Original Mix)").as_deref(),
            Some("Mix")
        );
    }

    #[test]
    fn base_title_strips_versions_and_feat() {
        assert_eq!(base_title("Essence (feat. Tems) [Remix]"), "essence");
        assert_eq!(base_title("Essence ft. Tems"), "essence");
        assert_eq!(base_artist("Wizkid feat. Tems"), "wizkid");
        assert_eq!(base_artist("Wizkid, Tems"), "wizkid");
    }

    #[test]
    fn like_escape_escapes_wildcards() {
        assert_eq!(like_escape("100%_a\\b"), "100\\%\\_a\\\\b");
    }
}
