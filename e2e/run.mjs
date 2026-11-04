// End-to-end test: real React UI + real dj-core backend (via the dev-only
// loopback bridge) + real audio fixture files. Run: npm run e2e
import { spawn, execSync } from "node:child_process";
import { cpSync, mkdirSync, rmSync, readdirSync, statSync, readFileSync, existsSync, writeFileSync } from "node:fs";
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
// Quick Prep: a separate folder of badly named downloads (copies of fixtures).
const messy = path.join(data, "Messy Downloads");
const exportsDir = path.join(data, "Exports");
mkdirSync(messy, { recursive: true });
mkdirSync(path.join(exportsDir, "playlists"), { recursive: true });
const fx = (p) => path.join(root, "crates/dj-core/tests/fixtures/library", p);
cpSync(fx("Lossless/untagged recording.wav"), path.join(messy, "01_-_dj_kozi-sunset_drive_(original_mix)_[FREE DL]_www.promo.net.wav"));
cpSync(fx("Lossless/untagged recording.wav"), path.join(messy, "deep_house_groove__clean_.wav"));
cpSync(fx("Lossless/untagged recording.wav"), path.join(messy, "track02 final FINAL v3.wav"));
cpSync(fx("House/Old School/Basement Hours.mp3"), path.join(messy, "basement-hours_FINAL.mp3"));

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
const messyBefore = snapshot(messy);

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
start(bridgeBin, ["--db", path.join(data, "app/catalogue.sqlite3"), "--port", "7878", "--demo-ai"]);
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

const bridge = (cmd, args = {}) => fetch("http://127.0.0.1:7878", { method: "POST", body: JSON.stringify({ cmd, args }) }).then((r) => r.json());
console.log("running e2e steps…");
await page.goto("http://127.0.0.1:5174");

await step("first run asks for a local account name (no sign-in)", async () => {
  await page.getByRole("heading", { name: "Welcome" }).waitFor();
  await page.screenshot({ path: path.join(shots, "00-account.png") });
  await page.getByLabel("Account name").fill("Herbie");
  await page.getByRole("button", { name: /Create account/ }).click();
  await page.getByRole("button", { name: /Herbie/ }).first().waitFor();
  // The scripted steps below check exact counts; auto-prep gets its own step later.
  await bridge("set_setting", { key: "auto_prep", value: false });
});

await step("splash animation shows on opening and hands over to the app", async () => {
  await page.locator("#splash").waitFor({ state: "detached", timeout: 15000 });
});

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

