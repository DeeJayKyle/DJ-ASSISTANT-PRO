import { useEffect, useState } from "react";
import { api, pickSave } from "../api";
import type { Gig, GigRecap, SavedSet, SetPlan, TrackRow } from "../types";
import { dateTime, duration, keyName, plural } from "../lib/format";
import { Icon } from "./Icon";
import { useDebounced } from "./ui";

function Clock() {
  const [t, setT] = useState(new Date());
  useEffect(() => { const i = setInterval(() => setT(new Date()), 1000); return () => clearInterval(i); }, []);
  return <div className="gig-clock">{t.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</div>;
}

export function GigView({ toast, onChange }: { toast: (m: string, e?: boolean) => void; onChange: () => void }) {
  const [gig, setGig] = useState<Gig | null>(null);
  const [sets, setSets] = useState<SavedSet[]>([]);
  const [plan, setPlan] = useState<SetPlan | null>(null);
  const [name, setName] = useState("");
  const [setId, setSetId] = useState<number | null>(null);
  const [req, setReq] = useState("");
  const [note, setNote] = useState("");
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<TrackRow[]>([]);
  const [recap, setRecap] = useState<GigRecap | null>(null);
  const [history, setHistory] = useState<{ id: number; name: string; started_at: number; played: number }[]>([]);
  const dq = useDebounced(q, 150);
  const load = () => api.gigCurrent().then((g) => { setGig(g); if (g?.set_plan_id) api.getSet(g.set_plan_id).then(setPlan); });
  useEffect(() => { load(); api.listSets().then(setSets); api.gigs().then(setHistory); }, []);
  useEffect(() => { if (dq.trim().length > 1) api.search({ text: dq, limit: 8 }).then((r) => setHits(r.rows)); else setHits([]); }, [dq]);
  const ev = (kind: string, track: number | null, t: string | null) => api.gigEvent(kind, track, t).then(load).catch((e) => toast(e.message, true));
  if (!gig) {
    return (
      <div className="page">
        <div className="view-head"><div className="grow"><h1>Gig Mode</h1><div className="sub">An offline set list, request queue and notes. Background scanning, analysis and the folder watcher pause while a gig runs.</div></div></div>
        <div className="view-body">
          {recap ? (
            <Recap r={recap} onClose={() => setRecap(null)} toast={toast} />
          ) : (
            <div className="grid2">
              <div className="panel col beam" style={{ gap: 12 }}>
                <h2>Start a gig</h2>
                <label className="field">Name<input className="input" value={name} onChange={(e) => setName(e.target.value)} placeholder="Saturday — Club Rouge" /></label>
                <label className="field">Set list (optional)<select className="select" value={setId ?? ""} onChange={(e) => setSetId(Number(e.target.value) || null)}><option value="">No set list</option>{sets.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
                <button className="btn primary big" onClick={() => api.gigStart(name, setId).then(() => { load(); onChange(); toast("Gig mode on. Background work paused."); }).catch((e) => toast(e.message, true))}><Icon name="gig" size={18} /> Start gig mode</button>
              </div>
              <div className="panel">
                <h2 style={{ marginBottom: 8 }}>Past gigs</h2>
                {history.length === 0 && <p className="faint">None yet.</p>}
                {history.map((h) => <div key={h.id} className="list-row"><span style={{ flex: 1 }}>{h.name} <span className="small muted">{dateTime(h.started_at)}</span></span><span className="small muted">{plural(h.played, "track")}</span><button className="btn small" onClick={() => api.gigRecap(h.id).then(setRecap)}>Recap</button></div>)}
              </div>
            </div>
          )}
        </div>
      </div>
    );
  }
  const played = gig.events.filter((e) => e.kind === "played");
  const playedIds = new Set(played.map((p) => p.track_id));
  const requests = gig.events.filter((e) => e.kind === "request");
  const notes = gig.events.filter((e) => e.kind === "note");
  const next = plan?.slots.find((s) => !playedIds.has(s.track_id));
  return (
    <div className="page">
      <div className="view-head">
        <div className="grow"><h1>{gig.name}</h1><div className="sub">Live since {new Date(gig.started_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })} · {plural(played.length, "track")} played · background work paused</div></div>
        <Clock />
        <button className="btn danger" onClick={() => api.gigEnd().then((r) => { onChange(); setGig(null); if (r.id) api.gigRecap(r.id).then(setRecap); })}><Icon name="stop" size={16} /> End gig</button>
      </div>
      <div className="view-body" style={{ display: "grid", gridTemplateColumns: "minmax(0, 1.3fr) minmax(0, 1fr)", gap: 16, alignItems: "start" }}>
        <div className="col" style={{ gap: 16 }}>
          <div className="glass now-playing beam">
            <div className="small muted">Up next{plan ? " from your set" : ""}</div>
            <div className="big">{next?.track ?? (plan ? "Set complete" : "No set list — use quick search")}</div>
            {next && <div className="muted small">Energy {next.energy ?? "—"} · {next.bpm ? Math.round(next.bpm) : "—"} BPM · {keyName(next.key)} {next.transition.length ? `· ${next.transition.join(" · ")}` : ""}</div>}
            {next && <button className="btn primary" style={{ marginTop: 12 }} onClick={() => ev("played", next.track_id, null)}><Icon name="check" size={16} /> Mark as played</button>}
          </div>
          <div className="panel">
            <h2 style={{ marginBottom: 8 }}>Quick search</h2>
            <input className="input" style={{ width: "100%" }} aria-label="Quick search" placeholder="Find any track…" value={q} onChange={(e) => setQ(e.target.value)} />
            {hits.map((h) => <div key={h.id} className="list-row"><span style={{ flex: 1 }}>{h.artist} — {h.title ?? h.file_name} <span className="faint small">{h.bpm ? Math.round(h.bpm) : ""} {h.key ?? ""}</span></span><button className="btn small" onClick={() => { ev("played", h.id, null); setQ(""); }}>Played</button></div>)}
          </div>
          {plan && (
            <div className="panel" style={{ padding: 0 }}>
              {plan.slots.map((s, i) => <div key={s.track_id + "-" + i} className="slot" style={{ opacity: playedIds.has(s.track_id) ? 0.45 : 1 }}><span className="n">{String(i + 1).padStart(2, "0")}</span><div className="cell">{s.track}</div>{playedIds.has(s.track_id) ? <Icon name="check" size={16} /> : <button className="btn small ghost" onClick={() => ev("played", s.track_id, null)}>Played</button>}</div>)}
            </div>
          )}
        </div>
        <div className="col" style={{ gap: 16 }}>
          <div className="panel">
            <h2 style={{ marginBottom: 8 }}>Requests ({requests.filter((r) => r.status === "pending").length} waiting)</h2>
            <form className="row" onSubmit={(e) => { e.preventDefault(); if (req.trim()) ev("request", null, req).then(() => setReq("")); }}>
              <input className="input" style={{ flex: 1 }} aria-label="New request" placeholder="Song or artist someone asked for" value={req} onChange={(e) => setReq(e.target.value)} />
              <button className="btn" type="submit">Add</button>
            </form>
            {requests.map((r) => (
              <div key={r.id} className="req">
                <span style={{ flex: 1, textDecoration: r.status === "declined" ? "line-through" : undefined }}>{r.text ?? r.track}</span>
                <span className="small muted">{r.status}</span>
                {r.status === "pending" && <><button className="btn small" onClick={() => api.gigRequest(r.id, "played").then(load)}>Played</button><button className="btn small ghost" onClick={() => api.gigRequest(r.id, "declined").then(load)}>Decline</button></>}
              </div>
            ))}
          </div>
          <div className="panel">
            <h2 style={{ marginBottom: 8 }}>DJ notes</h2>
            <form className="row" onSubmit={(e) => { e.preventDefault(); if (note.trim()) ev("note", null, note).then(() => setNote("")); }}>
              <input className="input" style={{ flex: 1 }} aria-label="New note" placeholder="Crowd loved the throwbacks…" value={note} onChange={(e) => setNote(e.target.value)} />
              <button className="btn" type="submit">Save</button>
            </form>
            {notes.map((n) => <div key={n.id} className="list-row small"><span className="faint">{new Date(n.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span><span>{n.text}</span></div>)}
          </div>
          <div className="panel">
            <h2 style={{ marginBottom: 8 }}>Played ({played.length})</h2>
            {[...played].reverse().map((p) => <div key={p.id} className="list-row small"><span className="faint">{new Date(p.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</span><span style={{ flex: 1 }}>{p.track}</span><button className="btn small ghost" aria-label="Undo" onClick={() => api.gigDeleteEvent(p.id).then(load)}><Icon name="undo" size={12} /></button></div>)}
          </div>
        </div>
      </div>
    </div>
  );
}

function Recap({ r, onClose, toast }: { r: GigRecap; onClose: () => void; toast: (m: string, e?: boolean) => void }) {
  const max = Math.max(1, ...r.genres.map((g) => g.count));
  return (
    <div className="col" style={{ gap: 16 }}>
      <div className="row"><h2 style={{ flex: 1 }}>Recap — {r.name}</h2><button className="btn" onClick={async () => { const p = await pickSave("Save recap", `${r.name} recap.md`, ["md", "txt"]); if (p) api.exportRecap(r.id, p).then(() => toast("Recap saved.")); }}><Icon name="export" size={16} /> Save as text</button><button className="btn" onClick={onClose}>Close</button></div>
      <div className="kpis stagger">
        <div className="card stat"><small>Duration</small><strong>{duration(r.duration_ms)}</strong></div>
        <div className="card stat"><small>Tracks played</small><strong>{r.played_count}</strong></div>
        <div className="card stat"><small>Requests played</small><strong>{r.requests_fulfilled}/{r.requests_total}</strong></div>
        <div className="card stat"><small>Notes</small><strong>{r.notes.length}</strong></div>
      </div>
      <div className="grid2">
        <div className="panel"><h3>Genres</h3><div className="bars">{r.genres.map((g) => <div key={g.genre} className="bar-row"><span>{g.genre}</span><span className="bar-track"><i style={{ width: `${(100 * g.count) / max}%` }} /></span><span className="small muted">{g.count}</span></div>)}</div></div>
        <div className="panel"><h3>Played</h3>{r.played.map((p, i) => <div key={p.id} className="small" style={{ padding: "3px 0" }}>{i + 1}. {p.track}</div>)}</div>
      </div>
      {r.notes.length > 0 && <div className="panel"><h3>Notes</h3>{r.notes.map((n) => <p key={n.id} className="small">{n.text}</p>)}</div>}
    </div>
  );
}
