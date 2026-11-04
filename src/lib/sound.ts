// Completion sounds, synthesised with Web Audio (no sound files, works offline).
// Each kind of task has its own short motif so you can tell them apart by ear.

export type SoundKind = "scan" | "analysis" | "prep" | "export" | "saved" | "ai" | "error";

let ctx: AudioContext | null = null;
let enabled = true;
let volume = 0.6;

export function configureSounds(on: boolean | undefined, vol: number | undefined) {
  enabled = on ?? true;
  volume = Math.min(1, Math.max(0, vol ?? 0.6));
}

const MOTIFS: Record<SoundKind, Array<[number, number, number]>> = {
  // [frequency Hz, start s, length s]
  scan: [[659.25, 0, 0.14], [880, 0.1, 0.22]],                         // E5 → A5
  analysis: [[523.25, 0, 0.12], [659.25, 0.09, 0.12], [783.99, 0.18, 0.26]], // C E G
  prep: [[587.33, 0, 0.12], [739.99, 0.09, 0.12], [880, 0.18, 0.12], [1174.66, 0.27, 0.32]], // D F# A D
  export: [[783.99, 0, 0.12], [1046.5, 0.1, 0.3]],                     // G5 → C6
  saved: [[987.77, 0, 0.12]],                                          // B5 blip
  ai: [[698.46, 0, 0.1], [880, 0.07, 0.18]],                           // F5 → A5
  error: [[392, 0, 0.18], [311.13, 0.14, 0.3]],                        // G4 → Eb4
};

export function playSound(kind: SoundKind) {
  if (!enabled || volume <= 0) return;
  try {
    ctx = ctx ?? new AudioContext();
    if (ctx.state === "suspended") void ctx.resume();
    const now = ctx.currentTime + 0.01;
    const master = ctx.createGain();
    master.gain.value = 0.18 * volume;
    master.connect(ctx.destination);
    for (const [f, t, len] of MOTIFS[kind]) {
      const o = ctx.createOscillator();
      const o2 = ctx.createOscillator();
      const g = ctx.createGain();
      o.type = kind === "error" ? "triangle" : "sine";
      o2.type = "sine";
      o.frequency.value = f;
      o2.frequency.value = f * 2; // soft bell overtone
      const g2 = ctx.createGain();
      g2.gain.value = 0.18;
      o.connect(g);
      o2.connect(g2).connect(g);
      g.connect(master);
      g.gain.setValueAtTime(0.0001, now + t);
      g.gain.exponentialRampToValueAtTime(1, now + t + 0.012);
      g.gain.exponentialRampToValueAtTime(0.0001, now + t + len);
      o.start(now + t);
      o2.start(now + t);
      o.stop(now + t + len + 0.05);
      o2.stop(now + t + len + 0.05);
    }
  } catch {
    // No audio device: stay silent.
  }
}

/** Which sound a finished background job should make. */
export function soundForJob(kind: string, failed: boolean): SoundKind {
  if (failed) return "error";
  if (kind === "auto_prep") return "prep";
  if (kind === "analysis") return "analysis";
  if (kind === "gigpack" || kind === "crate_export") return "export";
  return "saved";
}
