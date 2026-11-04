import { Fragment, useEffect, useRef, useState } from "react";
import { api } from "../api";
import type { AiStatus, AiTurn, AssistantReply, RuleSet, SetParams } from "../types";
import { text } from "../lib/format";
import { Icon } from "./Icon";
import { QualityBadge } from "./ui";

interface Msg {
  role: "user" | "bot" | "ai" | "cmd";
  text: string;
  reply?: AssistantReply;
  turn?: AiTurn;
  /** Decisions taken on this turn's action cards. */
  decided?: Record<string, boolean>;
  error?: boolean;
}

export type UiAction = { type: "show_tracks"; text?: string; filters?: RuleSet; label?: string } | { type: "open_view"; view: string; crate_id?: number; category?: string; set_params?: Partial<SetParams> };

const RULE_SUGGESTIONS = ["Show low-bitrate Afrobeats tracks", "house 120-128 bpm", "plan a 2 hour wedding set", "show duplicates", "help"];
const AI_SUGGESTIONS = ["What's in my library?", "Build me a peak-time Afrobeats crate", "Which tracks are missing genre or year?", "Plan a 2 hour wedding set, clean only", "What mixes well after my highest-rated house track?"];

/** Slash commands run app tasks directly, with or without the AI model. */
export const COMMANDS: Array<{ cmd: string; args?: string; help: string }> = [
  { cmd: "/scan", help: "Scan your music folders (read-only)" },
  { cmd: "/analyse", args: "[all]", help: "Analyse tracks not analysed yet (all: redo every track)" },
  { cmd: "/suggest", help: "Find metadata suggestions in file and folder names" },
  { cmd: "/find", args: "<text>", help: "Show matching tracks in the library" },
  { cmd: "/fix", args: "genre|year|album|bpm|key|artist", help: "Open the Library Health fixer" },
  { cmd: "/health", help: "Open Library Health" },
  { cmd: "/dupes", help: "Open Duplicate Review" },
  { cmd: "/crate", args: "<name>", help: "Create an empty manual crate" },
  { cmd: "/set", args: "<minutes> [journey|warmup|peak|wedding|lounge] [clean]", help: "Open Set Studio pre-filled" },
  { cmd: "/gig", args: "start [name] | end", help: "Start or end gig mode" },
  { cmd: "/keys", args: "camelot|musical", help: "Choose how keys are shown" },
  { cmd: "/premium", args: "on|off", help: "Premium UI (Midnight Pro look)" },
  { cmd: "/theme", args: "dark|light", help: "Switch theme" },
  { cmd: "/clear", help: "Start a new conversation" },
  { cmd: "/help", help: "List these commands" },
];

