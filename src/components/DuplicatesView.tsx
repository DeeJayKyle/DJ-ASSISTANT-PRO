import { useCallback, useEffect, useState } from "react";
import { api } from "../api";
import type { DupGroup, HashProgress } from "../types";
import { bytes, duration, text } from "../lib/format";
import { Icon } from "./Icon";
import { QualityBadge } from "./ui";

const KIND_LABEL = { exact: "Exact duplicate", possible: "Possible duplicate", alternate: "Alternate versions" } as const;
const TAB_LABEL = { exact: "Exact duplicates", possible: "Possible duplicates", alternate: "Alternate versions" } as const;
const DECISIONS: { id: string; label: string }[] = [
  { id: "not_duplicate", label: "Not a duplicate" },
  { id: "intentional_version", label: "Intentional version" },
  { id: "confirmed_duplicate", label: "Yes, duplicate (note only)" },
];

export function DuplicatesView({ version, toast }: { version: number; toast: (m: string, err?: boolean) => void }) {
  const [groups, setGroups] = useState<DupGroup[] | null>(null);
  const [tab, setTab] = useState<DupGroup["kind"]>("exact");
  const [hash, setHash] = useState<HashProgress | null>(null);
  const [hideReviewed, setHideReviewed] = useState(false);
  const load = useCallback(() => api.duplicates().then(setGroups), []);
  useEffect(() => {
    load();
    api.hashStatus().then(setHash);
  }, [load, version]);
  const [checking, setChecking] = useState(false);
  useEffect(() => {
    if (!checking) return;
    const t = setInterval(async () => {
      const h = await api.hashStatus();
      setHash(h);
      if (h.state !== "running") {
        setChecking(false);
        load();
      }
    }, 400);
    return () => clearInterval(t);
  }, [checking, load]);

  const counts = { exact: 0, possible: 0, alternate: 0 };
  groups?.forEach((g) => counts[g.kind]++);
  const shown = (groups ?? []).filter((g) => g.kind === tab && (!hideReviewed || !g.decision));
  const decide = async (g: DupGroup, d: string | null) => {
    await api.setDupDecision(g.key, d);
    load();
  };

  return (
    <>
      <div className="view-head">
        <div className="grow">
          <h1>Duplicate review</h1>
          <div className="sub">Nothing is ever deleted or merged. Your decisions are notes in the catalogue.</div>
        </div>
        {hash?.state === "running" ? (
          <button className="btn" onClick={() => api.cancelHash()}>
            <Icon name="stop" /> Stop checking
          </button>
        ) : (
          <button className="btn primary" onClick={() =>
              api
                .startHash()
                .then(() => {
                  setHash({ state: "running", candidates: 0, hashed: 0, errors: 0 });
                  setChecking(true);
                })
                .catch((e) => toast(e.message, true))
            }>
            <Icon name="dup" /> Check for exact duplicates
          </button>
        )}
      </div>
      <div className="view-body">
        {hash?.state === "running" && (
          <div className="panel" style={{ marginBottom: 14 }} aria-live="polite">
            <div className="row" style={{ marginBottom: 8 }}>
              <strong>Reading files to compare contents…</strong>
              <span className="muted small">
                {hash.hashed} of {hash.candidates} same-size files
              </span>
            </div>
            <div className="progress">
              <div style={{ width: `${hash.candidates ? (100 * hash.hashed) / hash.candidates : 0}%` }} />
            </div>
          </div>
        )}
        <div className="notice info" style={{ marginBottom: 16 }}>
          <Icon name="info" />
          <div>
            <strong>Exact</strong> means every byte is identical (full-file hash, computed only for files of the same size; press “Check for exact duplicates” to run it).{" "}
            <strong>Possible</strong> means the same artist and title with nearly the same length — the files may still differ. <strong>Alternate versions</strong> share a title but have different version labels such as Remix,
            Live or Clean, and are usually intentional.
          </div>
        </div>
        <div className="tabs" role="tablist">
          {(["exact", "possible", "alternate"] as const).map((k) => (
            <button key={k} role="tab" className="tab" aria-selected={tab === k} onClick={() => setTab(k)}>
              {TAB_LABEL[k]} ({counts[k]})
            </button>
          ))}
          <span className="spacer" />
          <label className="row small muted">
            <input type="checkbox" checked={hideReviewed} onChange={(e) => setHideReviewed(e.target.checked)} /> Hide reviewed
          </label>
        </div>
        {groups == null && <p>Loading…</p>}
        {groups && shown.length === 0 && (
          <div className="empty">
            <h2>Nothing to review here</h2>
            {tab === "exact" && <p>Run “Check for exact duplicates” after scanning to compare file contents.</p>}
          </div>
        )}
        {shown.map((g) => (
          <article key={g.key} className="dup-group" aria-label={`${KIND_LABEL[g.kind]} group`}>
            <div className="dup-head">
              <span className={`badge kind-${g.kind}`}>{KIND_LABEL[g.kind]}</span>
              <p style={{ flex: 1 }}>{g.reason}</p>
            </div>
            <table className="dup-table">
              <thead>
                <tr>
                  <th>Artist / title</th>
                  <th>Version</th>
                  <th>Time</th>
                  <th>Quality</th>
                  <th>Size</th>
                  <th>Location</th>
                </tr>
              </thead>
              <tbody>
                {g.tracks.map((t) => (
                  <tr key={t.id}>
                    <td>
                      {text(t.artist)} — {t.title ?? t.file_name}
                    </td>
                    <td className="version">{t.version ?? ""}</td>
                    <td>{duration(t.duration_ms)}</td>
                    <td>
                      <QualityBadge t={t} /> <span className="faint small">{t.format}</span>
                    </td>
                    <td>{bytes(t.file_size)}</td>
                    <td className="path">{t.path}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <div className="dup-actions">
              <span className="small muted">Your review:</span>
              {DECISIONS.map((d) => (
                <button key={d.id} className={`btn small${g.decision === d.id ? " primary" : ""}`} aria-pressed={g.decision === d.id} onClick={() => decide(g, g.decision === d.id ? null : d.id)}>
                  {g.decision === d.id && <Icon name="check" size={13} />} {d.label}
                </button>
              ))}
            </div>
          </article>
        ))}
      </div>
    </>
  );
}
