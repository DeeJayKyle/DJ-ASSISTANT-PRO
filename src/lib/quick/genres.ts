/**
 * Genres DJs sort by, grouped into families ("Group into families" turns Tech House + Deep House
 * into House). Tags are matched to these; without tags or AI, a BPM/energy guess is offered and
 * clearly marked as a guess.
 */
export const FAMILIES: Record<string, string[]> = {
  House: ['House', 'Deep House', 'Tech House', 'Afro House', 'Progressive House', 'Melodic House', 'Organic House', 'Funky House', 'Bass House', 'Soulful House', 'Electro House', 'Jackin House', 'Future House', 'Disco House'],
  Techno: ['Techno', 'Peak Time Techno', 'Melodic Techno', 'Hard Techno', 'Minimal', 'Industrial Techno', 'Acid Techno', 'Dub Techno', 'Hypnotic Techno'],
  Trance: ['Trance', 'Progressive Trance', 'Psytrance', 'Uplifting Trance', 'Hard Trance'],
  'Drum & Bass': ['Drum & Bass', 'Liquid Drum & Bass', 'Neurofunk', 'Jungle'],
  'Bass Music': ['Dubstep', 'Bass', 'Riddim', 'Trap', 'Future Bass', 'Breaks', 'UK Garage', 'Grime', 'Bassline'],
  'Disco & Funk': ['Disco', 'Nu Disco', 'Funk', 'Soul', 'Boogie'],
  'Hip-Hop & R&B': ['Hip-Hop', 'R&B', 'Rap', 'Drill'],
  African: ['Afrobeats', 'Amapiano', 'Afro Tech', 'Gqom', 'Kuduro', 'Afropop', 'Bongo Flava', 'Kadongo Kamu'],
  Latin: ['Reggaeton', 'Latin', 'Dembow', 'Salsa', 'Bachata', 'Moombahton'],
  Caribbean: ['Dancehall', 'Reggae', 'Soca', 'Dub'],
  Pop: ['Pop', 'Dance Pop', 'Indie Dance', 'Electropop', 'Synthpop'],
  'Chill & Downtempo': ['Downtempo', 'Chillout', 'Ambient', 'Lo-Fi', 'Electronica', 'Trip-Hop'],
  Rock: ['Rock', 'Indie', 'Alternative', 'Metal', 'Punk'],
  Other: ['Other'],
};

export const GENRES = Object.values(FAMILIES).flat();

const familyOf = new Map<string, string>();
for (const [fam, list] of Object.entries(FAMILIES)) for (const g of list) familyOf.set(g.toLowerCase(), fam);

export const family = (genre: string) => familyOf.get(genre.toLowerCase()) ?? 'Other';

const ALIASES: [RegExp, string][] = [
  [/peak\s*time|driving/i, 'Peak Time Techno'],
  [/melodic\s*(house\s*&\s*)?techno/i, 'Melodic Techno'],
  [/hard\s*techno/i, 'Hard Techno'],
  [/tech\s*-?\s*house/i, 'Tech House'],
  [/deep\s*-?\s*house/i, 'Deep House'],
  [/afro\s*-?\s*house/i, 'Afro House'],
  [/afro\s*-?\s*tech/i, 'Afro Tech'],
  [/amapiano/i, 'Amapiano'],
  [/afro\s*-?\s*beats?|naija/i, 'Afrobeats'],
  [/progressive\s*house/i, 'Progressive House'],
  [/organic/i, 'Organic House'],
  [/melodic\s*house/i, 'Melodic House'],
  [/bass\s*house/i, 'Bass House'],
  [/funky\s*house|disco\s*house/i, 'Funky House'],
  [/soulful/i, 'Soulful House'],
  [/psy/i, 'Psytrance'],
  [/trance/i, 'Trance'],
  [/drum\s*(&|and|n|'n')\s*bass|dnb|d&b/i, 'Drum & Bass'],
  [/jungle/i, 'Jungle'],
  [/dubstep/i, 'Dubstep'],
  [/uk\s*garage|ukg|2[- ]?step/i, 'UK Garage'],
  [/breaks?\b|breakbeat/i, 'Breaks'],
  [/nu[- ]?disco/i, 'Nu Disco'],
  [/disco/i, 'Disco'],
  [/funk/i, 'Funk'],
  [/hip[- ]?hop|rap\b/i, 'Hip-Hop'],
  [/r\s*&\s*b|rnb/i, 'R&B'],
  [/reggaeton|dembow/i, 'Reggaeton'],
  [/dancehall/i, 'Dancehall'],
  [/reggae/i, 'Reggae'],
  [/soca/i, 'Soca'],
  [/minimal/i, 'Minimal'],
  [/techno/i, 'Techno'],
  [/house/i, 'House'],
  [/down\s*tempo|chill|lo-?fi/i, 'Downtempo'],
  [/ambient/i, 'Ambient'],
  [/electronica|electronic/i, 'Electronica'],
  [/dance\s*pop|pop/i, 'Pop'],
  [/indie\s*dance/i, 'Indie Dance'],
  [/rock|metal|punk/i, 'Rock'],
];

/** Maps any genre text (tags, AI labels like "Electronic---Tech House") to one of GENRES, or null. */
export function normaliseGenre(text?: string | null): string | null {
  if (!text) return null;
  const t = text.replace(/---/g, ' ').trim();
  const exact = GENRES.find((g) => g.toLowerCase() === t.toLowerCase());
  if (exact) return exact;
  for (const [re, g] of ALIASES) if (re.test(t)) return g;
  return null;
}

/** A labelled guess from tempo and energy, for tracks without a genre tag. */
export function guessGenre(bpm: number, energy: number): string {
  if (!bpm) return 'Other';
  if (bpm >= 160) return 'Drum & Bass';
  if (bpm >= 136) return energy >= 7 ? 'Hard Techno' : 'Trance';
  if (bpm >= 126) return energy >= 6 ? 'Peak Time Techno' : 'Melodic Techno';
  if (bpm >= 115) return energy <= 4 ? 'Deep House' : energy >= 7 ? 'Tech House' : 'House';
  if (bpm >= 108) return 'Amapiano';
  if (bpm >= 95) return energy >= 6 ? 'Afrobeats' : 'Downtempo';
  if (bpm >= 85) return 'Hip-Hop';
  return 'Downtempo';
}
