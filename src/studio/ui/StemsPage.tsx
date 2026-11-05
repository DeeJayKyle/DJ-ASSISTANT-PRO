import { useEffect, useMemo, useRef, useState } from 'react';
import { useStudio, SongPicker, Wave, Bar, fmtTime, errText } from './host';
import type { Loaded, SongRef } from '../engine';
import { STEMS, instrumental, type StemName } from '../audio/stems';
import { encodeWav, overview } from '../audio/wav';
import { chordAt } from '../audio/chords';

const LABEL: Record<StemName | 'mix' | 'instrumental', string> = { mix: 'Full song', vocals: 'Vocals', drums: 'Drums', bass: 'Bass', melodies: 'Melodies', instrumental: 'Instrumental' };
const safe = (s: string) => s.replace(/[\\/:*?"<>|]/g, ' ').replace(/\s+/g, ' ').trim() || 'Song';

/** Stems: split a song into vocals, drums, bass and melodies; key, tempo, live chords; stems and MIDI downloads. */
export function StemsPage({ onSendToRemix, onSendToDeck }: { onSendToRemix?: (s: SongRef) => void; onSendToDeck?: (s: SongRef) => void }) {
  const { host, engine, markSplit } = useStudio();
  const [song, setSong] = useState<SongRef | null>(null);
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [phase, setPhase] = useState<'idle' | 'loading' | 'splitting' | 'ready'>('idle');
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState('');
  const [gains, setGains] = useState<Record<StemName, number>>({ vocals: 1, drums: 1, bass: 1, melodies: 1 });
  const [solo, setSolo] = useState<StemName | null>(null);
  const [pos, setPos] = useState(0);
  const [playing, setPlaying] = useState(false);
  const [dl, setDl] = useState<Set<string>>(new Set(['vocals', 'drums', 'bass', 'melodies', 'instrumental']));
  const [midiBusy, setMidiBusy] = useState(false);
  const [aiReady, setAiReady] = useState<boolean | null>(host.aiStems ? null : false);
  const [method, setMethod] = useState<'ai' | 'fast'>('fast');
  useEffect(() => {
    if (!host.aiStems) return;
    let live = true;
    let first = true;
    const check = () => host.aiStems!().then((p) => {
      if (!live) return;
      engine.ai = p; setAiReady(!!p);
      if (p && first) setMethod('ai'); // prefer AI once it's installed; the user can switch back
      if (!p) setMethod('fast');
      first = false;
    }).catch(() => live && setAiReady(false));
    check();
    window.addEventListener('focus', check);
    return () => { live = false; window.removeEventListener('focus', check); };
  }, [host]); // eslint-disable-line react-hooks/exhaustive-deps
  const player = useRef<{ nodes: AudioBufferSourceNode[]; gains: Map<StemName, GainNode>; startedAt: number; offset: number } | null>(null);
  const buffers = useRef<Map<StemName, AudioBuffer>>(new Map());

  const pick = async (s: SongRef, how: 'ai' | 'fast' = method) => {
    stop();
    setSong(s); setLoaded(null); setError(''); setPhase('loading'); setProgress(0); buffers.current.clear(); setPos(0);
    try {
      await engine.resume();
      const l = await engine.load(s, host.audioUrl(s));
      await engine.analyse(l);
      setPhase('splitting');
      const t0 = performance.now();
      let note = '';
      try {
        await engine.separate(l, setProgress, how === 'ai' && engine.ai ? 'ai' : 'fast');
      } catch (e) {
        if (!(e as { fallback?: boolean }).fallback) throw e;
        note = ` ${errText(e)}`;
      }
      for (const st of STEMS) buffers.current.set(st, engine.toBuffer(l.stems![st], l.sampleRate));
      markSplit(s.id);
      setLoaded(l); setPhase('ready');
      const by = l.stemsBy === 'ai' ? ` with AI (${engine.aiDevice === 'gpu' ? 'graphics card' : 'processor'})` : '';
      host.toast(`Split into 4 stems${by} in ${((performance.now() - t0) / 1000).toFixed(1)} s.${note}`, !!note);
    } catch (e) {
      setError(errText(e)); setPhase('idle');
    }
  };

  const duration = loaded ? loaded.mix[0].length / loaded.sampleRate : 0;
  const effGain = (st: StemName) => (solo ? (solo === st ? 1 : 0) : gains[st]);

  function stop() {
    const p = player.current;
    if (p) { for (const n of p.nodes) { try { n.stop(); } catch { /* already stopped */ } } player.current = null; }
    setPlaying(false);
  }
  const play = (from = pos) => {
    stop();
    const ctx = engine.ctx;
    const nodes: AudioBufferSourceNode[] = [];
    const gm = new Map<StemName, GainNode>();
    const when = ctx.currentTime + 0.05;
    for (const st of STEMS) {
      const b = buffers.current.get(st);
      if (!b) continue;
      const src = ctx.createBufferSource(); src.buffer = b;
      const g = ctx.createGain(); g.gain.value = effGain(st);
      src.connect(g).connect(ctx.destination);
      src.start(when, from);
      nodes.push(src); gm.set(st, g);
    }
    nodes[0]?.addEventListener('ended', () => { if (player.current?.nodes === nodes) { setPlaying(false); player.current = null; } });
    player.current = { nodes, gains: gm, startedAt: when, offset: from };
    setPlaying(true);
  };
  useEffect(() => { const p = player.current; if (p) for (const st of STEMS) p.gains.get(st)?.gain.setTargetAtTime(effGain(st), engine.ctx.currentTime, 0.01); });
  useEffect(() => {
    if (!playing) return;
    let raf = 0;
    const tick = () => { const p = player.current; if (p) setPos(Math.min(duration, p.offset + engine.ctx.currentTime - p.startedAt)); raf = requestAnimationFrame(tick); };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [playing, duration, engine]);
  useEffect(() => () => stop(), []);

  const peaks = useMemo(() => {
    if (!loaded?.stems) return null;
    return Object.fromEntries(STEMS.map((st) => [st, overview(loaded.stems![st], 500)])) as Record<StemName, Float32Array>;
  }, [loaded]);
  const chord = loaded?.analysis ? chordAt(loaded.analysis.chords, pos) : null;
  const next = loaded?.analysis?.chords.find((c) => c.start > pos);

  const downloadStems = async () => {
    if (!loaded?.stems || !song) return;
    const files: { name: string; bytes: Uint8Array }[] = [];
    for (const st of STEMS) if (dl.has(st)) files.push({ name: `${safe(song.title)} - ${LABEL[st]}.wav`, bytes: encodeWav(loaded.stems[st], loaded.sampleRate) });
    if (dl.has('instrumental')) files.push({ name: `${safe(song.title)} - Instrumental.wav`, bytes: encodeWav(instrumental(loaded.stems), loaded.sampleRate) });
    if (!files.length) return;
    try {
      const where = await host.saveFiles(`${safe(song.title)} - Stems`, files);
      if (where) host.toast(`Saved ${files.length} stem${files.length === 1 ? '' : 's'}.`);
    } catch (e) { host.toast(errText(e), true); }
  };
  const downloadMidi = async () => {
    if (!loaded || !song) return;
    setMidiBusy(true);
    try {
      const { bytes, counts } = await engine.midi(loaded, ['bass', 'melodies', 'vocals', 'drums', 'chords']);
      const where = await host.saveFile(`${safe(song.title)}.mid`, bytes);
      if (where) host.toast(`MIDI saved: ${counts.map((c) => `${c.name} ${c.notes}`).join(', ')} notes.`);
    } catch (e) { host.toast(errText(e), true); } finally { setMidiBusy(false); }
  };

  return (
    <div className="st-grid2">
      <section className="st-panel">
        <h2 className="st-h2">Pick a song</h2>
        <p className="st-muted st-small">Split it into vocals, drums, bass and melodies, find its key, tempo and chords, and turn the parts into MIDI. It all runs on this computer.</p>
        {host.aiStems && (
          <div className="st-row st-wrap" style={{ margin: '6px 0 10px' }}>
            <span className="st-small st-muted">Separation</span>
            <div className="st-seg" role="group" aria-label="Separation method">
              <button className={`st-chip${method === 'ai' ? ' on' : ''}`} aria-pressed={method === 'ai'} disabled={!aiReady} onClick={() => setMethod('ai')} title={aiReady ? 'HTDemucs AI model: the cleanest stems' : 'Install Pro Stems AI first'}>AI (best)</button>
              <button className={`st-chip${method === 'fast' ? ' on' : ''}`} aria-pressed={method === 'fast'} onClick={() => setMethod('fast')}>Fast</button>
            </div>
            {aiReady === false && <button className="st-btn small" onClick={() => host.openPacks?.()}>Get Pro Stems AI</button>}
            {song && loaded && loaded.stemsBy !== method && phase === 'ready' && <button className="st-btn small" onClick={() => pick(song, method)}>Split again with {method === 'ai' ? 'AI' : 'Fast'}</button>}
          </div>
        )}
        <SongPicker onPick={(s) => pick(s)} label="Song to split" />
      </section>
      <section className="st-panel st-col">
        {!song && <div className="st-empty">Choose a song to split it into stems.</div>}
        {song && (
          <>
            <div className="st-row st-wrap">
              <div className="st-grow">
                <h2 className="st-h2">{song.title}</h2>
                <div className="st-muted st-small">{song.artist}</div>
              </div>
              {loaded?.analysis && (
                <div className="st-stats">
                  <div><b>{Math.round(loaded.analysis.bpm * 10) / 10}</b><span>BPM</span></div>
                  <div><b>{loaded.analysis.key.short}</b><span>{loaded.analysis.key.camelot}</span></div>
                  <div className="st-chord" aria-live="polite"><b>{chord?.name ?? '—'}</b><span>{next ? `next ${next.name}` : 'chord'}</span></div>
                </div>
              )}
            </div>
            {error && <p className="st-error" role="alert">{error}</p>}
            {phase === 'loading' && <><p className="st-muted">Reading the song…</p><Bar value={0.05} /></>}
            {phase === 'splitting' && <><p className="st-muted">{method === 'ai' && engine.ai ? `Separating with AI${engine.aiDevice ? ` on the ${engine.aiDevice === 'gpu' ? 'graphics card' : 'processor'}` : ''}… ${Math.round(progress * 100)}%` : `Separating stems on ${engine.workers} cores… ${Math.round(progress * 100)}%`}</p><Bar value={progress} label="Separating" />{method === 'ai' && engine.ai && <button className="st-btn" onClick={() => engine.cancelAi()}>Stop</button>}</>}
            {phase === 'ready' && loaded && peaks && (
              <>
                <div className="st-row">
                  <button className="st-btn primary" onClick={() => (playing ? (setPos(pos), stop()) : play())} aria-label={playing ? 'Pause' : 'Play'}>{playing ? '❚❚ Pause' : '▶ Play'}</button>
                  <span className="st-mono st-small">{fmtTime(pos)} / {fmtTime(duration)}</span>
                  <span className="st-grow" />
                  {onSendToRemix && <button className="st-btn" onClick={() => onSendToRemix(song)}>Remix it →</button>}
                  {onSendToDeck && <button className="st-btn" onClick={() => onSendToDeck(song)}>DJ it →</button>}
                </div>
                <div className="st-stems">
                  {STEMS.map((st) => (
                    <div key={st} className={`st-stem${effGain(st) === 0 ? ' off' : ''}`}>
                      <div className="st-stem-head">
                        <b>{LABEL[st]}</b>
                        <button className={`st-chip${solo === st ? ' on' : ''}`} aria-pressed={solo === st} onClick={() => setSolo(solo === st ? null : st)}>Solo</button>
                        <button className={`st-chip${gains[st] === 0 ? ' on' : ''}`} aria-pressed={gains[st] === 0} onClick={() => setGains({ ...gains, [st]: gains[st] === 0 ? 1 : 0 })}>Mute</button>
                        <input type="range" min={0} max={1.5} step={0.01} value={gains[st]} onChange={(e) => setGains({ ...gains, [st]: Number(e.target.value) })} aria-label={`${LABEL[st]} volume`} />
                      </div>
                      <Wave peaks={peaks[st]} progress={duration ? pos / duration : 0} height={40} onSeek={(f) => { setPos(f * duration); if (playing) play(f * duration); }} />
                    </div>
                  ))}
                </div>
                <div className="st-row st-wrap" style={{ marginTop: 8 }}>
                  {(['vocals', 'drums', 'bass', 'melodies', 'instrumental'] as const).map((k) => (
                    <label key={k} className="st-check"><input type="checkbox" checked={dl.has(k)} onChange={(e) => { const n = new Set(dl); if (e.target.checked) n.add(k); else n.delete(k); setDl(n); }} /> {LABEL[k]}</label>
                  ))}
                  <span className="st-grow" />
                  <button className="st-btn primary" onClick={downloadStems} disabled={!dl.size}>Download stems (WAV)</button>
                  <button className="st-btn" onClick={downloadMidi} disabled={midiBusy}>{midiBusy ? 'Making MIDI…' : 'Download MIDI'}</button>
                </div>
                <p className="st-muted st-tiny">{loaded.stemsBy === 'ai' ? 'Separated with the HTDemucs AI model on this computer.' : 'Separated with fast signal processing: private and quick, but parts can bleed into each other more than with the AI model.'} MIDI has a track each for bass, melody, vocal melody, chords and drums.</p>
              </>
            )}
          </>
        )}
      </section>
    </div>
  );
}
