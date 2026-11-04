import { useEffect, useState } from "react";
import { api, isDesktop, pickFolder, reveal } from "../api";
import type { Crate, JobState, PackPlan, SavedSet } from "../types";
import { bytes, plural } from "../lib/format";
import { Icon } from "./Icon";

export function GigPackView({ crates, toast }: { crates: Crate[]; toast: (m: string, e?: boolean) => void }) {
  const [sets, setSets] = useState<SavedSet[]>([]);
  const [source, setSource] = useState<string>("");
  const [dest, setDest] = useState("");
  const [name, setName] = useState("Gig pack");
  const [preview, setPreview] = useState<{ token: string; plan: PackPlan } | null>(null);
  const [job, setJob] = useState<JobState | null>(null);
  useEffect(() => { api.listSets().then(setSets); }, []);
  useEffect(() => {
    if (!job || (job.state !== "running" && job.state !== "paused")) return;
    const t = setInterval(() => api.jobStatus("gigpack").then(setJob), 500);
    return () => clearInterval(t);
  }, [job]);
  const sel = () => (source.startsWith("set:") ? { set_id: Number(source.slice(4)) } : { crate_id: Number(source.slice(6)) });
  const doPreview = () => api.gigpackPreview(sel(), dest, name).then(setPreview).catch((e) => toast(e.message, true));
  const start = () => preview && api.gigpackStart(preview.token).then(() => setJob({ kind: "gigpack", state: "running", done: 0, total: preview.plan.files.length, errors: 0, message: null, started_at: Date.now(), finished_at: null, result: null })).catch((e) => toast(e.message, true));
  const done = job && job.state === "completed";
  return (
    <div className="page">
      <div className="view-head"><div className="grow"><h1>Gig Pack</h1><div className="sub">Copy a crate or set to a USB stick or drive, verify every copy, and get a manifest, playlist and missing-file report.</div></div></div>
      <div className="view-body grid2" style={{ alignItems: "start" }}>
        <div className="panel col" style={{ gap: 12 }}>
          <label className="field">What to pack
            <select className="select" value={source} onChange={(e) => { setSource(e.target.value); setPreview(null); }}>
              <option value="">Choose a crate or saved set…</option>
              <optgroup label="Saved sets">{sets.map((s) => <option key={s.id} value={`set:${s.id}`}>{s.name} ({s.count})</option>)}</optgroup>
              <optgroup label="Crates">{crates.map((c) => <option key={c.id} value={`crate:${c.id}`}>{c.name} ({c.track_count})</option>)}</optgroup>
            </select>
          </label>
          <label className="field">Destination drive or folder
            <div className="row">
              <input className="input" style={{ flex: 1 }} value={dest} onChange={(e) => { setDest(e.target.value); setPreview(null); }} placeholder="E:\\" />
              {isDesktop() && <button className="btn" onClick={() => pickFolder("Choose the USB stick or folder").then((p) => { if (p) { setDest(p); setPreview(null); } })}><Icon name="usb" size={16} /> Choose…</button>}
            </div>
          </label>
          <label className="field">Pack folder name<input className="input" value={name} onChange={(e) => { setName(e.target.value); setPreview(null); }} /></label>
          <button className="btn primary" disabled={!source || !dest} onClick={doPreview}>Preview pack</button>
          <div className="notice info"><Icon name="info" /><div className="small">Your originals are only read. The pack goes into a new folder; existing files are never overwritten. Serato crates and library links are not copied; cue points stored inside the files travel with them, but check on the gig laptop before relying on them.</div></div>
        </div>
        <div className="col" style={{ gap: 16 }}>
          {preview && !job && (
            <div className={`panel${preview.plan.fits ? "" : " beam warn"}`}>
              <h2 style={{ marginBottom: 10 }}>Preview</h2>
              <div className="kpis">
                <div className="card stat"><small>Files</small><strong>{preview.plan.files.length - preview.plan.missing}</strong></div>
                <div className="card stat"><small>Size</small><strong>{bytes(preview.plan.total_bytes)}</strong></div>
                <div className="card stat"><small>Free space</small><strong>{bytes(preview.plan.free_bytes)}</strong></div>
                <div className="card stat"><small>Missing</small><strong>{preview.plan.missing}</strong></div>
              </div>
              <div className="path" style={{ marginBottom: 8 }}>{preview.plan.pack_dir}</div>
              {preview.plan.warnings.map((w) => <p key={w} className="note">{w}</p>)}
              <div style={{ maxHeight: 260, overflow: "auto", marginTop: 8 }}>
                <table className="data-table"><tbody>{preview.plan.files.map((f) => <tr key={f.n}><td className="mono faint">{f.n}</td><td>{f.artist} — {f.title ?? f.dest_name}</td><td>{f.available ? bytes(f.size) : <span className="s-error">{f.problem}</span>}</td></tr>)}</tbody></table>
              </div>
              <button className="btn primary big" style={{ marginTop: 12, width: "100%" }} disabled={!preview.plan.fits} onClick={start}>Copy and verify {plural(preview.plan.files.length - preview.plan.missing, "file")}</button>
            </div>
          )}
          {job && (
            <div className={`panel${done ? "" : " beam"}`}>
              {done ? (
                <div className="success">
                  <svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="28" /><path d="M20 33 l8 8 l16 -18" /></svg>
                  <strong>Gig pack ready</strong>
                  <p className="muted small">{job.done - job.errors} files copied and verified{job.errors ? `, ${job.errors} failed (see missing-and-failed.txt)` : ""}.</p>
                  {isDesktop() && preview && <button className="btn" onClick={() => reveal(`${preview.plan.pack_dir}/manifest.json`)}><Icon name="folder" size={16} /> Show in Explorer</button>}
                  <button className="btn ghost" onClick={() => { setJob(null); setPreview(null); }}>Make another</button>
                </div>
              ) : (
                <>
                  <h2>Copying and verifying…</h2>
                  <div className="progress" style={{ margin: "12px 0" }}><div style={{ width: `${job.total ? (100 * job.done) / job.total : 0}%` }} /></div>
                  <div className="row"><span className="muted small">{job.done} of {job.total}</span><span className="spacer" /><button className="btn small danger" onClick={() => api.cancelJob("gigpack")}>Cancel</button></div>
                  {job.state === "failed" && <p className="s-error">{job.message}</p>}
                </>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
