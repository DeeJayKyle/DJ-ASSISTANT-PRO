import { useEffect, useState } from "react";
import { api, openUrl } from "../api";
import type { Suggestion, TrackDetail as Detail } from "../types";
import { Waveform } from "./Waveform";
import { bpm, bytes, dateTime, duration, getKeyNotation, keyHint, keyName, text } from "../lib/format";
import { ColorPicker, EnergyMeter, QualityBadge } from "./ui";
import { Icon } from "./Icon";

function KV({ items }: { items: [string, React.ReactNode][] }) {
  return (
    <dl className="kv">
      {items.map(([k, v]) => (
        <div key={k} style={{ display: "contents" }}>
          <dt>{k}</dt>
          <dd>{v}</dd>
        </div>
      ))}
    </dl>
  );
}

export function TrackDetail({ id, onClose, onChanged, toast, onWrite }: { id: number; onClose: () => void; onChanged: () => void; toast: (m: string, err?: boolean) => void; onWrite?: (id: number) => void }) {
  const [d, setD] = useState<Detail | null>(null);
  const [sugg, setSugg] = useState<Suggestion[]>([]);
  const [links, setLinks] = useState<{ store: string; url: string }[] | null>(null);
  const [form, setForm] = useState<Record<string, string>>({});
  const [tagInput, setTagInput] = useState("");
  const load = () =>
    api
      .trackDetail(id)
      .then((x) => {
        setD(x);
        const m = x.mine as Record<string, unknown>;
        setForm({
          genre: (m.genre as string) ?? "",
          year: m.year != null ? String(m.year) : "",
          bpm: m.bpm != null ? String(m.bpm) : "",
          key: (m.key as string) ?? "",
          mood: (m.mood as string) ?? "",
          notes: (m.notes as string) ?? "",
          version_label: (m.version_label as string) ?? "",
          clean_explicit: (m.clean_explicit as string) ?? "",
        });
      })
      .catch((e) => toast(String(e.message ?? e), true));
  useEffect(() => {
    load();
    api.suggestions("pending", id).then(setSugg).catch(() => setSugg([]));
    setLinks(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id]);

  if (!d) return <aside className="detail" aria-label="Track details">Loading…</aside>;
  const f = d.file as Record<string, unknown>;
  const t = d.technical as Record<string, unknown>;
  const m = d.mine as Record<string, unknown>;

  const patch = async (p: Record<string, unknown>) => {
    try {
      await api.updateUserFields([id], p);
      await load();
      onChanged();
    } catch (e) {
      toast(String((e as Error).message ?? e), true);
    }
  };
  const save = async () => {
    const p: Record<string, unknown> = {};
    for (const k of ["genre", "key", "mood", "notes", "version_label"]) p[k] = form[k].trim() || null;
    p.year = form.year.trim() ? Number(form.year) : null;
    p.bpm = form.bpm.trim() ? Number(form.bpm) : null;
    p.clean_explicit = form.clean_explicit || null;
    await patch(p);
    toast("Saved to your catalogue. The music file was not changed.");
  };

  const field = (k: string, label: string, fileVal: unknown, opts?: { full?: boolean; area?: boolean; placeholder?: string }) => (
    <label className={`field${opts?.full ? " full" : ""}`}>
      {label}
      {opts?.area ? (
        <textarea className="input" rows={3} value={form[k]} onChange={(e) => setForm({ ...form, [k]: e.target.value })} />
      ) : (
        <input className="input" value={form[k]} placeholder={fileVal != null && fileVal !== "" ? `File: ${fileVal}` : opts?.placeholder ?? "Unknown"} onChange={(e) => setForm({ ...form, [k]: e.target.value })} />
      )}
    </label>
  );

  return (
    <aside className="detail" aria-label="Track details">
      <div className="row" style={{ alignItems: "flex-start" }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <h2>{d.row.title ?? <span className="faint">{d.row.file_name}</span>}</h2>
          <div className="muted">{text(d.row.artist)}</div>
        </div>
        <button className="btn ghost icon" onClick={onClose} aria-label="Close details">
          <Icon name="close" />
        </button>
      </div>
      {d.read_error && (
        <div className="notice" style={{ marginTop: 12 }}>
          <Icon name="info" />
          <div>
            <strong>Could not read this file.</strong> {d.read_error}. The file was not changed.
          </div>
        </div>
      )}

      {d.analysis?.status === "ok" ? (
        <section>
          <h3>Analysis (estimates)</h3>
          <Waveform a={d.analysis} />
          <dl className="kv" style={{ marginTop: 8 }}>
            <dt>BPM</dt>
            <dd>
              {bpm(d.analysis.bpm)} {d.analysis.bpm_alt != null && <span className="faint">(or {bpm(d.analysis.bpm_alt)})</span>} <span className="faint small">conf. {Math.round((d.analysis.bpm_confidence ?? 0) * 100)}%</span>
              {d.analysis.bpm != null && <button className="btn ghost small" onClick={() => patch({ bpm: d.analysis!.bpm })}>Use</button>}
            </dd>
            <dt>Key</dt>
            <dd>
              {d.analysis.camelot ? <span title={keyHint(d.analysis.camelot)}>{keyName(d.analysis.camelot)}</span> : text(d.analysis.key)} {d.analysis.camelot && <span className="tag">{keyName(d.analysis.camelot, getKeyNotation() === "camelot" ? "musical" : "camelot")}</span>} <span className="faint small">conf. {Math.round((d.analysis.key_confidence ?? 0) * 100)}%</span>
              {d.analysis.camelot && <button className="btn ghost small" onClick={() => patch({ key: d.analysis!.camelot })}>Use</button>}
            </dd>
            <dt>Energy</dt>
            <dd>
              {text(d.analysis.energy)}/10 {d.analysis.energy != null && <button className="btn ghost small" onClick={() => patch({ energy: d.analysis!.energy })}>Use</button>}
            </dd>
            <dt>Loudness</dt>
            <dd>{d.analysis.loudness_lufs != null ? `${d.analysis.loudness_lufs.toFixed(1)} LUFS` : "—"} · peak {d.analysis.peak_dbfs ?? "—"} dBFS</dd>
            <dt>Intro / outro</dt>
            <dd>{duration((d.analysis.intro_end_ms ?? 0) - (d.analysis.silence_start_ms ?? 0))} / {d.analysis.outro_start_ms != null && d.analysis.duration_ms != null ? duration(d.analysis.duration_ms - (d.analysis.silence_end_ms ?? 0) - d.analysis.outro_start_ms) : "—"}</dd>
            <dt>Cue ideas</dt>
            <dd>{d.analysis.cues.map((c) => `${c.label} ${duration(c.ms)}`).join(" · ") || "—"}</dd>
          </dl>
          {d.analysis.warnings.map((w) => <p key={w} className="note">{w}</p>)}
          <p className="note">Estimates from {d.analysis.method} v{d.analysis.version}. They can be wrong (half/double tempo, modal keys) — your values always win. Serato's own cues and beatgrids are not read or changed.</p>
        </section>
      ) : (
        <section>
          <h3>Analysis</h3>
          <p className="muted small">{d.analysis?.status === "error" ? `Could not analyse: ${d.analysis.error}` : "Not analysed yet."}</p>
          <button className="btn small" onClick={() => api.startAnalysis([id], true).then(() => toast("Analysing in the background…")).catch((e) => toast(e.message, true))}>
            <Icon name="gauge" size={14} /> Analyse this track
          </button>
        </section>
      )}

      {sugg.length > 0 && (
        <section>
          <h3>Suggestions ({sugg.length})</h3>
          {sugg.slice(0, 6).map((s) => (
            <div key={s.id} className="list-row" style={{ alignItems: "flex-start" }}>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div><strong>{s.field}</strong>: <span className="faint">{s.current_value ?? "∅"}</span> → {s.suggested_value}</div>
                <div className="small muted">{s.source} · {Math.round((s.confidence ?? 0) * 100)}% · {s.evidence}</div>
              </div>
              <button className="btn small" onClick={() => api.acceptSuggestion(s.id).then(() => { setSugg(sugg.filter((x) => x.id !== s.id)); load(); onChanged(); })}>Accept</button>
              <button className="btn small ghost" aria-label="Reject" onClick={() => api.rejectSuggestion(s.id).then(() => setSugg(sugg.filter((x) => x.id !== s.id)))}><Icon name="close" size={14} /></button>
            </div>
          ))}
        </section>
      )}

      <section>
        <h3>Energy and rating (your catalogue)</h3>
        <div className="row" style={{ gap: 14 }}>
          <EnergyMeter big value={(m.energy as number) ?? null} onChange={(v) => patch({ energy: v })} />
          <span className="small muted">{m.energy != null ? `${m.energy}/10` : "Not rated"}</span>
        </div>
        <div className="row" style={{ marginTop: 10 }}>
          <span className="small muted" style={{ width: 52 }}>Rating</span>
          {[1, 2, 3, 4, 5].map((n) => (
            <button key={n} className="btn ghost small icon" aria-label={`${n} star${n > 1 ? "s" : ""}`} aria-pressed={(m.rating as number) >= n} onClick={() => patch({ rating: m.rating === n ? null : n })}>
              <span className="stars">{(m.rating as number) >= n ? "★" : <span className="off">★</span>}</span>
            </button>
          ))}
        </div>
        <div className="row" style={{ marginTop: 10 }}>
          <span className="small muted" style={{ width: 52 }}>Colour</span>
          <ColorPicker value={(m.color as string) ?? null} onChange={(c) => patch({ color: c })} />
        </div>
      </section>

      <section>
        <h3>Tags</h3>
        <div className="tagline">
          {d.row.tags.map((tg) => (
            <span key={tg} className="chip">
              {tg}
              <button aria-label={`Remove tag ${tg}`} onClick={() => api.setTags([id], [], [tg]).then(load).then(onChanged)}>
                <Icon name="close" size={12} />
              </button>
            </span>
          ))}
        </div>
        <form
          className="row"
          style={{ marginTop: 8 }}
          onSubmit={(e) => {
            e.preventDefault();
            const v = tagInput.trim();
            if (!v) return;
            api.setTags([id], [v]).then(() => {
              setTagInput("");
              load();
              onChanged();
            });
          }}
        >
          <input className="input" style={{ flex: 1 }} placeholder="Add a tag (e.g. Wedding, Peak time)" aria-label="New tag" value={tagInput} onChange={(e) => setTagInput(e.target.value)} />
          <button className="btn" type="submit">
            Add
          </button>
        </form>
      </section>

      <section>
        <h3>My catalogue values</h3>
        <p className="note" style={{ marginTop: 0, marginBottom: 10 }}>
          These override what the app shows and filters on. They are stored only in DJ Assistant and are never written to the music file or to Serato.
        </p>
        <div className="edit-grid">
          {field("genre", "Genre", f.genre)}
          {field("year", "Year", f.year)}
          {field("bpm", "BPM", f.bpm)}
          {field("key", "Key", f.key, { placeholder: "e.g. 8A or Am" })}
          {field("mood", "Mood", null, { placeholder: "e.g. Uplifting" })}
          {field("version_label", "Version label", f.version_hint)}
          <label className="field">
            Clean / explicit
            <select className="select" value={form.clean_explicit} onChange={(e) => setForm({ ...form, clean_explicit: e.target.value })}>
              <option value="">{f.clean_hint ? `From title: ${f.clean_hint}` : "Unknown"}</option>
              <option value="clean">Clean</option>
              <option value="explicit">Explicit</option>
            </select>
          </label>
          {field("notes", "Notes", null, { full: true, area: true })}
        </div>
        <div className="row" style={{ marginTop: 10 }}>
          <button className="btn primary" onClick={save}>
            Save to catalogue
          </button>
        </div>
      </section>

      <section>
        <h3>From the file (read-only)</h3>
        <KV
          items={[
            ["Title", text(f.title)],
            ["Artist", text(f.artist)],
            ["Album", text(f.album)],
            ["Album artist", text(f.album_artist)],
            ["Genre", text(f.genre)],
            ["Date / year", text(f.date ?? f.year)],
            ["Original year", text(f.original_year)],
            ["BPM tag", bpm(f.bpm as number | null)],
            ["Key tag", f.key ? `${f.key}${keyHint(f.key as string) ? ` (${keyHint(f.key as string)})` : ""}` : text(f.key)],
            ["Label", text(f.label)],
            ["Composer", text(f.composer)],
            ["ISRC", text(f.isrc)],
            ["Track / disc", `${text(f.track_no)} / ${text(f.disc_no)}`],
            ["Comment", text(f.comment)],
            ["Version (from title)", text(f.version_hint)],
          ]}
        />
        <p className="note">The year shown is whatever the file’s date tag says. It may be a release, reissue or remix year — the tag does not say which.</p>
      </section>

      <section>
        <h3>Technical</h3>
        <KV
          items={[
            ["Quality", <QualityBadge key="q" t={d.row} />],
            ["Format", text(t.format)],
            ["Codec", text(t.codec)],
            ["Lossless", t.lossless == null ? "Unknown" : t.lossless ? "Yes" : "No"],
            ["Bitrate", t.bitrate_kbps != null ? `${t.bitrate_kbps} kbps (reported average)` : "Unknown"],
            ["Sample rate", t.sample_rate != null ? `${(t.sample_rate as number) / 1000} kHz` : "Unknown"],
            ["Bit depth", text(t.bit_depth)],
            ["Channels", text(t.channels)],
            ["Duration", duration(t.duration_ms as number)],
            ["Size", bytes(t.file_size as number)],
            ["Modified", dateTime(t.file_mtime as number)],
            ["First seen", dateTime(t.first_seen_at as number)],
            ["Full-file hash", t.content_hash ? `${String(t.content_hash).slice(0, 16)}…` : "Not computed"],
          ]}
        />
        <p className="note">Bitrate is the value reported by the file. It does not prove quality: a 320 kbps file can be made from a low-quality source.</p>
      </section>

      <section>
        <h3>Location</h3>
        <div className="path">{String(t.path)}</div>
        <p className="small muted" style={{ marginTop: 6 }}>Played {d.plays} time{d.plays === 1 ? "" : "s"} (gig mode and imported history).</p>
      </section>

      <section>
        <h3>Find or buy</h3>
        {links ? (
          <div className="tagline">
            {links.map((l) => (
              <button key={l.store} className="btn small" onClick={() => openUrl(l.url)}>
                {l.store} <Icon name="external" size={12} />
              </button>
            ))}
          </div>
        ) : (
          <button className="btn small" onClick={() => api.storeLinks(d.row.artist ?? "", d.row.title ?? d.row.file_name).then(setLinks)}>Show store search links</button>
        )}
        <p className="note">Links open legitimate stores in your browser. DJ Assistant never downloads, rips or buys anything.</p>
        <div className="row wrap" style={{ marginTop: 8 }}>
          <button className="btn small" onClick={() => api.lookupMusicBrainz({ ids: [id] }).then(() => toast("Looking up on MusicBrainz… see Suggestions.")).catch((e) => toast(e.message, true))}>
            <Icon name="wand" size={14} /> MusicBrainz lookup
          </button>
          <button className="btn small" onClick={() => api.lastfmTrack(id).then((r) => toast(`${r.found} similar tracks added to Discovery.`)).catch((e) => toast(e.message, true))}>
            <Icon name="compass" size={14} /> Similar on Last.fm
          </button>
          {onWrite && (
            <button className="btn small" onClick={() => onWrite(id)}>
              <Icon name="edit" size={14} /> Write tags to file…
            </button>
          )}
        </div>
      </section>

      <section>
        <h3>In crates</h3>
        {d.crates.length ? (
          <div className="tagline">
            {d.crates.map(([cid, name]) => (
              <span key={cid} className="tag">
                {name}
              </span>
            ))}
          </div>
        ) : (
          <p className="faint small">Not added to any manual crate.</p>
        )}
      </section>
    </aside>
  );
}
