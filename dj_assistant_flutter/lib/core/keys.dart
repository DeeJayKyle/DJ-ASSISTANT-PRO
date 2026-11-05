/// Musical keys and the Camelot wheel, identical to 1.x `analysis.rs`.
library;

const _notes = [
  'C',
  'C#',
  'D',
  'Eb',
  'E',
  'F',
  'F#',
  'G',
  'Ab',
  'A',
  'Bb',
  'B',
];
const _camelotMajor = [
  '8B',
  '3B',
  '10B',
  '5B',
  '12B',
  '7B',
  '2B',
  '9B',
  '4B',
  '11B',
  '6B',
  '1B',
];
const _camelotMinor = [
  '5A',
  '12A',
  '7A',
  '2A',
  '9A',
  '4A',
  '11A',
  '6A',
  '1A',
  '8A',
  '3A',
  '10A',
];
const _aliases = {
  'Db': 'C#',
  'D#': 'Eb',
  'Gb': 'F#',
  'G#': 'Ab',
  'A#': 'Bb',
  'Cb': 'B',
  'Fb': 'E',
  'E#': 'F',
  'B#': 'C',
};

/// "A minor", "C major", "F#m" or "C" -> Camelot code.
String? camelotFor(String key) {
  final k = key.trim();
  String root;
  bool minor;
  if (k.endsWith(' minor')) {
    root = k.substring(0, k.length - 6);
    minor = true;
  } else if (k.endsWith(' major')) {
    root = k.substring(0, k.length - 6);
    minor = false;
  } else if (k.endsWith('m')) {
    root = k.substring(0, k.length - 1);
    minor = true;
  } else {
    root = k;
    minor = false;
  }
  final i = _notes.indexOf(_aliases[root] ?? root);
  if (i < 0) return null;
  return minor ? _camelotMinor[i] : _camelotMajor[i];
}

/// "8A" -> (8, minor). Accepts "08a".
(int, bool)? parseCamelot(String s) {
  final u = s.trim().toUpperCase();
  if (u.length < 2) return null;
  final n = int.tryParse(u.substring(0, u.length - 1));
  final l = u[u.length - 1];
  if (n == null || n < 1 || n > 12) return null;
  if (l == 'A') return (n, true);
  if (l == 'B') return (n, false);
  return null;
}

/// Any common key spelling ("8A", "Am", "A minor", "F♯ min", "Bbmaj", Open Key "1m")
/// -> Camelot code, or null.
String? normalizeKey(String s) {
  final t = s
      .trim()
      .replaceAll('♯', '#')
      .replaceAll('♭', 'b')
      .replaceAll(RegExp(r'\s'), '');
  if (t.isEmpty || t.length > 12) return null;
  final c = parseCamelot(t);
  if (c != null) return '${c.$1}${c.$2 ? 'A' : 'B'}';
  final lower = t.toLowerCase();
  if (lower.length >= 2) {
    final n = int.tryParse(lower.substring(0, lower.length - 1));
    final l = lower[lower.length - 1];
    if (n != null && n >= 1 && n <= 12 && (l == 'm' || l == 'd')) {
      return '${((n + 6) % 12) + 1}${l == 'm' ? 'A' : 'B'}';
    }
  }
  final first = t[0].toUpperCase();
  if (!'ABCDEFG'.contains(first)) return null;
  var rest = t.substring(1);
  var acc = '';
  if (rest.startsWith('#') || rest.startsWith('b')) {
    acc = rest[0];
    rest = rest.substring(1);
  }
  final bool minor;
  switch (rest.toLowerCase()) {
    case 'm' || 'min' || 'minor' || '-':
      minor = true;
    case '' || 'maj' || 'major':
      minor = false;
    default:
      return null;
  }
  return camelotFor('$first$acc ${minor ? 'minor' : 'major'}');
}

const _minorNames = [
  'Abm',
  'Ebm',
  'Bbm',
  'Fm',
  'Cm',
  'Gm',
  'Dm',
  'Am',
  'Em',
  'Bm',
  'F#m',
  'C#m',
];
const _majorNames = [
  'B',
  'F#',
  'Db',
  'Ab',
  'Eb',
  'Bb',
  'F',
  'C',
  'G',
  'D',
  'A',
  'E',
];

/// "8A" -> "Am", "8B" -> "C".
String? musicalName(String camelot) {
  final c = parseCamelot(camelot);
  if (c == null) return null;
  return c.$2 ? _minorNames[c.$1 - 1] : _majorNames[c.$1 - 1];
}

/// Why two keys mix well, or null.
String? camelotCompatible(String a, String b) {
  final ca =
      parseCamelot(a) ??
      (camelotFor(a) == null ? null : parseCamelot(camelotFor(a)!));
  final cb =
      parseCamelot(b) ??
      (camelotFor(b) == null ? null : parseCamelot(camelotFor(b)!));
  if (ca == null || cb == null) return null;
  if (ca == cb) return 'same key';
  if (ca.$1 == cb.$1) return 'relative major/minor';
  if (ca.$2 == cb.$2) {
    final d = (ca.$1 - cb.$1) % 12;
    if (d == 1 || d == 11) return 'adjacent on the Camelot wheel';
  }
  return null;
}
