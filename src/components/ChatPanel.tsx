import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { AssistantReply } from "../types";
import { text } from "../lib/format";
import { Icon } from "./Icon";
import { QualityBadge } from "./ui";

interface Msg {
  role: "user" | "bot";
  text: string;
  reply?: AssistantReply;
}

const SUGGESTIONS = ["Show low-bitrate Afrobeats tracks", "house 120-128 bpm", "plan a 2 hour wedding set", "show duplicates", "help"];

export function ChatPanel({ mode, setMode, onApply, onNavigate }: {
  mode: "open" | "full";
  setMode: (m: "open" | "full" | "hidden") => void;
  onApply: (r: AssistantReply) => void;
  onNavigate: (target: string, r: AssistantReply) => void;
}) {
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [menu, setMenu] = useState(false);
  const logRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    logRef.current?.scrollTo({ top: logRef.current.scrollHeight, behavior: "smooth" });
  }, [msgs]);

  const send = async (m: string) => {
    const q = m.trim();
    if (!q || busy) return;
    setInput("");
    setMsgs((x) => [...x, { role: "user", text: q }]);
    setBusy(true);
    try {
      const r = await api.assistant(q);
      setMsgs((x) => [...x, { role: "bot", text: r.reply, reply: r }]);
      if (r.action === "navigate" && r.target) onNavigate(r.target, r);
    } catch (e) {
      setMsgs((x) => [...x, { role: "bot", text: `Something went wrong: ${(e as Error).message}` }]);
    } finally {
      setBusy(false);
    }
  };

  return (
    <aside className="chat" aria-label="Assistant">
      <div className="chat-head">
        <div style={{ flex: 1 }}>
          <div className="t">
            <Icon name="sparkles" size={26} /> Assistant
          </div>
        </div>
        <span className="rel">
          <button className="btn icon" aria-label="Assistant options" aria-expanded={menu} onClick={() => setMenu(!menu)}>
            <span aria-hidden style={{ fontWeight: 800, letterSpacing: 1 }}>···</span>
          </button>
          {menu && (
            <div className="menu" style={{ left: "auto", right: 0 }} onMouseLeave={() => setMenu(false)}>
              <button onClick={() => { setMode(mode === "full" ? "open" : "full"); setMenu(false); }}>
                <Icon name={mode === "full" ? "collapse" : "expand"} size={16} /> {mode === "full" ? "Exit full screen" : "Full screen"}
              </button>
              <button onClick={() => { setMsgs([]); setMenu(false); }}>
                <Icon name="trash" size={16} /> Clear conversation
              </button>
              <button onClick={() => setMode("hidden")}>
                <Icon name="close" size={16} /> Hide assistant (Ctrl+J)
              </button>
            </div>
          )}
        </span>
      </div>
      <div className="chat-intro">
        <h2>Local search &amp; rules</h2>
        <p className="muted" style={{ margin: 0 }}>Find, filter and manage your music library using local data and simple rules. Not an AI model — it says exactly what it understood.</p>
      </div>
      <div className="chat-log" ref={logRef} aria-live="polite">
        {msgs.length === 0 && (
          <div className="col" style={{ gap: 10 }}>
            <span className="small faint">Try:</span>
            {SUGGESTIONS.map((s) => (
              <button key={s} className="chip preset" style={{ alignSelf: "flex-start" }} onClick={() => send(s)}>
                {s}
              </button>
            ))}
          </div>
        )}
        {msgs.map((m, i) =>
          m.role === "user" ? (
            <div key={i} className="bubble-user">
              <span>{m.text}</span>
              <Icon name="user" size={18} />
            </div>
          ) : (
            <div key={i} className="bubble-bot glass">
              <div className="headline">
                <Icon name="sparkles" size={20} />
                <div>
                  <strong>{m.reply?.action === "search" && m.reply.total != null ? `${m.reply.total} track${m.reply.total === 1 ? "" : "s"} match your filters.` : m.text.split("\n")[0]}</strong>
                  {m.reply?.understood && m.reply.understood.length > 0 && <div className="muted small" style={{ marginTop: 2 }}>{m.reply.understood.join(", ").replace(/^./, (c) => c.toUpperCase())}.</div>}
                  {m.reply?.action !== "search" && m.text.includes("\n") && <div className="muted small" style={{ whiteSpace: "pre-wrap", marginTop: 4 }}>{m.text.split("\n").slice(1).join("\n")}</div>}
                  {m.reply?.action === "search" && m.reply.total === 0 && <div className="muted small">{m.text}</div>}
                </div>
              </div>
              {m.reply?.action === "search" && m.reply.sample.length > 0 && (
                <div className="result-list">
                  {m.reply.sample.slice(0, 5).map((t) => (
                    <div key={t.id}>
                      <Icon name="music" size={16} />
                      <span className="cell strong">{t.title ?? t.file_name}</span>
                      <span className="cell muted">{text(t.artist)}</span>
                      {t.bitrate_kbps != null ? <span className={`badge q-${t.quality}`}>{t.bitrate_kbps} kbps</span> : <QualityBadge t={t} />}
                    </div>
                  ))}
                </div>
              )}
              {m.reply?.action === "search" && (m.reply.total ?? 0) > 0 && (
                <div className="row" style={{ marginTop: 12 }}>
                  <button className="btn primary big" style={{ flex: 1 }} onClick={() => onApply(m.reply!)}>
                    <Icon name="filter" size={18} /> Apply filters
                  </button>
                  <button className="btn icon big" style={{ width: 44, padding: 0 }} aria-label="Open in library with filter editor" onClick={() => onApply({ ...m.reply!, target: "edit" })}>
                    <Icon name="smart" size={18} />
                  </button>
                </div>
              )}
            </div>
          ),
        )}
        {busy && <div className="skeleton" style={{ width: "60%" }} />}
      </div>
      <form className="chat-form" onSubmit={(e) => { e.preventDefault(); send(input); }}>
        <input className="input" aria-label="Message the assistant" placeholder="Ask a local search or rule..." value={input} onChange={(e) => setInput(e.target.value)} />
        <button className="chat-send" type="submit" aria-label="Send" disabled={busy || !input.trim()}>
          <Icon name="send" size={20} />
        </button>
      </form>
    </aside>
  );
}
