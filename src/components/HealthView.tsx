import { useEffect, useState } from "react";
import { api } from "../api";
import type { Health, HealthItem } from "../types";
import { dateTime, plural } from "../lib/format";
import { Icon } from "./Icon";
import { HealthFixView } from "./HealthFixView";

export function HealthView({ version, onOpen, toast, bump }: { version: number; onOpen: (item: HealthItem) => void; toast: (m: string, e?: boolean) => void; bump: () => void }) {
  const [h, setH] = useState<Health | null>(null);
  const [fixing, setFixing] = useState<string | null>(null);
  useEffect(() => {
    api.health().then(setH).catch(() => setH(null));
  }, [version]);
  if (fixing) return <HealthFixView category={fixing} onBack={() => setFixing(null)} toast={toast} bump={bump} />;
  if (!h) return <div className="view-body">Loading…</div>;
  const warn = new Set(["read_errors", "low_bitrate", "missing", "unsupported"]);
  return (
    <>
      <div className="view-head">
        <div className="grow">
          <h1>Library health</h1>
          <div className="sub">Problems found by reading your files. Nothing is fixed automatically — fill in missing details with “Fix”, or open a card to review the tracks.</div>
        </div>
      </div>
      <div className="view-body">
        <div className="grid-cards">
          {h.items.map((it) => (
            <div key={it.id} className={`card health-card${it.count === 0 ? " zero" : warn.has(it.id) ? " warn" : ""}`}>
              <span className="n">{it.count.toLocaleString()}</span>
              <strong>{it.label}</strong>
              <p>{it.explanation}</p>
              {it.count > 0 && (
                <div className="row wrap health-actions">
                  {it.fix_fields.length > 0 && (
                    <button className="btn primary small" onClick={() => setFixing(it.id)} aria-label={`Fix ${it.label.toLowerCase()} (${it.count})`}>
                      <Icon name="wrench" size={14} /> Fix
                    </button>
                  )}
                  <button className="btn ghost small" onClick={() => onOpen(it)} aria-label={`${it.label}: ${it.count}. Open in library`}>
                    Show in library <Icon name="right" size={14} />
                  </button>
                </div>
              )}
            </div>
          ))}
        </div>

        <h2 style={{ margin: "28px 0 10px" }}>Last scan</h2>
        {h.last_scan ? (
          <div className="panel">
            <div className="row wrap" style={{ gap: 24 }}>
              <div>
                <div className="small muted">Status</div>
                <strong style={{ textTransform: "capitalize" }}>{h.last_scan.status}</strong>
              </div>
              <div>
                <div className="small muted">Finished</div>
                {dateTime(h.last_scan.finished_at)}
              </div>
              <div>
                <div className="small muted">Files seen</div>
                {h.last_scan.files_seen.toLocaleString()}
              </div>
              <div>
                <div className="small muted">New / updated / unchanged</div>
                {h.last_scan.added} / {h.last_scan.updated} / {h.last_scan.unchanged}
              </div>
              <div>
                <div className="small muted">Marked missing</div>
                {h.last_scan.missing}
              </div>
              <div>
                <div className="small muted">Problems</div>
                {h.last_scan.errors}
              </div>
            </div>
            {h.last_scan.message && <p className="note">{h.last_scan.message}</p>}
          </div>
        ) : (
          <p className="muted">No scan yet. Add a folder under Folders and press Scan.</p>
        )}

        {h.recent_errors.length > 0 && (
          <>
            <h2 style={{ margin: "28px 0 10px" }}>Problems in the last scan ({h.recent_errors.length})</h2>
            <div className="panel" style={{ padding: 0 }}>
              <table className="err-table">
                <thead>
                  <tr>
                    <th style={{ width: 90 }}>Type</th>
                    <th>File or folder</th>
                    <th>What happened</th>
                  </tr>
                </thead>
                <tbody>
                  {h.recent_errors.map((e, i) => (
                    <tr key={i}>
                      <td>{e.kind}</td>
                      <td>{e.path}</td>
                      <td>{e.message}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </>
        )}
        <div className="notice info" style={{ marginTop: 24 }}>
          <Icon name="info" />
          <div>
            Low-bitrate warnings use your threshold of <strong>{h.low_bitrate_threshold_kbps} kbps</strong> and apply only to lossy files with a known bitrate. Change it in Settings. {plural(h.items.find((i) => i.id === "unknown_bitrate")?.count ?? 0, "file")} with unknown quality are not flagged.
          </div>
        </div>
      </div>
    </>
  );
}
