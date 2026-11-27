#!/usr/bin/env node
// QA sweep driver (not part of the matrix): one throwaway headless Tern per port, driven one command at a time, so a
// sweep script can set a state, measure it and shoot it. Reuses lib.mjs's Profile and Serve (temp profile, plugin
// snapshot with the sheet-writing scaffold, omp through a wrapper with its own home).
//   node tests/smoke/sweep.mjs start PORT [reader|spine|console] [W] [H] ['{"agents_tray":false}']   (stays up)
//   node tests/smoke/sweep.mjs kv PORT key=json ...        plugin settings (tern.kv), as another window writes them
//   node tests/smoke/sweep.mjs ctl2 PORT key=json ...      the overlay extension's controls (see DEMO)
//   node tests/smoke/sweep.mjs cache PORT KIND [ageMin]    a cache the real extension writes (sweep-caches.mjs)
//   node tests/smoke/sweep.mjs cachefile PORT FILE         a cache file as is
//   node tests/smoke/sweep.mjs view PORT | geo PORT | shot PORT NAME [rest|hover|full] [above] [below] | quit PORT
//   node tests/smoke/sweep.mjs ctl PORT ARGS...            one raw `tern ctl`
// Profiles live in QA_SWEEP_DIR (default %TEMP%\qa-sweep) as prof-PORT.
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { crop, Profile, Serve, sleep, pluginLog } from "./lib.mjs";
import { build } from "./sweep-caches.mjs";

const ROOT = process.env.QA_SWEEP_DIR ?? join(tmpdir(), "qa-sweep");
const [, , cmd, portArg, ...rest] = process.argv;
const port = Number(portArg);
const root = join(ROOT, `prof-${port}`);
const profile = new Profile(root);
const serve = new Serve(profile, port, "x");
// The plugin's hover target (render.luau HOST): the empty chips row, or with attachments the first chip's end slot.
const CHIPS = ".tn-pane.on .sf-col[data-role^='omp.editor'] > .sf-row[data-role='omp.composer.chips']";
export const HOST_SEL = `${CHIPS}:is(.sf-hidden, .sf-void), ${CHIPS} > .sf-card:first-child > .sf-card-head > .sf-card-end:is(.sf-hidden, .sf-void)`;
export const EDITOR_SEL = ".tn-pane.on .sf-col[data-role^='omp.editor']";

// The overlay's extension, driven by ctl.json beside it: the usage status (status.txt), another extension's status
// (`other`), a widget above the editor (`widget`: lines), omp's working message (`working`), a notification
// (`notify`: [text, type], sent when it changes), a never-finishing background job for Tern's agents tray (`job`:
// its label; registered straight with omp's job manager and watched, so no turn ever starts; omp 19.2.1's bundle),
// and a beat (`beat`: ms) that keeps the headless window's plugin timers running.
const DEMO = `import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
const here = dirname(fileURLToPath(import.meta.url));
const read = (name) => { try { return readFileSync(join(here, name), "utf8").trim(); } catch { return ""; } };
export default function demoStatus(pi) {
  pi.on("session_start", async (_event, ctx) => {
    let last = {};
    let beat = 0;
    let beatAt = 0;
    const apply = () => {
      let want = {};
      try { want = JSON.parse(read("ctl.json") || "{}"); } catch {}
      const usage = read("status.txt");
      if (usage !== last.usage) { last.usage = usage; ctx.ui.setStatus("qa-usage", usage || undefined); }
      const other = want.other ?? "";
      if (other !== last.other) { last.other = other; ctx.ui.setStatus("qa-other", other || undefined); }
      const widget = JSON.stringify(want.widget ?? null);
      if (widget !== last.widget) { last.widget = widget; ctx.ui.setWidget("qa-widget", want.widget ?? undefined); }
      const working = want.working ?? "";
      if (working !== last.working) { last.working = working; try { ctx.ui.setWorkingMessage(working || undefined); } catch {} }
      if (want.job && !last.job) {
        last.job = "starting";
        import("B:/~BUN/root/chunks/packages/coding-agent/src/cli-zyfwkjsq.js").then((jm) => {
          const mgr = jm.nh?.instance?.();
          globalThis.__qaJobs = mgr;
          const ids = [];
          const run = () => (want.jobDone ? new Promise((done) => setTimeout(() => done("qa done"), Number(want.jobDone))) : new Promise(() => {}));
          for (let i = 0; i < Number(want.jobs ?? 1); i += 1) ids.push(mgr.register("bash", String(want.job) + (i ? " " + i : ""), run, { ownerId: "Main" }));
          mgr.watchJobs(ids);
          last.job = ids.join(",");
          const names = new Set();
          for (let p = mgr; p && p !== Object.prototype; p = Object.getPrototypeOf(p)) for (const n of Object.getOwnPropertyNames(p)) names.add(n);
          ctx.ui.setStatus("qa-job", "\\u25eb jobs " + last.job + " [" + [...names].join(" ") + "]");
        }, (err) => ctx.ui.setStatus("qa-job", "\\u25eb job import failed: " + err)).catch((err) => ctx.ui.setStatus("qa-job", "\\u25eb job failed: " + err));
      }
      if (want.cancel && last.job && last.job !== "starting" && !last.cancelled) {
        last.cancelled = true;
        const mgr = globalThis.__qaJobs;
        for (const id of last.job.split(",")) { try { (mgr.cancel ?? mgr.kill ?? mgr.abort)?.call(mgr, id); } catch (err) { ctx.ui.setStatus("qa-cancel", "\\u25eb cancel failed: " + err); } }
      }
      const every = Number(want.beat ?? 0);
      if (every > 0 && Date.now() - beatAt >= every) { beatAt = Date.now(); beat += 1; ctx.ui.setStatus("qa-beat", "\\u25eb " + beat); }
      else if (every <= 0 && last.beat !== 0) { ctx.ui.setStatus("qa-beat", undefined); }
      last.beat = every;
    };
    apply();
    setInterval(apply, 200);
  });
}
`;

