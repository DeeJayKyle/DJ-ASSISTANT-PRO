import { useEffect, useRef, useState, type ReactNode } from "react";
import { Icon } from "./Icon";
import { QUALITY_LABEL, STATUS_LABEL } from "../lib/format";
import type { TrackRow } from "../types";

export function Dialog({ title, onClose, children, footer, narrow }: { title: ReactNode; onClose: () => void; children: ReactNode; footer?: ReactNode; narrow?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const prev = document.activeElement as HTMLElement | null;
    const first = ref.current?.querySelector<HTMLElement>("input, select, textarea, button:not([data-close])");
    first?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeRef.current();
    };
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("keydown", onKey);
      prev?.focus?.();
    };
  }, []);
  return (
    <div className="backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className={`dialog${narrow ? " narrow" : ""}`} role="dialog" aria-modal="true" aria-label={typeof title === "string" ? title : undefined} ref={ref}>
        <div className="dialog-head">
          <h2 style={{ flex: 1 }}>{title}</h2>
          <button className="btn ghost icon" onClick={onClose} aria-label="Close" data-close>
            <Icon name="close" />
          </button>
        </div>
        <div className="dialog-body">{children}</div>
        {footer && <div className="dialog-foot">{footer}</div>}
      </div>
    </div>
  );
}

export function EnergyMeter({ value, onChange, big, estimate }: { value: number | null; onChange?: (v: number | null) => void; big?: boolean; estimate?: boolean }) {
  if (value == null && !onChange) return <span className="unknown-energy" title="Energy not rated yet">—</span>;
  const segs = Array.from({ length: 10 }, (_, i) => i + 1);
  const tone = (i: number) => (i <= 4 ? "lo" : i <= 7 ? "mid" : "hi");
  return (
    <span
      className={`meter${big ? " big" : ""}${onChange ? " edit" : ""}${estimate ? " est" : ""}`}
      title={estimate ? "Estimated by local analysis — set your own value in the track details" : undefined}
      role={onChange ? "slider" : "img"}
      aria-label={value == null ? "Energy not rated" : `Energy ${value} of 10${estimate ? " (estimate)" : ""}`}
      aria-valuemin={onChange ? 1 : undefined}
      aria-valuemax={onChange ? 10 : undefined}
      aria-valuenow={onChange ? (value ?? undefined) : undefined}
      tabIndex={onChange ? 0 : undefined}
      onKeyDown={
        onChange
          ? (e) => {
              if (e.key === "ArrowRight" || e.key === "ArrowUp") onChange(Math.min(10, (value ?? 0) + 1));
              if (e.key === "ArrowLeft" || e.key === "ArrowDown") onChange(value == null || value <= 1 ? null : value - 1);
              if (e.key === "Delete" || e.key === "Backspace") onChange(null);
            }
          : undefined
      }
    >
      {segs.map((i) => (
        <i key={i} className={value != null && i <= value ? `on ${tone(i)}` : ""} onClick={onChange ? () => onChange(value === i ? null : i) : undefined} />
      ))}
    </span>
  );
}

export function Stars({ value }: { value: number | null }) {
  if (value == null) return <span className="faint">—</span>;
  return (
    <span className="stars" aria-label={`${value} of 5 stars`}>
      {"★".repeat(value)}
      <span className="off">{"★".repeat(5 - value)}</span>
    </span>
  );
}

export function QualityBadge({ t }: { t: Pick<TrackRow, "quality" | "bitrate_kbps"> }) {
  const title =
    t.quality === "low_bitrate"
      ? `Lossy, average/nominal bitrate ${t.bitrate_kbps} kbps is under your threshold. Bitrate alone does not prove quality.`
      : t.quality === "unknown"
        ? "Bitrate or codec unknown — not flagged."
        : t.quality === "lossless"
          ? "Lossless codec (bitrate rule does not apply)."
          : `Lossy, ${t.bitrate_kbps} kbps reported.`;
  return (
    <span className={`badge q-${t.quality}`} title={title}>
      {QUALITY_LABEL[t.quality]}
    </span>
  );
}

export function StatusText({ s }: { s: string }) {
  if (s === "ok") return null;
  return <span className={`small s-${s}`}>{STATUS_LABEL[s] ?? s}</span>;
}

export function ColorDot({ color }: { color: string | null }) {
  return <span className={`crate-dot${color ? ` c-${color}` : ""}`} aria-hidden />;
}

export const COLORS = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "grey"];

export function ColorPicker({ value, onChange }: { value: string | null; onChange: (c: string | null) => void }) {
  return (
    <div className="color-pick" role="group" aria-label="Colour">
      <button type="button" className="none" aria-pressed={value == null} onClick={() => onChange(null)} title="No colour">
        ∅
      </button>
      {COLORS.map((c) => (
        <button type="button" key={c} className={`c-${c}`} aria-pressed={value === c} aria-label={c} title={c} onClick={() => onChange(c)} />
      ))}
    </div>
  );
}

export function useDebounced<T>(value: T, ms: number): T {
  const [v, setV] = useState<T>(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}
