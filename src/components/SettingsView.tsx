import { useEffect, useState } from "react";
import { api } from "../api";
import type { Settings } from "../types";
import { Icon } from "./Icon";

export const SAFETY_POINTS = [
  "Read-only: DJ Assistant reads your music files. It never edits tags, renames, moves, replaces or deletes them.",
  "Serato is untouched: it does not read or write Serato databases, crates, cues, beatgrids, history or settings.",
  "Your ratings, energy, tags, crates and notes are stored only in DJ Assistant’s own catalogue on this computer.",
  "Only folders you choose are scanned. Nothing else on your computer is indexed.",
  "Works offline. This version has no online features, no account and no telemetry. Nothing about your music, file paths or listening leaves your computer.",
];

const ONLINE = [
  { name: "MusicBrainz", what: "Recording, artist and release information", sends: "Artist and title text you choose to look up" },
  { name: "AcoustID / Chromaprint", what: "Possible audio identification", sends: "An audio fingerprint (never the audio), only after you approve each lookup" },
  { name: "Last.fm", what: "Similar artists and tracks", sends: "Artist and track names you choose" },
];

export function SettingsView({ settings, onChange, info }: { settings: Settings; onChange: (s: Settings) => void; info: { version: string; db_path: string } | null }) {
  const [kbps, setKbps] = useState(String(settings.low_bitrate_kbps));
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => setKbps(String(settings.low_bitrate_kbps)), [settings.low_bitrate_kbps]);
  const set = async (key: string, value: unknown, next: Settings) => {
    try {
      await api.setSetting(key, value);
      onChange(next);
      setMsg("Saved.");
    } catch (e) {
      setMsg(String((e as Error).message));
    }
  };
  return (
    <>
      <div className="view-head">
        <div className="grow">
          <h1>Settings</h1>
          <div className="sub">Preferences, privacy and safety.</div>
        </div>
      </div>
      <div className="view-body" style={{ display: "flex", flexDirection: "column", gap: 16, maxWidth: 860 }}>
        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>Audio quality warning</h2>
          <form
            className="row wrap"
            onSubmit={(e) => {
              e.preventDefault();
              const v = Number(kbps);
              if (!Number.isInteger(v)) return setMsg("Enter a whole number.");
              set("low_bitrate_kbps", v, { ...settings, low_bitrate_kbps: v });
            }}
          >
            <label className="field" style={{ flexDirection: "row", alignItems: "center", gap: 8 }}>
              Flag lossy files below
              <input className="input" style={{ width: 90 }} inputMode="numeric" value={kbps} onChange={(e) => setKbps(e.target.value)} aria-label="Low bitrate threshold in kbps" />
              kbps
            </label>
            <button className="btn" type="submit">
              Save
            </button>
            {msg && <span className="small muted" role="status">{msg}</span>}
          </form>
          <p className="note">
            Applies only to lossy formats (MP3, AAC, Ogg, Opus…) with a known bitrate. Lossless files (FLAC, WAV, AIFF, ALAC) and files with unknown bitrate are never flagged by this rule. For variable-bitrate files the
            reported average is used. Bitrate alone does not prove audio quality.
          </p>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>Appearance</h2>
          <div className="row">
            {(["dark", "light"] as const).map((t) => (
              <button key={t} className={`btn${settings.theme === t ? " primary" : ""}`} aria-pressed={settings.theme === t} onClick={() => set("theme", t, { ...settings, theme: t })}>
                {t === "dark" ? "Dark (booth)" : "Light"}
              </button>
            ))}
          </div>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>Safety and privacy</h2>
          <ul className="privacy-list">
            {SAFETY_POINTS.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 6 }}>Online services</h2>
          <p className="muted small">None are available in this version. When added, each will be off by default and will explain exactly what it sends before you turn it on. Credentials will be stored in Windows Credential Manager.</p>
          <table className="err-table" style={{ marginTop: 8 }}>
            <thead>
              <tr>
                <th>Service</th>
                <th>Would provide</th>
                <th>Would send</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {ONLINE.map((o) => (
                <tr key={o.name}>
                  <td>{o.name}</td>
                  <td>{o.what}</td>
                  <td>{o.sends}</td>
                  <td>
                    <span className="badge q-unknown">Planned — not available</span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>

        <section className="panel">
          <h2 style={{ marginBottom: 10 }}>About</h2>
          <dl className="kv">
            <dt>Version</dt>
            <dd>{info?.version ?? "—"}</dd>
            <dt>Catalogue file</dt>
            <dd className="path">{info?.db_path ?? "—"}</dd>
          </dl>
          <p className="note">
            <Icon name="info" size={12} /> The catalogue is a local SQLite file kept outside your music folders. Back it up to keep your crates, ratings and tags.
          </p>
        </section>
      </div>
    </>
  );
}
