// Mirror of the built-in `usage` statusline segment showing quota REMAINING
// instead of USED: a fresh account reads 100% left, an exhausted one 0% left.
// Saved resets appear only on 7d windows: (+N), or (!N - 3d 2h left) when an
// applicable available credit expires within 5 days. Countdown is the earliest
// credit expiry.
//
// Shown for any model whose provider has an `omp usage` report with limits
// (Anthropic, OpenAI Codex, Kimi, Gemini CLI, Muse Code, …); otherwise the
// status is cleared. A limit metered for one tier of the plan's models but
// counting toward the plan (e.g. Claude Fable 7d) is shown for every model as
// its own window, labeled with the tier (`Fable 7d`), beside the general one.
// A limit naming a model (e.g. Codex Spark 5h) is shown, labeled the same
// way, only while that model is active, so a missing general window is never
// backfilled; a tier none of the provider's models belong to names its plan
// and is a general window. Windows of any length are shown: 5h, 1d, 7d and mo
// by name, others by their length.
//
// Footer wiring: put "status" in statusLine.leftSegments/rightSegments (that
// segment renders ctx.ui.setStatus values).
//
// Native reports come from `omp usage --json`: one fetch at a time per
// session, on start, every 60s, and after a turn (at most one start per 20s;
// a turn that ends during a fetch or right after one gets one more fetch once
// the 20s are up). A periodic or model-switch fetch is skipped while LINES_FILE
// holds a fetch some session started under 30s ago. Configured CPA/Keeper
// sources have their own polling intervals and keep the actual quota
// observation time. Model switches redraw immediately from the last reports.
// Native and source results are drawn and written as each arrives.
//
// Every available model's line, windows and saved-reset expiries are also
// written to LINES_FILE, keyed by the name omp's model chip shows. The Tern
// omp-usage plugin draws the focused pane's line from it, so every pane shows
// the newest numbers any session has, and reads it for the hover card. Every
// session writes it, keeping per entry whichever numbers were observed later
// (its own or the file's), so a session can't put older numbers back.
import { Buffer } from "node:buffer";
import { execFile as nodeExecFile } from "node:child_process";
import * as nodeFs from "node:fs";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { loadUsageSources } from "./usage-sources/index.js";
import { finite } from "./usage-sources/common.js";
import { cleanText, limitDetails, planRow, reportNotes } from "./usage-sources/details.js";

const STATUS_KEY = "usage-remaining";
const INTERVAL_MS = 60_000;
const MODEL_CHECK_MS = 1_000;
const RESET_EXPIRY_WARN_MS = 5 * 86_400_000;
const TIMEOUT_MS = 15_000;
const LINES_FILE = join(homedir(), ".omp", "cache", "usage-remaining.json");
const LINES_REFRESH_MS = 120_000;
const LINES_SCHEMA = 2;
// The most LINES_FILE should take; the plugin reads up to 1 MiB of it.
const LINES_MAX_BYTES = 900_000;
// A session starts at most one native fetch per THROTTLE_MS, and skips a
// periodic one while LINES_FILE's fetch started less than SHARED_FRESH_MS ago.
const THROTTLE_MS = 20_000;
const SHARED_FRESH_MS = 30_000;
// How long the file keeps an entry no session writing it has numbers for (the
// plugin falls back to omp's status for entries this old anyway).
const KEEP_UNHEARD_MS = 30 * 60_000;
const RENAME_RETRY_MS = 100;
// How far a report's own observation time may run ahead of this clock.
const CLOCK_SKEW_MS = 60_000;

// This file's text as the session loaded it. Every omp session writes
// LINES_FILE, and a session started before an update keeps running the old
// code, so it would overwrite the updated sessions' lines with its own (a
// Fable reset's date flipping between two values). A session whose file on
// disk no longer matches what it loaded stops writing; its own status line
// stays as it was until it restarts.
const SELF_FILE = (() => {
  try {
    return fileURLToPath(import.meta.url);
  } catch {
    return undefined;
  }
})();
const SOURCE_FILES = ["common.js", "cpa.js", "keeper.js", "details.js", "reset-credits.js", "index.js"]
  .map((name) => fileURLToPath(new URL(`./usage-sources/${name}`, import.meta.url)));
const SELF_SOURCE = readSelf();

function readSelf() {
  try {
    return SELF_FILE ? [SELF_FILE, ...SOURCE_FILES].map((file) => readFileSync(file, "utf8")).join("\n") : undefined;
  } catch {
    return undefined;
  }
}

function ompBin() {
  const exe = process.execPath ?? "";
  return /omp(\.exe)?$/i.test(exe) ? exe : "omp";
}

// `omp usage --json` parsed; null when it fails or doesn't parse.
function fetchUsageJson(execFile) {
  return new Promise((resolve) => {
    try {
      execFile(ompBin(), ["usage", "--json"], { timeout: TIMEOUT_MS, windowsHide: true }, (err, stdout) => {
        if (err || !stdout) return resolve(null);
        try {
          resolve(JSON.parse(String(stdout)));
        } catch {
          resolve(null);
        }
      });
    } catch {
      resolve(null);
    }
  });
}

// Model splits identity: `provider` is its own field and `id` is usually bare
// ("gpt-5.6-sol"), so prefer the field and only split a composite id
// ("openai-codex/gpt-5.6-sol") as fallback.
function identity(m) {
  if (!m || typeof m !== "object") return { provider: "", bare: "" };
  const provider = String(m.provider ?? "").toLowerCase();
  const rawId = String(m.id ?? "");
  const slash = rawId.indexOf("/");
  const bare = (slash >= 0 ? rawId.slice(slash + 1) : rawId).toLowerCase();
  if (provider) return { provider, bare };
  if (slash > 0) return { provider: rawId.slice(0, slash).toLowerCase(), bare };
  return { provider: "", bare };
}

function activeModel(ctx) {
  try {
    return identity(ctx?.models?.current?.() ?? ctx?.model);
  } catch {
    return { provider: "", bare: "" };
  }
}

// The label omp's model chip shows (the statusline's model segment): the
// model's name, else its id, without a leading "Claude ".
function chipName(m) {
  const name = String(m?.name || m?.id || "");
  return name.startsWith("Claude ") ? name.slice(7) : name;
}

// Any provider can have a usage report; providerReports decides whether one exists.
function isTrackedProvider(provider) {
  return provider !== "";
}

const HOUR_MS = 3_600_000;
const DAY_MS = 86_400_000;

// A window's length as one token: `2h`, `3d`, `90m`.
function spanLabel(ms) {
  const mins = Math.round(ms / 60_000);
  if (mins % 1440 === 0) return `${mins / 1440}d`;
  if (mins % 60 === 0) return `${mins / 60}h`;
  return `${mins}m`;
}

