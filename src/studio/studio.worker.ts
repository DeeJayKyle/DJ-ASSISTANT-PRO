/// <reference lib="webworker" />
import { separatePart } from './audio/stems';
import { rhythm } from './audio/beats';
import { detectChords } from './audio/chords';
import { transcribePitched, transcribeDrums, chordNotes, writeMidi } from './audio/midi';
import { mono } from './audio/wav';
import { renderProject, clearRenderCache, type Project, type Source } from './remix';

/** Heavy work off the UI thread: separation parts, analysis, MIDI and remix rendering. */
const sources = new Map<string, Source>();
const transfer = (arrs: Float32Array[]) => arrs.map((a) => a.buffer as ArrayBuffer);

self.onmessage = (e: MessageEvent) => {
  const m = e.data;
  const reply = (result: unknown, buffers: ArrayBuffer[] = []) => (self as unknown as Worker).postMessage({ id: m.id, result }, buffers);
  try {
    switch (m.type) {
      case 'separatePart': {
        const part = separatePart(m.channels, m.inStart, m.len, m.sampleRate, m.f0, m.f1, (f) => (self as unknown as Worker).postMessage({ id: m.id, progress: f }));
        const bufs = [...Object.values(part.stems).flatMap((ch) => transfer(ch)), part.norm.buffer as ArrayBuffer];
        reply(part, bufs);
        break;
      }
      case 'analyse': {
        const r = rhythm(m.mono, m.sampleRate, m.bpm);
        reply({ ...r, chords: detectChords(m.mono, m.sampleRate) });
        break;
      }
      case 'midi': {
        const tracks = [];
        if (m.bass) tracks.push({ name: 'Bass', channel: 0, program: 33, notes: transcribePitched(m.bass, m.sampleRate, { minHz: 30, maxHz: 350 }) });
        if (m.melodies) tracks.push({ name: 'Melody', channel: 1, program: 80, notes: transcribePitched(m.melodies, m.sampleRate, { minHz: 120, maxHz: 1400 }) });
        if (m.vocals) tracks.push({ name: 'Vocal melody', channel: 2, program: 53, notes: transcribePitched(m.vocals, m.sampleRate, { minHz: 80, maxHz: 1100 }) });
        if (m.chords?.length) tracks.push({ name: 'Chords', channel: 3, program: 0, notes: chordNotes(m.chords) });
        if (m.drums) tracks.push({ name: 'Drums', channel: 9, notes: transcribeDrums(m.drums, m.sampleRate) });
        const bytes = writeMidi(tracks, m.bpm || 120);
        reply({ bytes, counts: tracks.map((t) => ({ name: t.name, notes: t.notes.length })) }, [bytes.buffer as ArrayBuffer]);
        break;
      }
      case 'addSource': sources.set(m.source.id, m.source); clearRenderCache(); reply(true); break;
      case 'removeSource': sources.delete(m.sourceId); clearRenderCache(); reply(true); break;
      case 'render': {
        const { mix, tracks } = renderProject(m.project as Project, sources, m.sampleRate);
        const trackList = m.withTracks ? [...tracks.entries()] : [];
        reply({ mix, tracks: trackList }, [...transfer(mix), ...trackList.flatMap(([, ch]) => transfer(ch))]);
        break;
      }
      case 'mono': reply(mono(m.channels)); break;
      default: reply(null);
    }
  } catch (err) {
    (self as unknown as Worker).postMessage({ id: m.id, error: String((err as Error)?.message ?? err) });
  }
};
