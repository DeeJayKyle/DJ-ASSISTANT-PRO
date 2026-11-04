import { useEffect, useRef, useState } from "react";
import { api, isDesktop, pickFolders } from "../api";
import type { Health, JobState, Root, ScanProgress, WatchItem } from "../types";
import { dateTime, plural } from "../lib/format";
import { Dialog } from "./ui";
import { Icon } from "./Icon";

export function ScanPanel({ scan }: { scan: ScanProgress }) {
  const running = scan.state === "running" || scan.state === "paused";
  const pct = scan.files_to_read ? Math.min(100, (100 * scan.files_processed) / scan.files_to_read) : 0;
  return (
    <div className={`card${running ? " beam" : ""}`} aria-live="polite">
      <div className="row wrap" style={{ marginBottom: 10 }}>
        <strong>{scan.state === "paused" ? "Scan paused" : running ? (scan.phase === "discovering" ? "Finding music files…" : scan.phase === "finalising" ? "Finishing…" : "Reading tags and properties…") : `Last scan ${scan.state}`}</strong>
        <span className="spacer" />
        {running && (
          <>
            <button className="btn small" onClick={() => api.pauseScan(scan.state !== "paused")}><Icon name={scan.state === "paused" ? "play" : "pause"} size={14} /> {scan.state === "paused" ? "Resume" : "Pause"}</button>
            <button className="btn small danger" onClick={() => api.cancelScan()}><Icon name="stop" size={14} /> Cancel</button>
          </>
        )}
      </div>
      {running && <div className={`progress${scan.phase === "discovering" ? " indeterminate" : ""}`} style={{ marginBottom: 10 }}><div style={{ width: `${pct}%` }} /></div>}
      <div className="row wrap small muted" style={{ gap: 18 }}>
        <span>{plural(scan.files_found, "music file")} found</span>
        <span>{scan.added} new</span>
        <span>{scan.updated} updated</span>
        <span>{scan.unchanged} unchanged</span>
        {scan.missing > 0 && <span>{scan.missing} missing</span>}
        {scan.offline_roots > 0 && <span className="s-offline">{plural(scan.offline_roots, "folder")} offline</span>}
        {scan.errors > 0 && <span className="s-error">{plural(scan.errors, "problem")} (see Library Health)</span>}
      </div>
      {scan.state === "cancelled" && <p className="note">Cancelled. Everything read before cancelling was saved; nothing was marked missing.</p>}
      {scan.message && <p className="note">{scan.message}</p>}
    </div>
  );
}

function JobCard({ title, job, onStart, startLabel, extra }: { title: string; job: JobState; onStart: () => void; startLabel: string; extra?: React.ReactNode }) {
  const running = job.state === "running" || job.state === "paused";
  const pct = job.total ? (100 * job.done) / job.total : 0;
  return (
    <div className={`card${running ? " beam" : ""}`}>
      <div className="row wrap" style={{ marginBottom: 8 }}>
        <h3 style={{ margin: 0 }}>{title}</h3>
        <span className="spacer" />
        {running ? (
          <>
            <button className="btn small" onClick={() => api.pauseJob(job.kind, job.state !== "paused")}><Icon name={job.state === "paused" ? "play" : "pause"} size={14} /> {job.state === "paused" ? "Resume" : "Pause"}</button>
            <button className="btn small danger" onClick={() => api.cancelJob(job.kind)}><Icon name="stop" size={14} /> Cancel</button>
          </>
        ) : (
          <button className="btn small primary" onClick={onStart}>{startLabel}</button>
        )}
      </div>
      {running && <div className="progress" style={{ marginBottom: 8 }}><div style={{ width: `${pct}%` }} /></div>}
      <div className="small muted">
        {job.state === "idle" ? "Not run yet in this session." : `${job.state === "paused" ? "Paused" : job.state[0].toUpperCase() + job.state.slice(1)}: ${job.done} of ${job.total}${job.errors ? `, ${job.errors} could not be read` : ""}.`}
        {job.message && <> {job.message}</>}
      </div>
      {extra}
    </div>
  );
}