// A limit's window as { key, label, ms }: `key` keeps one limit per window on
// a line, `label` is what the line shows and `ms` orders the windows. The
// usual ones get fixed labels (5h, 1d, 7d, mo), matched by omp's id or their
// length; any other is labeled by its length, else by omp's id for it, so an
// unfamiliar window is shown rather than dropped.
function windowOf(limit) {
  const window = limit?.window ?? {};
  const windowId = limit?.scope?.windowId ?? window.id;
  const durationMs = typeof window.durationMs === "number" && window.durationMs > 0 ? window.durationMs : undefined;
  const near = (ms) => durationMs !== undefined && Math.abs(durationMs - ms) <= 60_000;
  if (windowId === "5h" || near(5 * HOUR_MS)) return { key: "5h", label: "5h", ms: 5 * HOUR_MS };
  if (windowId === "daily" || windowId === "24h" || windowId === "1d" || near(DAY_MS)) {
    return { key: "daily", label: "1d", ms: DAY_MS };
  }
  if (windowId === "7d" || near(7 * DAY_MS)) return { key: "7d", label: "7d", ms: 7 * DAY_MS };
  if (
    windowId === "monthly" ||
    windowId === "30d" ||
    (durationMs !== undefined && durationMs >= 28 * DAY_MS && durationMs <= 31 * DAY_MS)
  ) {
    return { key: "monthly", label: "mo", ms: 30 * DAY_MS };
  }
  if (durationMs !== undefined) {
    const label = spanLabel(durationMs);
    return { key: label, label, ms: durationMs };
  }
  const id = typeof windowId === "string" ? windowId.trim().replace(/\s+/g, "-") : "";
  return id ? { key: id, label: id, ms: Infinity } : undefined;
}

function fmtResetShort(ms) {
  if (!Number.isFinite(ms) || ms <= 0) return "soon";
  const mins = Math.round(ms / 60_000);
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  const rem = mins % 60;
  if (hours < 24) return rem ? `${hours}h ${rem}m` : `${hours}h`;
  const days = Math.floor(hours / 24);
  const h = hours % 24;
  return h ? `${days}d ${h}h` : `${days}d`;
}

// One-word labels: the line's first word names its provider (the Tern plugin
// keys colors and change animations on it). Providers not listed get one from
// their id (see shortProvider).
const PROVIDER_LABELS = {
  anthropic: "Claude",
  "openai-codex": "Codex",
  openai: "OpenAI",
  "kimi-code": "Kimi",
  "google-gemini-cli": "Gemini",
  "google-antigravity": "Antigravity",
  "minimax-code": "MiniMax",
  "opencode-go": "Go",
  "alibaba-token-plan": "Qwen",
  synthetic: "Synthetic",
  devin: "Devin",
  xai: "Grok",
  "github-copilot": "Copilot",
};

// Words in provider ids that name the product or plan, not the provider.
const GENERIC_ID_WORDS = new Set(["api", "cli", "code", "coding", "plan", "subscription", "token"]);

const SOURCE_ID = /^(cpa|keeper):([^:]+):(.+)$/;

// Whether a provider id names a configured CPA/Keeper source's provider.
function isExternal(provider) {
  return SOURCE_ID.test(provider);
}

// A provider's label: its listed one, else the first word of its id that names
// it, capitalized (`muse-code` reads `Muse`, `zai-coding-plan` `Zai`). See
// providerLabels for providers that would share one.
function shortProvider(provider) {
  const source = SOURCE_ID.exec(provider);
  if (source) return `${source[3] === "status" ? source[1].toUpperCase() : shortProvider(source[3])}@${source[2]}`;
  const known = PROVIDER_LABELS[provider];
  if (known) return known;
  const word = provider.split(/[^a-z0-9]+/i).find((w) => w && !GENERIC_ID_WORDS.has(w.toLowerCase()));
  return word ? word[0].toUpperCase() + word.slice(1) : provider.replace(/\s+/g, "-");
}

// The words of a provider id from the one its short label names, capitalized.
function labelWords(id, short) {
  const words = id.split(/[^a-z0-9]+/i).filter(Boolean);
  const start = words.findIndex((w) => w.toLowerCase() === short.toLowerCase());
  return (start < 0 ? words : words.slice(start)).map((w) => w[0].toUpperCase() + w.slice(1));
}

// Labels for provider ids (no source ids) that no two of `ids` share. Of
// providers sharing a short label, the one it was made for keeps it (its
// listed one, or the one whose id is the label); each other adds the words of
// its id that follow, one at a time, until it reads unlike the rest (`zai`
// stays `Zai`, `zai-coding-plan` reads `Zai-Coding`). Any still alike get their
// place appended.
function uniqueNames(ids) {
  const short = new Map(ids.map((id) => [id, shortProvider(id)]));
  const names = new Map(short);
  const shorts = new Set(short.values());
  const owns = (id) => Object.hasOwn(PROVIDER_LABELS, id) || id === short.get(id).toLowerCase();
  for (const label of shorts) {
    const group = ids.filter((id) => short.get(id) === label);
    if (group.length < 2) continue;
    const owners = group.filter(owns);
    const extend = owners.length === 1 ? group.filter((id) => id !== owners[0]) : group;
    const words = new Map(extend.map((id) => [id, labelWords(id, label)]));
    for (const id of extend) {
      const own = words.get(id);
      let name = own.join("-") || label;
      for (let k = 2; k <= own.length; k++) {
        const candidate = own.slice(0, k).join("-");
        const clashes = shorts.has(candidate) || extend.some((other) => other !== id && words.get(other).slice(0, k).join("-") === candidate);
        if (!clashes) {
          name = candidate;
          break;
        }
      }
      names.set(id, name);
    }
  }
  const all = ids.map((id) => names.get(id));
  ids.forEach((id, i) => {
    if (all.indexOf(all[i]) !== all.lastIndexOf(all[i])) names.set(id, `${all[i]}#${i + 1}`);
  });
  return names;
}

// Every provider in `reports` with its label, unique among them: omp's own
// providers among themselves, and each source's (`Zai@cpa`) among that
// source's.
function providerLabels(reports) {
  const ids = [...new Set(reports.map((r) => String(r?.provider ?? "").toLowerCase()).filter(Boolean))];
  const groups = new Map();
  for (const id of ids) {
    const source = SOURCE_ID.exec(id);
    const key = source ? `${source[1]}:${source[2]}` : "";
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(id);
  }
  const labels = new Map();
  for (const [key, members] of groups) {
    if (!key) {
      for (const [id, name] of uniqueNames(members)) labels.set(id, name);
      continue;
    }
    const bases = members.map((id) => SOURCE_ID.exec(id)[3]).filter((base) => base !== "status");
    const names = uniqueNames(bases);
    for (const id of members) {
      const [, type, sourceId, base] = SOURCE_ID.exec(id);
      labels.set(id, `${base === "status" ? type.toUpperCase() : names.get(base)}@${sourceId}`);
    }
  }
  return labels;
}

// The bare ids of each provider's available models (ctx.models.list()), by
// provider; null when the list isn't known.
function modelIndex(models, sources, reports) {
  if (!Array.isArray(models)) return null;
  const index = new Map();
  for (const m of models) {
    const { provider: original, bare } = identity(m);
    const provider = sources ? sources.resolve(original, bare, reports ?? []) : original;
    if (!provider || !bare) continue;
    if (!index.has(provider)) index.set(provider, []);
    index.get(provider).push(bare);
  }
  return index;
}

function scopeText(value) {
  return typeof value === "string" && value.trim() ? value.trim().toLowerCase() : "";
}

// Whether model `bare` belongs to a tier/model scope.
function inScope(modelId, tier, bare) {
  if (!bare) return false;
  if (modelId && bare !== modelId && !bare.includes(modelId)) return false;
  return !tier || bare.includes(tier);
}