/** Minimal, safe rendering of the model's text: paragraphs, lists, **bold**, `code`. */
function Rich({ src }: { src: string }) {
  const inline = (s: string, k: string) =>
    s.split(/(\*\*[^*]+\*\*|`[^`]+`)/g).map((p, i) =>
      p.startsWith("**") && p.endsWith("**") ? <strong key={`${k}${i}`}>{p.slice(2, -2)}</strong> : p.startsWith("`") && p.endsWith("`") ? <code key={`${k}${i}`}>{p.slice(1, -1)}</code> : <Fragment key={`${k}${i}`}>{p}</Fragment>,
    );
  return (
    <div className="rich">
      {src.split(/\n{2,}/).map((para, i) => {
        const lines = para.split("\n").filter((l) => l.trim());
        if (lines.length && lines.every((l) => /^\s*([-*•]|\d+[.)])\s+/.test(l))) {
          const ordered = /^\s*\d/.test(lines[0]);
          const items = lines.map((l, j) => <li key={j}>{inline(l.replace(/^\s*([-*•]|\d+[.)])\s+/, ""), `${i}-${j}-`)}</li>);
          return ordered ? <ol key={i}>{items}</ol> : <ul key={i}>{items}</ul>;
        }
        return <p key={i}>{lines.map((l, j) => <Fragment key={j}>{j > 0 && <br />}{inline(l.replace(/^#+\s*/, ""), `${i}-${j}-`)}</Fragment>)}</p>;
      })}
    </div>
  );
}

export function ChatPanel({ mode, setMode, onApply, onNavigate, onUi, onOpenSettings, onChanged, toast }: {
  mode: "open" | "full";
  setMode: (m: "open" | "full" | "hidden") => void;
  onApply: (r: AssistantReply) => void;
  onNavigate: (target: string, r: AssistantReply) => void;
  onUi: (a: UiAction) => void;
  onOpenSettings: () => void;
  onChanged: () => void;
  toast: (m: string, e?: boolean) => void;
}) {
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [input, setInput] = useState("");
  const [busy, setBusy] = useState(false);
  const [menu, setMenu] = useState(false);
  const [ai, setAi] = useState<AiStatus | null>(null);
  const [conv, setConv] = useState<string | null>(null);
  const logRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    logRef.current?.scrollTo({ top: logRef.current.scrollHeight, behavior: "smooth" });
  }, [msgs, busy]);
  useEffect(() => {
    const load = () => api.aiStatus().then(setAi).catch(() => setAi(null));
    load();
    window.addEventListener("dj-ai-changed", load);
    return () => window.removeEventListener("dj-ai-changed", load);
  }, []);
  const aiOn = !!ai?.ready;

  const say = (m: Msg) => setMsgs((x) => [...x, m]);
  const applyTurn = (t: AiTurn) => {
    setConv(t.conversation_id);
    t.ui_actions.forEach((a) => onUi(a as UiAction));
    if (t.done.some((d) => d.ok)) onChanged();
  };

  const runCommand = async (q: string): Promise<boolean> => {
    const [c, ...rest] = q.trim().split(/\s+/);
    const arg = rest.join(" ");
    const cmd = c.toLowerCase();
    const done = (t: string) => say({ role: "cmd", text: t });
    const lib = (filters: RuleSet | null, txt: string | null) => onApply({ reply: "", understood: [], action: "search", target: null, text: txt, filters, total: null, sample: [] });
    switch (cmd) {
      case "/help":
        done(COMMANDS.map((x) => `${x.cmd}${x.args ? ` ${x.args}` : ""} — ${x.help}`).join("\n"));
        return true;
      case "/clear":
        if (conv) api.aiReset(conv).catch(() => {});
        setConv(null);
        setMsgs([]);
        return true;
      case "/scan":
        await api.startScan();
        done("Scan started (read-only). Progress is in Scan Activity.");
        onChanged();
        return true;
      case "/analyse":
      case "/analyze":
        await api.startAnalysis(undefined, rest[0] === "all");
        done(rest[0] === "all" ? "Re-analysing every track in the background." : "Analysing tracks that aren't analysed yet, in the background.");
        return true;
      case "/suggest": {
        const r = await api.generateSuggestions();
        done(`Found ${r.created} new suggestion${r.created === 1 ? "" : "s"}. Review them in Suggestions.`);
        onChanged();
        return true;
      }
      case "/find":
        lib(null, arg);
        done(`Showing tracks matching “${arg}”.`);
        return true;
      case "/fix": {
        const map: Record<string, string> = { genre: "missing_genre", year: "missing_year", album: "missing_album", bpm: "missing_bpm", key: "missing_key", artist: "missing_core", title: "missing_core" };
        const cat = map[rest[0]?.toLowerCase() ?? ""];
        if (!cat) { done("Use /fix genre, year, album, bpm, key or artist."); return true; }
        onUi({ type: "open_view", view: "health-fix", category: cat });
        done(`Opened the fixer for missing ${rest[0]}.`);
        return true;
      }
      case "/health": onNavigate("health", {} as AssistantReply); done("Opened Library Health."); return true;
      case "/dupes": onNavigate("duplicates", {} as AssistantReply); done("Opened Duplicate Review."); return true;
      case "/crate": {
        if (!arg) { done("Give the crate a name: /crate Peak Time Afro"); return true; }
        await api.createCrate({ name: arg, kind: "manual" });
        done(`Created the manual crate “${arg}”. Add tracks from the library.`);
        onChanged();
        return true;
      }
      case "/set": {
        const minutes = Number(rest.find((x) => /^\d+$/.test(x)) ?? 60);
        const curve = rest.find((x) => ["journey", "warmup", "peak", "wedding", "lounge"].includes(x));
        const params: Partial<SetParams> = { duration_min: minutes, ...(curve ? { curve } : {}), ...(rest.includes("clean") ? { clean_only: true } : {}) };
        onUi({ type: "open_view", view: "set-studio", set_params: params });
        done(`Opened Set Studio for a ${minutes}-minute set${curve ? ` (${curve})` : ""}${rest.includes("clean") ? ", clean only" : ""}.`);
        return true;
      }
      case "/gig":
        if (rest[0] === "end") { await api.gigEnd(); done("Gig ended. The recap is in Gig Mode."); }
        else { await api.gigStart(rest.slice(1).join(" ") || "Gig", null); done("Gig mode is on. Background work is paused."); }
        onChanged();
        return true;
      case "/keys":
        if (!["camelot", "musical"].includes(rest[0])) { done("Use /keys camelot or /keys musical."); return true; }
        await api.setSetting("key_notation", rest[0]);
        done(`Keys now show in ${rest[0]} notation.`);
        onChanged();
        return true;
      case "/premium":
        await api.setSetting("premium_ui", rest[0] !== "off");
        done(`Premium UI ${rest[0] !== "off" ? "on" : "off"}.`);
        onChanged();
        return true;
      case "/theme":
        if (!["dark", "light"].includes(rest[0])) { done("Use /theme dark or /theme light."); return true; }
        await api.setSetting("theme", rest[0]);
        done(`Theme: ${rest[0]}.`);
        onChanged();
        return true;
    }
    return false;
  };

  const send = async (m: string) => {
    const q = m.trim();
    if (!q || busy) return;
    setInput("");
    say({ role: "user", text: q });
    setBusy(true);
    try {
      if (q.startsWith("/")) {
        if (!(await runCommand(q))) say({ role: "cmd", text: `Unknown command ${q.split(/\s/)[0]}. Type /help for the list.`, error: true });
      } else if (aiOn) {
        const t = await api.aiChat(q, conv);
        say({ role: "ai", text: t.text, turn: t });
        applyTurn(t);
      } else {
        const r = await api.assistant(q);
        say({ role: "bot", text: r.reply, reply: r });
        if (r.action === "navigate" && r.target) onNavigate(r.target, r);
      }
    } catch (e) {
      say({ role: "cmd", text: (e as Error).message, error: true });
    } finally {
      setBusy(false);
    }
  };

  const decide = async (idx: number, decisions: Record<string, boolean>) => {
    const t = msgs[idx].turn!;
    setMsgs((x) => x.map((m, i) => (i === idx ? { ...m, decided: decisions } : m)));
    setBusy(true);
    try {
      const r = await api.aiConfirm(t.conversation_id, decisions);
      say({ role: "ai", text: r.text, turn: r });
      applyTurn(r);
      const ok = r.done.filter((d) => d.ok).length;
      if (ok) toast(`${ok} action${ok === 1 ? "" : "s"} done.`);
    } catch (e) {
      say({ role: "cmd", text: (e as Error).message, error: true });
    } finally {
      setBusy(false);
    }
  };

  const palette = input.startsWith("/") && !input.includes(" ") ? COMMANDS.filter((c) => c.cmd.startsWith(input.toLowerCase())) : [];
  const providerLabel = ai?.provider === "claude" ? ai.claude_models.find((m) => m.id === ai.model)?.label.split(" — ")[0] ?? ai.model : ai?.provider === "local" ? `${ai.model} (on this computer)` : "";

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
              <button onClick={() => { if (conv) api.aiReset(conv).catch(() => {}); setConv(null); setMsgs([]); setMenu(false); }}>
                <Icon name="trash" size={16} /> New conversation
              </button>
              <button onClick={() => { onOpenSettings(); setMenu(false); }}>
                <Icon name="settings" size={16} /> AI settings
              </button>
              <button onClick={() => setMode("hidden")}>
                <Icon name="close" size={16} /> Hide assistant (Ctrl+J)
              </button>
            </div>
          )}
        </span>
      </div>
      <div className="chat-intro">
        {aiOn ? (
          <>
            <h2>AI assistant <span className="ai-pill" title={ai?.sends}>{providerLabel}</span></h2>
            <p className="muted" style={{ margin: 0 }}>Knows every feature of DJ Assistant and works with your library. Anything that changes your catalogue waits for you to press Run. Your music files are never changed.</p>
          </>
        ) : (
          <>
            <h2>Local search &amp; rules</h2>
            <p className="muted" style={{ margin: 0 }}>Find, filter and manage your library with local rules and /commands.{" "}
              <button className="link-btn" onClick={onOpenSettings}>Turn on the AI assistant</button> to chat about your library and let it run tasks for you.
              {ai && ai.provider !== "off" && ai.reason ? <span className="s-error"> {ai.reason}</span> : null}
            </p>
          </>
        )}
      </div>
      <div className="chat-log" ref={logRef} aria-live="polite">
        {msgs.length === 0 && (
          <div className="col" style={{ gap: 10 }}>
            <span className="small faint">Try:</span>
            {(aiOn ? AI_SUGGESTIONS : RULE_SUGGESTIONS).map((s) => (
              <button key={s} className="chip preset" style={{ alignSelf: "flex-start" }} onClick={() => send(s)}>
                {s}
              </button>
            ))}
            <span className="small faint" style={{ marginTop: 4 }}>Type <kbd className="kbd">/</kbd> for commands.</span>
          </div>
        )}
        {msgs.map((m, i) => {
          if (m.role === "user")
            return (
              <div key={i} className="bubble-user">
                <span>{m.text}</span>
                <Icon name="user" size={18} />
              </div>
            );
          if (m.role === "cmd")
            return (
              <div key={i} className={`bubble-cmd${m.error ? " err" : ""}`}>
                <Icon name={m.error ? "warn" : "zap"} size={15} />
                <span style={{ whiteSpace: "pre-wrap" }}>{m.text}</span>
              </div>
            );
          if (m.role === "ai") {
            const t = m.turn!;
            const pending = t.pending;
            const decided = m.decided;
            return (
              <div key={i} className="bubble-bot glass ai">
                {t.done.length > 0 && (
                  <div className="ai-done">
                    {t.done.map((d, j) => (
                      <div key={j} className={d.ok ? "ok" : d.skipped ? "skip" : "fail"}>
                        <Icon name={d.ok ? "check" : d.skipped ? "minus" : "warn"} size={14} /> {d.summary}{d.error ? ` — ${d.error}` : d.skipped ? " (skipped)" : ""}
                      </div>
                    ))}
                  </div>
                )}
                {t.looked_up.length > 0 && <div className="ai-looked small faint"><Icon name="search" size={12} /> Looked up: {[...new Set(t.looked_up)].join(", ")}</div>}
                {t.text ? <Rich src={t.text} /> : !pending.length && <p className="muted">Done.</p>}
                {t.ui_actions.length > 0 && <div className="small faint" style={{ marginTop: 6 }}><Icon name="eye" size={12} /> {t.ui_actions.map((a) => (a.type === "show_tracks" ? `Showing ${String(a.label ?? "tracks")} in the library` : `Opened ${String(a.view)}`)).join(" · ")}</div>}
                {pending.length > 0 && (
                  <div className="ai-actions">
                    {pending.map((p) => (
                      <div key={p.id} className={`ai-action${decided ? (decided[p.id] ? " run" : " skipped") : ""}`}>
                        <Icon name="wand" size={16} />
                        <span className="grow">{p.summary}</span>
                        {!decided && pending.length > 1 && (
                          <span className="small faint">#{pending.indexOf(p) + 1}</span>
                        )}
                      </div>
                    ))}
                    {!decided ? (
                      <div className="row" style={{ gap: 8, marginTop: 8 }}>
                        <button className="btn primary" disabled={busy} onClick={() => decide(i, Object.fromEntries(pending.map((p) => [p.id, true])))}>
                          <Icon name="play" size={15} /> Run{pending.length > 1 ? ` all ${pending.length}` : ""}
                        </button>
                        {pending.length > 1 && pending.map((p, j) => (
                          <button key={p.id} className="btn small" disabled={busy} title={`Run only: ${p.summary}`} onClick={() => decide(i, Object.fromEntries(pending.map((q) => [q.id, q.id === p.id])))}>Only #{j + 1}</button>
                        ))}
                        <button className="btn ghost" disabled={busy} onClick={() => decide(i, {})}>Skip</button>
                      </div>
                    ) : (
                      <div className="small faint" style={{ marginTop: 6 }}>{Object.values(decided).some(Boolean) ? "Approved." : "Skipped."}</div>
                    )}
                  </div>
                )}
              </div>
            );
          }
          return (
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
                      <Icon name={t.media_kind === "video" ? "film" : "music"} size={16} />
                      <span className="cell strong">{t.title ?? t.file_name}</span>
                      <span className="cell muted">{text(t.artist)}</span>
                      {t.bitrate_kbps != null && t.quality !== "video" ? <span className={`badge q-${t.quality}`}>{t.bitrate_kbps} kbps</span> : <QualityBadge t={t} />}
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
          );
        })}
        {busy && (
          <div className="ai-typing" aria-label="Assistant is working">
            <span /><span /><span />
          </div>
        )}
      </div>
      {palette.length > 0 && (
        <div className="cmd-palette glass" role="listbox" aria-label="Commands">
          {palette.map((c) => (
            <button key={c.cmd} role="option" aria-selected={false} onClick={() => setInput(c.args ? `${c.cmd} ` : c.cmd)}>
              <code>{c.cmd}</code>
              {c.args && <span className="faint small">{c.args}</span>}
              <span className="muted small grow" style={{ textAlign: "right" }}>{c.help}</span>
            </button>
          ))}
        </div>
      )}
      <form className="chat-form" onSubmit={(e) => { e.preventDefault(); send(input); }}>
        <input className="input" aria-label="Message the assistant" placeholder={aiOn ? "Ask anything, or type / for commands…" : "Ask a local search or rule, or type /…"} value={input} onChange={(e) => setInput(e.target.value)} />
        <button className="chat-send" type="submit" aria-label="Send" disabled={busy || !input.trim()}>
          <Icon name="send" size={20} />
        </button>
      </form>
    </aside>
  );
}
