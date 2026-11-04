import { useEffect, useState } from "react";
import { api, isDesktop, pickFile, pickFolder } from "../api";
import type { AiStatus, ChangeLogEntry, Labels, Service, Settings } from "../types";
import { checkForUpdate, type UpdateInfo } from "../lib/updater";
import { dateTime } from "../lib/format";
import { Dialog } from "./ui";
import { Icon } from "./Icon";

export const SAFETY_POINTS = [
  "Your music is only read. DJ Assistant never renames, moves, replaces or deletes music files.",
  "Tag writing is off by default. If you turn it on, every change is previewed, the original is backed up and verified first, and you can roll it back.",
  "Serato's databases, crates, cues, beatgrids, history and settings are never written. Serato crates and history can be imported read-only.",
  "Your ratings, energy, tags, crates, sets and notes stay in DJ Assistant's own catalogue on this computer.",
  "Only folders you choose are scanned. Personal files are a separate, opt-in module.",
  "Core features work offline with no sign-in and no telemetry; accounts live only on this computer. Online services are off until you turn each one on, and each says exactly what it sends.",
];

function Toggle({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <label className="toggle">
      <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} aria-label={label} />
      <span className="knob" />
    </label>
  );
}


function AiSettings({ toast, onProvider }: { toast: (m: string, e?: boolean) => void; onProvider: () => void }) {
  const [st, setSt] = useState<AiStatus | null>(null);
  const [key, setKey] = useState("");
  const [local, setLocal] = useState<string[] | null>(null);
  const [localErr, setLocalErr] = useState<string | null>(null);
  const [modelName, setModelName] = useState("");
  const [testing, setTesting] = useState<string | null>(null);
  const load = () => api.aiStatus().then((s) => { setSt(s); if (s.provider === "local") setModelName(s.model); }).catch(() => {});
  useEffect(() => { load(); }, []);
  const changed = () => { load(); onProvider(); window.dispatchEvent(new Event("dj-ai-changed")); };
  const run = (p: Promise<unknown>, msg?: string) => p.then(() => { if (msg) toast(msg); changed(); }).catch((e) => toast(e.message, true));
  const findLocal = () => { setLocalErr(null); api.aiLocalModels().then(setLocal).catch((e) => { setLocal(null); setLocalErr(e.message); }); };
  useEffect(() => { if (st?.provider === "local") findLocal(); }, [st?.provider]);
  const test = async () => {
    setTesting("Asking…");
    try {
      const t = await api.aiChat("Reply with one short sentence confirming you can see my library, and say how many tracks it has.");
      api.aiReset(t.conversation_id).catch(() => {});
      setTesting(t.text || "(no reply)");
    } catch (e) {
      setTesting(`Failed: ${(e as Error).message}`);
    }
  };
  if (!st) return null;
  return (
    <section className="panel">
      <div className="row" style={{ marginBottom: 6 }}>
        <h2 style={{ flex: 1 }}>AI assistant</h2>
        {st.ready && <span className="badge q-lossless">Ready</span>}
      </div>
      <p className="small muted" style={{ marginTop: 0 }}>An AI model in the Assistant panel that already knows every feature of DJ Assistant. It looks things up in your library and proposes actions — creating crates, setting energy or genre, planning sets, starting scans — that run only when you press Run. It can never change, move or delete your music files or touch Serato.</p>
      <div className="seg" role="group" aria-label="AI provider" style={{ marginBottom: 12 }}>
        {(["off", "claude", "local"] as const).map((p) => (
          <button key={p} aria-pressed={st.provider === p} onClick={() => run(api.setSetting("ai_provider", p))}>
            {p === "off" ? "Off" : p === "claude" ? "Claude (online)" : "Local model (private)"}
          </button>
        ))}
      </div>
      {st.provider === "claude" && (
        <div className="col" style={{ gap: 10 }}>
          <label className="field">
            Model
            <select className="select" value={st.model} onChange={(e) => run(api.setSetting("ai_model", e.target.value))} aria-label="Claude model">
              {st.claude_models.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
            </select>
          </label>
          <form className="row wrap" style={{ gap: 8 }} onSubmit={(e) => { e.preventDefault(); run(api.setSecret("anthropic", key.trim()), "API key saved in Windows Credential Manager.").then(() => setKey("")); }}>
            <input className="input" style={{ flex: 1, minWidth: 220 }} type="password" autoComplete="off" placeholder={st.has_key ? "Key saved — paste a new one to replace it" : "Anthropic API key (sk-ant-…)"} value={key} onChange={(e) => setKey(e.target.value)} aria-label="Anthropic API key" />
            <button className="btn" type="submit" disabled={!key.trim()}>Save API key</button>
            {st.has_key && <button className="btn ghost" type="button" onClick={() => run(api.deleteSecret("anthropic"), "API key removed.")}>Remove API key</button>}
          </form>
          <p className="small muted" style={{ margin: 0 }}>Get a key at console.anthropic.com (usage is billed to your Anthropic account). The key is stored in Windows Credential Manager, never in DJ Assistant's files.</p>
        </div>
      )}
      {st.provider === "local" && (
        <div className="col" style={{ gap: 10 }}>
          <p className="small muted" style={{ margin: 0 }}>Runs a model on this computer with <strong>Ollama</strong> (free, ollama.com). Install it, then run <code>ollama pull {st.default_local_model}</code> once. Nothing leaves your computer. Smaller local models are slower and less reliable than Claude at multi-step tasks.</p>
          <div className="row wrap" style={{ gap: 8 }}>
            {local && local.length > 0 ? (
              <select className="select" value={st.model} onChange={(e) => run(api.setSetting("ai_local_model", e.target.value))} aria-label="Local model">
                {!local.includes(st.model) && <option value={st.model}>{st.model} (not installed)</option>}
                {local.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
            ) : (
              <form className="row" style={{ gap: 8 }} onSubmit={(e) => { e.preventDefault(); run(api.setSetting("ai_local_model", modelName.trim()), "Local model set."); }}>
                <input className="input" value={modelName} onChange={(e) => setModelName(e.target.value)} aria-label="Local model name" style={{ width: 200 }} />
                <button className="btn" type="submit">Use model</button>
              </form>
            )}
            <button className="btn ghost" onClick={findLocal}><Icon name="refresh" size={15} /> Find installed models</button>
          </div>
          {localErr && <p className="s-error small" style={{ margin: 0 }}>{localErr}</p>}
        </div>
      )}
      <p className="small" style={{ marginBottom: 0 }}><strong>What is sent:</strong> <span className="muted">{st.sends}</span></p>
      {st.provider !== "off" && (
        <div className="row wrap" style={{ gap: 10, marginTop: 10 }}>
          <button className="btn" disabled={!st.ready || testing === "Asking…"} onClick={test}><Icon name="sparkles" size={15} /> Test the assistant</button>
          {!st.ready && st.reason && <span className="small s-error">{st.reason}</span>}
          {testing && <span className="small muted" style={{ flex: 1 }}>{testing}</span>}
        </div>
      )}
    </section>
  );
}

export function SettingsView({ settings, onChange, info, toast, bump }: { settings: Settings; onChange: (s: Settings) => void; info: { version: string; db_path: string } | null; toast: (m: string, e?: boolean) => void; bump: () => void }) {
  const [kbps, setKbps] = useState(String(settings.low_bitrate_kbps));
  const [services, setServices] = useState<Service[]>([]);
  const [keys, setKeys] = useState<Record<string, string>>({});
  const [log, setLog] = useState<ChangeLogEntry[]>([]);
  const [labels, setLabels] = useState<Labels | null>(null);
  const [confirmWrites, setConfirmWrites] = useState(false);
  const [upd, setUpd] = useState<{ state: "idle" | "checking" | "none" | "available" | "installing" | "error"; info?: UpdateInfo; pct?: number | null; msg?: string }>({ state: "idle" });
  const load = () => { api.services().then(setServices); api.changeLog().then(setLog); api.labels().then(setLabels); };
  useEffect(load, []);
  const set = (key: keyof Settings, value: unknown) => api.setSetting(key, value).then(() => onChange({ ...settings, [key]: value } as Settings)).catch((e) => toast(e.message, true));
  const check = async () => {
    setUpd({ state: "checking" });
    try {
      const u = await checkForUpdate();
      setUpd(u ? { state: "available", info: u } : { state: "none" });
    } catch (e) {
      setUpd({ state: "error", msg: String((e as Error).message ?? e) });
    }
  };
  return (
    <div className="page">
      <div className="view-head"><div className="grow"><h1>Settings</h1><div className="sub">Preferences, online services, safety and updates.</div></div></div>
      <div className="view-body col stagger" style={{ gap: 16, maxWidth: 980 }}>
        <section className="panel">
          <div className="row" style={{ marginBottom: 8 }}><h2 style={{ flex: 1 }}>Updates</h2><span className="small muted">Check automatically</span><Toggle label="Check for updates automatically" checked={settings.auto_update} onChange={(v) => set("auto_update", v)} /></div>
          <p className="small muted" style={{ marginTop: 0 }}>Version {info?.version}. New versions are downloaded from the project's GitHub releases, verified with a signature and installed in place — no need to download the installer again. Only your app version and platform are sent when checking.</p>
          <div className="row wrap">
            <button className="btn" onClick={check} disabled={upd.state === "checking" || upd.state === "installing" || !isDesktop()}><Icon name="refresh" size={16} /> Check for updates</button>
            {upd.state === "checking" && <span className="muted small">Checking…</span>}
            {upd.state === "none" && <span className="muted small">You're up to date.</span>}
            {upd.state === "error" && <span className="s-error small">Couldn't check: {upd.msg}</span>}
            {upd.state === "available" && upd.info && (
              <>
                <span className="small"><strong>Version {upd.info.version}</strong> is available.</span>
                <button className="btn primary" onClick={() => { setUpd({ ...upd, state: "installing", pct: 0 }); upd.info!.install((pct) => setUpd((u) => ({ ...u, pct }))).catch((e) => setUpd({ state: "error", msg: String(e) })); }}><Icon name="download" size={16} /> Install and restart</button>
              </>
            )}
            {upd.state === "installing" && <span className="small muted">Downloading {upd.pct ?? "…"}% — the app will restart.</span>}
          </div>
          {upd.info?.notes && upd.state === "available" && <pre className="small muted" style={{ whiteSpace: "pre-wrap", marginTop: 10 }}>{upd.info.notes}</pre>}
        </section>

        <AiSettings toast={toast} onProvider={() => api.getSettings().then(onChange).catch(() => {})} />

        <section className="panel">
          <h2 style={{ marginBottom: 12 }}>Appearance</h2>
          <div className="row wrap" style={{ gap: 20 }}>
            <div className="col" style={{ gap: 6 }}><span className="small muted">Theme</span><div className="seg">{(["dark", "light"] as const).map((t) => <button key={t} aria-pressed={settings.theme === t} onClick={() => set("theme", t)}>{t === "dark" ? "Dark" : "Light"}</button>)}</div></div>
            <div className="col" style={{ gap: 6 }}><span className="small muted">Surfaces</span><div className="seg">{(["glass", "solid"] as const).map((t) => <button key={t} aria-pressed={settings.surface === t} onClick={() => set("surface", t)}>{t === "glass" ? "Glass" : "Solid"}</button>)}</div></div>
            <div className="col" style={{ gap: 6 }}><span className="small muted">Motion</span><div className="seg">{(["full", "reduced"] as const).map((t) => <button key={t} aria-pressed={settings.motion === t} onClick={() => set("motion", t)}>{t === "full" ? "Full" : "Reduced"}</button>)}</div></div>
            <div className="col" style={{ gap: 6 }}><span className="small muted">Premium UI (Midnight Pro)</span><div className="row" style={{ height: 36 }}><Toggle label="Premium UI" checked={settings.premium_ui} onChange={(v) => set("premium_ui", v)} /></div></div>
          </div>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 6 }}>Key notation</h2>
          <p className="small muted" style={{ marginTop: 0 }}>How musical keys are shown in the library, track details, Set Studio and Gig mode. Search, filters and the Assistant accept either form — "8A", "Am" and "A minor" all find the same tracks. Your files are not changed.</p>
          <div className="seg" role="group" aria-label="Key notation">
            {(["camelot", "musical"] as const).map((t) => (
              <button key={t} aria-pressed={settings.key_notation === t} onClick={() => set("key_notation", t)}>
                {t === "camelot" ? "Camelot (8A, 11B)" : "Musical (Am, A)"}
              </button>
            ))}
          </div>
        </section>

        <section className="panel">
          <div className="row" style={{ marginBottom: 6 }}>
            <h2 style={{ flex: 1 }}>Video files</h2>
            <span className="small muted">Include in scans</span>
            <Toggle label="Include video files in scans" checked={settings.scan_video} onChange={(v) => set("scan_video", v)} />
          </div>
          <p className="small muted" style={{ marginTop: 0 }}>Music videos and visuals (MP4, M4V, MOV, MKV, WebM, AVI) are catalogued alongside your audio with their resolution, codec and frame rate, so you can search, rate, tag and crate them. Only the file headers are read — videos are never changed, and tag writing is always off for them. WMV, FLV, MPEG and other formats are listed as unsupported. Takes effect at the next scan.</p>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>Audio quality warning</h2>
          <form className="row wrap" onSubmit={(e) => { e.preventDefault(); const v = Number(kbps); if (Number.isInteger(v)) set("low_bitrate_kbps", v); }}>
            <label className="field" style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>Flag lossy files below<input className="input" style={{ width: 90 }} inputMode="numeric" value={kbps} onChange={(e) => setKbps(e.target.value)} aria-label="Low bitrate threshold in kbps" />kbps</label>
            <button className="btn" type="submit">Save</button>
          </form>
          <p className="note">Applies only to lossy formats with a known bitrate. Lossless and unknown-bitrate files are never flagged. For variable-bitrate files the reported average is used. Bitrate alone does not prove audio quality.</p>
        </section>

        {labels && (
          <section className="panel">
            <h2 style={{ marginBottom: 10 }}>Labels</h2>
            <p className="small muted" style={{ marginTop: 0 }}>Defaults follow the crate &amp; playlist cheat sheet. Rename them to suit your style.</p>
            <div className="grid2">
              <div className="col">{labels.energy.map((e, i) => <label key={i} className="field" style={{ flexDirection: "row", alignItems: "center", gap: 8 }}><span className="mono" style={{ width: 48 }}>{e.min}–{e.max}</span><input className="input" style={{ flex: 1 }} value={e.label} onChange={(ev) => { const en = [...labels.energy]; en[i] = { ...e, label: ev.target.value }; setLabels({ ...labels, energy: en }); }} /></label>)}</div>
              <div className="col">{Object.keys(labels.rating).sort().reverse().map((k) => <label key={k} className="field" style={{ flexDirection: "row", alignItems: "center", gap: 8 }}><span className="stars" style={{ width: 70 }}>{"★".repeat(Number(k))}</span><input className="input" style={{ flex: 1 }} value={labels.rating[k]} onChange={(ev) => setLabels({ ...labels, rating: { ...labels.rating, [k]: ev.target.value } })} /></label>)}</div>
            </div>
            <div className="grid2" style={{ marginTop: 10 }}>{Object.keys(labels.color).map((c) => <label key={c} className="field" style={{ flexDirection: "row", alignItems: "center", gap: 8 }}><span className={`crate-dot c-${c}`} /><input className="input" style={{ flex: 1 }} placeholder={c} value={labels.color[c]} onChange={(ev) => setLabels({ ...labels, color: { ...labels.color, [c]: ev.target.value } })} /></label>)}</div>
            <button className="btn" style={{ marginTop: 12 }} onClick={() => api.setLabels(labels).then(() => toast("Labels saved."))}>Save labels</button>
          </section>
        )}

        <section className="panel">
          <h2 style={{ marginBottom: 6 }}>Online services</h2>
          <p className="small muted" style={{ marginTop: 0 }}>All off by default. Nothing about your audio, file paths, personal files or listening history is sent. API keys are stored in Windows Credential Manager and never shown again.</p>
          {services.filter((s) => s.id !== "updates").map((s) => (
            <div key={s.id} className="list-row" style={{ alignItems: "flex-start" }}>
              <div style={{ flex: 1 }}>
                <strong>{s.name}</strong> <span className="small muted">— {s.provides}</span>
                <div className="small"><span className="muted">Sends:</span> {s.sends}</div>
                {s.needs_key && (
                  <form className="row" style={{ marginTop: 6 }} onSubmit={(e) => { e.preventDefault(); api.setSecret(s.id, keys[s.id] ?? "").then(() => { toast("Key saved to Credential Manager."); setKeys({ ...keys, [s.id]: "" }); load(); }).catch((er) => toast(er.message, true)); }}>
                    <input className="input" type="password" autoComplete="off" style={{ width: 280 }} aria-label={`${s.name} API key`} placeholder={s.has_key ? "Key saved — enter a new one to replace" : "Paste your API key"} value={keys[s.id] ?? ""} onChange={(e) => setKeys({ ...keys, [s.id]: e.target.value })} />
                    <button className="btn small" type="submit" disabled={!(keys[s.id] ?? "").trim()}>Save key</button>
                    {s.has_key && <button className="btn small ghost danger" type="button" onClick={() => api.deleteSecret(s.id).then(load)}>Remove API key</button>}
                  </form>
                )}
              </div>
              <Toggle label={`Turn ${s.name} on`} checked={s.enabled} onChange={(v) => api.setService(s.id, v).then(load)} />
            </div>
          ))}
        </section>

        <section className={`panel${settings.allow_file_changes ? " beam warn" : ""}`}>
          <div className="row" style={{ marginBottom: 6 }}><h2 style={{ flex: 1 }}>Safety: writing tags to files</h2><Toggle label="Allow writing tags to music files" checked={settings.allow_file_changes} onChange={(v) => (v ? setConfirmWrites(true) : set("allow_file_changes", false))} /></div>
          <p className="small muted" style={{ marginTop: 0 }}>Off by default. When on, you can write catalogue values (title, artist, album, genre, year, BPM, key, comment) to MP3, FLAC and M4A files — always with a preview, a verified backup, checks that the audio and Serato's own tag data are preserved, and a rollback.</p>
          <h3 style={{ marginTop: 12 }}>Change log</h3>
          {log.length === 0 && <p className="faint small">No file changes yet.</p>}
          {log.length > 0 && (
            <table className="data-table">
              <thead><tr><th>When</th><th>File</th><th>Change</th><th>Status</th><th /></tr></thead>
              <tbody>{log.map((c) => <tr key={c.id}><td className="small">{dateTime(c.at)}</td><td className="path">{c.path}</td><td className="small">{c.action === "rollback" ? "Rollback" : Object.entries(c.changes as Record<string, [string | null, string | null]>).map(([k, [a, b]]) => `${k}: ${a ?? "∅"} → ${b ?? "∅"}`).join("; ")}{c.error && <div className="s-error">{c.error}</div>}</td><td className="small">{c.status}</td><td>{c.action === "tag_write" && c.status === "done" && <button className="btn small" onClick={() => api.rollback(c.id).then(() => { toast("Restored the original file."); load(); bump(); }).catch((e) => toast(e.message, true))}><Icon name="undo" size={14} /> Roll back</button>}</td></tr>)}</tbody>
            </table>
          )}
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>Import from Serato (read-only)</h2>
          <div className="row wrap">
            <button className="btn" disabled={!isDesktop()} onClick={() => pickFolder("Choose your _Serato_ folder").then((p) => { if (p) api.seratoImport(p).then((r) => { toast(`Imported ${r.crates.length} crates as virtual crates. Serato's files were only read.`); bump(); }).catch((e) => toast(e.message, true)); })}><Icon name="crate" size={16} /> Import Serato crates…</button>
            <button className="btn" disabled={!isDesktop()} onClick={() => pickFile("Choose a Serato history CSV export", ["csv"]).then((p) => { if (p) api.historyImport({ path: p, session: p.split(/[\\/]/).pop() }).then((r) => { toast(`History imported: ${r.matched} matched, ${r.unmatched} not in your library.`); bump(); }).catch((e) => toast(e.message, true)); })}><Icon name="clock" size={16} /> Import history CSV…</button>
            <button className="btn ghost danger" onClick={() => api.clearHistory().then(() => toast("Imported history cleared."))}>Clear imported history</button>
          </div>
          <p className="note">Serato's file formats are undocumented and may change, so imports are copies: nothing is ever written back. Export history from Serato via History → Export → CSV.</p>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>Modules</h2>
          <div className="list-row"><div style={{ flex: 1 }}><strong>Personal files</strong><div className="small muted">Index and search chosen document folders locally. Kept separate from music.</div></div><Toggle label="Enable personal files" checked={settings.docs_enabled} onChange={(v) => set("docs_enabled", v)} /></div>
          <div className="list-row"><div style={{ flex: 1 }}><strong>Folder watcher</strong><div className="small muted">Notice new music in your folders and suggest where to put it (never moves files).</div></div><Toggle label="Enable folder watcher" checked={settings.watch_enabled} onChange={(v) => set("watch_enabled", v)} /></div>
          <div className="list-row"><div style={{ flex: 1 }}><strong>Learn from my ratings and feedback</strong><div className="small muted">Used to rank recommendations. Inspect or reset it in Discovery → What I've learned.</div></div><Toggle label="Enable learning" checked={settings.learning_enabled} onChange={(v) => set("learning_enabled", v)} /></div>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>Safety and privacy</h2>
          <ul style={{ margin: 0, paddingLeft: 18, display: "flex", flexDirection: "column", gap: 6 }}>{SAFETY_POINTS.map((p) => <li key={p}>{p}</li>)}</ul>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>About</h2>
          <dl className="kv"><dt>Version</dt><dd>{info?.version}</dd><dt>Catalogue file</dt><dd className="path">{info?.db_path}</dd></dl>
          <p className="note">Back up the catalogue file to keep your crates, ratings, tags and sets. Third-party licences are listed in THIRD_PARTY_LICENSES.md in the project.</p>
        </section>
      </div>
      {confirmWrites && (
        <Dialog narrow title="Allow writing tags to music files?" onClose={() => setConfirmWrites(false)} footer={<><button className="btn" onClick={() => setConfirmWrites(false)}>Keep it off</button><button className="btn danger solid" onClick={() => { set("allow_file_changes", true); setConfirmWrites(false); }}>Turn on</button></>}>
          <p>This lets you write tags into your music files after previewing each change.</p>
          <ul style={{ paddingLeft: 18 }}><li>Every file is backed up and verified first; nothing is written if the backup fails.</li><li>Writing stops if the file changed since the preview.</li><li>The audio data and every tag you didn't change (including Serato's cue and beatgrid data) are checked to be identical before the file is replaced.</li><li>Every change is logged and can be rolled back.</li></ul>
          <p className="muted">Please try it on copies of a few files first, and keep your own backups. Close Serato before writing tags.</p>
        </Dialog>
      )}
    </div>
  );
}

