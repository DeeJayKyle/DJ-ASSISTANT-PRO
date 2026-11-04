// End-to-end test: real React UI + real dj-core backend (via the dev-only
// loopback bridge) + real audio fixture files. Run: npm run e2e
import { spawn, execSync } from "node:child_process";
import { cpSync, mkdirSync, rmSync, readdirSync, statSync, readFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const data = path.join(root, "e2e/.data");
const music = path.join(data, "Herbie Music");
const usb = path.join(data, "USB");
const shots = process.env.E2E_SCREENSHOTS ?? path.join(data, "screenshots");
rmSync(data, { recursive: true, force: true });
mkdirSync(shots, { recursive: true });
mkdirSync(usb, { recursive: true });
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
const waitFor = async (url, ms = 40000) => {
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
    console.log(`  ✗ ${name}\n    ${String(e.message ?? e).split("\n").slice(0, 6).join("\n    ")}`);
  }
};
const expect = (cond, msg) => { if (!cond) throw new Error(msg); };
const nav = (label) => page.getByRole("navigation", { name: "Main" }).getByRole("button", { name: new RegExp(`^${label}( [\\d,]+)?$`) }).first();
const count = (n) => page.getByText(new RegExp(`^${n} tracks?$`)).first();

const browser = await chromium.launch();
page = await browser.newPage({ viewport: { width: 1600, height: 960 }, deviceScaleFactor: Number(process.env.E2E_DPR ?? 1) });
const external = [];
page.on("request", (r) => { const u = new URL(r.url()); if (!["127.0.0.1", "localhost"].includes(u.hostname)) external.push(r.url()); });
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

await step("welcome screen leads to Scan Activity; folder is added and scanned read-only", async () => {
  await page.getByRole("button", { name: "Add music folders" }).click();
  await page.getByLabel("Folder path").fill(music);
  await page.getByRole("button", { name: "Add folder", exact: true }).click();
  await page.getByText(/Last scan completed/).waitFor({ timeout: 30000 });
  await page.getByText("22 music files found").waitFor();
});

await step("library matches the mock-up layout and lists real tracks", async () => {
  await nav("Library").click();
  await page.getByRole("heading", { name: "Music Library" }).waitFor();
  await count(22).waitFor();
  for (const b of ["Genre", "Decade", "Format", "Quality"]) await page.locator(".dropdown-btn", { hasText: b }).first().waitFor();
  await page.getByRole("button", { name: "Add folder..." }).waitFor();
  await page.getByRole("button", { name: "Scan", exact: true }).waitFor();
  await page.getByText("Online services off").waitFor();
});

await step("search is accent-insensitive; SQL-like text is plain text", async () => {
  await page.getByLabel("Search tracks").fill("beyonce");
  await count(1).waitFor();
  await page.getByLabel("Search tracks").fill("'; DROP TABLE tracks; --");
  await count(0).waitFor();
  await page.getByLabel("Search tracks").fill("");
  await count(22).waitFor();
});

await step("Quality → Low bitrate shows only lossy files under the threshold", async () => {
  await page.locator(".dropdown-btn", { hasText: "Quality" }).click();
  await page.getByRole("menuitem", { name: /Low bitrate/ }).click();
  await count(4).waitFor();
  const chips = await page.locator(".tbody .badge.q-low_bitrate").count();
  expect(chips === 4, `low-bitrate chips: ${chips}`);
  await page.getByRole("button", { name: "Clear all" }).click();
  await count(22).waitFor();
});

await step("track card shows original tags and path; details drawer edits energy", async () => {
  await page.getByLabel("Search tracks").fill("warehouse");
  await count(1).waitFor();
  await page.getByRole("row", { name: /Warehouse 94/ }).click();
  await page.getByText("Original tags").waitFor();
  await page.getByText("File path").waitFor();
  await page.getByRole("button", { name: "Details & edit" }).click();
  const detail = page.getByRole("complementary", { name: "Track details" });
  await detail.getByText("From the file (read-only)").waitFor();
  await detail.getByRole("slider", { name: /Energy/ }).locator("i").nth(6).click();
  await detail.getByText("7/10").waitFor();
  await page.screenshot({ path: path.join(shots, "02-track-detail.png") });
  await detail.getByRole("button", { name: "Close details" }).click();
  await page.getByLabel("Search tracks").fill("");
});

