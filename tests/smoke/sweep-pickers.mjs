#!/usr/bin/env node
// QA sweep only: every item of omp Usage: Settings… in the palette opens, and its choice applies (the setting in
// tern.kv, then the line).   node tests/smoke/sweep-pickers.mjs PORT
// Runs against a `sweep.mjs start` serve with the multi-account cache. Each step filters the open picker by typing
// and presses Enter only once the selected row is the one wanted; nothing is typed into omp's composer.
import { appendFileSync, copyFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { crop, Profile, Serve, sleep, waitFor } from "./lib.mjs";

const ROOT = process.env.QA_SWEEP_DIR ?? join(tmpdir(), "qa-sweep");
const port = Number(process.argv[2]);
const profile = new Profile(join(ROOT, `prof-${port}`));
const serve = new Serve(profile, port, "x");
const ev = join(ROOT, "ev", "pickers");
mkdirSync(ev, { recursive: true });

const items = () => serve.tree(".tn-pk-item").map((n) => ({ text: n.text ?? "", sel: /\bsel\b/.test(n.class ?? "") }));
const open = () => serve.tree(".tn-pk").length > 0;

async function menu() {
  serve.ctl("key", "Escape");
  serve.ctl("key", "Escape");
  await sleep(300);
  serve.ctl("palette", "omp Usage: Settings…");
  await sleep(800);
  const sel = serve.tree(".tn-pl-item.sel")[0]?.text ?? "";
  if (!sel.startsWith("omp Usage: Settings…")) {
    serve.ctl("key", "Down");
    await sleep(200);
  }
  if (!(serve.tree(".tn-pl-item.sel")[0]?.text ?? "").startsWith("omp Usage: Settings…")) throw new Error("palette row not found");
  serve.ctl("key", "Enter");
  return waitFor(() => (open() ? true : null), 5000, 200);
}

// Picks the row whose text starts with `label` in the open picker: by arrowing to it (filtering would also match the
// detail text).
async function choose(label) {
  const list = items();
  const at = list.findIndex((i) => i.text.startsWith(label));
  if (at < 0) throw new Error(`no row "${label}" in [${list.map((i) => i.text.slice(0, 30)).join(" | ")}]`);
  const from = list.findIndex((i) => i.sel);
  const key = at > from ? "Down" : "Up";
  for (let n = 0; n < Math.abs(at - from); n += 1) serve.ctl("key", key);
  await sleep(250);
  const now = items().find((i) => i.sel)?.text ?? "";
  if (!now.startsWith(label)) throw new Error(`arrowed to "${now}" instead of "${label}"`);
  serve.ctl("key", "Enter");
  await sleep(900);
  return items();
}

const steps = [
  { name: "mode all", path: ["All providers"], kv: (kv) => kv["omp-usage.mode"] === "all", line: /Codex/ },
  { name: "mode current", path: ["Current model"], kv: (kv) => kv["omp-usage.mode"] === undefined || kv["omp-usage.mode"] === "current", line: /^Claude/ },
  { name: "line style blocks", path: ["Line style…", "Blocks"], kv: (kv) => kv["omp-usage.style"] === "blocks", line: /▰/ },
  { name: "line style ring", path: ["Line style…", "Ring"], kv: (kv) => kv["omp-usage.style"] === "ring", line: /[○◔◑◕●]/ },
  { name: "line style compact", path: ["Line style…", "Compact"], kv: (kv) => kv["omp-usage.style"] === "compact", line: /^(?!.*[━▰○◔◑◕●])/ },
  { name: "line style instrument", path: ["Line style…", "Instrument"], kv: (kv) => kv["omp-usage.style"] === "instrument", line: /━/ },
  { name: "position stacked", path: ["Line position…", "Stacked"], kv: (kv) => kv["omp-usage.place"] === "stack", line: /\n/ },
  { name: "stacked at left (shows only while stacked)", path: ["Stacked at…", "Left"], kv: (kv) => kv["omp-usage.align"] === "left" },
  { name: "position under", path: ["Line position…", "Under the bar"], kv: (kv) => kv["omp-usage.place"] === "below" },
  { name: "position above", path: ["Line position…", "Above the bar"], kv: (kv) => kv["omp-usage.place"] === "above" },
  { name: "parts: bar off", path: ["What the line shows…", "Bar"], kv: (kv) => kv["omp-usage.line-parts"]?.bar === false, line: /^(?!.*━)/ },
  { name: "parts: share off with bar off (keeps one)", path: ["What the line shows…", "Share"], kv: (kv) => kv["omp-usage.line-parts"]?.share !== false || kv["omp-usage.line-parts"]?.bar !== false, line: /\d% left/ },
  { name: "parts: bar back on", path: ["What the line shows…", "Bar"], kv: (kv) => kv["omp-usage.line-parts"]?.bar !== false, line: /━/ },
  { name: "parts: plan on", path: ["What the line shows…", "Plan"], kv: (kv) => kv["omp-usage.line-parts"]?.plan === true, line: /Max|Pro|Ultra/ },
  { name: "shares used", path: ["Shares…", "Used"], kv: (kv) => kv["omp-usage.metric"] === "used", line: /used/ },
  { name: "shares left", path: ["Shares…", "Left"], kv: (kv) => kv["omp-usage.metric"] === "left", line: /left/ },
  { name: "choose providers: Codex", path: ["Choose providers…", "Codex"], kv: (kv) => (kv["omp-usage.selected"] ?? []).includes("openai-codex") },
  { name: "selected providers", path: ["Selected providers"], kv: (kv) => kv["omp-usage.mode"] === "selected", line: /^Codex/ },
  { name: "reorder providers: Codex to top", path: ["Reorder providers…", "Codex", "Move to top"], kv: (kv) => (kv["omp-usage.order"] ?? [])[0] === "openai-codex" },
  { name: "provider colors: Claude Sunset", path: ["Provider colors…", "Claude", "Sunset"], kv: (kv) => kv["omp-usage.colors"]?.anthropic === "named:sunset" },
  // with several accounts, each account's windows are rows of their own
  { name: "provider windows: Claude alice 5h off", path: ["Provider windows…", "Claude", "alice 5-hour window"], kv: (kv) => (kv["omp-usage.hidden"]?.anthropic ?? []).includes("alice 5h") },
  { name: "provider accounts: Claude combined", path: ["Provider accounts…", "Claude", "Combined"], kv: (kv) => kv["omp-usage.account"]?.anthropic === "\u0001combined" },
  { name: "plans: an account's plan off", path: ["Plans…", "Claude"], kv: (kv) => Object.keys(kv["omp-usage.plan-hidden"] ?? {}).length > 0 },
  { name: "card height 40", path: ["Card height…", "40"], kv: (kv) => kv["omp-usage.card-rows"] === 40 },
  { name: "show pace always", path: ["Show pace…", "Always"], kv: (kv) => kv["omp-usage.pace"] === "always" },
  { name: "line background solid", path: ["Line background…", "Solid"], kv: (kv) => kv["omp-usage.backdrop"] === "solid" },
  { name: "widget bar gauge: details", path: ["Widget bar gauge…", "Quota details"], kv: (kv) => kv["omp-usage.usage-opens"] === "details" },
  { name: "alerts on", path: ["Alerts…", "On"], kv: (kv) => kv["omp-usage.alerts"] === true },
  { name: "alerts off", path: ["Alerts…", "Off"], kv: (kv) => kv["omp-usage.alerts"] !== true },
];

const out = [];
for (const [i, step] of steps.entries()) {
  const problems = [];
  let rows = [];
  try {
    await menu();
    for (const [j, label] of step.path.entries()) {
      rows = await choose(label);
      if (j === 0) {
        // the submenu, as it opened, for the record
        const png = serve.shot(`picker-${i}`);
        const c = crop(png, [380, 60, 640, 520], 0) ?? png;
        copyFileSync(c, join(ev, `${String(i).padStart(2, "0")}-${step.name.replace(/[^a-z0-9]+/gi, "-")}.png`));
      }
    }
  } catch (err) {
    problems.push(String(err.message ?? err));
  }
  const kv = await waitFor(() => (step.kv(profile.readKv()) ? profile.readKv() : null), 5000, 250);
  if (!kv) problems.push(`setting not applied: ${JSON.stringify(Object.fromEntries(Object.entries(profile.readKv()).filter(([k]) => !/update|alerts-|setup|installed|linked/.test(k))))}`);
  let line = null;
  if (step.line) {
    const v = await waitFor(() => {
      const view = profile.view();
      return view.line && step.line.test(view.line) ? view : null;
    }, 20_000, 250);
    line = (v ?? profile.view()).line;
    if (!v) problems.push(`line didn't follow: ${line}`);
  }
  const entry = { label: "pickers", name: step.name, pass: problems.length === 0, problems, line, rows: rows.map((r) => r.text).slice(0, 12) };
  out.push(entry);
  appendFileSync(join(ROOT, "results.jsonl"), JSON.stringify(entry) + "\n");
  console.log(`${entry.pass ? "PASS" : "FAIL"} pickers ${step.name}${problems.length ? "\n   " + problems.join("\n   ") : ""}`);
  serve.ctl("key", "Escape");
  serve.ctl("key", "Escape");
  await sleep(300);
}
console.log(`DONE pickers: ${out.filter((r) => r.pass).length}/${out.length} pass`);
