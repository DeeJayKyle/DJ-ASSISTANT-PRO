import { useEffect, useMemo, useRef, useState } from 'react';
import { useStudio, SongPicker, Wave, Bar, fmtTime, errText } from './host';
import type { Loaded, SongRef } from '../engine';
import { STEMS, type StemName } from '../audio/stems';
import { overview } from '../audio/wav';
import { keyShift } from '../remix';

interface DeckState {
  song: SongRef | null; loaded: Loaded | null; peaks: Float32Array | null; time: number; playing: boolean;
  tempo: number; // fader, 1 = original
  semis: number; stems: boolean; gains: Record<StemName, number>; volume: number; busy: string | null; progress: number;
}
const fresh = (): DeckState => ({ song: null, loaded: null, peaks: null, time: 0, playing: false, tempo: 1, semis: 0, stems: false, gains: { vocals: 1, drums: 1, bass: 1, melodies: 1 }, volume: 0.9, busy: null, progress: 0 });

/** Two decks with automatic beat matching, key changes and stem toggles; a crossfader in between. */
export function DjPage({ incoming }: { incoming?: SongRef | null }) {
  const { host, engine, markSplit } = useStudio();
  const [decks, setDecks] = useState<DeckState[]>([fresh(), fresh()]);
  const [xfade, setXfade] = useState(0.5);
  const [picking, setPicking] = useState<0 | 1 | null>(null);
  const nodes = useRef<{ node: AudioWorkletNode; gain: GainNode }[]>([]);
  const ref = useRef(decks);
  ref.current = decks;

  const set = (i: number, patch: Partial<DeckState>) => setDecks((d) => d.map((x, j) => (j === i ? { ...x, ...patch } : x)));
  const deckNode = async (i: number) => {
    if (!nodes.current[i]) {
      const node = await engine.deckNode();
      const gain = engine.ctx.createGain();
      node.connect(gain).connect(engine.ctx.destination);
      node.port.onmessage = (e) => { if (e.data.type === 'time') set(i, { time: e.data.sec, playing: e.data.playing && !e.data.ended }); };
      nodes.current[i] = { node, gain };
    }
    return nodes.current[i];
  };
  const post = (i: number, msg: unknown, transfer: Transferable[] = []) => nodes.current[i]?.node.port.postMessage(msg, transfer);

  const bpmOf = (d: DeckState) => (d.loaded?.analysis?.bpm ?? 0) * d.tempo;
  const send = (i: number, d: DeckState) => {
    post(i, { type: 'rate', rate: d.tempo });
    post(i, { type: 'pitch', pitch: 2 ** (d.semis / 12) });
    post(i, { type: 'gains', gains: d.stems ? STEMS.map((s) => d.gains[s]) : [1] });
  };
  const layersOf = (l: Loaded, stems: boolean) => (stems && l.stems ? STEMS.map((s) => l.stems![s].map((c) => c.slice())) : [l.mix.map((c) => c.slice())]);

  const load = async (i: number, song: SongRef) => {
    setPicking(null);
    try {
      await engine.resume();
      set(i, { ...fresh(), song, busy: 'Loading…', volume: ref.current[i].volume });
      const l = await engine.load(song, host.audioUrl(song));
      const a = await engine.analyse(l);
      const { node } = await deckNode(i);
      const layers = layersOf(l, false);
      node.port.postMessage({ type: 'load', layers, sampleRate: l.sampleRate }, layers.flat().map((c) => c.buffer));
      // Auto beat-match: a deck loaded while the other plays takes its tempo.
      const other = ref.current[1 - i];
      const tempo = other.loaded && other.playing && a.bpm ? bpmOf(other) / a.bpm : 1;
      const d: DeckState = { ...fresh(), song, loaded: l, peaks: overview(l.mix, 700), tempo: Math.min(1.5, Math.max(0.67, tempo)), volume: ref.current[i].volume };
      set(i, d);
      send(i, d);
      post(i, { type: 'seek', sec: a.firstBeat });
    } catch (e) { set(i, { busy: null }); host.toast(errText(e), true); }
  };
  useEffect(() => { if (incoming) load(ref.current[0].song ? 1 : 0, incoming); }, [incoming]);

  const toggleStems = async (i: number) => {
    const d = ref.current[i];
    if (!d.loaded) return;
    if (!d.loaded.stems) {
      set(i, { busy: 'Separating stems…', progress: 0 });
      try { await engine.separate(d.loaded, (p) => set(i, { progress: p })); markSplit(d.loaded.song.id); } catch (e) { set(i, { busy: null }); host.toast(errText(e), true); return; }
    }
    const stems = !d.stems;
    const layers = layersOf(d.loaded, stems);
    post(i, { type: 'load', layers, sampleRate: d.loaded.sampleRate }, layers.flat().map((c) => c.buffer));
    const nd = { ...ref.current[i], stems, busy: null };
    set(i, nd);
    send(i, nd);
    post(i, { type: 'seek', sec: d.time });
    if (d.playing) post(i, { type: 'play' });
  };

  const update = (i: number, patch: Partial<DeckState>) => { const nd = { ...ref.current[i], ...patch }; set(i, patch); send(i, nd); };
  const playPause = async (i: number) => { await engine.resume(); post(i, { type: ref.current[i].playing ? 'pause' : 'play' }); };
  const cue = (i: number) => post(i, { type: 'seek', sec: ref.current[i].loaded?.analysis?.firstBeat ?? 0 });

  /** Match this deck's tempo to the other, then line up the beats. */
  const sync = (i: number) => {
    const me = ref.current[i], other = ref.current[1 - i];
    const a = me.loaded?.analysis, b = other.loaded?.analysis;
    if (!a || !b || !a.bpm || !b.bpm) return;
    const tempo = (b.bpm * other.tempo) / a.bpm;
    update(i, { tempo });
    if (other.playing) {
      const beatB = (other.time - b.firstBeat) / (60 / b.bpm);
      const fracB = beatB - Math.floor(beatB);
      const beatA = (me.time - a.firstBeat) / (60 / a.bpm);
      const target = a.firstBeat + (Math.floor(beatA) + fracB) * (60 / a.bpm);
      post(i, { type: 'seek', sec: Math.max(0, target) });
    }
  };
  const matchKey = (i: number) => {
    const me = ref.current[i].loaded?.analysis, other = ref.current[1 - i];
    if (!me || !other.loaded?.analysis) return;
    const k = other.loaded.analysis.key;
    const target = { tonic: (k.tonic + other.semis + 12) % 12, mode: k.mode };
    update(i, { semis: keyShift(me.key, target) });
  };

  // crossfader + volumes (equal power)
  useEffect(() => {
    nodes.current.forEach((n, i) => {
      if (!n) return;
      const x = i === 0 ? 1 - xfade : xfade;
      n.gain.gain.setTargetAtTime(Math.sin((x * Math.PI) / 2) * Math.SQRT2 * 0.7 * decks[i].volume, engine.ctx.currentTime, 0.02);
    });
  }, [xfade, decks, engine]);

  useEffect(() => () => { nodes.current.forEach((n) => { try { n.node.port.postMessage({ type: 'pause' }); n.node.disconnect(); } catch { /* closed */ } }); }, []);

  return (
    <div className="st-col">
      <div className="st-decks">
        {decks.map((d, i) => (
          <DeckView key={i} i={i} d={d} other={decks[1 - i]} onPick={() => setPicking(i as 0 | 1)} onPlay={() => playPause(i)} onCue={() => cue(i)} onSync={() => sync(i)} onMatchKey={() => matchKey(i)}
            onSeek={(f) => d.loaded && post(i, { type: 'seek', sec: f * (d.loaded.mix[0].length / d.loaded.sampleRate) })}
            onTempo={(t) => update(i, { tempo: t })} onSemis={(s) => update(i, { semis: s })} onStems={() => toggleStems(i)} onGain={(s, g) => update(i, { gains: { ...d.gains, [s]: g } })} onVolume={(v) => set(i, { volume: v })} bpm={bpmOf(d)} />
        ))}
      </div>
      <div className="st-panel st-mixer">
        <span className="st-small">A</span>
        <input type="range" min={0} max={1} step={0.01} value={xfade} onChange={(e) => setXfade(Number(e.target.value))} aria-label="Crossfader" className="st-xfade" />
        <span className="st-small">B</span>
      </div>
      {picking !== null && (
        <div className="st-modal" onMouseDown={(e) => e.target === e.currentTarget && setPicking(null)}>
          <div className="st-panel st-modal-box" role="dialog" aria-label={`Load deck ${picking === 0 ? 'A' : 'B'}`}>
            <div className="st-row"><h2 className="st-h2 st-grow">Load deck {picking === 0 ? 'A' : 'B'}</h2><button className="st-x" onClick={() => setPicking(null)} aria-label="Close">×</button></div>
            <SongPicker onPick={(s) => load(picking, s)} label="Song for the deck" />
          </div>
        </div>
      )}
    </div>
  );
}

