// The smoke matrix's harness: a throwaway Tern profile, headless `tern serve` sessions driven with `tern ctl`, a real
// omp in an agent pane, and the plugin's cache, settings and omp status under the test's control. Nothing here touches
// the user's Tern settings, plugins, plugin data, omp config or ~/.omp/cache:
// - Tern runs with TERN_CONFIG_DIR, LOCALAPPDATA, USERPROFILE and HOME in the profile, and loads a snapshot of the
//   plugin as a fixture (`ctl plugins fixtures`), with an empty `.git` so it acts as a linked clone (no extension
//   setup) and update checks off.
// - omp runs through a wrapper with a home of its own (so no extension writes any cache the plugin reads), temp
//   sessions, the user's agent dir for its accounts (read only), and an overlay whose only extension is
//   demo-status.js: a usage-shaped status the test sets, and another extension's status.
// - The snapshot's render.luau gets a marked scaffold that writes each sheet it installs to the plugin's data folder,
//   which is how the matrix reads the line and the card (a pseudo-element's text isn't in `ctl tree`).
import { execFileSync, spawn } from "node:child_process";
import {
  cpSync,
  existsSync,
  mkdirSync,
  openSync,
  readdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir, hostname } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
export const TERN = process.env.TERN_CLI ?? (process.platform === "win32" ? "tern.com" : "tern");
export const OMP = process.env.OMP_EXE ?? join(process.env.LOCALAPPDATA ?? "", "Tern", "omp", "bin", "omp.exe");
export const AGENT_DIR = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".omp", "agent");
export const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

// The computer's name, which no screenshot or saved text may show (the composer's footer has it).
const HOST = hostname();
const HOST_WORD = new RegExp(`\\b${HOST.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\b`, "i");
export const redact = (text) => String(text).replace(new RegExp(HOST_WORD.source, "gi"), "dev-box");

const SCAFFOLD = "-- QA-SCAFFOLD (smoke matrix only, never in the repo)";
const SCAFFOLDS = [
  ["\t\ttern.css(SHEET, css)\n", `\t\ttern.css(SHEET, css)\n\t\tpcall(tern.fs.write, tern.plugin.data .. "/qa-usage.css", css) ${SCAFFOLD}\n`],
  ["\t\ttern.css(FACTS_SHEET, css)\n", `\t\ttern.css(FACTS_SHEET, css)\n\t\tpcall(tern.fs.write, tern.plugin.data .. "/qa-usage-facts.css", css) ${SCAFFOLD}\n`],
];

export const DEFAULT_STATUS = "Claude 5h ███░░░░░ 33% left (1h 2m) · 7d ██████░░ 77% left (3d 4h)";

