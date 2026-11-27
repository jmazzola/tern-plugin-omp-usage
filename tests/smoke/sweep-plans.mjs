#!/usr/bin/env node
// QA sweep only: prints a plan for sweep-run.mjs.  node tests/smoke/sweep-plans.mjs KIND LABEL [JSON opts]
// display: every Style × Position × Shares (32 cells).  layout: each row above × chips × the four positions, styles
// and shares rotating so every pair of them meets across the plan.
const STYLES = ["instrument", "blocks", "ring", "compact"];
const POSITIONS = [["above", "right"], ["below", "right"], ["stack", "right"], ["stack", "left"]];
const METRICS = ["left", "used"];
const kvOf = (style, [place, align], metric) => ({ "omp-usage.style": style, "omp-usage.place": place, "omp-usage.align": align, "omp-usage.metric": metric });
const posName = ([place, align]) => (place === "stack" ? `stack-${align}` : place);

export function display() {
  const cells = [];
  for (const pos of POSITIONS) {
    for (const style of STYLES) {
      for (const metric of METRICS) {
        cells.push({ name: `${posName(pos)}-${style}-${metric}`, kv: kvOf(style, pos, metric), parse: style === "instrument" && metric === "left", hover: style === "blocks" && metric === "used" });
      }
    }
  }
  return cells;
}

export function layout(rows, chips, opts = {}) {
  const cells = [];
  let n = 0;
  for (const row of rows) {
    for (const chip of chips) {
      for (const pos of POSITIONS) {
        const style = STYLES[(n + Math.floor(n / 4)) % 4];
        const metric = METRICS[Math.floor(n / 2) % 2];
        cells.push({ name: `${row}-chips${chip}-${posName(pos)}-${style}-${metric}`, kv: kvOf(style, pos, metric), row, chips: chip, hover: Boolean(opts.hover) && n % 4 === 0, idle: opts.idle && n % 8 === 0 ? 6000 : 0, above: 180 });
        n += 1;
      }
    }
  }
  return cells;
}

