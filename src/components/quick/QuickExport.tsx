import { useEffect, useMemo, useState } from "react";
import { api, isDesktop, pickFolder, reveal } from "../../api";
import type { JobState, PackPlan } from "../../types";
import { bytes, plural } from "../../lib/format";
import { buildLayout, type Layout } from "../../lib/quick/layout";
import { safeFileName } from "../../lib/quick/names";
import { Dialog } from "../ui";
import { Icon } from "../Icon";
import { msg, type QState, type QTrack } from "./model";

type Mode = "folder" | "zip" | "links";
const MODES: { id: Mode; title: string; text: string }[] = [
  { id: "folder", title: "Organised copy in a new folder", text: "Verified copies with clean file names, in folders, with a playlist per folder. Ready for a USB stick or another laptop." },
  { id: "zip", title: "One ZIP file", text: "The same organised copy, packed into a single .zip to send or back up." },
  { id: "links", title: "Playlists only", text: "Writes .m3u8 playlists that point at your original files. Nothing is copied." },
];

/**
 * Saves the clean names (and AI genre suggestions) to the catalogue so the
 * library, the copies' file names and their tags all agree. Catalogue only:
 * music files are never changed.
 */
export async function saveProposals(st: QState, tracks: QTrack[]) {
  let n = 0;
  for (const t of tracks) {
    const patch: Record<string, unknown> = {};
    if (st.useClean) {
      if ((t.name.title || null) !== t.row.title) patch.title = t.name.title || null;
      if ((t.name.artist || null) !== t.row.artist) patch.artist = t.name.artist || null;
      if ((t.name.mix || null) !== t.row.version) patch.version_label = t.name.mix || null;
    }
    if (t.genreSource === "ai" && t.genre !== t.row.genre) patch.genre = t.genre;
    if (Object.keys(patch).length) {
      await api.updateUserFields([t.id], patch);
      n++;
    }
  }
  return n;
}

