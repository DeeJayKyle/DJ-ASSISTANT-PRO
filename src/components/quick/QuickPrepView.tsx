import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, isDesktop, pickFolder } from "../../api";
import type { Crate, Root, TrackRow } from "../../types";
import { keyName, plural } from "../../lib/format";
import { Icon } from "../Icon";
import { useAccount } from "../Accounts";
import { initialState, msg, tracksOf, type QScreen, type QState } from "./model";
import { stopPreview } from "./player";
import { CleanNames, Playlist, Folders, Genres } from "./paths";

/** Kept while you visit other views (per account). */
let saved: QState | null = null;

const TITLES: Partial<Record<QScreen, string>> = { clean: "Clean names", playlist: "Build a playlist", folders: "Organise folders", genres: "Split by genre" };

export function QuickPrepView({ crates, roots, toast, bump }: { crates: Crate[]; roots: Root[]; toast: (m: string, e?: boolean) => void; bump: () => void }) {
  const account = useAccount()?.current.id ?? "";
  const [st, setSt] = useState<QState>(() => (saved?.account === account ? saved : initialState(account)));
  const stRef = useRef(st);
  stRef.current = st;
  useEffect(() => { saved = st; }, [st]);
  useEffect(() => () => stopPreview(), []);
  const patch = useCallback((p: Partial<QState> | ((s: QState) => Partial<QState>)) => setSt((s) => ({ ...s, ...(typeof p === "function" ? p(s) : p) })), []);
  const go = (screen: QScreen) => { stopPreview(); patch({ screen }); };

  const allIds = async (q: { root_id?: number; crate_id?: number }) => {
    const ids: number[] = [];
    const rows: Record<number, TrackRow> = {};
    for (let offset = 0; ; offset += 2000) {
      const page = await api.search({ ...q, sort: "artist", limit: 2000, offset });
      for (const r of page.rows) { ids.push(r.id); rows[r.id] = r; }
      if (ids.length >= page.total || !page.rows.length || ids.length >= 20000) break;
    }
    return { ids, rows };
  };

  /** Reloads the batch's catalogue rows (after analysis or edits). */
  const reload = useCallback(async () => {
    const { source, ids } = stRef.current;
    const keep = new Set(ids);
    const { rows } = await allIds(source).catch(() => ({ rows: {} as Record<number, TrackRow> }));
    patch((s) => ({ rows: { ...s.rows, ...Object.fromEntries(Object.entries(rows).filter(([id]) => keep.has(Number(id)))) } }));
  }, [patch]);

  /** Scan (for a new folder) → analyse what's missing → ready. */
  const prepare = async (label: string, load: () => Promise<{ root?: number; crate?: number }>) => {
    patch({ ...initialState(account), format: st.format, folders: st.folders, screen: "analysing", label, phase: { step: "scanning", done: 0, total: 0 } });
    try {
      const src = await load();
      if (src.root != null) {
        for (;;) {
          const s = await api.scanStatus();
          if (s.state !== "running" && s.state !== "paused") break;
          patch({ phase: { step: "scanning", done: s.files_processed + s.unchanged, total: s.files_found } });
          await new Promise((r) => setTimeout(r, 400));
        }
      }
      const source = src.root != null ? { root_id: src.root } : src.crate != null ? { crate_id: src.crate } : {};
      const { ids, rows } = await allIds(source);
      const usable = ids.filter((id) => rows[id].status === "ok" && rows[id].media_kind === "audio");
      stRef.current = { ...stRef.current, source, ids: usable };
      patch({ source, ids: usable, rows, playlist: { name: label || "My Set", order: usable, note: "" } });
      if (!usable.length) {
        patch({ phase: { step: "failed", done: 0, total: 0, message: "No playable audio found there." } });
        return;
      }
      const todo = usable.filter((id) => rows[id].analysis == null);
      if (todo.length) {
        await api.startAnalysis(todo).catch((e) => { if (!/already running|busy/i.test(msg(e))) throw e; });
        let lastDone = -1;
        for (;;) {
          const j = await api.jobStatus("analysis");
          if (j.done !== lastDone) { lastDone = j.done; await reload(); }
          patch({ phase: { step: "analysing", done: j.done, total: j.total || todo.length } });
          if (j.state !== "running" && j.state !== "paused") break;
          await new Promise((r) => setTimeout(r, 600));
        }
      }
      await reload();
      patch({ phase: { step: "ready", done: usable.length, total: usable.length } });
      bump();
    } catch (e) {
      patch({ phase: { step: "failed", done: 0, total: 0, message: msg(e) } });
    }
  };

  const addFolder = async (path: string) => {
    const p = path.trim();
    if (!p) return;
    const known = roots.find((r) => r.path.replace(/[\\/]+$/, "").toLowerCase() === p.replace(/[\\/]+$/, "").toLowerCase());
    await prepare(p.split(/[\\/]/).filter(Boolean).pop() ?? p, async () => {
      const root = known ?? (await api.addRoot(p));
      await api.startScan([root.id]).catch((e) => { if (!/already running/i.test(msg(e))) throw e; });
      return { root: root.id };
    });
  };

  const tracks = useMemo(() => tracksOf(st), [st]);
  const ctx = { st, patch, tracks, toast, reload, bump };
  const inPath = !!TITLES[st.screen];

  return (
    <div className="page">
      <div className="view-head">
        <div className="grow">
          <h1>Quick Prep{inPath && <span className="faint" style={{ fontWeight: 500 }}> · {TITLES[st.screen]}</span>}</h1>
          <div className="sub">{st.screen === "start" ? "Drop in a folder and get it gig-ready: clean names, a playlist, folders or genres — then export a verified copy." : `${st.label} · ${plural(tracks.length, "track")}`}</div>
        </div>
        {inPath && <button className="btn" onClick={() => go("paths")}><Icon name="back" size={16} /> All paths</button>}
        {st.screen !== "start" && <button className="btn ghost" onClick={() => { stopPreview(); setSt({ ...initialState(account), format: st.format, folders: st.folders }); }}>Start over</button>}
      </div>
      <div className="view-body">
        {st.screen === "start" && <Start crates={crates} roots={roots} onFolder={addFolder} onRoot={(r) => prepare(r.label ?? r.path, async () => ({ root: r.id }))} onCrate={(c) => prepare(c.name, async () => ({ crate: c.id }))} toast={toast} />}
        {st.screen === "analysing" && <Analysing st={st} tracks={tracks} onContinue={() => go("paths")} onBack={() => go("start")} />}
        {st.screen === "paths" && <Paths st={st} tracks={tracks} go={go} />}
        {st.screen === "clean" && <CleanNames {...ctx} go={go} />}
        {st.screen === "playlist" && <Playlist {...ctx} go={go} />}
        {st.screen === "folders" && <Folders {...ctx} go={go} />}
        {st.screen === "genres" && <Genres {...ctx} go={go} />}
      </div>
    </div>
  );
}

