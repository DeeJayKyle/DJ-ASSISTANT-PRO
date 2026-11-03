import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "./api";
import type { AssistantReply, Crate, FieldInfo, HealthItem, RuleSet, ScanProgress, Settings, Stats } from "./types";
import { Sidebar, type View } from "./components/Sidebar";
import { LibraryView, emptyLibraryState, type LibraryState } from "./components/LibraryView";
import { HealthView } from "./components/HealthView";
import { DuplicatesView } from "./components/DuplicatesView";
import { FoldersView } from "./components/FoldersView";
import { SettingsView, SAFETY_POINTS } from "./components/SettingsView";
import { RoadmapView } from "./components/RoadmapView";
import { ChatPanel } from "./components/ChatPanel";
import { StatusBar } from "./components/StatusBar";
import { CrateDialog } from "./components/CrateDialog";
import { Dialog } from "./components/ui";
import { Icon } from "./components/Icon";
import { emptyRuleSet } from "./lib/rules";

type ChatMode = "open" | "full" | "hidden";

export default function App() {
  const [view, setView] = useState<View>("library");
  const [settings, setSettings] = useState<Settings | null>(null);
  const [info, setInfo] = useState<{ version: string; db_path: string } | null>(null);
  const [stats, setStats] = useState<Stats | null>(null);
  const [crates, setCrates] = useState<Crate[]>([]);
  const [fields, setFields] = useState<FieldInfo[]>([]);
  const [scan, setScan] = useState<ScanProgress | null>(null);
  const [version, setVersion] = useState(0);
  const [lib, setLib] = useState<LibraryState>(emptyLibraryState());
  const [crateState, setCrateState] = useState<LibraryState>(emptyLibraryState());
  const [chat, setChat] = useState<ChatMode>("open");
  const [crateDialog, setCrateDialog] = useState<null | { crate: Crate | null; rules?: RuleSet | null }>(null);
  const [toastMsg, setToastMsg] = useState<{ m: string; err: boolean } | null>(null);
  const [fatal, setFatal] = useState<string | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);

  const toast = useCallback((m: string, err = false) => {
    setToastMsg({ m, err });
    window.setTimeout(() => setToastMsg((t) => (t?.m === m ? null : t)), err ? 6000 : 3200);
  }, []);
  const bump = useCallback(() => setVersion((v) => v + 1), []);

  // Initial load
  useEffect(() => {
    Promise.all([api.getSettings(), api.appInfo(), api.ruleFields(), api.scanStatus()])
      .then(([s, i, f, sc]) => {
        setSettings(s);
        setInfo(i);
        setFields(f);
        setScan(sc);
        setChat(s.chat_open ? "open" : "hidden");
      })
      .catch((e) => setFatal(String(e.message ?? e)));
  }, []);

  useEffect(() => {
    api.stats().then(setStats).catch(() => {});
    api.listCrates().then(setCrates).catch(() => {});
  }, [version]);

  useEffect(() => {
    if (settings) document.documentElement.dataset.theme = settings.theme;
  }, [settings]);

  // Poll scan progress while a scan runs; refresh data when it ends.
  const running = scan?.state === "running" || scan?.state === "paused";
  useEffect(() => {
    if (!running) return;
    let last = 0;
    const t = window.setInterval(async () => {
      const s = await api.scanStatus().catch(() => null);
      if (!s) return;
      setScan(s);
      const done = s.files_processed + s.unchanged;
      if (s.state !== "running" && s.state !== "paused") {
        bump();
        toast(s.state === "completed" ? `Scan complete: ${s.added} new, ${s.updated} updated, ${s.errors} problem${s.errors === 1 ? "" : "s"}.` : `Scan ${s.state}.`, s.state === "failed");
      } else if (done - last >= 500) {
        last = done;
        bump();
      }
    }, 700);
    return () => window.clearInterval(t);
  }, [running, bump, toast]);
  // When a scan is started from anywhere, pick it up.
  useEffect(() => {
    api.scanStatus().then(setScan).catch(() => {});
  }, [version]);

  const setChatMode = (m: ChatMode) => {
    setChat(m);
    api.setSetting("chat_open", m !== "hidden").catch(() => {});
  };

  // Keyboard shortcuts
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement).tagName;
      const typing = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
      if (e.key === "/" && !typing) {
        e.preventDefault();
        if (view !== "library" && !view.startsWith("crate:")) setView("library");
        setTimeout(() => searchRef.current?.focus(), 0);
      }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "j") {
        e.preventDefault();
        setChatMode(chat === "hidden" ? "open" : "hidden");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  const currentCrate = view.startsWith("crate:") ? (crates.find((c) => c.id === Number(view.slice(6))) ?? null) : null;
  useEffect(() => setCrateState(emptyLibraryState()), [currentCrate?.id]);

  const applyAssistant = (r: AssistantReply) => {
    setLib({ ...emptyLibraryState(), text: r.text ?? "", filters: r.filters ?? emptyRuleSet() });
    setView("library");
    if (chat === "full") setChatMode("open");
  };
  const openHealth = (it: HealthItem) => {
    setLib({ ...emptyLibraryState(), filters: it.filters });
    setView("library");
  };

  if (fatal)
    return (
      <div className="empty" style={{ height: "100%", justifyContent: "center" }}>
        <h2>DJ Assistant could not start</h2>
        <p>{fatal}</p>
      </div>
    );
  if (!settings) return <div className="empty">Loading…</div>;

  let main: React.ReactNode;
  if (view === "library" || currentCrate) {
    main = (
      <LibraryView
        key={currentCrate ? `c${currentCrate.id}` : "lib"}
        state={currentCrate ? crateState : lib}
        setState={currentCrate ? setCrateState : setLib}
        crate={currentCrate}
        crates={crates}
        fields={fields}
        version={version}
        bump={bump}
        toast={toast}
        onEditCrate={(c) => setCrateDialog({ crate: c })}
        onSaveSmart={(rules) => setCrateDialog({ crate: null, rules })}
        searchRef={searchRef}
      />
    );
  } else if (view === "health") main = <HealthView version={version} onOpen={openHealth} />;
  else if (view === "duplicates") main = <DuplicatesView version={version} toast={toast} />;
  else if (view === "folders") main = <FoldersView scan={scan} version={version} bump={bump} toast={toast} />;
  else if (view === "settings") main = <SettingsView settings={settings} onChange={setSettings} info={info} />;
  else if (view === "roadmap") main = <RoadmapView />;
  else main = <div className="empty">This crate no longer exists.</div>;

  const noLibrary = stats && stats.roots === 0 && view === "library";

  return (
    <div className="shell">
      <div className={`workspace${chat === "full" ? " chat-full" : ""}`}>
        <Sidebar view={view} setView={setView} crates={crates} stats={stats} onNewCrate={() => setCrateDialog({ crate: null })} />
        <main>
          {noLibrary ? (
            <div className="empty" style={{ flex: 1, justifyContent: "center" }}>
              <h2>Welcome, Herbie</h2>
              <p style={{ maxWidth: 520 }}>Add the folders that hold your music. DJ Assistant reads them to build a searchable catalogue on this computer. It never changes, moves or deletes your files, and never touches Serato.</p>
              <button className="btn primary" onClick={() => setView("folders")}>
                <Icon name="folder" /> Add music folders
              </button>
            </div>
          ) : (
            main
          )}
        </main>
        {chat !== "hidden" && <ChatPanel mode={chat} setMode={setChatMode} onApply={applyAssistant} onNavigate={(t) => setView(t as View)} />}
      </div>
      <StatusBar scan={scan} version={info?.version ?? ""} chatHidden={chat === "hidden"} onShowChat={() => setChatMode("open")} onOpenFolders={() => setView("folders")} />
      {crateDialog && (
        <CrateDialog
          initial={crateDialog.crate}
          initialRules={crateDialog.rules}
          fields={fields}
          onClose={() => setCrateDialog(null)}
          onSaved={(c) => {
            setCrateDialog(null);
            bump();
            setView(`crate:${c.id}`);
            toast(`Crate “${c.name}” saved.`);
          }}
          onDeleted={() => {
            setCrateDialog(null);
            setView("library");
            bump();
            toast("Crate deleted. Tracks and files were not affected.");
          }}
        />
      )}
      {!settings.privacy_acknowledged && (
        <Dialog
          narrow
          title="Before you start"
          onClose={() => {}}
          footer={
            <button
              className="btn primary"
              onClick={() => {
                api.setSetting("privacy_acknowledged", true).then(() => setSettings({ ...settings, privacy_acknowledged: true }));
              }}
            >
              I understand
            </button>
          }
        >
          <p>DJ Assistant is built to protect your music library:</p>
          <ul className="privacy-list">
            {SAFETY_POINTS.map((p) => (
              <li key={p}>{p}</li>
            ))}
          </ul>
          <p className="muted small">You can read this again any time in Settings.</p>
        </Dialog>
      )}
      {toastMsg && (
        <div className={`toast${toastMsg.err ? " error" : ""}`} role={toastMsg.err ? "alert" : "status"}>
          {toastMsg.m}
        </div>
      )}
    </div>
  );
}
