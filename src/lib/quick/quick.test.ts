import { describe, it, expect } from 'vitest';
import { cleanName, parseFileName, formatName, safeFileName, needsCleanup, smartCase } from './names';
import { normaliseGenre, family, guessGenre, GENRES } from './genres';
import { warmupToPeak, byAscendingBpm, byGenre, parseSortRequest, applySort, setCost, assignRoles, type SetTrack } from './setlist';

describe('name cleanup', () => {
  it('cleans promo-pool junk', () => {
    expect(parseFileName('01_-_DJ_kozi-Sunset_Drive_(Original_Mix)_[FREE DL]_www.promo.net.mp3')).toEqual({ artist: 'DJ Kozi', title: 'Sunset Drive', mix: 'Original Mix' });
  });
  it('drops bitrates and keeps the mix name', () => {
    expect(parseFileName('Artist - Afro Pulse (Extended Mix) 320kbps.mp3')).toEqual({ artist: 'Artist', title: 'Afro Pulse', mix: 'Extended Mix' });
  });
  it('turns underscores into words', () => {
    expect(parseFileName('deep_house_groove__clean_.mp3')).toEqual({ artist: '', title: 'Deep House Groove', mix: 'Clean' });
  });
  it('prefers real tags over a placeholder file name', () => {
    expect(cleanName('track02 final FINAL v3.mp3', { title: 'Night Shift', artist: 'Mara Vey' })).toEqual({ artist: 'Mara Vey', title: 'Night Shift', mix: '' });
  });
  it('makes a readable name from a placeholder with no tags', () => {
    expect(cleanName('track02 final FINAL v3.mp3').title).toBe('Track 02');
  });
  it('handles remixes, feat. and mixed case', () => {
    expect(parseFileName('deadmau5 feat. Kaskade - I Remember [Joe Smith Remix].flac')).toEqual({ artist: 'deadmau5 feat. Kaskade', title: 'I Remember', mix: 'Joe Smith Remix' });
    expect(parseFileName('A1 BLACK COFFEE - SUPERMAN.wav')).toEqual({ artist: 'Black Coffee', title: 'Superman', mix: '' });
  });
  it('formats either way round', () => {
    const n = { artist: 'DJ Kozi', title: 'Sunset Drive', mix: 'Original Mix' };
    expect(formatName(n)).toBe('DJ Kozi - Sunset Drive (Original Mix)');
    expect(formatName(n, 'title-artist')).toBe('Sunset Drive - DJ Kozi (Original Mix)');
    expect(formatName({ artist: '', title: 'Groove', mix: '' })).toBe('Groove');
  });
  it('makes names safe for every OS', () => {
    expect(safeFileName('AC/DC: Back <In> Black?')).toBe('AC DC Back In Black');
    expect(safeFileName('con')).toBe('con_');
    expect(safeFileName('...')).toBe('Untitled');
  });
  it('knows which files still need cleanup', () => {
    expect(needsCleanup('DJ Kozi - Sunset Drive (Original Mix).mp3', { artist: 'DJ Kozi', title: 'Sunset Drive', mix: 'Original Mix' })).toBe(false);
    expect(needsCleanup('dj_kozi-sunset.mp3', { artist: 'DJ Kozi', title: 'Sunset', mix: '' })).toBe(true);
  });
  it('keeps acronyms and small words right', () => {
    expect(smartCase('mc solaar and the uk crew')).toBe('MC Solaar and the UK Crew');
  });
});

describe('genres', () => {
  it('maps tag text and AI labels to DJ genres', () => {
    expect(normaliseGenre('Electronic---Tech House')).toBe('Tech House');
    expect(normaliseGenre('Techno (Peak Time / Driving)')).toBe('Peak Time Techno');
    expect(normaliseGenre('drum n bass')).toBe('Drum & Bass');
    expect(normaliseGenre('Afro-House')).toBe('Afro House');
    expect(normaliseGenre('amapiano')).toBe('Amapiano');
    expect(normaliseGenre('')).toBeNull();
    expect(normaliseGenre('Polka')).toBeNull();
  });
  it('groups subgenres into families', () => {
    expect(family('Tech House')).toBe('House');
    expect(family('Deep House')).toBe('House');
    expect(family('Melodic Techno')).toBe('Techno');
    expect(family('Unknown')).toBe('Other');
  });
  it('every guess is a known genre', () => {
    for (const bpm of [0, 70, 90, 100, 110, 120, 128, 140, 174]) for (const e of [2, 5, 8]) expect(GENRES).toContain(guessGenre(bpm, e));
  });
});

const t = (id: string, bpm: number, camelot: string, energy: number, genre = 'House'): SetTrack => ({ id, bpm, camelot, energy, genre });

