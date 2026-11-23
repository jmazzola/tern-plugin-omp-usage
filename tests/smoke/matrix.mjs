#!/usr/bin/env node
// The plugin's headless smoke matrix: real Tern (`tern serve`), a real omp in an agent pane, and fixture caches, in a
// throwaway profile (see lib.mjs). Usage: node tests/smoke/matrix.mjs [OUT_DIR] [--only name,name]
// Writes OUT_DIR/results.json and OUT_DIR/results.md (PASS/FAIL per check, with what was seen) and keeps the
// screenshots in OUT_DIR/profile/shots/serve. Needs Windows, tern.com on PATH and Tern's own omp.
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import * as F from "./fixtures.mjs";
import { crop, DEFAULT_STATUS, pluginLog, Profile, redact, Serve, sleep, waitFor } from "./lib.mjs";

const args = process.argv.slice(2);
const onlyAt = args.indexOf("--only");
const only = onlyAt >= 0 ? new Set(args[onlyAt + 1].split(",")) : null;
const outDir = args.find((a, i) => !a.startsWith("--") && !(onlyAt >= 0 && i === onlyAt + 1)) ?? join(tmpdir(), "ompu-smoke");
mkdirSync(outDir, { recursive: true });

const HOST_SEL = ".tn-pane.on .sf-col[data-role^='omp.editor'] > .sf-row[data-role='omp.composer.chips']";
const EDITOR_SEL = ".tn-pane.on .sf-col[data-role^='omp.editor']";
const results = [];
const profile = new Profile(join(outDir, "profile")).prepare();
const a = new Serve(profile, Number(process.env.SMOKE_PORT_A ?? 47993), "a");

function record(name, pass, seen, evidence = []) {
  const entry = { name, result: pass === null ? "BLOCKED" : pass ? "PASS" : "FAIL", seen: redact(seen), evidence };
  results.push(entry);
  console.log(`${entry.result.padEnd(7)} ${name}\n        ${entry.seen.replaceAll("\n", "\n        ")}`);
}

// Writes `doc` and waits until the line satisfies `test(view)`; returns the view, or null after `timeout`.
async function show(doc, test, timeout = 40_000) {
  if (doc !== undefined) profile.writeCache(doc);
  return waitFor(() => {
    const view = profile.view();
    return view.line && test(view) ? view : null;
  }, timeout, 250);
}

// A screenshot of the composer (hovered: with its card), cropped to it; the crop's path, else the shot's.
async function snap(name, hover = false) {
  if (hover) {
    a.ctl("hover", HOST_SEL);
    await sleep(1600);
  } else {
    a.ctl("move", 5, 5);
    await sleep(400);
  }
  const png = a.shot(name);
  const editor = a.tree(EDITOR_SEL)[0];
  const above = hover ? 440 : 40;
  const box = editor ? [editor.rect[0], editor.rect[1] - above, editor.rect[2], above + 60] : null;
  return crop(png, box) ?? png;
}

const scenarios = {};

scenarios.freshness = async () => {
  const now = Date.now();
  const fresh = await show(F.doc(now, { observed: now - 60_000 }), (v) => v.line.includes("62% left") && !v.dim);
  const shots = [await snap("fresh", true)];
  const t = Date.now();
  const dim = await show(F.doc(t, { observed: t - 11 * F.M }), (v) => v.line.includes("62% left") && v.dim && v.card?.includes("as of 11m ago"));
  shots.push(await snap("dim-11m", true));
  const t2 = Date.now();
  const fallback = await show(F.doc(t2, { observed: t2 - 31 * F.M }), (v) => v.line.includes("33% left"));
  shots.push(await snap("fallback-31m"));
  const t3 = Date.now();
  const back = await show(F.doc(t3, { observed: t3 - 30_000 }), (v) => v.line.includes("62% left") && !v.dim);
  record(
    "fresh → 10-min dim → 30-min fallback → recovery",
    Boolean(fresh && dim && fallback && back),
    [
      `fresh: ${fresh?.line ?? "not seen"}`,
      `11 min: dim paint ${dim?.dim ?? "?"}, card age row ${dim?.card?.includes("as of 11m ago") ?? "?"}`,
      `31 min: ${fallback?.line ?? "status not shown"}`,
      `recovered: ${back?.line ?? "not seen"}`,
    ].join("\n"),
    shots
  );
};

