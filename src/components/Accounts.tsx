import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { hideSplash } from "../lib/splash";
import { api } from "../api";
import type { Account, AccountList } from "../types";
import { Dialog } from "./ui";
import { Icon, Logo } from "./Icon";

/**
 * Local accounts: no sign-in, no passwords. Each account has its own
 * catalogue (folders, crates, sets, settings). Switching remounts the app
 * so every view reloads from the new catalogue.
 */
interface Ctx {
  list: AccountList;
  current: Account;
  switchTo: (id: string) => Promise<void>;
  refresh: () => Promise<void>;
}
const AccountCtx = createContext<Ctx | null>(null);
export const useAccount = () => useContext(AccountCtx);

const initials = (name: string) => name.split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]!.toUpperCase()).join("") || "?";

export function Avatar({ a, size = 26 }: { a: Account; size?: number }) {
  return (
    <span className="avatar" style={{ width: size, height: size, background: a.color, fontSize: size * 0.42 }} aria-hidden>
      {initials(a.name)}
    </span>
  );
}

export function AccountGate({ children }: { children: (key: string) => ReactNode }) {
  const [list, setList] = useState<AccountList | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => api.accounts().then(setList).catch((e) => setError(String(e.message ?? e))), []);
  useEffect(() => {
    load();
  }, [load]);
  const switchTo = useCallback(async (id: string) => setList(await api.accountSwitch(id)), []);

  if (error) { hideSplash(); return <div className="empty" style={{ height: "100%", justifyContent: "center" }}><h2>DJ Assistant could not start</h2><p>{error}</p></div>; }
  if (!list) return <div className="empty" style={{ height: "100%", justifyContent: "center" }}><div className="spin"><Icon name="disc" size={32} /></div></div>;
  const current = list.accounts.find((a) => a.id === list.current);
  if (!current) { hideSplash(); return <Welcome list={list} onDone={setList} />; }
  return <AccountCtx.Provider value={{ list, current, switchTo, refresh: load }}>{children(current.id)}</AccountCtx.Provider>;
}

/** First run, or picking an account when none is open. */
function Welcome({ list, onDone }: { list: AccountList; onDone: (l: AccountList) => void }) {
  const [name, setName] = useState("");
  const [err, setErr] = useState("");
  const create = (e: React.FormEvent) => {
    e.preventDefault();
    api.accountCreate(name).then(onDone).catch((x) => setErr(x.message));
  };
  return (
    <div className="welcome">
      <div className="panel welcome-card">
        <div className="row" style={{ gap: 10, color: "var(--mint)" }}><Logo size={28} /><strong style={{ fontSize: 18, color: "var(--text)" }}>DJ Assistant</strong></div>
        <h1 style={{ margin: "18px 0 6px" }}>{list.accounts.length ? "Who's using DJ Assistant?" : "Welcome"}</h1>
        <p className="muted" style={{ marginTop: 0 }}>No sign-in needed. Your account lives only on this computer and keeps its own library folders, crates, sets and settings. Add more accounts any time — for a second DJ, or a separate library.</p>
        {list.accounts.length > 0 && (
          <div className="col" style={{ margin: "14px 0" }}>
            {list.accounts.map((a) => (
              <button key={a.id} className="btn account-pick" onClick={() => api.accountSwitch(a.id).then(onDone).catch((x) => setErr(x.message))}>
                <Avatar a={a} /> {a.name}
              </button>
            ))}
          </div>
        )}
        <form className="col" onSubmit={create} style={{ marginTop: 14 }}>
          <label className="field">
            {list.accounts.length ? "Or create a new account" : "What should we call you?"}
            <input className="input" autoFocus value={name} onChange={(e) => setName(e.target.value)} placeholder="Your DJ name" maxLength={40} aria-label="Account name" />
          </label>
          {err && <p className="s-error small" role="alert" style={{ margin: 0 }}>{err}</p>}
          <button className="btn primary big" disabled={!name.trim()}>Create account <Icon name="right" size={16} /></button>
        </form>
      </div>
    </div>
  );
}

