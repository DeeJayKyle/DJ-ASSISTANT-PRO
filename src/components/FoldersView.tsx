import { useEffect, useState } from "react";
import { api, isDesktop, pickFolders } from "../api";
import type { Root, ScanProgress } from "../types";
import { dateTime, plural } from "../lib/format";
import { Dialog } from "./ui";
import { Icon } from "./Icon";

export function ScanPanel({ scan }: { scan: ScanProgress }) {
  const running = scan.state === "running" || scan.state === "paused";
  const pct = scan.files_to_read ? Math.min(100, (100 * scan.files_processed) / scan.files_to_read) : 0;
  return (
    <div className="panel" aria-live="polite">
      <div className="row wrap" style={{ marginBottom: 10 }}>
        <strong>
          {scan.state === "paused" ? "Scan paused" : running ? (scan.phase === "discovering" ? "Finding music files…" : scan.phase === "finalising" ? "Finishing…" : "Reading tags and properties…") : `Last scan ${scan.state}`}
        </strong>
        <span className="spacer" />
        {running && (
          <>
            <button className="btn small" onClick={() => api.pauseScan(scan.state !== "paused")}>
              <Icon name={scan.state === "paused" ? "play" : "pause"} size={14} /> {scan.state === "paused" ? "Resume" : "Pause"}
            </button>
            <button className="btn small danger" onClick={() => api.cancelScan()}>
              <Icon name="stop" size={14} /> Cancel
            </button>
          </>
        )}
      </div>
      {running && (
        <div className={`progress${scan.phase === "discovering" ? " indeterminate" : ""}`} style={{ marginBottom: 10 }}>
          <div style={{ width: `${pct}%` }} />
        </div>
      )}
      <div className="row wrap small muted" style={{ gap: 18 }}>
        <span>{plural(scan.files_found, "music file")} found</span>
        <span>{scan.added} new</span>
        <span>{scan.updated} updated</span>
        <span>{scan.unchanged} unchanged</span>
        {scan.missing > 0 && <span>{scan.missing} missing</span>}
        {scan.offline_roots > 0 && <span className="s-offline">{plural(scan.offline_roots, "folder")} offline</span>}
        {scan.errors > 0 && <span className="s-error">{plural(scan.errors, "problem")} (see Library health)</span>}
      </div>
      {scan.current_root && running && <div className="path" style={{ marginTop: 8 }}>{scan.current_root}</div>}
      {scan.state === "cancelled" && <p className="note">The scan was cancelled. Everything read before cancelling was saved; no files were marked missing.</p>}
      {scan.message && <p className="note">{scan.message}</p>}
    </div>
  );
}

export function FoldersView({ scan, version, bump, toast }: { scan: ScanProgress | null; version: number; bump: () => void; toast: (m: string, err?: boolean) => void }) {
  const [roots, setRoots] = useState<Root[]>([]);
  const [path, setPath] = useState("");
  const [removing, setRemoving] = useState<Root | null>(null);
  const load = () => api.listRoots().then(setRoots);
  useEffect(() => {
    load();
  }, [version]);
  const running = scan?.state === "running" || scan?.state === "paused";

  const add = async (paths: string[]) => {
    const added: Root[] = [];
    for (const p of paths) {
      try {
        added.push(await api.addRoot(p));
      } catch (e) {
        toast(`${p}: ${(e as Error).message}`, true);
      }
    }
    if (added.length) {
      toast(`Added ${plural(added.length, "folder")}. Starting a read-only scan…`);
      setPath("");
      await load();
      await api.startScan(added.map((r) => r.id)).catch((e) => toast(e.message, true));
      bump();
    }
  };

  return (
    <>
      <div className="view-head">
        <div className="grow">
          <h1>Music folders</h1>
          <div className="sub">Only the folders you add here are scanned. DJ Assistant reads them; it never renames, moves, tags or deletes files.</div>
        </div>
        <button className="btn" disabled={running || roots.length === 0} onClick={() => api.startScan().then(bump).catch((e) => toast(e.message, true))}>
          <Icon name="refresh" /> Rescan all
        </button>
      </div>
      <div className="view-body">
        <div className="panel" style={{ marginBottom: 16 }}>
          <h2 style={{ marginBottom: 10 }}>Add a folder or drive</h2>
          <div className="row wrap">
            {isDesktop() && (
              <button className="btn primary" onClick={() => pickFolders().then((p) => p && add(p))}>
                <Icon name="folder" /> Choose folders…
              </button>
            )}
            <form
              className="row"
              style={{ flex: 1, minWidth: 280 }}
              onSubmit={(e) => {
                e.preventDefault();
                if (path.trim()) add([path.trim()]);
              }}
            >
              <input className="input" style={{ flex: 1 }} aria-label="Folder path" placeholder={isDesktop() ? "…or type a path, e.g. D:\\Music" : "Folder path, e.g. D:\\Music"} value={path} onChange={(e) => setPath(e.target.value)} />
              <button className={`btn${isDesktop() ? "" : " primary"}`} type="submit" disabled={!path.trim()}>
                Add folder
              </button>
            </form>
          </div>
          <p className="note">External drives are fine. If a drive is unplugged, its tracks are shown as offline — they are not deleted from the catalogue.</p>
        </div>

        {scan && scan.state !== "idle" && <ScanPanel scan={scan} />}

        <div style={{ marginTop: 16 }}>
          {roots.length === 0 ? (
            <div className="empty">
              <h2>No folders yet</h2>
              <p>Add your music folder to build your catalogue. Nothing on your computer is scanned unless you add it.</p>
            </div>
          ) : (
            roots.map((r) => (
              <div key={r.id} className="root-row">
                <div style={{ minWidth: 0 }}>
                  <div className="root-path">
                    <span className={`status-dot ${r.status}`} aria-hidden />
                    {r.path}
                  </div>
                  <div className="small muted">
                    {r.status === "offline" ? "Offline — not available at last scan" : r.status === "online" ? "Online" : "Not scanned yet"}. {plural(r.track_count, "track")}. Last scan: {dateTime(r.last_scan_at)}
                    {r.last_scan_status && r.last_scan_status !== "completed" ? ` (${r.last_scan_status})` : ""}
                  </div>
                </div>
                <button className="btn small" disabled={running} onClick={() => api.startScan([r.id]).then(bump).catch((e) => toast(e.message, true))}>
                  Scan
                </button>
                <button className="btn small ghost danger" disabled={running} onClick={() => setRemoving(r)}>
                  Remove
                </button>
              </div>
            ))
          )}
        </div>
      </div>
      {removing && (
        <Dialog
          narrow
          title="Remove folder from library?"
          onClose={() => setRemoving(null)}
          footer={
            <>
              <button className="btn" onClick={() => setRemoving(null)}>
                Keep it
              </button>
              <button
                className="btn danger"
                onClick={async () => {
                  await api.removeRoot(removing.id);
                  setRemoving(null);
                  toast("Folder removed from the catalogue. No files were touched.");
                  load();
                  bump();
                }}
              >
                Remove from catalogue
              </button>
            </>
          }
        >
          <p>
            <strong>{removing.path}</strong>
          </p>
          <p>
            This removes its {plural(removing.track_count, "track")} from DJ Assistant’s catalogue, including your ratings, tags and crate membership for those tracks. <strong>The music files themselves are not touched.</strong>
          </p>
          <p className="muted">If the drive is just unplugged, you don’t need to remove it — its tracks are kept and shown as offline.</p>
        </Dialog>
      )}
    </>
  );
}
