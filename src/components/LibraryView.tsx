import { useEffect, useRef, useState } from "react";
import { api, isDesktop, pickFolders, pickSave, reveal } from "../api";
import type { Crate, FieldInfo, Root, RuleNode, RuleSet, TrackDetail as Detail, TrackQuery } from "../types";
import { cleanRuleSet, countRules, describe, emptyRuleSet } from "../lib/rules";
import { bpm, plural, text } from "../lib/format";
import { TrackTable } from "./TrackTable";
import { TrackDetail } from "./TrackDetail";
import { RuleBuilder } from "./RuleBuilder";
import { FilterDropdown, FORMAT_OPTIONS, QUALITY_OPTIONS, type QuickOption } from "./FilterDropdown";
import { Dialog, useDebounced } from "./ui";
import { Icon } from "./Icon";
import { WriteDialog } from "./WriteDialog";

export interface LibraryState {
  text: string;
  filters: RuleSet;
  quick: Record<string, QuickOption | null>;
  sort: string | null;
  desc: boolean;
}

export const emptyLibraryState = (): LibraryState => ({ text: "", filters: emptyRuleSet(), quick: {}, sort: null, desc: false });

export function LibraryView({ state, setState, crate, root, crates, fields, version, bump, toast, onEditCrate, onSaveSmart, searchRef, onAddFolder, onScan, scanning }: {
  state: LibraryState;
  setState: (s: LibraryState) => void;
  crate: Crate | null;
  root: Root | null;
  crates: Crate[];
  fields: FieldInfo[];
  version: number;
  bump: () => void;
  toast: (m: string, err?: boolean) => void;
  onEditCrate: (c: Crate) => void;
  onSaveSmart: (rules: RuleSet) => void;
  searchRef: React.RefObject<HTMLInputElement | null>;
  onAddFolder: () => void;
  onScan: () => void;
  scanning: boolean;
}) {
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [cursor, setCursor] = useState(0);
  const [focusId, setFocusId] = useState<number | null>(null);
  const [drawer, setDrawer] = useState(false);
  const [focus, setFocus] = useState<Detail | null>(null);
  const [total, setTotal] = useState<number | null>(null);
  const [filterOpen, setFilterOpen] = useState(false);
  const [draft, setDraft] = useState<RuleSet>(state.filters);
  const [menu, setMenu] = useState<null | "crate" | "energy" | "tag" | "more">(null);
  const [bulkTag, setBulkTag] = useState("");
  const [writeIds, setWriteIds] = useState<number[] | null>(null);
  const text_ = useDebounced(state.text, 180);
  const quickNodes = Object.values(state.quick).filter(Boolean).map((q) => q!.node);
  const combined: RuleSet = { match: "all", rules: [...quickNodes, ...(state.filters.match === "all" ? state.filters.rules : state.filters.rules.length ? [{ kind: "group", match: "any", rules: state.filters.rules } as RuleNode] : [])], exclude: state.filters.exclude ?? [] };
  const filters = cleanRuleSet(combined, fields);
  const query: TrackQuery = { text: text_.trim() || null, filters, crate_id: crate?.id ?? null, root_id: root?.id ?? null, sort: state.sort, desc: state.desc };
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setSelected(new Set());
    setCursor(0);
  }, [crate?.id, root?.id, text_, JSON.stringify(filters)]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (focusId == null) return setFocus(null);
    api.trackDetail(focusId).then(setFocus).catch(() => setFocus(null));
  }, [focusId, version]);
  useEffect(() => {
    if (!menu) return;
    const close = (e: MouseEvent) => !menuRef.current?.contains(e.target as Node) && setMenu(null);
    window.addEventListener("mousedown", close);
    return () => window.removeEventListener("mousedown", close);
  }, [menu]);

  const ids = [...selected];
  const act = async (fn: () => Promise<unknown>, msg: string) => {
    try {
      await fn();
      toast(msg);
      bump();
    } catch (e) {
      toast(String((e as Error).message ?? e), true);
    }
    setMenu(null);
  };
  const removeNode = (which: "rules" | "exclude", i: number) => setState({ ...state, filters: { ...state.filters, [which]: (state.filters[which] ?? []).filter((_, j) => j !== i) } });
  const active = countRules(cleanRuleSet(state.filters, fields)) + quickNodes.length;
  const setQuick = (k: string, o: QuickOption | null) => setState({ ...state, quick: { ...state.quick, [k]: o } });
  const exportSel = async (kind: "m3u" | "csv") => {
    const name = (crate?.name ?? "DJ Assistant selection").replace(/[\\/:*?"<>|]/g, "_");
    const path = await pickSave(kind === "m3u" ? "Export playlist" : "Export list", `${name}.${kind === "m3u" ? "m3u8" : "csv"}`, kind === "m3u" ? ["m3u8"] : ["csv"]);
    if (!path) return;
    const sel = selected.size ? { ids } : { query };
    act(() => (kind === "m3u" ? api.exportM3u(sel, path) : api.exportCsv(sel, path)), `Exported to ${path}. Your music files were not touched.`);
  };

  const title = crate ? crate.name : root ? root.label ?? root.path : "Music Library";
  const sub = crate
    ? crate.kind === "smart"
      ? `Smart crate · ${crate.rules ? [...crate.rules.rules.map((r) => describe(r, fields)), ...(crate.rules.exclude ?? []).map((r) => "not " + describe(r, fields))].join(crate.rules.match === "all" ? ", " : " or ") : ""}`
      : "Manual crate — tracks are referenced, never copied or moved."
    : root
      ? `${root.path} · ${root.status === "offline" ? "offline" : "online"}`
      : "Your local DJ music collection for Serato DJ";

  return (
    <div className="page">
      <div className="view-head">
        <div className="grow">
          <h1>{title}</h1>
          <div className="sub">{sub}</div>
        </div>
        {crate ? (
          <button className="btn" onClick={() => onEditCrate(crate)}>
            <Icon name="edit" size={16} /> Edit crate
          </button>
        ) : (
          <button className="btn" onClick={onAddFolder}>
            <Icon name="folder" size={18} /> Add folder...
          </button>
        )}
        <button className="btn primary" onClick={onScan} disabled={scanning}>
          <Icon name="refresh" size={18} /> {scanning ? "Scanning…" : "Scan"}
        </button>
      </div>
      <div className="toolbar">
        <div className="row">
          <div className="search">
            <Icon name="search" size={18} />
            <input ref={searchRef} className="input" type="search" placeholder="Search your library (title, artist, etc.)" aria-label="Search tracks" value={state.text} onChange={(e) => setState({ ...state, text: e.target.value })} />
          </div>
        </div>
        <div className="row wrap">
          <FilterDropdown label="Genre" facet="genre" active={state.quick.genre ?? null} onPick={(o) => setQuick("genre", o)} />
          <FilterDropdown label="Decade" facet="decade" active={state.quick.decade ?? null} onPick={(o) => setQuick("decade", o)} />
          <FilterDropdown label="Format" options={FORMAT_OPTIONS} active={state.quick.format ?? null} onPick={(o) => setQuick("format", o)} />
          <FilterDropdown label="Quality" options={QUALITY_OPTIONS} active={state.quick.quality ?? null} onPick={(o) => setQuick("quality", o)} />
          <button className={`dropdown-btn${countRules(state.filters) ? " on" : ""}`} onClick={() => { setDraft(state.filters); setFilterOpen(true); }}>
            <Icon name="smart" size={16} /> More filters{countRules(state.filters) ? ` (${countRules(state.filters)})` : ""}
          </button>
          {active > 0 && (
            <button className="btn ghost small" onClick={() => setState({ ...state, filters: emptyRuleSet(), quick: {} })}>
              Clear all
            </button>
          )}
          {active > 0 && !crate && filters && (
            <button className="btn ghost small" onClick={() => onSaveSmart(filters)}>
              <Icon name="plus" size={14} /> Save as smart crate
            </button>
          )}
          <span className="spacer" />
          <span className="muted" aria-live="polite">{total == null ? "" : plural(total, "track")}</span>
        </div>
        {(state.filters.rules.length > 0 || (state.filters.exclude ?? []).length > 0) && (
          <div className="chips" aria-label="Active filters">
            {state.filters.rules.map((r, i) => (
              <span key={`r${i}`} className="chip">
                {describe(r, fields)}
                <button aria-label={`Remove filter ${describe(r, fields)}`} onClick={() => removeNode("rules", i)}>
                  <Icon name="close" size={13} />
                </button>
              </span>
            ))}
            {(state.filters.exclude ?? []).map((r, i) => (
              <span key={`x${i}`} className="chip exclude">
                not {describe(r, fields)}
                <button aria-label={`Remove exclusion ${describe(r, fields)}`} onClick={() => removeNode("exclude", i)}>
                  <Icon name="close" size={13} />
                </button>
              </span>
            ))}
          </div>
        )}
      </div>
      {(selected.size > 1 || (selected.size === 1 && !selected.has(focusId ?? -1))) && (
        <div className="bulkbar" ref={menuRef}>
          <strong>{plural(selected.size, "track")} selected</strong>
          <span className="rel">
            <button className="btn small" aria-haspopup="menu" aria-expanded={menu === "crate"} onClick={() => setMenu(menu === "crate" ? null : "crate")}>
              <Icon name="crate" size={14} /> Add to crate
            </button>
            {menu === "crate" && (
              <div className="menu" role="menu">
                {crates.filter((c) => c.id !== crate?.id).map((c) => (
                  <button key={c.id} role="menuitem" onClick={() => act(() => api.crateAdd(c.id, ids), `Added ${plural(ids.length, "track")} to “${c.name}”.`)}>
                    {c.name} {c.kind === "smart" && <span className="crate-kind">smart</span>}
                  </button>
                ))}
              </div>
            )}
          </span>
          <span className="rel">
            <button className="btn small" aria-haspopup="menu" aria-expanded={menu === "energy"} onClick={() => setMenu(menu === "energy" ? null : "energy")}>
              Set energy
            </button>
            {menu === "energy" && (
              <div className="menu" role="menu" style={{ minWidth: 140 }}>
                {[10, 9, 8, 7, 6, 5, 4, 3, 2, 1].map((n) => (
                  <button key={n} role="menuitem" onClick={() => act(() => api.updateUserFields(ids, { energy: n }), `Energy set to ${n}.`)}>
                    {n}
                  </button>
                ))}
                <button role="menuitem" onClick={() => act(() => api.updateUserFields(ids, { energy: null }), "Energy cleared.")}>Clear</button>
              </div>
            )}
          </span>
          <span className="rel">
            <button className="btn small" aria-expanded={menu === "tag"} onClick={() => setMenu(menu === "tag" ? null : "tag")}>Add tag</button>
            {menu === "tag" && (
              <form className="menu row" style={{ padding: 8, minWidth: 280 }} onSubmit={(e) => { e.preventDefault(); const t = bulkTag.trim(); if (t) act(() => api.setTags(ids, [t]), `Tagged ${plural(ids.length, "track")} “${t}”.`).then(() => setBulkTag("")); }}>
                <input className="input" autoFocus aria-label="Tag for selected tracks" placeholder="e.g. Opener, Banger, Wedding" value={bulkTag} onChange={(e) => setBulkTag(e.target.value)} />
                <button className="btn primary small" type="submit">Add</button>
              </form>
            )}
          </span>
          <button className="btn small" onClick={() => act(() => api.startAnalysis(ids, true), `Analysing ${plural(ids.length, "track")} in the background.`)}>
            <Icon name="gauge" size={14} /> Analyse
          </button>
          <span className="rel">
            <button className="btn small" aria-expanded={menu === "more"} onClick={() => setMenu(menu === "more" ? null : "more")}>More</button>
            {menu === "more" && (
              <div className="menu" role="menu">
                <button role="menuitem" onClick={() => exportSel("m3u")}><Icon name="export" size={14} /> Export as playlist (M3U8)</button>
                <button role="menuitem" onClick={() => exportSel("csv")}><Icon name="file" size={14} /> Export as CSV</button>
                <button role="menuitem" onClick={() => act(() => api.lookupMusicBrainz({ ids }), "Looking up on MusicBrainz (1 per second). Results appear in Suggestions.")}><Icon name="wand" size={14} /> Look up on MusicBrainz</button>
                <button role="menuitem" onClick={() => { setWriteIds(ids); setMenu(null); }}><Icon name="edit" size={14} /> Write tags to files…</button>
                {crate && (
                  <button role="menuitem" onClick={() => act(() => api.crateRemove(crate.id, ids), crate.kind === "smart" ? "Excluded from this smart crate." : "Removed from crate. Files were not touched.")}>
                    <Icon name="trash" size={14} /> Remove from crate
                  </button>
                )}
              </div>
            )}
          </span>
          <span className="spacer" />
          <button className="btn small ghost" onClick={() => setSelected(new Set())}>Clear selection</button>
        </div>
      )}
      <div className={`library-body${drawer && focusId != null ? " with-detail" : ""}`}>
        <div className="lib-left">
          <div className="table-card glass">
            <TrackTable
              query={query}
              version={version}
              selected={selected}
              onSelect={setSelected}
              onOpen={(id) => { setFocusId(id); }}
              cursor={cursor}
              setCursor={setCursor}
              onTotal={setTotal}
              onSort={(s) => setState({ ...state, sort: s, desc: state.sort === s ? !state.desc : false })}
            />
          </div>
          {focus && (
            <div className="now-card glass" key={focus.row.id}>
              <div className="art"><Icon name="music" size={34} /></div>
              <div style={{ minWidth: 0 }}>
                <div className="row" style={{ gap: 12 }}>
                  <div style={{ minWidth: 0 }}>
                    <div style={{ fontSize: 18, fontWeight: 700 }}>{focus.row.title ?? focus.row.file_name}</div>
                    <div className="muted">{text(focus.row.artist)}</div>
                  </div>
                </div>
                <div className="row" style={{ marginTop: 8, gap: 10 }}>
                  <span className="pill">Original tags</span>
                  <div className="meta">
                    <span>Title: {text(focus.file.title)}</span>
                    <span>Artist: {text(focus.file.artist)}</span>
                    <span>Year: {text(focus.file.year)}</span>
                    <span>Genre: {text(focus.file.genre)}</span>
                    <span>Format: {text(focus.technical.format)}</span>
                    <span>Bitrate: {focus.technical.bitrate_kbps != null ? `${focus.technical.bitrate_kbps} kbps` : "—"}</span>
                    {focus.analysis?.status === "ok" && (focus.analysis.bpm != null || focus.analysis.camelot) && <span>Analysis: {[focus.analysis.bpm != null ? `${bpm(focus.analysis.bpm)} BPM` : null, focus.analysis.camelot ? `key ${focus.analysis.camelot}` : null, focus.analysis.energy != null ? `energy ${focus.analysis.energy}` : null].filter(Boolean).join(", ")} (estimates)</span>}
                  </div>
                </div>
                <div className="pathbox">
                  <span className="pill">File path</span>
                  <code title={String(focus.technical.path)}>{String(focus.technical.path)}</code>
                  {isDesktop() && (
                    <button className="btn icon small" aria-label="Show in folder" title="Show in Explorer" onClick={() => reveal(String(focus.technical.path)).catch((e) => toast(String(e), true))}>
                      <Icon name="folder" size={16} />
                    </button>
                  )}
                </div>
              </div>
              <div className="col" style={{ alignSelf: "stretch", justifyContent: "space-between" }}>
                <button className="btn small icon" aria-label="Close track card" onClick={() => { setFocusId(null); setDrawer(false); }}><Icon name="close" size={16} /></button>
                <button className="btn small" onClick={() => setDrawer(!drawer)}>{drawer ? "Hide details" : "Details & edit"}</button>
              </div>
            </div>
          )}
        </div>
        {drawer && focusId != null && <TrackDetail id={focusId} onClose={() => setDrawer(false)} onChanged={bump} toast={toast} onWrite={(id) => setWriteIds([id])} />}
      </div>
      {filterOpen && (
        <Dialog
          title="More filters"
          onClose={() => setFilterOpen(false)}
          footer={
            <>
              <button className="btn" onClick={() => setDraft(emptyRuleSet())}>Reset</button>
              <span className="spacer" />
              <button className="btn" onClick={() => setFilterOpen(false)}>Cancel</button>
              <button className="btn primary" onClick={() => { setState({ ...state, filters: draft }); setFilterOpen(false); }}>Apply filters</button>
            </>
          }
        >
          <RuleBuilder value={draft} onChange={setDraft} fields={fields} />
        </Dialog>
      )}
      {writeIds && <WriteDialog ids={writeIds} onClose={() => setWriteIds(null)} onDone={bump} toast={toast} />}
    </div>
  );
}

export async function addFoldersFlow(toast: (m: string, err?: boolean) => void, bump: () => void): Promise<boolean> {
  const p = await pickFolders();
  if (!p) return false;
  const added = [];
  for (const path of p) {
    try {
      added.push(await api.addRoot(path));
    } catch (e) {
      toast(`${path}: ${(e as Error).message}`, true);
    }
  }
  if (added.length) {
    await api.startScan(added.map((r) => r.id)).catch((e) => toast(e.message, true));
    toast(`Added ${plural(added.length, "folder")}. Read-only scan started.`);
    bump();
  }
  return true;
}
