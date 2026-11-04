import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "./api";
import { setKeyNotation } from "./lib/format";
import type { AssistantReply, Crate, FieldInfo, Health, HealthItem, JobState, Root, RuleSet, ScanProgress, SetParams, Settings, Stats } from "./types";
import { Sidebar, type View } from "./components/Sidebar";
import { TitleBar } from "./components/TitleBar";
import { LibraryView, addFoldersFlow, emptyLibraryState, type LibraryState } from "./components/LibraryView";
import { HealthView } from "./components/HealthView";
import { DuplicatesView } from "./components/DuplicatesView";
import { ActivityView } from "./components/ActivityView";
import { CratesView } from "./components/CratesView";
import { SuggestionsView } from "./components/SuggestionsView";
import { DiscoveryView } from "./components/DiscoveryView";
import { SetStudioView } from "./components/SetStudioView";
import { GigView } from "./components/GigView";
import { GigPackView } from "./components/GigPackView";
import { FilesView } from "./components/FilesView";
import { SettingsView, SAFETY_POINTS } from "./components/SettingsView";
import { QuickPrepView } from "./components/quick/QuickPrepView";
import { ChatPanel, type UiAction } from "./components/ChatPanel";
import { StatusBar } from "./components/StatusBar";
import { CrateDialog } from "./components/CrateDialog";
import { Dialog } from "./components/ui";
import { Icon } from "./components/Icon";
import { emptyRuleSet } from "./lib/rules";
import { checkForUpdate, type UpdateInfo } from "./lib/updater";
import { useAccount } from "./components/Accounts";

type ChatMode = "open" | "full" | "hidden";