await step("AI assistant: a local model server is scanned and any installed model can be chosen", async () => {
  // A stand-in for Ollama on 127.0.0.1 with three installed models (one is embedding-only).
  const { createServer } = await import("node:http");
  const tags = { models: [
    { name: "mistral:latest", size: 4100000000, details: { family: "llama", parameter_size: "7.2B" } },
    { name: "gemma2:2b", size: 1600000000, details: { family: "gemma2", parameter_size: "2.6B" } },
    { name: "nomic-embed-text:latest", size: 274000000, details: { family: "nomic-bert", families: ["nomic-bert"] } },
  ] };
  const fake = createServer((req, res) => { res.setHeader("content-type", "application/json"); res.end(JSON.stringify(req.url === "/api/tags" ? tags : {})); });
  await new Promise((r) => fake.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${fake.address().port}`;
  expect(!(await bridge("set_setting", { key: "ai_local_url", value: url })).error, "local url not accepted");
  await nav("Settings").click();
  await page.getByRole("heading", { name: "AI assistant", exact: true }).waitFor();
  await page.getByLabel("AI provider", { exact: true }).selectOption("local");
  await page.getByText("Found 3 models on this computer — pick any one:").waitFor();
  const group = page.getByRole("radiogroup", { name: "Installed local models" });
  expect(await group.getByRole("radio", { name: /nomic-embed-text/ }).isDisabled(), "embedding model should not be choosable");
  await group.getByRole("radio", { name: /gemma2:2b/ }).check();
  await page.getByText("Using gemma2:2b").waitFor();
  await page.getByText("Ready", { exact: true }).waitFor();
  await page.getByRole("button", { name: "Scan again" }).click();
  await page.getByText("Found 3 models on this computer.").waitFor();
  await page.getByRole("radiogroup", { name: "Installed local models" }).scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(shots, "15-local-models.png") });
  expect((await bridge("ai_status")).ok?.model === "gemma2:2b", "model not saved");
  fake.close();
});

await step("AI assistant: any online AI can be chosen from a dropdown (OpenAI-compatible server, models loaded)", async () => {
  const { createServer } = await import("node:http");
  const fake = createServer((req, res) => {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify(req.url === "/v1/models" ? { data: [{ id: "local-llama-8b" }, { id: "qwen3-14b" }] } : {}));
  });
  await new Promise((r) => fake.listen(0, "127.0.0.1", r));
  const picker = page.getByLabel("AI provider", { exact: true });
  const options = await picker.locator("option").allInnerTexts();
  for (const want of ["Claude (Anthropic)", "OpenAI (ChatGPT)", "Google Gemini — free tier", "Groq — free tier", "GitHub Models — free with a GitHub account", "Mistral — free tier", "DeepSeek", "xAI (Grok)", "Local model (Ollama)"]) expect(options.includes(want), `${want} missing: ${options}`);
  await picker.selectOption("gemini");
  await page.getByLabel("Google Gemini — free tier API key").first().waitFor();
  await page.getByText(/Get a free key at/).waitFor();
  await page.getByText("Add the API key for this AI service").first().waitFor();
  await picker.selectOption("custom");
  await page.getByLabel("Server address").fill(`http://127.0.0.1:${fake.address().port}/v1`);
  await page.getByRole("button", { name: "Save address" }).click();
  await page.getByRole("button", { name: "Load models" }).click();
  await page.getByText("2 models available.").waitFor();
  await page.getByLabel("Model", { exact: true }).selectOption("qwen3-14b");
  await page.getByText("Ready", { exact: true }).waitFor();
  expect((await bridge("ai_status")).ok?.model === "qwen3-14b", "model not saved");
  // The Online services card offers the same choice.
  const card = page.getByLabel("Online AI service");
  expect((await card.inputValue()) === "custom", "online card shows the chosen service");
  await page.getByRole("switch", { name: "Turn AI assistant (online) on" }).or(page.getByLabel("Turn AI assistant (online) on")).first().waitFor();
  const on = await page.getByLabel("Turn AI assistant (online) on").first().evaluate((el) => el.getAttribute("aria-checked") ?? String(el.checked));
  expect(on === "true", `online switch should be on (${on})`);
  await page.getByRole("heading", { name: "Online services" }).scrollIntoViewIfNeeded();
  await page.screenshot({ path: path.join(shots, "16-ai-services.png") });
  fake.close();
});

await step("AI assistant: turn on Claude with a key (scripted model in tests)", async () => {
  await nav("Settings").click();
  await page.getByRole("heading", { name: "AI assistant", exact: true }).waitFor();
  await page.getByLabel("AI provider", { exact: true }).selectOption("claude");
  await page.getByText(/Add your Anthropic API key/).first().waitFor();
  await page.getByLabel("Anthropic API key").first().fill("sk-ant-e2e-demo");
  await page.getByRole("button", { name: "Save API key" }).click();
  await page.getByText("Ready", { exact: true }).waitFor();
  await page.getByText(/sent to Anthropic/).first().waitFor();
  await page.getByRole("contentinfo").getByText(/AI assistant \(online\)/).waitFor();
});

await step("AI assistant looks things up, filters the library and proposes a crate that runs only on approval", async () => {
  const chat = page.getByLabel("Message the assistant");
  await page.getByRole("heading", { name: /AI assistant/ }).first().waitFor();
  await chat.fill("show me my afrobeats");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByText(/Afrobeats tracks\. I can put them/).waitFor();
  await page.getByText(/Looked up: search tracks/).waitFor();
  await page.getByText(/Showing Afrobeats in the library/).waitFor();
  const before = await page.getByRole("navigation", { name: "Main" }).getByText("Afrobeats (AI)").count();
  expect(before === 0, "crate existed before approval");
  await chat.fill("yes, make that a crate");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByText(/Create smart crate “Afrobeats \(AI\)” — \d+ tracks? match now/).waitFor();
  expect((await page.getByRole("navigation", { name: "Main" }).getByText("Afrobeats (AI)").count()) === 0, "crate created before Run");
  await page.screenshot({ path: path.join(shots, "10-ai-action-card.png") });
  await page.getByRole("button", { name: /^Run/ }).click();
  await page.getByText(/All done\. The crate/).waitFor();
  await page.getByRole("navigation", { name: "Main" }).getByText("Afrobeats (AI)").first().waitFor();
});

await step("slash commands run app tasks directly", async () => {
  const chat = page.getByLabel("Message the assistant");
  await chat.fill("/");
  await page.getByRole("listbox", { name: "Commands" }).waitFor();
  await chat.fill("/keys musical");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByText("Keys now show in musical notation.").waitFor();
  await chat.fill("/fix genre");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByRole("heading", { name: "Fix: Missing genre" }).waitFor();
  await chat.fill("/keys camelot");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByText("Keys now show in camelot notation.").waitFor();
  await chat.fill("/nope");
  await page.getByRole("button", { name: "Send" }).click();
  await page.getByText(/Unknown command \/nope/).waitFor();
});

// ---------------------------------------------------------------- Quick Prep
const listFiles = (dir) => { const out = []; const walk = (d, rel) => { for (const n of readdirSync(d)) { const p = path.join(d, n); if (statSync(p).isDirectory()) walk(p, `${rel}${n}/`); else out.push(`${rel}${n}`); } }; walk(dir, ""); return out.sort(); };
const exportVia = async (mode, dest) => {
  if (mode) await page.getByText(mode).click();
  await page.getByLabel("Destination").fill(dest);
  if (mode === "Playlists only") {
    await page.getByRole("button", { name: "Save playlists" }).click();
  } else {
    await page.getByRole("button", { name: "Preview", exact: true }).click();
    await page.getByRole("button", { name: "Copy and verify" }).click();
  }
  await page.getByRole("heading", { name: "Export finished" }).waitFor({ timeout: 30000 });
};

await step("Quick Prep: a new folder is added read-only, scanned and analysed", async () => {
  await nav("Quick Prep").click();
  await page.screenshot({ path: path.join(shots, "20-quick-start.png") });
  await page.getByLabel("Folder path").fill(messy);
  await page.getByRole("button", { name: "Use folder" }).click();
  await page.getByRole("heading", { name: "Tracks ready." }).waitFor({ timeout: 60000 });
  await page.screenshot({ path: path.join(shots, "21-quick-analysed.png") });
  await page.getByRole("button", { name: "Continue", exact: true }).click();
  await page.getByRole("heading", { name: "What do you want to do?" }).waitFor();
});

await step("Quick Prep: clean names strip junk, keep real tags, and edits follow the format", async () => {
  await page.getByRole("button", { name: /Clean names/ }).click();
  const names = await page.locator(".qp-name").evaluateAll((els) => els.map((e) => e.value));
  for (const n of ["DJ Kozi - Sunset Drive (Original Mix)", "Deep House Groove (Clean)", "Track 02", "Deep Tenant - Basement Hours"]) expect(names.includes(n), `missing “${n}” in ${JSON.stringify(names)}`);
  const edit = page.getByLabel("Clean name for track02 final FINAL v3.wav");
  await edit.fill("Mara Vey - Last Train");
  await edit.press("Enter");
  await page.getByRole("button", { name: "Title – Artist" }).click();
  expect((await edit.inputValue()) === "Last Train - Mara Vey", `format switch: ${await edit.inputValue()}`);
  await page.getByRole("button", { name: "Artist – Title" }).click();
  await page.screenshot({ path: path.join(shots, "22-quick-clean.png") });
  await page.getByRole("button", { name: "Save names to catalogue" }).click();
  await page.getByText(/Saved clean names for \d+ tracks? to your catalogue/).waitFor();
});

await step("Quick Prep: clean export = verified copies with clean names, tags in the MP3, a playlist", async () => {
  await page.getByRole("button", { name: "Export clean tracks" }).click();
  await exportVia(null, exportsDir);
  const files = listFiles(path.join(exportsDir, "Clean tracks"));
  for (const f of ["DJ Kozi - Sunset Drive (Original Mix).wav", "Mara Vey - Last Train.wav", "Deep Tenant - Basement Hours.mp3", "All tracks.m3u8", "manifest.json"]) expect(files.includes(f), `missing ${f} in ${files}`);
  const manifest = JSON.parse(readFileSync(path.join(exportsDir, "Clean tracks", "manifest.json"), "utf8"));
  expect(manifest.tagged === 1 && manifest.files.every((f) => f.verified), `manifest: tagged=${manifest.tagged}`);
  await page.getByRole("button", { name: "Done" }).click();
});

await step("Quick Prep: playlist sorts by BPM and exports as one ZIP with numbered files", async () => {
  await page.getByRole("button", { name: "All paths" }).click();
  await page.getByRole("button", { name: /Build a playlist/ }).click();
  await page.getByRole("button", { name: "Ascending BPM" }).click();
  await page.getByRole("button", { name: "Warm-up → peak" }).click();
  await page.getByRole("button", { name: "Warm-up → peak", pressed: true }).waitFor();
  await page.getByLabel("Playlist name").fill("Friday Set");
  await page.screenshot({ path: path.join(shots, "23-quick-playlist.png") });
  await page.getByRole("button", { name: "Export playlist" }).click();
  await exportVia("One ZIP file", exportsDir);
  const zip = path.join(exportsDir, "Friday Set.zip");
  const names = execSync(`python3 -c "import zipfile,sys; print('\\n'.join(zipfile.ZipFile(sys.argv[1]).namelist()))" "${zip}"`).toString().split("\n");
  expect(names.includes("Friday Set/Friday Set.m3u8") && names.filter((n) => /^Friday Set\/0[1-4] /.test(n)).length === 4, `zip: ${names}`);
  await page.getByRole("button", { name: "Done" }).click();
});

await step("Quick Prep: folders are set up, sorted with number keys, and exported", async () => {
  await page.getByRole("button", { name: "All paths" }).click();
  await page.getByRole("button", { name: /Organise folders/ }).click();
  await page.getByText("2 main · 6 sub").waitFor();
  await page.getByRole("button", { name: "Start sorting" }).click();
  await page.locator(".qp-strack").first().click();
  await page.keyboard.press("1");
  await page.keyboard.press("3");
  await page.getByText(/^2 of 4 sorted/).waitFor();
  await page.screenshot({ path: path.join(shots, "24-quick-folders.png") });
  await page.getByRole("button", { name: "Export folders" }).click();
  await exportVia(null, exportsDir);
  const files = listFiles(path.join(exportsDir, "Messy Downloads – organised"));
  expect(files.some((f) => f.startsWith("Friday Night/Warm Up/")) && files.some((f) => f.startsWith("Friday Night/Peak Time/")) && files.filter((f) => f.startsWith("Unsorted/")).length === 2, `folders: ${files}`);
  expect(files.filter((f) => f.startsWith("Playlists/")).length === 3, `playlists: ${files}`);
  await page.getByRole("button", { name: "Done" }).click();
});

await step("Quick Prep: genres group into families, save as crates, and export playlists only", async () => {
  await page.getByRole("button", { name: "All paths" }).click();
  await page.getByRole("button", { name: /Split by genre/ }).click();
  await page.getByText("Group into families").click();
  await page.screenshot({ path: path.join(shots, "25-quick-genres.png") });
  await page.getByRole("button", { name: "Save as crates" }).click();
  await page.getByText(/genre crates? under “Quick Prep · Messy Downloads”/).waitFor();
  await page.getByRole("button", { name: "Export by genre" }).click();
  await exportVia("Playlists only", path.join(exportsDir, "playlists"));
  const lists = readdirSync(path.join(exportsDir, "playlists"));
  expect(lists.length >= 1 && lists.every((l) => l.endsWith(".m3u8")), `playlists: ${lists}`);
  expect(readFileSync(path.join(exportsDir, "playlists", lists[0]), "utf8").includes(messy), "links-only playlists point at the originals");
  await page.getByRole("button", { name: "Done" }).click();
});

await step("Quick Prep never changed the source files", async () => expect(JSON.stringify(messyBefore) === JSON.stringify(snapshot(messy)), "messy folder changed!"));


await step("Quick Prep: previews stream catalogued tracks only (range requests)", async () => {
  const row = (await bridge("search", { query: { text: "basement hours" } })).ok.rows[0];
  const r = await fetch(`http://127.0.0.1:7878/track/${row.id}`, { headers: { Range: "bytes=0-99" } });
  expect(r.status === 206 && (await r.arrayBuffer()).byteLength === 100, `status ${r.status}`);
  expect((await fetch("http://127.0.0.1:7878/track/999999")).status === 404, "unknown ids must not resolve");
});

await step("Quick Prep AI help uses the assistant's model: better names and a set order", async () => {
  await nav("Quick Prep").click();
  await page.getByRole("button", { name: "All paths" }).click();
  await page.getByRole("button", { name: /Clean names/ }).click();
  await page.getByRole("button", { name: "Improve with AI" }).click();
  await page.getByText(/AI suggested names for/).waitFor();
  const names = await page.locator(".qp-name").evaluateAll((els) => els.map((e) => e.value));
  expect(names.includes("Groove Unit - Deep House Groove (Clean)"), `AI name missing: ${names}`);
  expect(names.includes("Mara Vey - Last Train"), "your own edit must be kept");
  await page.getByRole("button", { name: "All paths" }).click();
  await page.getByRole("button", { name: /Build a playlist/ }).click();
  await page.getByLabel("Describe how to order the playlist").fill("something dreamy that slowly opens up");
  await page.getByRole("button", { name: "Sort", exact: true }).click();
  await page.getByText("Reversed by the demo AI.").waitFor();
});


// ---------------------------------------------------------------- Studio
const studioSongs = path.join(data, "Studio Songs");
const studioOut = path.join(data, "Studio Out");
mkdirSync(studioSongs, { recursive: true });
mkdirSync(studioOut, { recursive: true });
const groove = (bpm, seconds, rootHz) => {
  const sr = 44100, n = sr * seconds, beat = (60 / bpm) * sr;
  const L = new Float32Array(n), R = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const t = i / sr, b = i % beat, tb = b / sr;
    const kick = tb < 0.15 ? Math.sin(2 * Math.PI * (50 + 120 * Math.exp(-tb * 40)) * tb) * Math.exp(-tb * 18) * 0.7 : 0;
    const bass = Math.sin(2 * Math.PI * rootHz * t) * 0.2;
    const lead = Math.sin(2 * Math.PI * rootHz * 4 * t) * 0.08;
    L[i] = kick + bass + lead; R[i] = kick + bass;
  }
  const buf = Buffer.alloc(44 + n * 4);
  buf.write("RIFF", 0); buf.writeUInt32LE(36 + n * 4, 4); buf.write("WAVEfmt ", 8); buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(2, 22);
  buf.writeUInt32LE(sr, 24); buf.writeUInt32LE(sr * 4, 28); buf.writeUInt16LE(4, 32); buf.writeUInt16LE(16, 34); buf.write("data", 36); buf.writeUInt32LE(n * 4, 40);
  for (let i = 0; i < n; i++) { buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, L[i])) * 32000), 44 + i * 4); buf.writeInt16LE(Math.round(Math.max(-1, Math.min(1, R[i])) * 32000), 46 + i * 4); }
  return buf;
};
writeFileSync(path.join(studioSongs, "Studio Groove.wav"), groove(124, 20, 55));
writeFileSync(path.join(studioSongs, "Second Groove.wav"), groove(120, 20, 73.42));
const listDir = (d) => (existsSync(d) ? readdirSync(d).sort() : []);
const waitFile = async (p, ms = 60000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { if (existsSync(p)) return; await new Promise((r) => setTimeout(r, 200)); } throw new Error(`timed out waiting for ${p}`); };

