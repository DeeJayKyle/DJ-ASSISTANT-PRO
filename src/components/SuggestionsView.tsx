import { useEffect, useState } from "react";
import { api } from "../api";
import type { Suggestion } from "../types";
import { Dialog } from "./ui";
import { Icon } from "./Icon";

export function SuggestionsView({ version, bump, toast }: { version: number; bump: () => void; toast: (m: string, e?: boolean) => void }) {
  const [status, setStatus] = useState<"pending" | "accepted" | "rejected">("pending");
  const [list, setList] = useState<Suggestion[] | null>(null);
  const [counts, setCounts] = useState<Record<string, number>>({});
  const [edit, setEdit] = useState<Record<number, string>>({});
  const [source, setSource] = useState<string>("");
  const [consent, setConsent] = useState(false);
  const load = () => {
    api.suggestions(status).then(setList);
    api.suggestionCounts().then(setCounts);
  };
  useEffect(load, [status, version]); // eslint-disable-line react-hooks/exhaustive-deps
  const sources = [...new Set((list ?? []).map((s) => s.source))];
  const shown = (list ?? []).filter((s) => !source || s.source === source);
  const run = (p: Promise<unknown>, msg: string) => p.then(() => { toast(msg); load(); bump(); }).catch((e) => toast(e.message, true));
  return (
    <div className="page">
      <div className="view-head">
        <div className="grow">
          <h1>Suggestions</h1>
          <div className="sub">File tags, your catalogue values and suggestions are kept apart. Accepting stores the value in DJ Assistant only — the music file is not changed.</div>
        </div>
        <button className="btn" onClick={() => run(api.generateSuggestions(), "Checked file names, folders and spellings.")}><Icon name="wand" size={16} /> Find local suggestions</button>
        <button className="btn" onClick={() => run(api.lookupMusicBrainz({ query: { filters: { match: "any", rules: [{ kind: "condition", field: "original_year", op: "is_empty" }, { kind: "condition", field: "album", op: "is_empty" }] } } }), "MusicBrainz lookup started (one request per second).")}>
          <Icon name="cloud" size={16} /> MusicBrainz lookup
        </button>
        <button className="btn" onClick={() => setConsent(true)}><Icon name="headphones" size={16} /> AcoustID lookup…</button>
      </div>
      <div className="view-body">
        <div className="row wrap" style={{ marginBottom: 14 }}>
          <div className="seg" role="tablist">
            {(["pending", "accepted", "rejected"] as const).map((s) => (
              <button key={s} aria-pressed={status === s} onClick={() => setStatus(s)}>{s[0].toUpperCase() + s.slice(1)} ({counts[s] ?? 0})</button>
            ))}
          </div>
          <select className="select" aria-label="Source" value={source} onChange={(e) => setSource(e.target.value)}>
            <option value="">All sources</option>
            {sources.map((s) => <option key={s}>{s}</option>)}
          </select>
          <span className="spacer" />
          {status === "pending" && shown.length > 0 && (
            <button className="btn small" onClick={() => run(api.acceptBulk(0.8, source || null), "Accepted high-confidence suggestions into your catalogue.")}>
              Accept all ≥ 80% confidence{source ? ` from ${source}` : ""}
            </button>
          )}
        </div>
        {list == null && <div className="skeleton" />}
        {list && shown.length === 0 && (
          <div className="empty"><div className="art"><Icon name="wand" size={28} /></div><h2>Nothing here</h2><p>Use “Find local suggestions”, analyse tracks, or turn on MusicBrainz in Settings.</p></div>
        )}
        <div className="panel" style={{ padding: 0, display: shown.length ? undefined : "none" }}>
          <table className="data-table">
            <thead><tr><th>Track</th><th>Field</th><th>Now</th><th>Suggested</th><th>Source &amp; evidence</th><th style={{ width: 210 }} /></tr></thead>
            <tbody>
              {shown.map((s) => (
                <tr key={s.id}>
                  <td style={{ maxWidth: 220 }}>{s.track}</td>
                  <td><strong>{s.field.replace("_", " ")}</strong></td>
                  <td className="faint" style={{ whiteSpace: "nowrap" }}>{s.current_value ?? "unknown"}</td>
                  <td>{status === "pending" ? <input className="input" style={{ height: 30, width: "100%" }} aria-label={`Suggested ${s.field}`} value={edit[s.id] ?? s.suggested_value} onChange={(e) => setEdit({ ...edit, [s.id]: e.target.value })} /> : s.suggested_value}</td>
                  <td className="small">
                    <span className="tag">{s.source}</span> {s.confidence != null && <span className={`badge ${s.confidence >= 0.8 ? "q-lossless" : s.confidence >= 0.5 ? "q-lossy" : "q-low_bitrate"}`}>{Math.round(s.confidence * 100)}%</span>}
                    <div className="muted" style={{ marginTop: 4 }}>{s.evidence}</div>
                  </td>
                  <td>
                    {status === "pending" ? (
                      <div className="row">
                        <button className="btn small primary" onClick={() => run(api.acceptSuggestion(s.id, edit[s.id] ?? null), `Saved ${s.field} to your catalogue.`)}>Accept</button>
                        <button className="btn small" onClick={() => run(api.rejectSuggestion(s.id), "Rejected.")}>Reject</button>
                      </div>
                    ) : (
                      <button className="btn small ghost" onClick={() => run(api.resetSuggestion(s.id), "Moved back to pending.")}><Icon name="undo" size={14} /> Undo</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="note" style={{ marginTop: 14 }}>Release years are labelled carefully: “original year” is the earliest release of a recording; your file’s year may be a remix, reissue or edition year. Fingerprint matches are candidates, not proof of the exact version. MusicBrainz data is © MusicBrainz contributors (CC0); AcoustID is a service of the AcoustID project.</p>
      </div>
      {consent && (
        <Dialog narrow title="Send audio fingerprints to AcoustID?" onClose={() => setConsent(false)} footer={<><button className="btn" onClick={() => setConsent(false)}>Cancel</button><button className="btn primary" onClick={() => { setConsent(false); run(api.lookupAcoustid({ query: { filters: { match: "any", rules: [{ kind: "condition", field: "title", op: "is_empty" }, { kind: "condition", field: "artist", op: "is_empty" }] } } }), "AcoustID lookup started for tracks missing a title or artist."); }}>Yes, send fingerprints</button></>}>
          <p>For each track that is missing a title or artist and has been analysed, DJ Assistant will send <strong>a compact audio fingerprint and the track length</strong> to AcoustID. Your audio, file names and paths are not sent.</p>
          <p className="muted">You need AcoustID turned on and your own free AcoustID application key in Settings → Online services. Matches become suggestions for you to review.</p>
        </Dialog>
      )}
    </div>
  );
}
