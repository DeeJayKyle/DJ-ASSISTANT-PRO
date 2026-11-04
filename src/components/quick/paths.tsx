import { useEffect, useMemo, useState } from "react";
import { api } from "../../api";
import { bpm as fmtBpm, keyName, longDuration, plural } from "../../lib/format";
import type { CleanName, NameFormat } from "../../lib/quick/names";
import { FAMILIES, GENRES, family, normaliseGenre } from "../../lib/quick/genres";
import { applySort, parseSortRequest, setCost, type SortCommand } from "../../lib/quick/setlist";
import type { Layout } from "../../lib/quick/layout";
import { EnergyMeter } from "../ui";
import { Icon } from "../Icon";
import { flatBins, msg, type QScreen, type QState, type QTrack } from "./model";
import { PlayButton, WaveBar } from "./player";
import { QuickExport } from "./QuickExport";

interface Ctx {
  st: QState;
  patch: (p: Partial<QState> | ((s: QState) => Partial<QState>)) => void;
  tracks: QTrack[];
  toast: (m: string, e?: boolean) => void;
  reload: () => Promise<void>;
  bump: () => void;
  go: (s: QScreen) => void;
}

/** Reads back a name typed in the chosen format ("Artist - Title (Mix)"). */
export function parseTyped(text: string, format: NameFormat): CleanName {
  let s = text.trim();
  let mix = "";
  const m = s.match(/^(.*?)\s*[([]([^()[\]]+)[)\]]\s*$/);
  if (m && m[1]) { s = m[1]; mix = m[2].trim(); }
  const parts = s.split(/\s+[-–—]\s+/);
  if (parts.length < 2) return { artist: "", title: s, mix };
  const [a, ...rest] = parts;
  return format === "artist-title" ? { artist: a.trim(), title: rest.join(" - ").trim(), mix } : { artist: rest.join(" - ").trim(), title: a.trim(), mix };
}

const setTracks = (ts: QTrack[]) => ts.map((t) => ({ id: String(t.id), bpm: t.bpm, camelot: t.camelot, energy: t.energy, genre: t.genre, t }));

function useAi() {
  const [on, setOn] = useState(false);
  useEffect(() => { api.aiStatus().then((s) => setOn(s.ready)).catch(() => setOn(false)); }, []);
  return on;
}

function Meta({ t, children }: { t: QTrack; children?: React.ReactNode }) {
  return (
    <div className="qp-meta">
      <span><span className="lbl">BPM</span><b>{t.row.analysis == null && !t.bpm ? "…" : fmtBpm(t.row.bpm)}</b></span>
      <span><span className="lbl">Key</span><b>{t.row.analysis == null && !t.camelot ? "…" : keyName(t.camelot)}</b></span>
      <EnergyMeter value={t.row.energy} estimate={t.row.energy_source === "analysis"} />
      {children}
    </div>
  );
}

function GenreSelect({ t, ctx }: { t: QTrack; ctx: Ctx }) {
  const choose = (g: string) => api.updateUserFields([t.id], { genre: g }).then(() => {
    ctx.patch((s) => ({ proposals: { ...s.proposals, [t.id]: { ...(s.proposals[t.id] ?? { name: t.name, edited: false }), genre: undefined } } }));
    ctx.reload();
  }).catch((e) => ctx.toast(msg(e), true));
  return (
    <select className="select qp-genre" aria-label={`Genre of ${t.name.title}`} value={t.genre} onChange={(e) => choose(e.target.value)}>
      {!GENRES.includes(t.genre) && <option value={t.genre}>{t.genre}</option>}
      {Object.entries(FAMILIES).map(([fam, list]) => <optgroup key={fam} label={fam}>{list.map((g) => <option key={g} value={g}>{g}</option>)}</optgroup>)}
    </select>
  );
}

function CleanupBanner({ ctx }: { ctx: Ctx }) {
  const n = ctx.tracks.filter((t) => t.messy && !t.edited).length;
  if (!n || ctx.st.cleanupDismissed) return null;
  return (
    <div className="notice warn" role="status" style={{ marginBottom: 12, alignItems: "center" }}>
      <Icon name="wand" />
      <span style={{ flex: 1 }}>{plural(n, "track")} {n === 1 ? "needs" : "need"} a name cleanup{ctx.st.useClean ? " — clean names are used when you export." : "."}</span>
      <button className="btn small" onClick={() => ctx.go("clean")}>Review names</button>
      <button className="btn small ghost" onClick={() => ctx.patch({ cleanupDismissed: true })}>Skip</button>
    </div>
  );
}

