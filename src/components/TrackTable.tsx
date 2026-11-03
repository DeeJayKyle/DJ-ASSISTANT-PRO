import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api } from "../api";
import type { TrackQuery, TrackRow } from "../types";
import { bpm, duration, text } from "../lib/format";
import { EnergyMeter, QualityBadge, Stars, StatusText } from "./ui";
import { Icon } from "./Icon";

const PAGE = 200;

export interface Column {
  id: string;
  /** Hide this column when the table is narrower than this many pixels. */
  minTable?: number;
  label: string;
  width: string;
  sort?: string;
  num?: boolean;
  render: (t: TrackRow) => React.ReactNode;
}

export const COLUMNS: Column[] = [
  { id: "artist", label: "Artist", width: "minmax(120px, 1.2fr)", sort: "artist", render: (t) => <span className="cell strong" title={t.artist ?? ""}>{text(t.artist)}</span> },
  {
    id: "title",
    label: "Title",
    width: "minmax(160px, 1.8fr)",
    sort: "title",
    render: (t) => (
      <span className="cell" title={t.title ?? t.file_name}>
        {t.title ?? <span className="faint">{t.file_name}</span>}
        {t.clean_explicit && <> <span className="ce" title={t.clean_explicit}>{t.clean_explicit === "clean" ? "C" : "E"}</span></>}
        {t.status !== "ok" && <> <StatusText s={t.status} /></>}
      </span>
    ),
  },
  { id: "version", label: "Version", minTable: 980, width: "minmax(70px, 0.6fr)", render: (t) => <span className="cell version">{t.version ?? ""}</span> },
  { id: "genre", label: "Genre", minTable: 640, width: "minmax(80px, 0.8fr)", sort: "genre", render: (t) => <span className="cell">{text(t.genre)}</span> },
  { id: "year", label: "Year", minTable: 720, width: "48px", sort: "year", num: true, render: (t) => <span className="cell num">{text(t.year)}</span> },
  { id: "bpm", label: "BPM", minTable: 560, width: "48px", sort: "bpm", num: true, render: (t) => <span className="cell num">{bpm(t.bpm)}</span> },
  { id: "key", label: "Key", minTable: 760, width: "40px", sort: "key", render: (t) => <span className="cell">{text(t.key)}</span> },
  { id: "energy", label: "Energy", width: "82px", sort: "energy", render: (t) => <EnergyMeter value={t.energy} /> },
  { id: "rating", label: "Rating", minTable: 1080, width: "64px", sort: "rating", render: (t) => <Stars value={t.rating} /> },
  { id: "time", label: "Time", minTable: 700, width: "50px", sort: "duration", num: true, render: (t) => <span className="cell num">{duration(t.duration_ms)}</span> },
  { id: "quality", label: "Quality", width: "92px", sort: "bitrate", render: (t) => <QualityBadge t={t} /> },
  {
    id: "format",
    label: "Format",
    minTable: 880,
    width: "minmax(70px, 0.6fr)",
    sort: "format",
    render: (t) => (
      <span className="cell small">
        {text(t.format)}
        {t.bitrate_kbps != null && <span className="faint"> {t.bitrate_kbps}k</span>}
      </span>
    ),
  },
];

