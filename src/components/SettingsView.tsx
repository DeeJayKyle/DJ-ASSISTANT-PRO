import { useEffect, useRef, useState } from "react";
import { api, isDesktop, openUrl, pickFile, pickFolder } from "../api";
import type { AiStatus, ChangeLogEntry, Labels, Service, Settings } from "../types";
import { checkForUpdate, type UpdateInfo } from "../lib/updater";
import { dateTime } from "../lib/format";
import { BACKGROUNDS, PRESETS, type UiPrefs } from "../lib/theme";
import { configureSounds, playSound, type SoundKind } from "../lib/sound";
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


type LocalSetupState = {
  probe: { installed: boolean; running: boolean; models: string[]; details?: LocalModel[] };
  model: string;
  has_model: boolean;
  local_url: string;
  recommended: Array<{ id: string; size: string; note: string }>;
  download: { state: string; done: number; total: number; message: string | null; errors: number; result: unknown };
};

type LocalModel = { name: string; size: number; family: string; parameters: string; can_chat: boolean };

const gb = (n: number) => `${(n / 1e9).toFixed(n >= 1e10 ? 0 : 1)} GB`;

/** One-click setup for a private model on this computer (Ollama). */
function LookAndSound({ settings, onChange, toast }: { settings: Settings; onChange: (s: Settings) => void; toast: (m: string, e?: boolean) => void }) {
  const prefs: UiPrefs = settings.ui_prefs ?? {};
  const save = (patch: Partial<UiPrefs>) => {
    const next = { ...prefs, ...patch };
    onChange({ ...settings, ui_prefs: next });
    api.setSetting("ui_prefs", next).catch((e) => toast(e.message, true));
  };
  const activePreset = prefs.accent ? null : prefs.preset ?? "mint";
  return (
    <section className="panel">
      <h2 style={{ marginBottom: 4 }}>Look &amp; sound</h2>
      <p className="small muted" style={{ marginTop: 0 }}>Make DJ Assistant yours. Changes apply instantly and are saved with your account.</p>
      <div className="col" style={{ gap: 16 }}>
        <div>
          <div className="small muted" style={{ marginBottom: 8 }}>Colour</div>
          <div className="swatches" role="group" aria-label="Colour theme">
            {PRESETS.map((p) => (
              <div key={p.id}>
                <button className="swatch" style={{ background: `linear-gradient(135deg, ${p.accent}, ${p.accent2})` }} aria-pressed={activePreset === p.id} aria-label={`${p.name} colour theme`} onClick={() => save({ preset: p.id, accent: undefined })} />
                <div className="swatch-label">{p.name}</div>
              </div>
            ))}
            <div>
              <input className="color-input" type="color" aria-label="Custom accent colour" value={prefs.accent ?? PRESETS.find((x) => x.id === (prefs.preset ?? "mint"))?.accent ?? "#4fe0a6"} onChange={(e) => save({ accent: e.target.value })} />
              <div className="swatch-label">{prefs.accent ? "Custom ✓" : "Custom"}</div>
            </div>
          </div>
        </div>
        {settings.theme === "dark" && (
          <div>
            <div className="small muted" style={{ marginBottom: 8 }}>Background</div>
            <div className="row wrap" style={{ gap: 10 }} role="group" aria-label="Background style">
              {BACKGROUNDS.map((b) => (
                <button key={b.id} className="bg-swatch" style={{ background: `linear-gradient(160deg, ${b.panel}, ${b.bg})` }} aria-pressed={(prefs.background ?? "deep") === b.id} onClick={() => save({ background: b.id })}>{b.name}</button>
              ))}
            </div>
          </div>
        )}
        <div className="row wrap" style={{ gap: 24, alignItems: "flex-end" }}>
          <div className="col" style={{ gap: 6 }}>
            <span className="small muted">Page transitions</span>
            <div className="seg">{(["slide", "fade", "zoom"] as const).map((t) => <button key={t} aria-pressed={(prefs.transition ?? "slide") === t} onClick={() => save({ transition: t })}>{t[0].toUpperCase() + t.slice(1)}</button>)}</div>
          </div>
          <label className="col" style={{ gap: 6, minWidth: 220 }}>
            <span className="small muted">Animation speed: {(prefs.speed ?? 1) < 0.85 ? "Relaxed" : (prefs.speed ?? 1) > 1.15 ? "Snappy" : "Normal"}</span>
            <input type="range" min={0.5} max={1.5} step={0.05} value={prefs.speed ?? 1} onChange={(e) => save({ speed: Number(e.target.value) })} aria-label="Animation speed" />
          </label>
        </div>
        <div className="row wrap" style={{ gap: 16, alignItems: "center" }}>
          <span className="small muted">Sounds when tasks finish</span>
          <Toggle label="Sounds when tasks finish" checked={prefs.sounds ?? true} onChange={(v) => { save({ sounds: v }); if (v) { configureSounds(true, prefs.volume); playSound("saved"); } }} />
          <input type="range" min={0} max={1} step={0.05} value={prefs.volume ?? 0.6} disabled={prefs.sounds === false} onChange={(e) => save({ volume: Number(e.target.value) })} aria-label="Sound volume" style={{ width: 140 }} />
          <div className="row wrap" style={{ gap: 6 }}>
            {(["scan", "analysis", "prep", "export", "ai", "error"] as SoundKind[]).map((k) => (
              <button key={k} className="btn ghost small" disabled={prefs.sounds === false} onClick={() => { configureSounds(true, prefs.volume); playSound(k); }}>▶ {k === "prep" ? "Auto-prep" : k === "ai" ? "Assistant" : k[0].toUpperCase() + k.slice(1)}</button>
            ))}
          </div>
        </div>
        <button className="btn ghost small" style={{ alignSelf: "flex-start" }} onClick={() => save({ preset: "mint", accent: undefined, background: "deep", transition: "slide", speed: 1 })}>Reset look to default</button>
      </div>
    </section>
  );
}