scenarios.reset_clock = async () => {
  const clockOf = (card) => card?.match(/5-hour window[^\n]*\n\s+resets in [^·\n]+· ([^\n]+)/)?.[1] ?? null;
  // How many minutes apart two card clocks are (`5:07 AM`; `Mon 5:07 AM` when it isn't today), across midnight and
  // the week's end; null when either isn't a clock.
  const minutesApart = (x, y) => {
    const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const week = 7 * 24 * 60;
    const of = (clock) => {
      const m = /^(?:(Sun|Mon|Tue|Wed|Thu|Fri|Sat) )?(\d{1,2}):(\d\d) (AM|PM)$/.exec(clock ?? "");
      if (!m) return null;
      const day = m[1] ? days.indexOf(m[1]) : new Date().getDay();
      return day * 1440 + ((Number(m[2]) % 12) + (m[4] === "PM" ? 12 : 0)) * 60 + Number(m[3]);
    };
    const [a, b] = [of(x), of(y)];
    if (a === null || b === null) return null;
    const d = Math.abs(a - b) % week;
    return Math.min(d, week - d);
  };
  const t0 = Date.now();
  const at = t0 + 2 * F.H;
  const young = await show(F.doc(t0, { observed: t0 - 60_000, claude: F.claude(t0, { in5: at - t0 }) }), (v) => clockOf(v.card) !== null && v.line.includes("62%"));
  const t1 = Date.now();
  const old = await show(F.doc(t1, { observed: t1 - 9 * F.M, claude: F.claude(t1, { in5: at - t1, r5: 0.61 }) }), (v) => v.line.includes("61%"));
  // first schema: countdowns only, counted from the write and rounded to the minute. The rewrite's countdown is
  // rounded again, so its reset lands up to 30 s either side of the first one's: the clocks may be a minute apart.
  const t2 = Date.now();
  const g = t2 - 8 * F.M;
  const v1old = await show(F.doc(g, { v1: true, written: g, claude: F.claude(g, { in5: 2 * F.H, r5: 0.6 }) }), (v) => v.line.includes("60%"));
  const t3 = Date.now();
  const v1new = await show(F.doc(t3, { v1: true, written: t3, claude: F.claude(t3, { in5: g + 2 * F.H - t3, r5: 0.59 }) }), (v) => v.line.includes("59%"));
  const clocks = [clockOf(young?.card), clockOf(old?.card), clockOf(v1old?.card), clockOf(v1new?.card)];
  const v1apart = minutesApart(clocks[2], clocks[3]);
  record(
    "reset time stays put across cache age",
    clocks.every(Boolean) && clocks[0] === clocks[1] && v1apart !== null && v1apart <= 1,
    `schema 2, observed 1 min vs 9 min ago: ${clocks[0]} / ${clocks[1]}\nschema 1, written 8 min ago vs rewritten now (same reset, countdowns to the minute: ±1 min): ${clocks[2]} / ${clocks[3]} (${v1apart ?? "?"} min apart)`,
    [await snap("reset-clock", true)]
  );
};

scenarios.passed = async () => {
  const t = Date.now();
  const passed = await show(F.doc(t, { claude: F.claude(t, { in5: -5 * F.M }) }), (v) => v.line.includes("5H reset"));
  const shots = [await snap("passed-written", true)];
  const t2 = Date.now();
  profile.writeCache(F.doc(t2, { claude: F.claude(t2, { inf: 20_000 }) }));
  const before = await show(undefined, (v) => v.line.includes("FABLE 7D ━") && v.line.includes("62%"));
  const later = await show(undefined, (v) => v.line.includes("FABLE 7D reset"), 45_000);
  shots.push(await snap("passed-at-read", true));
  record(
    "passed reset reads `reset`",
    Boolean(passed && passed.card?.includes("waiting for new numbers") && before && later),
    [
      `written after the reset: ${passed?.line ?? "not seen"}`,
      `card: ${passed?.card?.split("\n").find((l) => l.includes("waiting")) ?? "no `waiting for new numbers` row"}`,
      `passing 20 s after the write: ${later ? `after ~${Math.round((Date.now() - t2) / 1000)} s: ${later.line}` : "never read `reset`"}`,
    ].join("\n"),
    shots
  );
};