function ExportButton({ label, onClick, disabled }: { label: string; onClick: () => void; disabled?: boolean }) {
  return <button className="btn primary qp-fab" onClick={onClick} disabled={disabled}><Icon name="download" size={16} /> {label}</button>;
}

// ---------------------------------------------------------------- Clean names
export function CleanNames(ctx: Ctx) {
  const { st, patch, tracks, toast } = ctx;
  const [exporting, setExporting] = useState(false);
  const [busy, setBusy] = useState(false);
  const ai = useAi();
  const rerun = () => {
    patch({ proposals: {} });
    toast("Names re-made automatically; your edits and AI suggestions were cleared.");
  };
  const improve = async () => {
    setBusy(true);
    try {
      const todo = tracks.filter((t) => !t.edited);
      let n = 0;
      for (let i = 0; i < todo.length; i += 25) {
        const batch = todo.slice(i, i + 25);
        const res = await api.aiTidy(batch.map((t) => ({ id: t.id, current: { artist: t.name.artist, title: t.name.title, mix: t.name.mix, genre: t.genre } })), GENRES);
        n += res.length;
        patch((s) => {
          const proposals = { ...s.proposals };
          for (const r of res) {
            const cur = proposals[r.id];
            if (cur?.edited) continue;
            const g = r.genre ? normaliseGenre(r.genre) : null;
            proposals[r.id] = { name: { artist: r.artist, title: r.title, mix: r.mix }, edited: false, genre: g ? { value: g, source: "ai" } : cur?.genre };
          }
          return { proposals };
        });
      }
      toast(`AI suggested names for ${plural(n, "track")}. Check them, then export or save.`);
    } catch (e) {
      toast(msg(e), true);
    } finally {
      setBusy(false);
    }
  };
  const saveAll = async () => {
    const { saveProposals } = await import("./QuickExport");
    try {
      const n = await saveProposals({ ...st, useClean: true }, tracks);
      await ctx.reload();
      ctx.bump();
      toast(n ? `Saved clean names for ${plural(n, "track")} to your catalogue. Files weren't changed.` : "Your catalogue already has these names.");
    } catch (e) { toast(msg(e), true); }
  };
  return (
    <div className="col" style={{ gap: 12, paddingBottom: 70 }}>
      <div className="row wrap">
        <p className="small muted" style={{ flex: "1 1 280px", margin: 0 }}>Click a name to edit it. Originals are never renamed — clean names go into your catalogue and exports.</p>
        <div className="seg" role="group" aria-label="Name format">
          {(["artist-title", "title-artist"] as const).map((f) => <button key={f} aria-pressed={st.format === f} onClick={() => patch({ format: f })}>{f === "artist-title" ? "Artist – Title" : "Title – Artist"}</button>)}
        </div>
        <button className="btn" onClick={improve} disabled={busy || !ai} title={ai ? "Uses the AI model chosen for the assistant" : "Turn on the AI assistant in Settings (optional)"}><Icon name="sparkles" size={16} /> {busy ? "Asking AI…" : "Improve with AI"}</button>
        <button className="btn ghost" onClick={rerun}><Icon name="refresh" size={16} /> Re-run</button>
        <button className="btn" onClick={saveAll}><Icon name="check" size={16} /> Save names to catalogue</button>
      </div>
      <div className="panel" style={{ padding: 0 }}>
        <div className="qp-row qp-head small faint"><span>ORIGINAL FILE</span><span /><span>CLEAN NAME</span></div>
        {tracks.map((t) => <CleanRow key={t.id} t={t} ctx={ctx} />)}
      </div>
      <div className="panel">
        <h3>Names look good? What's next</h3>
        <label className="check small" style={{ margin: "6px 0 10px" }}><input type="checkbox" checked={!st.useClean} onChange={(e) => patch({ useClean: !e.target.checked })} /> Keep the original file names when exporting</label>
        <div className="row wrap">
          <button className="btn" onClick={() => ctx.go("playlist")}>Build a playlist <Icon name="right" size={15} /></button>
          <button className="btn" onClick={() => ctx.go("folders")}>Organise folders <Icon name="right" size={15} /></button>
          <button className="btn" onClick={() => ctx.go("genres")}>Split by genre <Icon name="right" size={15} /></button>
        </div>
      </div>
      <ExportButton label="Export clean tracks" onClick={() => setExporting(true)} disabled={!tracks.length} />
      {exporting && <QuickExport st={st} tracks={tracks} layout={{ kind: "clean" }} name="Clean tracks" onClose={() => setExporting(false)} onSaved={() => { ctx.reload(); ctx.bump(); }} toast={toast} />}
    </div>
  );
}

