import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { Crate, FieldInfo, RuleNode, RuleSet, TrackQuery } from "../types";
import { cleanRuleSet, cond, countRules, describe, emptyRuleSet } from "../lib/rules";
import { plural } from "../lib/format";
import { TrackTable } from "./TrackTable";
import { TrackDetail } from "./TrackDetail";
import { RuleBuilder } from "./RuleBuilder";
import { Dialog, useDebounced } from "./ui";
import { Icon } from "./Icon";

export interface LibraryState {
  text: string;
  filters: RuleSet;
  sort: string | null;
  desc: boolean;
}

export const emptyLibraryState = (): LibraryState => ({ text: "", filters: emptyRuleSet(), sort: null, desc: false });

const PRESETS: { label: string; rules: RuleNode[] }[] = [
  { label: "Low bitrate", rules: [cond("quality", "equals", "low_bitrate")] },
  { label: "Lossless", rules: [cond("quality", "equals", "lossless")] },
  { label: "Missing genre", rules: [cond("genre", "is_empty")] },
  { label: "No energy yet", rules: [cond("energy", "is_empty")] },
  { label: "Clean", rules: [cond("clean_explicit", "equals", "clean")] },
];

export function LibraryView({
  state,
  setState,
  crate,
  crates,
  fields,
  version,
  bump,
  toast,
  onEditCrate,
  onSaveSmart,
  searchRef,
}: {
  state: LibraryState;
  setState: (s: LibraryState) => void;
  crate: Crate | null;
  crates: Crate[];
  fields: FieldInfo[];
  version: number;
  bump: () => void;
  toast: (m: string, err?: boolean) => void;
  onEditCrate: (c: Crate) => void;
  onSaveSmart: (rules: RuleSet) => void;
  searchRef: React.RefObject<HTMLInputElement | null>;
}) {
  const [selected, setSelected] = useState<Set<number>>(new Set());
  const [cursor, setCursor] = useState(0);
  const [openId, setOpenId] = useState<number | null>(null);
  const [total, setTotal] = useState<number | null>(null);
  const [filterOpen, setFilterOpen] = useState(false);
  const [draft, setDraft] = useState<RuleSet>(state.filters);
  const [menu, setMenu] = useState<null | "crate" | "energy" | "tag">(null);
  const [bulkTag, setBulkTag] = useState("");
  const text = useDebounced(state.text, 180);
  const filters = cleanRuleSet(state.filters, fields);
  const query: TrackQuery = { text: text.trim() || null, filters, crate_id: crate?.id ?? null, sort: state.sort, desc: state.desc };
  const menuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setSelected(new Set());
    setCursor(0);
  }, [crate?.id, text, JSON.stringify(filters)]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!menu) return;
    const close = (e: MouseEvent) => {
      if (!menuRef.current?.contains(e.target as Node)) setMenu(null);
    };
    window.addEventListener("mousedown", close);
    return () => window.removeEventListener("mousedown", close);
  }, [menu]);

  const ids = [...selected];
  const manualCrates = crates.filter((c) => c.id !== crate?.id);
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
  const removeNode = (which: "rules" | "exclude", i: number) => {
    const f = { ...state.filters, [which]: (state.filters[which] ?? []).filter((_, j) => j !== i) };
    setState({ ...state, filters: f });
  };
  const active = countRules(filters);

  return (
    <>
      <div className="view-head">
        <div className="grow">
          <h1>{crate ? crate.name : "Library"}</h1>
          <div className="sub">
            {crate
              ? crate.kind === "smart"
                ? `Smart crate: ${crate.rules ? [...crate.rules.rules.map((r) => describe(r, fields)), ...(crate.rules.exclude ?? []).map((r) => "not " + describe(r, fields))].join(crate.rules.match === "all" ? ", " : " or ") : ""}`
                : "Manual crate. Tracks are referenced, never copied or moved."
              : "Everything in your selected folders. Your files are read, never changed."}
          </div>
        </div>
        {crate && (
          <button className="btn" onClick={() => onEditCrate(crate)}>
            <Icon name="edit" /> Edit crate
          </button>
        )}
      </div>
      <div className="toolbar">
        <div className="row">
          <div className="search">
            <Icon name="search" />
            <input
              ref={searchRef}
              className="input"
              type="search"
              placeholder="Search artist, title, album, genre, label, tags, file name…"
              aria-label="Search tracks"
              value={state.text}
              onChange={(e) => setState({ ...state, text: e.target.value })}
            />
          </div>
          <span className="kbd" title="Press / to search">/</span>
          <button
            className="btn"
            aria-expanded={filterOpen}
            onClick={() => {
              setDraft(state.filters);
              setFilterOpen(true);
            }}
          >
            <Icon name="smart" /> Filters{active ? ` (${active})` : ""}
          </button>
          {active > 0 && !crate && (
            <button className="btn" onClick={() => filters && onSaveSmart(filters)}>
              Save as smart crate
            </button>
          )}
        </div>
        <div className="chips" aria-label="Active filters">
          {state.filters.rules.map((r, i) => (
            <span key={`r${i}`} className="chip">
              {describe(r, fields)}
              <button aria-label={`Remove filter ${describe(r, fields)}`} onClick={() => removeNode("rules", i)}>
                <Icon name="close" size={12} />
              </button>
            </span>
          ))}
          {(state.filters.exclude ?? []).map((r, i) => (
            <span key={`x${i}`} className="chip exclude">
              not {describe(r, fields)}
              <button aria-label={`Remove exclusion ${describe(r, fields)}`} onClick={() => removeNode("exclude", i)}>
                <Icon name="close" size={12} />
              </button>
            </span>
          ))}
          {active > 1 && state.filters.match === "any" && <span className="small muted">(any of these)</span>}
          {active > 0 && (
            <button className="btn ghost small" onClick={() => setState({ ...state, filters: emptyRuleSet() })}>
              Clear filters
            </button>
          )}
          {active === 0 &&
            PRESETS.map((p) => (
              <button key={p.label} className="chip preset" onClick={() => setState({ ...state, filters: { match: "all", rules: p.rules, exclude: [] } })}>
                {p.label}
              </button>
            ))}
        </div>
      </div>
      {selected.size > 0 && (
        <div className="bulkbar" ref={menuRef}>
          <strong>{plural(selected.size, "track")} selected</strong>
          <span className="rel">
            <button className="btn small" aria-haspopup="menu" aria-expanded={menu === "crate"} onClick={() => setMenu(menu === "crate" ? null : "crate")}>
              <Icon name="crate" size={14} /> Add to crate
            </button>
            {menu === "crate" && (
              <div className="menu" role="menu">
                {manualCrates.length === 0 && <div className="small muted" style={{ padding: 8 }}>No other crates yet. Create one in the sidebar.</div>}
                {manualCrates.map((c) => (
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
              <div className="menu" role="menu" style={{ minWidth: 120 }}>
                {[1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map((n) => (
                  <button key={n} role="menuitem" onClick={() => act(() => api.updateUserFields(ids, { energy: n }), `Energy set to ${n}.`)}>
                    {n}
                  </button>
                ))}
                <button role="menuitem" onClick={() => act(() => api.updateUserFields(ids, { energy: null }), "Energy cleared.")}>
                  Clear
                </button>
              </div>
            )}
          </span>
          <span className="rel">
            <button className="btn small" aria-haspopup="dialog" aria-expanded={menu === "tag"} onClick={() => setMenu(menu === "tag" ? null : "tag")}>
              Add tag
            </button>
            {menu === "tag" && (
              <form
                className="menu row"
                style={{ padding: 8, minWidth: 260 }}
                onSubmit={(e) => {
                  e.preventDefault();
                  const t = bulkTag.trim();
                  if (t) act(() => api.setTags(ids, [t]), `Tagged ${plural(ids.length, "track")} “${t}”.`).then(() => setBulkTag(""));
                }}
              >
                <input className="input" autoFocus aria-label="Tag for selected tracks" placeholder="Tag name" value={bulkTag} onChange={(e) => setBulkTag(e.target.value)} />
                <button className="btn primary small" type="submit">
                  Add
                </button>
              </form>
            )}
          </span>
          {crate && (
            <button className="btn small danger" onClick={() => act(() => api.crateRemove(crate.id, ids), crate.kind === "smart" ? "Excluded from this smart crate." : "Removed from crate. Files were not touched.")}>
              Remove from crate
            </button>
          )}
          <span className="spacer" />
          <button className="btn small ghost" onClick={() => setSelected(new Set())}>
            Clear selection
          </button>
        </div>
      )}
      <div className={`library${openId != null ? " with-detail" : ""}`}>
        <div style={{ display: "flex", flexDirection: "column", minHeight: 0 }}>
          <TrackTable
            query={query}
            version={version}
            selected={selected}
            onSelect={setSelected}
            onOpen={setOpenId}
            cursor={cursor}
            setCursor={setCursor}
            onTotal={setTotal}
            onSort={(s) => setState({ ...state, sort: s, desc: state.sort === s ? !state.desc : false })}
          />
          <div className="tablefoot" aria-live="polite">
            <span>{total == null ? "Loading…" : plural(total, "track")}</span>
            <span>Unknown values are shown as —</span>
          </div>
        </div>
        {openId != null && <TrackDetail id={openId} onClose={() => setOpenId(null)} onChanged={bump} toast={toast} />}
      </div>
      {filterOpen && (
        <Dialog
          title="Filters"
          onClose={() => setFilterOpen(false)}
          footer={
            <>
              <button className="btn" onClick={() => setDraft(emptyRuleSet())}>
                Reset
              </button>
              <span className="spacer" />
              <button className="btn" onClick={() => setFilterOpen(false)}>
                Cancel
              </button>
              <button
                className="btn primary"
                onClick={() => {
                  setState({ ...state, filters: draft });
                  setFilterOpen(false);
                }}
              >
                Apply filters
              </button>
            </>
          }
        >
          <RuleBuilder value={draft} onChange={setDraft} fields={fields} />
        </Dialog>
      )}
    </>
  );
}
