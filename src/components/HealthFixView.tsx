import { useEffect, useMemo, useState } from "react";
import { api } from "../api";
import type { FixList, FixRow } from "../types";
import { keyName, musicalToCamelot, plural, text } from "../lib/format";
import { Icon } from "./Icon";

const LABELS: Record<string, string> = { artist: "Artist", title: "Title", genre: "Genre", year: "Year", album: "Album", bpm: "BPM", key: "Key" };
const PLACEHOLDER: Record<string, string> = { year: "e.g. 2016", bpm: "e.g. 124", key: "e.g. 8A or Am", genre: "e.g. Afrobeats" };
const PAGE = 100;

/** Check and convert a typed value. Returns [value for the patch, error]. */
function parseValue(field: string, raw: string): [unknown, string | null] {
  const v = raw.trim();
  if (!v) return [null, null];
  if (field === "year") {
    const n = Number(v);
    if (!Number.isInteger(n) || n < 1900 || n > 2100) return [null, "Year must be between 1900 and 2100"];
    return [n, null];
  }
  if (field === "bpm") {
    const n = Number(v);
    if (!Number.isFinite(n) || n < 40 || n > 300) return [null, "BPM must be between 40 and 300"];
    return [Math.round(n * 100) / 100, null];
  }
  if (field === "key") {
    const c = musicalToCamelot(v);
    if (!c) return [null, "Not a key — try 8A, Am or A minor"];
    return [c, null];
  }
  return [v, null];
}

