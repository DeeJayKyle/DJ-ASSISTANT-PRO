import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { useStudio, errText } from './host';
import { renderNote, type Patch } from '../sound/synth';
import { renderPad, type Kit, type Pad } from '../sound/drums';
import { patchFromPrompt, kitFromPrompt, patchFromAi, SYNTH_IDEAS, DRUM_IDEAS, AI_SYNTH_SYSTEM } from '../sound/prompt';
import { instrumentFiles, kitFiles } from '../sound/export';

const shuffle = <T,>(a: T[], n: number) => [...a].sort(() => Math.random() - 0.5).slice(0, n);
const typing = (e: KeyboardEvent) => ['INPUT', 'TEXTAREA', 'SELECT'].includes((e.target as HTMLElement).tagName);
const NOTE = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const extractJson = (t: string) => { const m = t.match(/\{[\s\S]*\}/); try { return m ? JSON.parse(m[0]) : null; } catch { return null; } };

/** Plays rendered sounds with a release on key-up. */
function useVoices() {
  const { engine } = useStudio();
  const live = useRef(new Map<string, { src: AudioBufferSourceNode; gain: GainNode }>());
  const start = useCallback((id: string, ch: Float32Array[], sr: number) => {
    const ctx = engine.ctx;
    live.current.get(id)?.src.stop();
    const src = ctx.createBufferSource(); src.buffer = engine.toBuffer(ch, sr);
    const gain = ctx.createGain(); src.connect(gain).connect(ctx.destination);
    src.start();
    live.current.set(id, { src, gain });
    src.onended = () => { if (live.current.get(id)?.src === src) live.current.delete(id); };
  }, [engine]);
  const release = useCallback((id: string, seconds: number) => {
    const v = live.current.get(id);
    if (!v) return;
    const t = engine.ctx.currentTime;
    v.gain.gain.setValueAtTime(v.gain.gain.value, t);
    v.gain.gain.linearRampToValueAtTime(0, t + Math.max(0.02, seconds));
    v.src.stop(t + Math.max(0.02, seconds) + 0.02);
  }, [engine]);
  return { start, release };
}

/** Optional MIDI controller input (Web MIDI). */
function useMidi(onNote: (note: number, on: boolean, velocity: number) => void) {
  const [name, setName] = useState<string | null>(null);
  const cb = useRef(onNote);
  cb.current = onNote;
  const connect = async () => {
    const nav = navigator as Navigator & { requestMIDIAccess?: () => Promise<MIDIAccess> };
    if (!nav.requestMIDIAccess) throw new Error('MIDI controllers aren’t available here.');
    const access = await nav.requestMIDIAccess();
    const inputs = [...access.inputs.values()];
    if (!inputs.length) throw new Error('No MIDI controller found. Plug one in and try again.');
    for (const i of inputs) i.onmidimessage = (e: MIDIMessageEvent) => { const [st, n, v] = e.data ?? []; const cmd = st & 0xf0; if (cmd === 0x90 && v > 0) cb.current(n, true, v / 127); else if (cmd === 0x80 || (cmd === 0x90 && v === 0)) cb.current(n, false, 0); };
    setName(inputs.map((i) => i.name).join(', '));
  };
  return { name, connect };
}

const KEYS = 'awsedftgyhujkolp;'.split(''); // C … E an octave up