await step("smart crate with live preview: Afrobeats 2010–2019 excluding live", async () => {
  await page.getByRole("button", { name: "New crate" }).first().click();
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
  await dlg.getByRole("button", { name: "Create crate" }).click();
  await page.getByRole("heading", { name: "Afro 2010s (no live)" }).waitFor();
  await count(5).waitFor();
});

await step("manual crates: checkbox selection, bulk add, same track in two crates", async () => {
  for (const name of ["Warm-up", "Wedding"]) {
    await page.getByRole("button", { name: "New crate" }).first().click();
    const dlg = page.getByRole("dialog", { name: "New crate" });
    await dlg.getByPlaceholder("e.g. Afrobeats 2010s peak time").fill(name);
    await dlg.getByRole("button", { name: "Create crate" }).click();
    await page.getByRole("heading", { name }).waitFor();
  }
  await nav("Library").click();
  await page.getByLabel("Search tracks").fill("low tide");
  await count(1).waitFor();
  for (const name of ["Warm-up", "Wedding"]) {
    await page.getByLabel("Select Low Tide").check();
    await page.getByRole("button", { name: "Add to crate" }).click();
    await page.getByRole("menuitem", { name }).click();
    await page.getByText(`to “${name}”`).waitFor();
  }
  await page.getByLabel("Search tracks").fill("");
});

await step("crate templates from the cheat sheet build nested smart crates", async () => {
  await nav("Virtual Crates").click();
  await page.getByText("Start from a template").waitFor();
  const card = page.locator(".template-card").filter({ hasText: "Sort by energy" });
  await card.getByRole("button", { name: "Add crates" }).click();
  await page.getByText(/Added 5 crates under “Energy”/).waitFor();
  await page.screenshot({ path: path.join(shots, "03-crates.png") });
});

await step("audio analysis runs in the background and reports completion", async () => {
  await nav("Scan Activity").click();
  await page.getByRole("button", { name: /^Analyse \d+ tracks$/ }).click();
  await page.getByText(/^Completed: \d+ of \d+/).waitFor({ timeout: 60000 });
});

await step("duplicate review separates exact, possible and alternate", async () => {
  await nav("Duplicate Review").click();
  await page.getByRole("button", { name: "Check for exact duplicates" }).click();
  await page.getByRole("tab", { name: "Exact duplicates (1)" }).waitFor({ timeout: 20000 });
  await page.getByText(/Identical file contents/).waitFor();
  await page.getByRole("tab", { name: "Possible duplicates (1)" }).click();
  await page.getByText(/not proven identical/).waitFor();
  await page.getByRole("tab", { name: "Alternate versions (1)" }).click();
  await page.getByRole("button", { name: "Intentional version" }).click();
  await page.getByRole("button", { name: "Intentional version", pressed: true }).waitFor();
});

await step("library health reports unreadable, unsupported and low-bitrate files", async () => {
  await nav("Library Health").click();
  await page.getByRole("button", { name: /Unreadable or corrupt: 3/ }).waitFor();
  await page.getByRole("button", { name: /Unsupported formats: 1/ }).waitFor();
  await page.getByRole("button", { name: /Low bitrate .*: 4/ }).waitFor();
});

await step("suggestions: local suggestions are reviewed before reaching the catalogue", async () => {
  await nav("Suggestions").click();
  await page.getByRole("button", { name: "Find local suggestions" }).click();
  const row = page.getByRole("row").filter({ hasText: "untagged recording" }).filter({ hasText: "title" }).first();
  await row.waitFor();
  await row.getByRole("button", { name: "Accept" }).click();
  await page.getByText(/Saved title to your catalogue/).waitFor();
  await page.screenshot({ path: path.join(shots, "04-suggestions.png") });
});