await step("Studio: songs are added and the save folder is set", async () => {
  const root = (await bridge("add_root", { path: studioSongs })).ok;
  await bridge("start_scan", { root_ids: [root.id] });
  for (let i = 0; i < 100; i++) { const st = (await bridge("scan_status")).ok; if (st.state !== "running" && st.state !== "paused") break; await new Promise((r) => setTimeout(r, 200)); }
  await page.evaluate((d) => { window.__studioSaveDir = d; }, studioOut);
});

await step("Studio Stems: split a song, see key/tempo/chords, save stems and MIDI", async () => {
  await nav("Stems").click();
  await page.getByRole("list", { name: "Song to split" }).getByRole("button", { name: /Studio Groove/ }).click();
  await page.getByRole("button", { name: "Download stems (WAV)" }).waitFor({ timeout: 120000 });
  const stats = await page.locator(".st-stats").first().innerText();
  expect(/BPM/.test(stats), `stats: ${stats}`);
  await page.screenshot({ path: path.join(shots, "30-studio-stems.png") });
  await page.getByRole("button", { name: "Download stems (WAV)" }).click();
  await waitFile(path.join(studioOut, "Studio Groove - Stems"));
  await page.waitForTimeout(1500);
  const files = listDir(path.join(studioOut, "Studio Groove - Stems"));
  expect(files.length === 5 && files.some((f) => f.endsWith("Vocals.wav")) && files.some((f) => f.endsWith("Instrumental.wav")), `stems: ${files}`);
  await page.getByRole("button", { name: "Download MIDI" }).click();
  await waitFile(path.join(studioOut, "Studio Groove.mid"));
  expect(readFileSync(path.join(studioOut, "Studio Groove.mid")).subarray(0, 4).toString() === "MThd", "not a MIDI file");
});

