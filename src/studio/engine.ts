import { planParts, mergeParts, type Stems, type StemName } from './audio/stems';
import type { ChordSegment } from './audio/chords';
import type { Project, Source } from './remix';
import workletUrl from './deck.worklet.ts?worker&url';

/**
 * The studio engine on the UI thread: decodes songs, runs separation in parallel workers, keeps
 * results per song, and creates realtime decks. One engine per app.
 */
export interface SongRef { id: string; title: string; artist?: string | null; bpm?: number | null; key?: string | null; durationSec?: number | null }
export interface Analysis { bpm: number; firstBeat: number; key: { tonic: number; mode: 'major' | 'minor'; short: string; camelot: string }; chords: ChordSegment[] }
export interface Loaded { song: SongRef; sampleRate: number; mix: Float32Array[]; analysis?: Analysis; stems?: Stems }

type Pending = { resolve: (v: any) => void; reject: (e: Error) => void; progress?: (f: number) => void };

class Pool {
  workers: Worker[] = [];
  private pending = new Map<number, Pending>();
  private seq = 0;
  constructor(size: number) {
    for (let i = 0; i < size; i++) {
      const w = new Worker(new URL('./studio.worker.ts', import.meta.url), { type: 'module' });
      w.onmessage = (e) => {
        const { id, result, error, progress } = e.data;
        const p = this.pending.get(id);
        if (!p) return;
        if (progress != null) { p.progress?.(progress); return; }
        this.pending.delete(id);
        if (error) p.reject(new Error(error)); else p.resolve(result);
      };
      this.workers.push(w);
    }
  }
  run<T>(worker: number, msg: Record<string, unknown>, transfer: Transferable[] = [], progress?: (f: number) => void): Promise<T> {
    const id = ++this.seq;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve, reject, progress });
      this.workers[worker % this.workers.length].postMessage({ ...msg, id }, transfer);
    });
  }
}

export class StudioEngine {
  ctx: AudioContext;
  private pool: Pool;
  songs = new Map<string, Loaded>();
  static KEEP = 8;
  private workletReady: Promise<void> | null = null;

  constructor() {
    this.ctx = new AudioContext({ latencyHint: 'interactive' });
    const cores = Math.max(2, Math.min(6, (navigator.hardwareConcurrency || 4) - 1));
    this.pool = new Pool(cores);
  }

  get workers() { return this.pool.workers.length; }

  async resume() { if (this.ctx.state !== 'running') await this.ctx.resume().catch(() => {}); }

  /** Decodes a song from its URL (cached). */
  async load(song: SongRef, url: string): Promise<Loaded> {
    const hit = this.songs.get(song.id);
    // most-recently used last, so the oldest is evicted first
    if (hit) { this.songs.delete(song.id); this.songs.set(song.id, hit); return hit; }
    const res = await fetch(url);
    if (!res.ok) throw new Error('Could not read the file');
    const buf = await res.arrayBuffer();
    let audio: AudioBuffer;
    try { audio = await this.ctx.decodeAudioData(buf); } catch { throw new Error('This file can’t be decoded (AIFF and some codecs aren’t supported here).'); }
    if (audio.duration > 15 * 60) throw new Error('Songs longer than 15 minutes aren’t supported here.');
    const mix = [audio.getChannelData(0).slice(), (audio.numberOfChannels > 1 ? audio.getChannelData(1) : audio.getChannelData(0)).slice()];
    const loaded: Loaded = { song, sampleRate: audio.sampleRate, mix };
    this.songs.set(song.id, loaded);
    // decoded audio and stems are large: keep only the most recent songs in memory
    while (this.songs.size > StudioEngine.KEEP) this.songs.delete(this.songs.keys().next().value as string);
    return loaded;
  }

  async analyse(l: Loaded): Promise<Analysis> {
    if (l.analysis) return l.analysis;
    const m = new Float32Array(l.mix[0].length);
    for (let i = 0; i < m.length; i++) m[i] = (l.mix[0][i] + l.mix[1][i]) / 2;
    l.analysis = await this.pool.run<Analysis>(0, { type: 'analyse', mono: m, sampleRate: l.sampleRate, bpm: l.song.bpm ?? undefined }, [m.buffer]);
    return l.analysis;
  }

