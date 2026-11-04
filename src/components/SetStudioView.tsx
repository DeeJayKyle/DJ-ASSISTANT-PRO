import { useEffect, useState } from "react";
import { api, pickSave } from "../api";
import type { Crate, SavedSet, SetParams, SetPlan, SetSlot, TrackRow } from "../types";
import { bpm, duration, plural, text } from "../lib/format";
import { Icon } from "./Icon";
import { useDebounced } from "./ui";

const CURVES: [string, string][] = [["journey", "Journey (build to peak)"], ["warmup", "Warm-up"], ["peak", "Peak time"], ["wedding", "Wedding arc"], ["lounge", "Lounge / chill"]];
const EVENTS = ["Club / Nightclub", "Festival", "Wedding", "Corporate", "Private Party", "Birthday", "Latin Night", "House Party", "Lounge / Chill"];

export function EnergyCurve({ points, slots }: { points: number[]; slots?: SetSlot[] }) {
  const W = 600, H = 120, P = 8;
  const x = (i: number, n: number) => P + (i / Math.max(1, n - 1)) * (W - 2 * P);
  const y = (e: number) => H - P - ((e - 1) / 9) * (H - 2 * P);
  const line = points.map((p, i) => `${i ? "L" : "M"}${x(i, points.length)},${y(p)}`).join(" ");
  return (
    <svg className="curve wave-reveal" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" role="img" aria-label="Energy journey">
      <defs><linearGradient id="curveFill" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor="var(--mint)" stopOpacity="0.35" /><stop offset="1" stopColor="var(--mint)" stopOpacity="0" /></linearGradient></defs>
      <g className="grid">{[2, 4, 6, 8, 10].map((e) => <line key={e} x1={P} x2={W - P} y1={y(e)} y2={y(e)} />)}</g>
      <path className="area" d={`${line} L${x(points.length - 1, points.length)},${H - P} L${P},${H - P} Z`} />
      <path className="line" d={line} />
      {slots?.map((s, i) => s.energy != null && <circle key={s.track_id} cx={x(i, slots.length)} cy={y(s.energy)} r={3.5} />)}
    </svg>
  );
}

const defaults = (): SetParams => ({ duration_min: 60, genres: [], must_play: [], exclude: [], exclude_tags: [], clean_only: false, curve: "journey", event_type: null, audience: "", harmonic: true, crate_id: null });

