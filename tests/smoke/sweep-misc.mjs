#!/usr/bin/env node
// QA sweep only: the quota details, the settings panel, the widget bar's gauge, light theme, narrow and short panes,
// and omp's extension statuses switched off, against a `sweep.mjs start` serve.
//   node tests/smoke/sweep-misc.mjs PORT [only,names]
import { execFileSync } from "node:child_process";
import { appendFileSync, copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as F from "./fixtures.mjs";
import { crop, Profile, Serve, sleep, waitFor } from "./lib.mjs";
import { build } from "./sweep-caches.mjs";

const ROOT = process.env.QA_SWEEP_DIR ?? join(tmpdir(), "qa-sweep");
const port = Number(process.argv[2]);
const only = process.argv[3] ? new Set(process.argv[3].split(",")) : null;
const profile = new Profile(join(ROOT, `prof-${port}`));
const serve = new Serve(profile, port, "x");
const ev = join(ROOT, "ev", "misc");
mkdirSync(ev, { recursive: true });
const CHIPS = ".tn-pane.on .sf-col[data-role^='omp.editor'] > .sf-row[data-role='omp.composer.chips']";
const HOST_SEL = `${CHIPS}:is(.sf-hidden, .sf-void), ${CHIPS} > .sf-card:first-child > .sf-card-head > .sf-card-end:is(.sf-hidden, .sf-void)`;
const AGENT_HOST = HOST_SEL.replaceAll(".tn-pane.on", ".tn-pane.agent");

function record(name, pass, seen, evidence = []) {
  const entry = { label: "misc", name, pass, problems: pass ? [] : [seen], seen, evidence };
  appendFileSync(join(ROOT, "results.jsonl"), JSON.stringify(entry) + "\n");
  console.log(`${pass ? "PASS" : "FAIL"} misc ${name}\n   ${String(seen).replaceAll("\n", "\n   ")}`);
}
function shot(name, box) {
  const png = serve.shot(`misc-${name}`);
  const c = box ? crop(png, box, 0) ?? png : png;
  const out = join(ev, `${name}.png`);
  copyFileSync(c, out);
  return out;
}
const kvReset = () => {
  const patch = {};
  for (const k of ["style", "place", "align", "metric", "line-parts", "backdrop", "mode", "selected", "account", "pace", "card-rows", "order", "hidden", "account-order", "account-hidden", "plan-hidden", "colors", "usage-opens"]) patch[`omp-usage.${k}`] = undefined;
  profile.writeKv(patch);
};
const nums = (s) => [...String(s).matchAll(/(>99|<1|\d+)%/g)].map((m) => m[1]);
async function line(test, timeout = 25_000) {
  return waitFor(() => {
    const v = profile.view();
    return v.line && test(v) ? v : null;
  }, timeout, 250);
}
// the drawn text of the canvas pane (details or panel), when it matches: its surface's elements' texts joined (the
// region's own text starts with the spec Tern keeps beside it, and is cut short)
function canvasText(re) {
  const text = serve.tree(".tn-pane:not(.agent) .sf-region.sf-main .sf-el").map((n) => n.text ?? "").filter((t) => t && !/\{"v":/.test(t)).join(" ");
  return text && re.test(text) ? text : null;
}
const canvases = () => serve.tree(".tn-pane:not(.agent)").length;
// Tern (0.9.36) panes have no close button to click: the pane that isn't omp's takes focus (a glimpse has it already;
// the settings panel opens at the right) and `ctl close` closes the focused one.
function closeOther() {
  if (!serve.tree(".tn-pane:not(.agent).on").length) serve.ctl("focus", "right");
  if (serve.tree(".tn-pane:not(.agent).on").length) serve.ctl("close");
}
// The README's key for the details first: Tern's Close block (Ctrl+Shift+W, which a headless serve takes as
// Meta+Shift+W), pressed only while the canvas has the focus, since it closes whichever pane does; returns whether
// that closed it. Esc isn't tried: Tern gives a canvas no keys. Then the pane itself.
async function closeCanvas() {
  if (serve.tree(".tn-pane:not(.agent).on").length) serve.ctl("key", "Meta+Shift+W");
  await sleep(800);
  const byKey = canvases() === 0;
  for (let i = 0; i < 3 && canvases(); i += 1) {
    closeOther();
    await sleep(800);
  }
  serve.ctl("focus", "left");
  await sleep(300);
  return byKey;
}
async function openPanel() {
  serve.ctl("palette", "omp Usage: Settings panel");
  await sleep(800);
  if (!(serve.tree(".tn-pl-item.sel")[0]?.text ?? "").startsWith("omp Usage: Settings panel")) {
    serve.ctl("key", "Escape");
    return null;
  }
  serve.ctl("key", "Enter");
  return waitFor(() => canvasText(/Display|Card height/), 15_000, 300);
}

const scenarios = {};

scenarios.details = async () => {
  for (const [name, cache, kv, test, age = 0] of [
    ["single-left", "single", {}, (t) => /62% left/.test(t)],
    ["single-used", "single", { "omp-usage.metric": "used" }, (t) => /38% used/.test(t)],
    ["multi-only-bob", "multi", { "omp-usage.account": { anthropic: "bob" } }, (t) => /bob/.test(t)],
    ["multi-hidden-5h", "multi", { "omp-usage.hidden": { anthropic: ["5h"] } }, (t) => /Weekly/.test(t)],
    ["sources-all", "sources", { "omp-usage.mode": "all" }, (t) => /dashboard/.test(t)],
    // D7: the stale Keeper account says so in the details (and the card, checked in the data plan)
    ["keeper-stale-bob", "sources", { "omp-usage.mode": "selected", "omp-usage.selected": ["keeper:dashboard:anthropic"] }, (t) => /bob[\s\S]*stale/i.test(t)],
    ["edge-all", "edge", { "omp-usage.mode": "all" }, (t) => /Codex/.test(t)],
    ["age-14m-all", "single", { "omp-usage.mode": "all" }, (t) => /as of 1\dm ago/.test(t), 14],
  ]) {
    kvReset();
    profile.writeKv(kv);
    profile.writeCache(await build(cache, Date.now(), age));
    await sleep(4000);
    const v = profile.view();
    serve.ctl("key", "shift+alt+u");
    const text = await waitFor(() => canvasText(/usage|window|left|used/i), 15_000, 300);
    const problems = [];
    if (!text) problems.push("the quota details didn't open on Alt+Shift+U");
    else {
      if (!test(text)) problems.push(`expected content missing`);
      // every share on the line is in the details too
      const missing = nums(v.line).filter((n) => !nums(text).includes(n));
      if (missing.length) problems.push(`line shares ${JSON.stringify(missing)} not in the details`);
      if (kv["omp-usage.account"]?.anthropic === "bob" && /alice|carol/.test(text)) problems.push("details show accounts the line leaves out (only bob picked)");
      if (kv["omp-usage.hidden"] && /5-hour|5h window/i.test(text)) problems.push("details show a hidden window");
    }
    const png = shot(`details-${name}`, null);
    const byKey = await closeCanvas();
    if (!byKey) problems.push("Ctrl+Shift+W (Tern's Close block) didn't close the focused details (README: click outside it, click Close, or press Ctrl+Shift+W); closed with `ctl close`");
    if (canvases() !== 0) problems.push("the details wouldn't close");
    record(`details ${name}`, problems.length === 0, `${problems.join("; ") || "ok"}\nline: ${v.line}\ndetails: ${(text ?? "").slice(0, 600)}`, [png]);
  }
  kvReset();
};

scenarios.panel = async () => {
  profile.writeCache(await build("multi"));
  kvReset();
  await sleep(3000);
  serve.ctl("key", "ctrl+alt+u");
  const byKey = await waitFor(() => canvasText(/Display|Card height/), 6_000, 300);
  const text = byKey ?? (await openPanel());
  await sleep(1500);
  const problems = [];
  if (!byKey) problems.push("Ctrl+Alt+U didn't open the panel headless (the palette did)");
  if (!text) problems.push("the settings panel didn't open from the palette either");
  // the line stays drawn in the agent pane beside the focused panel (its composer folds, so it has no hover target)
  const sheet = profile.view().css;
  if (!sheet.includes(".tn-pane.agent")) problems.push("the line's sheet doesn't follow the agent pane while the panel has focus");
  for (const word of ["Display", "Style", "Position", "On the line", "Shares", "Card height", "Line background", "Show pace", "Widget bar", "Alerts", "Updates"]) {
    if (text && !text.includes(word)) problems.push(`panel has no "${word}"`);
  }
  const png = shot("panel-open", null);
  record("settings panel opens; the line stays drawn beside it", problems.length === 0, `${problems.join("; ") || "ok"}\n${(text ?? "").slice(0, 900)}`, [png]);
  await closeCanvas();
};

scenarios.widget = async () => {
  serve.ctl("widgets", "set", "status");
  kvReset();
  const find = () => serve.tree("#widgetbar .wg-seg").find((n) => /^plugin\.omp-usage\.(panel|details)$/.test(n.title ?? "")) ?? null;
  const t = Date.now();
  profile.writeCache(F.doc(t, { claude: F.claude(t, { r5: 0.2, in5: 2 * F.H, r7: 0.2, in7: 3.5 * F.D }) }));
  // this cache's line first: the previous scenario's cache can still be warning
  await line((v) => /^Claude  5H [^·]*20% left/.test(v.line), 30_000);
  await sleep(3000);
  const seg = await waitFor(() => {
    const s = find();
    return s && /pace/.test(s.text ?? "") ? s : null;
  }, 40_000, 300);
  const problems = [];
  if (!seg) problems.push(`no pace warning: segment ${JSON.stringify(find())}`);
  const png = seg ? shot("widget-ahead", [seg.rect[0] - 200, seg.rect[1] - 20, 420, 60]) : null;
  // its click opens the settings panel
  if (seg) {
    serve.ctl("click", Math.round(seg.rect[0] + seg.rect[2] / 2), Math.round(seg.rect[1] + seg.rect[3] / 2));
    const panel = await waitFor(() => canvasText(/Display|Card height/), 10_000, 300);
    if (!panel) problems.push("clicking the gauge didn't open the settings panel");
    await closeCanvas();
  }
  profile.writeKv({ "omp-usage.usage-opens": "details" });
  const seg2 = await waitFor(() => (find()?.title === "plugin.omp-usage.details" ? find() : null), 20_000, 300);
  if (!seg2) problems.push(`gauge's click target didn't switch to the quota details: ${find()?.title}`);
  else {
    serve.ctl("click", Math.round(seg2.rect[0] + seg2.rect[2] / 2), Math.round(seg2.rect[1] + seg2.rect[3] / 2));
    const det = await waitFor(() => canvasText(/window/i), 10_000, 300);
    if (!det || /Card height/.test(det)) problems.push("clicking the gauge set to Quota details didn't open them");
    await closeCanvas();
  }
  // the warning and the card agree: the card's furthest-ahead pace row names the same rate
  const v = profile.view();
  const rate = /(\d+\.\d)× pace/.exec(seg?.text ?? "")?.[1];
  const rates = [...(v.card ?? "").matchAll(/(\d+\.\d)× pace/g)].map((m) => m[1]);
  if (rate && !rates.includes(rate)) problems.push(`widget says ${rate}× but the card's pace rows say ${JSON.stringify(rates)}`);
  record("widget gauge: warning, click opens panel, then details", problems.length === 0, `${problems.join("; ") || "ok"}\nsegment: ${seg?.text}\ncard pace rows: ${JSON.stringify(rates)}`, png ? [png] : []);
  kvReset();
};

scenarios.light = async () => {
  profile.writeCache(await build("multi"));
  serve.ctl("appearance", "light");
  const shots = [];
  for (const [place, align, style] of [["above", "right", "instrument"], ["below", "right", "blocks"], ["stack", "right", "ring"], ["stack", "left", "compact"]]) {
    kvReset();
    profile.writeKv({ "omp-usage.place": place, "omp-usage.align": align, "omp-usage.style": style, "omp-usage.line-parts": { plan: true } });
    await sleep(4500);
    const ed = serve.tree(".tn-pane.on .sf-col[data-role^='omp.editor']")[0]?.rect;
    const pane = serve.tree(".tn-pane.on")[0]?.rect;
    serve.ctl("move", 5, 5);
    await sleep(400);
    shots.push(shot(`light-${place}-${align}-${style}`, ed && pane ? [pane[0], ed[1] - 120, pane[2], 170] : null));
    serve.ctl("hover", HOST_SEL);
    await sleep(1800);
    shots.push(shot(`light-${place}-${align}-${style}-hover`, ed && pane ? [pane[0], Math.max(pane[1], ed[1] - 520), pane[2], 580] : null));
  }
  serve.ctl("appearance", "dark");
  kvReset();
  record("light theme, each position (by eye)", true, "shots only", shots);
};

// What a pair of 2x shots (at rest, hovered) show of the line and its card, measured in CSS px: where the three dots
// that end a cut line are (2px squares 1px apart on rows 9-10 of the line's 13px box, whose top is 1px under the
// target's, with nothing right above them, unlike a letter), and the box of what the hover added above the target:
// the card. A pseudo-element's text and box aren't in `ctl tree`, so the pixels are the measure.
const MEASURE = `
import sys, json
from PIL import Image, ImageChops
rest, hover, spec = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
a = Image.open(rest).convert("RGB"); b = Image.open(hover).convert("RGB")
hx, hy, hw, hh = spec["host"]
def dots(im):
    y = int(round((hy + 1 + 9.5) * 2)); up = int(round((hy + 1 + 5) * 2))
    x0 = int(hx * 2); x1 = min(im.size[0], int((hx + hw) * 2))
    if y >= im.size[1] or x1 - x0 < 16: return None
    row = [max(im.getpixel((x, y))) for x in range(x0, x1)]
    top = [max(im.getpixel((x, up))) for x in range(x0, x1)]
    ground = sorted(row)[len(row) // 4]
    on = [v - ground > 28 for v in row]
    runs = []; i = 0
    while i < len(on):
        j = i
        while j < len(on) and on[j] == on[i]: j += 1
        runs.append((on[i], i, j - i)); i = j
    for k in range(len(runs) - 4):
        r = runs[k:k + 5]
        if [x[0] for x in r] != [True, False, True, False, True]: continue
        if not all(3 <= x[2] <= 5 for x in r[0::2]) or not all(1 <= x[2] <= 3 for x in r[1::2]): continue
        s, e = r[0][1], r[4][1] + r[4][2]
        if all(v - ground <= 28 for v in top[s:e]) and (k + 5 >= len(runs) or runs[k + 5][2] >= 4):
            return round(hx + s / 2, 1)
    return None
diff = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 24 else 0)
box = diff.crop((0, 0, diff.size[0], max(1, int((hy - 2) * 2)))).getbbox()
print(json.dumps({"dotsRest": dots(a), "dotsHover": dots(b), "card": [v / 2 for v in box] if box else None}))
`;
function measure(rest, hover, host) {
  try {
    return JSON.parse(execFileSync("python", ["-c", MEASURE, rest, hover, JSON.stringify({ host })], { encoding: "utf8", timeout: 60_000 }));
  } catch (err) {
    return { error: String(err.message).slice(0, 200) };
  }
}

// Narrow and short panes, each position, with nine windows on the line (three accounts): the target stays in the
// pane; a single line always ends in its three dots, at rest and hovered; under the width its first window's share
// needs, the sheet's narrow copy shows instead; and the hover card stays inside the pane at both sides. 353 and 263
// are the half panes (347 and 257px) a split leaves of a 700 and a 520px window.
scenarios.narrow = async () => {
  profile.writeCache(await build("multi"));
  const shots = [];
  const problems = [];
  const rows = [];
  for (const [w, h] of [[300, 640], [470, 640], [520, 640], [700, 640], [900, 640], [353, 640], [263, 640], [1400, 260]]) {
    serve.ctl("size", w, h);
    for (const [place, align] of [["above", "right"], ["below", "right"], ["stack", "right"], ["stack", "left"]]) {
      const cell = `${w}x${h} ${place}-${align}`;
      kvReset();
      profile.writeKv({ "omp-usage.place": place, "omp-usage.align": align });
      await sleep(4500);
      const pane = serve.tree(".tn-pane.on")[0]?.rect;
      const host = serve.tree(HOST_SEL)[0]?.rect;
      const ed = serve.tree(".tn-pane.on .sf-col[data-role^='omp.editor']")[0]?.rect;
      const meter = serve.tree(".tn-pane.on .sf-meter[data-role='omp.composer.context']")[0]?.rect;
      if (!host) problems.push(`${cell}: no target`);
      else if (pane && (host[0] < pane[0] - 0.5 || host[0] + host[2] > pane[0] + pane[2] + 0.5 || host[1] < pane[1])) problems.push(`${cell}: target ${JSON.stringify(host)} leaves the pane ${JSON.stringify(pane)}`);
      if (host && ed && (host[0] < ed[0] - 16 || host[0] + host[2] > ed[0] + ed[2] + 16)) problems.push(`${cell}: target ${JSON.stringify(host)} runs past the composer ${JSON.stringify(ed)}`);
      serve.ctl("move", 5, 5);
      await sleep(300);
      const rest = serve.shot(`misc-size-${w}x${h}-${place}-${align}`);
      serve.ctl("hover", HOST_SEL);
      await sleep(1800);
      const hover = serve.shot(`misc-size-${w}x${h}-${place}-${align}-hover`);
      const out = (png, box, suffix) => {
        const to = join(ev, `size-${w}x${h}-${place}-${align}${suffix}.png`);
        copyFileSync((box && crop(png, box, 0)) || png, to);
        shots.push(to);
      };
      out(rest, pane && ed ? [pane[0], Math.max(pane[1], ed[1] - 140), pane[2], 200] : null, "");
      out(hover, pane, "-hover");
      if (!host || !pane || !meter) continue;
      // the width under which the sheet draws the narrow copy (the line's paint goes from there)
      const css = profile.view().css;
      const under = Number(/background-size: clamp\(0px, calc\(\(100% - ([\d.]+)px\) \* 1000000\)/.exec(css)?.[1] ?? NaN) + 0.25;
      const single = place !== "stack";
      const shows = !single ? "stacked rows" : meter[2] < under ? "narrow copy" : "line";
      const m = measure(rest, hover, host);
      rows.push(`${cell}: pane ${pane[2]} meter ${meter[2]} target ${host[2]} · ${shows}${single ? ` (copy under ${under})` : ""} · dots at ${m.dotsRest ?? "none"} / hovered ${m.dotsHover ?? "none"} · card x ${m.card ? `${m.card[0]}..${m.card[2]}` : "none"} in pane ${pane[0]}..${pane[0] + pane[2]}`);
      if (m.error) problems.push(`${cell}: couldn't measure the shots: ${m.error}`);
      if (single && m.dotsRest == null) problems.push(`${cell}: windows are missing from the line and no dots say so`);
      if (single && m.dotsHover == null) problems.push(`${cell}: hovered, no dots`);
      if (!m.card) problems.push(`${cell}: no card opened`);
      else if (m.card[0] < pane[0] + 1 || m.card[2] > pane[0] + pane[2] - 1) problems.push(`${cell}: the card (${m.card[0]}..${m.card[2]}) reaches the pane's edge (${pane[0]}..${pane[0] + pane[2]}): cut off there`);
    }
  }
  serve.ctl("size", 1400, 640);
  kvReset();
  record("narrow and short panes, each position: dots, narrow copy and card measured", problems.length === 0, `${problems.join("\n") || "ok"}\n${rows.join("\n")}`, shots);
};

// omp's extension statuses off (statusLine.showHookStatus: false in the overlay; omp re-reads it): the line comes
// from the cache alone, and with an old cache there's none (README: the fallback needs the statuses).
scenarios.hookstatus = async () => {
  const overlay = join(profile.root, "overlay.yml");
  const before = readFileSync(overlay, "utf8");
  writeFileSync(overlay, before.replace("showHookStatus: true", "showHookStatus: false"));
  kvReset();
  profile.writeCache(await build("single"));
  await sleep(9000);
  const facts = () => serve.tree(".tn-pane.on [data-role='omp.composer.bar'] [data-id*='/hook-'], .tn-pane.on [data-role='omp.composer.bar'] [data-id$='/status']").map((n) => n.text ?? "");
  const off = facts();
  const fresh = await line((v) => /62% left/.test(v.line));
  profile.writeCache(await build("single", Date.now(), 31));
  const stale = await waitFor(() => (profile.view().css.trim() === "" || !/content:/.test(profile.view().css) ? true : null), 30_000, 300);
  const staleView = profile.view();
  const pngStale = shot("hookstatus-off-stale", null);
  writeFileSync(overlay, before);
  await sleep(9000);
  const back = await line((v) => /33% left/.test(v.line), 30_000);
  profile.writeCache(await build("single"));
  const problems = [];
  if (off.some((t) => /% left|demo/.test(t))) problems.push(`statuses still in omp's bar: ${JSON.stringify(off)}`);
  if (!fresh) problems.push("no line from a fresh cache with statuses off");
  if (!stale) problems.push(`a line with statuses off and a 31-min cache: ${staleView.line}`);
  if (!back) problems.push("statuses back on: no fallback to the status");
  record("omp statuses off: cache-only line; none once it's old; fallback again with statuses on", problems.length === 0, `${problems.join("; ") || "ok"}\nbar facts with statuses off: ${JSON.stringify(off)}\nfresh: ${fresh?.line}\nback on, old cache: ${back?.line}`, [pngStale]);
};

// Alerts in one window: two quota windows crossing together share one toast (`Also …`), an expiring saved reset
// toasts once, and nothing toasts again on the next polls.
scenarios.alerts = async () => {
  kvReset();
  const t = Date.now();
  profile.writeCache(F.doc(t, { claude: F.claude(t, { r5: 0.5, r7: 0.5 }), resets: [] }));
  profile.writeKv({ "omp-usage.alerts": true, "omp-usage.alerts-seen": undefined, "omp-usage.alerts-seed": true, "omp-usage.alerts-claim": undefined });
  await sleep(20_000);
  const seen = [];
  const watch = async (ms) => {
    const until = Date.now() + ms;
    while (Date.now() < until) {
      for (const node of serve.tree(".toast")) {
        const text = node.text ?? "";
        if (/Claude/.test(text) && !seen.includes(text)) seen.push(text);
      }
      await sleep(400);
    }
  };
  const t2 = Date.now();
  // 5h and 7d both fall to 20% at once, and a saved reset expires in 6 hours
  profile.writeCache(F.doc(t2, { claude: F.claude(t2, { r5: 0.2, r7: 0.2 }), resets: [{ expiresAt: t2 + 6 * F.H, count: 1, window: "7d" }] }));
  await watch(45_000);
  const first = [...seen];
  const png = shot("alerts-together", null);
  await watch(35_000);
  const problems = [];
  if (first.length === 0) problems.push("no toast for two windows crossing 25%");
  if (first.length > 2) problems.push(`${first.length} toasts for one check (two windows and a saved reset): ${JSON.stringify(first)}`);
  if (!first.some((t) => /Also/.test(t))) problems.push(`the second window isn't in the same toast (no "Also"): ${JSON.stringify(first)}`);
  if (seen.length !== first.length) problems.push(`more toasts on later polls: ${JSON.stringify(seen.slice(first.length))}`);
  profile.writeKv({ "omp-usage.alerts": undefined });
  record("alerts: two windows crossing together share a toast; nothing repeats", problems.length === 0, `${problems.join("; ") || "ok"}\ntoasts: ${JSON.stringify(seen)}`, [png]);
};

for (const [name, fn] of Object.entries(scenarios)) {
  if (only && !only.has(name)) continue;
  try {
    // each scenario starts from the omp pane alone, with nothing left open by the one before
    for (let i = 0; i < 4 && canvases(); i += 1) {
      closeOther();
      await sleep(800);
    }
    serve.ctl("focus", "left");
    serve.ctl("size", 1400, 640);
    await fn();
  } catch (err) {
    record(name, false, `error: ${err.stack ?? err}`);
  }
}
console.log("DONE misc");