scenarios.pace = async () => {
  const t = Date.now();
  const rows = (view) => (view?.card ?? "").split("\n").filter((l) => l.includes("× pace")).map((l) => l.trim());
  // A step's outcome: how long the card took to get there, else what it still shows. An idle headless window runs
  // no plugin timers (lib.mjs demoStatus), so while a step waits it gives omp a new status to draw every 5 s, which
  // lets the next poll run (a poll that reads a new cache draws it on the poll after). The line is drawn from the
  // cache either way: its 5h window reads 20%, which no status here says.
  let nudges = 0;
  const step = async (kv, test) => {
    profile.writeKv(kv);
    const t0 = Date.now();
    let view = null;
    for (let i = 0; i < 9 && !view; i += 1) {
      nudges += 1;
      profile.setStatus(nudges % 2 ? DEFAULT_STATUS.replace("33%", "34%") : DEFAULT_STATUS);
      view = await show(undefined, (v) => v.line.includes("20%") && test(v), 5_000);
    }
    const now = rows(view ?? profile.view()).join(" | ") || "no pace row";
    return { ok: Boolean(view), text: view ? `after ${((Date.now() - t0) / 1000).toFixed(1)} s: ${now}` : `never; the card still shows: ${now}` };
  };
  const none = (v) => Boolean(v.card) && rows(v).length === 0;
  const one = (v) => rows(v).length === 1 && rows(v)[0].includes("empty ~");
  // 5h runs ahead (80% used, 3h of 5h gone); 7d and Fable 7d last past their resets
  profile.writeCache(F.doc(t, { claude: F.claude(t, { r5: 0.2, in5: 2 * F.H, r7: 0.8, in7: 3.5 * F.D }) }));
  const ahead = await step({}, one);
  const shots = [await snap("pace-ahead", true)];
  // the on/off setting from before the three choices still counts while no choice is stored
  const before = await step({ "omp-usage.show-pace": false }, none);
  const always = await step({ "omp-usage.pace": "always" }, (v) => rows(v).length === 3 && v.card.includes("0.4× pace · lasts past reset"));
  shots.push(await snap("pace-always", true));
  const off = await step({ "omp-usage.pace": "off", "omp-usage.show-pace": undefined }, none);
  shots.push(await snap("pace-off", true));
  const back = await step({ "omp-usage.pace": "ahead" }, one);
  profile.writeKv({ "omp-usage.pace": undefined });
  profile.setStatus(DEFAULT_STATUS);
  record(
    "Show pace Off / When ahead / Always each redraw the card",
    Boolean(ahead.ok && before.ok && always.ok && off.ok && back.ok),
    [
      `nothing stored (When ahead): ${ahead.text}`,
      `the old on/off setting, off, with no choice stored: ${before.text}`,
      `Always, over the old setting: ${always.text}`,
      `Off: ${off.text}`,
      `When ahead: ${back.text}`,
    ].join("\n"),
    shots
  );
};

scenarios.card_rows = async () => {
  const t = Date.now();
  const accounts = [];
  const windows = [];
  for (let i = 1; i <= 10; i += 1) {
    const name = `acct${i}`;
    accounts.push(name);
    windows.push(F.win({ label: `${name} 5h`, key: "5h", ms: 5 * F.H, r: 0.5 + i / 100, at: t + 2 * F.H, account: name }));
    windows.push(F.win({ label: `${name} 7d`, key: "7d", ms: 7 * F.D, r: 0.3 + i / 100, at: t + 3 * F.D, account: name }));
  }
  const doc = F.doc(t);
  doc.providers.anthropic = F.provider("anthropic", "Claude", windows, t, { accounts });
  for (const chip of Object.keys(doc.models)) doc.models[chip] = F.model("anthropic", "Claude", windows, t);
  profile.writeKv({ "omp-usage.card-rows": 50 });
  const tall = await show(doc, (v) => (v.card?.match(/\n/g)?.length ?? 0) > 30, 30_000);
  const shots = [await snap("card-rows-50", true)];
  const tallRows = tall?.card?.split("\n").length ?? 0;
  profile.writeKv({ "omp-usage.card-rows": 16 });
  const t0 = Date.now();
  const short = await show(undefined, (v) => v.card && v.card.split("\n").length <= 17, 20_000);
  shots.push(await snap("card-rows-16", true));
  profile.writeKv({ "omp-usage.card-rows": undefined });
  record(
    "card height change alone redraws the card",
    Boolean(tall && short),
    `50 rows: card ${tallRows} rows; 16 rows (only the setting changed): ${short ? `${short.card.split("\n").length} rows after ${((Date.now() - t0) / 1000).toFixed(1)} s` : "card never shrank"}`,
    shots
  );
};