const ctlFile = () => join(root, "ctl.json");
function readCtl() {
  try {
    return JSON.parse(readFileSync(ctlFile(), "utf8"));
  } catch {
    return {};
  }
}
function pairs(list) {
  const out = {};
  for (const item of list) {
    const at = item.indexOf("=");
    const raw = item.slice(at + 1);
    let value;
    if (raw === "undefined") value = undefined;
    else {
      try {
        value = JSON.parse(raw);
      } catch {
        value = raw;
      }
    }
    out[item.slice(0, at)] = value;
  }
  return out;
}

// Visible geometry of what matters around the composer: the composer, its meter, the hover target, every block in
// the dock (with its role/class and a bit of text), the tray, attachment chips and the pane.
export function geo(s) {
  const pick = (sel) => s.tree(sel).map((n) => ({ rect: n.rect, cls: n.class, text: (n.text ?? "").slice(0, 80), title: n.title }));
  const dock = s.ctl("dump", ".tn-pane.on .sf-dock > *").elements ?? [];
  return {
    pane: pick(".tn-pane.on")[0]?.rect ?? null,
    dockCls: pick(".tn-pane.on .sf-dock")[0]?.cls ?? null,
    editor: pick(EDITOR_SEL)[0]?.rect ?? null,
    meter: pick(".tn-pane.on .sf-meter[data-role='omp.composer.context']")[0]?.rect ?? null,
    meterKids: pick(".tn-pane.on .sf-meter[data-role='omp.composer.context'] *").map((n) => n.rect),
    host: pick(HOST_SEL).map((n) => n.rect),
    hostAll: (s.ctl("dump", HOST_SEL).elements ?? []).map((e) => ({ rect: e.rect, visible: e.visible })),
    chips: pick(".tn-pane.on [data-role='omp.composer.chips'] > .sf-card"),
    line: pick(".tn-pane.on [data-role='omp.composer.line']")[0]?.rect ?? null,
    bar: pick(".tn-pane.on [data-role='omp.composer.bar']")[0]?.rect ?? null,
    dock: dock.filter((e) => e.visible).map((e) => ({ rect: e.rect, path: String(e.path ?? "").split(">").slice(-1)[0].trim().slice(0, 160) })),
    tray: pick(".tn-pane.on .sf-col.sf-tray"),
    trayCards: pick(".tn-pane.on .sf-tray-card").map((n) => n.rect),
    dots: pick(".tn-pane.on .sf-tray-dots > .sf-tray-pip").map((n) => n.rect),
    activity: pick(".tn-pane.on [data-role='omp.hud.activity']"),
  };
}

