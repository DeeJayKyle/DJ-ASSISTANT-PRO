import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { RuleNode } from "../types";
import { Icon } from "./Icon";

export interface QuickOption {
  label: string;
  node: RuleNode;
  count?: number;
}

/** A filter button with a menu of options ("Genre ▾"). One option active at a time. */
export function FilterDropdown({ label, facet, options, active, onPick }: {
  label: string;
  facet?: string;
  options?: QuickOption[];
  active: QuickOption | null;
  onPick: (o: QuickOption | null) => void;
}) {
  const [open, setOpen] = useState(false);
  const [opts, setOpts] = useState<QuickOption[]>(options ?? []);
  const ref = useRef<HTMLSpanElement>(null);
  useEffect(() => {
    if (!open || !facet) return;
    api.facet(facet).then((v) =>
      setOpts(
        v.map(([val, n]) => ({
          label: facet === "decade" ? `${val}s` : val,
          count: n,
          node: facet === "decade" ? { kind: "condition", field: "decade", op: "eq", value: Number(val) } : { kind: "condition", field: facet, op: "equals", value: val },
        })),
      ),
    );
  }, [open, facet]);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => !ref.current?.contains(e.target as Node) && setOpen(false);
    window.addEventListener("mousedown", close);
    return () => window.removeEventListener("mousedown", close);
  }, [open]);
  return (
    <span className="rel" ref={ref}>
      <button className={`dropdown-btn${active ? " on" : ""}`} aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)}>
        {active ? `${label}: ${active.label}` : label} <Icon name="down" size={16} />
      </button>
      {open && (
        <div className="menu" role="menu">
          {active && (
            <button role="menuitem" onClick={() => { onPick(null); setOpen(false); }}>
              <Icon name="close" size={14} /> Any {label.toLowerCase()}
            </button>
          )}
          {opts.length === 0 && <div className="small muted" style={{ padding: 10 }}>Nothing to choose yet</div>}
          {opts.map((o) => (
            <button key={o.label} role="menuitem" aria-checked={active?.label === o.label} onClick={() => { onPick(o); setOpen(false); }}>
              {active?.label === o.label ? <Icon name="check" size={14} /> : <span style={{ width: 14 }} />}
              {o.label}
              {o.count != null && <span className="count">{o.count}</span>}
            </button>
          ))}
        </div>
      )}
    </span>
  );
}

export const FORMAT_OPTIONS: QuickOption[] = ["MP3", "FLAC", "WAV", "AIFF", "M4A (AAC)", "M4A (ALAC)", "Ogg Vorbis", "Opus"].map((f) => ({
  label: f,
  node: { kind: "condition", field: "format", op: "equals", value: f },
}));

export const QUALITY_OPTIONS: QuickOption[] = [
  { label: "Low bitrate", node: { kind: "condition", field: "quality", op: "equals", value: "low_bitrate" } },
  { label: "Lossy", node: { kind: "condition", field: "quality", op: "equals", value: "lossy" } },
  { label: "Lossless", node: { kind: "condition", field: "quality", op: "equals", value: "lossless" } },
  { label: "Unknown", node: { kind: "condition", field: "quality", op: "equals", value: "unknown" } },
];
