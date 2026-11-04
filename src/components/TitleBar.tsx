import { useEffect, useState } from "react";
import { isDesktop } from "../api";
import { Icon, Logo } from "./Icon";

/** Custom window title bar (the window has no native decorations). */
export function TitleBar({ gig }: { gig: boolean }) {
  const [max, setMax] = useState(false);
  const win = async () => (await import("@tauri-apps/api/window")).getCurrentWindow();
  useEffect(() => {
    if (!isDesktop()) return;
    win().then((w) => w.isMaximized().then(setMax));
  }, []);
  return (
    <header className="titlebar" data-tauri-drag-region>
      <div className="brand" data-tauri-drag-region>
        <Logo />
        <span data-tauri-drag-region>
          DJ Assistant <span className="dot">·</span> Herbie
        </span>
      </div>
      <div className="drag" data-tauri-drag-region onDoubleClick={() => isDesktop() && win().then((w) => w.toggleMaximize().then(() => w.isMaximized().then(setMax)))} />
      {gig && (
        <span className="badge kind-possible gig-flag" title="Gig mode is on: background work is paused">
          <Icon name="gig" size={13} /> Gig mode
        </span>
      )}
      {isDesktop() && (
        <>
          <button className="winbtn" aria-label="Minimise" onClick={() => win().then((w) => w.minimize())}>
            <Icon name="minus" size={16} />
          </button>
          <button className="winbtn" aria-label={max ? "Restore" : "Maximise"} onClick={() => win().then((w) => w.toggleMaximize().then(() => w.isMaximized().then(setMax)))}>
            <Icon name="square" size={13} />
          </button>
          <button className="winbtn close" aria-label="Close" onClick={() => win().then((w) => w.close())}>
            <Icon name="close" size={17} />
          </button>
        </>
      )}
    </header>
  );
}
