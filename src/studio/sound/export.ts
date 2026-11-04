import { encodeWav } from '../audio/wav';
import { renderNote, type Patch } from './synth';
import { renderPad, type Kit } from './drums';

/**
 * Downloads for instruments and kits: one WAV per sample plus an SFZ file, an open text format
 * that most samplers and DAWs can load (and the patch/kit JSON so it can be reopened here).
 */
export interface OutFile { name: string; bytes: Uint8Array }
const safe = (s: string) => s.replace(/[\\/:*?"<>|]/g, ' ').replace(/\s+/g, ' ').trim() || 'Sound';
const text = (s: string) => new TextEncoder().encode(s);
const NOTE = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
const noteName = (m: number) => `${NOTE[m % 12]}${Math.floor(m / 12) - 1}`;

export function instrumentFiles(patch: Patch, sampleRate = 44100): OutFile[] {
  const files: OutFile[] = [];
  const regions: string[] = [];
  const roots = [];
  for (let m = 36; m <= 84; m += 4) roots.push(m);
  roots.forEach((m, i) => {
    const name = `samples/${safe(patch.name)} ${noteName(m)}.wav`;
    files.push({ name, bytes: encodeWav(renderNote(patch, m, 1.6, sampleRate), sampleRate) });
    const lo = i === 0 ? 0 : m - 1, hi = i === roots.length - 1 ? 127 : m + 2;
    regions.push(`<region> sample=${name.replace('samples/', 'samples\\')} pitch_keycenter=${m} lokey=${lo} hikey=${hi}`);
  });
  files.push({ name: `${safe(patch.name)}.sfz`, bytes: text(`// ${patch.name}\n<group> ampeg_release=${patch.amp.r.toFixed(3)}\n${regions.join('\n')}\n`) });
  files.push({ name: `${safe(patch.name)}.patch.json`, bytes: text(JSON.stringify(patch, null, 2)) });
  return files;
}

export function kitFiles(kit: Kit, sampleRate = 44100): OutFile[] {
  const files: OutFile[] = kit.pads.map((p, i) => ({ name: `${String(i + 1).padStart(2, '0')} ${safe(p.name)}.wav`, bytes: encodeWav(renderPad(p, sampleRate), sampleRate) }));
  const sfz = kit.pads.map((p, i) => `<region> sample=${files[i].name} key=${p.note} loop_mode=one_shot`).join('\n');
  files.push({ name: `${safe(kit.name)}.sfz`, bytes: text(`// ${kit.name} — notes ${kit.pads[0].note}–${kit.pads[kit.pads.length - 1].note}\n${sfz}\n`) });
  files.push({ name: `${safe(kit.name)}.kit.json`, bytes: text(JSON.stringify(kit, null, 2)) });
  return files;
}