// Accounts, data states, Show, the parts on the line, Stacked's specials, the line's background, pace and colors:
// each a cell with what its line and card must (and mustn't) say. The overlay's other status is on throughout.
const K = (o) => Object.fromEntries(Object.entries(o).map(([k, v]) => [`omp-usage.${k}`, v]));
const ALL_OFF = { provider: false, window: false, bar: false, share: false, reset: false, saved: false, plan: false, others: false };
export function data() {
  const c = (name, o) => ({ name, cache: "single", kv: {}, ...o, kv: K(o.kv ?? {}) });
  return [
    // data states, Current model (chip Opus 5.5)
    c("fresh", { lineExpect: "62% left", dim: false, notExpect: "as of", hover: true }),
    c("age-11m", { age: 11, lineExpect: "62% left", expect: "as of 11m ago", dim: true, hover: true }),
    c("age-31m-fallback", { age: 31, lineExpect: "33% left", lineNot: "62%", consistent: false }),
    c("back-fresh", { lineExpect: "62% left", dim: false }),
    c("passed-reset", { cache: "passed", lineExpect: "5H reset", expect: "waiting for new numbers", hover: true }),
    c("v1-cache", { cache: undefined, fixture: "v1", lineExpect: "57% left", dim: false }),
    c("oversize-cache", { cache: undefined, fixture: "oversize", lineExpect: "too big", consistent: false }),
    c("after-oversize", { lineExpect: "62% left" }),
    c("missing-cache", { cache: undefined, fixture: "missing", lineExpect: "33% left", consistent: false }),
    c("garbage-cache", { cache: undefined, fixture: "garbage", consistent: false }),
    c("edge-left", { cache: "edge", lineExpect: "<1% left", expect: "0% left", hover: true }),
    c("edge-used", { cache: "edge", kv: { metric: "used" }, lineExpect: ">99% used", expect: "100% used", hover: true }),
    c("edge-all", { cache: "edge", kv: { mode: "all" }, lineExpect: "Codex", hover: true }),
    c("edge-all-used-stack", { cache: "edge", kv: { mode: "all", metric: "used", place: "stack" }, lineExpect: "used|more" }),
    c("clash-status-claude", { cache: "clash", lineExpect: "62% left", lineNot: "91%" }),
    c("clash-status-codex", { cache: "clash", status: "Codex 5h ████░░░░ 50% left (2h) · 7d ███░░░░░ 33% left (4d)", lineExpect: "^Codex", lineNot: "62%" }),
    c("status-back", { status: "Claude 5h ███░░░░░ 33% left (1h 2m) · 7d ██████░░ 77% left (3d 4h)", lineExpect: "62% left" }),
    // Show
    c("all-six", { cache: "six", kv: { mode: "all" }, lineExpect: "Claude[\\s\\S]*Codex[\\s\\S]*Zai", hover: true }),
    c("selected-codex", { kv: { mode: "selected", selected: ["openai-codex"] }, lineExpect: "^Codex", lineNot: "Claude" }),
    c("selected-zai", { cache: "zai", kv: { mode: "selected", selected: ["zai", "zai-coding-plan"] }, lineExpect: "Zai-Coding", hover: true }),
    c("selected-none", { kv: { mode: "selected", selected: [] }, consistent: false }),
    c("order-codex-first", { kv: { mode: "all", order: ["openai-codex", "anthropic"] }, lineExpect: "^Codex[\\s\\S]*Claude" }),
    c("hidden-5h", { kv: { hidden: { anthropic: ["5h"] } }, lineNot: "5H", notExpect: "5-hour" }),
    c("hidden-fable", { kv: { hidden: { anthropic: ["fable 7d"] } }, lineNot: "FABLE", notExpect: "Fable weekly window" }),
    // accounts
    c("multi-current", { cache: "multi", lineExpect: "alice[\\s\\S]*bob[\\s\\S]*carol", hover: true }),
    c("multi-only-bob", { cache: "multi", kv: { account: { anthropic: "bob" } }, lineExpect: "bob", lineNot: "alice|carol", hover: true, consistent: false }),
    c("multi-combined", { cache: "multi", kv: { account: { anthropic: "\u0001combined" } }, expect: "3 accounts", hover: true, consistent: false }),
    c("multi-by-plan", { cache: "multi", kv: { account: { anthropic: "\u0001plans" } }, expect: "Max|Ultra|Pro", hover: true, consistent: false }),
    c("multi-hide-bob", { cache: "multi", kv: { "account-hidden": { anthropic: ["bob"] } }, notExpect: "bob" }),
    c("multi-order", { cache: "multi", kv: { "account-order": { anthropic: ["carol", "alice", "bob"] } }, lineExpect: "^Claude carol" }),
    c("multi-plan-hidden", { cache: "multi", kv: { "plan-hidden": { anthropic: ["alice"] }, "line-parts": { plan: true } }, hover: true }),
    c("multi-all", { cache: "multi", kv: { mode: "all" }, lineExpect: "Codex", hover: true }),
    c("multi-all-combined-both", { cache: "multi", kv: { mode: "all", account: { anthropic: "\u0001combined", "openai-codex": "\u0001plans" } }, expect: "3 accounts", hover: true, consistent: false }),
    c("many-rows-16", { cache: "many", kv: { "card-rows": 16 }, cardRowsMax: 17, hover: true, consistent: false }),
    c("many-rows-26", { cache: "many", kv: { "card-rows": 26 }, cardRowsMax: 27, hover: true, consistent: false }),
    c("many-rows-50", { cache: "many", kv: { "card-rows": 50 }, cardRowsMax: 51, cardRowsMin: 30, hover: true, consistent: false }),
    c("many-by-plan", { cache: "many", kv: { account: { anthropic: "\u0001plans" } }, hover: true, consistent: false }),
    c("sources-all", { cache: "sources", kv: { mode: "all" }, lineExpect: "Codex@proxy[\\s\\S]*Claude@dashboard|Claude@dashboard[\\s\\S]*Codex@proxy", hover: true, consistent: false }),
    c("sources-keeper-only", { cache: "sources", kv: { mode: "selected", selected: ["keeper:dashboard:anthropic"] }, lineExpect: "Claude@dashboard", hover: true }),
    c("nolimits-all", { cache: "nolimits", kv: { mode: "all" }, lineNot: "Kimi" }),
    // the parts on the line (Other statuses on: the overlay's other status shows)
    c("parts-default-others", { ctl: { other: "demo: other extension" }, lineExpect: "demo: other extension" }),
    c("parts-provider-off", { kv: { "line-parts": { provider: false } }, lineNot: "Claude" }),
    c("parts-window-off", { kv: { "line-parts": { window: false } }, lineNot: "5H|7D" }),
    c("parts-bar-off", { kv: { "line-parts": { bar: false } }, lineNot: "━", lineExpect: "62% left" }),
    c("parts-share-off", { kv: { "line-parts": { share: false } }, lineNot: "%", lineExpect: "━" }),
    c("parts-reset-off", { kv: { "line-parts": { reset: false } }, lineNot: "\\d+h \\d+m|3d \\d+h" }),
    c("parts-saved-off", { kv: { "line-parts": { saved: false } }, lineNot: "\\+1" }),
    c("parts-others-off", { kv: { "line-parts": { others: false } }, lineNot: "demo: other" }),
    c("parts-plan-on", { kv: { "line-parts": { plan: true } }, lineExpect: "Ultra" }),
    c("parts-all-but-share", { kv: { "line-parts": { ...ALL_OFF, share: true } }, lineExpect: "62% left", lineNot: "Claude|5H|━|\\+1|demo" }),
    c("parts-all-but-bar", { kv: { "line-parts": { ...ALL_OFF, bar: true } }, lineExpect: "━", lineNot: "%" }),
    c("parts-all-off", { kv: { "line-parts": ALL_OFF }, lineExpect: "62% left" }),
    c("parts-compact-share-off", { kv: { style: "compact", "line-parts": { share: false } }, lineExpect: "62%" }),
    c("parts-ring-share-off", { kv: { style: "ring", "line-parts": { share: false } }, lineNot: "%" }),
    c("parts-ring-all-off", { kv: { style: "ring", "line-parts": ALL_OFF }, lineExpect: "62%" }),
    c("parts-plan-on-stack", { kv: { place: "stack", "line-parts": { plan: true } }, lineExpect: "Ultra" }),
    c("parts-plan-on-provider-off", { kv: { "line-parts": { plan: true, provider: false } }, lineExpect: "Ultra" }),
    // Stacked's specials
    c("stack-multi-repeats", { cache: "multi", kv: { place: "stack" }, cssExpect: "content: \"[^\"]*Claude", hover: true }),
    c("stack-multi-provider-off", { cache: "multi", kv: { place: "stack", "line-parts": { provider: false } }, hover: true }),
    c("stack-six-more", { cache: "six", kv: { mode: "all", place: "stack" }, lineExpect: "\\+\\d+ more · lowest", hover: true }),
    c("stack-six-more-used", { cache: "six", kv: { mode: "all", place: "stack", metric: "used" }, lineExpect: "\\+\\d+ more · most used" }),
    c("stack-six-more-left", { cache: "six", kv: { mode: "all", place: "stack", align: "left", style: "blocks" }, lineExpect: "\\+\\d+ more", hover: true }),
    c("stack-many-ring", { cache: "many", kv: { place: "stack", style: "ring" }, lineExpect: "more", consistent: false }),
    // the line's background
    c("backdrop-glass", { kv: { backdrop: "glass" }, cssExpect: "blur\\(2\\.5px\\)", hover: true }),
    c("backdrop-solid", { kv: { backdrop: "solid" }, cssNot: "blur\\(2\\.5px\\)", cssExpect: "\\{\\n\\tbackground-color: var\\(--ou-glass\\);\\n\\}" }),
    c("backdrop-clear", { kv: { backdrop: "clear" }, cssNot: "blur\\(2\\.5px\\)|\\{\\n\\tbackground-color: var\\(--ou-glass\\);\\n\\}" }),
    // pace (single: 5h 0.6×, 7d and Fable keep pace)
    c("pace-off", { kv: { pace: "off" }, notExpect: "× pace" }),
    c("pace-always", { kv: { pace: "always" }, expect: "× pace", hover: true }),
    c("pace-ahead-edge", { cache: "edge", kv: { pace: "ahead" }, hover: true }),
    // colors
    c("colors-sunset", { kv: { colors: { anthropic: "named:sunset" } }, cssExpect: "#fb7185", hover: true }),
    c("colors-custom-two", { kv: { mode: "all", colors: { anthropic: "#22d3ee, #a78bfa" } }, cssExpect: "#22d3ee", hover: true }),
    c("colors-near-white", { kv: { colors: { anthropic: "#fafafa" } }, cssExpect: "light-dark\\(" }),
    c("colors-accent", { kv: { colors: { anthropic: "named:accent" } }, cssExpect: "--ou-g1-a: var\\(--accent\\)" }),
    c("colors-garbage", { kv: { colors: { anthropic: "red; } body { display:none" } }, cssNot: "display:none" }),
  ];
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].replaceAll("\\", "/").split("/").pop())) {
  const [kind, label, optsArg = "{}"] = process.argv.slice(2);
  const opts = JSON.parse(optsArg);
  const cells = kind === "display" ? display() : kind === "data" ? data() : layout(opts.rows ?? ["none", "progress", "widget"], opts.chips ?? [0, 1], opts);
  console.log(JSON.stringify({ label, cells }));
}
