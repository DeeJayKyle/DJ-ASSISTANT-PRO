/// Genres DJs sort by, grouped into families (1.x `src/lib/quick/genres.ts`).
library;

const genreFamilies = <String, List<String>>{
  'House': [
    'House',
    'Deep House',
    'Tech House',
    'Afro House',
    'Progressive House',
    'Melodic House',
    'Organic House',
    'Funky House',
    'Bass House',
    'Soulful House',
    'Electro House',
    'Jackin House',
    'Future House',
    'Disco House',
  ],
  'Techno': [
    'Techno',
    'Peak Time Techno',
    'Melodic Techno',
    'Hard Techno',
    'Minimal',
    'Industrial Techno',
    'Acid Techno',
    'Dub Techno',
    'Hypnotic Techno',
  ],
  'Trance': [
    'Trance',
    'Progressive Trance',
    'Psytrance',
    'Uplifting Trance',
    'Hard Trance',
  ],
  'Drum & Bass': ['Drum & Bass', 'Liquid Drum & Bass', 'Neurofunk', 'Jungle'],
  'Bass Music': [
    'Dubstep',
    'Bass',
    'Riddim',
    'Trap',
    'Future Bass',
    'Breaks',
    'UK Garage',
    'Grime',
    'Bassline',
  ],
  'Disco & Funk': ['Disco', 'Nu Disco', 'Funk', 'Soul', 'Boogie'],
  'Hip-Hop & R&B': ['Hip-Hop', 'R&B', 'Rap', 'Drill'],
  'African': [
    'Afrobeats',
    'Amapiano',
    'Afro Tech',
    'Gqom',
    'Kuduro',
    'Afropop',
    'Bongo Flava',
    'Kadongo Kamu',
  ],
  'Latin': ['Reggaeton', 'Latin', 'Dembow', 'Salsa', 'Bachata', 'Moombahton'],
  'Caribbean': ['Dancehall', 'Reggae', 'Soca', 'Dub'],
  'Pop': ['Pop', 'Dance Pop', 'Indie Dance', 'Electropop', 'Synthpop'],
  'Chill & Downtempo': [
    'Downtempo',
    'Chillout',
    'Ambient',
    'Lo-Fi',
    'Electronica',
    'Trip-Hop',
  ],
  'Rock': ['Rock', 'Indie', 'Alternative', 'Metal', 'Punk'],
  'Other': ['Other'],
};

final allGenres = [for (final l in genreFamilies.values) ...l];

final _familyOf = <String, String>{
  for (final e in genreFamilies.entries)
    for (final g in e.value) g.toLowerCase(): e.key,
};

String genreFamily(String genre) => _familyOf[genre.toLowerCase()] ?? 'Other';

RegExp _r(String s) => RegExp(s, caseSensitive: false);

final _aliases = <(RegExp, String)>[
  (_r(r'peak\s*time|driving'), 'Peak Time Techno'),
  (_r(r'melodic\s*(house\s*&\s*)?techno'), 'Melodic Techno'),
  (_r(r'hard\s*techno'), 'Hard Techno'),
  (_r(r'tech\s*-?\s*house'), 'Tech House'),
  (_r(r'deep\s*-?\s*house'), 'Deep House'),
  (_r(r'afro\s*-?\s*house'), 'Afro House'),
  (_r(r'afro\s*-?\s*tech'), 'Afro Tech'),
  (_r('amapiano'), 'Amapiano'),
  (_r(r'afro\s*-?\s*beats?|naija'), 'Afrobeats'),
  (_r(r'progressive\s*house'), 'Progressive House'),
  (_r('organic'), 'Organic House'),
  (_r(r'melodic\s*house'), 'Melodic House'),
  (_r(r'bass\s*house'), 'Bass House'),
  (_r(r'funky\s*house|disco\s*house'), 'Funky House'),
  (_r('soulful'), 'Soulful House'),
  (_r('psy'), 'Psytrance'),
  (_r('trance'), 'Trance'),
  (_r(r"drum\s*(&|and|n|'n')\s*bass|dnb|d&b"), 'Drum & Bass'),
  (_r('jungle'), 'Jungle'),
  (_r('dubstep'), 'Dubstep'),
  (_r(r'uk\s*garage|ukg|2[- ]?step'), 'UK Garage'),
  (_r(r'breaks?\b|breakbeat'), 'Breaks'),
  (_r(r'nu[- ]?disco'), 'Nu Disco'),
  (_r('disco'), 'Disco'),
  (_r('funk'), 'Funk'),
  (_r(r'hip[- ]?hop|rap\b'), 'Hip-Hop'),
  (_r(r'r\s*&\s*b|rnb'), 'R&B'),
  (_r('reggaeton|dembow'), 'Reggaeton'),
  (_r('dancehall'), 'Dancehall'),
  (_r('reggae'), 'Reggae'),
  (_r('soca'), 'Soca'),
  (_r('minimal'), 'Minimal'),
  (_r('techno'), 'Techno'),
  (_r('house'), 'House'),
  (_r(r'down\s*tempo|chill|lo-?fi'), 'Downtempo'),
  (_r('ambient'), 'Ambient'),
  (_r('electronica|electronic'), 'Electronica'),
  (_r(r'dance\s*pop|pop'), 'Pop'),
  (_r(r'indie\s*dance'), 'Indie Dance'),
  (_r('rock|metal|punk'), 'Rock'),
];

/// Maps any genre text (tags, AI labels like "Electronic---Tech House") to a known genre, or null.
String? normaliseGenre(String? text) {
  if (text == null || text.isEmpty) return null;
  final t = text.replaceAll('---', ' ').trim();
  for (final g in allGenres) {
    if (g.toLowerCase() == t.toLowerCase()) return g;
  }
  for (final (re, g) in _aliases) {
    if (re.hasMatch(t)) return g;
  }
  return null;
}

/// A labelled guess from tempo and energy, for tracks without a genre tag.
String guessGenre(num bpm, num energy) {
  if (bpm == 0) return 'Other';
  if (bpm >= 160) return 'Drum & Bass';
  if (bpm >= 136) return energy >= 7 ? 'Hard Techno' : 'Trance';
  if (bpm >= 126) return energy >= 6 ? 'Peak Time Techno' : 'Melodic Techno';
  if (bpm >= 115) {
    return energy <= 4 ? 'Deep House' : (energy >= 7 ? 'Tech House' : 'House');
  }
  if (bpm >= 108) return 'Amapiano';
  if (bpm >= 95) return energy >= 6 ? 'Afrobeats' : 'Downtempo';
  if (bpm >= 85) return 'Hip-Hop';
  return 'Downtempo';
}

/// Camelot neighbours that mix well: same code, ±1 on the wheel, and the relative major/minor.
List<String> compatibleCamelot(String code) {
  final m = RegExp(r'^(\d+)([AB])$').firstMatch(code);
  if (m == null) return const [];
  final n = int.parse(m[1]!), l = m[2]!;
  int wrap(int x) => ((x - 1 + 12) % 12) + 1;
  return [
    code,
    '${wrap(n + 1)}$l',
    '${wrap(n - 1)}$l',
    '$n${l == 'A' ? 'B' : 'A'}',
  ];
}