export function SetStudioView({ crates, version, toast, bump, initial }: { crates: Crate[]; version: number; toast: (m: string, e?: boolean) => void; bump: () => void; initial?: Partial<SetParams> | null }) {
  const [p, setP] = useState<SetParams>({ ...defaults(), ...(initial ?? {}) });
  const [genreText, setGenreText] = useState("");
  const [plan, setPlan] = useState<SetPlan | null>(null);
  const [planId, setPlanId] = useState<number | null>(null);
  const [name, setName] = useState("");
  const [saved, setSaved] = useState<SavedSet[]>([]);
  const [busy, setBusy] = useState(false);
  const [mustQ, setMustQ] = useState("");
  const [mustHits, setMustHits] = useState<TrackRow[]>([]);
  const [mustNames, setMustNames] = useState<Record<number, string>>({});
  const dq = useDebounced(mustQ, 200);
  useEffect(() => { if (initial) setP({ ...defaults(), ...initial }); }, [initial]);
  useEffect(() => { api.listSets().then(setSaved); }, [version]);
  useEffect(() => { if (dq.trim().length > 1) api.search({ text: dq, limit: 8 }).then((r) => setMustHits(r.rows)); else setMustHits([]); }, [dq]);
  const generate = async () => {
    setBusy(true);
    try {
      const params = { ...p, genres: genreText.split(",").map((g) => g.trim()).filter(Boolean) };
      const r = await api.planSet(params);
      setPlan(r);
      setPlanId(null);
      if (!name) setName(`${p.event_type ?? "Set"} — ${p.duration_min} min`);
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };
  const reorder = async (slots: SetSlot[]) => {
    const review = await api.reviewSet(slots.map((s) => s.track_id));
    const next = slots.map((s, i) => ({ ...s, transition: i === 0 ? [] : review[i - 1]?.notes ?? [] }));
    setPlan({ ...plan!, slots: next });
  };
  const move = (i: number, d: number) => {
    const s = [...plan!.slots];
    const j = i + d;
    if (j < 0 || j >= s.length) return;
    [s[i], s[j]] = [s[j], s[i]];
    reorder(s);
  };
  const swap = (i: number, alt: SetSlot["alternatives"][number]) => {
    const s = [...plan!.slots];
    s[i] = { ...s[i], track_id: alt.track_id, track: alt.track, energy: alt.energy, bpm: alt.bpm, key: alt.key, reasons: [...alt.reasons, "Swapped in by you"], alternatives: s[i].alternatives.filter((a) => a.track_id !== alt.track_id) };
    reorder(s);
  };
  const remove = (i: number) => reorder(plan!.slots.filter((_, k) => k !== i));
  const save = async () => {
    if (!plan) return;
    try {
      const r = await api.saveSet(planId, name || "Untitled set", plan);
      setPlanId(r.id);
      api.listSets().then(setSaved);
      toast("Set saved.");
    } catch (e) {
      toast((e as Error).message, true);
    }
  };
  const total = plan?.slots.length ?? 0;
  return (
    <div className="page">
      <div className="view-head">
        <div className="grow">
          <h1>Set Studio</h1>
          <div className="sub">Build an editable running order. Suggestions consider energy, tempo and key — always check transitions by ear.</div>
        </div>
      </div>
      <div className="view-body" style={{ display: "grid", gridTemplateColumns: "360px minmax(0, 1fr)", gap: 16, alignItems: "start" }}>
        <div className="panel col" style={{ gap: 12 }}>
          <h2>The gig</h2>
          <label className="field">Event type
            <select className="select" value={p.event_type ?? ""} onChange={(e) => setP({ ...p, event_type: e.target.value || null, curve: e.target.value === "Wedding" ? "wedding" : e.target.value.startsWith("Lounge") ? "lounge" : p.curve })}>
              <option value="">Any</option>
              {EVENTS.map((e) => <option key={e}>{e}</option>)}
            </select>
          </label>
          <label className="field">Audience notes<input className="input" value={p.audience ?? ""} onChange={(e) => setP({ ...p, audience: e.target.value })} placeholder="e.g. mixed ages, loves 2000s R&B" /></label>
          <div className="row">
            <label className="field" style={{ flex: 1 }}>Length (minutes)<input className="input" type="number" min={5} max={720} value={p.duration_min} onChange={(e) => setP({ ...p, duration_min: Number(e.target.value) })} /></label>
            <label className="field" style={{ flex: 1 }}>From crate<select className="select" value={p.crate_id ?? ""} onChange={(e) => setP({ ...p, crate_id: Number(e.target.value) || null })}><option value="">Whole library</option>{crates.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}</select></label>
          </div>
          <label className="field">Genres (comma separated, optional)<input className="input" value={genreText} onChange={(e) => setGenreText(e.target.value)} placeholder="Afrobeats, Amapiano" /></label>
          <label className="field">Energy journey
            <select className="select" value={p.curve} onChange={(e) => setP({ ...p, curve: e.target.value })}>{CURVES.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>
          </label>
          <EnergyCurve points={plan?.curve ?? ({ journey: [4, 5, 6, 7, 8, 9, 8.5, 6.5], warmup: [3, 3.5, 4, 4.5, 5, 5.5, 6], peak: [7, 8, 8.5, 9, 9, 9.5, 8.5], wedding: [4, 5, 6, 7.5, 8.5, 9, 8, 6], lounge: [3, 3.5, 4, 4, 4.5, 4, 3.5] } as Record<string, number[]>)[p.curve] ?? [5, 5]} />
          <div className="row">
            <label className="field" style={{ flex: 1 }}>Min BPM<input className="input" type="number" value={p.bpm_min ?? ""} onChange={(e) => setP({ ...p, bpm_min: e.target.value ? Number(e.target.value) : null })} /></label>
            <label className="field" style={{ flex: 1 }}>Max BPM<input className="input" type="number" value={p.bpm_max ?? ""} onChange={(e) => setP({ ...p, bpm_max: e.target.value ? Number(e.target.value) : null })} /></label>
          </div>
          <label className="field">Skip tracks shorter than (seconds)<input className="input" type="number" min={0} max={600} value={p.min_track_seconds ?? 30} onChange={(e) => setP({ ...p, min_track_seconds: Number(e.target.value) })} /></label>
          <label className="toggle"><input type="checkbox" checked={p.clean_only} onChange={(e) => setP({ ...p, clean_only: e.target.checked })} /><span className="knob" /> Clean versions only</label>
          <label className="toggle"><input type="checkbox" checked={p.harmonic ?? true} onChange={(e) => setP({ ...p, harmonic: e.target.checked })} /><span className="knob" /> Prefer harmonic (Camelot) moves</label>
          <div className="field">Must-play tracks
            <input className="input" placeholder="Search to add…" value={mustQ} onChange={(e) => setMustQ(e.target.value)} />
            {mustHits.length > 0 && <div className="list">{mustHits.map((h) => <button key={h.id} className="btn ghost small" style={{ justifyContent: "flex-start" }} onClick={() => { setP({ ...p, must_play: [...new Set([...p.must_play, h.id])] }); setMustNames({ ...mustNames, [h.id]: `${h.artist ?? ""} — ${h.title ?? h.file_name}` }); setMustQ(""); }}><Icon name="plus" size={12} /> {h.artist} — {h.title ?? h.file_name}</button>)}</div>}
            <div className="tagline">{p.must_play.map((id) => <span key={id} className="chip">{mustNames[id] ?? `#${id}`}<button aria-label="Remove must-play" onClick={() => setP({ ...p, must_play: p.must_play.filter((x) => x !== id) })}><Icon name="close" size={12} /></button></span>)}</div>
          </div>
          <button className="btn primary big" onClick={generate} disabled={busy}>{busy ? "Building…" : plan ? "Regenerate" : "Generate running order"}</button>
          {saved.length > 0 && (
            <>
              <h3 style={{ marginTop: 8 }}>Saved sets</h3>
              {saved.map((s) => (
                <div key={s.id} className="list-row">
                  <button className="btn ghost small" style={{ flex: 1, justifyContent: "flex-start" }} onClick={() => api.getSet(s.id).then((g) => { setPlan(g); setPlanId(g.id); setName(g.name); })}>{s.name}</button>
                  <span className="small muted">{plural(s.count, "track")}</span>
                  <button className="btn small ghost" aria-label={`Delete ${s.name}`} onClick={() => api.deleteSet(s.id).then(() => api.listSets().then(setSaved))}><Icon name="trash" size={14} /></button>
                </div>
              ))}
            </>
          )}
        </div>
        <div className="col" style={{ gap: 16 }}>
          {!plan && (
            <div className="panel empty"><div className="art"><Icon name="set" size={30} /></div><h2>No set yet</h2><p>Choose the gig on the left and press Generate. Unknown energy or BPM values are treated cautiously — analyse your library for better plans.</p></div>
          )}
          {plan && (
            <>
              <div className="panel beam">
                <div className="row wrap" style={{ marginBottom: 10 }}>
                  <input className="input" style={{ flex: 1, minWidth: 200, fontWeight: 650 }} aria-label="Set name" value={name} onChange={(e) => setName(e.target.value)} />
                  <button className="btn primary" onClick={save}><Icon name="check" size={16} /> {planId ? "Save changes" : "Save set"}</button>
                  <button className="btn" disabled={!planId} title={planId ? "" : "Save first"} onClick={async () => { const path = await pickSave("Export set", `${name}.m3u8`, ["m3u8"]); if (path) api.exportM3u({ set_id: planId! }, path).then(() => toast("Playlist exported.")).catch((e) => toast(e.message, true)); }}><Icon name="export" size={16} /> M3U8</button>
                  <button className="btn" disabled={!planId} onClick={() => api.setToCrate(planId!, name).then(() => { toast("Saved as a crate."); bump(); })}><Icon name="crate" size={16} /> To crate</button>
                </div>
                <EnergyCurve points={plan.curve} slots={plan.slots} />
                <div className="small muted">{plural(total, "track")} · about {duration(plan.planned_ms ?? 0)} · {plan.note}</div>
                {plan.warnings?.map((w) => <p key={w} className="note">{w}</p>)}
              </div>
              <div className="panel" style={{ padding: 0 }}>
                {plan.slots.map((s, i) => (
                  <div key={s.track_id + "-" + i} className={`slot${s.must_play ? " must" : ""}`} style={{ animationDelay: `${Math.min(i, 12) * 25}ms` }}>
                    <span className="n">{String(i + 1).padStart(2, "0")}</span>
                    <div style={{ minWidth: 0 }}>
                      <div className="row" style={{ gap: 10 }}><strong className="cell">{s.track}</strong>{s.must_play && <span className="badge q-lossless">must-play</span>}</div>
                      <div className="small muted">{s.start_ms > 0 ? duration(s.start_ms) : "0:00"} · energy {text(s.energy)} (target {s.target_energy}) · {bpm(s.bpm)} BPM · {text(s.key)} {s.reasons.filter((r) => !r.startsWith("Energy ")).length ? `· ${s.reasons.filter((r) => !r.startsWith("Energy ")).join(", ")}` : ""}</div>
                      {s.transition.length > 0 && <div className="trans">{s.transition.map((t) => <span key={t} className={/jump|not a standard|unknown/i.test(t) ? "bad" : ""}>{t}</span>)}</div>}
                      {s.alternatives.length > 0 && (
                        <details style={{ marginTop: 4 }}>
                          <summary className="small faint" style={{ cursor: "pointer" }}>{plural(s.alternatives.length, "alternative")}</summary>
                          {s.alternatives.map((a) => <div key={a.track_id} className="row small" style={{ padding: "3px 0" }}><span style={{ flex: 1 }}>{a.track} <span className="faint">E{text(a.energy)} · {bpm(a.bpm)} · {text(a.key)}</span></span><button className="btn small ghost" onClick={() => swap(i, a)}>Use</button></div>)}
                        </details>
                      )}
                    </div>
                    <div className="row" style={{ alignSelf: "start" }}>
                      <button className="btn small icon ghost" aria-label="Move up" onClick={() => move(i, -1)}><Icon name="arrowUp" size={14} /></button>
                      <button className="btn small icon ghost" aria-label="Move down" onClick={() => move(i, 1)}><Icon name="arrowDown" size={14} /></button>
                      <button className="btn small icon ghost" aria-label="Remove from set" onClick={() => remove(i)}><Icon name="close" size={14} /></button>
                    </div>
                  </div>
                ))}
              </div>
              {plan.emergency.length > 0 && (
                <div className="panel">
                  <h2 style={{ marginBottom: 8 }}>Emergency tracks</h2>
                  <p className="small muted" style={{ marginTop: 0 }}>Dependable floor-fillers (4–5★ or tagged “banger”) kept out of the plan in case you need to rescue the floor.</p>
                  {plan.emergency.map((e) => <div key={e.track_id} className="list-row"><span style={{ flex: 1 }}>{e.track}</span><span className="small muted">{e.rating ? "★".repeat(e.rating) : ""} E{text(e.energy)} · {bpm(e.bpm)}</span></div>)}
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