// On Windows the rename fails (EPERM, EBUSY) while Tern has the file open to read it: a few tries, 50 ms apart.
function writeAtomic(path, text) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${process.pid}.tmp`;
  writeFileSync(tmp, text);
  for (let tries = 0; ; tries += 1) {
    try {
      renameSync(tmp, path);
      return;
    } catch (err) {
      if (tries >= 10 || !["EPERM", "EBUSY", "EACCES"].includes(err.code)) throw err;
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
    }
  }
}

export class Profile {
  constructor(root) {
    this.root = root;
    this.cfg = join(root, "cfg");
    this.local = join(root, "local");
    this.home = join(root, "home");
    this.omphome = join(root, "omphome");
    this.work = join(root, "work");
    this.fx = join(root, "fx");
    this.plugin = join(root, "plugin");
    this.shots = join(root, "shots");
    this.data = join(this.cfg, "plugin-data", "omp-usage");
    this.cachePath = join(this.home, ".omp", "cache", "usage-remaining.json");
    this.wrapper = join(root, "omp-smoke.cmd");
    this.probe = join(root, "probe.css");
  }

  // A fresh profile: the plugin snapshot (with the scaffold), its settings, and omp's wrapper and overlay. `beatMs`:
  // the overlay also sets a status that counts every beatMs ms (see demoStatus).
  prepare(kv = {}, { beatMs = 0 } = {}) {
    rmSync(this.root, { recursive: true, force: true });
    for (const dir of [this.cfg, this.local, dirname(this.cachePath), this.omphome, this.work, this.shots, this.data]) {
      mkdirSync(dir, { recursive: true });
    }
    mkdirSync(join(this.fx, "crates", "tern", "goldens"), { recursive: true });
    mkdirSync(join(this.fx, "crates", "plugins", "fixtures"), { recursive: true });
    mkdirSync(this.plugin, { recursive: true });
    for (const name of readdirSync(REPO)) {
      if (name.endsWith(".luau") || name === "plugin.toml" || name === "bar.css") {
        cpSync(join(REPO, name), join(this.plugin, name));
      }
    }
    cpSync(join(REPO, "omp"), join(this.plugin, "omp"), { recursive: true });
    mkdirSync(join(this.plugin, ".git"));
    let render = readFileSync(join(this.plugin, "render.luau"), "utf8");
    for (const [from, to] of SCAFFOLDS) {
      if (!render.includes(from)) throw new Error(`scaffold anchor not found in render.luau: ${JSON.stringify(from)}`);
      render = render.replace(from, to);
    }
    writeFileSync(join(this.plugin, "render.luau"), render);
    writeFileSync(join(this.fx, "crates", "plugins", "fixtures", "omp-usage.path"), this.plugin);
    this.writeKv({ "omp-usage.update-every": "off", ...kv });
    writeFileSync(
      join(this.cfg, "settings.json"),
      JSON.stringify({ theme: "Dark", theme_dark: "titanium", widgets: [{ id: "cwd" }, { id: "spacer" }, { id: "status" }] }, null, 1)
    );
    writeFileSync(this.probe, ".sf-status .sf-st-l > .sf-seg:first-child { display: none !important; }\n");
    writeFileSync(join(this.root, "uncut.css"), ".sf-row[data-role='omp.composer.bar'] .sf-drop { display: flex !important; }\n");
    writeFileSync(join(this.root, "demo-status.js"), demoStatus(beatMs));
    this.setStatus(DEFAULT_STATUS);
    const slash = (p) => p.replaceAll("\\", "/");
    writeFileSync(
      join(this.root, "overlay.yml"),
      `statusLine:\n  showHookStatus: true\nextensions:\n  - ${slash(join(this.root, "demo-status.js"))}\n`
    );
    writeFileSync(
      this.wrapper,
      [
        "@echo off",
        "rem Smoke matrix only: omp with its own home, temp sessions, the user's agent dir read only, and the test overlay.",
        `set "USERPROFILE=${this.omphome}"`,
        `set "HOME=${this.omphome}"`,
        `set "PI_CODING_AGENT_DIR=${AGENT_DIR}"`,
        `set "PI_CONFIG_FILES=${join(this.root, "overlay.yml")}"`,
        `set "PI_CODING_AGENT_SESSION_DIR=${join(this.root, "sessions")}"`,
        `cd /d "${this.work}"`,
        `"${OMP}" %*`,
        "",
      ].join("\r\n")
    );
    return this;
  }

  env() {
    return {
      ...process.env,
      TERN_CONFIG_DIR: this.cfg,
      LOCALAPPDATA: this.local,
      USERPROFILE: this.home,
      HOME: this.home,
      STENCIL_FIXTURE_ROOT: join(this.fx, "crates", "tern"),
    };
  }

  writeCache(docOrText) {
    writeAtomic(this.cachePath, typeof docOrText === "string" ? docOrText : JSON.stringify(docOrText));
  }

  kvPath() {
    return join(this.data, "kv.json");
  }

  readKv() {
    try {
      return JSON.parse(readFileSync(this.kvPath(), "utf8"));
    } catch {
      return {};
    }
  }

  // Sets (or with undefined, removes) settings in the plugin's tern.kv, as another window would.
  writeKv(patch) {
    const kv = this.readKv();
    for (const [key, value] of Object.entries(patch)) {
      if (value === undefined) delete kv[key];
      else kv[key] = value;
    }
    writeAtomic(this.kvPath(), JSON.stringify(kv, null, 1));
  }

  // The usage status demo-status.js sets (it reads this every 2 s).
  setStatus(text) {
    writeAtomic(join(this.root, "status.txt"), text);
  }

  // A widget demo-status.js shows above the composer, as an extension's would (it reads this every 2 s): the kind
  // of block that sits right above the line. Empty: none.
  setWidget(text) {
    writeAtomic(join(this.root, "widget.txt"), text);
  }

  // The plugin's last installed sheet (`usage` or `usage-facts`), as the scaffold wrote it; null before any.
  sheet(name = "usage") {
    const path = join(this.data, `qa-${name}.css`);
    return existsSync(path) ? readFileSync(path, "utf8") : null;
  }

  // The line and the hover card's text, from the last `usage` sheet (no-break spaces read as spaces).
  view() {
    const css = this.sheet("usage") ?? "";
    const contents = [...css.matchAll(/content: "((?:[^"\\]|\\.)*)"/g)].map((m) => m[1]).filter((s) => s !== "");
    const decode = (s) => s.replace(/\\A ?/g, "\n").replace(/\\(["\\])/g, "$1").replaceAll("\u00a0", " ");
    return {
      line: contents.length ? decode(contents[0]) : null,
      card: contents.length > 1 ? decode(contents[contents.length - 1]) : null,
      dim: css.includes("r g b / 45%)"),
      css,
    };
  }
}

// Smoke tests only: a usage-shaped status (from status.txt beside this file) and another extension's status. With
// `beatMs`, a third status counts every beatMs ms: omp redraws, and Tern runs the window's plugin timers on time. A
// headless window runs them only when something in it changes: never without an omp pane, and about every 10 s with
// an idle one.
const demoStatus = (beatMs) => `// Smoke tests only: a usage-shaped status (from status.txt beside this file) and another extension's status.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
const read = (name) => { try { return readFileSync(join(here, name), "utf8").trim(); } catch { return ""; } };
const usage = () => read("status.txt");
export default function demoStatus(pi) {
  pi.on("session_start", async (_event, ctx) => {
    let last = usage();
    let widget = "";
    ctx.ui.setStatus("qa-usage", last);
    ctx.ui.setStatus("qa-other", "demo: other extension");
    setInterval(() => {
      const now = usage();
      if (now !== last) { last = now; ctx.ui.setStatus("qa-usage", now); }
      const block = read("widget.txt");
      if (block !== widget) { widget = block; ctx.ui.setWidget("qa-widget", block ? block.split("\\n") : undefined); }
    }, 2000);${
  beatMs > 0 ? `\n    let beat = 0;\n    setInterval(() => { beat += 1; ctx.ui.setStatus("qa-beat", "beat " + beat); }, ${beatMs});` : ""
}
  });
}
`;

export class Serve {
  constructor(profile, port, label) {
    this.profile = profile;
    this.port = port;
    this.label = label;
    this.log = join(profile.root, `serve-${label}.log`);
  }

  async start() {
    const out = openSync(this.log, "a");
    this.child = spawn(TERN, ["serve", "--control", String(this.port), "--out", this.profile.shots], {
      env: this.profile.env(),
      cwd: this.profile.work,
      stdio: ["ignore", out, out],
      windowsHide: true,
    });
    const until = Date.now() + 90_000;
    while (Date.now() < until) {
      // a ctl that can't connect comes back without `ok`: only a reply counts
      if (this.ctl("stats").ok === true) return this;
      await sleep(500);
    }
    throw new Error(`tern serve on ${this.port} didn't start (see ${this.log})`);
  }

  // One `tern ctl` command; the reply as JSON when it is.
  ctl(...args) {
    let text;
    try {
      text = execFileSync(TERN, ["ctl", "--control", String(this.port), ...args.map(String)], {
        encoding: "utf8",
        timeout: 90_000,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (err) {
      text = String(err.stdout ?? "") || String(err.message);
    }
    try {
      return JSON.parse(text);
    } catch {
      return { raw: text };
    }
  }

  // Visible nodes for a selector: [{ text, class, rect, … }].
  tree(selector) {
    return this.ctl("tree", selector).nodes ?? [];
  }

  // Opens one omp pane alone in the window and waits for its composer; loads the plugin first unless `plugins` is
  // false (a test that loads it later, in several windows at once).
  async openAgent({ width = 1400, height = 640, plugins = true } = {}) {
    if (plugins) this.ctl("plugins", "fixtures");
    this.ctl("size", width, height);
    this.ctl("agent-command", this.profile.wrapper);
    this.ctl("block", "agent");
    this.ctl("focus", "left");
    this.ctl("close");
    await this.waitForChip();
    this.ctl("css", "probe:hidehost", this.profile.probe);
    return this;
  }

  async waitForChip(timeout = 120_000) {
    const until = Date.now() + timeout;
    while (Date.now() < until) {
      const chip = this.tree(".tn-pane.on [data-role='omp.composer.model']")[0];
      if (chip?.text) return chip.text;
      await sleep(1000);
    }
    throw new Error("no omp composer appeared");
  }

  // A screenshot, kept only if the computer's name shows nowhere in it.
  shot(name) {
    this.ctl("css", "probe:hidehost", this.profile.probe);
    const visible = this.tree(".sf-status .sf-seg").map((node) => node.text ?? "");
    if (visible.some((text) => HOST_WORD.test(text))) throw new Error("the computer's name is visible: not shooting");
    const reply = this.ctl("shot", name);
    const layout = reply.layout && existsSync(reply.layout) ? readFileSync(reply.layout, "utf8") : "";
    if (HOST_WORD.test(layout)) {
      rmSync(reply.png, { force: true });
      rmSync(reply.layout, { force: true });
      throw new Error(`shot ${name} had the computer's name in it: deleted`);
    }
    return reply.png;
  }

  async quit() {
    this.ctl("quit");
    await sleep(1500);
    try {
      this.child?.kill();
    } catch {
      // gone already
    }
  }
}

// Waits until `test()` returns something truthy (polling every `every` ms); returns it, or null at the timeout.
export async function waitFor(test, timeout = 30_000, every = 250) {
  const until = Date.now() + timeout;
  for (;;) {
    const value = await test();
    if (value) return value;
    if (Date.now() >= until) return null;
    await sleep(every);
  }
}

// Crops a 2x shot to a CSS-px box (with a margin) with Python's PIL, when it's there; returns the crop's path or null.
export function crop(png, box, margin = 12) {
  if (!png || !box) return null;
  const [x, y, w, h] = box;
  const out = png.replace(/\.png$/, "-crop.png");
  const script = [
    "import sys",
    "from PIL import Image",
    "im = Image.open(sys.argv[1])",
    "x, y, w, h, m = (float(v) for v in sys.argv[3:8])",
    "box = (max(0, int((x - m) * 2)), max(0, int((y - m) * 2)), min(im.size[0], int((x + w + m) * 2)), min(im.size[1], int((y + h + m) * 2)))",
    "im.crop(box).save(sys.argv[2])",
  ].join("\n");
  try {
    execFileSync("python", ["-c", script, png, out, x, y, w, h, margin], { stdio: "ignore", timeout: 30_000 });
    return out;
  } catch {
    return null;
  }
}

// Lines of a serve log (Tern writes it under the profile's LOCALAPPDATA) that mention the plugin.
export function pluginLog(profile) {
  const dir = join(profile.local, "Tern", "Logs");
  if (!existsSync(dir)) return [];
  const lines = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (!statSync(path).isFile()) continue;
    for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
      if (/omp-usage|omp Usage/.test(line)) lines.push(redact(line));
    }
  }
  return lines;
}