function Start({ crates, roots, onFolder, onRoot, onCrate, toast }: { crates: Crate[]; roots: Root[]; onFolder: (p: string) => void; onRoot: (r: Root) => void; onCrate: (c: Crate) => void; toast: (m: string, e?: boolean) => void }) {
  const [path, setPath] = useState("");
  const [pick, setPick] = useState("");
  const FEATURES = [
    ["wand", "Clean names", "Strips “[FREE DL]”, “320kbps”, track numbers and underscores, and fixes capitals."],
    ["set", "Build a playlist", "Warm-up to peak with harmonic mixing, by BPM, or from what you type."],
    ["folder", "Organise folders", "Sort into gig folders with a key press while you listen."],
    ["layers", "Split by genre", "Group by genre or by family, ready for your DJ software."],
  ];
  return (
    <div className="col" style={{ gap: 18, maxWidth: 980 }}>
      <div className="panel qp-drop">
        <Icon name="folder" size={30} />
        <h2 style={{ margin: "8px 0 4px" }}>Add a folder of tracks</h2>
        <p className="muted" style={{ marginTop: 0, maxWidth: 560 }}>It's added to your library (read-only) and analysed on this computer — BPM, key, energy. Your files are never changed, moved or renamed.</p>
        <div className="row wrap" style={{ justifyContent: "center" }}>
          {isDesktop() && <button className="btn primary big" onClick={() => pickFolder("Choose a folder of tracks").then((p) => p && onFolder(p)).catch((e) => toast(msg(e), true))}><Icon name="folder" size={18} /> Choose a folder</button>}
          <form className="row" onSubmit={(e) => { e.preventDefault(); onFolder(path); }}>
            <input className="input" style={{ width: 340 }} value={path} onChange={(e) => setPath(e.target.value)} placeholder={isDesktop() ? "…or paste a folder path" : "Folder path"} aria-label="Folder path" />
            <button className="btn" disabled={!path.trim()}>Use folder</button>
          </form>
        </div>
        {(roots.length > 0 || crates.length > 0) && (
          <div className="row wrap" style={{ justifyContent: "center", marginTop: 12 }}>
            <span className="small muted">Or work on something already in your library:</span>
            <select className="select" value={pick} onChange={(e) => setPick(e.target.value)} aria-label="Library folder or crate">
              <option value="">Choose…</option>
              {roots.length > 0 && <optgroup label="Library folders">{roots.map((r) => <option key={r.id} value={`root:${r.id}`}>{r.label ?? r.path}</option>)}</optgroup>}
              {crates.length > 0 && <optgroup label="Crates">{crates.map((c) => <option key={c.id} value={`crate:${c.id}`}>{c.name} ({c.track_count})</option>)}</optgroup>}
            </select>
            <button className="btn" disabled={!pick} onClick={() => { const [k, v] = pick.split(":"); if (k === "root") onRoot(roots.find((r) => r.id === Number(v))!); else onCrate(crates.find((c) => c.id === Number(v))!); }}>Start</button>
          </div>
        )}
      </div>
      <div className="qp-features">
        {FEATURES.map(([icon, t, d]) => (
          <div key={t} className="card"><Icon name={icon} size={20} /><h3 style={{ margin: "8px 0 4px" }}>{t}</h3><p className="small muted" style={{ margin: 0 }}>{d}</p></div>
        ))}
      </div>
    </div>
  );
}