export function QuickExport({ st, tracks, layout, name, onClose, onSaved, toast }: {
  st: QState; tracks: QTrack[]; layout: Layout; name: string; onClose: () => void; onSaved: () => void; toast: (m: string, e?: boolean) => void;
}) {
  const [mode, setMode] = useState<Mode>("folder");
  const [tags, setTags] = useState(true);
  const [dest, setDest] = useState("");
  const [packName, setPackName] = useState(name);
  const [preview, setPreview] = useState<{ token: string; plan: PackPlan } | null>(null);
  const [job, setJob] = useState<JobState | null>(null);
  const [links, setLinks] = useState<{ dir: string; files: number } | null>(null);
  const [busy, setBusy] = useState(false);

  const pack = useMemo(() => buildLayout(tracks.map((t) => ({ id: t.id, bpm: t.bpm, genre: t.genre, name: st.useClean ? t.name : { artist: "", title: t.row.file_name.replace(/\.[^.]+$/, ""), mix: "" } })), layout, st.format), [tracks, layout, st.format, st.useClean]);
  const pending = tracks.filter((t) => t.row.analysis == null).length;

  useEffect(() => {
    if (!job || (job.state !== "running" && job.state !== "paused")) return;
    const t = setInterval(() => api.jobStatus("gigpack").then(setJob).catch(() => {}), 400);
    return () => clearInterval(t);
  }, [job]);

  const choose = () => pickFolder(mode === "links" ? "Where to save the playlists" : "Where to put the copy (a USB stick or another folder)").then((p) => { if (p) { setDest(p); setPreview(null); } });

  const doPreview = async () => {
    setBusy(true);
    try {
      const saved = await saveProposals(st, tracks);
      if (saved) onSaved();
      setPreview(await api.gigpackPreview({}, dest, packName, { items: pack.items, playlists: pack.playlists, zip: mode === "zip", write_tags: tags }));
    } catch (e) {
      toast(msg(e), true);
    } finally {
      setBusy(false);
    }
  };
  const start = () => preview && api.gigpackStart(preview.token).then(() => setJob({ kind: "gigpack", state: "running", done: 0, total: preview.plan.files.length - preview.plan.missing, errors: 0, message: null, started_at: Date.now(), finished_at: null, result: null })).catch((e) => toast(msg(e), true));

  const writeLinks = async () => {
    setBusy(true);
    try {
      const saved = await saveProposals(st, tracks);
      if (saved) onSaved();
      const sep = dest.includes("\\") ? "\\" : "/";
      const base = dest.replace(/[\\/]+$/, "");
      for (const pl of pack.playlists) await api.exportM3u({ ids: pl.track_ids }, `${base}${sep}${safeFileName(pl.name, 80)}.m3u8`, false);
      setLinks({ dir: base, files: pack.playlists.length });
    } catch (e) {
      toast(msg(e), true);
    } finally {
      setBusy(false);
    }
  };

  const running = job && (job.state === "running" || job.state === "paused");
  const finished = (job && !running) || links;
  return (
    <Dialog title={finished ? "Export finished" : "Export"} onClose={running ? () => {} : onClose}>
      {links ? (
        <div className="col" style={{ gap: 12 }}>
          <p>{plural(links.files, "playlist")} saved in <span className="path">{links.dir}</span>. They point at your original files, so keep them on this computer.</p>
          <ImportHelp />
          <div className="row" style={{ justifyContent: "flex-end" }}><button className="btn primary" onClick={onClose}>Done</button></div>
        </div>
      ) : job && !running ? (
        <div className="col" style={{ gap: 12 }}>
          {job.state === "completed" ? (
            <div className="success">
              <svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="28" /><path d="M20 33 l8 8 l16 -18" /></svg>
              <strong>{preview?.plan.zip ? "ZIP ready" : "Copy ready"}</strong>
              <p className="muted small">{plural(job.done - job.errors, "track")} copied and verified{job.message ? ` · ${job.message}` : ""}{job.errors ? ` · ${job.errors} failed (see missing-and-failed.txt)` : ""}. Your original files weren't changed.</p>
            </div>
          ) : (
            <p className="s-error">{job.state === "cancelled" ? "Cancelled. What was copied so far is listed in the manifest." : job.message}</p>
          )}
          <div className="path">{preview?.plan.pack_dir}</div>
          <ImportHelp />
          <div className="row" style={{ justifyContent: "flex-end" }}>
            {isDesktop() && preview && <button className="btn" onClick={() => reveal(preview.plan.zip ? preview.plan.pack_dir : `${preview.plan.pack_dir}/manifest.json`)}><Icon name="folder" size={16} /> Show in Explorer</button>}
            <button className="btn primary" onClick={onClose}>Done</button>
          </div>
        </div>
      ) : running ? (
        <div className="col" style={{ gap: 10 }}>
          <h3>Copying and verifying…</h3>
          <div className="progress"><div style={{ width: `${job!.total ? (100 * job!.done) / job!.total : 0}%` }} /></div>
          <div className="row"><span className="muted small">{job!.done} of {job!.total}</span><span className="spacer" /><button className="btn small danger" onClick={() => api.cancelJob("gigpack")}>Cancel</button></div>
        </div>
      ) : (
        <div className="col" style={{ gap: 12 }}>
          <div className="col" role="radiogroup" aria-label="Export as" style={{ gap: 8 }}>
            {MODES.map((m) => (
              <label key={m.id} className={`qp-option${mode === m.id ? " on" : ""}`}>
                <input type="radio" name="qp-mode" checked={mode === m.id} onChange={() => { setMode(m.id); setPreview(null); }} />
                <span><strong>{m.title}</strong><br /><span className="small muted">{m.text}</span></span>
              </label>
            ))}
          </div>
          {mode !== "links" && (
            <>
              <label className="check"><input type="checkbox" checked={tags} onChange={(e) => { setTags(e.target.checked); setPreview(null); }} /> Write clean title, artist, genre, BPM and key into the copies (MP3, FLAC, M4A)</label>
              <label className="field">Name<input className="input" value={packName} onChange={(e) => { setPackName(e.target.value); setPreview(null); }} /></label>
            </>
          )}
          <label className="field">{mode === "links" ? "Folder for the playlists" : "Destination drive or folder"}
            <div className="row">
              <input className="input" style={{ flex: 1 }} value={dest} onChange={(e) => { setDest(e.target.value); setPreview(null); }} placeholder={mode === "links" ? "C:\\Users\\you\\Music\\Playlists" : "E:\\"} aria-label="Destination" />
              {isDesktop() && <button className="btn" onClick={choose}><Icon name="folder" size={16} /> Choose…</button>}
            </div>
          </label>
          <div className="card small">
            <div className="muted" style={{ marginBottom: 6 }}>{plural(pack.items.length, "track")} · {plural(pack.playlists.length, "playlist")}</div>
            <ul className="mono small" style={{ margin: 0, paddingLeft: 16 }}>
              {pack.items.slice(0, 6).map((i) => <li key={i.track_id}>{i.folder ? `${i.folder}/` : ""}{i.name}</li>)}
              {pack.items.length > 6 && <li className="faint">…and {pack.items.length - 6} more</li>}
            </ul>
          </div>
          {st.useClean && <p className="small muted" style={{ margin: 0 }}>Clean names are saved to your catalogue first, so the library, file names and tags all match. Your original files are never changed.</p>}
          {pending > 0 && <div className="notice warn"><Icon name="warn" /><div className="small">{plural(pending, "track")} {pending === 1 ? "isn't" : "aren't"} analysed yet; BPM and key may be missing.</div></div>}
          {preview && (
            <div className={`panel${preview.plan.fits ? "" : " beam warn"}`} style={{ padding: 14 }}>
              <div className="kpis" style={{ marginBottom: 8 }}>
                <div className="card stat"><small>Files</small><strong>{preview.plan.files.length - preview.plan.missing}</strong></div>
                <div className="card stat"><small>Size</small><strong>{bytes(preview.plan.total_bytes)}</strong></div>
                <div className="card stat"><small>Free</small><strong>{bytes(preview.plan.free_bytes)}</strong></div>
              </div>
              <div className="path">{preview.plan.pack_dir}</div>
              {preview.plan.warnings.map((w) => <p key={w} className="note">{w}</p>)}
            </div>
          )}
          <div className="row" style={{ justifyContent: "flex-end" }}>
            <button className="btn ghost" onClick={onClose}>Cancel</button>
            {mode === "links" ? (
              <button className="btn primary" disabled={!dest || busy} onClick={writeLinks}><Icon name="download" size={16} /> Save playlists</button>
            ) : preview ? (
              <button className="btn primary" disabled={!preview.plan.fits} onClick={start}><Icon name="download" size={16} /> Copy and verify</button>
            ) : (
              <button className="btn primary" disabled={!dest || busy || !packName.trim()} onClick={doPreview}>{busy ? "Checking…" : "Preview"}</button>
            )}
          </div>
        </div>
      )}
    </Dialog>
  );
}

function ImportHelp() {
  return (
    <details className="small muted">
      <summary>Using the playlists in your DJ software</summary>
      <p style={{ marginBottom: 0 }}>Serato: drag the .m3u8 onto the crates panel. Rekordbox: File → Import → Import Playlist. Traktor: right-click Playlists → Import Playlist. VirtualDJ: drag the .m3u8 into Lists. Keep each playlist next to its folders so the paths stay valid.</p>
    </details>
  );
}
