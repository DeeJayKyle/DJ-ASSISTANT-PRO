import type { Crate, Stats } from "../types";
import { Icon, Logo } from "./Icon";
import { ColorDot } from "./ui";

export type View = "library" | "health" | "duplicates" | "folders" | "settings" | "roadmap" | `crate:${number}`;

export function Sidebar({ view, setView, crates, stats, onNewCrate }: { view: View; setView: (v: View) => void; crates: Crate[]; stats: Stats | null; onNewCrate: () => void }) {
  const problems = stats ? stats.errors + stats.missing + stats.low_bitrate : 0;
  const item = (v: View, icon: string, label: string, count?: React.ReactNode, warn?: boolean) => (
    <button className="nav-item" aria-current={view === v ? "page" : undefined} onClick={() => setView(v)}>
      <Icon name={icon} />
      {label}
      {count != null && <span className={`count${warn ? " warn" : ""}`}>{count}</span>}
    </button>
  );
  const groups = new Map<string, Crate[]>();
  for (const c of crates) {
    const k = c.category ?? "";
    groups.set(k, [...(groups.get(k) ?? []), c]);
  }
  return (
    <nav className="sidebar" aria-label="Main">
      <div className="brand">
        <Logo />
        <div>
          <div className="brand-name">DJ Assistant</div>
          <div className="brand-sub">Herbie’s library</div>
        </div>
      </div>
      <div className="nav">
        {item("library", "library", "Library", stats?.tracks.toLocaleString())}
        {item("health", "health", "Library health", problems > 0 ? problems.toLocaleString() : undefined, problems > 0)}
        {item("duplicates", "dup", "Duplicates")}
        {item("folders", "folder", "Folders", stats?.roots)}
      </div>
      <div className="nav-section">
        <span>Crates</span>
        <button className="btn ghost small icon" onClick={onNewCrate} aria-label="New crate" title="New crate">
          <Icon name="plus" size={14} />
        </button>
      </div>
      <div className="crate-list">
        {crates.length === 0 && <p className="small faint" style={{ padding: "0 10px" }}>No crates yet. Crates are virtual: tracks are never copied or moved.</p>}
        {[...groups.entries()].map(([cat, cs]) => (
          <div key={cat}>
            {cat && <div className="small faint" style={{ padding: "8px 10px 2px" }}>{cat}</div>}
            {cs.map((c) => (
              <button key={c.id} className="nav-item" aria-current={view === `crate:${c.id}` ? "page" : undefined} onClick={() => setView(`crate:${c.id}`)}>
                <ColorDot color={c.color} />
                <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{c.name}</span>
                {c.kind === "smart" && <span className="crate-kind">smart</span>}
                <span className="count">{c.track_count}</span>
              </button>
            ))}
          </div>
        ))}
      </div>
      <div className="nav" style={{ borderTop: "1px solid var(--line-soft)", paddingTop: 6, paddingBottom: 8 }}>
        {item("roadmap", "map", "Coming later")}
        {item("settings", "settings", "Settings")}
      </div>
    </nav>
  );
}