// How a limit counts, as { kind, name, modelId, tier } (`name`: what labels
// its window, "" for a general one). `bares`: the provider's model ids,
// undefined when they aren't known.
// - "plan": a general window, counting toward every model. No tier/model
//   scope; or a tier that omp marks shared (Muse Code's tier is its plan name)
//   or that none of the provider's models belong to, which then names
//   something other than a model.
// - "meter": a tier without a model id (Claude Fable 7d): a separate meter on
//   the same plan, shown for every model as its own window, so the plan's
//   meters all show whichever model is active.
// - "model": names a model id (Codex Spark 5h, which omp marks shared too):
//   it only applies while a model in its scope is active.
function scopeOf(limit, bares) {
  const scope = limit?.scope ?? {};
  const modelId = scopeText(scope.modelId);
  const tier = scopeText(scope.tier);
  if (modelId) return { kind: "model", name: tier || modelId, modelId, tier };
  const display = scopeText(limit?.displayLabel);
  if (display) return { kind: modelId ? "model" : "meter", name: display, modelId, tier };
  if (limit?.id === "anthropic:7d:fable") return { kind: "meter", name: "fable", modelId, tier };
  if (!tier || scope.shared === true || (bares && !bares.some((b) => inScope("", tier, b)))) {
    return { kind: "plan", name: "", modelId, tier };
  }
  return { kind: "meter", name: tier, modelId, tier };
}

// Whether a limit counts toward model `bare` ("" for the provider's windows
// that count toward every model).
function limitApplies(limit, activeBare, bares) {
  const scope = scopeOf(limit, bares);
  return scope.kind !== "model" || inScope(scope.modelId, scope.tier, activeBare);
}

// The provider's model ids from modelIndex's index; undefined when unknown.
function providerBares(report, index) {
  return index ? (index.get(String(report.provider).toLowerCase()) ?? []) : undefined;
}

// The test for which of a report's limits count toward model `bare`.
function appliesTo(bare, bares) {
  return (limit) => limitApplies(limit, bare, bares);
}

// Anthropic's Fable reset credits clear the Fable meter alone: omp's limit id,
// or (older omp) the API meter. A full reset that also clears the Fable meter
// counts on the general 7d window only, so each credit shows once.
// A later Fable credit can be unavailable until the preceding one is used;
// remainingCount and the report's availableCount still include it.
const FABLE_METERS = ["anthropic:7d:fable", "anthropic:reset:seven_day_overage_included"];

function creditApplies(c, report, limit, general) {
  if ((report.metadata?.baseProvider ?? report.provider) === "anthropic" && limit.id === "anthropic:7d:fable") {
    const clears = Array.isArray(c?.clears) ? c.clears : [];
    return clears.some((id) => FABLE_METERS.includes(id)) && !clears.includes("anthropic:7d")
      && c.remainingCount > 0 && (c.status === "available" || c.status === "unavailable");
  }
  if (c?.status !== "available" || c.usable === false || c.remainingCount <= 0) return false;
  return Array.isArray(c.clears) ? c.clears.includes(limit.id) : general;
}

function stashFor(report, limit, wc, general) {
  const rc = report?.resetCredits;
  if (!rc || wc === "monthly") return 0;
  const credits = Array.isArray(rc.credits) ? rc.credits : [];
  if (!credits.some((c) => Array.isArray(c?.clears))) {
    return general && typeof rc.availableCount === "number" ? rc.availableCount : 0;
  }
  return credits.reduce((n, c) => n + (creditApplies(c, report, limit, general)
    ? (typeof c.remainingCount === "number" ? c.remainingCount : 1) : 0), 0);
}

// Find the earliest applicable saved-reset expiry within the warning window.
function expiringResetLeft(report, limit, wc, now, general) {
  if (wc === "monthly") return undefined;
  const credits = Array.isArray(report?.resetCredits?.credits) ? report.resetCredits.credits : [];
  let soonest = Infinity;
  for (const c of credits) {
    if (!creditApplies(c, report, limit, general)) continue;
    const expiresAt = Date.parse(c.expiresAt);
    if (!Number.isFinite(expiresAt)) continue;
    const left = expiresAt - now;
    if (left > 0 && left <= RESET_EXPIRY_WARN_MS && left < soonest) soonest = left;
  }
  return soonest === Infinity ? undefined : soonest;
}

// Expiries are associated with the same weekly window that displays the count,
// labeled as windowParts labels it (`account` included).
function savedResets(report, applies, bares, account, now) {
  const credits = Array.isArray(report.resetCredits?.credits) ? report.resetCredits.credits : [];
  const out = [];
  for (const limit of report.limits ?? []) {
    const w = windowOf(limit);
    if (!applies(limit) || w?.key !== "7d") continue;
    const scope = scopeOf(limit, bares).name.replace(/\s+/g, "-");
    const scoped = scope ? `${scope[0].toUpperCase()}${scope.slice(1)} ${w.label}` : w.label;
    const label = account ? `${account} ${scoped}` : scoped;
    for (const c of credits) {
      if (!creditApplies(c, report, limit, !scope)) continue;
      const expiresAt = Date.parse(c.expiresAt);
      if (!Number.isFinite(expiresAt) || expiresAt <= now) continue;
      out.push({ expiresAt, count: typeof c.remainingCount === "number" ? c.remainingCount : 1, window: label });
    }
  }
  return out.sort((a, b) => a.expiresAt - b.expiresAt);
}

// The model families a tier meter counts: Claude's Fable weekly meter also
// meters Mythos (omp's usage reports name only Fable for the one counter).
const METER_FAMILIES = { fable: ["fable", "mythos"] };

// Whether model `bare` draws on a tier meter (see scopeOf): `Fable 7d` for
// claude-fable-5 and claude-mythos-5.
function metersModel(scope, bare) {
  if (!bare || scope.kind !== "meter") return false;
  const families = METER_FAMILIES[scope.name] ?? [scope.tier || scope.name];
  return families.some((family) => family && bare.includes(family));
}

// A remaining fraction as the line shows it: whole percents rounded down, so a
// window never reads fuller than it is, and `<1%` for what's left below 1%.
function pctText(remaining) {
  if (remaining <= 0) return "0%";
  if (remaining < 0.01) return "<1%";
  // The epsilon keeps 1 - 0.71 (0.29 less a rounding error) at 29%.
  return `${Math.floor(remaining * 100 + 1e-9)}%`;
}

