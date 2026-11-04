import type { JobState, ScanProgress } from "../types";
import { Icon } from "./Icon";

export function StatusBar({ scan, jobs, version, onlineOn, chatHidden, onShowChat, onOpen }: {
  scan: ScanProgress | null; jobs: JobState[]; version: string; onlineOn: string[]; chatHidden: boolean; onShowChat: () => void; onOpen: (v: string) => void;
}) {
  const running = scan && (scan.state === "running" || scan.state === "paused");
  const pct = scan && scan.files_to_read ? (100 * scan.files_processed) / scan.files_to_read : 0;
  const active = jobs.filter((j) => j.state === "running" || j.state === "paused");
  return (
    <footer className="statusbar">
      <span>
        <span className="status-dot online" /> Local catalogue
      </span>
      <span title="Music files are only read. The optional tag writer needs your approval for every change.">
        <Icon name="lock" size={14} /> Source files read-only
      </span>
      <span title={onlineOn.length ? `On: ${onlineOn.join(", ")}` : "No online services are turned on"}>
        <span className={`status-dot ${onlineOn.length ? "online" : "off"}`} /> {onlineOn.length ? `Online: ${onlineOn.join(", ")}` : "Online services off"}
      </span>
      {running && (
        <span>
          <button onClick={() => onOpen("activity")}>
            {scan!.state === "paused" ? "Scan paused" : "Scanning"} {scan!.files_processed + scan!.unchanged}/{scan!.files_found}
          </button>
          <span className={`progress${scan!.phase === "discovering" ? " indeterminate" : ""}`}>
            <div style={{ width: `${pct}%` }} />
          </span>
        </span>
      )}
      {active.map((j) => (
        <span key={j.kind}>
          <button onClick={() => onOpen(j.kind === "gigpack" ? "gig-pack" : j.kind === "docs" ? "files" : j.kind === "analysis" ? "activity" : "suggestions")}>
            {j.state === "paused" ? <Icon name="pause" size={12} /> : <Icon name="refresh" size={12} />} {j.kind} {j.done}/{j.total}
          </button>
        </span>
      ))}
      <span className="spacer" style={{ border: 0 }} />
      {chatHidden && (
        <span style={{ border: 0 }}>
          <button onClick={onShowChat} aria-label="Show assistant">
            <Icon name="sparkles" size={13} /> Assistant
          </button>
        </span>
      )}
      <span style={{ border: 0 }} className="faint">v{version}</span>
    </footer>
  );
}
