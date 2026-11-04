import * as L from "lucide-react";

const MAP: Record<string, L.LucideIcon> = {
  lock: L.Lock, search: L.Search, library: L.Music, health: L.HeartPulse, dup: L.Copy, folder: L.FolderOpen, settings: L.Settings,
  plus: L.Plus, close: L.X, expand: L.Maximize2, collapse: L.Minimize2, chat: L.MessageSquare, info: L.Info, crate: L.Folder,
  smart: L.SlidersHorizontal, play: L.Play, pause: L.Pause, stop: L.CircleStop, refresh: L.RefreshCw, trash: L.Trash2, check: L.Check,
  edit: L.Pencil, sortUp: L.ArrowUp, sortDown: L.ArrowDown, warn: L.TriangleAlert, music: L.Music, drive: L.HardDrive,
  down: L.ChevronDown, right: L.ChevronRight, sparkles: L.Sparkles, user: L.User, send: L.Send, filter: L.Filter, activity: L.Activity,
  wand: L.Wand2, compass: L.Compass, set: L.ListMusic, gig: L.Radio, usb: L.Usb, file: L.FileText, star: L.Star, external: L.ExternalLink,
  undo: L.Undo2, shield: L.ShieldCheck, disc: L.Disc3, gauge: L.Gauge, zap: L.Zap, layers: L.Layers, eye: L.Eye, up: L.ThumbsUp,
  thumbdown: L.ThumbsDown, clock: L.Clock, template: L.LayoutTemplate, palette: L.Palette, key: L.KeyRound, cloudoff: L.CloudOff,
  cloud: L.Cloud, download: L.Download, export: L.FileOutput, party: L.PartyPopper, wave: L.AudioWaveform, minus: L.Minus, square: L.Square,
  grip: L.GripVertical, arrowUp: L.ArrowUp, arrowDown: L.ArrowDown, shuffle: L.Shuffle, headphones: L.Headphones, calendar: L.CalendarDays,
};

export function Icon({ name, size = 18, title, strokeWidth = 1.9 }: { name: string; size?: number; title?: string; strokeWidth?: number }) {
  const C = MAP[name] ?? L.Circle;
  return <C size={size} strokeWidth={strokeWidth} aria-hidden={title ? undefined : true} aria-label={title} role={title ? "img" : undefined} />;
}

export function Logo({ size = 22 }: { size?: number }) {
  return <L.AudioWaveform size={size} strokeWidth={2.2} aria-hidden />;
}