export function ActivityView({ scan, version, bump, toast, health }: { scan: ScanProgress | null; version: number; bump: () => void; toast: (m: string, err?: boolean) => void; health: Health | null }) {
  const [roots, setRoots] = useState<Root[]>([]);
  const [path, setPath] = useState("");
  const [removing, setRemoving] = useState<Root | null>(null);
  const [analysis, setAnalysis] = useState<JobState>({ kind: "analysis", state: "idle", done: 0, total: 0, errors: 0, message: null, started_at: null, finished_at: null, result: null });
  const [summary, setSummary] = useState<{ analysed: number; errors: number; pending: number } | null>(null);
  const [watch, setWatch] = useState<{ enabled: boolean; active: boolean; pending: WatchItem[] } | null>(null);
  const load = () => {
    api.listRoots().then(setRoots);
    api.analysisSummary().then(setSummary);
    api.watchStatus().then(setWatch);
  };
  useEffect(load, [version]);
  const prevState = useRef<string>("idle");
  useEffect(() => {
    const t = setInterval(() => {
      api.jobStatus("analysis").then((j) => {
        const was = prevState.current;
        prevState.current = j.state;
        setAnalysis(j);
        if ((was === "running" || was === "paused") && j.state !== "running" && j.state !== "paused") bump();
      });
    }, 800);
    return () => clearInterval(t);
  }, [bump]);
  const running = scan?.state === "running" || scan?.state === "paused";
  const add = async (paths: string[]) => {
    const added: Root[] = [];
    for (const p of paths) {
      try { added.push(await api.addRoot(p)); } catch (e) { toast(`${p}: ${(e as Error).message}`, true); }
    }
    if (added.length) {
      setPath("");
      await api.startScan(added.map((r) => r.id)).catch((e) => toast(e.message, true));
      toast(`Added ${plural(added.length, "folder")}. Read-only scan started.`);
      bump();
    }
  };
  return (
    <div className="page">
      <div className="view-head">
        <div className="grow">
          <h1>Scan Activity</h1>
          <div className="sub">Folders, scans, audio analysis and the folder watcher. Your files are only read.</div>
        </div>
        <button className="btn" disabled={running || roots.length === 0} onClick={() => api.startScan().then(bump).catch((e) => toast(e.message, true))}>
          <Icon name="refresh" size={16} /> Rescan all
        </button>
      </div>
      <div className="view-body col" style={{ gap: 16 }}>
        <div className="kpis stagger">
          <div className="card stat"><small>Folders</small><strong>{roots.length}</strong></div>
          <div className="card stat"><small>Analysed</small><strong>{summary?.analysed ?? "—"}</strong></div>
          <div className="card stat"><small>Waiting for analysis</small><strong>{summary?.pending ?? "—"}</strong></div>
          <div className="card stat"><small>Last scan problems</small><strong>{health?.last_scan?.errors ?? 0}</strong></div>
        </div>
        <div className="panel">
          <h2 style={{ marginBottom: 10 }}>Music folders</h2>
          <div className="row wrap">
            {isDesktop() && <button className="btn primary" onClick={() => pickFolders().then((p) => p && add(p))}><Icon name="folder" size={18} /> Choose folders…</button>}
            <form className="row" style={{ flex: 1, minWidth: 280 }} onSubmit={(e) => { e.preventDefault(); if (path.trim()) add([path.trim()]); }}>
              <input className="input" style={{ flex: 1 }} aria-label="Folder path" placeholder={isDesktop() ? "…or type a path, e.g. D:\\DJ Music" : "Folder path, e.g. D:\\DJ Music"} value={path} onChange={(e) => setPath(e.target.value)} />
              <button className={`btn${isDesktop() ? "" : " primary"}`} type="submit" disabled={!path.trim()}>Add folder</button>
            </form>
          </div>
          <div style={{ marginTop: 8 }}>
            {roots.map((r) => (
              <div key={r.id} className="root-row">
                <span className={`status-dot ${r.status}`} aria-label={r.status} />
                <div style={{ minWidth: 0 }}>
                  <div style={{ fontWeight: 600, overflowWrap: "anywhere" }}>{r.path}</div>
                  <div className="small muted">{r.status === "offline" ? "Offline — tracks kept, not deleted" : r.status === "online" ? "Online" : "Not scanned yet"} · {plural(r.track_count, "track")} · last scan {dateTime(r.last_scan_at)}{r.last_scan_status && r.last_scan_status !== "completed" ? ` (${r.last_scan_status})` : ""}</div>
                </div>
                <button className="btn small" disabled={running} onClick={() => api.startScan([r.id]).then(bump).catch((e) => toast(e.message, true))}>Scan</button>
                <button className="btn small ghost danger" disabled={running} onClick={() => setRemoving(r)}>Remove</button>
              </div>
            ))}
            {roots.length === 0 && <p className="muted" style={{ marginTop: 10 }}>No folders yet. Only folders you add are ever scanned.</p>}
          </div>
        </div>
        {scan && scan.state !== "idle" && <ScanPanel scan={scan} />}
        <JobCard
          title="Audio analysis"
          job={analysis}
          startLabel={summary?.pending ? `Analyse ${summary.pending} tracks` : "Re-check library"}
          onStart={() => api.startAnalysis().then((r) => { toast(r.paused_for_gig ? "Analysis queued — paused while gig mode is on." : "Analysis started. Files are only read."); setAnalysis({ ...analysis, state: "running" }); }).catch((e) => toast(e.message, true))}
          extra={<p className="note">Estimates BPM (with half/double-time alternatives), key (Camelot), energy, loudness, silence, clipping, intro/outro, cue ideas and a waveform. Your own values always take priority.</p>}
        />
        <div className="panel">
          <div className="row" style={{ marginBottom: 8 }}>
            <h2 style={{ flex: 1 }}>Folder watcher</h2>
            <label className="toggle">
              <span className="small muted">{watch?.enabled ? "On" : "Off"}</span>
              <input type="checkbox" checked={!!watch?.enabled} onChange={(e) => api.setSetting("watch_enabled", e.target.checked).then(load)} />
              <span className="knob" />
            </label>
          </div>
          <p className="small muted" style={{ marginTop: 0 }}>Notices new music in your folders and suggests where it could go. It never moves files (that would break Serato’s links). Paused during gig mode.</p>
          {watch?.pending.length ? (
            <>
              <table className="data-table">
                <thead><tr><th>New file</th><th>Tags</th><th>Suggested folder</th></tr></thead>
                <tbody>{watch.pending.map((w) => <tr key={w.id}><td className="path">{w.path}</td><td>{w.artist ?? "—"} — {w.title ?? "—"} <span className="faint">{w.genre ?? ""}</span></td><td className="path">{w.suggested_folder ?? "—"}</td></tr>)}</tbody>
              </table>
              <div className="row" style={{ marginTop: 10 }}>
                <button className="btn primary small" disabled={running} onClick={() => api.startScan().then(() => api.watchClear()).then(bump)}>Scan now</button>
                <button className="btn small" onClick={() => api.watchClear().then(load)}>Dismiss</button>
              </div>
            </>
          ) : (
            <p className="small faint">{watch?.active ? "Watching — no new files yet." : "Not watching."}</p>
          )}
        </div>
        {health && health.recent_errors.length > 0 && (
          <div className="panel" style={{ padding: 0 }}>
            <h2 style={{ padding: "16px 16px 4px" }}>Problems in the last scan ({health.recent_errors.length})</h2>
            <table className="err-table">
              <thead><tr><th style={{ width: 90 }}>Type</th><th>File or folder</th><th>What happened</th></tr></thead>
              <tbody>{health.recent_errors.slice(0, 200).map((e, i) => <tr key={i}><td>{e.kind}</td><td>{e.path}</td><td>{e.message}</td></tr>)}</tbody>
            </table>
          </div>
        )}
      </div>
      {removing && (
        <Dialog narrow title="Remove folder from library?" onClose={() => setRemoving(null)} footer={<><button className="btn" onClick={() => setRemoving(null)}>Keep it</button><button className="btn danger" onClick={async () => { await api.removeRoot(removing.id); setRemoving(null); toast("Folder removed from the catalogue. No files were touched."); bump(); }}>Remove from catalogue</button></>}>
          <p><strong>{removing.path}</strong></p>
          <p>This removes its {plural(removing.track_count, "track")} from DJ Assistant’s catalogue, including your ratings, tags and crate membership for them. <strong>The music files are not touched.</strong></p>
          <p className="muted">If the drive is just unplugged, keep it — its tracks are shown as offline.</p>
        </Dialog>
      )}
    </div>
  );
}