if (cmd === "start") {
  const [chat = "reader", w = "1400", h = "640", extra = "{}"] = rest;
  mkdirSync(ROOT, { recursive: true });
  profile.prepare({}, {});
  writeFileSync(join(root, "demo-status.js"), DEMO);
  writeFileSync(ctlFile(), JSON.stringify({ beat: 250 }));
  // a headless serve doesn't take the chat style from settings.json (nor a reload): it's set from the palette below
  const settings = JSON.parse(readFileSync(join(profile.cfg, "settings.json"), "utf8"));
  Object.assign(settings, JSON.parse(extra));
  writeFileSync(join(profile.cfg, "settings.json"), JSON.stringify(settings, null, 1));
  profile.writeCache(await build("single"));
  await serve.start();
  await serve.openAgent({ width: Number(w), height: Number(h) });
  serve.ctl("appearance", "dark");
  if (chat !== "reader" && chat !== "default") {
    serve.ctl("palette", `chat style: ${chat}`);
    await sleep(900);
    const row = serve.tree(".tn-pl-item.sel")[0]?.text ?? "";
    if (row.toLowerCase() === `chat style: ${chat}`) serve.ctl("key", "Enter");
    else serve.ctl("key", "Escape");
    await sleep(1500);
  }
  const chip = serve.tree(".tn-pane.on [data-role='omp.composer.model']")[0]?.text;
  const dock = serve.tree(".tn-pane.on .sf-dock")[0];
  console.log("READY " + JSON.stringify({ chip, dockClass: dock?.class, root }));
  await new Promise((done) => serve.child.on("exit", done));
  process.exit(0);
} else if (cmd === "kv") {
  profile.writeKv(pairs(rest));
  console.log(JSON.stringify(profile.readKv()));
} else if (cmd === "ctl2") {
  const next = { ...readCtl(), ...pairs(rest) };
  for (const [k, v] of Object.entries(next)) if (v === undefined) delete next[k];
  writeFileSync(ctlFile(), JSON.stringify(next));
  console.log(JSON.stringify(next));
} else if (cmd === "status") {
  profile.setStatus(rest.join(" "));
} else if (cmd === "cache") {
  const [kind, age = "0"] = rest;
  const doc = await build(kind, Date.now(), Number(age));
  profile.writeCache(doc);
  console.log(JSON.stringify({ kind, age }));
} else if (cmd === "cachefile") {
  profile.writeCache(readFileSync(rest[0], "utf8"));
} else if (cmd === "view") {
  const v = profile.view();
  console.log(v.line);
  console.log("--- card");
  console.log(v.card);
  console.log("--- dim " + v.dim);
} else if (cmd === "sheet") {
  process.stdout.write(profile.sheet(rest[0] ?? "usage") ?? "");
} else if (cmd === "geo") {
  console.log(JSON.stringify(geo(serve)));
} else if (cmd === "shot") {
  const [name, mode = "rest", aboveArg, belowArg] = rest;
  if (mode === "hover") {
    serve.ctl("hover", HOST_SEL);
    await sleep(1700);
  } else {
    serve.ctl("move", 5, 5);
    await sleep(350);
  }
  const png = serve.shot(name);
  const editor = serve.tree(EDITOR_SEL)[0];
  const above = Number(aboveArg ?? (mode === "hover" ? 440 : 110));
  const below = Number(belowArg ?? 44);
  let out = png;
  if (editor && mode !== "full") {
    const pane = serve.tree(".tn-pane.on")[0];
    const box = pane ? [pane.rect[0], editor.rect[1] - above, pane.rect[2], above + below] : [editor.rect[0], editor.rect[1] - above, editor.rect[2], above + below];
    out = crop(png, box, 0) ?? png;
  }
  console.log(JSON.stringify({ png: out, editor: editor?.rect }));
} else if (cmd === "ctl") {
  console.log(JSON.stringify(serve.ctl(...rest)));
} else if (cmd === "bang") {
  // A local `!` shell command in omp's composer: typed, then sent only once the composer reads exactly that text and
  // starts with `!` (never a prompt for the model); else the composer is cleared.
  const text = rest.join(" ");
  if (!text.startsWith("!")) throw new Error("only ! commands");
  serve.ctl("click", ".tn-pane.on .sf-editor");
  serve.ctl("type", `"${text}"`);
  await sleep(500);
  const seen = serve.tree(".tn-pane.on .sf-editor")[0]?.text ?? "";
  if (seen === text && seen.startsWith("!")) {
    serve.ctl("key", "Enter");
    console.log("sent " + seen);
  } else {
    serve.ctl("key", "ctrl+a");
    serve.ctl("key", "Backspace");
    console.log("NOT SENT, composer read " + JSON.stringify(seen));
  }
} else if (cmd === "log") {
  console.log(pluginLog(profile).join("\n"));
} else if (cmd === "quit") {
  serve.ctl("quit");
} else {
  console.error("unknown command");
  process.exit(2);
}