await step("Set Studio builds an editable running order with transition notes", async () => {
  await nav("Set Studio").click();
  await page.getByLabel("Skip tracks shorter than (seconds)").fill("0");
  await page.locator("label.field").filter({ hasText: "Length (minutes)" }).locator("input").fill("20");
  await page.getByRole("button", { name: "Generate running order" }).click();
  await page.locator(".slot").first().waitFor();
  const n = await page.locator(".slot").count();
  expect(n >= 4, `slots: ${n}`);
  await page.getByLabel("Set name").fill("E2E warm-up");
  await page.getByRole("button", { name: "Save set" }).click();
  await page.getByText("Set saved.").waitFor();
  await page.screenshot({ path: path.join(shots, "05-set-studio.png") });
});

await step("gig mode: start with the set, take a request, mark played, recap", async () => {
  await nav("Gig Mode").click();
  await page.getByLabel("Name").fill("E2E club night");
  await page.locator("label.field").filter({ hasText: "Set list" }).locator("select").selectOption({ label: "E2E warm-up" });
  await page.getByRole("button", { name: "Start gig mode" }).click();
  await page.getByText("Gig mode", { exact: true }).waitFor();
  await page.getByRole("button", { name: "Mark as played" }).click();
  await page.getByLabel("New request").fill("Something by Velvet Arcade");
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await page.getByText("Something by Velvet Arcade").waitFor();
  await page.screenshot({ path: path.join(shots, "06-gig-mode.png") });
  await page.getByRole("button", { name: "End gig" }).click();
  await page.getByText(/Recap — E2E club night/).waitFor();
});

await step("gig pack copies a crate to a 'USB' folder and verifies every file", async () => {
  await nav("Gig Pack").click();
  await page.locator("label.field").filter({ hasText: "What to pack" }).locator("select").selectOption({ label: "Wedding (1)" });
  await page.locator("label.field").filter({ hasText: "Destination" }).locator("input").fill(usb);
  await page.locator("label.field").filter({ hasText: "Pack folder name" }).locator("input").fill("Saturday pack");
  await page.getByRole("button", { name: "Preview pack" }).click();
  await page.getByRole("button", { name: /Copy and verify 1 file/ }).click();
  await page.getByText("Gig pack ready").waitFor({ timeout: 20000 });
  expect(existsSync(path.join(usb, "Saturday pack", "manifest.json")), "manifest missing");
  expect(existsSync(path.join(usb, "Saturday pack", "Music", "Low Tide.flac")), "copied file missing");
});

await step("assistant (rule-based) answers like the mock-up and applies filters", async () => {
  await nav("Library").click();
  await page.getByLabel("Message the assistant").fill("afrobeats 2010s no live");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByText("5 tracks match your filters.").waitFor();
  await page.screenshot({ path: path.join(shots, "07-assistant.png") });
  await page.getByRole("button", { name: "Apply filters" }).click();
  await count(5).waitFor();
});

await step("assistant opens Set Studio pre-filled from a request", async () => {
  await page.getByLabel("Message the assistant").fill("plan a 2 hour wedding set");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByRole("heading", { name: "Set Studio" }).waitFor();
  const v = await page.locator("label.field").filter({ hasText: "Length (minutes)" }).locator("input").inputValue();
  expect(v === "120", `length ${v}`);
});

await step("assistant can go full screen and be hidden; core UI still works", async () => {
  await page.getByRole("button", { name: "Assistant options" }).click();
  await page.getByRole("button", { name: "Full screen" }).click();
  await page.getByRole("button", { name: "Assistant options" }).click();
  await page.getByRole("button", { name: "Exit full screen" }).click();
  await page.getByRole("button", { name: "Assistant options" }).click();
  await page.getByRole("button", { name: /Hide assistant/ }).click();
  await page.getByRole("button", { name: "Show assistant" }).waitFor();
  await nav("Library").click();
  await page.getByRole("button", { name: "Show assistant" }).click();
});

await step("keyboard: '/' focuses search", async () => {
  await page.locator(".statusbar").click();
  await page.keyboard.press("/");
  await page.waitForFunction(() => document.activeElement?.getAttribute("aria-label") === "Search tracks", null, { timeout: 3000 });
});

