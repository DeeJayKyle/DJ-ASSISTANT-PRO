const P: Record<string, string> = {
  lock: "M7 11V8a5 5 0 0 1 10 0v3M6 11h12v10H6z",
  search: "M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14zM20 20l-4-4",
  library: "M4 5h4v14H4zM10 5h4v14h-4zM16 6l3.5-1 3 13-3.5 1z",
  health: "M3 12h4l2-5 4 10 2-5h6",
  dup: "M8 8h11v11H8zM5 16V5h11",
  folder: "M3 6h6l2 2h10v11H3z",
  settings: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM19 12l2-1-1-3-2 .2-1.5-1.5L16.7 4l-3-1-1 2h-1.4l-1-2-3 1 .2 2.7L6 8.2 4 8 3 11l2 1v1.4l-2 1 1 3 2-.2 1.5 1.5L7.3 20l3 1 1-2h1.4l1 2 3-1-.2-2.7 1.5-1.5 2 .2 1-3-2-1z",
  plus: "M12 5v14M5 12h14",
  close: "M6 6l12 12M18 6L6 18",
  expand: "M4 10V4h6M20 14v6h-6M4 4l7 7M20 20l-7-7",
  collapse: "M10 4v6H4M14 20v-6h6M10 10L3 3M14 14l7 7",
  chat: "M4 5h16v11H9l-5 4z",
  hide: "M15 6l-6 6 6 6",
  info: "M12 8h.01M11 12h1v5h1M12 21a9 9 0 1 1 0-18 9 9 0 0 1 0 18z",
  map: "M9 4L3 6v14l6-2 6 2 6-2V4l-6 2zM9 4v14M15 6v14",
  sortUp: "M7 14l5-5 5 5",
  sortDown: "M7 10l5 5 5-5",
  crate: "M3 8h18v12H3zM3 8l2-4h14l2 4M9 13h6",
  smart: "M4 6h16M7 12h10M10 18h4",
  play: "M8 5v14l11-7z",
  pause: "M7 5h3v14H7zM14 5h3v14h-3z",
  stop: "M6 6h12v12H6z",
  refresh: "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7",
  trash: "M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3",
  check: "M5 12l5 5 9-10",
  edit: "M4 20h4L19 9l-4-4L4 16zM14 6l4 4",
};

export function Icon({ name, size = 16, title }: { name: keyof typeof P | string; size?: number; title?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" aria-hidden={title ? undefined : true} role={title ? "img" : undefined}>
      {title && <title>{title}</title>}
      <path d={P[name] ?? P.info} />
    </svg>
  );
}

export function Logo({ size = 30 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 1024 1024" aria-hidden>
      <rect x="48" y="48" width="928" height="928" rx="208" fill="#16203A" />
      <circle cx="512" cy="430" r="300" fill="#0B1020" />
      <circle cx="512" cy="430" r="96" fill="#F5A524" />
      <rect x="190" y="560" width="644" height="300" rx="36" fill="#F5A524" />
      <rect x="300" y="640" width="424" height="56" rx="28" fill="#16203A" />
    </svg>
  );
}