// The windows `applies` passes, in line order: one per window, a limit with a
// tier/model scope (see scopeOf) on its own, labeled with it (`Fable 7d`) and
// keyed apart from the general window of the same length. `account` (set when
// the provider has several accounts) leads every label: `alice 5h`. The meter
// model `bare` draws on comes first (Fable 7d while a Fable or Mythos model is
// active), so the window that limits it leads the line. Each is { text, window }:
// `text` its piece of the line (`5h ████░░░░ 50% left (2h 10m)`, or `5h reset`
// once its reset time has passed), `window` its numbers for LINES_FILE (see
// writeLines). A stale report has none.
function windowParts(report, applies, bares, account, bare, now) {
  if (report.stale) return [];
  const provider = String(report.provider).toLowerCase();
  const seen = new Map();
  for (const limit of report.limits) {
    if (!applies(limit)) continue;
    const w = windowOf(limit);
    if (!w) continue;
    const scopeInfo = scopeOf(limit, bares);
    const scope = scopeInfo.name.replace(/\s+/g, "-");
    const key = scope ? `${scope}:${w.key}` : w.key;
    if (seen.has(key)) continue;
    const shownScope = scope ? `${scope[0].toUpperCase()}${scope.slice(1)}` : "";
    const scoped = shownScope ? `${shownScope} ${w.label}` : w.label;
    const label = account ? `${account} ${scoped}` : scoped;
    const amount = limit.amount ?? {};
    const remainingFrac =
      typeof amount.remainingFraction === "number"
        ? amount.remainingFraction
        : typeof amount.usedFraction === "number"
          ? 1 - amount.usedFraction
          : undefined;
    if (!Number.isFinite(remainingFrac)) continue;
    const remaining = Math.min(1, Math.max(0, remainingFrac));
    const stash = w.key === "7d" ? stashFor(report, limit, w.key, !scope) : 0;
    const expiryLeft = stash > 0 ? expiringResetLeft(report, limit, w.key, now, !scope) : undefined;
    const extra = stash <= 0
      ? ""
      : expiryLeft === undefined
        ? ` (+${stash})`
        : ` (!${stash} - ${fmtResetShort(expiryLeft)} left)`;
    const resetsAt = typeof limit.window?.resetsAt === "number" && Number.isFinite(limit.window.resetsAt) ? limit.window.resetsAt : undefined;
    let text;
    if (resetsAt !== undefined && resetsAt <= now) {
      // The window has started over since it was measured: its old percent would be wrong.
      text = `${label} reset${extra}`;
    } else {
      const filled = Math.round(remaining * 8);
      const meter = `${"\u2588".repeat(filled)}${"\u2591".repeat(8 - filled)}`;
      const reset = resetsAt !== undefined ? ` (${fmtResetShort(resetsAt - now)})` : "";
      text = `${label} ${meter} ${pctText(remaining)} left${reset}${extra}`;
    }
    const window = {
      provider,
      key: w.key,
      label,
      ...(account ? { account } : {}),
      ...(shownScope ? { scope: shownScope } : {}),
      remaining,
      ...(resetsAt !== undefined ? { resetsAt } : {}),
      ...(Number.isFinite(w.ms) ? { windowMs: w.ms } : {}),
      text,
    };
    seen.set(key, { ms: w.ms, scoped: !!scope, own: metersModel(scopeInfo, bare), text, window });
  }
  // The active model's own meter first; then shortest window first, at the same length the general one before
  // scoped ones.
  return [...seen.values()]
    .sort((a, b) => (a.own !== b.own ? Number(b.own) - Number(a.own)
      : a.ms !== b.ms ? (a.ms < b.ms ? -1 : 1) : Number(a.scoped) - Number(b.scoped)))
    .map(({ text, window }) => ({ text, window }));
}

// Every report with limits for `provider`, in omp's order: one per signed-in
// account, so a provider with several accounts has several.
function providerReports(reports, provider) {
  return reports.filter(
    (r) => r && Array.isArray(r.limits) && (r.limits.length > 0 || r.metadata?.sourceId) && String(r.provider).toLowerCase() === provider,
  );
}

// One word naming each report's account: its email's local part, else the
// start of its account id, else its place in omp's order. Accounts that would
// share a name (several team seats: claude-team@lumen.dev, claude-team@pinegg.gg)
// tell themselves apart by their email's domain, as briefly as that does it:
// its first label (`claude-team@lumen`, `claude-team@pinegg`), else all of it
// (`claude-team@lumen.dev` beside `claude-team@lumen.ai`); two that still match
// get their place appended. So every window label, and the plugin's settings
// per window and per account, stay distinct.
function accountLabels(reports) {
  const accounts = reports.map((report, i) => {
    const email = report?.metadata?.email;
    const id = report?.metadata?.accountId;
    const label = report?.metadata?.label;
    if (typeof label === "string" && label.trim() && !(typeof email === "string" && email.includes("@"))) {
      return { name: cleanText(label).replace(/\s+/g, "-"), domain: "" };
    }
    if (typeof email === "string" && email.includes("@")) {
      const at = email.lastIndexOf("@");
      return { name: email.slice(0, at), domain: email.slice(at + 1).toLowerCase() };
    }
    return { name: typeof id === "string" && id ? id.slice(0, 8) : `#${i + 1}`, domain: "" };
  });
  const alone = (names, i) => names.indexOf(names[i]) === i && names.lastIndexOf(names[i]) === i;
  const plain = accounts.map((a) => a.name);
  const short = accounts.map((a, i) => (alone(plain, i) || !a.domain ? a.name : `${a.name}@${a.domain.split(".")[0]}`));
  const long = accounts.map((a, i) => (alone(short, i) || !a.domain ? short[i] : `${a.name}@${a.domain}`));
  return long.map((name, i) => (alone(long, i) ? name : `${name}#${i + 1}`).replace(/\s+/g, "-"));
}

// For the current model, retain its scopes. External provider overviews include
// all scopes; native overviews prefer shared windows when those are available.
function appliesFor(report, bare, bares) {
  if (!bare && report.metadata?.sourceId) return () => true;
  const applies = appliesTo(bare, bares);
  if (bare || (report.limits ?? []).some((l) => applies(l) && windowOf(l))) return applies;
  return () => true;
}

// What every line, window and detail of one write or draw is made from: the
// reports, the available models' ids by provider (see modelIndex), the clock
// and the providers' labels (see providerLabels).
function makeView(state, reports, now) {
  return { reports, index: modelIndex(state.models, state.sources, reports), now, labels: providerLabels(reports) };
}

// Every account of `provider` with its label ("" with one account) and the
// filter for model `bare`.
function accountsFor(view, provider, bare) {
  const matches = providerReports(view.reports, provider);
  const labels = matches.length > 1 ? accountLabels(matches) : matches.map(() => "");
  return matches.map((report, i) => {
    const bares = providerBares(report, view.index);
    return { report, bares, account: labels[i], applies: appliesFor(report, bare, bares) };
  });
}

// When a report's numbers were observed: omp's own reports carry the time omp
// fetched them (it can answer from its own cache), else the start of the fetch
// that brought them (see startNative); a source's carry its observation time.
const OBSERVED = new WeakMap();

function observedOf(report) {
  return OBSERVED.get(report) ?? finite(report?.observedAt);
}

// The oldest observation among the reports an entry is drawn from: those that
// drew windows, else any; undefined when none has a time.
function observedFor(accounts) {
  const times = (reports) => reports.map(observedOf).filter((at) => at !== undefined);
  const shown = times(accounts.filter((a) => !a.report.stale).map((a) => a.report));
  const all = shown.length ? shown : times(accounts.map((a) => a.report));
  return all.length ? Math.min(...all) : undefined;
}

// The status for a model from fetched reports, with its windows and when they
// were observed; line "" when its provider isn't tracked or has no report.
// With no model (`bare` ""), the provider's windows that count toward every
// model; a provider whose limits are all scoped to some of its models shows
// those instead, so a provider with limits is never left out. With several
// accounts, each account's windows follow in omp's order, labeled with the
// account (`Claude alice 7d … · bob 5h …`).
function drawn(view, provider, bare) {
  if (!isTrackedProvider(provider)) return { line: "", windows: [], observedAt: undefined };
  const accounts = accountsFor(view, provider, bare);
  const parts = accounts.map((a) => windowParts(a.report, a.applies, a.bares, a.account, bare, view.now));
  const pieces = parts.map((p) => p.map(({ text }) => text).join(" · ")).filter(Boolean);
  const label = view.labels.get(provider) ?? shortProvider(provider);
  const line = pieces.length
    ? `${label} ${pieces.join(" · ")}`
    : accounts.some((a) => a.report.metadata?.sourceId) ? `${label} quota details` : "";
  return { line, windows: parts.flat().map(({ window }) => window), observedAt: line ? observedFor(accounts) : undefined };
}

