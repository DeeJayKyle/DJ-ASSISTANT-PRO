import { useEffect, useState } from "react";
import { api, isDesktop, pickFolder, reveal } from "../api";
import type { DocHit, DocsReport } from "../types";
import { bytes, dateTime, plural } from "../lib/format";
import { Icon } from "./Icon";
import { useDebounced } from "./ui";

export function FilesView({ toast }: { toast: (m: string, e?: boolean) => void }) {
  const [roots, setRoots] = useState<Awaited<ReturnType<typeof api.docsRoots>>>([]);
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<DocHit[]>([]);
  const [report, setReport] = useState<DocsReport | null>(null);
  const [path, setPath] = useState("");
  const [scanning, setScanning] = useState(false);
  const dq = useDebounced(q, 200);
  const load = () => { api.docsRoots().then(setRoots); api.docsReport().then(setReport).catch(() => {}); };
  useEffect(load, []);
  useEffect(() => { api.docsSearch(dq).then(setHits).catch(() => setHits([])); }, [dq, scanning]);
  useEffect(() => {
    if (!scanning) return;
    const t = setInterval(() => api.jobStatus("docs").then((j) => { if (j.state !== "running" && j.state !== "paused") { setScanning(false); load(); } }), 600);
    return () => clearInterval(t);
  }, [scanning]);
  const add = (p: string) => api.docsAddRoot(p).then(() => { setPath(""); load(); }).catch((e) => toast(e.message, true));
  return (
    <div className="page">
      <div className="view-head">
        <div className="grow"><h1>Personal Files</h1><div className="sub">A separate, opt-in index of folders you choose. Searched locally, never changed, never used for music recommendations.</div></div>
        <button className="btn primary" disabled={!roots.length || scanning} onClick={() => api.docsScan().then(() => setScanning(true)).catch((e) => toast(e.message, true))}><Icon name="refresh" size={16} /> {scanning ? "Indexing…" : "Index now"}</button>
      </div>
      <div className="view-body col" style={{ gap: 16 }}>
        <div className="panel">
          <div className="row wrap">
            {isDesktop() && <button className="btn" onClick={() => pickFolder("Choose a documents folder").then((p) => { if (p) add(p); })}><Icon name="folder" size={16} /> Add folder…</button>}
            <form className="row" style={{ flex: 1 }} onSubmit={(e) => { e.preventDefault(); if (path.trim()) add(path.trim()); }}>
              <input className="input" style={{ flex: 1 }} aria-label="Documents folder path" placeholder="C:\\Users\\Herbie\\Documents\\Bookings" value={path} onChange={(e) => setPath(e.target.value)} />
              <button className="btn" type="submit" disabled={!path.trim()}>Add</button>
            </form>
          </div>
          {roots.map((r) => <div key={r.id} className="root-row" style={{ gridTemplateColumns: "auto 1fr auto" }}><span className={`status-dot ${r.status}`} /><div><div style={{ fontWeight: 600 }}>{r.path}</div><div className="small muted">{plural(r.count, "file")} · indexed {dateTime(r.last_scan_at)}</div></div><button className="btn small ghost danger" onClick={() => api.docsRemoveRoot(r.id).then(load)}>Remove</button></div>)}
        </div>
        <div className="search"><Icon name="search" size={18} /><input className="input" aria-label="Search documents" placeholder="Search file names, folders and text in .txt, .md, .csv, .docx…" value={q} onChange={(e) => setQ(e.target.value)} /></div>
        <div className="panel" style={{ padding: 0 }}>
          <table className="data-table">
            <thead><tr><th>Name</th><th>Folder</th><th>Size</th><th>Content</th><th /></tr></thead>
            <tbody>{hits.map((h) => <tr key={h.id}><td><strong>{h.name}</strong>{h.snippet && <div className="small muted">…{h.snippet}…</div>}</td><td className="small muted">{h.folder || "—"}</td><td className="small">{bytes(h.size)}</td><td><span className={`badge ${h.content_status === "indexed" ? "q-lossless" : h.content_status === "encrypted" || h.content_status === "unreadable" ? "q-low_bitrate" : "q-lossy"}`}>{h.content_status.replace("_", " ")}</span></td><td>{isDesktop() && <button className="btn small ghost" aria-label="Show in folder" onClick={() => reveal(h.path)}><Icon name="folder" size={14} /></button>}</td></tr>)}</tbody>
          </table>
          {hits.length === 0 && <p className="faint" style={{ padding: 16 }}>No files found.</p>}
        </div>
        {report && (
          <div className="grid2">
            <div className="panel"><h3>Duplicates (identical contents)</h3>{report.duplicates.length === 0 ? <p className="faint small">None found.</p> : report.duplicates.map((d, i) => <div key={i} className="small" style={{ padding: "4px 0" }}>{d.paths.join("  =  ")} <span className="faint">({bytes(d.size)})</span></div>)}</div>
            <div className="panel"><h3>Encrypted or unreadable</h3>{report.flagged.length === 0 ? <p className="faint small">None.</p> : report.flagged.map((f) => <div key={f.path} className="small" style={{ padding: "3px 0" }}><span className="badge q-low_bitrate">{f.status}</span> {f.path}</div>)}</div>
            <div className="panel"><h3>Organisation ideas</h3>{report.suggestions.length === 0 ? <p className="faint small">Nothing to suggest.</p> : report.suggestions.map((s) => <div key={s.folder} className="small" style={{ padding: "3px 0" }}><strong>{s.folder}</strong> — {plural(s.count, "loose file")}. {s.note}</div>)}</div>
            <div className="panel"><h3>File types</h3>{report.types.map((t) => <div key={t.ext} className="small" style={{ padding: "2px 0" }}>.{t.ext || "?"} — {t.count} ({bytes(t.bytes)})</div>)}</div>
          </div>
        )}
      </div>
    </div>
  );
}
