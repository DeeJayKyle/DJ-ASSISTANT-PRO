import { useState } from "react";
import { api } from "../api";
import type { PlannedChange } from "../types";
import { Dialog } from "./ui";
import { Icon } from "./Icon";

const FIELDS: [string, string][] = [["title", "Title"], ["artist", "Artist"], ["album", "Album"], ["genre", "Genre"], ["year", "Year"], ["bpm", "BPM"], ["key", "Key"], ["comment", "Comment"]];

/** Opt-in, previewed, backed-up tag writing to music files. */
export function WriteDialog({ ids, onClose, onDone, toast, initial }: { ids: number[]; onClose: () => void; onDone: () => void; toast: (m: string, e?: boolean) => void; initial?: Record<string, string> }) {
  const [vals, setVals] = useState<Record<string, string>>(initial ?? {});
  const [use, setUse] = useState<Record<string, boolean>>(Object.fromEntries(Object.keys(initial ?? {}).map((k) => [k, true])));
  const [preview, setPreview] = useState<{ token: string; plan: PlannedChange[] } | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState<{ ok: number; failed: number } | null>(null);
  const build = async () => {
    setErr(null);
    const values: Record<string, string | null> = {};
    for (const [k] of FIELDS) if (use[k]) values[k] = (vals[k] ?? "").trim() || null;
    if (!Object.keys(values).length) return setErr("Choose at least one field to write.");
    try {
      setPreview(await api.writePreview({ ids }, values));
    } catch (e) {
      setErr((e as Error).message);
    }
  };
  const apply = async () => {
    if (!preview) return;
    setBusy(true);
    try {
      const res = await api.writeApply(preview.token);
      const ok = res.filter((r) => r.status === "done").length;
      const failed = res.filter((r) => r.status === "failed").length;
      setDone({ ok, failed });
      if (failed) toast(res.find((r) => r.status === "failed")?.message ?? "Some files were not changed", true);
      onDone();
    } catch (e) {
      setErr((e as Error).message);
    } finally {
      setBusy(false);
    }
  };
  const changes = preview?.plan.filter((p) => !p.blocked) ?? [];
  return (
    <Dialog
      title="Write tags to music files"
      onClose={onClose}
      footer={
        done ? (
          <button className="btn primary" onClick={onClose}>Done</button>
        ) : preview ? (
          <>
            <button className="btn" onClick={() => setPreview(null)}>Back</button>
            <span className="spacer" />
            <button className="btn primary" disabled={!changes.length || busy} onClick={apply}>
              {busy ? "Writing…" : `Back up and write ${changes.length} file${changes.length === 1 ? "" : "s"}`}
            </button>
          </>
        ) : (
          <>
            <button className="btn" onClick={onClose}>Cancel</button>
            <button className="btn primary" onClick={build}>Preview changes</button>
          </>
        )
      }
    >
      {done ? (
        <div className="success">
          <svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="28" /><path d="M20 33 l8 8 l16 -18" /></svg>
          <strong>{done.ok} file{done.ok === 1 ? "" : "s"} updated</strong>
          <p className="muted small">Each original was backed up and verified first. You can undo any change in Settings → Change log.</p>
        </div>
      ) : !preview ? (
        <>
          <div className="notice warn">
            <Icon name="warn" />
            <div>
              This changes the files on disk. Serato keeps cues, loops and beatgrids inside the file tags — DJ Assistant preserves every tag it isn't asked to change and verifies the audio is untouched, but please test on copies first.
              Each file is backed up and verified before writing, nothing is written if the file changed since the preview, and every change can be rolled back.
            </div>
          </div>
          <p className="muted small" style={{ margin: 0 }}>{ids.length} track{ids.length === 1 ? "" : "s"} selected. Tick the fields to write; leave a value empty to remove that tag.</p>
          <div className="edit-grid">
            {FIELDS.map(([k, label]) => (
              <label key={k} className="field">
                <span className="row"><input type="checkbox" checked={!!use[k]} onChange={(e) => setUse({ ...use, [k]: e.target.checked })} /> {label}</span>
                <input className="input" disabled={!use[k]} value={vals[k] ?? ""} onChange={(e) => setVals({ ...vals, [k]: e.target.value })} />
              </label>
            ))}
          </div>
        </>
      ) : (
        <>
          <p className="muted small" style={{ margin: 0 }}>Exact changes. Nothing has been written yet.</p>
          <table className="data-table">
            <thead><tr><th>File</th><th>Change</th><th>Notes</th></tr></thead>
            <tbody>
              {preview.plan.map((p) => (
                <tr key={p.track_id}>
                  <td className="path">{p.path}</td>
                  <td>{p.blocked ? <span className="faint">—</span> : Object.entries(p.changes).map(([k, [a, b]]) => <div key={k}><strong>{k}</strong>: <span className="faint">{a ?? "∅"}</span> → {b ?? <em>removed</em>}</div>)}</td>
                  <td className="small">{p.blocked ? <span className="s-error">{p.blocked}</span> : p.warnings.map((w) => <div key={w} className="muted">{w}</div>)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
      {err && <div className="notice danger" role="alert"><Icon name="warn" />{err}</div>}
    </Dialog>
  );
}