await step("Studio Remix: add stems and songs, auto-synced, export the remix", async () => {
  await page.getByRole("button", { name: "Remix it →" }).click();
  await page.getByRole("button", { name: "+ Drums" }).click();
  await page.locator(".st-trackrow").first().waitFor({ timeout: 60000 });
  await page.getByRole("list", { name: "Song to add" }).getByRole("button", { name: /Second Groove/ }).click();
  await page.getByRole("button", { name: "+ Song" }).click();
  const t0 = Date.now(); while ((await page.locator(".st-trackrow").count()) < 2 && Date.now() - t0 < 60000) await page.waitForTimeout(200);
  expect((await page.locator(".st-trackrow").count()) === 2, "second track missing");
  const clips = () => page.locator(".st-clip").count();
  const n = await clips();
  await page.locator(".st-clip").first().click();
  await page.getByRole("button", { name: "Duplicate clip" }).click();
  await page.waitForTimeout(200);
  expect((await clips()) === n + 1, "clip not duplicated");
  await page.getByRole("button", { name: "Undo" }).click();
  await page.waitForTimeout(200);
  expect((await clips()) === n, "undo did not remove the duplicate");
  await page.getByRole("button", { name: "Redo" }).click();
  await page.waitForTimeout(200);
  expect((await clips()) === n + 1, "redo did not restore it");
  await page.getByRole("button", { name: "Undo" }).click();
  await page.screenshot({ path: path.join(shots, "31-studio-remix.png") });
  await page.getByRole("button", { name: "Export remix (WAV)" }).click();
  await waitFile(path.join(studioOut, "My Remix.wav"));
});