/** Synth Lab: describe a sound, get a playable instrument; fine-tune; download WAV + SFZ. */
export function SynthLab({ active = true }: { active?: boolean }) {
  const { host, engine } = useStudio();
  const [prompt, setPrompt] = useState('warm analog pad with slow attack');
  const [seed, setSeed] = useState(1);
  const [patch, setPatch] = useState<Patch>(() => patchFromPrompt('warm analog pad with slow attack', 1));
  const [ideas, setIdeas] = useState(() => shuffle(SYNTH_IDEAS, 5));
  const [octave, setOctave] = useState(4);
  const [down, setDown] = useState<Set<number>>(new Set());
  const [busy, setBusy] = useState(false);
  const voices = useVoices();
  const cache = useRef(new Map<string, Float32Array[]>());
  const key = JSON.stringify(patch);
  useEffect(() => cache.current.clear(), [key]);

  const make = async (text: string, s = 1) => {
    setPrompt(text); setSeed(s);
    let p = patchFromPrompt(text, s);
    if (host.ai && s === 1) {
      setBusy(true);
      try { p = patchFromAi(extractJson(await host.ai(AI_SYNTH_SYSTEM, `Design a patch for: ${text}`)), p); } catch { /* rules are enough */ } finally { setBusy(false); }
    }
    setPatch(p);
  };
  const noteOn = useCallback((midi: number, vel = 0.9) => {
    void engine.resume();
    const id = `${midi}`;
    let ch = cache.current.get(`${midi}:${vel.toFixed(1)}`);
    if (!ch) { ch = renderNote(patch, midi, 6, engine.ctx.sampleRate, vel); cache.current.set(`${midi}:${vel.toFixed(1)}`, ch); }
    voices.start(id, ch, engine.ctx.sampleRate);
    setDown((d) => new Set(d).add(midi));
  }, [patch, engine, voices]);
  const noteOff = useCallback((midi: number) => {
    voices.release(`${midi}`, patch.amp.r);
    setDown((d) => { const n = new Set(d); n.delete(midi); return n; });
  }, [patch, voices]);
  const midi = useMidi((n, on, v) => (on ? noteOn(n, v) : noteOff(n)));

  useEffect(() => {
    if (!active) return;
    const held = new Set<string>();
    const kd = (e: KeyboardEvent) => {
      if (typing(e) || e.repeat || e.metaKey || e.ctrlKey) return;
      const k = e.key.toLowerCase();
      if (k === 'z') { setOctave((o) => Math.max(1, o - 1)); return; }
      if (k === 'x') { setOctave((o) => Math.min(7, o + 1)); return; }
      const i = KEYS.indexOf(k);
      if (i < 0 || held.has(k)) return;
      held.add(k); e.preventDefault();
      noteOn(12 * (octave + 1) + i);
    };
    const ku = (e: KeyboardEvent) => { const k = e.key.toLowerCase(); const i = KEYS.indexOf(k); if (i < 0 || !held.has(k)) return; held.delete(k); noteOff(12 * (octave + 1) + i); };
    window.addEventListener('keydown', kd); window.addEventListener('keyup', ku);
    return () => { window.removeEventListener('keydown', kd); window.removeEventListener('keyup', ku); };
  }, [octave, noteOn, noteOff, active]);

  const download = async () => {
    try {
      const files = instrumentFiles(patch, 44100);
      const where = await host.saveFiles(patch.name, files);
      if (where) host.toast(`Saved ${files.length - 2} samples and an SFZ instrument.`);
    } catch (e) { host.toast(errText(e), true); }
  };
  const knob = (label: string, value: number, min: number, max: number, step: number, set: (v: number) => void, fmt = (v: number) => v.toFixed(2)) => (
    <label className="st-field">{label} <span className="st-mono">{fmt(value)}</span><input type="range" min={min} max={max} step={step} value={value} onChange={(e) => set(Number(e.target.value))} aria-label={label} /></label>
  );
  const whites = useMemo(() => { const out: number[] = []; for (let m = 12 * (octave + 1); m <= 12 * (octave + 1) + 16; m++) out.push(m); return out; }, [octave]);

  return (
    <div className="st-col">
      <section className="st-panel">
        <h2 className="st-h2">Describe an instrument</h2>
        <form className="st-row" onSubmit={(e) => { e.preventDefault(); void make(prompt); }}>
          <input className="st-input st-grow" value={prompt} onChange={(e) => setPrompt(e.target.value)} placeholder="e.g. dark thick sub bass" aria-label="Describe the sound" />
          <button className="st-btn primary" disabled={!prompt.trim() || busy}>{busy ? 'Designing…' : 'Make it'}</button>
          <button type="button" className="st-btn" onClick={() => make(prompt, seed - 1 < 1 ? 1 : seed - 1)} aria-label="Previous variation">◀</button>
          <button type="button" className="st-btn" onClick={() => make(prompt, seed + 1)} aria-label="Next variation">▶</button>
        </form>
        <div className="st-row st-wrap" style={{ marginTop: 8 }}>
          {ideas.map((i) => <button key={i} className="st-chip" onClick={() => make(i)}>{i}</button>)}
          <button className="st-chip ghost" onClick={() => setIdeas(shuffle(SYNTH_IDEAS, 5))}>New ideas</button>
        </div>
      </section>
      <section className="st-panel st-col">
        <div className="st-row st-wrap">
          <h2 className="st-h2 st-grow">{patch.name} <span className="st-muted st-small">variation {seed}</span></h2>
          <span className="st-small st-muted">Octave {octave} (Z / X)</span>
          <button className="st-btn" onClick={() => midi.connect().catch((e) => host.toast(errText(e), true))}>{midi.name ? `MIDI: ${midi.name}` : 'Connect MIDI controller'}</button>
          <button className="st-btn primary" onClick={download}>Download instrument</button>
        </div>
        <div className="st-keys" aria-label="Keyboard">
          {whites.map((m, idx) => {
            const black = [1, 3, 6, 8, 10].includes(m % 12);
            return (
              <button key={m} className={`st-key${black ? ' black' : ''}${down.has(m) ? ' down' : ''}`} onPointerDown={() => noteOn(m)} onPointerUp={() => noteOff(m)} onPointerLeave={() => down.has(m) && noteOff(m)} aria-label={`${NOTE[m % 12]}${Math.floor(m / 12) - 1}`}>
                <span>{KEYS[idx]?.toUpperCase()}</span>
              </button>
            );
          })}
        </div>
        <div className="st-knobs">
          {knob('Cutoff', patch.filter.cutoff, 60, 16000, 10, (v) => setPatch({ ...patch, filter: { ...patch.filter, cutoff: v } }), (v) => `${Math.round(v)} Hz`)}
          {knob('Resonance', patch.filter.resonance, 0, 0.9, 0.01, (v) => setPatch({ ...patch, filter: { ...patch.filter, resonance: v } }))}
          {knob('Attack', patch.amp.a, 0.001, 2, 0.001, (v) => setPatch({ ...patch, amp: { ...patch.amp, a: v } }), (v) => `${v.toFixed(2)} s`)}
          {knob('Decay', patch.amp.d, 0.01, 3, 0.01, (v) => setPatch({ ...patch, amp: { ...patch.amp, d: v } }), (v) => `${v.toFixed(2)} s`)}
          {knob('Sustain', patch.amp.s, 0, 1, 0.01, (v) => setPatch({ ...patch, amp: { ...patch.amp, s: v } }))}
          {knob('Release', patch.amp.r, 0.01, 4, 0.01, (v) => setPatch({ ...patch, amp: { ...patch.amp, r: v } }), (v) => `${v.toFixed(2)} s`)}
          {knob('Drive', patch.drive, 0, 1, 0.01, (v) => setPatch({ ...patch, drive: v }))}
          {knob('Width', patch.spread, 0, 60, 1, (v) => setPatch({ ...patch, spread: v, unison: Math.max(patch.unison, v > 0 ? 3 : 1) }), (v) => `${Math.round(v)} ct`)}
          {knob('Reverb', patch.reverb.mix, 0, 1, 0.01, (v) => setPatch({ ...patch, reverb: { ...patch.reverb, mix: v } }))}
        </div>
        <p className="st-muted st-tiny">Play with your computer keys (A W S E D…), the on-screen keys or a MIDI controller. The download has samples every four semitones plus an .sfz file most samplers can open.</p>
      </section>
    </div>
  );
}

