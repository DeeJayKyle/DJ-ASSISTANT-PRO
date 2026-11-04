import type { AnalysisInfo } from "../types";
import { duration } from "../lib/format";

/** Overview waveform with suggested cue points (estimates). */
export function Waveform({ a }: { a: AnalysisInfo }) {
  const w = a.waveform ?? [];
  if (!w.length) return null;
  const W = 800;
  const H = 64;
  const dur = a.duration_ms ?? 1;
  const x = (ms: number) => (ms / dur) * W;
  return (
    <svg className="waveform wave-reveal" viewBox={`0 0 ${W} ${H + 12}`} preserveAspectRatio="none" role="img" aria-label="Waveform overview with suggested cue points">
      {w.map((v, i) => {
        const h = Math.max(1, (v / 255) * H);
        return <rect key={i} className="bar" x={(i / w.length) * W} y={(H - h) / 2} width={Math.max(0.6, W / w.length - 0.3)} height={h} />;
      })}
      {a.cues.map((c) => (
        <g key={c.label + c.ms}>
          <line className="cue" x1={x(c.ms)} x2={x(c.ms)} y1={0} y2={H} />
          <title>{`${c.label} at ${duration(c.ms)}`}</title>
        </g>
      ))}
    </svg>
  );
}