await step("Studio DJ: two decks, sync matches tempo, deck plays", async () => {
  await nav("DJ Decks").click();
  await page.getByRole("button", { name: "Load a song" }).first().click();
  await page.getByRole("dialog", { name: "Load deck A" }).getByRole("button", { name: /Studio Groove/ }).click();
  await page.getByRole("button", { name: "Play deck A" }).waitFor({ timeout: 30000 });
  await page.getByRole("button", { name: "Play deck A" }).click();
  await page.getByRole("button", { name: "Load a song" }).click();
  await page.getByRole("dialog", { name: "Load deck B" }).getByRole("button", { name: /Second Groove/ }).click();
  await page.getByRole("button", { name: "Sync deck B" }).waitFor({ timeout: 30000 });
  await page.getByRole("button", { name: "Sync deck B" }).click();
  await page.waitForTimeout(1200);
  const b = await page.locator(".st-deck .st-stats b").evaluateAll((els) => els.map((e) => e.textContent));
  expect(b[0] === b[2] && b[0] !== "—", `bpms ${b}`);
  const time = await page.locator(".st-deck").first().locator(".st-mono").first().innerText();
  expect(!time.startsWith("0:00 /"), `deck A not playing: ${time}`);
  await page.getByRole("button", { name: "Loop 4 beats on deck A" }).click();
  expect((await page.getByRole("button", { name: "Loop 4 beats on deck A" }).getAttribute("aria-pressed")) === "true", "loop not on");
  await page.getByRole("button", { name: "Set hot cue 1 on deck A" }).click();
  await page.getByRole("button", { name: "Jump to hot cue 1 on deck A" }).waitFor();
  await page.getByLabel("low EQ deck A").fill("-24");
  await page.getByLabel("Filter deck B").fill("-0.5");
  await page.getByText("low-pass").waitFor();
  await page.screenshot({ path: path.join(shots, "32-studio-dj.png") });
  await page.getByRole("button", { name: "Loop 4 beats on deck A" }).click();
  await page.getByRole("button", { name: "Pause deck A" }).click();
});