scenarios.combined = async () => {
  const t = Date.now();
  const alice = [
    F.win({ label: "alice 5h", key: "5h", ms: 5 * F.H, r: 0.55, at: t + 2 * F.H, account: "alice" }),
    F.win({ label: "alice 7d", key: "7d", ms: 7 * F.D, r: 0.38, at: t + 3 * F.D, account: "alice" }),
  ];
  const doc = F.doc(t);
  doc.providers.anthropic = F.provider("anthropic", "Claude", alice, t, { accounts: ["alice", "bob"] });
  profile.writeKv({ "omp-usage.mode": "all", "omp-usage.account": { anthropic: "\u0001combined" } });
  const seen = await show(doc, (v) => v.card?.includes("no current numbers for bob"));
  const shots = [await snap("combined-stale-seat", true)];
  profile.writeKv({ "omp-usage.mode": undefined, "omp-usage.account": undefined });
  // the note is the combined view's own: a row of its own, not labelled `Provider ·` as a provider-wide detail is
  const note = seen?.card?.split("\n").find((l) => l.includes("no current numbers for bob")) ?? null;
  record(
    "combined pool with a stale seat",
    Boolean(note?.trim() === "1 of 2 accounts · no current numbers for bob"),
    `line: ${seen?.line ?? "not seen"}\ncard: ${note ?? "no note"}`,
    shots
  );
};

scenarios.zai = async () => {
  const t = Date.now();
  const zai = [
    F.win({ label: "5h", ms: 5 * F.H, r: 0.72, at: t + F.H, provider: "zai" }),
    F.win({ label: "mo", key: "monthly", ms: 30 * F.D, r: 0.64, at: t + 12 * F.D, provider: "zai" }),
  ];
  const coding = [F.win({ label: "5h", ms: 5 * F.H, r: 0.18, at: t + 4 * F.H, provider: "zai-coding-plan" })];
  const doc = F.doc(t, {
    providers: {
      zai: F.provider("zai", "Zai", zai, t),
      "zai-coding-plan": F.provider("zai-coding-plan", "Zai-Coding", coding, t),
    },
  });
  profile.writeKv({ "omp-usage.mode": "selected", "omp-usage.selected": ["zai", "zai-coding-plan"] });
  const seen = await show(doc, (v) => v.line.includes("Zai-Coding"));
  const shots = [await snap("zai-vs-coding", true)];
  profile.writeKv({ "omp-usage.mode": undefined, "omp-usage.selected": undefined });
  const line = seen?.line ?? "";
  const zaiPart = line.split(" · ").find((p) => p.startsWith("Zai ")) ?? "";
  const codingPart = line.split(" · ").find((p) => p.startsWith("Zai-Coding")) ?? "";
  record(
    "zai vs zai-coding-plan stay apart",
    zaiPart.includes("72%") && zaiPart.includes("64%") && codingPart.includes("18%") && !codingPart.includes("72%"),
    `line: ${line || "not seen"}`,
    shots
  );
};

scenarios.v1 = async () => {
  const t = Date.now();
  const seen = await show(F.doc(t, { v1: true, claude: F.claude(t, { r5: 0.57, r7: 0.44 }) }), (v) => v.line.includes("57% left") && v.line.includes("44% left"));
  record("first-version cache", Boolean(seen && !seen.dim), `line: ${seen?.line ?? "not seen"}; dim: ${seen?.dim}`, [await snap("v1", false)]);
};

