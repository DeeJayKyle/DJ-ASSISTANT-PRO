import type { ScanProgress } from "../types";
import { Icon } from "./Icon";

export function StatusBar({ scan, version, chatHidden, onShowChat, onOpenFolders }: { scan: ScanProgress | null; version: string; chatHidden: boolean; onShowChat: () => void; onOpenFolders: () => void }) {
  const running = scan && (scan.state === "running" || scan.state === "paused");
  const pct = scan && scan.files_to_read ? (100 * scan.files_processed) / scan.files_to_read : 0;
  return (
    <footer className="statusbar">
      <span className="lock" title="DJ Assistant never edits, renames, moves or deletes your music files, and never writes to Serato.">
        <Icon name="lock" size={14} /> Read-only: your music files are never changed
      </span>
      <span className="scan" aria-live="polite">
        {running && (
          <button onClick={onOpenFolders}>
            {scan!.state === "paused" ? "Scan paused" : "Scanning"} {scan!.files_processed + scan!.unchanged}/{scan!.files_found}
          </button>
        )}
        {running && (
          <span className={`progress${scan!.phase === "discovering" ? " indeterminate" : ""}`}>
            <div style={{ width: `${pct}%` }} />
          </span>
        )}
      </span>
      <span className="spacer" />
      <span title="No online services are enabled in this version.">Offline: no data leaves this computer</span>
      {chatHidden && (
        <button onClick={onShowChat} aria-label="Show assistant">
          <Icon name="chat" size={13} /> Assistant
        </button>
      )}
      <span className="faint">v{version}</span>
    </footer>
  );
}
