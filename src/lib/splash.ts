// Opening splash (painted by index.html) and the closing animation.
import { isDesktop } from "../api";

const shownAt = performance.now();
let hidden = false;

/** Fade the splash away once the app has something to show (at least ~0.9 s of animation). */
export function hideSplash() {
  if (hidden) return;
  hidden = true;
  const el = document.getElementById("splash");
  if (!el) return;
  const wait = Math.max(0, 900 - (performance.now() - shownAt));
  window.setTimeout(() => {
    el.classList.add("out");
    window.setTimeout(() => el.remove(), 480);
  }, wait);
}

// Never leave the splash up if something goes wrong while starting.
window.setTimeout(hideSplash, 8000);

let closing = false;

/** Play the closing animation, then close the window. */
export async function closeWithAnimation() {
  if (closing) return;
  closing = true;
  const reduce = document.documentElement.dataset.motion === "reduced" || window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  document.documentElement.classList.add("app-closing");
  if (!reduce) await new Promise((r) => window.setTimeout(r, 460));
  if (!isDesktop()) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow().destroy();
}

/** Alt+F4, the taskbar's Close and the tray's Quit go through the same animation. */
export async function interceptCloseRequests() {
  if (!isDesktop()) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  await getCurrentWindow().onCloseRequested((e) => {
    e.preventDefault();
    void closeWithAnimation();
  });
}