function CleanRow({ t, ctx }: { t: QTrack; ctx: Ctx }) {
  const [draft, setDraft] = useState<string | null>(null);
  const commit = () => {
    if (draft === null) return;
    const text = draft.trim();
    setDraft(null);
    if (!text || text === t.display) return;
    ctx.patch((s) => ({ proposals: { ...s.proposals, [t.id]: { ...s.proposals[t.id], name: parseTyped(text, s.format), edited: true } } }));
  };
  return (
    <div className="qp-row">
      <div style={{ minWidth: 0 }}>
        <div className="qp-orig" title={t.row.path}>{t.row.file_name}</div>
        <div className="row" style={{ marginTop: 6 }}><PlayButton id={t.id} label={t.display} /><Meta t={t} /></div>
      </div>
      <span className="faint" aria-hidden>→</span>
      <div style={{ minWidth: 0 }}>
        <input className="qp-name" value={draft ?? t.display} aria-label={`Clean name for ${t.row.file_name}`} onChange={(e) => setDraft(e.target.value)} onBlur={commit} onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); if (e.key === "Escape") setDraft(null); }} />
        <div className="row" style={{ marginTop: 6 }}>
          <GenreSelect t={t} ctx={ctx} />
          {t.genreSource === "guess" && <span className="badge" title="Guessed from BPM and energy — pick one to keep it">guess</span>}
          {t.genreSource === "ai" && <span className="badge" title="Suggested by AI — saved when you export">AI</span>}
          {t.edited && <span className="badge qp-badge">edited</span>}
          {t.edited && <button className="btn small ghost" onClick={() => ctx.patch((s) => { const p = { ...s.proposals }; delete p[t.id]; return { proposals: p }; })}>Undo</button>}
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Playlist
const QUICK: { cmd: SortCommand; label: string }[] = [
  { cmd: "warmup-peak", label: "Warm-up → peak" },
  { cmd: "ascending-bpm", label: "Ascending BPM" },
  { cmd: "key", label: "Harmonic (key)" },
  { cmd: "genre", label: "Group by genre" },
  { cmd: "energy-down", label: "Cool down" },
];