describe('set building', () => {
  const lib = [t('peak', 130, '9A', 9, 'Peak Time Techno'), t('warm', 118, '8A', 2, 'Deep House'), t('mid', 124, '8A', 5), t('mid2', 125, '9A', 6, 'Tech House'), t('late', 128, '10A', 8, 'Techno')];
  it('warmup → peak starts calm and ends at the peak, mixing harmonically', () => {
    const order = warmupToPeak(lib).map((x) => x.id);
    expect(order[0]).toBe('warm');
    expect(order.at(-1)).toBe('peak');
    expect(setCost(warmupToPeak(lib))).toBeLessThan(setCost([lib[0], lib[1], lib[4], lib[2], lib[3]]));
  });
  it('ascending BPM and genre grouping', () => {
    expect(byAscendingBpm(lib).map((x) => x.bpm)).toEqual([118, 124, 125, 128, 130]);
    expect(byGenre(lib).map((x) => x.genre)).toEqual(['Deep House', 'House', 'Tech House', 'Peak Time Techno', 'Techno']);
  });
  it('understands plain-words sort requests', () => {
    expect(parseSortRequest('Build a warmup → peak set')).toBe('warmup-peak');
    expect(parseSortRequest('Sort by BPM ascending')).toBe('ascending-bpm');
    expect(parseSortRequest('fastest first, by tempo descending')).toBe('descending-bpm');
    expect(parseSortRequest('group by genre')).toBe('genre');
    expect(parseSortRequest('harmonic order by key')).toBe('key');
    expect(parseSortRequest('make me a sandwich')).toBeNull();
    expect(applySort('energy-down', lib)[0].id).toBe('peak');
  });
  it('spreads energy roles across a library', () => {
    const roles = assignRoles(lib.map((x) => ({ id: x.id, energy: x.energy, bpm: x.bpm })));
    expect(roles.get('warm')).toBe('Warm Up');
    expect(roles.get('peak')).toBe('Peak Time');
    expect(new Set(roles.values()).size).toBe(3);
  });
});

import { buildLayout, type LayoutTrack } from './layout';
describe('export layouts', () => {
  const n = (artist: string, title: string, mix = '') => ({ artist, title, mix });
  const tracks: LayoutTrack[] = [
    { id: 1, name: n('DJ Kozi', 'Sunset Drive', 'Original Mix'), genre: 'Deep House', bpm: 124 },
    { id: 2, name: n('Mara Vey', 'Night Shift'), genre: 'Peak Time Techno', bpm: 132 },
    { id: 3, name: n('', 'Groove'), genre: 'Tech House', bpm: 120 },
  ];
  it('clean: everything in one folder with a playlist', () => {
    const l = buildLayout(tracks, { kind: 'clean' }, 'artist-title');
    expect(l.items.map((i) => i.name)).toEqual(['DJ Kozi - Sunset Drive (Original Mix)', 'Mara Vey - Night Shift', 'Groove']);
    expect(l.playlists).toEqual([{ name: 'All tracks', path: 'All tracks.m3u8', track_ids: [1, 2, 3] }]);
  });
  it('playlist: play order, numbered, title first when asked', () => {
    const l = buildLayout(tracks, { kind: 'playlist', name: 'Friday: Set', order: [3, 1, 2, 99], numbered: true }, 'title-artist');
    expect(l.items.map((i) => `${i.folder}/${i.name}`)).toEqual(['Friday Set/01 Groove', 'Friday Set/02 Sunset Drive - DJ Kozi (Original Mix)', 'Friday Set/03 Night Shift - Mara Vey']);
    expect(l.playlists[0]).toEqual({ name: 'Friday: Set', path: 'Friday Set/Friday Set.m3u8', track_ids: [3, 1, 2] });
  });
  it('genres: a folder per genre or family, sorted by BPM', () => {
    expect(buildLayout(tracks, { kind: 'genres', families: false }, 'artist-title').playlists.map((p) => p.path)).toEqual(['Playlists/Deep House.m3u8', 'Playlists/Peak Time Techno.m3u8', 'Playlists/Tech House.m3u8']);
    const fam = buildLayout(tracks, { kind: 'genres', families: true }, 'artist-title');
    expect(fam.playlists.map((p) => [p.name, p.track_ids])).toEqual([['House', [3, 1]], ['Techno', [2]]]);
    expect(fam.items[0]).toEqual({ track_id: 3, folder: 'House', name: 'Groove' });
  });
  it('folders: main/sub, the rest unsorted, each track once', () => {
    const l = buildLayout(tracks, { kind: 'folders', bins: [{ main: 'Friday Night', sub: 'Warm Up', ids: [3, 1] }, { main: 'Friday Night', sub: 'Peak Time', ids: [1] }, { main: 'Empty', sub: '', ids: [] }] }, 'artist-title');
    expect(l.items.map((i) => [i.track_id, i.folder])).toEqual([[3, 'Friday Night/Warm Up'], [1, 'Friday Night/Warm Up'], [2, 'Unsorted']]);
    expect(l.playlists.map((p) => p.path)).toEqual(['Playlists/Friday Night - Warm Up.m3u8', 'Playlists/Unsorted.m3u8']);
  });
});