/** The account chip in the title bar: switch, add, rename or remove accounts. */
export function AccountMenu({ toast }: { toast?: (m: string, err?: boolean) => void }) {
  const ctx = useAccount();
  const [open, setOpen] = useState(false);
  const [manage, setManage] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (e: MouseEvent) => !ref.current?.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", esc);
    return () => { window.removeEventListener("mousedown", close); window.removeEventListener("keydown", esc); };
  }, [open]);
  if (!ctx) return null;
  const pick = (id: string) => {
    setOpen(false);
    ctx.switchTo(id).catch((e) => toast?.(e.message, true));
  };
  return (
    <div className="account-menu" ref={ref}>
      <button className="account-chip" aria-haspopup="menu" aria-expanded={open} onClick={() => setOpen(!open)} title="Accounts on this computer">
        <Avatar a={ctx.current} size={22} />
        <span>{ctx.current.name}</span>
        <Icon name="down" size={14} />
      </button>
      {open && (
        <div className="menu glass" role="menu" aria-label="Accounts">
          <div className="small faint" style={{ padding: "6px 10px" }}>Accounts on this computer</div>
          {ctx.list.accounts.map((a) => (
            <button key={a.id} role="menuitemradio" aria-checked={a.id === ctx.current.id} className="menu-item" onClick={() => pick(a.id)}>
              <Avatar a={a} size={22} /> <span style={{ flex: 1 }}>{a.name}</span> {a.id === ctx.current.id && <Icon name="check" size={15} />}
            </button>
          ))}
          <div className="nav-sep" />
          <button role="menuitem" className="menu-item" onClick={() => { setOpen(false); setManage(true); }}><Icon name="user" size={16} /> Manage accounts…</button>
        </div>
      )}
      {manage && <ManageAccounts onClose={() => setManage(false)} toast={toast} />}
    </div>
  );
}

function ManageAccounts({ onClose, toast }: { onClose: () => void; toast?: (m: string, err?: boolean) => void }) {
  const ctx = useAccount()!;
  const [names, setNames] = useState<Record<string, string>>({});
  const [newName, setNewName] = useState("");
  const [confirm, setConfirm] = useState<Account | null>(null);
  const fail = (e: Error) => toast?.(e.message, true);
  return (
    <Dialog title="Accounts on this computer" onClose={onClose}>
      <p className="small muted" style={{ marginTop: 0 }}>No sign-in and no passwords. Each account keeps its own library folders, crates, sets, analysis and settings in its own catalogue on this computer. Your music files are shared and never changed.</p>
      <div className="col" style={{ gap: 10 }}>
        {ctx.list.accounts.map((a) => (
          <form key={a.id} className="row" onSubmit={(e) => { e.preventDefault(); api.accountRename(a.id, names[a.id] ?? a.name).then(() => { ctx.refresh(); toast?.("Account renamed."); }).catch(fail); }}>
            <Avatar a={a} />
            <input className="input" style={{ flex: 1 }} aria-label={`Name of ${a.name}`} value={names[a.id] ?? a.name} onChange={(e) => setNames({ ...names, [a.id]: e.target.value })} maxLength={40} />
            <button className="btn small" disabled={(names[a.id] ?? a.name).trim() === a.name}>Rename</button>
            {a.id !== ctx.current.id && <button type="button" className="btn small ghost" onClick={() => ctx.switchTo(a.id).then(onClose).catch(fail)}>Switch</button>}
            <button type="button" className="btn small ghost danger icon" aria-label={`Remove ${a.name}`} title="Remove account" disabled={ctx.list.accounts.length < 2} onClick={() => setConfirm(a)}><Icon name="trash" size={15} /></button>
          </form>
        ))}
      </div>
      <form className="row" style={{ marginTop: 16 }} onSubmit={(e) => { e.preventDefault(); api.accountCreate(newName).then((l) => { setNewName(""); onClose(); ctx.switchTo(l.current!); toast?.("Account created. It starts with an empty library — add your music folders."); }).catch(fail); }}>
        <input className="input" style={{ flex: 1 }} placeholder="New account name" aria-label="New account name" value={newName} onChange={(e) => setNewName(e.target.value)} maxLength={40} />
        <button className="btn primary" disabled={!newName.trim()}><Icon name="plus" size={16} /> Add account</button>
      </form>
      {confirm && (
        <Dialog narrow title={`Remove “${confirm.name}”?`} onClose={() => setConfirm(null)} footer={<>
          <button className="btn" onClick={() => setConfirm(null)}>Keep it</button>
          <button className="btn danger solid" onClick={() => api.accountDelete(confirm.id).then((r) => { setConfirm(null); onClose(); ctx.refresh(); toast?.(r.kept_backups ? `Account removed. Tag-write backups were kept in ${r.kept_backups}.` : "Account removed. Your music files were not touched."); }).catch(fail)}>Remove account</button>
        </>}>
          <p>This deletes the account's catalogue on this computer: its folder list, crates, sets, ratings, edits and settings. <strong>Your music files are not touched.</strong></p>
        </Dialog>
      )}
    </Dialog>
  );
}