// Extra facts use the same account/window labels as the status, but never its percent grammar.
// Every row is { text, account?, window?, kind?, valueText? }, whole however long it is: the hover card and the
// quota details each wrap a long note themselves, so a note keeps its kind (a stale or failed source reads as
// one) and no view is left with its first words alone.
function detailsFor(view, provider, bare) {
  const details = [];
  const add = (detail, account, window) => {
    const text = cleanText(detail.text);
    if (!text) return;
    details.push({
      text,
      ...(typeof detail.kind === "string" ? { kind: detail.kind } : {}),
      ...(typeof detail.valueText === "string" ? { valueText: detail.valueText } : {}),
      ...(account ? { account } : {}),
      ...(window ? { window } : {}),
    });
  };
  for (const { report, bares, account, applies } of accountsFor(view, provider, bare)) {
    // omp's own reports add only their plan, which rides on the account's heading
    const notes = report.metadata?.sourceId ? reportNotes(report) : [planRow(report)].filter(Boolean);
    for (const note of notes) add(note, account);
    for (const limit of report.limits) {
      if (!applies(limit)) continue;
      if (!report.metadata?.sourceId && (!limit.amount?.unit || ["percent", "unknown"].includes(limit.amount.unit)) && !limit.usage) continue;
      const w = windowOf(limit);
      const scope = scopeOf(limit, bares).name.replace(/\s+/g, "-");
      const scoped = w ? (scope ? `${scope[0].toUpperCase()}${scope.slice(1)} ${w.label}` : w.label) : undefined;
      const window = scoped ? (account ? `${account} ${scoped}` : scoped) : undefined;
      const metered = !report.stale && w && (typeof limit.amount?.remainingFraction === "number" || typeof limit.amount?.usedFraction === "number");
      for (const detail of limitDetails(limit, { estimates: !report.stale, includeShare: !metered })) {
        // A quantity with no drawable window keeps its scope as plain text.
        if (metered) add(detail, account, window);
        else add({ text: `${scoped || cleanText(limit.displayLabel || limit.id)}: ${detail.text}` }, account);
      }
      if (!metered && Number.isFinite(limit.window?.resetsAt)) {
        const reset = new Date(limit.window.resetsAt);
        if (Number.isFinite(reset.getTime())) add({ text: `${scoped || cleanText(limit.displayLabel || limit.id)} resets ${reset.toISOString().slice(0, 16).replace("T", " ")} UTC` }, account);
      }
    }
  }
  return details;
}

// The saved resets of every account of `provider`, soonest expiry first.
function resetsFor(view, provider, bare) {
  if (!isTrackedProvider(provider)) return [];
  return accountsFor(view, provider, bare)
    .filter((a) => !a.report.stale)
    .flatMap((a) => savedResets(a.report, a.applies, a.bares, a.account, view.now))
    .sort((a, b) => a.expiresAt - b.expiresAt);
}

// Draws the status for the active model from the last reports. Until the
// reports its provider comes from have arrived (omp's own, or a configured
// source's), a tracked model keeps the current status.
function render(state, ctx) {
  const { provider: original, bare } = activeModel(ctx);
  state.shownModel = `${original}/${bare}`;
  const reports = state.data && Array.isArray(state.data.reports) ? state.data.reports : null;
  const provider = state.sources ? state.sources.resolve(original, bare, reports ?? []) : original;
  if (!isTrackedProvider(provider)) {
    ctx.ui.setStatus(STATUS_KEY, undefined);
    return;
  }
  if (!reports || !(isExternal(provider) ? state.external !== null : state.native.attempted)) return;
  ctx.ui.setStatus(STATUS_KEY, drawn(makeView(state, reports, state.deps.now()), provider, bare).line || undefined);
}

// Writes LINES_FILE, { schema, generatedAt, fetchedAt, models, providers }:
// - schema: 2. generatedAt: when it was written; unchanged data is still
//   rewritten every LINES_REFRESH_MS, so it says a session is running, not
//   that its numbers are new. fetchedAt: when the newest successful
//   `omp usage` fetch any session wrote started.
// - models: every available model's entry keyed by chip name, line "" when
//   its provider isn't tracked. Models sharing a chip name but not an entry:
//   the name gets null (a reader that knows only the name can't tell which
//   one is shown, so it keeps omp's status rather than draw another one's
//   numbers), and each is written under `<provider>/<chip name>`, `provider`
//   being the one its entry is drawn from (the providers key whose label its
//   line shows). Those that still clash there get null too. An entry is
//   { line, resets, provider, details, windows, observedAt? } in full, but is
//   written compact against its provider's entry when `providers` has one
//   (see compactEntry): with 32 accounts and 220 models, whole entries would
//   make the file 15 MB.
// - providers: every tracked provider with limits, keyed by provider id, in
//   report order, as { label, line, resets, details, baseProvider, windows,
//   observedAt?, accounts? } for the windows that count toward every model,
//   tier meters included (see drawn; no model is given, so model-scoped
//   windows are left out). `label` is unique among the providers (see
//   providerLabels). A provider with several accounts also lists them, as its
//   line names them and in omp's order: `accounts` ["alice", "bob"], which the
//   plugin needs to tell an account (`alice 7d`) from a tier (`Fable 7d`) and
//   to let the user order and pick accounts.
// - windows: the line's windows in its order, { provider, key, label,
//   account?, scope?, remaining, resetsAt?, windowMs?, text } (see
//   windowParts): `provider` the provider id, `label` as the line names it,
//   `remaining` the fraction left, unrounded, `resetsAt` epoch ms, `text` its
//   piece of the line. A window whose reset time had passed when it was
//   written reads `<label> reset` in the line.
// - observedAt: when the entry's numbers were observed (see observedFor); a
//   failed fetch doesn't move it. Absent when no report says.
// Details rows are `{ text, account?, window?, kind?, valueText? }`: `text` is
// always readable, and `kind` (`tokens-used`, `cost-used`, `tokens-estimate`,
// `cost-estimate`, `plan`, `observed`, `stale`, `error`) with its
// already-formatted `valueText` lets the plugin draw a quantity or status
// without parsing prose.
// Each entry keeps whichever was observed later, this session's or the file's
// (see mergeLines). A file that would pass LINES_MAX_BYTES is written without
// details, then without windows too (see linesText).
async function writeLines(state) {
  const { deps } = state;
  const reports = state.data && Array.isArray(state.data.reports) ? state.data.reports : null;
  const models = state.models;
  if (!reports || !Array.isArray(models)) return;
  const now = deps.now();
  const view = makeView(state, reports, now);
  // Every model's entry, with its JSON, by chip name.
  const byName = new Map();
  for (const m of models) {
    const name = chipName(m);
    if (!name) continue;
    const { provider: original, bare } = identity(m);
    const provider = state.sources ? state.sources.resolve(original, bare, reports) : original;
    const { line, windows, observedAt } = drawn(view, provider, bare);
    const entry = {
      line,
      resets: resetsFor(view, provider, bare),
      provider,
      details: detailsFor(view, provider, bare),
      windows,
      ...(observedAt !== undefined ? { observedAt } : {}),
    };
    if (!byName.has(name)) byName.set(name, []);
    byName.get(name).push({ entry, json: JSON.stringify(entry) });
  }
  const entries = new Map();
  const qualified = new Map();
  for (const [name, list] of byName) {
    if (list.every(({ json }) => json === list[0].json)) {
      entries.set(name, list[0].entry);
      continue;
    }
    // Models the chip can't tell apart: each can be found by its provider only.
    entries.set(name, null);
    for (const item of list) {
      const key = `${item.entry.provider}/${name}`;
      const held = qualified.get(key);
      if (held === undefined) qualified.set(key, item);
      else if (held !== null && held.json !== item.json) qualified.set(key, null);
    }
  }
  // A key that is also some model's chip name stays that model's.
  for (const [key, item] of qualified) if (!byName.has(key)) entries.set(key, item && item.entry);
  const providers = new Map();
  for (const r of reports) {
    const provider = String(r?.provider ?? "").toLowerCase();
    if (!isTrackedProvider(provider) || providers.has(provider)) continue;
    const { line, windows, observedAt } = drawn(view, provider, "");
    if (!line) continue;
    const entry = {
      label: view.labels.get(provider) ?? shortProvider(provider),
      line,
      resets: resetsFor(view, provider, ""),
      details: detailsFor(view, provider, ""),
      baseProvider: r.metadata?.baseProvider ?? provider,
      windows,
      ...(observedAt !== undefined ? { observedAt } : {}),
    };
    const accounts = accountsFor(view, provider, "").map((a) => a.account);
    if (accounts.length > 1) entry.accounts = accounts;
    providers.set(provider, entry);
  }
  const body = JSON.stringify({ entries: [...entries], providers: [...providers] });
  if (body === state.writtenLines && now - state.writtenAt < LINES_REFRESH_MS) return;
  if (SELF_SOURCE !== undefined && readSelf() !== SELF_SOURCE) return;
  const disk = readLines(deps);
  const head = {
    schema: LINES_SCHEMA,
    generatedAt: now,
    fetchedAt: Math.max(state.native.fetchedAt, finite(disk?.fetchedAt) ?? 0),
  };
  // The file's compact model entries are made whole against the file's
  // providers before they are weighed against this session's, and every
  // entry is made compact again against the providers it's written beside.
  const keptModels = mergeLines(state, entries, expandModels(disk?.models, disk?.providers), (entry) => entry.provider, disk, now, true);
  const keptProviders = mergeLines(state, providers, disk?.providers, (_entry, id) => id, disk, now, false);
  await writeAtomic(deps, deps.linesFile, linesText(state, head, keptModels, keptProviders));
  state.writtenLines = body;
  state.writtenAt = now;
}