await step("Studio Synth Lab and Drum Lab: sounds from words, played and saved", async () => {
  await nav("Synth Lab").click();
  await page.getByLabel("Describe the sound").fill("bright cinematic synth organ");
  await page.getByRole("button", { name: "Make it" }).click();
  await page.getByRole("heading", { name: /Bright Cinematic Synth Organ/ }).waitFor();
  await page.keyboard.down("a"); await page.waitForTimeout(150); await page.keyboard.up("a");
  await page.getByRole("button", { name: "Download instrument" }).click();
  await waitFile(path.join(studioOut, "Bright Cinematic Synth Organ", "Bright Cinematic Synth Organ.sfz"));
  await page.screenshot({ path: path.join(shots, "33-studio-synth.png") });
  await nav("Drum Lab").click();
  await page.getByLabel("Describe the kit").fill("warm disco house kit");
  await page.getByRole("button", { name: "Make it" }).click();
  await page.getByRole("heading", { name: /Warm Disco House Kit/ }).waitFor();
  await page.keyboard.press("z");
  await page.getByRole("button", { name: "Download kit" }).click();
  await waitFile(path.join(studioOut, "Warm Disco House Kit", "Warm Disco House Kit.sfz"));
  expect(listDir(path.join(studioOut, "Warm Disco House Kit")).filter((f) => f.endsWith(".wav")).length === 16, "kit pads");
  await page.getByRole("button", { name: "Play pattern" }).click();
  await page.getByRole("gridcell").first().click();
  const seen = new Set();
  for (let t = 0; t < 8; t++) {
    seen.add(await page.locator(".st-seq-row").first().locator(".st-step").evaluateAll((els) => els.findIndex((e) => e.classList.contains("now"))));
    await page.waitForTimeout(150);
  }
  expect(seen.size >= 3 && !seen.has(-1), `playhead did not move: ${[...seen]}`);
  await page.screenshot({ path: path.join(shots, "34-studio-drums.png") });
  await page.getByRole("button", { name: "Stop pattern" }).click();
  await page.getByRole("button", { name: "Export loop (WAV)" }).click();
  await waitFile(path.join(studioOut, "Warm Disco House Kit 124 bpm.wav"));
  await page.getByRole("button", { name: "Export pattern (MIDI)" }).click();
  await waitFile(path.join(studioOut, "Warm Disco House Kit 124 bpm.mid"));
  expect(readFileSync(path.join(studioOut, "Warm Disco House Kit 124 bpm.mid")).subarray(0, 4).toString() === "MThd", "pattern MIDI");
});