export default function App() {
  const [view, setView] = useState<View>("library");
  const [settings, setSettings] = useState<Settings | null>(null);
  const [healthFix, setHealthFix] = useState<{ category: string; n: number } | null>(null);
  // The status bar's "online services" list must follow AI provider changes at once.
  useEffect(() => {
    const on = () => setVersion((v) => v + 1);
    window.addEventListener("dj-ai-changed", on);
    return () => window.removeEventListener("dj-ai-changed", on);
  }, []);
  const [info, setInfo] = useState<{ version: string; db_path: string } | null>(null);
  const [stats, setStats] = useState<Stats | null>(null);
  const [crates, setCrates] = useState<Crate[]>([]);
  const [roots, setRoots] = useState<Root[]>([]);
  const [fields, setFields] = useState<FieldInfo[]>([]);
  const [scan, setScan] = useState<ScanProgress | null>(null);
  const [jobs, setJobs] = useState<JobState[]>([]);
  const [health, setHealth] = useState<Health | null>(null);
  const [pending, setPending] = useState(0);
  const [onlineOn, setOnlineOn] = useState<string[]>([]);
  const [version, setVersion] = useState(0);
  const [lib, setLib] = useState<LibraryState>(emptyLibraryState());
  const [subState, setSubState] = useState<LibraryState>(emptyLibraryState());
  const [chat, setChat] = useState<ChatMode>("open");
  const [crateDialog, setCrateDialog] = useState<null | { crate: Crate | null; rules?: RuleSet | null }>(null);
  const [setParams, setSetParams] = useState<Partial<SetParams> | null>(null);
  const [toastMsg, setToastMsg] = useState<{ m: string; err: boolean; k: number } | null>(null);
  const [update, setUpdate] = useState<{ info: UpdateInfo; pct: number | null; installing: boolean } | null>(null);
  const [fatal, setFatal] = useState<string | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const account = useAccount();

  const toast = useCallback((m: string, err = false) => {
    const k = Date.now();
    setToastMsg({ m, err, k });
    window.setTimeout(() => setToastMsg((t) => (t?.k === k ? null : t)), err ? 6500 : 3400);
  }, []);
  const bump = useCallback(() => setVersion((v) => v + 1), []);

  useEffect(() => {
    let stale = false;
    Promise.all([api.getSettings(), api.appInfo(), api.ruleFields(), api.scanStatus()])
      .then(([s, i, f, sc]) => {
        if (stale) return;
        setSettings(s);
        setInfo(i);
        setFields(f);
        setScan(sc);
        setChat(s.chat_open ? "open" : "hidden");
        if (s.auto_update) checkForUpdate().then((u) => !stale && u && setUpdate({ info: u, pct: null, installing: false })).catch(() => {});
      })
      .catch((e) => !stale && setFatal(String(e.message ?? e)));
    return () => { stale = true; };
  }, []);

  useEffect(() => {
    api.stats().then(setStats).catch(() => {});
    api.listCrates().then(setCrates).catch(() => {});
    api.listRoots().then(setRoots).catch(() => {});
    api.health().then(setHealth).catch(() => {});
    api.suggestionCounts().then((c) => setPending(c.pending ?? 0)).catch(() => {});
    api.services().then((s) => setOnlineOn(s.filter((x) => x.enabled && x.id !== "updates").map((x) => x.name))).catch(() => {});
  }, [version]);

  useEffect(() => {
    if (!settings) return;
    const r = document.documentElement;
    r.dataset.theme = settings.theme;
    r.dataset.surface = settings.surface;
    r.dataset.motion = settings.motion;
    // Premium UI only repaints: the Midnight Pro palette over the current view.
    if (settings.premium_ui) r.dataset.palette = "midnight-pro";
    else delete r.dataset.palette;
  }, [settings]);
  // Applied during render so every view formats keys with the current choice.
  if (settings) setKeyNotation(settings.key_notation);

  // Poll scan + background jobs; refresh data when they finish.
  const busy = scan?.state === "running" || scan?.state === "paused" || jobs.some((j) => j.state === "running" || j.state === "paused");
  const prevScan = useRef<string>("idle");
  const prevJobs = useRef<Record<string, string>>({});
  useEffect(() => {
    let last = 0;
    const live = (st: string) => st === "running" || st === "paused";
    const t = window.setInterval(async () => {
      const [s, j] = await Promise.all([api.scanStatus().catch(() => null), api.jobs().catch(() => [] as JobState[])]);
      let changed = false;
      if (s) {
        if (live(prevScan.current) && !live(s.state)) {
          changed = true;
          toast(s.state === "completed" ? `Scan complete: ${s.added} new, ${s.updated} updated, ${s.errors} problem${s.errors === 1 ? "" : "s"}.` : `Scan ${s.state}.`, s.state === "failed");
        }
        prevScan.current = s.state;
        setScan(s);
        const done = s.files_processed + s.unchanged;
        if (s.state === "running" && done - last >= 500) { last = done; changed = true; }
      }
      for (const n of j) {
        const was = prevJobs.current[n.kind];
        if (was && live(was) && !live(n.state)) {
          changed = true;
          toast(n.state === "failed" ? `${n.kind} failed: ${n.message}` : `${n.kind[0].toUpperCase() + n.kind.slice(1)} ${n.state}${n.errors ? ` (${n.errors} could not be processed)` : ""}.`, n.state === "failed");
        }
        prevJobs.current[n.kind] = n.state;
      }
      setJobs(j);
      if (changed) bump();
    }, busy ? 700 : 2500);
    return () => window.clearInterval(t);
  }, [busy, bump, toast]);

  const setChatMode = (m: ChatMode) => {
    setChat(m);
    api.setSetting("chat_open", m !== "hidden").catch(() => {});
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement).tagName;
      const typing = tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT";
      if (e.key === "/" && !typing) {
        e.preventDefault();
        if (view !== "library" && !view.startsWith("crate:") && !view.startsWith("root:")) setView("library");
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
  const currentRoot = view.startsWith("root:") ? (roots.find((r) => r.id === Number(view.slice(5))) ?? null) : null;
  useEffect(() => setSubState(emptyLibraryState()), [currentCrate?.id, currentRoot?.id]);

  const applyAssistant = (r: AssistantReply) => {
    setLib({ ...emptyLibraryState(), text: r.text ?? "", filters: r.filters ?? emptyRuleSet() });
    setView("library");
    if (chat === "full") setChatMode("open");
  };
  const openHealth = (it: HealthItem) => {
    setLib({ ...emptyLibraryState(), filters: it.filters });
    setView("library");
  };
  const navigate = (target: string, r: AssistantReply) => {
    if (target === "set-studio" && r.params) setSetParams(r.params);
    const map: Record<string, View> = { folders: "activity" };
    setView((map[target] ?? target) as View);
  };
  // Screen changes requested by the AI assistant or a /command.
  const onAiUi = (a: UiAction) => {
    if (a.type === "show_tracks") {
      applyAssistant({ reply: "", understood: [], action: "search", target: null, text: a.text ?? null, filters: a.filters ?? null, total: null, sample: [] });
      return;
    }
    if (a.view === "crate" && a.crate_id != null) setView(`crate:${a.crate_id}` as View);
    else if (a.view === "health-fix") {
      setHealthFix({ category: a.category ?? "missing_genre", n: Date.now() });
      setView("health");
    } else if (a.view === "set-studio") {
      if (a.set_params) setSetParams(a.set_params);
      setView("set-studio");
    } else setView(a.view as View);
    if (chat === "full") setChatMode("open");
  };
  const refreshAfterChat = () => {
    bump();
    api.getSettings().then(setSettings).catch(() => {});
  };

  if (fatal) return <div className="empty" style={{ height: "100%", justifyContent: "center" }}><h2>DJ Assistant could not start</h2><p>{fatal}</p></div>;
  if (!settings) return <div className="empty" style={{ height: "100%", justifyContent: "center" }}><div className="spin"><Icon name="disc" size={32} /></div></div>;

  const scanning = scan?.state === "running" || scan?.state === "paused";
  const onAddFolder = () => addFoldersFlow(toast, bump).then((ok) => !ok && setView("activity"));
  const onScan = () => (roots.length ? api.startScan().then(() => { setScan({ ...(scan as ScanProgress), state: "running", phase: "starting" }); toast("Read-only scan started."); }).catch((e) => toast(e.message, true)) : setView("activity"));

  let main: React.ReactNode;
  if (view === "library" || currentCrate || currentRoot) {
    const noLibrary = stats && stats.roots === 0 && view === "library";
    main = noLibrary ? (
      <div className="page"><div className="empty" style={{ flex: 1, justifyContent: "center" }}>
        <div className="art"><Icon name="music" size={30} /></div>
        <h2>Welcome, {account?.current.name ?? "DJ"}</h2>
        <p style={{ maxWidth: 520 }}>Add the folders that hold your music. DJ Assistant reads them to build a searchable catalogue on this computer. It never changes, moves or deletes your files, and never writes to Serato.</p>
        <button className="btn primary big" onClick={() => setView("activity")}><Icon name="folder" size={18} /> Add music folders</button>
      </div></div>
    ) : (
      <LibraryView
        key={currentCrate ? `c${currentCrate.id}` : currentRoot ? `r${currentRoot.id}` : "lib"}
        state={currentCrate || currentRoot ? subState : lib}
        setState={currentCrate || currentRoot ? setSubState : setLib}
        crate={currentCrate}
        root={currentRoot}
        crates={crates}
        fields={fields}
        version={version}
        bump={bump}
        toast={toast}
        onEditCrate={(c) => setCrateDialog({ crate: c })}
        onSaveSmart={(rules) => setCrateDialog({ crate: null, rules })}
        searchRef={searchRef}
        onAddFolder={onAddFolder}
        onScan={onScan}
        scanning={scanning}
      />
    );
  } else if (view === "quick") main = <QuickPrepView crates={crates} roots={roots} toast={toast} bump={bump} />;
  else if (view === "health") main = <div className="page"><HealthView version={version} onOpen={openHealth} toast={toast} bump={bump} startFix={healthFix} /></div>;
  else if (view === "duplicates") main = <div className="page"><DuplicatesView version={version} toast={toast} /></div>;
  else if (view === "activity") main = <ActivityView scan={scan} version={version} bump={bump} toast={toast} health={health} />;
  else if (view === "crates") main = <CratesView crates={crates} version={version} bump={bump} toast={toast} setView={setView} onNewCrate={() => setCrateDialog({ crate: null })} />;
  else if (view === "suggestions") main = <SuggestionsView version={version} bump={bump} toast={toast} />;
  else if (view === "discovery") main = <DiscoveryView crates={crates} version={version} bump={bump} toast={toast} />;
  else if (view === "set-studio") main = <SetStudioView crates={crates} version={version} toast={toast} bump={bump} initial={setParams} />;
  else if (view === "gig") main = <GigView toast={toast} onChange={() => { api.getSettings().then(setSettings); bump(); }} />;
  else if (view === "gig-pack") main = <GigPackView crates={crates} toast={toast} />;
  else if (view === "files") main = <FilesView toast={toast} />;
  else if (view === "settings") main = <SettingsView settings={settings} onChange={setSettings} info={info} toast={toast} bump={bump} />;
  else main = <div className="empty">This crate no longer exists.</div>;

  return (
    <div className="app-shell">
      <TitleBar toast={toast} gig={settings.gig_mode} premium={settings.premium_ui} onPremium={(v) => { setSettings({ ...settings, premium_ui: v }); api.setSetting("premium_ui", v).catch(() => {}); }} />
      <div className={`workspace${chat === "full" ? " chat-full" : chat === "hidden" ? " no-chat" : ""}`}>
        <Sidebar view={view} setView={setView} crates={crates} roots={roots} stats={stats} pending={pending} onNewCrate={() => setCrateDialog({ crate: null })} docsEnabled={settings.docs_enabled} />
        <main>{main}</main>
        {chat !== "hidden" && <ChatPanel mode={chat} setMode={setChatMode} onApply={(r) => { applyAssistant(r); }} onNavigate={navigate} onUi={onAiUi} onOpenSettings={() => setView("settings")} onChanged={refreshAfterChat} toast={toast} />}
      </div>
      <StatusBar scan={scan} jobs={jobs} version={info?.version ?? ""} onlineOn={onlineOn} chatHidden={chat === "hidden"} onShowChat={() => setChatMode("open")} onOpen={(v) => setView(v as View)} />
      {crateDialog && (
        <CrateDialog
          initial={crateDialog.crate}
          initialRules={crateDialog.rules}
          fields={fields}
          crates={crates}
          onClose={() => setCrateDialog(null)}
          onSaved={(c) => { setCrateDialog(null); bump(); setView(`crate:${c.id}`); toast(`Crate “${c.name}” saved.`); }}
          onDeleted={() => { setCrateDialog(null); setView("library"); bump(); toast("Crate deleted. Tracks and files were not affected."); }}
        />
      )}
      {update && (
        <div className="update-banner glass beam" role="status">
          <div className="row" style={{ alignItems: "flex-start" }}>
            <Icon name="download" />
            <div style={{ flex: 1 }}>
              <strong>DJ Assistant {update.info.version} is ready</strong>
              <div className="small muted">{update.installing ? `Downloading… ${update.pct ?? ""}${update.pct != null ? "%" : ""}` : "Installs in place and restarts. Your catalogue and settings are kept."}</div>
            </div>
            {!update.installing && <button className="btn ghost small icon" aria-label="Later" onClick={() => setUpdate(null)}><Icon name="close" size={14} /></button>}
          </div>
          {!update.installing && (
            <div className="row" style={{ marginTop: 10, justifyContent: "flex-end" }}>
              <button className="btn small" onClick={() => setUpdate(null)}>Later</button>
              <button className="btn small primary" onClick={() => { setUpdate({ ...update, installing: true }); update.info.install((pct) => setUpdate((u) => (u ? { ...u, pct } : u))).catch((e) => { toast(`Update failed: ${e}`, true); setUpdate(null); }); }}>Install &amp; restart</button>
            </div>
          )}
        </div>
      )}
      {!settings.privacy_acknowledged && (
        <Dialog narrow title="Before you start" onClose={() => {}} footer={<button className="btn primary" onClick={() => api.setSetting("privacy_acknowledged", true).then(() => setSettings({ ...settings, privacy_acknowledged: true }))}>I understand</button>}>
          <p>DJ Assistant is built to protect your music library:</p>
          <ul style={{ margin: 0, paddingLeft: 18, display: "flex", flexDirection: "column", gap: 6 }}>{SAFETY_POINTS.map((p) => <li key={p}>{p}</li>)}</ul>
          <p className="muted small">You can read this again any time in Settings.</p>
        </Dialog>
      )}
      {toastMsg && <div key={toastMsg.k} className={`toast${toastMsg.err ? " error" : ""}`} role={toastMsg.err ? "alert" : "status"}>{toastMsg.err ? <Icon name="warn" size={16} /> : <Icon name="check" size={16} />}{toastMsg.m}</div>}
    </div>
  );
}