/** Drum Lab: describe a kit, get 16 playable pads; tweak each pad; download WAV + SFZ. */
export function DrumLab({ active = true }: { active?: boolean }) {
  const { host, engine } = useStudio();
  const [prompt, setPrompt] = useState('deep punchy techno kick-driven groove');
  const [kit, setKit] = useState<Kit>(() => kitFromPrompt('deep punchy techno kick-driven groove', 1));
  const [ideas, setIdeas] = useState(() => shuffle(DRUM_IDEAS, 5));
  const [sel, setSel] = useState(0);
  const [hit, setHit] = useState<number | null>(null);
  const voices = useVoices();
  const cache = useRef(new Map<string, Float32Array[]>());

  const make = (text: string, seed = 1) => { setPrompt(text); setKit(kitFromPrompt(text, seed)); cache.current.clear(); };
  const play = useCallback((i: number, vel = 1) => {
    void engine.resume();
    const p = kit.pads[i];
    const k = `${JSON.stringify(p)}:${vel.toFixed(1)}`;
    let ch = cache.current.get(k);
    if (!ch) { ch = renderPad(p, engine.ctx.sampleRate, vel); cache.current.set(k, ch); }
    voices.start(`pad${i}${p.type.includes('Hat') ? 'hat' : ''}`, ch, engine.ctx.sampleRate);
    setHit(i); setTimeout(() => setHit((h) => (h === i ? null : h)), 120);
  }, [kit, engine, voices]);
  const midi = useMidi((n, on, v) => { const i = kit.pads.findIndex((p) => p.note === n); if (on && i >= 0) play(i, v); });

  useEffect(() => {
    if (!active) return;
    const kd = (e: KeyboardEvent) => {
      if (typing(e) || e.repeat || e.metaKey || e.ctrlKey) return;
      const i = kit.pads.findIndex((p) => p.key === e.key.toLowerCase());
      if (i >= 0) { e.preventDefault(); play(i); setSel(i); }
    };
    window.addEventListener('keydown', kd);
    return () => window.removeEventListener('keydown', kd);
  }, [kit, play, active]);

  const pad = kit.pads[sel];
  const setPad = (patch: Partial<Pad>) => setKit({ ...kit, pads: kit.pads.map((p, i) => (i === sel ? { ...p, ...patch, env: { ...p.env, ...(patch.env ?? {}) } } : p)) });
  const download = async () => {
    try {
      const files = kitFiles(kit, 44100);
      const where = await host.saveFiles(kit.name, files);
      if (where) host.toast(`Saved ${kit.pads.length} drum samples and an SFZ kit.`);
    } catch (e) { host.toast(errText(e), true); }
  };
  const knob = (label: string, value: number, min: number, max: number, step: number, set: (v: number) => void, fmt = (v: number) => v.toFixed(2)) => (
    <label className="st-field">{label} <span className="st-mono">{fmt(value)}</span><input type="range" min={min} max={max} step={step} value={value} onChange={(e) => { set(Number(e.target.value)); }} onPointerUp={() => play(sel)} aria-label={`${pad.name} ${label}`} /></label>
  );

  return (
    <div className="st-col">
      <section className="st-panel">
        <h2 className="st-h2">Describe a drum kit</h2>
        <form className="st-row" onSubmit={(e) => { e.preventDefault(); make(prompt); }}>
          <input className="st-input st-grow" value={prompt} onChange={(e) => setPrompt(e.target.value)} placeholder="e.g. crisp trap kit with booming 808" aria-label="Describe the kit" />
          <button className="st-btn primary" disabled={!prompt.trim()}>Make it</button>
          <button type="button" className="st-btn" onClick={() => make(prompt, Math.max(1, kit.seed - 1))} aria-label="Previous variation">◀</button>
          <button type="button" className="st-btn" onClick={() => make(prompt, kit.seed + 1)} aria-label="Next variation">▶</button>
        </form>
        <div className="st-row st-wrap" style={{ marginTop: 8 }}>
          {ideas.map((i) => <button key={i} className="st-chip" onClick={() => make(i)}>{i}</button>)}
          <button className="st-chip ghost" onClick={() => setIdeas(shuffle(DRUM_IDEAS, 5))}>New ideas</button>
        </div>
      </section>
      <div className="st-grid2">
        <section className="st-panel">
          <div className="st-row"><h2 className="st-h2 st-grow">{kit.name} <span className="st-muted st-small">variation {kit.seed}</span></h2>
            <button className="st-btn" onClick={() => midi.connect().catch((e) => host.toast(errText(e), true))}>{midi.name ? 'MIDI on' : 'MIDI controller'}</button>
            <button className="st-btn primary" onClick={download}>Download kit</button></div>
          <div className="st-pads">
            {kit.pads.map((p, i) => (
              <button key={i} className={`st-pad${sel === i ? ' sel' : ''}${hit === i ? ' hit' : ''}`} onPointerDown={() => { play(i); setSel(i); }} aria-label={`${p.name} (key ${p.key.toUpperCase()})`}>
                <b>{p.name}</b><span className="st-mono">{p.key.toUpperCase()}</span>
              </button>
            ))}
          </div>
          <p className="st-muted st-tiny">Keys Z X C V / A S D F / Q W E R / 1 2 3 4, or MIDI notes 36–51.</p>
        </section>
        <section className="st-panel st-col">
          <h2 className="st-h2">{pad.name}</h2>
          <div className="st-knobs">
            {knob('Pitch', pad.pitch, 20, 2000, 1, (v) => setPad({ pitch: v }), (v) => `${Math.round(v)} Hz`)}
            {knob('Decay', pad.decay, 0.01, 2, 0.01, (v) => setPad({ decay: v, env: { ...pad.env, d: v } }), (v) => `${v.toFixed(2)} s`)}
            {knob('Attack', pad.env.a, 0.0005, 0.05, 0.0005, (v) => setPad({ env: { ...pad.env, a: v } }), (v) => `${(v * 1000).toFixed(1)} ms`)}
            {knob('Tone', pad.tone, 0, 1, 0.01, (v) => setPad({ tone: v }))}
            {knob('Noise', pad.noise, 0, 1, 0.01, (v) => setPad({ noise: v }))}
            {knob('Drive', pad.drive, 0, 1, 0.01, (v) => setPad({ drive: v }))}
            {knob('Room', pad.room, 0, 1, 0.01, (v) => setPad({ room: v }))}
            {knob('Volume', pad.volume, 0, 1.5, 0.01, (v) => setPad({ volume: v }))}
          </div>
        </section>
      </div>
    </div>
  );
}