function LocalSetup({ toast, onChanged }: { toast: (m: string, e?: boolean) => void; onChanged: () => void }) {
  const [s, setS] = useState<LocalSetupState | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [waitingInstall, setWaitingInstall] = useState(false);
  const [other, setOther] = useState("");
  const load = () => api.aiLocalSetup().then(setS).catch(() => {});
  const rescan = () => { setBusy("scan"); api.aiLocalSetup().then((r: LocalSetupState) => { setS(r); toast(r.probe.running ? `Found ${r.probe.models.length} model${r.probe.models.length === 1 ? "" : "s"} on this computer.` : "Ollama isn't answering. Start it first.", !r.probe.running); }).catch(() => {}).finally(() => setBusy(null)); };
  useEffect(() => { load(); }, []);
  const dl = s?.download;
  const downloading = dl?.state === "running" || dl?.state === "paused";
  // Keep checking while something is in progress (installing Ollama, downloading a model).
  useEffect(() => {
    if (!downloading && !waitingInstall && !(s && s.probe.installed && !s.probe.running && busy)) return;
    const t = setInterval(load, 1500);
    return () => clearInterval(t);
  }, [downloading, waitingInstall, busy, s?.probe.installed, s?.probe.running]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (waitingInstall && s?.probe.installed) setWaitingInstall(false);
  }, [waitingInstall, s?.probe.installed]);
  const prevState = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (prevState.current === "running" && dl?.state === "completed") { toast(`${s?.model} is ready — the assistant runs on this computer now.`); onChanged(); }
    if (prevState.current === "running" && dl?.state === "failed") toast(dl.message ?? "The download failed.", true);
    prevState.current = dl?.state;
  }, [dl?.state]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!s) return <div className="skeleton" style={{ height: 120 }} />;
  const { probe } = s;
  const ready = probe.running && s.has_model;
  const installed: LocalModel[] = probe.details ?? probe.models.map((name) => ({ name, size: 0, family: "", parameters: "", can_chat: true }));
  const isInstalled = (id: string) => probe.models.some((m) => m === id || m.replace(/:latest$/, "") === id);
  const otherName = other.trim();
  const validName = /^[A-Za-z0-9][A-Za-z0-9:._\-/]{0,99}$/.test(otherName);
  const pull = (m: string) => api.setSetting("ai_local_model", m).then(() => api.aiLocalPull(m)).then(() => { setOther(""); return load(); }).catch((e) => toast(e.message, true));
  const picker = (
    <div className="col" style={{ gap: 10 }}>
      {probe.running && (
        <div className="col" style={{ gap: 6 }}>
          <div className="row wrap" style={{ gap: 8 }}>
            <span className="small muted grow">{installed.length ? `Found ${installed.length} model${installed.length === 1 ? "" : "s"} on this computer — pick any one:` : "No models on this computer yet. Download one below."}</span>
            <button className="btn ghost small" disabled={busy === "scan"} onClick={rescan}><Icon name="refresh" size={14} /> {busy === "scan" ? "Scanning…" : "Scan again"}</button>
          </div>
          {installed.length > 0 && (
            <div className="model-pick" role="radiogroup" aria-label="Installed local models">
              {installed.map((m) => (
                <label key={m.name} className={`model-opt${s.model === m.name || s.model === m.name.replace(/:latest$/, "") ? " on" : ""}${m.can_chat ? "" : " off"}`}>
                  <input type="radio" name="installed-model" checked={s.model === m.name || s.model === m.name.replace(/:latest$/, "")} disabled={!m.can_chat || downloading} onChange={() => choose(m.name)} />
                  <span><strong>{m.name}</strong> <span className="faint">{[m.parameters, m.size ? gb(m.size) : "", m.family].filter(Boolean).join(" · ")}</span>
                    {!m.can_chat && <><br /><span className="small muted">Embedding model — it can't hold a conversation.</span></>}</span>
                </label>
              ))}
            </div>
          )}
        </div>
      )}
      {downloading ? (
        <div className="col" style={{ gap: 6 }}>
          <div className="progress" aria-label="Model download progress"><div style={{ width: `${dl!.total ? Math.min(100, (dl!.done / dl!.total) * 100) : 2}%` }} /></div>
          <div className="row" style={{ gap: 10 }}>
            <span className="small muted grow">{s.model}: {dl!.message}{dl!.total ? ` — ${gb(dl!.done)} of ${gb(dl!.total)} (${Math.floor((dl!.done / dl!.total) * 100)}%)` : ""}</span>
            <button className="btn ghost small" onClick={() => api.cancelJob("ai_model").then(load)}>Stop</button>
          </div>
          <span className="small faint">You can keep using DJ Assistant. If you stop, the download picks up where it left off next time.</span>
        </div>
      ) : (
        <details className="col" open={!installed.some((m) => m.can_chat)}>
          <summary className="small">Download a model</summary>
          <div className="model-pick" style={{ marginTop: 8 }}>
            {s.recommended.filter((m) => !isInstalled(m.id)).map((m) => (
              <div key={m.id} className="model-opt">
                <span className="grow"><strong>{m.id}</strong> <span className="faint">· {m.size}</span><br /><span className="small muted">{m.note}</span></span>
                <button className="btn small" disabled={!probe.running} onClick={() => pull(m.id)} aria-label={`Download ${m.id}`}><Icon name="download" size={14} /> Download</button>
              </div>
            ))}
          </div>
          <form className="row wrap" style={{ gap: 8, marginTop: 8 }} onSubmit={(e) => { e.preventDefault(); if (validName) pull(otherName); }}>
            <input className="input mono grow" value={other} onChange={(e) => setOther(e.target.value)} placeholder="Any model from ollama.com/library, e.g. mistral or gemma2:9b" aria-label="Other model name" />
            <button className="btn small" disabled={!probe.running || !validName}><Icon name="download" size={14} /> Download</button>
          </form>
          {!probe.running && <span className="small faint">Start Ollama first.</span>}
          {dl?.state === "failed" && <span className="small s-error">{dl.message}</span>}
        </details>
      )}
    </div>
  );
  const step = (done: boolean, n: number, title: string, body: React.ReactNode) => (
    <li className={`setup-step${done ? " done" : ""}`}>
      <span className="setup-n" aria-hidden>{done ? <Icon name="check" size={14} /> : n}</span>
      <div className="grow">
        <strong>{title}</strong>
        {!done && <div className="small muted" style={{ marginTop: 4 }}>{body}</div>}
      </div>
    </li>
  );
  const choose = (m: string) => { setS((x) => (x ? { ...x, model: m } : x)); api.setSetting("ai_local_model", m).then(() => { load(); onChanged(); }).catch((e) => { toast(e.message, true); load(); }); };
  return (
    <div className="col" style={{ gap: 12 }}>
      <p className="small muted" style={{ margin: 0 }}>Runs the assistant on this computer with <strong>Ollama</strong> (free). Nothing leaves your computer. Local models are slower and less reliable than Claude at multi-step tasks.</p>
      <ol className="setup-steps">
        {step(probe.installed, 1, probe.installed ? "Ollama is installed" : "Install Ollama", (
          <div className="col" style={{ gap: 8 }}>
            <span>Download the free installer from ollama.com, run it, then come back here — this page notices when it's installed.</span>
            <div className="row wrap" style={{ gap: 8 }}>
              <button className="btn primary small" onClick={() => { openUrl("https://ollama.com/download").catch(() => {}); setWaitingInstall(true); }}><Icon name="download" size={14} /> Download Ollama</button>
              <button className="btn ghost small" onClick={load}><Icon name="refresh" size={14} /> Check again</button>
              {waitingInstall && <span className="small faint">Waiting for Ollama to be installed…</span>}
            </div>
          </div>
        ))}
        {step(probe.running, 2, probe.running ? "Ollama is running" : "Start Ollama", (
          <div className="row wrap" style={{ gap: 8 }}>
            <button className="btn primary small" disabled={!probe.installed || busy === "start"} onClick={() => { setBusy("start"); api.aiLocalStart().then((r) => { if (!r.running) toast("Ollama is starting — this can take a few seconds.", false); return load(); }).catch((e) => toast(e.message, true)).finally(() => setBusy(null)); }}>
              <Icon name="play" size={14} /> {busy === "start" ? "Starting…" : "Start Ollama"}
            </button>
            <span className="small faint">It runs quietly in the background (look for the llama icon in the system tray).</span>
          </div>
        ))}
        {step(s.has_model, 3, s.has_model ? `Using ${s.model}` : "Choose a model", picker)}
      </ol>
      {ready && (
        <div className="notice info" style={{ margin: 0 }}>
          <Icon name="check" />
          <div>The assistant runs privately on this computer with <strong>{s.model}</strong>.</div>
        </div>
      )}
      {ready && <div className="col" style={{ gap: 8 }}><strong className="small">Models on this computer</strong>{picker}</div>}
    </div>
  );
}

function AiSettings({ toast, onProvider }: { toast: (m: string, e?: boolean) => void; onProvider: () => void }) {
  const [st, setSt] = useState<AiStatus | null>(null);
  const [key, setKey] = useState("");
  const [testing, setTesting] = useState<string | null>(null);
  const load = () => api.aiStatus().then(setSt).catch(() => {});
  useEffect(() => { load(); }, []);
  const changed = () => { load(); onProvider(); window.dispatchEvent(new Event("dj-ai-changed")); };
  const run = (p: Promise<unknown>, msg?: string) => p.then(() => { if (msg) toast(msg); changed(); }).catch((e) => toast(e.message, true));
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
      {st.provider === "local" && <LocalSetup toast={toast} onChanged={changed} />}
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

        <LookAndSound settings={settings} onChange={onChange} toast={toast} />

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