// This session's entries (`mine`, by key) with the file's (`theirs`): of an
// entry both have, the one observed later, this session's on a tie; one only
// the file has stays while it was observed under KEEP_UNHEARD_MS ago and after
// this session last heard from its provider (never, for a source this session
// doesn't poll: sessions can be configured differently). An entry without
// observedAt (it draws nothing, or the file is from before entries said)
// counts as observed when its reports last arrived: this session's last fetch
// or source poll; for the file's, the file's fetchedAt for omp's own
// providers. So a session whose fetch failed, or was skipped while another's
// was fresh, keeps the newer numbers in the file, and one whose own fetch
// never succeeded still writes its sources' numbers. For `models`, chip-name
// clashes are then settled over the merged entries (see settleClashes).
function mergeLines(state, mine, theirs, providerOf, disk, now, models) {
  const polled = new Set((state.external ?? []).map((report) => sourceOf(String(report?.provider ?? "").toLowerCase())));
  const heard = (provider) => {
    if (!isExternal(provider)) return state.native.fetchedAt || -Infinity;
    return polled.has(sourceOf(provider)) ? state.externalAt || -Infinity : -Infinity;
  };
  const diskFetched = finite(disk?.fetchedAt) ?? -Infinity;
  const fileAt = (entry, provider) => finite(entry.observedAt) ?? (isExternal(provider) ? -Infinity : diskFetched);
  const file = theirs && typeof theirs === "object" && !Array.isArray(theirs) ? theirs : {};
  const usable = (entry) => entry && typeof entry === "object" && !Array.isArray(entry);
  const merged = new Map();
  for (const [key, entry] of mine) {
    if (entry === null) {
      merged.set(key, null);
      continue;
    }
    const other = Object.hasOwn(file, key) && usable(file[key]) ? file[key] : undefined;
    const provider = String(providerOf(entry, key) ?? "");
    const ownAt = finite(entry.observedAt) ?? heard(provider);
    merged.set(key, other && fileAt(other, String(providerOf(other, key) ?? "")) > ownAt ? other : entry);
  }
  for (const [key, other] of Object.entries(file)) {
    if (merged.has(key) || !usable(other)) continue;
    const provider = String(providerOf(other, key) ?? "");
    const at = fileAt(other, provider);
    if (at > heard(provider) && now - at < KEEP_UNHEARD_MS) merged.set(key, other);
  }
  if (models) settleClashes(merged);
  return Object.fromEntries(merged);
}

// `cpa:pool` for `cpa:pool:openai-codex`; "" for omp's own providers.
function sourceOf(provider) {
  const source = SOURCE_ID.exec(provider);
  return source ? `${source[1]}:${source[2]}` : "";
}

// Merged model entries can clash where no one session's did: one session
// lists two models under a chip name (null, plus `<provider>/<name>` keys),
// another lists only one of them and writes the name. While another
// provider's `<provider>/<name>` entry differs from the name's, the name is
// null and its entry goes to its own `<provider>/<name>` key (unless an entry
// observed later is there), as writeLines does.
function settleClashes(merged) {
  const qualified = new Map();
  for (const [key, entry] of merged) {
    if (!entry || typeof entry.provider !== "string" || !key.startsWith(`${entry.provider}/`)) continue;
    const name = key.slice(entry.provider.length + 1);
    if (!qualified.has(name)) qualified.set(name, []);
    qualified.get(name).push(entry);
  }
  for (const [name, list] of qualified) {
    const plain = merged.get(name);
    if (!plain || typeof plain.provider !== "string") continue;
    const json = JSON.stringify(plain);
    if (list.every((entry) => entry.provider === plain.provider || JSON.stringify(entry) === json)) continue;
    merged.set(name, null);
    const own = `${plain.provider}/${name}`;
    const held = merged.get(own);
    if (held === undefined || (held && !((finite(held.observedAt) ?? -Infinity) > (finite(plain.observedAt) ?? -Infinity)))) {
      merged.set(own, plain);
    }
  }
}

