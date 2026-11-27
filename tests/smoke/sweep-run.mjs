#!/usr/bin/env node
// QA sweep only: one plan against a running `sweep.mjs start` serve. Sets each cell's state (plugin settings, the
// overlay's row above the composer, an attachment chip), waits for the plugin's sheet to say it, measures the
// composer's geometry, checks the line's hover target against everything around it, and shoots it.
//   node tests/smoke/sweep-run.mjs PORT PLAN_JSON
// PLAN: { label, cells: [{ kv, row, chips }], hover: bool, out } — results go to QA_SWEEP_DIR/results.jsonl, shots to
// QA_SWEEP_DIR/ev/<label>/.
import { appendFileSync, copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { crop, Profile, Serve, sleep, waitFor } from "./lib.mjs";

const ROOT = process.env.QA_SWEEP_DIR ?? join(tmpdir(), "qa-sweep");
const [, , portArg, planArg] = process.argv;
const port = Number(portArg);
const plan = JSON.parse(planArg);
const profile = new Profile(join(ROOT, `prof-${port}`));
const serve = new Serve(profile, port, "x");
const ev = join(ROOT, "ev", plan.label);
mkdirSync(ev, { recursive: true });

const CHIPS = ".tn-pane.on .sf-col[data-role^='omp.editor'] > .sf-row[data-role='omp.composer.chips']";
const HOST_SEL = `${CHIPS}:is(.sf-hidden, .sf-void), ${CHIPS} > .sf-card:first-child > .sf-card-head > .sf-card-end:is(.sf-hidden, .sf-void)`;
const EDITOR_SEL = ".tn-pane.on .sf-col[data-role^='omp.editor']";
const ROWS = {
  none: null,
  progress: ["Optimizing skills failed: QA progress row, as omp's own sits right above the composer"],
  widget: ["QA widget line 1: an extension's widget above the editor", "QA widget line 2", "QA widget line 3"],
};
const KEYS = ["style", "place", "align", "metric", "line-parts", "backdrop", "mode", "selected", "account", "pace", "card-rows", "order", "hidden", "account-order", "account-hidden", "plan-hidden", "colors", "show-pace"];

const ctlPath = join(profile.root, "ctl.json");
function setCtl(patch) {
  let cur = {};
  try {
    cur = JSON.parse(readFileSync(ctlPath, "utf8"));
  } catch {}
  const next = { ...cur, ...patch };
  for (const [k, v] of Object.entries(next)) if (v === undefined || v === null) delete next[k];
  writeFileSync(ctlPath, JSON.stringify(next));
}

const pick = (sel) => serve.tree(sel).map((n) => ({ rect: n.rect, cls: n.class ?? "", text: n.text ?? "" }));
function geo() {
  const widgetNodes = pick(".tn-pane.on .sf-dock *").filter((n) => /^(QA widget|Optimizing skills failed)/.test(n.text));
  const activity = pick(".tn-pane.on [data-role='omp.hud.activity']")[0] ?? null;
  const labels = pick(".tn-pane.on .sf-meter[data-role='omp.composer.context'] *").filter((n) => /\S/.test(n.text) && n.rect[3] > 2);
  return {
    pane: pick(".tn-pane.on")[0]?.rect ?? null,
    dockCls: pick(".tn-pane.on .sf-dock")[0]?.cls ?? "",
    editor: pick(EDITOR_SEL)[0]?.rect ?? null,
    input: pick(".tn-pane.on .sf-editor")[0]?.rect ?? null,
    meter: pick(".tn-pane.on .sf-meter[data-role='omp.composer.context']")[0]?.rect ?? null,
    labels: labels.map((n) => ({ rect: n.rect, text: n.text })),
    host: pick(HOST_SEL)[0]?.rect ?? null,
    chips: pick(".tn-pane.on [data-role='omp.composer.chips'] > .sf-card").map((n) => n.rect),
    widget: widgetNodes.length ? union(widgetNodes.map((n) => n.rect)) : null,
    activity: activity && !/sf-void|sf-hidden/.test(activity.cls) && /\S/.test(activity.text.replace(/\+0$/, "")) ? textRect(".tn-pane.on [data-role='omp.hud.activity'] *", activity.rect) : null,
    tray: pick(".tn-pane.on .sf-col.sf-tray")[0] ?? null,
    // the tray's cards take room only in its full and row tiers (the dots tier keeps them at height 0)
    trayCards: /tier-(full|row)/.test(pick(".tn-pane.on .sf-col.sf-tray")[0]?.cls ?? "") && !/\bclosed\b/.test(pick(".tn-pane.on .sf-col.sf-tray")[0]?.cls ?? "")
      ? pick(".tn-pane.on .sf-tray-card").map((n) => n.rect).filter((r) => r[2] > 0 && r[3] > 0)
      : [],
    pips: pick(".tn-pane.on .sf-tray-dots > .sf-tray-pip").map((n) => n.rect),
  };
}
// The inked part of the activity row: its children with text.
function textRect(sel, fallback) {
  const kids = pick(sel).filter((n) => /\S/.test(n.text) && n.rect[2] > 0 && n.rect[3] > 0 && !/^\+0$/.test(n.text));
  return kids.length ? union(kids.map((n) => n.rect)) : fallback;
}
function union(rects) {
  const x0 = Math.min(...rects.map((r) => r[0]));
  const y0 = Math.min(...rects.map((r) => r[1]));
  const x1 = Math.max(...rects.map((r) => r[0] + r[2]));
  const y1 = Math.max(...rects.map((r) => r[1] + r[3]));
  return [x0, y0, x1 - x0, y1 - y0];
}
function overlap(a, b) {
  if (!a || !b) return 0;
  const w = Math.min(a[0] + a[2], b[0] + b[2]) - Math.max(a[0], b[0]);
  const h = Math.min(a[1] + a[3], b[1] + b[3]) - Math.max(a[1], b[1]);
  return w > 0.5 && h > 0.5 ? Math.round(w * 10) / 10 + "x" + Math.round(h * 10) / 10 : 0;
}

// What the sheet must say for a cell's settings to be the ones drawn.
function drawnFor(kv) {
  const style = kv["omp-usage.style"] ?? "instrument";
  const place = kv["omp-usage.place"] ?? "above";
  const align = kv["omp-usage.align"] ?? "right";
  const metric = kv["omp-usage.metric"] ?? "left";
  const parts = kv["omp-usage.line-parts"] ?? {};
  return (v) => {
    if (!v.line) return false;
    const css = v.css;
    const stacked = css.includes("max-width: 100%;");
    if ((place === "stack") !== stacked) return false;
    if (place === "stack" && !css.includes(align === "right" ? "left: auto;\n\tright: 0;" : "left: 0;\n\tright: auto;")) return false;
    if (place === "below" && !/\.sf-dock\.sf-tray-ctx > \.sf-col\.sf-tray \{\n\tpadding-top/.test(css)) return false;
    if (place === "above" && !css.includes(".sf-col.sf-tray.under {")) return false;
    const has = { instrument: /━/, blocks: /[▰▱]/, ring: /[○◔◑◕●]/ };
    const barOn = parts.bar !== false && style !== "compact";
    for (const [s, re] of Object.entries(has)) {
      // a stacked Instrument bar is painted over blanks (render.luau stack_of: `boxed`)
      if (barOn && s === style && !(s === "instrument" && place === "stack") && !re.test(v.line)) return false;
      if ((s !== style || !barOn) && re.test(v.line)) return false;
    }
    // shares say the metric's word, except where the line goes compact (several providers, Compact): never the
    // other one's
    if (parts.share !== false || !barOn) {
      const other = metric === "used" ? /\d% left/ : /\d% used/;
      if (other.test(v.line)) return false;
    }
    return true;
  };
}

function checks(g, cell) {
  const place = cell.kv["omp-usage.place"] ?? "above";
  const align = cell.kv["omp-usage.align"] ?? "right";
  const out = [];
  const bad = (what) => out.push(what);
  const h = g.host;
  if (!h || h[2] <= 0 || h[3] <= 0) {
    bad(`no hover target (${JSON.stringify(h)})`);
    return out;
  }
  if (g.pane && (h[0] < g.pane[0] - 0.5 || h[0] + h[2] > g.pane[0] + g.pane[2] + 0.5 || h[1] < g.pane[1] - 0.5)) bad(`target ${JSON.stringify(h)} outside pane ${JSON.stringify(g.pane)}`);
  for (const l of g.labels) {
    const o = overlap(h, l.rect);
    if (o) bad(`target overlaps context label "${l.text}" ${JSON.stringify(l.rect)} by ${o}`);
  }
  const o1 = overlap(h, g.widget);
  if (o1) bad(`target overlaps the row above ${JSON.stringify(g.widget)} by ${o1}`);
  const o2 = overlap(h, g.activity);
  if (o2) bad(`target overlaps the working row text ${JSON.stringify(g.activity)} by ${o2}`);
  for (const c of g.trayCards) {
    const o = overlap(h, c);
    if (o) bad(`target overlaps a tray card ${JSON.stringify(c)} by ${o}`);
  }
  for (const p of g.pips) {
    const o = overlap(h, p);
    if (o) bad(`target overlaps a tray pip ${JSON.stringify(p)} by ${o}`);
  }
  for (const c of g.chips) {
    const o = overlap(h, c);
    if (o) bad(`target overlaps an attachment chip ${JSON.stringify(c)} by ${o}`);
  }
  if (g.input) {
    const o = overlap(h, g.input);
    if (o) bad(`target overlaps the input ${JSON.stringify(g.input)} by ${o}`);
  }
  // the row above against the working row and the tray (omp's own layout, but the plugin's room rules move them)
  if (g.widget && g.activity) {
    const o = overlap(g.widget, g.activity);
    if (o) bad(`row above overlaps the working row by ${o}`);
  }
  if (g.editor && g.meter) {
    const spine = g.dockCls.includes("sf-chat-spine");
    if (place === "below" && !spine) {
      if (h[1] + 0.5 < g.meter[1] + g.meter[3] - 3) bad(`Under the bar: target top ${h[1]} above the hairline (meter ${JSON.stringify(g.meter)})`);
    }
    if ((place === "above" || place === "stack") && !spine) {
      if (h[1] + h[3] > g.meter[1] + 1.5) bad(`target bottom ${h[1] + h[3]} below the meter top ${g.meter[1]}`);
    }
    if (place === "stack") {
      const mid = g.editor[0] + g.editor[2] / 2;
      if (align === "right" ? h[0] + h[2] / 2 < mid : h[0] + h[2] / 2 > mid) bad(`stacked ${align}: target ${JSON.stringify(h)} on the wrong side of ${mid}`);
    }
  }
  return out;
}

async function setChips(n) {
  const have = pick(".tn-pane.on [data-role='omp.composer.chips'] > .sf-card").length;
  if (n > 0 && have === 0) {
    const input = pick(".tn-pane.on .sf-editor")[0]?.rect;
    const png = join(ROOT, "qa-attach.png").replaceAll("\\", "/");
    serve.ctl("drop", Math.round(input[0] + input[2] / 2), Math.round(input[1] + input[3] / 2), "file", `"${png}"`);
    await waitFor(() => pick(".tn-pane.on [data-role='omp.composer.chips'] > .sf-card").length > 0, 10_000, 250);
  } else if (n === 0 && have > 0) {
    serve.ctl("click", ".tn-pane.on .sf-editor");
    serve.ctl("key", "ctrl+a");
    serve.ctl("key", "Backspace");
    await waitFor(() => pick(".tn-pane.on [data-role='omp.composer.chips'] > .sf-card").length === 0, 10_000, 250);
  }
  // nothing is ever sent: the composer must not hold text that isn't an attachment's token
}

const results = [];
let kvNow = {};
for (const [i, cell] of plan.cells.entries()) {
  const name = `${String(i).padStart(3, "0")}-${cell.name}`;
  // the sheet before this cell's writes: a cell is judged on a sheet drawn after them (or, when nothing it shows
  // changed, on the same one once a poll or two has gone by)
  const before = profile.sheet("usage");
  // settings: the cell's, the rest back to their defaults
  const patch = {};
  for (const key of KEYS) patch[`omp-usage.${key}`] = undefined;
  Object.assign(patch, cell.kv);
  profile.writeKv(patch);
  kvNow = cell.kv;
  if (cell.row !== undefined) setCtl({ widget: ROWS[cell.row] ?? null });
  if (cell.ctl) setCtl(cell.ctl);
  if (cell.chips !== undefined) await setChips(cell.chips);
  if (cell.cache) {
    const { build } = await import("./sweep-caches.mjs");
    profile.writeCache(await build(cell.cache, Date.now(), cell.age ?? 0));
  }
  // first-version, oversize and missing caches (fixtures.mjs, as the matrix writes them)
  if (cell.fixture) {
    const F = await import("./fixtures.mjs");
    const now = Date.now();
    if (cell.fixture === "v1") profile.writeCache(F.doc(now, { v1: true, claude: F.claude(now, { r5: 0.57, r7: 0.44 }) }));
    else if (cell.fixture === "oversize") profile.writeCache(JSON.stringify({ ...F.doc(now, { claude: F.claude(now, { r5: 0.1 }) }), padding: "x".repeat(1100 * 1024) }));
    else if (cell.fixture === "missing") rmSync(profile.cachePath, { force: true });
    else if (cell.fixture === "garbage") profile.writeCache("{ not json");
  }
  if (cell.status !== undefined) profile.setStatus(cell.status);
  for (const args of cell.app ?? []) serve.ctl(...args);
  if (cell.size) serve.ctl("size", cell.size[0], cell.size[1]);
  const t0 = Date.now();
  const test = drawnFor(cell.kv);
  const extra = cell.expect ? new RegExp(cell.expect) : null;
  const lineExtra = cell.lineExpect ? new RegExp(cell.lineExpect) : null;
  const cssExtra = cell.cssExpect ? new RegExp(cell.cssExpect) : null;
  const view = await waitFor(() => {
    const v = profile.view();
    const fresh = v.css !== (before ?? "") || Date.now() - t0 > (cell.grace ?? 3500);
    return fresh && test(v) && (!extra || extra.test(v.line + "\n" + (v.card ?? ""))) && (!lineExtra || lineExtra.test(v.line)) && (!cssExtra || cssExtra.test(v.css)) && (cell.dim === undefined || v.dim === cell.dim) ? v : null;
  }, cell.timeout ?? 25_000, 250);
  const drawnMs = Date.now() - t0;
  if (cell.row !== undefined) {
    const wantRow = ROWS[cell.row];
    await waitFor(() => {
      const w = pick(".tn-pane.on .sf-dock *").some((n) => /^(QA widget|Optimizing skills failed)/.test(n.text));
      return Boolean(wantRow) === w ? true : null;
    }, 10_000, 300);
  }
  await sleep(cell.settle ?? 1600);
  const g1 = geo();
  await sleep(cell.idle ?? 0);
  const g = cell.idle ? geo() : g1;
  const want = [cell.expect && `/${cell.expect}/`, cell.lineExpect && `line /${cell.lineExpect}/`, cell.cssExpect && `css /${cell.cssExpect}/`, cell.dim !== undefined && `dim ${cell.dim}`].filter(Boolean).join(", ");
  const problems = view ? checks(g, cell) : [`not drawn within ${drawnMs} ms${want ? ` (waiting for ${want})` : ""}; line: ${profile.view().line}\n   card: ${(profile.view().card ?? "").replaceAll("\n", " | ")}\n   dim: ${profile.view().dim}`];
  if (view && cell.lineNot && new RegExp(cell.lineNot).test(view.line)) problems.push(`line shows /${cell.lineNot}/: ${view.line.replaceAll("\n", " | ")}`);
  if (view && cell.cssNot && new RegExp(cell.cssNot).test(view.css)) problems.push(`sheet has /${cell.cssNot}/`);
  if (view && cell.cardRowsMax && (view.card ?? "").split("\n").length > cell.cardRowsMax) problems.push(`card has ${(view.card ?? "").split("\n").length} rows, over ${cell.cardRowsMax}`);
  if (view && cell.cardRowsMin && (view.card ?? "").split("\n").length < cell.cardRowsMin) problems.push(`card has ${(view.card ?? "").split("\n").length} rows, under ${cell.cardRowsMin}`);
  if (view && cell.notExpect && new RegExp(cell.notExpect).test(view.line + "\n" + (view.card ?? ""))) {
    problems.push(`saw /${cell.notExpect}/ that shouldn't show: line ${view.line.replaceAll("\n", " | ")} card ${(view.card ?? "").replaceAll("\n", " | ")}`);
  }
  // every share the line says is one the card says too (the card shows every window either way)
  if (view && view.card && cell.consistent !== false) {
    const nums = (s) => [...s.matchAll(/(>99|<1|\d+)%/g)].map((m) => m[1]);
    const card = nums(view.card);
    const missing = nums(view.line).filter((n) => !card.includes(n));
    if (missing.length) problems.push(`line shares ${JSON.stringify(missing)} not in the card (line ${view.line.replaceAll("\n", " | ")})`);
  }
  if (cell.idle) {
    for (const k of ["editor", "host", "meter"]) {
      if (JSON.stringify(g1[k]) !== JSON.stringify(g[k])) problems.push(`idle layout shift: ${k} ${JSON.stringify(g1[k])} → ${JSON.stringify(g[k])} over ${cell.idle} ms`);
    }
  }
  let parse = null;
  if (cell.parse) {
    const f = join(ev, `${name}.css`);
    writeFileSync(f, view?.css ?? "");
    const reply = serve.ctl("css", "probe:qa-check", f);
    serve.ctl("css", "probe:qa-check");
    parse = (reply.errors ?? []).length;
    if (!reply.ok || parse) problems.push(`sheet parse errors: ${JSON.stringify(reply.errors ?? reply).slice(0, 300)}`);
  }
  let shotPath = null;
  if (cell.shot !== false) {
    serve.ctl("move", 5, 5);
    await sleep(300);
    const png = serve.shot(`${plan.label}-${name}`);
    const box = g.editor && g.pane ? [g.pane[0], g.editor[1] - (cell.above ?? 130), g.pane[2], (cell.above ?? 130) + (cell.below ?? 50)] : null;
    const c = crop(png, box, 0) ?? png;
    shotPath = join(ev, `${name}.png`);
    copyFileSync(c, shotPath);
  }
  let hoverPath = null;
  if (cell.hover) {
    serve.ctl("hover", HOST_SEL);
    await sleep(1800);
    const h = g.host;
    const hit = h ? serve.ctl("pick", Math.round(h[0] + h[2] / 2), Math.round(h[1] + h[3] / 2)) : null;
    const path = String(hit?.path ?? "");
    // the target itself (the empty chips row or the first chip's end slot) must be what the pointer finds there; its
    // width may have moved with a redraw since it was measured
    const last = path.split(">").slice(-1)[0] ?? "";
    const isHost = /sf-card-end/.test(last) || (/sf-row/.test(last) && /sf-void|sf-hidden/.test(last) && hit?.rect?.[1] === h?.[1]);
    if (h && !isHost) problems.push(`hover target not hit at its centre: ${path.split(">").slice(-2).join(">")} ${JSON.stringify(hit?.rect)}`);
    const png = serve.shot(`${plan.label}-${name}-hover`);
    const box = g.editor && g.pane ? [g.pane[0], Math.max(g.pane[1], g.editor[1] - 520), g.pane[2], Math.min(520, g.editor[1] - g.pane[1]) + 60] : null;
    const c = crop(png, box, 0) ?? png;
    hoverPath = join(ev, `${name}-hover.png`);
    copyFileSync(c, hoverPath);
    serve.ctl("move", 5, 5);
  }
  const entry = { label: plan.label, name, kv: cell.kv, row: cell.row, chips: cell.chips, cache: cell.cache, age: cell.age, drawnMs, pass: problems.length === 0, problems, line: view?.line ?? null, card: view?.card ?? null, dim: view?.dim, geo: g, dock: g.dockCls, shot: shotPath, hover: hoverPath };
  results.push(entry);
  appendFileSync(join(ROOT, "results.jsonl"), JSON.stringify(entry) + "\n");
  console.log(`${entry.pass ? "PASS" : "FAIL"} ${plan.label} ${name} (${drawnMs} ms)${problems.length ? "\n   " + problems.join("\n   ") : ""}`);
}
// leave the cell state neutral
setCtl({ widget: null });
console.log(`DONE ${plan.label}: ${results.filter((r) => r.pass).length}/${results.length} pass`);