// ---------------------------------------------------------------- local accounts
await step("Online catalogues: Deezer & Apple Music can be turned on and checked from Suggestions", async () => {
  await nav("Settings").click();
  const sw = page.getByLabel("Turn Deezer & Apple Music catalogues on");
  await sw.scrollIntoViewIfNeeded();
  expect(!(await sw.isChecked()), "catalogues should be off by default");
  await sw.locator("xpath=..").click();
  await page.waitForTimeout(300);
  expect((await bridge("services")).ok.some((s) => s.id === "catalogs" && s.enabled), "catalogues not enabled");
  await nav("Suggestions").click();
  // the Studio (visited earlier) stays mounted but must be hidden on other pages
  expect(!(await page.getByRole("heading", { name: "Studio", exact: true }).isVisible()), "Studio page shows through on Suggestions");
  await page.screenshot({ path: path.join(shots, "17-suggestions.png") });
  await page.getByRole("button", { name: /Check BPM, year & genre online/ }).click();
  await page.getByText(/Checking BPM, year and genre on Deezer and Apple Music/).first().waitFor();
  // the test build has no network: turn it back off so later steps stay offline
  expect(!(await bridge("set_service", { service: "catalogs", enabled: false })).error, "turn off");
});

await step("a second local account has its own empty library, and switching back restores yours", async () => {
  await page.getByRole("button", { name: /Herbie/ }).first().click();
  await page.getByRole("menuitem", { name: "Manage accounts…" }).click();
  await page.getByLabel("New account name").fill("Guest DJ");
  await page.getByRole("button", { name: "Add account" }).click();
  await page.getByRole("dialog", { name: "Before you start" }).waitFor();
  await page.getByRole("button", { name: "I understand" }).click();
  await page.getByRole("heading", { name: "Welcome, Guest DJ" }).waitFor();
  await page.screenshot({ path: path.join(shots, "26-second-account.png") });
  await page.getByRole("button", { name: /Guest DJ/ }).first().click();
  await page.getByRole("menuitemradio", { name: /Herbie/ }).click();
  await nav("Library").click();
  await page.getByRole("heading", { name: "Music Library" }).waitFor();
  await nav("Wedding").waitFor();
});

