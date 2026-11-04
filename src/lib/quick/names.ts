/**
 * Turns messy file names ("01_-_DJ_kozi-Sunset_Drive_(Original_Mix)_[FREE DL]_www.promo.net.mp3")
 * into "DJ Kozi - Sunset Drive (Original Mix)". Tags win when they look real; the file name fills
 * the gaps. Everything is deterministic and local; the optional AI pass only refines it.
 */
export interface CleanName {
  artist: string;
  title: string;
  /** e.g. "Original Mix", "Extended Mix", "Joe Remix" */
  mix: string;
}

export type NameFormat = 'artist-title' | 'title-artist';

const UPPER = new Set(['DJ', 'MC', 'VIP', 'UK', 'USA', 'US', 'NYC', 'LA', 'EDM', 'DNB', 'UKG', 'II', 'III', 'IV', 'XL', 'TV', 'AI', 'OG', 'R&B', 'B2B', 'BPM']);
const LOWER = new Set(['a', 'an', 'and', 'as', 'at', 'by', 'for', 'in', 'of', 'on', 'or', 'the', 'to', 'vs', 'feat', 'ft', 'x', 'de', 'la', 'le', 'el', 'y']);
const MIX_WORDS = /\b(clean|dirty|explicit|intro|original|extended|club|radio|dub|vip|instrumental|acapella|a cappella|vocal|remix|rework|edit|bootleg|flip|mix|version|remaster(ed)?|re-?edit|live)\b/i;

/** Noise that download sites and promo pools add to names. */
const JUNK: RegExp[] = [
  /\[(free\s*(dl|download)|out now|premiere|exclusive|promo|hq|hd|official( video| audio)?|lyrics?)[^\]]*\]/gi,
  /\((free\s*(dl|download)|out now|premiere|exclusive|promo|hq|hd|official( video| audio)?|lyrics?)[^)]*\)/gi,
  /\b(free\s*(dl|download)|out now|premiere)\b/gi,
  /\b(www\.)?[a-z0-9-]+\.(com|net|org|io|co|ru|me|fm|info|biz|to|cc)\b/gi,
  /\b\d{2,3}\s?kbps\b/gi,
  /\b(320|256|192|128)k?\b(?=\s*$|\s*\))/gi,
  /\b(final|copy|new|master(ed)?|mp3|wav|flac|aiff?)\b(?=(\s+(final|v\d+|copy|\d+))*\s*$)/gi,
  /\bv\d+\b\s*$/gi,
  /\(\d\)\s*$/g,
];