scenarios.oversize = async () => {
  const t = Date.now();
  await show(F.doc(t, { claude: F.claude(t, { r5: 0.62 }) }), (v) => v.line.includes("62% left"));
  const big = JSON.stringify({ ...F.doc(t, { claude: F.claude(t, { r5: 0.1 }) }), padding: "x".repeat(1100 * 1024) });
  const seen = await show(big, (v) => v.line.includes("too big"));
  await sleep(8000);
  const warnings = pluginLog(profile).filter((l) => l.includes("bytes, over the"));
  const shots = [await snap("oversize", true)];
  await show(F.doc(Date.now()), (v) => !v.line.includes("too big"));
  record(
    "oversize cache says so and keeps the last numbers",
    Boolean(seen?.line.includes("62% left") && warnings.length === 1),
    `line: ${seen?.line ?? "not seen"}\nlog warnings: ${warnings.length} (${warnings[0] ?? "none"})`,
    shots
  );
};

scenarios.model_switch = async () => {
  const t = Date.now();
  const before = await a.waitForChip();
  const claudeChips = [before, "Opus 5.5", "Fable 5.2", "Mythos 5.2"];
  // omp's chip shows a model's display name (`GPT-6 Luna` for gpt-6-luna): both spellings, so the entry is found
  const codexChips = ["GPT-6 Luna", "GPT-6-Luna", "GPT-6 Astra", "GPT-6 Sol", "GPT-6.1 Sol", "GPT-6.2 Sol", "GPT-6.2 Astra", "GPT-6.1 Terra"];
  await show(F.doc(t, { chips: claudeChips, codexChips }), (v) => v.line.startsWith("Claude"));
  a.ctl("key", "alt+p");
  await sleep(1200);
  a.ctl("type", "gpt-6-luna");
  await sleep(800);
  const t0 = Date.now();
  a.ctl("key", "enter");
  const chip = await waitFor(() => {
    const text = a.tree(".tn-pane.on [data-role='omp.composer.model']")[0]?.text;
    return text && text !== before ? text : null;
  }, 15_000, 100);
  const chipAt = Date.now();
  // as usage-remaining.js does within a second of a switch: its status names the new model's provider (with numbers
  // of its own here, so a line from the cache entry shows the entry's 91%, not the status's 50%). Until it does, the
  // wrong-provider guard keeps the line on the old status.
  profile.setStatus("Codex 5h ████░░░░ 50% left (2h) · 7d ███░░░░░ 33% left (4d)");
  // headless timers run late (lib.mjs demoStatus): the plugin's next poll can take a while
  const seen = await show(undefined, (v) => v.line.startsWith("Codex") && v.line.includes("91% left"), 40_000);
  const lineAt = Date.now();
  const shots = [await snap("model-switch", false)];
  profile.setStatus(DEFAULT_STATUS);
  record(
    "model switch: the line follows the chip",
    Boolean(chip && seen),
    `chip ${before} → ${chip ?? "unchanged"} after ${((chipAt - t0) / 1000).toFixed(1)} s; the status set to Codex's then; line followed ${seen ? `${((lineAt - chipAt) / 1000).toFixed(1)} s later, from the cache entry: ${seen.line}` : "never"}`,
    shots
  );
};

