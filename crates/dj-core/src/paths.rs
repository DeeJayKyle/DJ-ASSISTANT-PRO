//! Path handling. Paths are stored as given; a separate normalised key is
//! used for identity so Windows case differences and Unicode normalisation
//! forms do not create phantom duplicates.
use std::path::Path;
use unicode_normalization::UnicodeNormalization;

/// Whether the platform file system should be treated as case-insensitive.
pub const CASE_INSENSITIVE: bool = cfg!(windows) || cfg!(target_os = "macos");

pub fn path_key_with(path: &str, case_insensitive: bool) -> String {
    let mut s: String = path.nfc().collect();
    if cfg!(windows) || case_insensitive {
        s = s.replace('/', "\\");
    }
    // Trim a trailing separator (but keep roots like "C:\").
    while (s.ends_with('\\') || s.ends_with('/')) && s.len() > 3 {
        s.pop();
    }
    if case_insensitive {
        s = s.to_lowercase();
    }
    s
}

pub fn path_key(path: &Path) -> Option<String> {
    path.to_str().map(|p| path_key_with(p, CASE_INSENSITIVE))
}

/// True if `child_key` is the same as or inside `parent_key`.
pub fn key_is_within(child_key: &str, parent_key: &str) -> bool {
    if child_key == parent_key {
        return true;
    }
    if !child_key.starts_with(parent_key) {
        return false;
    }
    let rest = &child_key[parent_key.len()..];
    rest.starts_with('\\')
        || rest.starts_with('/')
        || parent_key.ends_with('\\')
        || parent_key.ends_with('/')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_style_keys_are_case_insensitive() {
        assert_eq!(
            path_key_with("D:\\Music\\Afro\\Track.MP3", true),
            path_key_with("d:/music/afro/track.mp3", true)
        );
    }

    #[test]
    fn unicode_forms_are_normalised() {
        let nfc = "Caf\u{e9}.mp3";
        let nfd = "Cafe\u{301}.mp3";
        assert_eq!(path_key_with(nfc, false), path_key_with(nfd, false));
    }

    #[test]
    fn within_checks_boundaries() {
        assert!(key_is_within("/music/a/b.mp3", "/music/a"));
        assert!(!key_is_within("/music/ab/b.mp3", "/music/a"));
    }
}