await step("settings: updates, online services (off), threshold and light theme", async () => {
  await nav("Settings").click();
  await page.getByRole("heading", { name: "Updates" }).waitFor();
  await page.getByText("MusicBrainz", { exact: true }).waitFor();
  const on = await page.getByLabel("Turn MusicBrainz on").isChecked();
  expect(!on, "MusicBrainz must be off by default");
  await page.getByLabel("Low bitrate threshold in kbps").fill("100");
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await page.getByRole("button", { name: "Light" }).click();
  await page.screenshot({ path: path.join(shots, "08-settings-light.png") });
  await page.getByRole("button", { name: "Dark" }).click();
});

await step("library health: Fix fills a missing genre from a folder hint (catalogue only)", async () => {
  await nav("Library Health").click();
  await page.getByRole("button", { name: /^Fix missing genre/ }).click();
  await page.getByRole("heading", { name: "Fix: Missing genre" }).waitFor();
  const row = page.locator(".fix-row", { hasText: "Roller Rink" });
  await row.getByRole("button", { name: /^House/ }).click();
  expect((await row.getByLabel(/Genre for/).inputValue()) === "House", "hint did not fill the input");
  await row.getByRole("button", { name: "Save", exact: true }).click();
  await page.getByText(/Saved 1 track to your catalogue/).waitFor();
  await page.locator(".fix-row", { hasText: "Roller Rink" }).waitFor({ state: "detached" });
  await page.getByRole("button", { name: "Back to Library health" }).click();
});

await step("key notation: switching to musical names changes the table", async () => {
  await nav("Settings").click();
  await page.getByRole("button", { name: /^Musical/ }).click();
  await nav("Library").click();
  await page.getByRole("row").nth(2).waitFor();
  const keys = await page.getByRole("row").evaluateAll((rows) => rows.map((r) => r.textContent ?? ""));
  expect(keys.length > 0, "no rows");
  expect(!keys.some((k) => /(^|[^\w])(1[0-2]|[1-9])[AB]([^\w]|$)/.test(k)), `Camelot codes still shown: ${keys.find((k) => /(1[0-2]|[1-9])[AB]/.test(k))}`);
  await nav("Settings").click();
  await page.getByRole("button", { name: /^Camelot/ }).click();
});

await step("premium UI switch repaints with the Midnight Pro palette and back", async () => {
  const sw = page.getByRole("switch", { name: /Premium UI/ });
  await sw.click();
  expect((await page.evaluate(() => document.documentElement.dataset.palette)) === "midnight-pro", "palette not applied");
  await page.screenshot({ path: path.join(shots, "09-premium-ui.png") });
  await sw.click();
  expect((await page.evaluate(() => document.documentElement.dataset.palette)) === undefined, "palette not removed");
});

await step("data, crates and sets persist after restarting the backend", async () => {
  restarting = true;
  procs[0].kill();
  await new Promise((r) => setTimeout(r, 500));
  procs[0] = start(bridgeBin, ["--db", path.join(data, "app/catalogue.sqlite3"), "--port", "7878"]);
  await waitFor("http://127.0.0.1:7878");
  await page.reload();
  restarting = false;
  await nav("Wedding").click();
  await count(1).waitFor();
  await nav("Set Studio").click();
  await page.getByRole("button", { name: "E2E warm-up", exact: true }).waitFor();
});

await step("no external network requests were made by the UI", async () => expect(external.length === 0, `external requests: ${external.join(", ")}`));
await step("no console errors", async () => expect(consoleErrors.length === 0, consoleErrors.join("\n")));
await browser.close();
const after = snapshot(music);
await step("source files unchanged after the whole session (size, mtime, SHA-256)", async () => expect(JSON.stringify(before) === JSON.stringify(after), "fixture files changed!"));
cleanup();
console.log(failures ? `\n${failures} e2e step(s) FAILED` : "\nall e2e steps passed");
process.exit(failures ? 1 : 0);