scenarios.widget = async () => {
  a.ctl("widgets", "set", "status");
  // omp Usage's segment among the Plugin segments: Tern titles a segment with the command its click runs.
  const find = () => a.tree("#widgetbar .wg-seg").find((n) => /^plugin\.omp-usage\.(panel|details)$/.test(n.title ?? "")) ?? null;
  // the segment's color, as Tern computed it (its tone): the segment and every element inside its box
  const colorOf = (node) => {
    const [x, y, w, h] = node.rect;
    const inside = (a.ctl("dump", "#widgetbar .wg-seg, #widgetbar .wg-seg *").elements ?? []).filter((e) => e.visible && e.rect[0] >= x - 1 && e.rect[1] >= y - 1 && e.rect[0] + e.rect[2] <= x + w + 1 && e.rect[1] + e.rect[3] <= y + h + 1);
    return [...new Set(inside.map((e) => e.color))].join(" / ") || null;
  };
  // Waits until the segment reads `text` ("": its gauge alone), and returns it with its color then; null if it never
  // does. An idle headless window runs no plugin timers (lib.mjs demoStatus), so each try gives omp a new status to
  // draw, which lets the next poll run.
  let nudges = 0;
  const reads = async (text) => {
    for (let i = 0; i < 8; i += 1) {
      nudges += 1;
      profile.setStatus(nudges % 2 ? DEFAULT_STATUS.replace("33%", "34%") : DEFAULT_STATUS);
      const node = await waitFor(() => {
        const seg = find();
        return seg && (seg.text ?? "") === text ? seg : null;
      }, 5_000, 300);
      if (node) return { ...node, color: colorOf(node) };
    }
    return null;
  };
  const said = (node) => (node ? `"${node.text ?? ""}", ${node.rect[2]}px wide, color ${node.color}` : `not seen; the segment reads "${find()?.text ?? ""}"`);
  // every window keeps pace (7d, the closest, at 1.08×)
  const t = Date.now();
  await show(F.doc(t), (v) => v.line.includes("62% left"));
  const calm = await reads("");
  // 8% left, but on pace (0.95×: 92% used with 4h 50m of 5h gone): Tern's own usage widgets show the share
  const t2 = Date.now();
  await show(F.doc(t2, { claude: F.claude(t2, { r5: 0.08, in5: 10 * F.M }) }), (v) => v.line.includes("8% left"));
  const low = await reads("");
  // 5h at 1.3× (80% used, 3h of 5h gone), 7d at 1.6× (80% used, half of it gone): the furthest ahead
  const t3 = Date.now();
  await show(F.doc(t3, { claude: F.claude(t3, { r5: 0.2, in5: 2 * F.H, r7: 0.2, in7: 3.5 * F.D }) }), (v) => v.line.includes("20% left"));
  const ahead = await reads("Claude 1.6× pace");
  const png = a.shot("widget-ahead");
  record(
    "widget bar: the gauge alone while windows keep pace, a warning while one runs ahead",
    Boolean(calm && low && ahead && calm.color !== ahead.color && calm.rect[2] < ahead.rect[2]),
    [`on pace: ${said(calm)}`, `8% left, on pace: ${said(low)}`, `5h at 1.3×, 7d at 1.6×: ${said(ahead)}`].join("\n"),
    [png]
  );
  profile.writeKv({ "omp-usage.pace": "off" });
  const off = await reads("");
  profile.writeKv({ "omp-usage.pace": "always" });
  const always = await reads("Claude 1.6× pace");
  profile.writeKv({ "omp-usage.pace": undefined });
  profile.setStatus(DEFAULT_STATUS);
  record(
    "widget bar follows Show pace",
    Boolean(off && always),
    [`Off: ${said(off)}`, `Always: ${said(always)}`].join("\n"),
    []
  );
};

scenarios.light_dark = async () => {
  const t = Date.now();
  await show(F.doc(t), (v) => v.line.includes("62% left") && !v.dim);
  a.ctl("appearance", "light");
  await sleep(1500);
  const light = await snap("light", true);
  a.ctl("appearance", "dark");
  await sleep(1500);
  const dark = await snap("dark", true);
  record("light and dark", true, "shots taken: compare by eye (the line and card must read on both)", [light, dark]);
};

scenarios.reduce_motion = async () => {
  const t = Date.now();
  await show(F.doc(t, { claude: F.claude(t, { r5: 0.62 }) }), (v) => v.line.includes("62% left"));
  await sleep(2500);
  // a change with motion on: the line prints again and comets run
  profile.writeCache(F.doc(Date.now(), { claude: F.claude(Date.now(), { r5: 0.4 }) }));
  // headless timers run late (lib.mjs demoStatus): the plugin's next cache read can take a while
  const moving = await waitFor(() => (profile.view().css.includes("omp-usage-reveal-") ? profile.view() : null), 40_000, 100);
  a.ctl("motion-at", 250);
  const motionShot = await snap("motion-on-250ms");
  a.ctl("thaw");
  await sleep(2500);
  a.ctl("reduce-motion", "on");
  await sleep(1000);
  const still = a.ctl("dump", ".sf-still").elements?.length ?? 0;
  profile.writeCache(F.doc(Date.now(), { claude: F.claude(Date.now(), { r5: 0.2 }) }));
  await waitFor(() => (profile.view().line?.includes("20% left") ? true : null), 40_000, 100);
  a.ctl("motion-at", 250);
  const stillShot = await snap("reduce-motion-250ms");
  a.ctl("thaw");
  a.ctl("reduce-motion", "off");
  record(
    "Reduce Motion drops the change animation",
    Boolean(moving) && still > 0,
    `a change with motion on writes the reveal/comet keyframes: ${Boolean(moving)}; Reduce Motion on: ${still} .sf-still elements (the sheet's still rules apply to them); compare the two shots, both frozen 250 ms into the change`,
    [motionShot, stillShot]
  );
};