export function useTrackPages(query: TrackQuery, version: number) {
  const [total, setTotal] = useState<number | null>(null);
  const [pages, setPages] = useState<Map<number, TrackRow[]>>(new Map());
  const [error, setError] = useState<string | null>(null);
  const loading = useRef(new Set<number>());
  const key = JSON.stringify(query) + version;
  const keyRef = useRef(key);

  useEffect(() => {
    keyRef.current = key;
    loading.current.clear();
    setPages(new Map());
    setError(null);
    api
      .search({ ...query, offset: 0, limit: PAGE })
      .then((p) => {
        if (keyRef.current !== key) return;
        setTotal(p.total);
        setPages(new Map([[0, p.rows]]));
      })
      .catch((e) => {
        if (keyRef.current === key) {
          setError(String(e.message ?? e));
          setTotal(0);
        }
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);

  const ensure = useCallback(
    (from: number, to: number) => {
      for (let p = Math.floor(from / PAGE); p <= Math.floor(to / PAGE); p++) {
        if (pages.has(p) || loading.current.has(p)) continue;
        loading.current.add(p);
        const k = keyRef.current;
        api.search({ ...query, offset: p * PAGE, limit: PAGE }).then((res) => {
          if (keyRef.current !== k) return;
          setPages((m) => new Map(m).set(p, res.rows));
        });
      }
    },
    [pages, query],
  );

  const rowAt = (i: number): TrackRow | undefined => pages.get(Math.floor(i / PAGE))?.[i % PAGE];
  return { total, rowAt, ensure, error };
}

export function TrackTable({
  query,
  version,
  selected,
  onSelect,
  onOpen,
  cursor,
  setCursor,
  onSort,
  onTotal,
}: {
  query: TrackQuery;
  version: number;
  selected: Set<number>;
  onSelect: (s: Set<number>) => void;
  onOpen: (id: number) => void;
  cursor: number;
  setCursor: (i: number) => void;
  onSort: (s: string) => void;
  onTotal?: (n: number | null) => void;
}) {
  const { total, rowAt, ensure, error } = useTrackPages(query, version);
  const bodyRef = useRef<HTMLDivElement>(null);
  const [scroll, setScroll] = useState(0);
  const [height, setHeight] = useState(600);
  const rowH = 34;
  const [width, setWidth] = useState(1200);
  const columns = useMemo(() => COLUMNS.filter((c) => !c.minTable || width >= c.minTable), [width]);
  const cols = "22px " + columns.map((c) => c.width).join(" ");
  const anchor = useRef<number | null>(null);

  useEffect(() => onTotal?.(total), [total, onTotal]);
  useEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      setHeight(el.clientHeight);
      setWidth(el.clientWidth);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  useEffect(() => {
    bodyRef.current?.scrollTo({ top: 0 });
    setScroll(0);
  }, [query]);

  const first = Math.max(0, Math.floor(scroll / rowH) - 10);
  const last = Math.min((total ?? 0) - 1, Math.ceil((scroll + height) / rowH) + 10);
  useEffect(() => {
    if (total && last >= first) ensure(first, last);
  }, [first, last, total, ensure]);

  const select = (i: number, e: { shiftKey: boolean; ctrlKey: boolean; metaKey: boolean }) => {
    const r = rowAt(i);
    if (!r) return;
    setCursor(i);
    if (e.shiftKey && anchor.current != null) {
      const s = new Set(selected);
      const [a, b] = [Math.min(anchor.current, i), Math.max(anchor.current, i)];
      for (let k = a; k <= b; k++) {
        const rr = rowAt(k);
        if (rr) s.add(rr.id);
      }
      onSelect(s);
      return;
    }
    anchor.current = i;
    if (e.ctrlKey || e.metaKey) {
      const s = new Set(selected);
      if (s.has(r.id)) s.delete(r.id);
      else s.add(r.id);
      onSelect(s);
    } else {
      onSelect(new Set([r.id]));
      onOpen(r.id);
    }
  };

  const onKey = (e: React.KeyboardEvent) => {
    if (!total) return;
    let i = cursor;
    if (e.key === "ArrowDown") i = Math.min(total - 1, cursor + 1);
    else if (e.key === "ArrowUp") i = Math.max(0, cursor - 1);
    else if (e.key === "PageDown") i = Math.min(total - 1, cursor + Math.floor(height / rowH));
    else if (e.key === "PageUp") i = Math.max(0, cursor - Math.floor(height / rowH));
    else if (e.key === "Home") i = 0;
    else if (e.key === "End") i = total - 1;
    else if (e.key === " ") {
      e.preventDefault();
      select(cursor, { shiftKey: false, ctrlKey: true, metaKey: false });
      return;
    } else if (e.key === "Enter") {
      const r = rowAt(cursor);
      if (r) onOpen(r.id);
      return;
    } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "a") {
      e.preventDefault();
      const s = new Set<number>();
      for (let k = 0; k < total; k++) {
        const r = rowAt(k);
        if (r) s.add(r.id);
      }
      onSelect(s);
      return;
    } else return;
    e.preventDefault();
    if (e.shiftKey) select(i, { shiftKey: true, ctrlKey: false, metaKey: false });
    else {
      setCursor(i);
      const r = rowAt(i);
      if (r) {
        onSelect(new Set([r.id]));
        anchor.current = i;
      }
    }
    const el = bodyRef.current!;
    if (i * rowH < el.scrollTop) el.scrollTop = i * rowH;
    else if ((i + 1) * rowH > el.scrollTop + el.clientHeight) el.scrollTop = (i + 1) * rowH - el.clientHeight;
  };

  const loadedIds = () => {
    const ids: number[] = [];
    for (let k = 0; k < (total ?? 0); k++) {
      const r = rowAt(k);
      if (r) ids.push(r.id);
    }
    return ids;
  };
  const allSelected = total != null && total > 0 && selected.size >= total;

  return (
    <div className="table-wrap" style={{ ["--cols" as string]: cols }}>
      <div className="thead" role="row">
        <input type="checkbox" aria-label="Select all loaded tracks" checked={allSelected} onChange={(e) => onSelect(e.target.checked ? new Set(loadedIds()) : new Set())} />
        {columns.map((c) => (
          <span key={c.id} className={c.num ? "num" : ""} role="columnheader" aria-sort={query.sort === c.sort ? (query.desc ? "descending" : "ascending") : undefined}>
            {c.sort ? (
              <button onClick={() => onSort(c.sort!)} style={c.num ? { marginLeft: "auto" } : undefined}>
                {c.label}
                {query.sort === c.sort && <Icon name={query.desc ? "sortDown" : "sortUp"} size={12} />}
              </button>
            ) : (
              c.label
            )}
          </span>
        ))}
      </div>
      <div className="tbody" ref={bodyRef} tabIndex={0} role="grid" aria-label="Tracks" aria-rowcount={total ?? 0} onScroll={(e) => setScroll(e.currentTarget.scrollTop)} onKeyDown={onKey}>
        {error && <div className="empty">Search failed: {error}</div>}
        {total === 0 && !error && (
          <div className="empty">
            <h2>No tracks here</h2>
            <p>Try clearing the search or filters, or add a music folder under Folders.</p>
          </div>
        )}
        <div style={{ height: (total ?? 0) * rowH, position: "relative" }}>
          {total != null &&
            Array.from({ length: Math.max(0, last - first + 1) }, (_, k) => {
              const i = first + k;
              const t = rowAt(i);
              const style: React.CSSProperties = { position: "absolute", top: i * rowH, left: 0, right: 0 };
              if (!t)
                return (
                  <div key={i} className="trow dim" style={style}>
                    <span />
                    <span className="cell faint">Loading…</span>
                  </div>
                );
              const sel = selected.has(t.id);
              return (
                <div
                  key={t.id}
                  className={`trow${sel ? " selected" : ""}${cursor === i ? " cursor" : ""}${t.status !== "ok" ? " dim" : ""}`}
                  style={style}
                  role="row"
                  aria-rowindex={i + 1}
                  aria-selected={sel}
                  data-track-id={t.id}
                  onClick={(e) => select(i, e)}
                  onDoubleClick={() => onOpen(t.id)}
                >
                  <input
                    type="checkbox"
                    aria-label={`Select ${t.title ?? t.file_name}`}
                    checked={sel}
                    onClick={(e) => e.stopPropagation()}
                    onChange={() => {
                      const s = new Set(selected);
                      if (sel) s.delete(t.id);
                      else s.add(t.id);
                      onSelect(s);
                      setCursor(i);
                    }}
                  />
                  {columns.map((c) => (
                    <span key={c.id} className={c.num ? "num" : ""} style={{ minWidth: 0, display: "flex", justifyContent: c.num ? "flex-end" : undefined }}>
                      {c.render(t)}
                    </span>
                  ))}
                </div>
              );
            })}
        </div>
      </div>
    </div>
  );
}
