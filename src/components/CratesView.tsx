import { Fragment, useEffect, useState } from "react";
import { api } from "../api";
import type { Crate, CrateTemplate, Labels } from "../types";
import { plural } from "../lib/format";
import { Icon } from "./Icon";
import { ColorDot } from "./ui";
import type { View } from "./Sidebar";

export function CratesView({ crates, version, bump, toast, setView, onNewCrate }: { crates: Crate[]; version: number; bump: () => void; toast: (m: string, e?: boolean) => void; setView: (v: View) => void; onNewCrate: () => void }) {
  const [templates, setTemplates] = useState<CrateTemplate[]>([]);
  const [labels, setLabels] = useState<Labels | null>(null);
  const [hyg, setHyg] = useState<Awaited<ReturnType<typeof api.crateHygiene>> | null>(null);
  const [genre, setGenre] = useState("Afrobeats");
  useEffect(() => {
    api.crateTemplates().then(setTemplates);
    api.labels().then(setLabels);
    api.crateHygiene().then(setHyg);
  }, [version]);
  const apply = (t: CrateTemplate) =>
    api
      .applyTemplate(t.id, t.needs_genre ? genre : null)
      .then((r) => { toast(r.created ? `Added ${plural(r.created, "crate")} under “${r.parent}”.` : `“${r.parent}” already has these crates.`); bump(); })
      .catch((e) => toast(e.message, true));
  const top = crates.filter((c) => c.parent_id == null);
  return (
    <div className="page">
      <div className="view-head">
        <div className="grow">
          <h1>Virtual Crates</h1>
          <div className="sub">Crates live in DJ Assistant only. A track can be in many crates; files are never copied or moved.</div>
        </div>
        <button className="btn" onClick={() => api.colourByEnergy(true).then((r) => { toast(`Coloured ${plural(r.updated, "track")} by energy.`); bump(); })}>
          <Icon name="palette" size={16} /> Colour tracks by energy
        </button>
        <button className="btn primary" onClick={onNewCrate}><Icon name="plus" size={18} /> New crate</button>
      </div>
      <div className="view-body">
        {hyg && (hyg.issues.length > 0 || hyg.untagged_unrated > 0) && (
          <div className="notice warn" style={{ marginBottom: 16 }}>
            <Icon name="warn" />
            <div>
              <strong>Avoid this:</strong> unorganised crates mean missed moments.
              {hyg.issues.map((i) => <div key={i.crate_id + i.issue}>“{i.crate}” — {i.issue}. {i.advice}</div>)}
              {hyg.untagged_unrated > 0 && <div>{plural(hyg.untagged_unrated, "track")} have no tags or rating yet.</div>}
            </div>
          </div>
        )}
        <h2 style={{ margin: "4px 0 12px" }}>Start from a template</h2>
        <div className="grid-cards stagger" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(290px, 1fr))" }}>
          {templates.map((t) => (
            <div key={t.id} className="card template-card">
              <div className="row"><Icon name="template" size={18} /><h3 style={{ margin: 0, flex: 1 }}>{t.name}</h3></div>
              <p className="small muted" style={{ margin: 0 }}>{t.description}</p>
              <ul>{t.crates.slice(0, 10).map((c) => <li key={c}>{c}</li>)}</ul>
              <div className="row">
                {t.needs_genre && <input className="input" style={{ flex: 1, height: 32 }} aria-label="Genre for template" value={genre} onChange={(e) => setGenre(e.target.value)} />}
                <button className="btn small primary" onClick={() => apply(t)}>Add crates</button>
              </div>
            </div>
          ))}
        </div>
        <div className="grid2" style={{ marginTop: 20 }}>
          <div className="panel">
            <h2 style={{ marginBottom: 10 }}>Your crates</h2>
            {top.length === 0 && <p className="muted">No crates yet.</p>}
            <div className="list">
              {top.map((c) => {
                const kids = crates.filter((k) => k.parent_id === c.id);
                return (
                  <div key={c.id} className="list-row">
                    <ColorDot color={c.color} />
                    <button className="btn ghost small" onClick={() => setView(`crate:${c.id}`)} style={{ fontWeight: 650 }}>{c.name}</button>
                    {c.kind === "smart" && <span className="crate-kind">smart</span>}
                    <span className="spacer" />
                    <span className="small muted">{kids.length ? plural(kids.length, "sub-crate") : plural(c.track_count, "track")}</span>
                  </div>
                );
              })}
            </div>
          </div>
          {labels && (
            <div className="panel">
              <h2 style={{ marginBottom: 10 }}>Labels from the cheat sheet</h2>
              <div className="legend">
                {labels.energy.map((e) => (
                  <Fragment key={e.label}><strong className="mono">{e.min}–{e.max}</strong><span>{e.label} <span className="muted small">— {e.hint}</span></span></Fragment>
                ))}
              </div>
              <div className="legend" style={{ marginTop: 12 }}>
                {Object.entries(labels.rating).sort((a, b) => Number(b[0]) - Number(a[0])).map(([k, v]) => (
                  <Fragment key={k}><span className="stars">{"★".repeat(Number(k))}<span className="off">{"★".repeat(5 - Number(k))}</span></span><span>{v} <span className="muted small">— {labels.rating_hint[k]}</span></span></Fragment>
                ))}
              </div>
              <div className="legend" style={{ marginTop: 12 }}>
                {Object.entries(labels.color).filter(([, v]) => v).map(([c, v]) => (
                  <Fragment key={c}><ColorDot color={c} /><span>{v}</span></Fragment>
                ))}
              </div>
              <p className="note">Rename these in Settings → Labels.</p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