scenarios.short_pane = async () => {
  const t = Date.now();
  await show(F.doc(t), (v) => v.line.includes("62% left"));
  a.ctl("size", 1400, 260);
  await sleep(2000);
  // over the line's left end, then its middle (where a pane this short has its drag grip)
  const host = a.tree(HOST_SEL)[0];
  const middle = host ? a.ctl("pick", Math.round(host.rect[0] + host.rect[2] / 2), Math.round(host.rect[1] + host.rect[3] / 2)) : null;
  if (host) a.ctl("move", Math.round(host.rect[0] + 40), Math.round(host.rect[1] + host.rect[3] / 2));
  await sleep(1600);
  const png = a.shot("short-pane");
  const centre = await snap("short-pane-centre", true);
  a.ctl("size", 1400, 640);
  await sleep(1500);
  const under = String(middle?.path ?? "nothing").split(">").slice(-2).join(">");
  record(
    "short pane",
    true,
    `1400×260 window. Hovered at the line's left end, then its middle; under the middle: ${under}. Check the card in both shots by eye (the plugin can't see a pane's height)`,
    [png, centre]
  );
};

scenarios.unfocused = async () => {
  a.ctl("css", "probe:uncut", join(profile.root, "uncut.css"));
  a.ctl("block", "agent");
  await sleep(3000);
  await a.waitForChip();
  await sleep(8000);
  const t = Date.now();
  const chips = [...new Set(a.tree("[data-role='omp.composer.model']").map((n) => n.text).filter(Boolean))];
  await show(F.doc(t, { chips }), (v) => v.line.includes("62% left"));
  await sleep(20000); // the shared facts sheet is checked every 5 s; headless timers run late
  const factsIn = (sel) => a.tree(`${sel} [data-role='omp.composer.bar'] [data-id*='/hook-']`).map((n) => n.text ?? "");
  const cachedOther = factsIn(".tn-pane.agent:not(.on)");
  const factsSheet = profile.sheet("usage-facts");
  const png1 = a.shot("unfocused-cached");
  const t2 = Date.now();
  await show(F.doc(t2, { observed: t2 - 31 * F.M }), (v) => v.line.includes("33% left"));
  await sleep(20000);
  const staleOther = factsIn(".tn-pane.agent:not(.on)");
  const png2 = a.shot("unfocused-fallback");
  a.ctl("css", "probe:uncut");
  record(
    "L-13: usage status hidden in unfocused panes while the cache draws their line",
    cachedOther.length > 0 && !cachedOther.some((t) => t.includes("% left")) && cachedOther.includes("demo: other extension") && staleOther.some((t) => t.includes("33% left")),
    `unfocused pane's bar facts, cache fresh: ${JSON.stringify(cachedOther)}\nusage-facts sheet: ${(factsSheet ?? "").replace(/\s+/g, " ").trim() || "(empty)"}\nunfocused pane's bar facts, cache 31 min old: ${JSON.stringify(staleOther)}`,
    [png1, png2]
  );
  // back to one pane
  a.ctl("close");
  await sleep(2000);
};