export function HealthFixView({ category, onBack, toast, bump }: { category: string; onBack: () => void; toast: (m: string, e?: boolean) => void; bump: () => void }) {
  const [list, setList] = useState<FixList | null>(null);
  const [offset, setOffset] = useState(0);
  const [drafts, setDrafts] = useState<Record<number, Record<string, string>>>({});
  const [sel, setSel] = useState<Set<number>>(new Set());
  const [bulk, setBulk] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState<Set<number>>(new Set());
  const [mbOn, setMbOn] = useState(false);

  const load = (o = offset) =>
    api
      .healthFixList(category, PAGE, o)
      .then((l) => {
        setList(l);
        setSel(new Set());
      })
      .catch((e) => toast(e.message, true));
  useEffect(() => {
    setDrafts({});
    setSaved(new Set());
    setOffset(0);
    load(0);
    api.services().then((s) => setMbOn(!!s.find((x) => x.id === "musicbrainz")?.enabled)).catch(() => {});
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [category]);

  const fields = list?.fields ?? [];
  const rows = list?.rows ?? [];
  const draft = (id: number, f: string) => drafts[id]?.[f] ?? "";
  const setDraft = (id: number, f: string, v: string) => setDrafts((d) => ({ ...d, [id]: { ...(d[id] ?? {}), [f]: v } }));
  const edited = useMemo(() => rows.filter((r) => fields.some((f) => draft(r.track.id, f).trim() !== "")), [rows, fields, drafts]); // eslint-disable-line react-hooks/exhaustive-deps
  const errorsFor = (id: number) => fields.map((f) => parseValue(f, draft(id, f))[1]).filter(Boolean) as string[];

  const patchFor = (id: number): Record<string, unknown> | null => {
    const p: Record<string, unknown> = {};
    for (const f of fields) {
      const [v, err] = parseValue(f, draft(id, f));
      if (err) return null;
      if (v != null) p[f] = v;
    }
    return Object.keys(p).length ? p : null;
  };

  const after = async (ids: number[], msg: string) => {
    setSaved((s) => new Set([...s, ...ids]));
    toast(msg);
    bump();
    // Let the saved rows show their tick before they leave the list.
    setTimeout(() => {
      setDrafts((d) => {
        const n = { ...d };
        ids.forEach((i) => delete n[i]);
        return n;
      });
      load();
    }, 650);
  };

  const saveRows = async (target: FixRow[]) => {
    const jobs = target.map((r) => [r.track.id, patchFor(r.track.id)] as const).filter((x) => x[1]);
    if (!jobs.length) return toast("Nothing to save — type a value or pick a suggestion first.", true);
    setBusy(true);
    try {
      for (const [id, p] of jobs) await api.updateUserFields([id], p!);
      await after(jobs.map((j) => j[0]), `Saved ${plural(jobs.length, "track")} to your catalogue. Files were not changed.`);
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  const applyBulk = async () => {
    const p: Record<string, unknown> = {};
    for (const f of fields) {
      const [v, err] = parseValue(f, bulk[f] ?? "");
      if (err) return toast(err, true);
      if (v != null) p[f] = v;
    }
    if (!Object.keys(p).length) return toast("Type a value to apply.", true);
    const ids = [...sel];
    setBusy(true);
    try {
      await api.updateUserFields(ids, p);
      setBulk({});
      await after(ids, `Set ${Object.keys(p).map((f) => LABELS[f]).join(", ")} on ${plural(ids.length, "track")}. Files were not changed.`);
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  /** Fill every empty draft with the row's first hint. */
  const useTopHints = () => {
    let n = 0;
    setDrafts((d) => {
      const out = { ...d };
      for (const r of rows) {
        for (const f of fields) {
          if ((out[r.track.id]?.[f] ?? "").trim()) continue;
          const h = r.hints.find((x) => x.field === f);
          if (h) {
            out[r.track.id] = { ...(out[r.track.id] ?? {}), [f]: f === "key" ? keyName(h.value) : h.value };
            n++;
          }
        }
      }
      return out;
    });
    setTimeout(() => toast(n ? `Filled ${plural(n, "value")} from the top suggestion. Review, then save.` : "No suggestions to fill in."), 0);
  };

  const run = async (p: Promise<unknown>, msg: string, reload = true) => {
    setBusy(true);
    try {
      await p;
      toast(msg);
      if (reload) await load();
    } catch (e) {
      toast((e as Error).message, true);
    } finally {
      setBusy(false);
    }
  };

  const ids = rows.map((r) => r.track.id);
  const allSel = ids.length > 0 && ids.every((i) => sel.has(i));
  const analysable = fields.includes("bpm") || fields.includes("key");
  const hintCount = rows.reduce((n, r) => n + r.hints.length, 0);

  return (
    <>
      <div className="view-head">
        <button className="btn ghost icon-btn" onClick={onBack} aria-label="Back to Library health" title="Back"><Icon name="back" size={18} /></button>
        <div className="grow">
          <h1>Fix: {list?.label ?? "…"}</h1>
          <div className="sub">Fill in what's missing. Values are saved to DJ Assistant's catalogue only — your music files and Serato are not changed.</div>
        </div>
        <button className="btn" disabled={busy} onClick={() => run(api.generateSuggestions(), "Checked file names, folders and spellings for suggestions.")}><Icon name="wand" size={16} /> Find local suggestions</button>
        {(fields.includes("year") || fields.includes("album") || fields.includes("genre") || fields.includes("artist") || fields.includes("title")) && (
          <button
            className="btn"
            disabled={busy || !ids.length}
            title={mbOn ? "Sends artist and title of these tracks to MusicBrainz" : "Turn on MusicBrainz in Settings → Online services"}
            onClick={() => (mbOn ? run(api.lookupMusicBrainz({ ids: sel.size ? [...sel] : ids }), "MusicBrainz lookup started (one request per second). Press Refresh in a moment to see new suggestions.", false) : toast("MusicBrainz is off. Turn it on in Settings → Online services.", true))}
          >
            <Icon name="cloud" size={16} /> MusicBrainz lookup
          </button>
        )}
        {analysable && (
          <button className="btn" disabled={busy || !ids.length} onClick={() => run(api.startAnalysis(sel.size ? [...sel] : ids), "Analysis started in the background. Estimated values fill these in automatically when it finishes.", false)}>
            <Icon name="activity" size={16} /> Analyse {sel.size ? "selected" : "these"}
          </button>
        )}
      </div>
      <div className="view-body">
        {!list ? (
          <div className="skeleton" style={{ height: 240 }} />
        ) : rows.length === 0 ? (
          <div className="empty">
            <div className="success" aria-hidden>
              <svg viewBox="0 0 52 52"><circle cx="26" cy="26" r="24" /><path d="M15 27l7 7 15-15" /></svg>
            </div>
            <h2>All fixed</h2>
            <p>No tracks are missing {fields.map((f) => LABELS[f].toLowerCase()).join(" or ")} any more.</p>
            <button className="btn" onClick={onBack}>Back to Library health</button>
          </div>
        ) : (
          <>
            <div className="fix-toolbar panel">
              <label className="row" style={{ gap: 8 }}>
                <input type="checkbox" checked={allSel} onChange={() => setSel(allSel ? new Set() : new Set(ids))} aria-label="Select all on this page" />
                <span className="small">{sel.size ? `${sel.size} selected` : `${plural(list.total, "track")} to fix`}</span>
              </label>
              {sel.size > 0 ? (
                <>
                  {fields.map((f) => (
                    <input key={f} className="input" style={{ width: f === "year" || f === "bpm" || f === "key" ? 120 : 180 }} placeholder={`${LABELS[f]} for selected`} value={bulk[f] ?? ""} onChange={(e) => setBulk({ ...bulk, [f]: e.target.value })} aria-label={`${LABELS[f]} for selected tracks`} />
                  ))}
                  <button className="btn primary small" disabled={busy} onClick={applyBulk}>Apply to {plural(sel.size, "track")}</button>
                </>
              ) : (
                <span className="small muted">Tip: select tracks to set one value on all of them (for example a whole album's year).</span>
              )}
              <div className="grow" />
              <button className="btn small" disabled={!hintCount} onClick={useTopHints}><Icon name="sparkles" size={14} /> Use top suggestions</button>
              <button className="btn primary small" disabled={busy || !edited.length} onClick={() => saveRows(edited)}>Save {edited.length ? plural(edited.length, "edited track") : "edits"}</button>
            </div>

            <div className="fix-list stagger">
              {rows.map((r) => {
                const id = r.track.id;
                const errs = errorsFor(id);
                const done = saved.has(id);
                return (
                  <div key={id} className={`fix-row panel${sel.has(id) ? " selected" : ""}${done ? " done" : ""}`}>
                    <input type="checkbox" checked={sel.has(id)} onChange={() => setSel((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n; })} aria-label={`Select ${r.track.file_name}`} />
                    <div className="fix-who">
                      <strong className="ellipsis">{r.track.title || <span className="faint">No title</span>}</strong>
                      <span className="small muted ellipsis">{r.track.artist || "Unknown artist"}{r.track.album ? ` · ${r.track.album}` : ""}{r.track.year ? ` · ${r.track.year}` : ""}{r.track.genre ? ` · ${r.track.genre}` : ""}</span>
                      <span className="small faint ellipsis mono" title={r.track.path}>{r.folder ? `${r.folder}/` : ""}{r.track.file_name}</span>
                    </div>
                    <div className="fix-fields">
                      {fields.map((f) => {
                        const hints = r.hints.filter((h) => h.field === f);
                        const current = f === "key" ? r.track.key : (r.track as unknown as Record<string, unknown>)[f];
                        return (
                          <div key={f} className="fix-field">
                            <label className="small muted">
                              {LABELS[f]}
                              {current != null && current !== "" && <span className="faint"> · now {f === "key" ? keyName(String(current)) : text(current as string)}</span>}
                            </label>
                            <input className="input" value={draft(id, f)} placeholder={PLACEHOLDER[f] ?? "Type a value"} onChange={(e) => setDraft(id, f, e.target.value)} onKeyDown={(e) => { if (e.key === "Enter") saveRows([r]); }} aria-label={`${LABELS[f]} for ${r.track.file_name}`} />
                            {hints.length > 0 && (
                              <div className="row wrap" style={{ gap: 6 }}>
                                {hints.slice(0, 4).map((h, i) => (
                                  <button key={i} className={`chip preset hint${draft(id, f) === (f === "key" ? keyName(h.value) : h.value) ? " on" : ""}`} title={`${h.source}: ${h.evidence}`} onClick={() => setDraft(id, f, f === "key" ? keyName(h.value) : h.value)}>
                                    {f === "key" ? keyName(h.value) : h.value}
                                    <span className="faint small">{h.source}</span>
                                  </button>
                                ))}
                              </div>
                            )}
                          </div>
                        );
                      })}
                      {errs.length > 0 && <div className="s-error small">{errs[0]}</div>}
                    </div>
                    <div className="fix-act">
                      {done ? (
                        <span className="tick-sm" aria-label="Saved"><Icon name="check" size={16} /></span>
                      ) : (
                        <button className="btn small" disabled={busy || !patchFor(id)} onClick={() => saveRows([r])}>Save</button>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>

            {list.total > PAGE && (
              <div className="row" style={{ justifyContent: "center", marginTop: 14, gap: 10 }}>
                <button className="btn small" disabled={offset === 0} onClick={() => { const o = Math.max(0, offset - PAGE); setOffset(o); load(o); }}>Previous</button>
                <span className="small muted">{offset + 1}–{Math.min(offset + PAGE, list.total)} of {list.total}</span>
                <button className="btn small" disabled={offset + PAGE >= list.total} onClick={() => { const o = offset + PAGE; setOffset(o); load(o); }}>Next</button>
              </div>
            )}
            <p className="note" style={{ marginTop: 16 }}>Suggestions come from your own library — file and folder names, other tracks on the same album or by the same artist — and from lookups you ran. Hover a suggestion to see why it was offered. Nothing is filled in until you choose it and save.</p>
          </>
        )}
      </div>
    </>
  );
}