// A model entry as LINES_FILE holds it: compact against `base`, its
// provider's entry there, when there is one; whole otherwise. A compact
// entry has no `line`. It keeps `provider` and `observedAt`, and only what
// differs from `base`:
// - `windows`, `resets`, `details`: left out when they are base's, else
//   listed: an item base also lists as its index there (from 0), any other
//   in full. Left-out `windows` also means base's line.
// - `text`: the line, unless it is base's label and its windows' texts
//   joined by " · " ("" without windows), as drawn joins them.
// Plugin copies from before compact entries (0.7.10) pass over an entry
// without `line` as over a missing one: the focused model shows omp's own
// status there, never another model's numbers. They read `providers` as ever.
function compactEntry(entry, base) {
  const known = baseIndex(base);
  const out = { provider: entry.provider };
  if (entry.line !== base.line || jsonOf(entry.windows) !== known.windows.json) {
    out.windows = refsTo(entry.windows, known.windows);
    if (composeLine(base.label, entry.windows) !== entry.line) out.text = entry.line;
  }
  if (jsonOf(entry.resets) !== known.resets.json) out.resets = refsTo(entry.resets, known.resets);
  if (jsonOf(entry.details) !== known.details.json) out.details = refsTo(entry.details, known.details);
  if (entry.observedAt !== undefined) out.observedAt = entry.observedAt;
  return out;
}

// compactEntry undone: the whole entry, or undefined when `entry` doesn't
// resolve against `base` (no base, or an index base doesn't have). Whole
// entries come back as they are.
function expandEntry(entry, base) {
  if (!entry || typeof entry !== "object" || typeof entry.line === "string") return entry;
  if (!base || typeof base !== "object" || typeof base.line !== "string") return undefined;
  const pick = (own, from) => {
    const list = Array.isArray(from) ? from : [];
    if (own === undefined) return list;
    if (!Array.isArray(own)) return undefined;
    const items = own.map((item) => (typeof item === "number" ? list[item] : item));
    return items.every((item) => item && typeof item === "object") ? items : undefined;
  };
  const windows = pick(entry.windows, base.windows);
  const resets = pick(entry.resets, base.resets);
  const details = pick(entry.details, base.details);
  const line = typeof entry.text === "string" ? entry.text
    : entry.windows === undefined ? base.line
    : windows && composeLine(base.label, windows);
  if (!windows || !resets || !details || typeof line !== "string") return undefined;
  const observedAt = finite(entry.observedAt);
  return { line, resets, provider: entry.provider, details, windows, ...(observedAt !== undefined ? { observedAt } : {}) };
}

// A line as drawn makes it from its windows; undefined when a window has no
// text.
function composeLine(label, windows) {
  const list = Array.isArray(windows) ? windows : [];
  if (!list.length) return "";
  if (!list.every((w) => typeof w?.text === "string")) return undefined;
  return `${label} ${list.map((w) => w.text).join(" · ")}`;
}

function jsonOf(list) {
  return JSON.stringify(Array.isArray(list) ? list : []);
}

// A provider entry's lists, each as its JSON and the index of each item's
// JSON (the first, for items listed twice); kept while the entry is.
const BASE_INDEX = new WeakMap();

function baseIndex(base) {
  let known = BASE_INDEX.get(base);
  if (!known) {
    const index = (list) => {
      const items = Array.isArray(list) ? list : [];
      const at = new Map();
      items.forEach((item, i) => {
        const json = JSON.stringify(item);
        if (!at.has(json)) at.set(json, i);
      });
      return { json: JSON.stringify(items), at };
    };
    known = { windows: index(base.windows), resets: index(base.resets), details: index(base.details) };
    BASE_INDEX.set(base, known);
  }
  return known;
}

function refsTo(list, known) {
  return (Array.isArray(list) ? list : []).map((item) => known.at.get(JSON.stringify(item)) ?? item);
}

