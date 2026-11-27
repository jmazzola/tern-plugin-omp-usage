#!/usr/bin/env node
// QA sweep only: every layout state for one chat style, each in a serve of its own (sweep.mjs start), its cells run
// by sweep-run.mjs.   node tests/smoke/sweep-chat.mjs reader|spine|console BASEPORT [phases]
// Serves: A (agents tray on, no job: fresh, then a conversation, then a finished job's quiet dots), C (agents tray
// on, a running job: the dots and working row in a fresh composer, then the full tray once there's a conversation).
// B (agents tray off) isn't run by default: a headless serve doesn't read the setting from settings.json, and with
// the tray off an idle running job shows no row at all, so it adds nothing over A.
import { spawn, spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { display, layout } from "./sweep-plans.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const [chat, baseArg, phasesArg = "A,C"] = process.argv.slice(2);
const base = Number(baseArg);
const phases = new Set(phasesArg.split(","));
const node = process.execPath;
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

function run(...args) {
  const r = spawnSync(node, [join(here, "sweep.mjs"), ...args.map(String)], { encoding: "utf8", timeout: 120_000 });
  return (r.stdout ?? "") + (r.stderr ?? "");
}
function cells(label, list) {
  return JSON.stringify({ label, cells: list });
}
function runPlan(port, label, list) {
  const r = spawnSync(node, [join(here, "sweep-run.mjs"), String(port), cells(label, list)], { encoding: "utf8", timeout: 3_600_000, maxBuffer: 64 * 1024 * 1024 });
  process.stdout.write(r.stdout ?? "");
  process.stdout.write(r.stderr ?? "");
}
async function start(port, extra) {
  const child = spawn(node, [join(here, "sweep.mjs"), "start", String(port), chat, "1400", "640", JSON.stringify(extra)], { stdio: ["ignore", "pipe", "pipe"] });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  const until = Date.now() + 240_000;
  while (Date.now() < until && !/READY|Error/.test(out)) await sleep(500);
  console.log(`[${chat}] serve ${port}: ${out.trim().split("\n").slice(-1)[0]}`);
  if (!/READY/.test(out)) throw new Error(out);
  return child;
}
async function stop(port, child) {
  run("quit", port);
  await sleep(2500);
  try {
    child.kill();
  } catch {}
}
const settle = (ms) => sleep(ms);
// the last cell takes the attachment off again: a `!` command is only sent from an otherwise empty composer
const lay = (opts) => [...layout(opts.rows ?? ["none", "progress", "widget"], [0, 1], { hover: true, idle: true, ...opts }), { name: "clear-chips", kv: {}, chips: 0, shot: false, consistent: false }];

if (phases.has("A")) {
  const port = base;
  const child = await start(port, {});
  try {
    runPlan(port, `${chat}-A0-display`, display());
    runPlan(port, `${chat}-A1-fresh-notray`, lay({}));
    console.log(run("bang", port, "!echo qa-sweep"));
    await settle(4000);
    runPlan(port, `${chat}-A2-notray`, lay({}));
    run("ctl2", port, "job=qa-done", "jobDone=1500");
    await settle(6000);
    runPlan(port, `${chat}-A3-dots`, lay({}));
    console.log(run("log", port));
  } finally {
    await stop(port, child);
  }
}
if (phases.has("B")) {
  const port = base + 1;
  const child = await start(port, { agents_tray: false });
  try {
    console.log(run("bang", port, "!echo qa-sweep"));
    await settle(3000);
    run("ctl2", port, "job=qa-sleep");
    await settle(6000);
    runPlan(port, `${chat}-B1-working-notray`, lay({ rows: ["none", "progress", "widget"] }));
    console.log(run("log", port));
  } finally {
    await stop(port, child);
  }
}
if (phases.has("C")) {
  const port = base + 2;
  const child = await start(port, {});
  try {
    run("ctl2", port, "job=qa-sleep");
    await settle(6000);
    runPlan(port, `${chat}-C1-fresh-dots-working`, lay({}));
    console.log(run("bang", port, "!echo qa-sweep"));
    await settle(5000);
    runPlan(port, `${chat}-C2-full-tray`, lay({}));
    console.log(run("log", port));
  } finally {
    await stop(port, child);
  }
}
console.log(`[${chat}] all phases done`);
