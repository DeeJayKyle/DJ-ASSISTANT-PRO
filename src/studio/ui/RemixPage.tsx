import { useEffect, useRef, useState } from 'react';
import { useStudio, SongPicker, Bar, errText } from './host';
import type { SongRef } from '../engine';
import { encodeWav } from '../audio/wav';
import { NOTE_NAMES } from '../audio/chords';
import { newTrackFor, projectBeats, uid, type Clip, type Layer, type Project, type Source } from '../remix';

const LAYERS: { id: Layer; label: string }[] = [
  { id: 'mix', label: 'Song' }, { id: 'vocals', label: 'Vocals' }, { id: 'drums', label: 'Drums' }, { id: 'bass', label: 'Bass' }, { id: 'melodies', label: 'Melodies' },
];
const COLORS: Record<Layer, string> = { mix: '#7aa2ff', vocals: '#ff7aa8', drums: '#ffb547', bass: '#b38cff', melodies: '#3ee6c4' };

/** Remix: clips from songs and stems on a beat grid; one tempo and key; Fadr-style auto-sync, made here. */
export function RemixPage({ incoming, active = true }: { incoming?: SongRef | null; active?: boolean }) {
  const { host, engine, markSplit } = useStudio();
  const [project, setProject] = useState<Project>({ name: 'My Remix', bpm: 120, key: { tonic: 9, mode: 'minor' }, tracks: [] });
  const [sources, setSources] = useState<Map<string, Source>>(new Map());
  const [selected, setSelected] = useState<SongRef | null>(null);
  const [busy, setBusy] = useState<{ label: string; p: number } | null>(null);
  const [zoom, setZoom] = useState(14);
  const [playing, setPlaying] = useState(false);
  const [head, setHead] = useState(0); // beats
  const node = useRef<{ src: AudioBufferSourceNode; at: number; from: number } | null>(null);
  const [selected2, setSel] = useState<string | null>(null); // selected clip id
  const history = useRef<{ past: Project[]; future: Project[] }>({ past: [], future: [] });
  const projectRef = useRef(project);
  projectRef.current = project;
  /** Remember the arrangement before a change, for undo. */
  const remember = () => { const h = history.current; h.past.push(projectRef.current); if (h.past.length > 60) h.past.shift(); h.future = []; };

  useEffect(() => { if (incoming) setSelected(incoming); }, [incoming]);

  const addLayer = async (song: SongRef, layer: Layer) => {
    try {
      await engine.resume();
      setBusy({ label: layer === 'mix' ? 'Reading the song…' : 'Separating stems…', p: 0 });
      const l = await engine.load(song, host.audioUrl(song));
      if (layer !== 'mix') { await engine.separate(l, (p) => setBusy({ label: 'Separating stems…', p })); markSplit(song.id); }
      let src = sources.get(song.id);
      if (!src || (layer !== 'mix' && !l.stems) || !engine.hasRemixSource(song.id) || (layer !== 'mix' && !src.layers.vocals)) {
        setBusy({ label: 'Getting it ready to sync…', p: 0.9 });
        src = await engine.remixSource(l, !!l.stems);
        setSources((m) => new Map(m).set(song.id, src!));
      }
      remember();
      setProject((p) => {
        const first = p.tracks.length === 0;
        const base: Project = first ? { ...p, bpm: Math.round(src!.bpm * 10) / 10, key: { tonic: src!.key.tonic, mode: src!.key.mode } } : p;
        return { ...base, tracks: [...base.tracks, newTrackFor(src!, layer, base)] };
      });
    } catch (e) { host.toast(errText(e), true); } finally { setBusy(null); }
  };

  const stop = () => { try { node.current?.src.stop(); } catch { /* already */ } node.current = null; setPlaying(false); };
  const render = async (withTracks = false) => {
    setBusy({ label: 'Rendering the remix…', p: 0.5 });
    try { return await engine.render(project, withTracks); } finally { setBusy(null); }
  };
  const play = async () => {
    if (playing) { stop(); return; }
    if (!project.tracks.length) return;
    try {
      await engine.resume();
      const { mix } = await render();
      const buf = engine.toBuffer(mix, engine.ctx.sampleRate);
      const src = engine.ctx.createBufferSource(); src.buffer = buf; src.connect(engine.ctx.destination);
      const fromSec = (head * 60) / project.bpm;
      const at = engine.ctx.currentTime + 0.05;
      src.start(at, Math.min(fromSec, buf.duration - 0.01));
      src.onended = () => { if (node.current?.src === src) stop(); };
      node.current = { src, at, from: head };
      setPlaying(true);
    } catch (e) { host.toast(errText(e), true); }
  };
  useEffect(() => {
    if (!playing) return;
    let raf = 0;
    const tick = () => { const n = node.current; if (n) setHead(n.from + ((engine.ctx.currentTime - n.at) * project.bpm) / 60); raf = requestAnimationFrame(tick); };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [playing, project.bpm, engine]);
  useEffect(() => () => stop(), []);
  // Any edit stops playback so what you hear matches the arrangement.
  const edit = (fn: (p: Project) => Project) => { if (playing) stop(); setProject(fn); };
  /** A change that can be undone in one step. */
  const change = (fn: (p: Project) => Project) => { remember(); edit(fn); };
  const undo = () => { const h = history.current; const prev = h.past.pop(); if (!prev) return; h.future.push(projectRef.current); edit(() => prev); };
  const redo = () => { const h = history.current; const next = h.future.pop(); if (!next) return; h.past.push(projectRef.current); edit(() => next); };
  const removeClip = (id: string) => change((p) => ({ ...p, tracks: p.tracks.map((t) => ({ ...t, clips: t.clips.filter((c) => c.id !== id) })).filter((t) => t.clips.length > 0) }));
  const duplicateClip = (id: string) => change((p) => ({ ...p, tracks: p.tracks.map((t) => { const c = t.clips.find((x) => x.id === id); if (!c) return t; const end = Math.max(...t.clips.map((x) => x.start + x.length * x.loops)); return { ...t, clips: [...t.clips, { ...c, id: uid('c'), start: end }] }; }) }));
  useEffect(() => {
    if (!active) return;
    const k = (e: KeyboardEvent) => {
      if (['INPUT', 'SELECT', 'TEXTAREA'].includes((e.target as HTMLElement).tagName)) return;
      const mod = e.ctrlKey || e.metaKey;
      if (mod && e.key.toLowerCase() === 'z') { e.preventDefault(); if (e.shiftKey) redo(); else undo(); }
      else if (mod && e.key.toLowerCase() === 'y') { e.preventDefault(); redo(); }
      else if (mod && e.key.toLowerCase() === 'd' && selected2) { e.preventDefault(); duplicateClip(selected2); }
      else if ((e.key === 'Delete' || e.key === 'Backspace') && selected2) { e.preventDefault(); removeClip(selected2); setSel(null); }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  });

  const exportMix = async () => {
    try {
      const { mix } = await render();
      const where = await host.saveFile(`${project.name}.wav`, encodeWav(mix, engine.ctx.sampleRate));
      if (where) host.toast('Remix exported.');
    } catch (e) { host.toast(errText(e), true); }
  };
  const exportTracks = async () => {
    try {
      const { mix, tracks } = await render(true);
      const files = [{ name: `${project.name} - Mix.wav`, bytes: encodeWav(mix, engine.ctx.sampleRate) }, ...tracks.map(([id, ch], i) => ({ name: `${String(i + 1).padStart(2, '0')} ${project.tracks.find((t) => t.id === id)?.name.replace(/[\\/:*?"<>|]/g, ' ') ?? 'Track'}.wav`, bytes: encodeWav(ch, engine.ctx.sampleRate) }))];
      const where = await host.saveFiles(`${project.name} - Tracks`, files);
      if (where) host.toast(`Exported the mix and ${tracks.length} tracks.`);
    } catch (e) { host.toast(errText(e), true); }
  };

  const beats = Math.ceil(projectBeats(project) + 8);
  const width = beats * zoom;
  const drag = (e: React.PointerEvent, clip: Clip, trackId: string, mode: 'move' | 'left' | 'right' | 'loop') => {
    e.preventDefault(); e.stopPropagation();
    remember();
    setSel(clip.id);
    const x0 = e.clientX, start = { ...clip };
    const move = (ev: PointerEvent) => {
      const d = Math.round((ev.clientX - x0) / zoom);
      edit((p) => ({ ...p, tracks: p.tracks.map((t) => t.id !== trackId ? t : { ...t, clips: t.clips.map((c) => {
        if (c.id !== clip.id) return c;
        if (mode === 'move') return { ...c, start: Math.max(0, start.start + d) };
        if (mode === 'right') return { ...c, length: Math.max(1, start.length + d) };
        if (mode === 'left') { const dd = Math.max(-start.offset, Math.min(start.length - 1, d)); return { ...c, start: Math.max(0, start.start + dd), offset: start.offset + dd, length: start.length - dd }; }
        return { ...c, loops: Math.max(1, Math.round((start.length * start.loops + d) / start.length)) };
      }) }) }));
    };
    const up = () => { window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  };
  const upd = (id: string, patch: Partial<Project['tracks'][number]>) => change((p) => ({ ...p, tracks: p.tracks.map((t) => (t.id === id ? { ...t, ...patch } : t)) }));

  return (
    <div className="st-remix">
      <aside className="st-panel st-col">
        <h2 className="st-h2">Library</h2>
        <SongPicker onPick={setSelected} compact label="Song to add" />
        {selected && (
          <div className="st-card">
            <b>{selected.title}</b>
            <div className="st-muted st-small">Add the whole song or one of its stems:</div>
            <div className="st-row st-wrap" style={{ marginTop: 6 }}>
              {LAYERS.map((l) => <button key={l.id} className="st-chip" style={{ borderColor: COLORS[l.id] }} onClick={() => addLayer(selected, l.id)} disabled={!!busy}>+ {l.label}</button>)}
            </div>
          </div>
        )}
        {busy && <div><p className="st-muted st-small">{busy.label}</p><Bar value={busy.p} /></div>}
      </aside>
      <section className="st-panel st-col st-grow">
        <div className="st-row st-wrap">
          <input className="st-input st-title" value={project.name} onChange={(e) => setProject({ ...project, name: e.target.value })} aria-label="Remix name" />
          <button className="st-btn primary" onClick={play} disabled={!project.tracks.length || (!!busy && !playing)}>{playing ? '■ Stop' : '▶ Play'}</button>
          <label className="st-field">Tempo<input className="st-input st-num" type="number" min={60} max={200} step={0.5} value={project.bpm} onChange={(e) => edit((p) => ({ ...p, bpm: Math.min(200, Math.max(60, Number(e.target.value) || 120)) }))} aria-label="Project tempo" /></label>
          <label className="st-field">Key<select className="st-input" value={`${project.key.tonic}:${project.key.mode}`} onChange={(e) => { const [t, m] = e.target.value.split(':'); edit((p) => ({ ...p, key: { tonic: Number(t), mode: m as 'major' | 'minor' } })); }} aria-label="Project key">
            {NOTE_NAMES.flatMap((n, i) => [<option key={`${i}M`} value={`${i}:major`}>{n} major</option>, <option key={`${i}m`} value={`${i}:minor`}>{n} minor</option>])}
          </select></label>
          <label className="st-field">Zoom<input type="range" min={6} max={40} value={zoom} onChange={(e) => setZoom(Number(e.target.value))} aria-label="Zoom" /></label>
          <button className="st-btn" onClick={undo} disabled={!history.current.past.length} aria-label="Undo" title="Undo (Ctrl+Z)">↶</button>
          <button className="st-btn" onClick={redo} disabled={!history.current.future.length} aria-label="Redo" title="Redo (Ctrl+Shift+Z)">↷</button>
          {selected2 && <><button className="st-btn" onClick={() => duplicateClip(selected2)} title="Duplicate (Ctrl+D)">Duplicate clip</button><button className="st-btn" onClick={() => { removeClip(selected2); setSel(null); }} title="Delete">Delete clip</button></>}
          <span className="st-grow" />
          <button className="st-btn" onClick={exportTracks} disabled={!project.tracks.length || !!busy}>Export tracks</button>
          <button className="st-btn primary" onClick={exportMix} disabled={!project.tracks.length || !!busy}>Export remix (WAV)</button>
        </div>
        {!project.tracks.length && <div className="st-empty">Add a song or a stem from the library. Every clip follows the remix's tempo and key automatically.</div>}
        {project.tracks.length > 0 && (
          <div className="st-timeline" onClick={(e) => { const r = (e.currentTarget.querySelector('.st-lanes') as HTMLElement).getBoundingClientRect(); const x = e.clientX - r.left + (e.currentTarget as HTMLElement).scrollLeft; if (x >= 0) { if (playing) stop(); setHead(Math.max(0, Math.round(x / zoom))); } }}>
            <div className="st-ruler" style={{ width: width + 220 }}>
              <div className="st-trackhead" />
              <div className="st-lanes" style={{ width, ["--beat" as string]: `${zoom}px` }}>{Array.from({ length: Math.ceil(beats / 4) }, (_, b) => <span key={b} style={{ left: b * 4 * zoom }}>{b + 1}</span>)}</div>
            </div>
            {project.tracks.map((t) => (
              <div key={t.id} className="st-trackrow" style={{ width: width + 220 }}>
                <div className="st-trackhead" onClick={(e) => e.stopPropagation()}>
                  <div className="st-row"><b className="st-ellipsis st-grow" title={t.name}>{t.name}</b><button className="st-x" aria-label={`Remove ${t.name}`} onClick={() => change((p) => ({ ...p, tracks: p.tracks.filter((x) => x.id !== t.id) }))}>×</button></div>
                  <div className="st-row">
                    <button className={`st-chip small${t.mute ? ' on' : ''}`} aria-pressed={t.mute} onClick={() => upd(t.id, { mute: !t.mute })}>M</button>
                    <button className={`st-chip small${t.solo ? ' on' : ''}`} aria-pressed={t.solo} onClick={() => upd(t.id, { solo: !t.solo })}>S</button>
                    <input type="range" min={0} max={1.5} step={0.01} value={t.gain} onChange={(e) => upd(t.id, { gain: Number(e.target.value) })} aria-label={`${t.name} volume`} />
                    <input type="range" min={-1} max={1} step={0.05} value={t.pan} onChange={(e) => upd(t.id, { pan: Number(e.target.value) })} aria-label={`${t.name} pan`} style={{ width: 50 }} />
                  </div>
                </div>
                <div className="st-lanes" style={{ width, ["--beat" as string]: `${zoom}px` }}>
                  {t.clips.map((c) => (
                    <div key={c.id} className={`st-clip${selected2 === c.id ? ' sel' : ''}`} style={{ left: c.start * zoom, width: c.length * c.loops * zoom, background: COLORS[c.layer] }} onPointerDown={(e) => drag(e, c, t.id, 'move')} title={`${c.length} beats${c.loops > 1 ? ` × ${c.loops}` : ''} — drag to move, edges to trim, top-right to loop`} aria-label={`Clip ${t.name}`}>
                      {Array.from({ length: c.loops - 1 }, (_, i) => <i key={i} className="st-loopmark" style={{ left: (i + 1) * c.length * zoom }} />)}
                      <span className="st-cliplabel">{c.length}b{c.loops > 1 ? ` ×${c.loops}` : ''}</span>
                      <b className="st-h left" onPointerDown={(e) => drag(e, c, t.id, 'left')} />
                      <b className="st-h right" onPointerDown={(e) => drag(e, c, t.id, 'right')} />
                      <b className="st-h loop" onPointerDown={(e) => drag(e, c, t.id, 'loop')} title="Drag to loop" />
                    </div>
                  ))}
                  <button className="st-addclip" onClick={(e) => { e.stopPropagation(); const last = t.clips[t.clips.length - 1]; if (last) change((p) => ({ ...p, tracks: p.tracks.map((x) => (x.id === t.id ? { ...x, clips: [...x.clips, { ...last, id: uid('c'), start: last.start + last.length * last.loops, loops: 1 }] } : x)) })); }} style={{ left: Math.max(0, ...t.clips.map((c) => (c.start + c.length * c.loops) * zoom)) + 6 }} aria-label={`Repeat the last clip of ${t.name}`}>+</button>
                </div>
              </div>
            ))}
            <div className="st-playhead" style={{ left: 220 + head * zoom }} />
          </div>
        )}
        <p className="st-muted st-tiny">Each clip is time-stretched to {project.bpm} BPM and moved into {NOTE_NAMES[project.key.tonic]} {project.key.mode} (the shortest way round, via the relative key for major/minor).</p>
      </section>
    </div>
  );
}