function DeckView({ i, d, other, bpm, onPick, onPlay, onCue, onSync, onMatchKey, onSeek, onTempo, onSemis, onStems, onGain, onVolume }: {
  i: number; d: DeckState; other: DeckState; bpm: number; onPick: () => void; onPlay: () => void; onCue: () => void; onSync: () => void; onMatchKey: () => void;
  onSeek: (f: number) => void; onTempo: (t: number) => void; onSemis: (s: number) => void; onStems: () => void; onGain: (s: StemName, g: number) => void; onVolume: (v: number) => void;
}) {
  const dur = d.loaded ? d.loaded.mix[0].length / d.loaded.sampleRate : 0;
  const a = d.loaded?.analysis;
  const keyNow = a ? shiftedKey(a.key.tonic, a.key.mode, d.semis) : '—';
  const peaks = useMemo(() => d.peaks ?? new Float32Array(0), [d.peaks]);
  const synced = !!(a && other.loaded?.analysis && Math.abs(bpm - (other.loaded.analysis.bpm * other.tempo)) < 0.05);
  return (
    <section className={`st-panel st-deck${d.playing ? ' live' : ''}`} aria-label={`Deck ${i === 0 ? 'A' : 'B'}`}>
      <div className="st-row">
        <span className="st-deckletter">{i === 0 ? 'A' : 'B'}</span>
        <div className="st-grow st-ellipsis"><b>{d.song?.title ?? 'Empty deck'}</b><div className="st-muted st-small st-ellipsis">{d.song?.artist}</div></div>
        <button className="st-btn" onClick={onPick}>{d.song ? 'Change' : 'Load a song'}</button>
      </div>
      {d.busy && <div><p className="st-muted st-small">{d.busy}</p>{d.busy.startsWith('Separating') && <Bar value={d.progress} />}</div>}
      {d.loaded && (
        <>
          <Wave peaks={peaks} progress={dur ? d.time / dur : 0} onSeek={onSeek} height={64} />
          <div className="st-row st-wrap">
            <button className="st-btn primary big" onClick={onPlay} aria-label={`${d.playing ? 'Pause' : 'Play'} deck ${i === 0 ? 'A' : 'B'}`}>{d.playing ? '❚❚' : '▶'}</button>
            <button className="st-btn" onClick={onCue}>Cue</button>
            <button className={`st-btn${synced ? ' on' : ''}`} onClick={onSync} disabled={!other.loaded} aria-label={`Sync deck ${i === 0 ? 'A' : 'B'}`}>Sync</button>
            <span className="st-mono st-small">{fmtTime(d.time)} / {fmtTime(dur)}</span>
            <span className="st-grow" />
            <div className="st-stats small"><div><b>{bpm ? bpm.toFixed(1) : '—'}</b><span>BPM</span></div><div><b>{keyNow}</b><span>{d.semis ? `${d.semis > 0 ? '+' : ''}${d.semis} st` : 'key'}</span></div></div>
          </div>
          <div className="st-row st-wrap">
            <label className="st-field grow">Tempo {((d.tempo - 1) * 100).toFixed(1)}%<input type="range" min={0.84} max={1.16} step={0.001} value={d.tempo} onChange={(e) => onTempo(Number(e.target.value))} aria-label={`Tempo deck ${i === 0 ? 'A' : 'B'}`} /></label>
            <div className="st-field">Key
              <div className="st-row">
                <button className="st-chip small" onClick={() => onSemis(Math.max(-6, d.semis - 1))} aria-label="Key down">−</button>
                <button className="st-chip small" onClick={() => onSemis(0)}>0</button>
                <button className="st-chip small" onClick={() => onSemis(Math.min(6, d.semis + 1))} aria-label="Key up">+</button>
                <button className="st-chip small" onClick={onMatchKey} disabled={!other.loaded}>Match</button>
              </div>
            </div>
            <label className="st-field">Volume<input type="range" min={0} max={1.2} step={0.01} value={d.volume} onChange={(e) => onVolume(Number(e.target.value))} aria-label={`Volume deck ${i === 0 ? 'A' : 'B'}`} /></label>
          </div>
          <div className="st-row st-wrap">
            <button className={`st-chip${d.stems ? ' on' : ''}`} aria-pressed={d.stems} onClick={onStems} disabled={!!d.busy}>Stems</button>
            {d.stems && STEMS.map((s) => <button key={s} className={`st-chip${d.gains[s] ? ' on' : ''}`} aria-pressed={!!d.gains[s]} onClick={() => onGain(s, d.gains[s] ? 0 : 1)}>{s[0].toUpperCase() + s.slice(1)}</button>)}
            {!d.stems && <span className="st-muted st-tiny">Turn on Stems to drop the vocals, drums, bass or melodies live.</span>}
          </div>
        </>
      )}
    </section>
  );
}

const NAMES = ['C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B'];
const shiftedKey = (tonic: number, mode: string, semis: number) => `${NAMES[(((tonic + semis) % 12) + 12) % 12]}${mode === 'minor' ? 'm' : ''}`;
