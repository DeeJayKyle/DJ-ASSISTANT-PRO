import { useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { AssistantReply } from "../types";
import { text } from "../lib/format";
import { Icon } from "./Icon";

interface Msg {
  role: "user" | "bot";
  text: string;
  reply?: AssistantReply;
}

const SUGGESTIONS = ["afrobeats 2010s energy 6-8 no live", "house 120-128 bpm", "low bitrate", "show duplicates", "help"];

export function ChatPanel({
  mode,
  setMode,
  onApply,
  onNavigate,
}: {
  mode: "open" | "full";
  setMode: (m: "open" | "full" | "hidden") => void;
  onApply: (r: AssistantReply) => void;
  onNavigate: (target: string) => void;
}) {
  const [msgs, setMsgs] = useState<Msg[]>([
    {
      role: "bot",
      text: "Hi Herbie. I’m a local, rule-based helper — not an AI model — so I only understand simple requests, and I can search and filter your library but can’t change files. Try one of the examples below or type “help”.",
    },
  ]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const logRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    logRef.current?.scrollTo({ top: logRef.current.scrollHeight });
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
      if (r.action === "navigate" && r.target) onNavigate(r.target);
    } catch (e) {
      setMsgs((x) => [...x, { role: "bot", text: `Something went wrong: ${(e as Error).message}` }]);
    } finally {
      setBusy(false);
    }
  };

  return (
    <aside className={`chat${mode === "full" ? " full" : ""}`} aria-label="Assistant">
      <div className="chat-head">
        <Icon name="chat" />
        <div style={{ flex: 1 }}>
          <div className="t">Assistant</div>
          <div className="s">Local and rule-based. Not AI. Works offline.</div>
        </div>
        <button className="btn ghost icon" onClick={() => setMode(mode === "full" ? "open" : "full")} aria-label={mode === "full" ? "Exit full screen" : "Expand assistant to full screen"} title={mode === "full" ? "Exit full screen" : "Full screen"}>
          <Icon name={mode === "full" ? "collapse" : "expand"} />
        </button>
        <button className="btn ghost icon" onClick={() => setMode("hidden")} aria-label="Hide assistant" title="Hide (Ctrl+J)">
          <Icon name="close" />
        </button>
      </div>
      <div className="chat-log" ref={logRef} aria-live="polite">
        {msgs.map((m, i) => (
          <div key={i} className={`msg ${m.role}`}>
            {m.text}
            {m.reply && m.reply.understood.length > 0 && (
              <>
                <div className="mini">I understood:</div>
                <ul className="small">
                  {m.reply.understood.map((u) => (
                    <li key={u}>{u}</li>
                  ))}
                </ul>
              </>
            )}
            {m.reply?.action === "search" && m.reply.total != null && m.reply.total > 0 && (
              <>
                <ul className="small">
                  {m.reply.sample.slice(0, 5).map((t) => (
                    <li key={t.id}>
                      {text(t.artist)} — {t.title ?? t.file_name}
                    </li>
                  ))}
                </ul>
                <button className="btn small" onClick={() => onApply(m.reply!)}>
                  Show all {m.reply.total} in library
                </button>
              </>
            )}
          </div>
        ))}
      </div>
      {msgs.length < 3 && (
        <div className="chat-suggest">
          {SUGGESTIONS.map((s) => (
            <button key={s} className="chip preset" onClick={() => send(s)}>
              {s}
            </button>
          ))}
        </div>
      )}
      <form
        className="chat-form"
        onSubmit={(e) => {
          e.preventDefault();
          send(input);
        }}
      >
        <input className="input" aria-label="Message the assistant" placeholder="e.g. clean 90s hip hop" value={input} onChange={(e) => setInput(e.target.value)} />
        <button className="btn primary" type="submit" disabled={busy || !input.trim()}>
          Send
        </button>
      </form>
    </aside>
  );
}