export function Playlist(ctx: Ctx) {
  const { st, patch, tracks, toast } = ctx;
  const byId = useMemo(() => new Map(tracks.map((t) => [t.id, t])), [tracks]);
  const order = [...st.playlist.order.filter((id) => byId.has(id)), ...tracks.filter((t) => !st.playlist.order.includes(t.id)).map((t) => t.id)];
  const list = order.map((id) => byId.get(id)!);
  const [drag, setDrag] = useState<number | null>(null);
  const [over, setOver] = useState<number | null>(null);
  const [ask, setAsk] = useState("");
  const [busy, setBusy] = useState(false);
  const [active, setActive] = useState<SortCommand | null>(null);
  const [numbered, setNumbered] = useState(true);
  const [exporting, setExporting] = useState(false);
  const ai = useAi();
  const setOrder = (ids: number[], note = "") => patch((s) => ({ playlist: { ...s.playlist, order: ids, note } }));
  const sortBy = (cmd: SortCommand) => { setActive(cmd); setOrder(applySort(cmd, setTracks(list)).map((x) => x.t.id)); };
  const submit = async () => {
    const text = ask.trim();
    if (!text) return;
    const simple = parseSortRequest(text);
    if (!ai) {
      if (simple) { sortBy(simple); setAsk(""); }
      else toast("Try “warm-up to peak”, “by BPM”, “fastest first” or “harmonic” — or turn on the AI assistant in Settings for anything else.");
      return;
    }
    setBusy(true);
    try {
      const r = await api.aiOrder(text, order);
      setActive(null);
      setOrder(r.order, r.note);
      setAsk("");
    } catch (e) {
      if (simple) { sortBy(simple); setAsk(""); toast("AI unavailable — sorted with the built-in rules instead."); }
      else toast(msg(e), true);
    } finally { setBusy(false); }
  };
  const move = (from: number, to: number) => {
    if (from === to) return;
    const ids = order.filter((x) => x !== from);
    ids.splice(ids.indexOf(to), 0, from);
    setActive(null);
    setOrder(ids);
  };
  const nudge = (id: number, d: number) => {
    const i = order.indexOf(id), j = i + d;
    if (j < 0 || j >= order.length) return;
    const ids = [...order];
    [ids[i], ids[j]] = [ids[j], ids[i]];
    setOrder(ids);
  };
  const flow = list.length > 1 ? Math.max(0, Math.round(100 - setCost(setTracks(list)) * 12)) : null;
  const total = list.reduce((s, t) => s + (t.row.duration_ms ?? 0), 0);
  const name = st.playlist.name.trim() || "My Set";
  return (
    <div className="col" style={{ gap: 12 }}>
      <CleanupBanner ctx={ctx} />
      <div className="row wrap">
        <input className="qp-name qp-title" value={st.playlist.name} aria-label="Playlist name" onChange={(e) => patch((s) => ({ playlist: { ...s.playlist, name: e.target.value } }))} />
        <span className="small muted">{plural(list.length, "track")}{total ? ` · ${longDuration(total)}` : ""}{flow !== null ? ` · flow score ${flow}/100` : ""}</span>
      </div>
      <div className="row wrap">{QUICK.map((q) => <button key={q.cmd} className={`chip preset${active === q.cmd ? " on" : ""}`} aria-pressed={active === q.cmd} onClick={() => sortBy(q.cmd)}>{q.label}</button>)}</div>
      {st.playlist.note && <p className="small muted" style={{ margin: 0 }}><Icon name="sparkles" size={14} /> {st.playlist.note}</p>}
      <div className="panel" style={{ padding: 0 }} role="list">
        {list.map((t, i) => (
          <div key={t.id} role="listitem" draggable className={`qp-ptrack${drag === t.id ? " dragging" : ""}${over === t.id && drag !== t.id ? " over" : ""}`}
            onDragStart={(e) => { setDrag(t.id); e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", String(t.id)); }}
            onDragOver={(e) => { if (drag != null) { e.preventDefault(); setOver(t.id); } }}
            onDrop={(e) => { e.preventDefault(); if (drag != null) move(drag, t.id); setDrag(null); setOver(null); }}
            onDragEnd={() => { setDrag(null); setOver(null); }}>
            <span className="faint" aria-hidden><Icon name="grip" size={16} /></span>
            <span className="mono faint">{String(i + 1).padStart(2, "0")}</span>
            <div style={{ minWidth: 0 }}>
              <div className="qp-tt">{t.display}</div>
              <Meta t={t}><span className="small">{t.genre}</span><span className="badge">{t.role}</span></Meta>
            </div>
            <div className="row">
              <PlayButton id={t.id} label={t.display} />
              <button className="btn small icon ghost" onClick={() => nudge(t.id, -1)} disabled={i === 0} aria-label={`Move ${t.name.title} up`}><Icon name="arrowUp" size={14} /></button>
              <button className="btn small icon ghost" onClick={() => nudge(t.id, 1)} disabled={i === list.length - 1} aria-label={`Move ${t.name.title} down`}><Icon name="arrowDown" size={14} /></button>
            </div>
          </div>
        ))}
      </div>
      <div className="qp-askbar">
        <form className="qp-ask" onSubmit={(e) => { e.preventDefault(); void submit(); }}>
          <Icon name="sparkles" size={16} />
          <input value={ask} onChange={(e) => setAsk(e.target.value)} placeholder={ai ? "Ask for an order — e.g. “start deep, peak with the techno, end uplifting”" : "Ask for an order — e.g. “warm up to peak”, “fastest first”, “harmonic”"} aria-label="Describe how to order the playlist" disabled={busy} />
          <button className="btn primary small" disabled={busy || !ask.trim()}>{busy ? "Thinking…" : "Sort"}</button>
        </form>
        <div className="row wrap" style={{ marginTop: 10 }}>
          <label className="check small" style={{ flex: 1 }}><input type="checkbox" checked={numbered} onChange={(e) => setNumbered(e.target.checked)} /> Number the files in play order (01, 02…)</label>
          <button className="btn" onClick={() => api.createCrate({ name, kind: "manual" }).then((c) => api.crateAdd(c.id, order)).then(() => { ctx.bump(); toast(`Saved as crate “${name}”.`); }).catch((e) => toast(msg(e), true))}><Icon name="crate" size={16} /> Save as crate</button>
          <button className="btn primary" onClick={() => setExporting(true)} disabled={!list.length}><Icon name="download" size={16} /> Export playlist</button>
        </div>
      </div>
      {exporting && <QuickExport st={st} tracks={tracks} layout={{ kind: "playlist", name, order, numbered }} name={name} onClose={() => setExporting(false)} onSaved={() => { ctx.reload(); ctx.bump(); }} toast={toast} />}
    </div>
  );
}

// ---------------------------------------------------------------- Folders
export function Folders(ctx: Ctx) {
  return ctx.st.foldersReady ? <Sorter ctx={ctx} /> : <FolderSetupView ctx={ctx} />;
}

function FolderSetupView({ ctx }: { ctx: Ctx }) {
  const { st, patch } = ctx;
  const [f, setF] = useState(() => structuredClone(st.folders));
  const subs = f.mains.reduce((n, m) => n + m.subs.length, 0);
  const update = (fn: (x: typeof f) => void) => setF((old) => { const x = structuredClone(old); fn(x); return x; });
  const valid = f.mains.length > 0 && f.mains.every((m) => m.name.trim() && m.subs.every((s) => s.trim()));
  const start = () => {
    const clean = { mains: f.mains.map((m) => ({ name: m.name.trim(), subs: m.subs.map((s) => s.trim()) })) };
    const count = flatBins(clean).length;
    patch((s) => ({ folders: clean, foldersReady: true, bins: Object.fromEntries(Object.entries(s.bins).filter(([, b]) => b < count)) }));
  };
  return (
    <div className="col" style={{ gap: 12, maxWidth: 860 }}>
      <p className="muted" style={{ margin: 0 }}>Set up the folders you want — one per gig, say, with energy sub-folders — then sort tracks into them while you listen.</p>
      <span className="badge qp-badge" style={{ alignSelf: "flex-start" }}>{f.mains.length} main · {subs} sub</span>
      {f.mains.map((m, i) => (
        <div key={i} className="panel qp-main">
          <div className="row">
            <Icon name="folder" />
            <input className="input" style={{ flex: 1, fontWeight: 650 }} value={m.name} aria-label={`Main folder ${i + 1} name`} onChange={(e) => update((x) => { x.mains[i].name = e.target.value; })} />
            <button className="btn icon ghost" aria-label={`Remove ${m.name || "folder"}`} onClick={() => update((x) => { x.mains.splice(i, 1); })}><Icon name="close" size={16} /></button>
          </div>
          <div className="col" style={{ paddingLeft: 30, marginTop: 8 }}>
            {m.subs.map((s, j) => (
              <div key={j} className="row">
                <span className="faint">└</span>
                <input className="input" style={{ flex: 1 }} value={s} aria-label={`${m.name} sub-folder ${j + 1}`} onChange={(e) => update((x) => { x.mains[i].subs[j] = e.target.value; })} />
                <button className="btn icon ghost small" aria-label={`Remove ${s || "sub-folder"}`} onClick={() => update((x) => { x.mains[i].subs.splice(j, 1); })}><Icon name="close" size={14} /></button>
              </div>
            ))}
            <button className="btn small ghost" style={{ alignSelf: "flex-start" }} onClick={() => update((x) => { x.mains[i].subs.push(`Folder ${x.mains[i].subs.length + 1}`); })}><Icon name="plus" size={14} /> Add sub-folder</button>
          </div>
        </div>
      ))}
      <div className="row">
        <button className="btn" onClick={() => update((x) => { x.mains.push({ name: `Folder ${String.fromCharCode(65 + x.mains.length)}`, subs: ["Warm Up", "Groove", "Peak Time"] }); })}><Icon name="plus" size={15} /> Add main folder</button>
        <span className="spacer" style={{ flex: 1 }} />
        <button className="btn primary" disabled={!valid} onClick={start}>Start sorting <Icon name="right" size={16} /></button>
      </div>
      {!valid && <p className="small" style={{ color: "var(--amber)", margin: 0 }}>Every folder needs a name, and you need at least one.</p>}
    </div>
  );
}

function Sorter({ ctx }: { ctx: Ctx }) {
  const { st, patch, tracks, toast } = ctx;
  const bins = useMemo(() => flatBins(st.folders), [st.folders]);
  const [sel, setSel] = useState<Set<number>>(new Set());
  const [focus, setFocus] = useState<number | null>(null);
  const [filter, setFilter] = useState<"unsorted" | "all">("unsorted");
  const [order, setOrder] = useState<number[] | null>(null);
  const [ask, setAsk] = useState("");
  const [overBin, setOverBin] = useState<number | null>(null);
  const [exporting, setExporting] = useState(false);
  const ordered = order ? order.map((id) => tracks.find((t) => t.id === id)).filter((t): t is QTrack => !!t) : tracks;
  const shown = ordered.filter((t) => filter === "all" || st.bins[t.id] === undefined);
  const sorted = tracks.filter((t) => st.bins[t.id] !== undefined).length;
  const focusTrack = tracks.find((t) => t.id === focus) ?? shown[0];
  const setBin = (ids: number[], bin: number | null) => patch((s) => { const b = { ...s.bins }; for (const id of ids) { if (bin == null) delete b[id]; else b[id] = bin; } return { bins: b }; });
  const targets = () => (sel.size ? [...sel] : focusTrack ? [focusTrack.id] : []);
  const send = (ids: number[], bin: number) => {
    if (!ids.length) return;
    setBin(ids, bin);
    const next = shown.find((t) => !ids.includes(t.id));
    setSel(new Set(next ? [next.id] : []));
    setFocus(next?.id ?? null);
  };
  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement).tagName;
      if (["INPUT", "SELECT", "TEXTAREA"].includes(tag)) return;
      const n = Number(e.key);
      if (n >= 1 && n <= Math.min(9, bins.length)) { e.preventDefault(); send(targets(), n - 1); }
      if (e.key === "0" || e.key === "Backspace") setBin(targets(), null);
    };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  });
  const pick = (id: number, multi: boolean) => {
    setFocus(id);
    setSel((old) => { if (!multi) return new Set([id]); const s = new Set(old); if (s.has(id)) s.delete(id); else s.add(id); return s; });
  };
  const autoByRole = () => {
    const adds: Record<number, number> = {};
    for (const t of tracks) {
      if (st.bins[t.id] !== undefined) continue;
      const i = bins.findIndex((b) => b.sub.toLowerCase() === t.role.toLowerCase());
      if (i >= 0) adds[t.id] = i;
    }
    const n = Object.keys(adds).length;
    patch((s) => ({ bins: { ...s.bins, ...adds } }));
    toast(n ? `Sorted ${plural(n, "track")} into the first Warm Up / Groove / Peak Time folders.` : "No unsorted track matched a sub-folder called Warm Up, Groove or Peak Time.");
  };
  const sortList = () => {
    const cmd = parseSortRequest(ask);
    if (!cmd) { toast("Try “by BPM”, “by energy” or “harmonic”."); return; }
    setOrder(applySort(cmd, setTracks(tracks)).map((x) => x.t.id));
    setAsk("");
  };
  const layout: Layout = { kind: "folders", bins: bins.map((b, i) => ({ ...b, ids: tracks.filter((t) => st.bins[t.id] === i).map((t) => t.id) })) };
  const saveCrates = async () => {
    try {
      const parent = await api.createCrate({ name: `Quick Prep · ${st.label || "Folders"}`, kind: "manual" });
      for (const [i, b] of bins.entries()) {
        const ids = layout.kind === "folders" ? layout.bins[i].ids : [];
        if (!ids.length) continue;
        const c = await api.createCrate({ name: b.sub ? `${b.main} – ${b.sub}` : b.main, kind: "manual", parent_id: parent.id });
        await api.crateAdd(c.id, ids);
      }
      ctx.bump();
      toast(`Saved as crates under “${parent.name}”. Nothing was copied.`);
    } catch (e) { toast(msg(e), true); }
  };
  let binNo = 0;
  return (
    <div className="col" style={{ gap: 12 }}>
      <CleanupBanner ctx={ctx} />
      <div className="row wrap">
        <p className="small muted" style={{ flex: 1, margin: 0 }}>{sorted} of {tracks.length} sorted · select a track, then press a folder's number (or drag it there). Shift/Ctrl-click selects several; 0 takes a track out.</p>
        <button className="btn ghost" onClick={() => patch({ foldersReady: false })}>Edit folders</button>
        <button className="btn" onClick={autoByRole}><Icon name="zap" size={15} /> Auto-sort by energy</button>
      </div>
      <div className="qp-sorter">
        <div className="col" style={{ gap: 8 }}>
          <div className="seg" role="group" aria-label="Show">
            <button aria-pressed={filter === "unsorted"} onClick={() => setFilter("unsorted")}>Unsorted ({tracks.length - sorted})</button>
            <button aria-pressed={filter === "all"} onClick={() => setFilter("all")}>All ({tracks.length})</button>
          </div>
          {focusTrack && (
            <div className="panel" style={{ padding: 12 }}>
              <div className="row"><PlayButton id={focusTrack.id} label={focusTrack.display} /><div className="qp-tt" style={{ flex: 1 }}>{focusTrack.display}</div></div>
              <div style={{ marginTop: 8 }}><WaveBar id={focusTrack.id} label={focusTrack.display} /></div>
            </div>
          )}
          <div className="panel qp-tracks" style={{ padding: 0 }} role="listbox" aria-multiselectable="true" aria-label="Tracks">
            {shown.length === 0 && <p className="small muted" style={{ padding: 14, margin: 0 }}>Everything is sorted. Export when you're ready, or show all tracks to move some.</p>}
            {shown.map((t) => {
              const b = st.bins[t.id] !== undefined ? bins[st.bins[t.id]] : undefined;
              const selected = sel.has(t.id);
              return (
                <div key={t.id} role="option" aria-selected={selected} tabIndex={0} draggable className={`qp-strack${selected ? " sel" : ""}`}
                  onClick={(e) => pick(t.id, e.shiftKey || e.metaKey || e.ctrlKey)}
                  onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); pick(t.id, e.shiftKey || e.ctrlKey); } }}
                  onDragStart={(e) => { e.dataTransfer.setData("text/plain", JSON.stringify(selected ? [...sel] : [t.id])); e.dataTransfer.effectAllowed = "move"; }}>
                  <div className="row"><input type="checkbox" checked={selected} readOnly tabIndex={-1} aria-hidden /><div className="qp-tt" style={{ flex: 1 }}>{t.display}</div><PlayButton id={t.id} label={t.display} /></div>
                  <div style={{ paddingLeft: 24, marginTop: 4 }}><Meta t={t}><span className="small">{t.genre}</span>{b && <span className="badge qp-badge">{b.sub ? `${b.main} / ${b.sub}` : b.main}</span>}</Meta></div>
                </div>
              );
            })}
          </div>
        </div>
        <div className="col" style={{ gap: 12 }}>
          {st.folders.mains.map((m, mi) => (
            <div key={mi} className="qp-main panel">
              <div className="row"><Icon name="folder" size={16} /><h3 style={{ margin: 0 }}>{m.name}</h3></div>
              <div className="qp-bins">
                {(m.subs.length ? m.subs : [""]).map((s) => {
                  const i = binNo++;
                  const inBin = tracks.filter((t) => st.bins[t.id] === i);
                  return (
                    <button key={`${mi}/${s}`} className={`qp-bin${overBin === i ? " over" : ""}`} onClick={() => send(targets(), i)}
                      onDragOver={(e) => { e.preventDefault(); setOverBin(i); }} onDragLeave={() => setOverBin(null)}
                      onDrop={(e) => { e.preventDefault(); setOverBin(null); try { send(JSON.parse(e.dataTransfer.getData("text/plain") || "[]"), i); } catch { /* not ours */ } }}
                      aria-label={`Send to ${m.name}${s ? ` / ${s}` : ""} (key ${i + 1}), ${inBin.length} tracks`}>
                      {i < 9 && <span className="k">{i + 1}</span>}
                      <span className="lbl">{s || m.name}</span>
                      <div className="mono" style={{ fontSize: 20 }}>{inBin.length}</div>
                      <ul>{inBin.slice(0, 4).map((t) => <li key={t.id}>{t.name.title}</li>)}{inBin.length > 4 && <li className="faint">+{inBin.length - 4} more</li>}</ul>
                    </button>
                  );
                })}
              </div>
            </div>
          ))}
        </div>
      </div>
      <div className="qp-askbar">
        <form className="qp-ask" onSubmit={(e) => { e.preventDefault(); sortList(); }}>
          <Icon name="sortDown" size={16} />
          <input value={ask} onChange={(e) => setAsk(e.target.value)} placeholder="Order the track list — “by BPM”, “by energy”, “harmonic”" aria-label="Order the track list" />
          <button className="btn primary small" disabled={!ask.trim()}>Order</button>
        </form>
        <div className="row wrap" style={{ marginTop: 10 }}>
          <span className="small muted" style={{ flex: 1 }}>{tracks.length - sorted ? `${plural(tracks.length - sorted, "unsorted track")} go into an “Unsorted” folder.` : "All tracks sorted."}</span>
          <button className="btn" onClick={saveCrates} disabled={!sorted}><Icon name="crate" size={16} /> Save as crates</button>
          <button className="btn primary" onClick={() => setExporting(true)} disabled={!tracks.length}><Icon name="download" size={16} /> Export folders</button>
        </div>
      </div>
      {exporting && <QuickExport st={st} tracks={tracks} layout={layout} name={st.label ? `${st.label} – organised` : "Organised folders"} onClose={() => setExporting(false)} onSaved={() => { ctx.reload(); ctx.bump(); }} toast={toast} />}
    </div>
  );
}