function isMap(value) {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

// Model entries by key, each compact against its provider's entry in
// `providers` when there is one (see compactEntry).
function compactModels(models, providers) {
  return Object.fromEntries(Object.entries(models).map(([key, entry]) => {
    const base = entry && typeof entry.provider === "string" && Object.hasOwn(providers, entry.provider) ? providers[entry.provider] : undefined;
    return [key, base ? compactEntry(entry, base) : entry];
  }));
}

// LINES_FILE's model entries made whole against its providers (see
// expandEntry); one that doesn't resolve is left out, as unreadable.
function expandModels(models, providers) {
  if (!isMap(models)) return models;
  const bases = isMap(providers) ? providers : {};
  const out = {};
  for (const [key, entry] of Object.entries(models)) {
    const base = isMap(entry) && typeof entry.provider === "string" && Object.hasOwn(bases, entry.provider) ? bases[entry.provider] : undefined;
    const whole = isMap(entry) ? expandEntry(entry, base) : entry;
    if (whole !== undefined) out[key] = whole;
  }
  return out;
}

// LINES_FILE's text: `head`, with `models` compact against `providers`. One
// that would pass LINES_MAX_BYTES is written without details, else without
// windows too: the lines and saved resets stay, and the plugin draws from the
// lines. Logged once a session.
function linesText(state, head, models, providers) {
  const sizes = [];
  let text = "";
  let dropped = [];
  for (dropped of [[], ["details"], ["details", "windows"]]) {
    const cut = Object.fromEntries(dropped.map((field) => [field, []]));
    const strip = (entries) => Object.fromEntries(Object.entries(entries).map(([key, entry]) => [key, entry && { ...entry, ...cut }]));
    const shown = dropped.length ? strip(providers) : providers;
    text = JSON.stringify({ ...head, models: compactModels(dropped.length ? strip(models) : models, shown), providers: shown });
    sizes.push(Buffer.byteLength(text));
    if (sizes.at(-1) <= LINES_MAX_BYTES) break;
  }
  if (dropped.length && !state.oversizeLogged) {
    state.oversizeLogged = true;
    state.log(`usage-remaining: the usage cache would take ${sizes[0]} bytes, over ${LINES_MAX_BYTES}; written without ${dropped.join(" and ")} (${sizes.at(-1)} bytes)`);
  }
  return text;
}

// LINES_FILE decoded; null when missing or unreadable.
function readLines(deps) {
  try {
    const doc = JSON.parse(deps.fs.readFileSync(deps.linesFile, "utf8"));
    return doc && typeof doc === "object" && !Array.isArray(doc) ? doc : null;
  } catch {
    return null;
  }
}

// When the newest fetch in LINES_FILE started; 0 when unknown (no file, or
// one written before it said).
function sharedFetchedAt(deps) {
  return finite(readLines(deps)?.fetchedAt) ?? 0;
}

// Writes `file` through a temporary file renamed over it, so a reader never
// sees half of it. A failed rename (the file held open by a reader or a virus
// scan) is tried once more after a moment; the temporary file never stays.
async function writeAtomic(deps, file, text) {
  deps.fs.mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.${process.pid}.tmp`;
  for (let attempt = 1; ; attempt++) {
    try {
      deps.fs.writeFileSync(tmp, text, { mode: 0o600 });
      deps.fs.renameSync(tmp, file);
      return;
    } catch (error) {
      try {
        deps.fs.unlinkSync(tmp);
      } catch {
        // Never written, or already gone.
      }
      if (attempt >= 2) throw error;
      await deps.sleep(RENAME_RETRY_MS);
    }
  }
}

// Asks for a native fetch. Starts one unless one is running (it serves this
// request too), one started under THROTTLE_MS ago, or (once this session has
// reports of its own) LINES_FILE's fetch started under SHARED_FRESH_MS ago.
// `need`: when a turn ended, for a request whose fetch must start after it: it
// isn't served by an earlier start, so it runs once the throttle allows, and
// only a fetch started since then counts as fresh. Resolves once the fetch it
// started or joined has been drawn and written.
function requestNative(state, ctx, need = 0) {
  const n = state.native;
  if (need > n.needAt) n.needAt = need;
  if (n.flight) return n.flight;
  const now = state.deps.now();
  const wait = n.startedAt + THROTTLE_MS - now;
  if (wait > 0) {
    if (n.needAt > n.startedAt) defer(state, ctx, wait);
    return Promise.resolve();
  }
  if (n.fetchedAt > 0 && sharedFetchedAt(state.deps) >= Math.max(now - SHARED_FRESH_MS, n.needAt)) {
    n.needAt = 0;
    return Promise.resolve();
  }
  return startNative(state, ctx);
}

// Asks again in `wait` ms; one pending ask at a time.
function defer(state, ctx, wait) {
  const n = state.native;
  if (n.deferred) return;
  n.deferred = true;
  const run = () => {
    n.deferred = false;
    void requestNative(state, ctx);
  };
  if (typeof ctx?.setTimeout === "function") ctx.setTimeout(run, wait);
  else state.deps.setTimeout(run, wait);
}

// One `omp usage --json` fetch. Its start is recorded before it runs; its
// reports replace the last ones only when it succeeds and started after them,
// so a failed fetch leaves the reports and their observation times as they
// were. A turn that ended while it ran asks for one more.
//
// A successful fetch doesn't mean new numbers: omp answers from its own usage
// cache, refreshing each account's report about every 5 minutes (±25%
// jitter), and when the provider can't be reached it keeps answering with the
// last good report for up to 24 hours. Each report's `fetchedAt` says when omp
// really got it, so that (not this fetch's start) is the report's observation
// time: healthy numbers are normally up to ~7 minutes old, and omp serving an
// old last-good report shows as an old observedAt beside a recent fetchedAt.
// A report without `fetchedAt` counts as observed when this fetch started.
function startNative(state, ctx) {
  const n = state.native;
  const startedAt = state.deps.now();
  n.startedAt = startedAt;
  n.needAt = 0;
  n.flight = (async () => {
    try {
      const data = await state.deps.fetchUsage();
      if (data && Array.isArray(data.reports) && startedAt > n.fetchedAt) {
        const end = state.deps.now();
        for (const report of data.reports) {
          if (!report || typeof report !== "object") continue;
          const at = finite(report.fetchedAt);
          OBSERVED.set(report, at !== undefined && at <= end + CLOCK_SKEW_MS ? Math.min(at, end) : startedAt);
        }
        n.reports = data.reports;
        n.fetchedAt = startedAt;
      }
    } catch {
      // As a failed fetch.
    } finally {
      n.attempted = true;
      n.flight = null;
    }
    await publish(state, ctx);
    if (n.needAt > startedAt) defer(state, ctx, Math.max(0, n.startedAt + THROTTLE_MS - state.deps.now()));
  })();
  return n.flight;
}

// Polls the configured sources (each keeps its own interval) and draws and
// writes what they return; one poll at a time.
function refreshExternal(state, ctx) {
  if (state.externalFlight) return state.externalFlight;
  state.externalFlight = (async () => {
    try {
      const reports = state.sources ? await state.sources.poll() : [];
      state.external = Array.isArray(reports) ? reports : [];
      state.externalAt = state.deps.now();
    } catch {
      // The last reports stay; the next poll retries.
    } finally {
      state.externalFlight = null;
    }
    await publish(state, ctx);
  })();
  return state.externalFlight;
}

// Draws the status and writes LINES_FILE from the last native and source
// reports, one publish at a time. Nothing is drawn before either has any.
function publish(state, ctx) {
  state.publishing = state.publishing.then(async () => {
    try {
      if (!state.native.attempted && !state.external?.length) return;
      state.data = { reports: [...state.native.reports, ...(state.external ?? [])] };
      try {
        const models = await ctx.models?.list?.();
        if (Array.isArray(models)) state.models = models;
      } catch {
        // The last list stays.
      }
      render(state, ctx);
      await writeLines(state);
    } catch {
      // Keep the last good value; the next poll retries.
    }
  });
  return state.publishing;
}

// Every second: a model switch redraws from the last reports at once, and asks
// for new ones (see requestNative).
function checkModel(state, ctx) {
  try {
    const { provider, bare } = activeModel(ctx);
    if (`${provider}/${bare}` === state.shownModel) return;
    render(state, ctx);
    void requestNative(state, ctx);
    void refreshExternal(state, ctx);
  } catch {
    // The next check retries.
  }
}

function rawTimeout(fn, ms) {
  const timer = setTimeout(() => {
    try {
      fn();
    } catch {
      // A deferred ask that throws is dropped; the next tick asks again.
    }
  }, ms);
  timer.unref?.();
  return timer;
}

// The extension, with what it reaches outside replaceable (tests): `execFile`
// runs `omp usage --json`, `now` is the clock, `fs` and `linesFile` where the
// lines go, `loadSources` the configured sources, `sleep` the pause before a
// rename is retried, `setTimeout` for a deferred fetch when ctx has none.
export function createUsageRemaining(options = {}) {
  const deps = {
    execFile: options.execFile ?? ((...args) => nodeExecFile(...args)),
    now: options.now ?? (() => Date.now()),
    fs: options.fs ?? nodeFs,
    linesFile: options.linesFile ?? LINES_FILE,
    loadSources: options.loadSources ?? (() => loadUsageSources()),
    sleep: options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms))),
    setTimeout: options.setTimeout ?? rawTimeout,
  };
  deps.fetchUsage = () => fetchUsageJson(deps.execFile);
  return function usageRemaining(pi) {
    // Per session: the native reports (when their fetch started, the last
    // start, a turn's pending ask, the running fetch), the sources' reports and
    // when they came, the available models, the model last drawn and the lines
    // last written to LINES_FILE, and when.
    const state = {
      deps,
      data: null,
      native: { reports: [], fetchedAt: 0, startedAt: -Infinity, needAt: 0, attempted: false, flight: null, deferred: false },
      external: null,
      externalAt: 0,
      externalFlight: null,
      publishing: Promise.resolve(),
      models: null,
      sources: null,
      sourceError: null,
      shownModel: undefined,
      writtenLines: undefined,
      writtenAt: 0,
      // omp's log, for what the user hears about only when looking
      log: (message) => pi.logger?.warn?.(message),
      oversizeLogged: false,
    };
    try {
      state.sources = deps.loadSources();
    } catch (error) {
      state.sourceError = error instanceof Error ? error.message : "Cannot load usage sources";
    }
    pi.on("session_start", async (_event, ctx) => {
      if (state.sourceError) ctx.ui.notify?.(state.sourceError, "warning");
      ctx.setInterval(() => {
        void requestNative(state, ctx);
        void refreshExternal(state, ctx);
      }, INTERVAL_MS);
      ctx.setInterval(() => checkModel(state, ctx), MODEL_CHECK_MS);
      await Promise.all([requestNative(state, ctx), refreshExternal(state, ctx)]);
    });
    pi.on("turn_end", async (_event, ctx) => {
      await Promise.all([requestNative(state, ctx, deps.now()), refreshExternal(state, ctx)]);
    });
    // An auto-retry fallback can switch provider mid-turn.
    pi.on("retry_fallback_applied", async (_event, ctx) => {
      checkModel(state, ctx);
    });
  };
}

export default createUsageRemaining();
