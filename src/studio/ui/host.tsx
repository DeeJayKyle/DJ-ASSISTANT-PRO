import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { getEngine, type SongRef, type StudioEngine } from '../engine';

/** What a host app gives the studio: its songs, their audio, saving files, and optional AI. */
export interface StudioHost {
  appName: string;
  songs(query: string): Promise<SongRef[]>;
  /** Optional: let the user add files (Music Assistant); the DJ app uses its library instead. */
  addSongs?(): Promise<SongRef[]>;
  audioUrl(song: SongRef): string;
  /** Saves one new file; returns where it went, or null if cancelled. */
  saveFile(suggestedName: string, bytes: Uint8Array): Promise<string | null>;
  /** Saves several files into a new folder; returns the folder, or null if cancelled. */
  saveFiles(folderName: string, files: { name: string; bytes: Uint8Array }[]): Promise<string | null>;
  /** Optional AI help: one system + user message, reply text. */
  ai?: (system: string, user: string) => Promise<string>;
  reveal?(path: string): void;
  toast(message: string, error?: boolean): void;
}

interface Ctx { host: StudioHost; engine: StudioEngine; split: Set<string>; markSplit: (id: string) => void }
const StudioCtx = createContext<Ctx | null>(null);
export const useStudio = () => {
  const c = useContext(StudioCtx);
  if (!c) throw new Error('StudioProvider missing');
  return c;
};

export function StudioProvider({ host, children }: { host: StudioHost; children: ReactNode }) {
  const [split, setSplit] = useState<Set<string>>(new Set());
  const engine = getEngine();
  return <StudioCtx.Provider value={{ host, engine, split, markSplit: (id) => setSplit((s) => new Set(s).add(id)) }}>{children}</StudioCtx.Provider>;
}

/** Searchable song list from the host. */
export function SongPicker({ onPick, compact, label = 'Choose a song' }: { onPick: (s: SongRef) => void; compact?: boolean; label?: string }) {
  const { host, split } = useStudio();
  const [q, setQ] = useState('');
  const [list, setList] = useState<SongRef[]>([]);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    let live = true;
    const t = setTimeout(() => { setBusy(true); host.songs(q).then((l) => live && setList(l)).catch(() => {}).finally(() => live && setBusy(false)); }, 150);
    return () => { live = false; clearTimeout(t); };
  }, [q, host]);
  return (
    <div className={`st-picker${compact ? ' compact' : ''}`}>
      <div className="st-row">
        <input className="st-input" placeholder="Search songs" value={q} onChange={(e) => setQ(e.target.value)} aria-label={`${label}: search`} />
        {host.addSongs && <button className="st-btn" onClick={() => host.addSongs!().then((l) => l[0] && onPick(l[0])).catch((e) => host.toast(String(e.message ?? e), true))}>Add files…</button>}
      </div>
      <ul className="st-songs" aria-label={label}>
        {list.map((s) => (
          <li key={s.id}>
            <button className="st-song" onClick={() => onPick(s)}>
              <span className="st-song-title">{s.title}{split.has(s.id) && <span className="st-badge">stems</span>}</span>
              <span className="st-muted st-small">{[s.artist, s.bpm ? `${Math.round(s.bpm)} BPM` : null, s.key].filter(Boolean).join(' · ')}</span>
            </button>
          </li>
        ))}
        {!list.length && <li className="st-muted st-small st-pad">{busy ? 'Loading…' : q ? 'No songs match.' : 'No songs yet.'}</li>}
      </ul>
    </div>
  );
}

/** Waveform overview with a playhead and optional markers; click to seek. */
export function Wave({ peaks, progress, onSeek, markers, height = 56, color }: { peaks: Float32Array | number[]; progress: number; onSeek?: (f: number) => void; markers?: { at: number; label: string }[]; height?: number; color?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const c = ref.current;
    if (!c) return;
    const dpr = window.devicePixelRatio || 1;
    const w = c.clientWidth || 600;
    c.width = w * dpr; c.height = height * dpr;
    const g = c.getContext('2d')!;
    g.scale(dpr, dpr);
    g.clearRect(0, 0, w, height);
    const css = getComputedStyle(c);
    const on = color || css.getPropertyValue('--st-accent').trim() || '#3ee6c4';
    const off = css.getPropertyValue('--st-line-strong').trim() || '#3a4554';
    const n = peaks.length || 1;
    for (let i = 0; i < peaks.length; i++) {
      const x = (i / n) * w, h = Math.max(1, peaks[i] * (height - 6));
      g.fillStyle = i / n < progress ? on : off;
      g.fillRect(x, (height - h) / 2, Math.max(1, w / n - 0.5), h);
    }
    if (markers) {
      g.fillStyle = css.getPropertyValue('--st-muted').trim() || '#9aa6b4';
      g.font = '10px ui-sans-serif, system-ui';
      for (const m of markers) { const x = m.at * w; g.fillRect(x, 0, 1, 6); g.fillText(m.label, x + 2, 9); }
    }
    g.fillStyle = css.getPropertyValue('--st-text').trim() || '#fff';
    g.fillRect(progress * w, 0, 1.5, height);
  }, [peaks, progress, markers, height, color]);
  return <canvas ref={ref} className="st-wave" style={{ height }} onClick={(e) => { const r = e.currentTarget.getBoundingClientRect(); onSeek?.((e.clientX - r.left) / r.width); }} role={onSeek ? 'slider' : 'img'} aria-label="Waveform" aria-valuenow={Math.round(progress * 100)} />;
}

export function Bar({ value, label }: { value: number; label?: string }) {
  return <div className="st-progress" role="progressbar" aria-label={label ?? 'Progress'} aria-valuenow={Math.round(value * 100)} aria-valuemax={100}><i style={{ width: `${Math.round(value * 100)}%` }} /></div>;
}

export const fmtTime = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, '0')}`;
export const errText = (e: unknown) => String((e as Error)?.message ?? e).replace(/^Error invoking remote method '[^']+': (Error: )?/, '');