scenarios.remote = async () => {
  const t = Date.now();
  await show(F.doc(t), (v) => v.line.includes("62% left"));
  const attach = a.ctl("remote", "loopback", "box");
  await sleep(4000);
  a.ctl("block", "agent");
  let chip = null;
  try {
    chip = await a.waitForChip(90_000);
  } catch {
    chip = null;
  }
  await sleep(6000);
  const seen = await show(undefined, (v) => v.line.includes("33% left") || v.line.includes("62% left"), 20_000);
  const png = chip ? a.shot("remote-loopback") : null;
  record(
    "remote pane uses its status, not this machine's cache",
    chip ? Boolean(seen?.line.includes("33% left")) : null,
    chip
      ? `loopback host attached (${JSON.stringify(attach)}); its omp pane's line: ${seen?.line ?? "not seen"} (cache says 62%, its status 33%)`
      : `couldn't open an omp pane on a loopback host (${JSON.stringify(attach)})`,
    png ? [png] : []
  );
};

scenarios.alerts_two_windows = async () => {
  const b = new Serve(profile, Number(process.env.SMOKE_PORT_B ?? 47994), "b");
  await b.start();
  await b.openAgent();
  profile.writeKv({ "omp-usage.alerts": true, "omp-usage.alerts-seen": undefined, "omp-usage.alerts-seed": undefined });
  const seen = { a: [], b: [] };
  const claims = [];
  const watch = async (ms) => {
    const until = Date.now() + ms;
    let lastClaim = profile.readKv()["omp-usage.alerts-claim"];
    while (Date.now() < until) {
      for (const [label, serve] of [["a", a], ["b", b]]) {
        for (const node of serve.tree(".toast")) {
          const text = node.text ?? "";
          if (text.includes("Claude") && !seen[label].includes(text)) seen[label].push(text);
        }
      }
      const claim = profile.readKv()["omp-usage.alerts-claim"];
      if (claim !== lastClaim) {
        claims.push({ at: Date.now(), claim });
        lastClaim = claim;
      }
      await sleep(400);
    }
  };
  const resetAt = Date.now() + 2 * F.H;
  const steps = [
    [0.3, "30% (nothing to say)"],
    [0.2, "20% (a quarter left)"],
    [0.09, "9% (a tenth left)"],
    [0, "0% (used up)"],
  ];
  const log = [];
  for (const [r5, label] of steps) {
    const before = seen.a.length + seen.b.length;
    const t = Date.now();
    profile.writeCache(F.doc(t, { claude: F.claude(t, { r5, in5: resetAt - t }), resets: [] }));
    await watch(40_000);
    log.push(`${label}: a ${seen.a.length} toasts, b ${seen.b.length} toasts (+${seen.a.length + seen.b.length - before})`);
  }
  const png = a.shot("alerts-a");
  await b.quit();
  const total = seen.a.length + seen.b.length;
  record(
    "alerts opt-in, two windows active: one toast per crossing",
    total === 3 && new Set([...seen.a, ...seen.b]).size === 3,
    `${log.join("\n")}\ntoasts in window a: ${JSON.stringify(seen.a)}\ntoasts in window b: ${JSON.stringify(seen.b)}\nclaims written: ${claims.length}`,
    [png]
  );
  profile.writeKv({ "omp-usage.alerts": undefined });
};

const order = [
  "freshness",
  "reset_clock",
  "passed",
  "pace",
  "card_rows",
  "combined",
  "zai",
  "v1",
  "oversize",
  "widget",
  "light_dark",
  "reduce_motion",
  "short_pane",
  "model_switch",
  "unfocused",
  "alerts_two_windows",
  "remote",
];

try {
  await a.start();
  await a.openAgent();
  a.ctl("appearance", "dark");
  for (const name of order) {
    if (only && !only.has(name)) continue;
    try {
      await scenarios[name]();
    } catch (err) {
      record(name, false, `error: ${err.stack ?? err}`);
    }
  }
} finally {
  const log = pluginLog(profile);
  results.push({ name: "plugin log lines", result: "INFO", seen: log.slice(-40).join("\n"), evidence: [] });
  writeFileSync(join(outDir, "results.json"), JSON.stringify(results, null, 1));
  const md = results.map((r) => `### ${r.result} ${r.name}\n\n\`\`\`\n${r.seen}\n\`\`\`\n${r.evidence.map((e) => `- ${e}`).join("\n")}\n`).join("\n");
  writeFileSync(join(outDir, "results.md"), md);
  await a.quit();
}
