import { useState } from "react";
import { api, isDesktop, pickFolder, pickSave } from "../api";
import type { Crate } from "../types";
import { plural } from "../lib/format";
import { playSound } from "../lib/sound";
import { Dialog } from "./ui";
import { Icon } from "./Icon";

type Target = "serato" | "rekordbox" | "folders";

const INFO: Record<Target, { title: string; help: string; dest: string }> = {
  serato: { title: "Serato crates", help: "Writes a new .crate file for each crate into your _Serato_\\Subcrates folder (sub-crates stay nested). Existing Serato crates are never overwritten, and Serato's database, cues and beatgrids aren't touched. Close Serato first; the crates appear when it starts.", dest: "Your _Serato_ folder (in Music, or at the top of an external drive)" },
  rekordbox: { title: "rekordbox XML", help: "Writes one rekordbox XML file with your tracks and a playlist per crate (folders kept). In rekordbox: Preferences → Advanced → Database → rekordbox xml → choose the file, then import the playlists.", dest: "Where to save the .xml file" },
  folders: { title: "Folders", help: "Copies each crate's music into its own folder (sub-crates become sub-folders) with a playlist, verifying every copy. Great for USB sticks and other DJ software. Your originals stay where they are.", dest: "Destination folder or drive (not inside your music folders)" },
};

export function ExportCratesDialog({ crates, onClose, toast }: { crates: Crate[]; onClose: () => void; toast: (m: string, e?: boolean) => void }) {
  const [target, setTarget] = useState<Target>("serato");
  const [sel, setSel] = useState<Set<number>>(new Set(crates.filter((c) => c.parent_id == null).map((c) => c.id)));
  const [dest, setDest] = useState("");
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<string | null>(null);
  const tops = crates.filter((c) => c.parent_id == null);
  const choose = async () => {
    if (target === "rekordbox") {
      const p = await pickSave("Save rekordbox XML", "DJ Assistant crates.xml", ["xml"]);
      if (p) setDest(p);
    } else {
      const p = await pickFolder(target === "serato" ? "Choose your _Serato_ folder" : "Choose where to export");
      if (p) setDest(p);
    }
  };
  const run = async () => {
    setBusy(true);
    setResult(null);
    try {
      const ids = [...sel];
      if (target === "serato") {
        const r = await api.exportSerato(dest, ids);
        setResult(`Wrote ${plural(r.written.length, "crate")} (${r.written.map((w) => w.file).join(", ")}).${r.skipped_other_drive ? ` ${plural(r.skipped_other_drive, "track")} on other drives were left out — export to that drive's _Serato_ folder too.` : ""} ${r.note}`);
      } else if (target === "rekordbox") {
        const r = await api.exportRekordbox(dest, ids);
        setResult(`Saved ${plural(r.tracks, "track")} in ${plural(r.playlists, "playlist")}. ${r.note}`);
      } else {
        await api.exportCrateFolders(dest, ids);
        setResult("Copying in the background — you'll hear a chime when it's done (progress in Scan Activity).");
      }
      playSound(target === "folders" ? "saved" : "export");
    } catch (e) {
      toast((e as Error).message, true);
      playSound("error");
    } finally {
      setBusy(false);
    }
  };
  return (
    <Dialog title="Export crates" onClose={onClose} footer={<>
      <button className="btn ghost" onClick={onClose}>{result ? "Done" : "Cancel"}</button>
      <button className="btn primary" disabled={busy || !dest || sel.size === 0} onClick={run}><Icon name="export" size={15} /> Export {plural(sel.size, "crate")}</button>
    </>}>
      <div className="seg" role="group" aria-label="Export to" style={{ marginBottom: 12 }}>
        {(["serato", "rekordbox", "folders"] as Target[]).map((t) => (
          <button key={t} aria-pressed={target === t} onClick={() => { setTarget(t); setDest(""); setResult(null); }}>{INFO[t].title}</button>
        ))}
      </div>
      <p className="small muted" style={{ marginTop: 0 }}>{INFO[target].help}</p>
      <label className="field">
        {INFO[target].dest}
        <div className="row" style={{ gap: 8 }}>
          <input className="input" style={{ flex: 1 }} value={dest} onChange={(e) => setDest(e.target.value)} placeholder={target === "rekordbox" ? "C:\\Users\\you\\Music\\DJ Assistant crates.xml" : target === "serato" ? "C:\\Users\\you\\Music\\_Serato_" : "E:\\"} aria-label="Export destination" />
          {isDesktop() && <button className="btn" type="button" onClick={choose}><Icon name="folder" size={15} /> Choose…</button>}
        </div>
      </label>
      <div className="small muted" style={{ margin: "12px 0 6px" }}>Crates (sub-crates come along)</div>
      <div className="col" style={{ gap: 4, maxHeight: 220, overflow: "auto" }}>
        {tops.map((c) => (
          <label key={c.id} className="row small" style={{ gap: 8 }}>
            <input type="checkbox" checked={sel.has(c.id)} onChange={() => setSel((s) => { const n = new Set(s); if (n.has(c.id)) n.delete(c.id); else n.add(c.id); return n; })} />
            {c.name} <span className="faint">· {plural(c.track_count, "track")}</span>
          </label>
        ))}
        {tops.length === 0 && <span className="small muted">No crates yet.</span>}
      </div>
      {result && <div className="notice info small" style={{ marginTop: 12 }}><Icon name="check" /><div>{result}</div></div>}
    </Dialog>
  );
}