const tidy = (s: string) => s.replace(/\s+/g, ' ').replace(/\s*([)\]])/g, '$1').replace(/([([])\s*/g, '$1').replace(/^[\s\-–—_.,]+|[\s\-–—_.,]+$/g, '').trim();

/** Title-cases words that are all lower or all upper case; leaves mixed-case words (e.g. "deadmau5", "SebastiAn") alone. */
export function smartCase(s: string) {
  return s.split(/(\s+|(?=[-/&()])|(?<=[-/&(]))/).map((w, i) => {
    if (!w.trim() || /^[-/&()]$/.test(w)) return w;
    const bare = w.replace(/[^A-Za-z&]/g, '');
    if (UPPER.has(bare.toUpperCase())) return w.replace(bare, bare.toUpperCase());
    // Mixed case ("SebastiAn") or letters with digits ("deadmau5") are styled on purpose.
    const styled = (/[a-z]/.test(w) && /[A-Z]/.test(w)) || (/[a-z]/i.test(w) && /\d/.test(w));
    if (styled) return w;
    const low = w.toLowerCase();
    if (i > 0 && LOWER.has(low.replace(/[.]/g, ''))) return low;
    return low.replace(/(^|[^a-z'’])([a-z])/g, (_, p, c) => p + c.toUpperCase());
  }).join('');
}

function stripJunk(s: string) {
  let t = s;
  for (const re of JUNK) t = t.replace(re, ' ');
  return t.replace(/\[\s*\]|\(\s*\)/g, ' ');
}

/** Pulls "(Original Mix)", "[Joe Remix]" or a trailing "Extended Mix" out of a title. */
function splitMix(title: string): [string, string] {
  const bracket = title.match(/[([]([^)\]]+)[)\]]\s*$/);
  if (bracket && MIX_WORDS.test(bracket[1])) return [tidy(title.slice(0, bracket.index)), tidy(bracket[1])];
  const trailing = title.match(/\s[-–]\s([^-–]+(?:mix|edit|remix|dub|rework|version))\s*$/i);
  if (trailing) return [tidy(title.slice(0, trailing.index)), tidy(trailing[1])];
  return [tidy(title), ''];
}

export function parseFileName(fileName: string): CleanName {
  let base = fileName.replace(/\.[a-z0-9]{2,5}$/i, '');
  // "name__clean_" is what "name (clean)" becomes when a site swaps brackets for underscores.
  base = base.replace(/__([a-z0-9][a-z0-9 _-]*?)_$/i, (_, w) => ` (${w.replace(/_/g, ' ')})`);
  base = base.replace(/_-_/g, ' - ').replace(/_/g, ' ');
  base = stripJunk(base);
  // Leading track numbers: "01 ", "01. ", "A1 ", "1-03 "
  base = base.replace(/^\s*(\d{1,3}[\s.\-)_]+|[A-D]\d{1,2}\s+|\d-\d{2}\s+)/, '');
  base = tidy(base);
  // Artist - Title (allowing " - ", " – ", or a bare hyphen between words with spaces on one side)
  let parts = base.split(/\s+[-–—]\s+/);
  if (parts.length === 1) parts = base.split(/\s*[-–—]\s*(?=[A-Za-z])/);
  let artist = '';
  let title = base;
  if (parts.length >= 2) {
    artist = parts[0];
    title = parts.slice(1).join(' - ');
  }
  const [t, mix] = splitMix(title);
  artist = smartCase(tidy(artist));
  title = smartCase(t);
  // Placeholder names ("track02", "audio 3") become a readable "Track 02".
  title = title.replace(/^(track|audio|untitled|song)\s*(\d+)$/i, (_, w, n) => `${w[0].toUpperCase()}${w.slice(1).toLowerCase()} ${n}`);
  return { artist, title, mix: mix ? smartCase(mix) : '' };
}

const looksReal = (s?: string) => !!s && s.trim().length > 0 && !/^(track|audio|untitled)\s*\d*$/i.test(s.trim()) && !/^\d+$/.test(s.trim());

/** Combines tags and the file name: real tags win, the file name fills gaps. */
export function cleanName(fileName: string, tags: { artist?: string; title?: string } = {}): CleanName {
  const fromFile = parseFileName(fileName);
  const tagTitle = looksReal(tags.title) ? tags.title!.trim() : '';
  const tagArtist = looksReal(tags.artist) ? tags.artist!.trim() : '';
  if (!tagTitle) return { ...fromFile, artist: tagArtist ? smartCase(tidy(stripJunk(tagArtist))) : fromFile.artist };
  const [t, mix] = splitMix(tidy(stripJunk(tagTitle)));
  return { artist: tagArtist ? smartCase(tidy(stripJunk(tagArtist))) : fromFile.artist, title: smartCase(t), mix: mix ? smartCase(mix) : fromFile.mix };
}

export function formatName(n: CleanName, format: NameFormat = 'artist-title') {
  const main = !n.artist ? n.title : format === 'artist-title' ? `${n.artist} - ${n.title}` : `${n.title} - ${n.artist}`;
  return n.mix ? `${main} (${n.mix})` : main;
}

/** A name every OS accepts as a file name (no \ / : * ? " < > |, no trailing dots, sane length). */
export function safeFileName(name: string, maxLength = 150) {
  let s = name.replace(/[\\/:*?"<>|\u0000-\u001f]/g, ' ').replace(/\s+/g, ' ').trim().replace(/[. ]+$/, '');
  if (/^(con|prn|aux|nul|com\d|lpt\d)$/i.test(s)) s = `${s}_`;
  if (s.length > maxLength) s = s.slice(0, maxLength).trim();
  return s || 'Untitled';
}

/** Whether a file still needs its name cleaning (its base name differs from the clean one). */
export function needsCleanup(fileName: string, n: CleanName, format: NameFormat = 'artist-title') {
  return fileName.replace(/\.[a-z0-9]{2,5}$/i, '') !== safeFileName(formatName(n, format));
}
