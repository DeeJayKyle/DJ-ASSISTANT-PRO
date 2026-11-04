import { useState } from "react";
import type { Crate, Root, Stats } from "../types";
import { Icon } from "./Icon";
import { ColorDot } from "./ui";

export type View =
  | "library" | "quick" | "organize" | "crates" | "duplicates" | "health" | "activity" | "suggestions" | "discovery" | "set-studio" | "gig" | "gig-pack"
  | "files" | "settings" | `crate:${number}` | `root:${number}`;

function CrateTree({ crates, parent, depth, view, setView }: { crates: Crate[]; parent: number | null; depth: number; view: View; setView: (v: View) => void }) {
  const [open, setOpen] = useState<Record<number, boolean>>({});
  const kids = crates.filter((c) => (c.parent_id ?? null) === parent);
  return (
    <>
      {kids.map((c) => {
        const hasKids = crates.some((x) => x.parent_id === c.id);
        const isOpen = open[c.id] ?? false;
        return (
          <div key={c.id}>
            <button className="nav-item small" aria-current={view === `crate:${c.id}` ? "page" : undefined} onClick={() => setView(`crate:${c.id}`)} style={{ paddingLeft: 12 + depth * 14 }}>
              {hasKids ? (
                <span role="button" aria-label={isOpen ? "Collapse" : "Expand"} onClick={(e) => { e.stopPropagation(); setOpen({ ...open, [c.id]: !isOpen }); }} style={{ display: "inline-flex" }}>
                  <Icon name={isOpen ? "down" : "right"} size={14} />
                </span>
              ) : c.color ? (
                <ColorDot color={c.color} />
              ) : (
                <Icon name="crate" size={16} />
              )}
              <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{c.name}</span>
              {c.kind === "smart" && <span className="crate-kind">smart</span>}
              <span className="count">{c.track_count || ""}</span>
            </button>
            {hasKids && isOpen && <CrateTree crates={crates} parent={c.id} depth={depth + 1} view={view} setView={setView} />}
          </div>
        );
      })}
    </>
  );
}

export function Sidebar({ view, setView, crates, roots, stats, pending, onNewCrate, docsEnabled }: {
  view: View; setView: (v: View) => void; crates: Crate[]; roots: Root[]; stats: Stats | null; pending: number; onNewCrate: () => void; docsEnabled: boolean;
}) {
  const [sourcesOpen, setSourcesOpen] = useState(true);
  const problems = stats ? stats.errors + stats.missing + stats.low_bitrate : 0;
  const item = (v: View, icon: string, label: string, count?: React.ReactNode, warn?: boolean) => (
    <button className="nav-item" aria-current={view === v ? "page" : undefined} onClick={() => setView(v)}>
      <Icon name={icon} size={20} />
      {label}
      {count != null && count !== 0 && <span className={`count${warn ? " warn" : ""}`}>{count}</span>}
    </button>
  );
  return (
    <nav className="sidebar" aria-label="Main">
      <div className="nav">
        {item("quick", "zap", "Quick Prep")}
        {item("library", "library", "Library", stats?.tracks.toLocaleString())}
        {item("crates", "crate", "Virtual Crates", crates.length || undefined)}
        {item("duplicates", "dup", "Duplicate Review")}
        {item("activity", "refresh", "Scan Activity")}
        {item("health", "health", "Library Health", problems || undefined, problems > 0)}
        {item("organize", "wrench", "Organise Files")}
      </div>
      <div className="nav-section">Prepare</div>
      <div className="nav">
        {item("set-studio", "set", "Set Studio")}
        {item("discovery", "compass", "Discovery")}
        {item("suggestions", "wand", "Suggestions", pending || undefined)}
        {item("gig", "gig", "Gig Mode")}
        {item("gig-pack", "usb", "Gig Pack")}
      </div>
      <div className="nav-section">
        <span>My crates</span>
        <button className="btn ghost small icon" onClick={onNewCrate} aria-label="New crate" title="New crate">
          <Icon name="plus" size={16} />
        </button>
      </div>
      <div className="nav">
        {crates.length === 0 && <p className="small faint" style={{ padding: "0 12px", margin: 0 }}>No crates yet. Try a template under Virtual Crates.</p>}
        <CrateTree crates={crates} parent={null} depth={0} view={view} setView={setView} />
      </div>
      <div className="nav-section">
        <span>Sources</span>
        <button className="btn ghost small icon" aria-label={sourcesOpen ? "Collapse sources" : "Expand sources"} onClick={() => setSourcesOpen(!sourcesOpen)}>
          <Icon name={sourcesOpen ? "down" : "right"} size={16} />
        </button>
      </div>
      {sourcesOpen && (
        <div className="nav">
          {roots.map((r) => (
            <button key={r.id} className="nav-item small" aria-current={view === `root:${r.id}` ? "page" : undefined} onClick={() => setView(`root:${r.id}`)} title={r.path}>
              <Icon name="drive" size={18} />
              <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r.label ?? r.path}</span>
              <span className={`status-dot ${r.status}`} style={{ marginLeft: "auto" }} aria-label={r.status} />
            </button>
          ))}
          {roots.length === 0 && (
            <button className="nav-item small" onClick={() => setView("activity")}>
              <Icon name="plus" size={16} /> Add a music folder
            </button>
          )}
        </div>
      )}
      <div className="spacer" />
      <div className="nav-sep" />
      <div className="nav">
        {docsEnabled && item("files", "file", "Personal Files")}
        {item("settings", "settings", "Settings")}
      </div>
    </nav>
  );
}