function Analysing({ st, tracks, onContinue, onBack }: { st: QState; tracks: ReturnType<typeof tracksOf>; onContinue: () => void; onBack: () => void }) {
  const p = st.phase;
  const ready = p.step === "ready";
  const done = tracks.filter((t) => t.row.analysis != null).slice(-14);
  return (
    <div className="col" style={{ gap: 16, maxWidth: 900 }}>
      <div>
        <h2>{ready ? "Tracks ready." : p.step === "failed" ? "That didn't work" : p.step === "scanning" ? "Reading the folder…" : "Listening to your tracks…"}</h2>
        <p className="muted" style={{ margin: "4px 0 12px" }}>
          {p.step === "scanning" && `${p.done} files read so far (read-only).`}
          {p.step === "analysing" && `${p.done} of ${p.total} analysed — tempo, key and energy, all on this computer.`}
          {ready && `${plural(tracks.length, "track")} with BPM, key and energy.`}
          {p.step === "failed" && p.message}
        </p>
        <div className={`progress${p.step === "scanning" ? " indeterminate" : ""}`} role="progressbar" aria-label="Progress" aria-valuenow={p.done} aria-valuemax={p.total || undefined}><div style={{ width: p.step === "scanning" ? undefined : `${ready ? 100 : p.total ? (100 * p.done) / p.total : 0}%` }} /></div>
      </div>
      <div className="row wrap" aria-live="polite" style={{ minHeight: 34 }}>
        {done.map((t) => <span key={t.id} className="chip qp-chip"><b className="mono">{t.bpm ? Math.round(t.bpm) : "—"}</b><span className="muted">{keyName(t.camelot)}</span><span>{t.genre}</span></span>)}
      </div>
      <div className="row">
        {p.step === "failed" ? <button className="btn" onClick={onBack}><Icon name="back" size={16} /> Back</button> : <button className="btn primary" disabled={!tracks.length} onClick={onContinue}>{ready ? "Continue" : "Continue while it finishes"} <Icon name="right" size={16} /></button>}
      </div>
      <BeatHop />
    </div>
  );
}

function Paths({ st, tracks, go }: { st: QState; tracks: ReturnType<typeof tracksOf>; go: (s: QScreen) => void }) {
  const bpms = tracks.map((t) => t.bpm).filter(Boolean);
  const PATHS: [QScreen, string, string, string][] = [
    ["clean", "wand", "Clean names", "Tidy names, check BPM, key and genre, and fix anything by hand."],
    ["playlist", "set", "Build a playlist", "Order a set from warm-up to peak, by tempo, or from what you ask for."],
    ["folders", "folder", "Organise folders", "Sort tracks into gig folders and energy sub-folders while you listen."],
    ["genres", "layers", "Split by genre", "Group the batch by genre — or by families like House or Techno."],
  ];
  return (
    <div className="col" style={{ gap: 16 }}>
      <div className="kpis">
        <div className="card stat"><small>Tracks</small><strong>{tracks.length}</strong></div>
        <div className="card stat"><small>BPM range</small><strong>{bpms.length ? `${Math.round(Math.min(...bpms))}–${Math.round(Math.max(...bpms))}` : "—"}</strong></div>
        <div className="card stat"><small>Genres</small><strong>{new Set(tracks.map((t) => t.genre)).size}</strong></div>
        <div className="card stat"><small>Messy names</small><strong>{tracks.filter((t) => t.messy && !t.edited).length}</strong></div>
      </div>
      <h2 style={{ margin: 0 }}>What do you want to do?</h2>
      <div className="qp-paths">
        {PATHS.map(([s, icon, title, text]) => (
          <button key={s} className="card link qp-path" onClick={() => go(s)}>
            <span className="qp-ico"><Icon name={icon} size={22} /></span>
            <span style={{ flex: 1, textAlign: "left" }}><strong style={{ fontSize: 16 }}>{title}</strong><br /><span className="small muted">{text}</span></span>
            <Icon name="right" />
          </button>
        ))}
      </div>
      {st.phase.step === "analysing" && <p className="small muted">Still analysing {st.phase.total - st.phase.done} tracks — values fill in as they finish.</p>}
    </div>
  );
}