  /** Four stems, using every worker. */
  async separate(l: Loaded, onProgress?: (f: number) => void): Promise<Stems> {
    if (l.stems) return l.stems;
    const len = l.mix[0].length;
    const plans = planParts(len, this.pool.workers.length);
    const prog = plans.map(() => 0);
    const parts = await Promise.all(plans.map((p, i) => {
      const ch = [l.mix[0].slice(p.inStart, p.inEnd), l.mix[1].slice(p.inStart, p.inEnd)];
      return this.pool.run<any>(i, { type: 'separatePart', channels: ch, inStart: p.inStart, len, sampleRate: l.sampleRate, f0: p.f0, f1: p.f1 }, ch.map((c) => c.buffer), (f) => {
        prog[i] = f;
        onProgress?.(prog.reduce((a, b) => a + b, 0) / prog.length);
      });
    }));
    l.stems = mergeParts(parts, len);
    return l.stems;
  }

  async midi(l: Loaded, which: (StemName | 'chords')[]): Promise<{ bytes: Uint8Array; counts: { name: string; notes: number }[] }> {
    const stems = await this.separate(l);
    const a = await this.analyse(l);
    const monoOf = (s: StemName) => { const [L, R] = stems[s]; const m = new Float32Array(L.length); for (let i = 0; i < m.length; i++) m[i] = (L[i] + R[i]) / 2; return m; };
    const msg: Record<string, unknown> = { type: 'midi', sampleRate: l.sampleRate, bpm: a.bpm };
    const tr: Transferable[] = [];
    for (const s of ['bass', 'melodies', 'vocals', 'drums'] as StemName[]) if (which.includes(s)) { const m = monoOf(s); msg[s] = m; tr.push(m.buffer); }
    if (which.includes('chords')) msg.chords = a.chords;
    return this.pool.run(1, msg, tr);
  }

  // ---- remix (sources live in one worker) ----
  private remixSources = new Set<string>();
  async remixSource(l: Loaded, withStems: boolean): Promise<Source> {
    const a = await this.analyse(l);
    const stems = withStems ? await this.separate(l) : undefined;
    const src: Source = {
      id: l.song.id, name: l.song.title, sampleRate: l.sampleRate, bpm: a.bpm, firstBeat: a.firstBeat, key: a.key, durationSec: l.mix[0].length / l.sampleRate,
      layers: { mix: l.mix.map((c) => c.slice()), ...(stems ? Object.fromEntries(Object.entries(stems).map(([k, v]) => [k, v.map((c) => c.slice())])) : {}) },
    };
    const bufs = Object.values(src.layers).flatMap((ch) => ch!.map((c) => c.buffer));
    await this.pool.run(this.pool.workers.length - 1, { type: 'addSource', source: src }, bufs);
    this.remixSources.add(src.id);
    return { ...src, layers: Object.fromEntries(Object.keys(src.layers).map((k) => [k, []])) as Source['layers'] };
  }
  hasRemixSource(id: string) { return this.remixSources.has(id); }

  render(project: Project, withTracks = false): Promise<{ mix: Float32Array[]; tracks: [string, Float32Array[]][] }> {
    return this.pool.run(this.pool.workers.length - 1, { type: 'render', project, sampleRate: this.ctx.sampleRate, withTracks });
  }

  // ---- realtime decks ----
  async deckNode(): Promise<AudioWorkletNode> {
    this.workletReady ??= this.ctx.audioWorklet.addModule(workletUrl);
    await this.workletReady;
    return new AudioWorkletNode(this.ctx, 'studio-deck', { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [2] });
  }

  toBuffer(ch: Float32Array[], sampleRate: number) {
    const b = this.ctx.createBuffer(2, ch[0].length, sampleRate);
    b.copyToChannel(ch[0] as Float32Array<ArrayBuffer>, 0);
    b.copyToChannel((ch[1] ?? ch[0]) as Float32Array<ArrayBuffer>, 1);
    return b;
  }
}

let engine: StudioEngine | null = null;
export const getEngine = () => (engine ??= new StudioEngine());
