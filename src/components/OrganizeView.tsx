import { useEffect, useState } from "react";
import { api, isDesktop, pickFolder } from "../api";
import type { Crate, JobState, OrgHistory, OrgPlan, PlannedChange, Settings } from "../types";
import { bytes, dateTime, plural } from "../lib/format";
import { playSound } from "../lib/sound";
import { Dialog } from "./ui";
import { Icon } from "./Icon";

type Scope = { label: string; sel: Record<string, unknown> };

function useScopes(crates: Crate[]): Scope[] {
  return [{ label: "All tracks", sel: { query: {} } }, ...crates.map((c) => ({ label: `Crate: ${c.name}`, sel: { crate_id: c.id } }))];
}

/** Old → new list for a previewed organiser plan. */
export function OpsList({ plan }: { plan: OrgPlan }) {
  const name = (p: string) => p.split(/[\\/]/).slice(-2).join(" / ");
  return (
    <>
      <div className="small" style={{ marginTop: 8 }}>
        <strong>{plural(plan.ready, "change")} ready</strong>{plan.blocked ? <span className="muted"> · {plan.blocked} can't be done (shown faded, with the reason)</span> : null}
      </div>
      {plan.warning && <div className="notice warn small" style={{ marginTop: 8 }}><Icon name="warn" /><div>{plan.warning}</div></div>}
      <div className="op-list">
        {plan.ops.slice(0, 400).map((o, i) => (
          <div key={i} className={`op-row${o.blocked ? " blocked" : ""}`}>
            <Icon name={o.op === "remove" ? "trash" : o.op === "folder_rename" ? "folder" : "edit"} size={15} />
            <div style={{ minWidth: 0 }}>
              <div className="from ellipsis" title={o.from}>{name(o.from)}</div>
              <div className="to ellipsis" title={o.to}>→ {o.op === "remove" ? "Removed files (restorable)" : name(o.to)}{o.op === "folder_rename" ? ` · ${plural(o.tracks, "track")}` : ""}</div>
              {o.blocked && <div className="why small">{o.blocked}</div>}
            </div>
          </div>
        ))}
        {plan.ops.length === 0 && <div className="small muted">Nothing to change — everything already matches.</div>}
        {plan.ops.length > 400 && <div className="small muted">…and {plan.ops.length - 400} more.</div>}
      </div>
    </>
  );
}

function TagList({ plan }: { plan: PlannedChange[] }) {
  const ready = plan.filter((p) => !p.blocked);
  return (
    <>
      <div className="small" style={{ marginTop: 8 }}><strong>{plural(ready.length, "file")} to update</strong>{plan.length - ready.length ? <span className="muted"> · {plan.length - ready.length} can't be written (format or file problem)</span> : null}</div>
      <div className="op-list">
        {plan.slice(0, 300).map((p) => (
          <div key={p.track_id} className={`op-row${p.blocked ? " blocked" : ""}`}>
            <Icon name="edit" size={15} />
            <div style={{ minWidth: 0 }}>
              <div className="ellipsis" title={p.path}>{p.path.split(/[\\/]/).pop()}</div>
              {p.blocked ? <div className="why small">{p.blocked}</div> : (
                <div className="small muted">{Object.entries(p.changes).map(([k, [a, b]]) => `${k}: ${a ?? "—"} → ${b ?? "(cleared)"}`).join(" · ")}</div>
              )}
            </div>
          </div>
        ))}
        {plan.length === 0 && <div className="small muted">Your files already match your catalogue.</div>}
      </div>
    </>
  );
}

function FolderField({ value, onChange, label }: { value: string; onChange: (v: string) => void; label: string }) {
  return (
    <div className="row" style={{ gap: 8 }}>
      <input className="input" style={{ flex: 1 }} value={value} placeholder="Folder path" onChange={(e) => onChange(e.target.value)} aria-label={label} />
      {isDesktop() && <button className="btn" onClick={() => pickFolder(label).then((p) => p && onChange(p))}><Icon name="folder" size={15} /> Choose…</button>}
    </div>
  );
}

export function OrganizeView({ settings, crates, toast, bump, onSettings, onReview }: {
  settings: Settings; crates: Crate[]; toast: (m: string, e?: boolean) => void; bump: () => void; onSettings: () => void; onReview: () => void;
}) {
  const scopes = useScopes(crates);
  const [busy, setBusy] = useState<string | null>(null);
  const [prep, setPrep] = useState<JobState | null>(null);
  const [tagPlan, setTagPlan] = useState<{ token: string; plan: PlannedChange[] } | null>(null);
  const [estimates, setEstimates] = useState(true);
  const [orgPlan, setOrgPlan] = useState<{ token: string; plan: OrgPlan; title: string } | null>(null);
  const [renameScope, setRenameScope] = useState(0);
  const [renameTpl, setRenameTpl] = useState("{artist} - {title}");
  const [moveScope, setMoveScope] = useState(0);
  const [moveTpl, setMoveTpl] = useState("{genre}/{artist}");
  const [folder, setFolder] = useState("");
  const [folderName, setFolderName] = useState("");
  const [bad, setBad] = useState<number | null>(null);
  const [removed, setRemoved] = useState<{ files: number; bytes: number } | null>(null);
  const [history, setHistory] = useState<OrgHistory[]>([]);
  const [confirmEmpty, setConfirmEmpty] = useState(false);
  const on = settings.allow_file_changes;

  const load = () => {
    api.jobStatus("auto_prep").then(setPrep).catch(() => {});
    api.badFiles().then((b) => setBad(b.ids.length)).catch(() => {});
    api.removedSummary().then(setRemoved).catch(() => {});
    api.organizeHistory().then(setHistory).catch(() => {});
  };
  useEffect(load, []);
  useEffect(() => {
    if (prep?.state !== "running") return;
    const t = setInterval(() => api.jobStatus("auto_prep").then((j) => { setPrep(j); if (j.state !== "running") { load(); bump(); } }), 1000);
    return () => clearInterval(t);
  }, [prep?.state]); // eslint-disable-line react-hooks/exhaustive-deps

  const run = async (key: string, f: () => Promise<void>) => {
    setBusy(key);
    try { await f(); } catch (e) { toast((e as Error).message, true); playSound("error"); } finally { setBusy(null); }
  };
  const preview = (title: string, args: Record<string, unknown>) => run(title, async () => setOrgPlan({ ...(await api.organizePreview(args)), title }));
  const applyOrg = () => orgPlan && run("apply", async () => {
    const r = await api.organizeApply(orgPlan.token);
    setOrgPlan(null);
    toast(`${plural(r.done, "change")} done${r.skipped.length ? `, ${r.skipped.length} skipped` : ""}. You can undo it below.`);
    playSound(r.skipped.length && !r.done ? "error" : "saved");
    load(); bump();
  });
  const result = prep?.result as null | { analysed: number; fixes_applied: number; left_to_review: number; suggestions_found: number; musicbrainz_lookups: number; catalog_checked?: number };
  const batches = Object.values(history.reduce<Record<string, OrgHistory[]>>((m, h) => { (m[h.batch] ??= []).push(h); return m; }, {})).slice(0, 12);

  return (
    <div className="page">
      <div className="view-head">
        <div className="grow">
          <h1>Organise Files</h1>
          <div className="sub">Auto-prep your catalogue, then — when you choose — fix tags, names, folders and bad files on disk. Every file change is previewed, needs your OK and can be undone.</div>
        </div>
        <span className={`badge ${on ? "q-lossless" : "kind-possible"}`}>{on ? "Changes to files: on" : "Changes to files: off"}</span>
      </div>
      <div className="view-body col stagger" style={{ gap: 14 }}>
        <section className="panel">
          <div className="row" style={{ marginBottom: 6 }}>
            <h2 style={{ flex: 1 }}><Icon name="sparkles" size={18} /> Auto-prep</h2>
            <span className="small muted">After every scan</span>
            <label className="toggle"><input type="checkbox" aria-label="Auto-prep after every scan" checked={settings.auto_prep} onChange={(e) => api.setSetting("auto_prep", e.target.checked).then(bump)} /><span className="knob" /></label>
          </div>
          <p className="small muted" style={{ marginTop: 0 }}>When music is added, DJ Assistant analyses BPM, key, energy and loudness, finds titles, artists, genres and years from file names, folders, albums and artists (and MusicBrainz, plus exact BPM, release year and genre from Deezer &amp; Apple Music, if you turned them on in Settings → Online services), and applies the recommended fixes to your catalogue. Empty fields are filled from good evidence; existing values change only at {Math.round(settings.auto_fix_min * 100)}% confidence or more. Nothing on disk changes here.</p>
          {prep?.state === "running" && (
            <div className="col" style={{ gap: 6 }}>
              <div className="progress"><div style={{ width: `${prep.total ? (prep.done / prep.total) * 100 : 5}%` }} /></div>
              <span className="small muted">{prep.message}</span>
            </div>
          )}
          {result && prep?.state !== "running" && (
            <div className="prep-stats" style={{ marginBottom: 10 }}>
              <div><strong>{result.analysed}</strong><span className="small muted">analysed</span></div>
              <div><strong>{result.fixes_applied}</strong><span className="small muted">fixes applied</span></div>
              <div><strong>{result.left_to_review}</strong><span className="small muted">left to review</span></div>
              {result.musicbrainz_lookups > 0 && <div><strong>{result.musicbrainz_lookups}</strong><span className="small muted">MusicBrainz lookups</span></div>}
              {(result.catalog_checked ?? 0) > 0 && <div><strong>{result.catalog_checked}</strong><span className="small muted">checked on Deezer &amp; Apple Music</span></div>}
            </div>
          )}
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn primary" disabled={prep?.state === "running"} onClick={() => run("prep", async () => { await api.runAutoPrep(); setPrep(await api.jobStatus("auto_prep")); })}><Icon name="play" size={15} /> Run auto-prep now</button>
            <button className="btn ghost" onClick={onReview}>Review remaining suggestions</button>
          </div>
        </section>

        {!on && (
          <div className="notice info">
            <Icon name="shield" />
            <div>Changes to music files are off, so only your catalogue is changed. To rename, re-tag or remove files, turn on <strong>Allow writing to music files</strong> in Settings → Safety (keep a backup of your music first). <button className="link-btn" onClick={onSettings}>Open Settings</button></div>
          </div>
        )}

        <div className="org-grid">
          <section className="panel">
            <h2><Icon name="edit" size={17} /> Write fixes into the files</h2>
            <p className="small muted">Copies your catalogue values (titles, artists, genres, years, keys, BPM) into each file's own tags so Serato and other software see them. Every file is backed up first and can be rolled back from Settings → Change log. MP3, FLAC and M4A.</p>
            <label className="row small" style={{ gap: 8 }}><input type="checkbox" checked={estimates} onChange={(e) => setEstimates(e.target.checked)} /> Also write analysed BPM and key where the file has none</label>
            <div className="row" style={{ gap: 8, marginTop: 10 }}>
              <button className="btn" disabled={!on || busy === "tags"} onClick={() => run("tags", async () => setTagPlan(await api.fixFilesPreview({ all: true }, estimates)))}><Icon name="eye" size={15} /> Preview changes</button>
            </div>
          </section>

          <section className="panel">
            <h2><Icon name="file" size={17} /> Rename files</h2>
            <p className="small muted">Fields: {"{artist} {title} {album} {genre} {year} {bpm} {key} {version}"}</p>
            <div className="col" style={{ gap: 8 }}>
              <select className="select" value={renameScope} onChange={(e) => setRenameScope(Number(e.target.value))} aria-label="Files to rename">{scopes.map((s, i) => <option key={i} value={i}>{s.label}</option>)}</select>
              <input className="input" value={renameTpl} onChange={(e) => setRenameTpl(e.target.value)} aria-label="File name template" />
              <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!on} onClick={() => preview("Rename files", { kind: "rename", template: renameTpl, ...scopes[renameScope].sel })}><Icon name="eye" size={15} /> Preview renames</button>
            </div>
          </section>

          <section className="panel">
            <h2><Icon name="layers" size={17} /> Sort into folders</h2>
            <p className="small muted">Moves files into folders inside their music folder, e.g. {"{genre}/{artist}"} or {"{genre}/{year}"}.</p>
            <div className="col" style={{ gap: 8 }}>
              <select className="select" value={moveScope} onChange={(e) => setMoveScope(Number(e.target.value))} aria-label="Files to sort">{scopes.map((s, i) => <option key={i} value={i}>{s.label}</option>)}</select>
              <input className="input" value={moveTpl} onChange={(e) => setMoveTpl(e.target.value)} aria-label="Folder template" />
              <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!on} onClick={() => preview("Sort into folders", { kind: "move", template: moveTpl, ...scopes[moveScope].sel })}><Icon name="eye" size={15} /> Preview moves</button>
            </div>
          </section>

          <section className="panel">
            <h2><Icon name="folder" size={17} /> Rename a folder</h2>
            <p className="small muted">For a folder inside one of your music folders. Its tracks, crates and analysis follow.</p>
            <div className="col" style={{ gap: 8 }}>
              <FolderField value={folder} onChange={setFolder} label="Folder to rename" />
              <input className="input" value={folderName} placeholder="New folder name" onChange={(e) => setFolderName(e.target.value)} aria-label="New folder name" />
              <button className="btn" style={{ alignSelf: "flex-start" }} disabled={!on || !folder || !folderName} onClick={() => preview("Rename folder", { kind: "folder_rename", folder, new_name: folderName })}><Icon name="eye" size={15} /> Preview</button>
            </div>
          </section>

          <section className="panel">
            <h2><Icon name="warn" size={17} /> Corrupt and bad files</h2>
            <p className="small muted">{bad == null ? "Checking…" : bad === 0 ? "No unreadable or empty files found." : `${plural(bad, "file")} can't be read or are empty.`} Removing moves them to “Removed files” in DJ Assistant's data folder, where you can restore them until you empty it. Duplicates: use “Keep this, replace others” in Duplicate Review.</p>
            <button className="btn" disabled={!on || !bad} onClick={() => preview("Remove bad files", { kind: "bad_files" })}><Icon name="eye" size={15} /> Preview removal</button>
          </section>

          <section className="panel">
            <h2><Icon name="trash" size={17} /> Removed files</h2>
            <p className="small muted">{removed && removed.files ? `${plural(removed.files, "file")} (${bytes(removed.bytes)}) can still be restored — use Undo below.` : "Nothing removed."}</p>
            <button className="btn ghost" disabled={!on || !removed?.files} onClick={() => setConfirmEmpty(true)}>Empty removed files permanently…</button>
          </section>
        </div>

        <section className="panel">
          <h2 style={{ marginBottom: 8 }}><Icon name="undo" size={17} /> Recent file changes</h2>
          {batches.length === 0 ? <p className="small muted" style={{ margin: 0 }}>No changes yet.</p> : (
            <div className="col" style={{ gap: 6 }}>
              {batches.map((b) => {
                const live = b.filter((x) => x.status === "done");
                const kinds = [...new Set(b.map((x) => x.op))].map((k) => ({ rename: "renamed", move: "moved", folder_rename: "folder renamed", remove: "removed" })[k] ?? k).join(", ");
                return (
                  <div key={b[0].batch} className="row" style={{ gap: 10 }}>
                    <span className="small grow">{dateTime(b[0].at)} — {plural(b.length, "file")} {kinds}{live.length < b.length ? ` (${b.length - live.length} undone or purged)` : ""}</span>
                    <button className="btn small" disabled={!live.length} onClick={() => run("undo", async () => { const r = await api.organizeUndo(b[0].batch); toast(`Undid ${plural(r.undone, "change")}.`); playSound("saved"); load(); bump(); })}><Icon name="undo" size={14} /> Undo</button>
                  </div>
                );
              })}
            </div>
          )}
        </section>
      </div>

      {orgPlan && (
        <Dialog title={orgPlan.title} onClose={() => setOrgPlan(null)} footer={<>
          <button className="btn ghost" onClick={() => setOrgPlan(null)}>Cancel</button>
          <button className="btn primary" disabled={!orgPlan.plan.ready || busy === "apply"} onClick={applyOrg}><Icon name="check" size={15} /> Apply {plural(orgPlan.plan.ready, "change")}</button>
        </>}>
          <OpsList plan={orgPlan.plan} />
        </Dialog>
      )}
      {tagPlan && (
        <Dialog title="Write fixes into the files" onClose={() => setTagPlan(null)} footer={<>
          <button className="btn ghost" onClick={() => setTagPlan(null)}>Cancel</button>
          <button className="btn primary" disabled={!tagPlan.plan.some((p) => !p.blocked) || busy === "write"} onClick={() => run("write", async () => {
            const r = await api.writeApply(tagPlan.token);
            setTagPlan(null);
            const ok = r.filter((x) => x.status === "done").length;
            toast(`Wrote tags to ${plural(ok, "file")}${r.length - ok ? `; ${r.length - ok} skipped` : ""}. Backups kept — roll back in Settings → Change log.`);
            playSound("saved"); bump();
          })}><Icon name="check" size={15} /> Write {plural(tagPlan.plan.filter((p) => !p.blocked).length, "file")}</button>
        </>}>
          <TagList plan={tagPlan.plan} />
        </Dialog>
      )}
      {confirmEmpty && (
        <Dialog narrow title="Delete removed files permanently?" onClose={() => setConfirmEmpty(false)} footer={<>
          <button className="btn ghost" onClick={() => setConfirmEmpty(false)}>Keep them</button>
          <button className="btn danger solid" onClick={() => run("empty", async () => { const r = await api.emptyRemoved(); setConfirmEmpty(false); toast(`Deleted ${plural(r.deleted, "file")} permanently.`); load(); bump(); })}>Delete {plural(removed?.files ?? 0, "file")}</button>
        </>}>
          <p>This deletes the files in “Removed files” for good. They can't be restored afterwards.</p>
        </Dialog>
      )}
    </div>
  );
}
