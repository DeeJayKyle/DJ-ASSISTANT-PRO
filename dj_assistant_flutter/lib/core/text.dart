import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Accent- and case-insensitive form used for search and matching, identical to
/// 1.x `text::fold`: Unicode NFD, combining marks removed, lower-cased.
/// `fold("Beyoncé") == "beyonce"`.
String fold(String s) {
  final d = unorm.nfd(s);
  final out = StringBuffer();
  for (final r in d.runes) {
    if (_isCombiningMark(r)) continue;
    out.write(String.fromCharCode(r).toLowerCase());
  }
  return out.toString();
}

bool _isCombiningMark(int r) =>
    (r >= 0x0300 && r <= 0x036F) ||
    (r >= 0x1AB0 && r <= 0x1AFF) ||
    (r >= 0x1DC0 && r <= 0x1DFF) ||
    (r >= 0x20D0 && r <= 0x20FF) ||
    (r >= 0xFE20 && r <= 0xFE2F);

/// Escapes `\`, `%` and `_` for `LIKE … ESCAPE '\'` (same as 1.x `like_escape`).
String likeEscape(String s) =>
    s.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}');

/// Version labels that suggest an intentional alternate version rather than a
/// duplicate (same table and order as 1.x `VERSION_MARKERS`).
const versionMarkers = <(String, String)>[
  ('extended mix', 'Extended'),
  ('extended version', 'Extended'),
  ('extended', 'Extended'),
  ('radio edit', 'Radio Edit'),
  ('radio version', 'Radio Edit'),
  ('club mix', 'Club Mix'),
  ('dub mix', 'Dub'),
  ('dub', 'Dub'),
  ('remix', 'Remix'),
  ('rmx', 'Remix'),
  ('bootleg', 'Bootleg'),
  ('mashup', 'Mashup'),
  ('re-edit', 'Edit'),
  ('edit', 'Edit'),
  ('live', 'Live'),
  ('acoustic', 'Acoustic'),
  ('instrumental', 'Instrumental'),
  ('acapella', 'Acapella'),
  ('a cappella', 'Acapella'),
  ('intro', 'Intro'),
  ('outro', 'Outro'),
  ('clean', 'Clean'),
  ('dirty', 'Explicit'),
  ('explicit', 'Explicit'),
  ('vip', 'VIP'),
  ('remaster', 'Remaster'),
  ('remastered', 'Remaster'),
  ('reprise', 'Reprise'),
  ('version', 'Version'),
  ('mix', 'Mix'),
];

final _alnum = RegExp(r'[\p{L}\p{N}]', unicode: true);
bool _isAlnum(String c) => _alnum.hasMatch(c);

bool _containsWord(String hay, String needle) {
  var start = 0;
  while (start < hay.length) {
    final abs = hay.indexOf(needle, start);
    if (abs < 0) break;
    final end = abs + needle.length;
    final beforeOk = abs == 0 || !_isAlnum(hay[abs - 1]);
    final afterOk = end >= hay.length || !_isAlnum(hay[end]);
    if (beforeOk && afterOk) return true;
    start = abs + (needle.isEmpty ? 1 : needle.length);
  }
  return false;
}

/// Version labels found in brackets or after the last " - " of [text]: a sorted,
/// comma-separated list, or null. A hint from text, not proof (1.x
/// `detect_version_labels`).
String? detectVersionLabels(String text) {
  final f = fold(text);
  final segments = <String>[];
  var depth = 0;
  final cur = StringBuffer();
  for (final r in f.runes) {
    final c = String.fromCharCode(r);
    if (c == '(' || c == '[' || c == '{') {
      if (depth == 0) cur.clear();
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth > 0) {
        depth--;
        if (depth == 0) {
          segments.add(cur.toString());
          cur.clear();
        }
      }
    } else if (depth > 0) {
      cur.write(c);
    }
  }
  final dash = f.lastIndexOf(' - ');
  if (dash >= 0) segments.add(f.substring(dash + 3));
  final found = <String>[];
  for (final seg in segments) {
    final segFound = <String>[];
    for (final (marker, label) in versionMarkers) {
      if (_containsWord(seg, marker) && !segFound.contains(label)) {
        final generic = label == 'Mix' || label == 'Version' || label == 'Edit';
        if (generic && segFound.isNotEmpty) continue;
        segFound.add(label);
      }
    }
    for (final l in segFound) {
      if (!found.contains(l)) found.add(l);
    }
  }
  if (found.isEmpty) return null;
  found.sort();
  return found.join(', ');
}

/// "clean", "explicit" or null (unknown), from title text only.
String? detectCleanExplicit(String text) {
  final l = detectVersionLabels(text);
  if (l == null) return null;
  if (l.contains('Clean')) return 'clean';
  if (l.contains('Explicit')) return 'explicit';
  return null;
}

/// Folded title without bracketed parts, " - " suffixes and featured artists.
String baseTitle(String title) {
  final f = fold(title);
  final out = StringBuffer();
  var depth = 0;
  for (final r in f.runes) {
    final c = String.fromCharCode(r);
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth = depth > 0 ? depth - 1 : 0;
    } else if (depth == 0) {
      out.write(c);
    }
  }
  var s = out.toString();
  final i = s.indexOf(' - ');
  if (i >= 0) s = s.substring(0, i);
  return _normaliseWs(_stripFeat(s));
}

/// Folded first credited artist, without featured artists.
String baseArtist(String artist) {
  final f = _stripFeat(fold(artist));
  final first = f
      .split(RegExp('[,&;/]'))
      .first
      .split(' x ')
      .first
      .split(' and ')
      .first;
  return _normaliseWs(first);
}

String _stripFeat(String s) {
  for (final pat in [' feat. ', ' feat ', ' ft. ', ' ft ', ' featuring ']) {
    final i = s.indexOf(pat);
    if (i >= 0) return s.substring(0, i);
  }
  return s;
}

String _normaliseWs(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    b.write(_isAlnum(c) ? c : ' ');
  }
  return b
      .toString()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .join(' ');
}
