import { useEffect, useState } from "react";
import { api, openUrl } from "../api";
import type { Crate, CrateGaps, DiscoveryItem, Overplayed, Preferences, Recommendation, TracklistMatch } from "../types";
import { dateTime, plural } from "../lib/format";
import { Icon } from "./Icon";

type Tab = "fit" | "tracklist" | "online" | "overplayed" | "learned";

export function DiscoveryView({ crates, version, bump, toast }: { crates: Crate[]; version: number; bump: () => void; toast: (m: string, e?: boolean) => void }) {
  const [tab, setTab] = useState<Tab>("fit");
  const [crateId, setCrateId] = useState<number | null>(crates.find((c) => c.track_count > 0)?.id ?? null);
  const [fit, setFit] = useState<Recommendation[] | null>(null);
  const [gaps, setGaps] = useState<CrateGaps | null>(null);
  const [tl, setTl] = useState("");
  const [tlRes, setTlRes] = useState<TracklistMatch | null>(null);
  const [items, setItems] = useState<DiscoveryItem[]>([]);
  const [followed, setFollowed] = useState<{ id: number; name: string }[]>([]);
  const [newArtist, setNewArtist] = useState("");
  const [over, setOver] = useState<Overplayed[]>([]);
  const [prefs, setPrefs] = useState<Preferences | null>(null);
  const err = (e: Error) => toast(e.message, true);
  useEffect(() => {
    if (tab === "fit" && crateId) {
      setFit(null);
      api.crateFit(crateId).then(setFit).catch((e) => { setFit([]); err(e); });
      api.crateGaps(crateId).then(setGaps).catch(() => setGaps(null));
    }
    if (tab === "online") { api.discoveryItems().then(setItems); api.followed().then(setFollowed); }
    if (tab === "overplayed") api.overplayed().then(setOver);
    if (tab === "learned") api.preferences().then(setPrefs);
  }, [tab, crateId, version]); // eslint-disable-line react-hooks/exhaustive-deps
  const addToCrate = (tid: number) => crateId && api.crateAdd(crateId, [tid]).then(() => { toast("Added to crate."); setFit((f) => f?.filter((r) => r.track_id !== tid) ?? null); bump(); });
  const own = (o: string) => <span className={`badge ${o === "owned" ? "q-lossless" : o === "possibly_owned" ? "q-low_bitrate" : "q-lossy"}`}>{o.replace("_", " ")}</span>;
  return (
    <div className="page">
      <div className="view-head">
        <div className="grow">
          <h1>Discovery</h1>
          <div className="sub">Every recommendation shows why, where it came from and when. Listening similarity is not proof two tracks mix well.</div>
        </div>
      </div>
      <div className="view-body">
        <div className="tabs" role="tablist">
          {([["fit", "Fits a crate"], ["tracklist", "Tracklist match"], ["online", "Similar & new releases"], ["overplayed", "Overplayed"], ["learned", "What I've learned"]] as [Tab, string][]).map(([t, l]) => (
            <button key={t} role="tab" className="tab" aria-selected={tab === t} onClick={() => setTab(t)}>{l}</button>
          ))}
        </div>
        {tab === "fit" && (
          <>
            <div className="row" style={{ marginBottom: 14 }}>
              <label className="field" style={{ flexDirection: "row", alignItems: "center", gap: 10 }}>Crate
                <select className="select" value={crateId ?? ""} onChange={(e) => setCrateId(Number(e.target.value) || null)}>
                  <option value="">Choose…</option>
                  {crates.map((c) => <option key={c.id} value={c.id}>{c.name} ({c.track_count})</option>)}
                </select>
              </label>
            </div>
            <div className="grid2">
              <div className="panel">
                <h2 style={{ marginBottom: 10 }}>From your library</h2>
                {!crateId && <p className="muted">Pick a crate with a few tracks.</p>}
                {crateId && fit == null && <div className="skeleton" />}
                {fit?.length === 0 && <p className="muted">No strong matches yet. Rate energy or analyse tracks for better results.</p>}
                <div className="list">
                  {fit?.map((r) => (
                    <div key={r.track_id} className="list-row" style={{ alignItems: "flex-start" }}>
                      <div style={{ flex: 1, minWidth: 0 }}>
                        <strong>{r.track}</strong>
                        <div className="small muted">{r.reasons.join(" · ")}</div>
                      </div>
                      <button className="btn small" onClick={() => addToCrate(r.track_id)}><Icon name="plus" size={14} /> Add</button>
                    </div>
                  ))}
                </div>
              </div>
              <div className="panel">
                <h2 style={{ marginBottom: 10 }}>Gaps</h2>
                {gaps && (
                  <>
                    {gaps.artists.length > 0 && <><h3>Artists you own more of</h3>{gaps.artists.slice(0, 8).map((a) => <div key={a.artist} className="small" style={{ padding: "3px 0" }}>{a.reason}</div>)}</>}
                    <h3 style={{ marginTop: 12 }}>Decades: library vs crate</h3>
                    <div className="bars">
                      {gaps.decades.map((d) => (
                        <div key={d.decade} className="bar-row"><span>{d.decade}s</span><span className="bar-track"><i style={{ width: `${(100 * d.crate) / Math.max(1, d.library)}%` }} /></span><span className="small muted">{d.crate}/{d.library}</span></div>
                      ))}
                    </div>
                    {(gaps.missing_energy > 0 || gaps.missing_bpm > 0) && <p className="note">{gaps.missing_energy} without energy and {gaps.missing_bpm} without BPM in this crate.</p>}
                  </>
                )}
                {crateId && (
                  <button className="btn small" style={{ marginTop: 12 }} onClick={() => api.lastfmCrate(crateId).then((r) => { toast(`${r.found} similar artists from Last.fm.`); setTab("online"); }).catch(err)}>
                    <Icon name="cloud" size={14} /> Similar artists on Last.fm
                  </button>
                )}
              </div>
            </div>
          </>
        )}
        {tab === "tracklist" && (
          <div className="grid2">
            <div className="panel col">
              <h2>Paste a tracklist</h2>
              <p className="small muted" style={{ margin: 0 }}>From a radio show, a DJ mix or a festival set. One track per line, “Artist - Title”. “ID - ID” stays as unknown.</p>
              <textarea className="input" rows={14} aria-label="Tracklist" value={tl} onChange={(e) => setTl(e.target.value)} placeholder={"01. Wizkid - Essence\n02. ID - ID\n03. Rema - Calm Down"} />
              <button className="btn primary" disabled={!tl.trim()} onClick={() => api.matchTracklist(tl).then(setTlRes).catch(err)}>Match against my library</button>
            </div>
            <div className="panel">
              {tlRes ? (
                <>
                  <div className="row wrap" style={{ marginBottom: 10 }}>
                    <span className="badge q-lossless">{tlRes.owned} owned</span><span className="badge q-low_bitrate">{tlRes.possibly_owned} possibly owned</span><span className="badge q-lossy">{tlRes.missing} missing</span><span className="badge q-unknown">{tlRes.unknown} unknown</span>
                  </div>
                  <div className="list">
                    {tlRes.lines.map((l) => (
                      <div key={l.line} className="list-row" style={{ alignItems: "flex-start" }}>
                        <span className="mono faint small" style={{ width: 24 }}>{l.line}</span>
                        <div style={{ flex: 1, minWidth: 0 }}>
                          <div>{l.text}</div>
                          {(l.match || l.note) && <div className="small muted">{l.match ? `→ ${l.match}. ` : ""}{l.note}</div>}
                        </div>
                        {own(l.status === "unknown" ? "unknown" : l.status)}
                        {l.status === "missing" && l.artist && <button className="btn small ghost" onClick={() => api.storeLinks(l.artist!, l.title!).then((x) => openUrl(x[1].url))} title="Search Bandcamp">Find</button>}
                      </div>
                    ))}
                  </div>
                  <p className="note">{tlRes.note}</p>
                </>
              ) : <p className="muted">Results appear here.</p>}
            </div>
          </div>
        )}
        {tab === "online" && (
          <div className="grid2">
            <div className="panel">
              <h2 style={{ marginBottom: 6 }}>Recommendations</h2>
              <p className="small muted">From Last.fm (similar artists/tracks) and MusicBrainz (new releases from artists you follow). Online services must be on in Settings.</p>
              {items.length === 0 && <p className="faint">Nothing yet.</p>}
              <div className="list">
                {items.map((i) => (
                  <div key={i.id} className="list-row" style={{ alignItems: "flex-start" }}>
                    <div style={{ flex: 1, minWidth: 0 }}>
                      <strong>{i.artist}{i.title ? ` — ${i.title}` : ""}</strong> {own(i.ownership)}
                      <div className="small muted">{i.reason} {i.detail ? `· ${i.detail}` : ""} {i.released ? `· released ${i.released}` : ""}</div>
                      <div className="small faint">{i.source} · fetched {dateTime(i.fetched_at)}</div>
                    </div>
                    {i.url && <button className="btn small ghost" onClick={() => openUrl(i.url!)} aria-label="Open source"><Icon name="external" size={14} /></button>}
                    <button className="btn small ghost" title="Save to wishlist" onClick={() => api.discoveryStatus(i.id, i.status === "wishlist" ? "new" : "wishlist").then(() => api.discoveryItems().then(setItems))}><Icon name="star" size={14} /></button>
                    <button className="btn small ghost" title="Not for me" onClick={() => api.discoveryStatus(i.id, "dismissed").then(() => { api.prefFeedback("artist", i.artist ?? "", -1); api.discoveryItems().then(setItems); })}><Icon name="thumbdown" size={14} /></button>
                  </div>
                ))}
              </div>
            </div>
            <div className="panel col">
              <h2>Artists you follow</h2>
              <form className="row" onSubmit={(e) => { e.preventDefault(); api.follow(newArtist).then(() => { setNewArtist(""); api.followed().then(setFollowed); }).catch(err); }}>
                <input className="input" style={{ flex: 1 }} aria-label="Artist to follow" placeholder="Artist name" value={newArtist} onChange={(e) => setNewArtist(e.target.value)} />
                <button className="btn" type="submit" disabled={!newArtist.trim()}>Follow</button>
              </form>
              <div className="tagline">{followed.map((f) => <span key={f.id} className="chip">{f.name}<button aria-label={`Unfollow ${f.name}`} onClick={() => api.unfollow(f.id).then(() => api.followed().then(setFollowed))}><Icon name="close" size={12} /></button></span>)}</div>
              <button className="btn" disabled={!followed.length} onClick={() => api.refreshReleases().then(() => toast("Checking MusicBrainz for new releases (1 request per second)…")).catch(err)}><Icon name="refresh" size={14} /> Check for new releases</button>
            </div>
          </div>
        )}
        {tab === "overplayed" && (
          <div className="panel">
            <p className="muted small">Based on gig mode play logs and imported history. Alternatives share genre, tempo and energy and have been played less.</p>
            {over.length === 0 && <p className="faint">No play history yet. Use Gig Mode or import Serato history in Settings.</p>}
            {over.map((o) => (
              <div key={o.track_id} className="list-row" style={{ alignItems: "flex-start" }}>
                <div style={{ flex: 1 }}>
                  <strong>{o.track}</strong> <span className="small muted">played {plural(o.plays, "time")}</span>
                  <div className="small muted">{o.alternatives.length ? `Try: ${o.alternatives.map((a) => a.track).join(" · ")}` : "No close alternatives in your library."}</div>
                </div>
              </div>
            ))}
          </div>
        )}
        {tab === "learned" && prefs && (
          <div className="grid2">
            <div className="panel">
              <div className="row" style={{ marginBottom: 8 }}>
                <h2 style={{ flex: 1 }}>What DJ Assistant has learned</h2>
                <label className="toggle"><span className="small muted">{prefs.enabled ? "Learning on" : "Learning off"}</span><input type="checkbox" checked={prefs.enabled} onChange={(e) => api.setSetting("learning_enabled", e.target.checked).then(() => api.preferences().then(setPrefs))} /><span className="knob" /></label>
              </div>
              <p className="small muted">{prefs.explanation}</p>
              <h3>Genres</h3>
              <div className="bars">{prefs.genres.map((g) => <div key={g.name} className="bar-row"><span>{g.name}</span><span className="bar-track"><i style={{ width: `${Math.min(100, Math.abs(g.weight) * 60)}%`, opacity: g.weight < 0 ? 0.4 : 1 }} /></span><span className="small muted">{g.weight}</span></div>)}</div>
              <h3 style={{ marginTop: 12 }}>Artists</h3>
              <div className="bars">{prefs.artists.slice(0, 10).map((g) => <div key={g.name} className="bar-row"><span>{g.name}</span><span className="bar-track"><i style={{ width: `${Math.min(100, Math.abs(g.weight) * 60)}%`, opacity: g.weight < 0 ? 0.4 : 1 }} /></span><span className="small muted">{g.weight}</span></div>)}</div>
            </div>
            <div className="panel">
              <h2 style={{ marginBottom: 8 }}>Your likes and dislikes</h2>
              {prefs.feedback.length === 0 && <p className="faint">None yet.</p>}
              {prefs.feedback.map((f) => <div key={f.kind + f.subject} className="list-row"><Icon name={f.value > 0 ? "up" : "thumbdown"} size={14} /><span style={{ flex: 1 }}>{f.subject} <span className="faint small">({f.kind})</span></span><button className="btn small ghost" onClick={() => api.prefFeedback(f.kind, f.subject, 0).then(() => api.preferences().then(setPrefs))}>Remove</button></div>)}
              <button className="btn danger" style={{ marginTop: 12 }} onClick={() => api.resetLearning().then(() => api.preferences().then(setPrefs))}>Reset what I've learned</button>
              <p className="note">Personal files are never used for recommendations.</p>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