// ---------------------------------------------------------------- Genres
export function Genres(ctx: Ctx) {
  const { st, patch, tracks, toast } = ctx;
  const [open, setOpen] = useState<string | null>(null);
  const [exporting, setExporting] = useState(false);
  const groups = useMemo(() => {
    const m = new Map<string, QTrack[]>();
    for (const t of tracks) { const g = st.families ? family(t.genre) : t.genre || "Other"; m.set(g, [...(m.get(g) ?? []), t]); }
    return [...m.entries()].sort((a, b) => b[1].length - a[1].length || a[0].localeCompare(b[0]));
  }, [tracks, st.families]);
  const range = (ts: QTrack[]) => { const b = ts.map((t) => t.bpm).filter(Boolean); return b.length ? `${Math.round(Math.min(...b))}–${Math.round(Math.max(...b))} BPM` : ""; };
  const saveCrates = async () => {
    try {
      const parent = await api.createCrate({ name: `Quick Prep · ${st.label || "Genres"}`, kind: "manual" });
      for (const [g, ts] of groups) {
        const c = await api.createCrate({ name: g, kind: "manual", parent_id: parent.id });
        await api.crateAdd(c.id, ts.map((t) => t.id));
      }
      ctx.bump();
      toast(`Saved ${plural(groups.length, "genre crate")} under “${parent.name}”. Nothing was copied.`);
    } catch (e) { toast(msg(e), true); }
  };
  return (
    <div className="col" style={{ gap: 12, paddingBottom: 70 }}>
      <CleanupBanner ctx={ctx} />
      <div className="row wrap">
        <p className="small muted" style={{ flex: 1, margin: 0 }}>{plural(groups.length, "group")} · change a track's genre and it moves. Each group becomes a folder and a playlist.</p>
        <label className="check card" style={{ padding: "8px 14px" }}>
          <input type="checkbox" checked={st.families} onChange={(e) => patch({ families: e.target.checked })} />
          <span><strong>Group into families</strong><br /><span className="small muted">Tech House + Deep House → House</span></span>
        </label>
        <button className="btn" onClick={saveCrates}><Icon name="crate" size={16} /> Save as crates</button>
      </div>
      <div className="qp-genres">
        {groups.map(([g, ts]) => (
          <div key={g} className="card qp-gcard">
            <h3 className="row" style={{ justifyContent: "space-between", margin: 0 }}><span>{g}</span><span className="badge qp-badge">{ts.length}</span></h3>
            <div className="small faint">{range(ts)}</div>
            <ul>{(open === g ? ts : ts.slice(0, 6)).map((t) => <li key={t.id}><span title={t.display}>{t.display}</span><span className="mono faint">{t.bpm ? Math.round(t.bpm) : ""}</span></li>)}</ul>
            {ts.length > 6 && <button className="btn small ghost" onClick={() => setOpen(open === g ? null : g)}>{open === g ? "Show fewer" : `Show all ${ts.length}`}</button>}
          </div>
        ))}
      </div>
      <details className="panel">
        <summary className="small"><strong>Fix genres</strong> <span className="muted">— every track with its genre</span></summary>
        <div className="col" style={{ marginTop: 10 }}>
          {tracks.map((t) => (
            <div key={t.id} className="row" style={{ borderTop: "1px solid var(--line-soft)", paddingTop: 8 }}>
              <PlayButton id={t.id} label={t.display} />
              <span className="qp-tt" style={{ flex: 1 }}>{t.display}</span>
              {t.genreSource === "guess" && <span className="badge">guess</span>}
              <GenreSelect t={t} ctx={ctx} />
            </div>
          ))}
        </div>
      </details>
      <ExportButton label="Export by genre" onClick={() => setExporting(true)} disabled={!tracks.length} />
      {exporting && <QuickExport st={st} tracks={tracks} layout={{ kind: "genres", families: st.families }} name={st.label ? `${st.label} – by genre` : "By genre"} onClose={() => setExporting(false)} onSaved={() => { ctx.reload(); ctx.bump(); }} toast={toast} />}
    </div>
  );
}