/** “Beat Hop”: an original one-button mini game while tracks are analysed. Space, ↑ or click. */
function BeatHop() {
  const ref = useRef<HTMLCanvasElement>(null);
  const [score, setScore] = useState(0);
  const [best, setBest] = useState(() => { try { return Number(localStorage.getItem("dja-beathop")) || 0; } catch { return 0; } });
  const jump = useRef<() => void>(() => {});
  useEffect(() => {
    const c = ref.current;
    const g = c?.getContext("2d");
    if (!c || !g) return;
    let raf = 0, y = 0, vy = 0, t = 0, speed = 4, pts = 0, alive = true, started = false;
    let bars: { x: number; h: number; passed: boolean }[] = [];
    const css = getComputedStyle(document.documentElement);
    const mint = css.getPropertyValue("--mint").trim() || "#4fe0a6";
    const amber = css.getPropertyValue("--amber").trim() || "#f3b648";
    jump.current = () => {
      started = true;
      if (!alive) { y = 0; vy = 0; bars = []; speed = 4; pts = 0; alive = true; setScore(0); return; }
      if (y === 0) vy = 10.5;
    };
    const loop = () => {
      const dpr = window.devicePixelRatio || 1, W = c.clientWidth, H = c.clientHeight, ground = H - 26;
      if (c.width !== W * dpr) { c.width = W * dpr; c.height = H * dpr; }
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, W, H);
      g.fillStyle = "rgba(255,255,255,0.08)";
      g.fillRect(0, ground, W, 1);
      if (started && alive) {
        t++;
        vy -= 0.6; y = Math.max(0, y + vy); if (y === 0) vy = 0;
        if (!bars.length || bars[bars.length - 1].x < W - (220 + Math.random() * 240)) bars.push({ x: W + 20, h: 18 + Math.random() * 34, passed: false });
        for (const b of bars) b.x -= speed;
        bars = bars.filter((b) => b.x > -30);
        speed = Math.min(10, 4 + t / 900);
        for (const b of bars) {
          if (!b.passed && b.x + 14 < 70) { b.passed = true; pts++; setScore(pts); }
          if (b.x < 79 && b.x + 14 > 61 && y < b.h) {
            alive = false;
            setBest((o) => { const nb = Math.max(o, pts); try { localStorage.setItem("dja-beathop", String(nb)); } catch { /* private mode */ } return nb; });
          }
        }
      }
      g.fillStyle = amber;
      for (const b of bars) g.fillRect(b.x, ground - b.h, 14, b.h);
      const r = 9 + (alive ? Math.sin(t / 6) * 1.5 : 0);
      g.fillStyle = alive ? mint : "#ff7a72";
      g.beginPath(); g.arc(70, ground - y - r, r, 0, Math.PI * 2); g.fill();
      g.fillStyle = "rgba(255,255,255,0.5)"; g.font = "12px ui-monospace, monospace"; g.textAlign = "center";
      if (!started) g.fillText("Press SPACE or click to hop", W / 2, H / 2);
      else if (!alive) g.fillText("Missed the beat — SPACE to go again", W / 2, H / 2);
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    const key = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement).tagName;
      if ((e.code === "Space" || e.code === "ArrowUp") && !["INPUT", "BUTTON", "SELECT", "TEXTAREA"].includes(tag)) { e.preventDefault(); jump.current(); }
    };
    window.addEventListener("keydown", key);
    return () => { cancelAnimationFrame(raf); window.removeEventListener("keydown", key); };
  }, []);
  return (
    <div>
      <div className="row small muted" style={{ marginBottom: 6 }}><span style={{ flex: 1 }}>Beat Hop — while you wait</span><span className="mono">Score {score} · Best {best}</span></div>
      <canvas ref={ref} className="qp-game" onClick={() => jump.current()} aria-label="Beat Hop mini game. Press space to hop." />
    </div>
  );
}
