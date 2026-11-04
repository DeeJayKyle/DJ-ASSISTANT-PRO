import { useEffect, useRef, useState } from "react";
import { api, trackUrl } from "../../api";
import { Icon } from "../Icon";

/** One shared preview player: starting a track stops the last one. Read-only streaming by track id. */
const audio = typeof Audio !== "undefined" ? new Audio() : null;
let current: number | null = null;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((f) => f());
if (audio) for (const ev of ["play", "pause", "ended", "timeupdate", "error"]) audio.addEventListener(ev, notify);

export function stopPreview() {
  audio?.pause();
  current = null;
  notify();
}

export function usePlayer() {
  const [, tick] = useState(0);
  useEffect(() => {
    const f = () => tick((n) => n + 1);
    listeners.add(f);
    return () => { listeners.delete(f); };
  }, []);
  return {
    playing: (id: number) => current === id && !!audio && !audio.paused,
    progress: (id: number) => (current === id && audio && audio.duration ? audio.currentTime / audio.duration : 0),
    toggle(id: number, startAt?: number) {
      if (!audio) return;
      if (current === id && startAt == null) {
        if (audio.paused) void audio.play().catch(() => {});
        else audio.pause();
        return;
      }
      if (current !== id) {
        current = id;
        audio.src = trackUrl(id);
        // Start a third of the way in, where the groove usually is.
        audio.addEventListener("loadedmetadata", () => { if (current === id && audio.duration > 60) audio.currentTime = audio.duration * (startAt ?? 0.33); else if (current === id && startAt != null) audio.currentTime = audio.duration * startAt; }, { once: true });
      } else if (startAt != null && audio.duration) audio.currentTime = audio.duration * startAt;
      void audio.play().catch(() => {});
    },
  };
}

export function PlayButton({ id, label }: { id: number; label: string }) {
  const p = usePlayer();
  const on = p.playing(id);
  return (
    <button className={`btn small icon qp-play${on ? " on" : ""}`} onClick={(e) => { e.stopPropagation(); p.toggle(id); }} aria-label={`${on ? "Pause" : "Play"} ${label}`}>
      <Icon name={on ? "pause" : "play"} size={14} />
    </button>
  );
}

const waveCache = new Map<number, number[]>();

/** The track's waveform from analysis; click to jump there. */
export function WaveBar({ id, label, height = 44 }: { id: number; label: string; height?: number }) {
  const [w, setW] = useState<number[] | null>(waveCache.get(id) ?? null);
  const ref = useRef<HTMLDivElement>(null);
  const p = usePlayer();
  useEffect(() => {
    if (waveCache.has(id)) { setW(waveCache.get(id)!); return; }
    let live = true;
    api.trackDetail(id).then((d) => { const v = d.analysis?.waveform ?? []; waveCache.set(id, v); if (live) setW(v); }).catch(() => live && setW([]));
    return () => { live = false; };
  }, [id]);
  const prog = p.progress(id);
  if (!w || !w.length) return <div className="qp-wave empty small faint" style={{ height }}>{w ? "No waveform yet" : "…"}</div>;
  return (
    <div
      ref={ref} className="qp-wave" style={{ height }} role="slider" tabIndex={0} aria-label={`Position in ${label}`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(prog * 100)}
      onClick={(e) => { const r = e.currentTarget.getBoundingClientRect(); p.toggle(id, (e.clientX - r.left) / r.width); }}
      onKeyDown={(e) => { if (e.key === " " || e.key === "Enter") { e.preventDefault(); p.toggle(id); } }}
    >
      {w.map((v, i) => <i key={i} className={i / w.length < prog ? "on" : ""} style={{ height: `${Math.max(4, (v / 255) * 100)}%` }} />)}
    </div>
  );
}
