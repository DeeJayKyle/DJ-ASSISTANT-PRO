// End-to-end test: real React UI + real dj-core backend (via the dev-only
// loopback bridge) + real audio fixture files. Run: npm run e2e
import { spawn, execSync } from "node:child_process";
import { cpSync, mkdirSync, rmSync, readdirSync, statSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const data = path.join(root, "e2e/.data");
const music = path.join(data, "Herbie Music");
const shots = process.env.E2E_SCREENSHOTS ?? path.join(root, "e2e/.data/screenshots");
rmSync(data, { recursive: true, force: true });
mkdirSync(shots, { recursive: true });
cpSync(path.join(root, "crates/dj-core/tests/fixtures/library"), music, { recursive: true });

const snapshot = (dir) => {
  const out = {};
  const walk = (d) => {
    for (const n of readdirSync(d)) {
      const p = path.join(d, n);
      const s = statSync(p);
      if (s.isDirectory()) walk(p);
      else out[p] = `${s.size}:${s.mtimeMs}:${createHash("sha256").update(readFileSync(p)).digest("hex")}`;
    }
  };
  walk(dir);
  return out;
};
const before = snapshot(music);

console.log("building dev bridge…");
execSync("cargo build -q -p dj-devbridge", { cwd: root, stdio: "inherit" });
const bridgeBin = path.join(root, "target/debug/dj-devbridge" + (process.platform === "win32" ? ".exe" : ""));
const procs = [];
const start = (cmd, args, env = {}) => {
  const p = spawn(cmd, args, { cwd: root, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
  p.stderr.on("data", (d) => process.env.E2E_VERBOSE && process.stderr.write(d));
  procs.push(p);
  return p;
};
const cleanup = () => procs.forEach((p) => p.kill());
process.on("exit", cleanup);

start(bridgeBin, ["--db", path.join(data, "app/catalogue.sqlite3"), "--port", "7878"]);
start("npx", ["vite", "--port", "5174", "--strictPort"], { VITE_DEV_BRIDGE: "1" });

const waitFor = async (url, ms = 30000) => {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    try {
      const r = await fetch(url, { method: url.includes("7878") ? "POST" : "GET", body: url.includes("7878") ? '{"cmd":"app_info"}' : undefined });
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`timeout waiting for ${url}`);
};
await waitFor("http://127.0.0.1:7878");
await waitFor("http://127.0.0.1:5174");

let failures = 0;
let page;
const step = async (name, fn) => {
  try {
    await fn();
    console.log(`  ✓ ${name}`);
  } catch (e) {
    failures++;
    await page.screenshot({ path: path.join(shots, `FAIL-${failures}.png`) }).catch(() => {});
    if (process.env.E2E_VERBOSE) console.log(String(e.message));
    console.log(`  ✗ ${name}\n    ${String(e.message ?? e).split("\n").slice(0, 6).join("\n    ")}`);
  }
};
const expect = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

const browser = await chromium.launch();
page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: Number(process.env.E2E_DPR ?? 1) });
page.on("framenavigated", (f) => f === page.mainFrame() && console.log("    [navigated]", f.url()));
const external = [];
page.on("request", (r) => {
  const u = new URL(r.url());
  if (!["127.0.0.1", "localhost"].includes(u.hostname)) external.push(r.url());
});
const consoleErrors = [];
let restarting = false;
page.on("console", (m) => m.type() === "error" && !restarting && consoleErrors.push(m.text()));
page.on("pageerror", (e) => consoleErrors.push(String(e)));

console.log("running e2e steps…");
await page.goto("http://127.0.0.1:5174");

await step("first run shows the safety notice and it can be acknowledged", async () => {
  await page.getByRole("dialog", { name: "Before you start" }).waitFor();
  await page.screenshot({ path: path.join(shots, "01-first-run.png") });
  await page.getByRole("button", { name: "I understand" }).click();
  await page.getByRole("dialog").waitFor({ state: "detached" });
});

await step("welcome screen leads to folders; folder is added and scanned", async () => {
  await page.getByRole("button", { name: "Add music folders" }).click();
  await page.getByLabel("Folder path").fill(music);
  await page.getByRole("button", { name: "Add folder" }).click();
  await page.getByText(/Last scan completed/).waitFor({ timeout: 20000 });
  await page.getByText("22 music files found").waitFor();
  await page.screenshot({ path: path.join(shots, "02-folders.png") });
});

await step("library lists real tracks; unknown values show as —", async () => {
  await page.getByRole("button", { name: /^Library( [\d,]+)?$/ }).click();
  await page.getByText("22 tracks", { exact: true }).waitFor();
  await page.getByRole("row", { name: /Sunrise Groove \(feat\. Ada\)/ }).first().waitFor();
  await page.screenshot({ path: path.join(shots, "03-library.png") });
});

await step("search is accent-insensitive", async () => {
  await page.getByLabel("Search tracks").fill("beyonce");
  await page.getByText("1 track", { exact: true }).waitFor();
  await page.getByText("Déjà Vu Medley").waitFor();
  await page.getByLabel("Search tracks").fill("");
  await page.getByText("22 tracks", { exact: true }).waitFor();
});

await step("SQL-looking search text is treated as text", async () => {
  await page.getByLabel("Search tracks").fill("'; DROP TABLE tracks; --");
  await page.getByText("0 tracks", { exact: true }).waitFor();
  await page.getByLabel("Search tracks").fill("");
  await page.getByText("22 tracks", { exact: true }).waitFor();
});

await step("preset filter: low bitrate shows only lossy files under threshold", async () => {
  await page.getByRole("button", { name: "Low bitrate", exact: true }).click();
  await page.getByText("4 tracks", { exact: true }).waitFor();
  const badges = await page.locator(".tbody .badge").allTextContents();
  expect(badges.length === 4 && badges.every((b) => b === "Low bitrate"), `badges: ${badges}`);
  await page.getByRole("button", { name: "Clear filters" }).click();
});

await step("track detail separates file tags from catalogue values; energy edit persists", async () => {
  await page.getByLabel("Search tracks").fill("warehouse");
  await page.getByText("1 track", { exact: true }).waitFor();
  await page.getByRole("row", { name: /Warehouse 94/ }).click();
  const detail = page.getByRole("complementary", { name: "Track details" });
  await detail.getByText("From the file (read-only)").waitFor();
  await detail.getByRole("slider", { name: /Energy/ }).locator("i").nth(6).click();
  await detail.getByText("7/10").waitFor();
  await page.screenshot({ path: path.join(shots, "04-track-detail.png") });
  await detail.getByRole("button", { name: "Close details" }).click();
  await page.getByLabel("Search tracks").fill("");
});

await step("smart crate with preview: Afrobeats 2010–2019 excluding live", async () => {
  await page.getByRole("button", { name: "New crate" }).click();
  const dlg = page.getByRole("dialog", { name: "New crate" });
  await dlg.getByPlaceholder("e.g. Afrobeats 2010s peak time").fill("Afro 2010s (no live)");
  await dlg.getByText("Smart — rules pick tracks").click();
  await dlg.getByRole("button", { name: "Add rule" }).click();
  await dlg.getByLabel("Include rule 1 field").selectOption("genre");
  await dlg.getByLabel("Include rule 1 operator").selectOption("equals");
  await dlg.getByLabel("Include rule 1 value").fill("Afrobeats");
  await dlg.getByRole("button", { name: "Add rule" }).click();
  await dlg.getByLabel("Include rule 2 field").selectOption("year");
  await dlg.getByLabel("Include rule 2 minimum").fill("2010");
  await dlg.getByLabel("Include rule 2 maximum").fill("2019");
  await dlg.getByRole("button", { name: "Add exclusion" }).click();
  await dlg.getByLabel("Exclude rule 1 field").selectOption("version");
  await dlg.getByLabel("Exclude rule 1 value").fill("live");
  await dlg.getByText("5 tracks match right now").waitFor();
  await page.screenshot({ path: path.join(shots, "05-smart-crate.png") });
  await dlg.getByRole("button", { name: "Create crate" }).click();
  await page.getByRole("heading", { name: "Afro 2010s (no live)" }).waitFor();
  await page.getByText("5 tracks", { exact: true }).waitFor();
});

await step("manual crate: add selected tracks; same track in multiple crates", async () => {
  for (const name of ["Warm-up", "Wedding"]) {
    await page.getByRole("button", { name: "New crate" }).click();
    const dlg = page.getByRole("dialog", { name: "New crate" });
    await dlg.getByPlaceholder("e.g. Afrobeats 2010s peak time").fill(name);
    await dlg.getByRole("button", { name: "Create crate" }).click();
    await page.getByRole("heading", { name }).waitFor();
  }
  await page.getByRole("button", { name: /^Library( [\d,]+)?$/ }).click();
  await page.getByLabel("Search tracks").fill("low tide");
  await page.getByText("1 track", { exact: true }).waitFor();
  for (const name of ["Warm-up", "Wedding"]) {
    await page.getByLabel("Select Low Tide").check();
    await page.getByRole("button", { name: "Add to crate" }).click();
    await page.getByRole("menuitem", { name }).click();
    await page.getByText(`to “${name}”`).waitFor();
  }
  await page.getByLabel("Search tracks").fill("");
  await page.getByRole("button", { name: /^Warm-up/ }).click();
  await page.getByText("1 track", { exact: true }).waitFor();
});

await step("duplicate review separates exact, possible and alternate", async () => {
  await page.getByRole("button", { name: "Duplicates", exact: true }).click();
  await page.getByRole("tab", { name: "Exact duplicates (0)" }).waitFor();
  await page.getByRole("button", { name: "Check for exact duplicates" }).click();
  await page.getByRole("tab", { name: "Exact duplicates (1)" }).waitFor({ timeout: 15000 });
  await page.getByText(/Identical file contents/).waitFor();
  await page.screenshot({ path: path.join(shots, "06-duplicates-exact.png") });
  await page.getByRole("tab", { name: "Possible duplicates (1)" }).click();
  await page.getByText(/not proven identical/).waitFor();
  await page.getByRole("tab", { name: "Alternate versions (1)" }).click();
  await page.getByRole("button", { name: "Intentional version" }).click();
  await page.getByRole("button", { name: "Intentional version", pressed: true }).waitFor();
});

await step("library health reports errors, unsupported files and low bitrate", async () => {
  await page.getByRole("button", { name: /^Library health/ }).click();
  await page.getByRole("button", { name: /Unreadable or corrupt: 3/ }).waitFor();
  await page.getByRole("button", { name: /Unsupported formats: 1/ }).waitFor();
  await page.getByRole("button", { name: /Low bitrate .*: 4/ }).waitFor();
  await page.screenshot({ path: path.join(shots, "07-health.png") });
  await page.getByRole("button", { name: /Unreadable or corrupt: 3/ }).click();
  await page.getByText("3 tracks", { exact: true }).waitFor();
});

await step("assistant (rule-based) applies filters to the library", async () => {
  await page.getByLabel("Message the assistant").fill("afrobeats 2010s no live");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByText(/Found 5 tracks/).waitFor();
  await page.getByRole("button", { name: "Show all 5 in library" }).click();
  await page.getByText("5 tracks", { exact: true }).waitFor();
  await page.screenshot({ path: path.join(shots, "08-assistant.png") });
});

await step("assistant can go full screen and be hidden, core UI still works", async () => {
  await page.getByRole("button", { name: "Expand assistant to full screen" }).click();
  await page.getByRole("button", { name: "Exit full screen" }).waitFor();
  await page.getByRole("button", { name: "Exit full screen" }).click();
  await page.getByRole("button", { name: "Hide assistant" }).click();
  await page.getByRole("button", { name: "Show assistant" }).waitFor();
  await page.getByRole("button", { name: /^Library( [\d,]+)?$/ }).click();
  await page.getByRole("button", { name: "Show assistant" }).click();
});

await step("keyboard: '/' focuses search", async () => {
  await page.locator("body").click({ position: { x: 700, y: 870 } });
  await page.keyboard.press("/");
  await page.waitForFunction(() => document.activeElement?.getAttribute("aria-label") === "Search tracks", null, { timeout: 3000 });
});

await step("settings: threshold validation and light theme", async () => {
  await page.getByRole("button", { name: "Settings" }).click();
  await page.getByLabel("Low bitrate threshold in kbps").fill("100");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await page.getByRole("status").filter({ hasText: "Saved." }).waitFor();
  await page.getByRole("button", { name: "Light" }).click();
  await page.screenshot({ path: path.join(shots, "09-settings-light.png") });
  await page.getByRole("button", { name: "Dark (booth)" }).click();
});

await step("data and crates persist after restarting the backend", async () => {
  // restart bridge (fresh process, same catalogue)
  restarting = true;
  procs[0].kill();
  await new Promise((r) => setTimeout(r, 500));
  procs[0] = start(bridgeBin, ["--db", path.join(data, "app/catalogue.sqlite3"), "--port", "7878"]);
  await waitFor("http://127.0.0.1:7878");
  await page.reload();
  restarting = false;
  await page.getByRole("button", { name: /^Afro 2010s \(no live\)/ }).waitFor();
  await page.getByRole("button", { name: /^Wedding/ }).click();
  await page.getByText("1 track", { exact: true }).waitFor();
  await page.getByRole("button", { name: /^Library( [\d,]+)?$/ }).click();
  await page.getByLabel("Search tracks").fill("warehouse");
  await page.getByRole("row", { name: /Warehouse 94/ }).getByRole("img", { name: "Energy 7 of 10" }).waitFor();
});

await step("no external network requests were made by the UI", async () => {
  expect(external.length === 0, `external requests: ${external.join(", ")}`);
});
await step("no console errors", async () => {
  expect(consoleErrors.length === 0, consoleErrors.join("\n"));
});

await browser.close();
const after = snapshot(music);
await step("source files unchanged after the whole session (size, mtime, SHA-256)", async () => {
  expect(JSON.stringify(before) === JSON.stringify(after), "fixture files changed!");
});
cleanup();
console.log(failures ? `\n${failures} e2e step(s) FAILED` : "\nall e2e steps passed");
process.exit(failures ? 1 : 0);