await step("Organise Files: auto-prep analyses and applies recommended fixes", async () => {
  await nav("Organise Files").click();
  await page.getByRole("heading", { name: "Organise Files" }).waitFor();
  await page.getByRole("button", { name: "Run auto-prep now" }).click();
  await page.getByText("fixes applied").waitFor({ timeout: 120000 });
  await page.screenshot({ path: path.join(shots, "11-organise.png") });
});

await step("Organise Files: rename is previewed, applied on approval, and undone", async () => {
  await bridge("set_setting", { key: "allow_file_changes", value: true });
  await page.reload();
  await nav("Organise Files").click();
  await page.getByText("Changes to files: on").waitFor();
  await page.getByRole("button", { name: "Preview renames" }).click();
  const dlg = page.getByRole("dialog", { name: "Rename files" });
  await dlg.waitFor();
  await dlg.getByText(/Serato's links/).waitFor();
  await page.screenshot({ path: path.join(shots, "12-rename-preview.png") });
  await dlg.getByRole("button", { name: /^Apply/ }).click();
  await page.getByText(/changes? done/).first().waitFor();
  expect(existsSync(path.join(music, "House", "Old School", "Deep Tenant - Basement Hours.mp3")), "file was not renamed");
  await page.getByRole("button", { name: "Undo" }).first().click();
  await page.getByText(/Undid/).waitFor();
  expect(existsSync(path.join(music, "House", "Old School", "Basement Hours.mp3")), "undo did not restore the name");
  await bridge("set_setting", { key: "allow_file_changes", value: false });
});

await step("crates export to rekordbox XML", async () => {
  await nav("Virtual Crates").click();
  await page.getByRole("button", { name: "Export crates…" }).click();
  const dlg = page.getByRole("dialog", { name: "Export crates" });
  await dlg.getByRole("button", { name: "rekordbox XML" }).click();
  const xml = path.join(data, "export-test.xml");
  await dlg.getByLabel("Export destination").fill(xml);
  await dlg.getByRole("button", { name: /^Export \d+ crate/ }).click();
  await dlg.getByText(/Saved \d+ tracks?/).waitFor();
  const text = readFileSync(xml, "utf8");
  expect(text.includes("<DJ_PLAYLISTS") && text.includes("<TRACK TrackID="), "rekordbox XML looks wrong");
  await dlg.getByRole("button", { name: "Done" }).click();
});

await step("look: a colour theme recolours the app instantly", async () => {
  await nav("Settings").click();
  await page.getByRole("button", { name: "Ocean colour theme" }).click();
  const accent = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue("--mint").trim());
  expect(accent === "#4cb8ff", `accent is ${accent}`);
  await page.screenshot({ path: path.join(shots, "13-ocean-theme.png") });
  await page.getByRole("button", { name: "Mint colour theme" }).click();
});

await step("data, crates and sets persist after restarting the backend", async () => {
  restarting = true;
  procs[0].kill();
  await new Promise((r) => setTimeout(r, 500));
  procs[0] = start(bridgeBin, ["--db", path.join(data, "app/catalogue.sqlite3"), "--port", "7878", "--demo-ai"]);
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
