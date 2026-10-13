// Mirror of the built-in `usage` statusline segment showing quota REMAINING
// instead of USED: a fresh account reads 100% left, an exhausted one 0% left.
// Saved resets appear only on 7d: (+N), or (!N - 3d 2h left) when an applicable
// available credit expires within 5 days. Countdown is the earliest credit expiry.
//
// Shown for any model whose provider has an `omp usage` report with limits
// (Anthropic, OpenAI Codex, Kimi, Gemini CLI, Muse Code, …); otherwise the
// status is cleared. Tier/model-scoped windows (e.g. Codex Spark 5h, Claude
// Fable 7d) are shown only when the active model belongs to that scope, so a
// missing general window is never backfilled; a scope none of the provider's
// models belong to names its plan and applies to every model. Windows of any
// length are shown: 5h, 1d, 7d and mo by name, others by their length.
//
// Footer wiring: put "status" in statusLine.leftSegments/rightSegments (that
// segment renders ctx.ui.setStatus values).
//
// Source of truth is `omp usage --json` (same reports the `usage` segment and
// `omp usage` use), polled every 60s and after each turn. omp has no extension
// event for a model switch, so the active model is checked every second; a
// change redraws at once from the last reports (they cover every provider),
// then fetches fresh ones.
//
// After each fetch, every available model's line and saved-reset expiries are
// also written to LINES_FILE, keyed by the name omp's model chip shows. The
// Tern omp-usage plugin reads it for the hover card's expiry dates, and while
// a subagent's transcript is viewed (omp's chip then shows the subagent's
// model, but the status stays the main session's) for that model's line.
import { execFile } from "node:child_process";
import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const STATUS_KEY = "usage-remaining";
const INTERVAL_MS = 60_000;
const MODEL_CHECK_MS = 1_000;
const RESET_EXPIRY_WARN_MS = 5 * 86_400_000;
const TIMEOUT_MS = 15_000;
const LINES_FILE = join(homedir(), ".omp", "cache", "usage-remaining.json");
const LINES_REFRESH_MS = 120_000;

function ompBin() {
  const exe = process.execPath ?? "";
  return /omp(\.exe)?$/i.test(exe) ? exe : "omp";
}

function fetchUsageJson() {
  return new Promise((resolve) => {
    execFile(ompBin(), ["usage", "--json"], { timeout: TIMEOUT_MS, windowsHide: true }, (err, stdout) => {
      if (err || !stdout) return resolve(null);
      try {
        resolve(JSON.parse(String(stdout)));
      } catch {
        resolve(null);
      }
    });
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

// Any provider can have a usage report; pickReport decides whether one exists.
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
};

// Words in provider ids that name the product or plan, not the provider.
const GENERIC_ID_WORDS = new Set(["api", "cli", "code", "coding", "plan", "subscription", "token"]);

// A provider's label: its listed one, else the first word of its id that names
// it, capitalized (`muse-code` reads `Muse`, `zai-coding-plan` `Zai`).
function shortProvider(provider) {
  const known = PROVIDER_LABELS[provider];
  if (known) return known;
  const word = provider.split(/[^a-z0-9]+/i).find((w) => w && !GENERIC_ID_WORDS.has(w.toLowerCase()));
  return word ? word[0].toUpperCase() + word.slice(1) : provider.replace(/\s+/g, "-");
}

function pickReport(reports, activeProvider) {
  const withLimits = reports.filter((r) => r && Array.isArray(r.limits) && r.limits.length > 0);
  if (!withLimits.length) return null;
  // Exact provider match only: never backfill from another provider's report.
  return withLimits.find((r) => String(r.provider).toLowerCase() === activeProvider) ?? null;
}

// The bare ids of each provider's available models (ctx.models.list()), by
// provider; null when the list isn't known.
function modelIndex(models) {
  if (!Array.isArray(models)) return null;
  const index = new Map();
  for (const m of models) {
    const { provider, bare } = identity(m);
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

// A limit scoped to a tier/model (e.g. Codex Spark 5h, Claude Fable 7d) only
// applies when the active model belongs to that scope. A limit is plan-wide,
// applying to every model, when it has no such scope, when omp marks it
// shared (as omp itself treats them; Muse Code's tier is its plan name), or
// when none of its provider's models belong to its scope, which then names
// something other than a model. `bares`: the provider's model ids, undefined
// when they aren't known.
function limitApplies(limit, activeBare, bares) {
  const scope = limit?.scope ?? {};
  const modelId = scopeText(scope.modelId);
  const tier = scopeText(scope.tier);
  if (scope.shared === true || (!modelId && !tier)) return true;
  if (bares && !bares.some((b) => inScope(modelId, tier, b))) return true;
  return inScope(modelId, tier, activeBare);
}

// The test for which of a report's limits count toward model `bare` ("" for
// the provider's plan-wide windows), given modelIndex's index.
function appliesTo(report, bare, index) {
  const bares = index ? (index.get(String(report.provider).toLowerCase()) ?? []) : undefined;
  return (limit) => limitApplies(limit, bare, bares);
}

// Saved resets restore a blocked short window. Credits that list the limit ids
// they clear (Anthropic) count only toward those windows; credits without that
// list (Codex) count toward every non-monthly window.
function stashFor(report, limit, wc) {
  const rc = report?.resetCredits;
  if (!rc || wc === "monthly") return 0;
  const credits = Array.isArray(rc.credits) ? rc.credits : [];
  const targeted = credits.filter((c) => Array.isArray(c?.clears));
  if (!targeted.length) return typeof rc.availableCount === "number" ? rc.availableCount : 0;
  let n = 0;
  for (const c of targeted) {
    if (c.status !== "available" || c.usable === false || !c.clears.includes(limit.id)) continue;
    n += typeof c.remainingCount === "number" ? c.remainingCount : 1;
  }
  return n;
}

// Find the earliest applicable saved-reset expiry within the warning window.
function expiringResetLeft(report, limit, wc, now) {
  if (wc === "monthly") return undefined;
  const credits = Array.isArray(report?.resetCredits?.credits) ? report.resetCredits.credits : [];
  let soonest = Infinity;
  for (const c of credits) {
    if (c?.status !== "available" || c.usable === false || c.remainingCount <= 0) continue;
    if (Array.isArray(c.clears) && !c.clears.includes(limit.id)) continue;
    const expiresAt = Date.parse(c.expiresAt);
    if (!Number.isFinite(expiresAt)) continue;
    const left = expiresAt - now;
    if (left > 0 && left <= RESET_EXPIRY_WARN_MS && left < soonest) soonest = left;
  }
  return soonest === Infinity ? undefined : soonest;
}

// The saved resets counted on a model's 7d window, soonest expiry first, as
// [{ expiresAt (epoch ms), count }]. Same credit filter as expiringResetLeft,
// without the 5-day warning window.
function savedResets(report, applies) {
  const limit = (report.limits ?? []).find((l) => applies(l) && windowOf(l)?.key === "7d");
  if (!limit) return [];
  const credits = Array.isArray(report.resetCredits?.credits) ? report.resetCredits.credits : [];
  const now = Date.now();
  const out = [];
  for (const c of credits) {
    if (c?.status !== "available" || c.usable === false || c.remainingCount <= 0) continue;
    if (Array.isArray(c.clears) && !c.clears.includes(limit.id)) continue;
    const expiresAt = Date.parse(c.expiresAt);
    if (!Number.isFinite(expiresAt) || expiresAt <= now) continue;
    out.push({ expiresAt, count: typeof c.remainingCount === "number" ? c.remainingCount : 1 });
  }
  return out.sort((a, b) => a.expiresAt - b.expiresAt);
}

function renderRemaining(report, applies) {
  const now = Date.now();
  const seen = new Map();
  for (const limit of report.limits) {
    if (!applies(limit)) continue;
    const w = windowOf(limit);
    if (!w || seen.has(w.key)) continue;
    const amount = limit.amount ?? {};
    const remainingFrac =
      typeof amount.remainingFraction === "number"
        ? amount.remainingFraction
        : typeof amount.usedFraction === "number"
          ? 1 - amount.usedFraction
          : undefined;
    if (typeof remainingFrac !== "number") continue;
    const pct = w.key === "monthly" ? Math.floor(remainingFrac * 100) : Math.round(remainingFrac * 100);
    const filled = Math.round(Math.min(1, Math.max(0, remainingFrac)) * 8);
    const meter = `${"\u2588".repeat(filled)}${"\u2591".repeat(8 - filled)}`;
    const stash = w.key === "7d" ? stashFor(report, limit, w.key) : 0;
    const expiryLeft = stash > 0 ? expiringResetLeft(report, limit, w.key, now) : undefined;
    const extra = stash <= 0
      ? ""
      : expiryLeft === undefined
        ? ` (+${stash})`
        : ` (!${stash} - ${fmtResetShort(expiryLeft)} left)`;
    const resetsAt = limit.window?.resetsAt;
    const reset = typeof resetsAt === "number" ? ` (${fmtResetShort(resetsAt - now)})` : "";
    seen.set(w.key, { ms: w.ms, text: `${w.label} ${meter} ${pct}% left${reset}${extra}` });
  }
  if (!seen.size) return undefined;
  const parts = [...seen.values()]
    .sort((a, b) => (a.ms === b.ms ? 0 : a.ms < b.ms ? -1 : 1))
    .map((p) => p.text);
  return `${shortProvider(report.provider)} ${parts.join(" · ")}`;
}

// The status for a model from fetched reports; "" when its provider isn't
// tracked or has no report. With no model (`bare` ""), the provider's
// plan-wide windows; a provider whose limits are all scoped to some of its
// models shows those instead, so a provider with limits is never left out.
function lineFor(reports, provider, bare, index) {
  if (!isTrackedProvider(provider)) return "";
  const report = pickReport(reports, provider);
  if (!report) return "";
  const line = renderRemaining(report, appliesTo(report, bare, index));
  if (line || bare) return line || "";
  return renderRemaining(report, () => true) || "";
}

// Draws the status for the active model from the last fetched reports. With
// none yet, a tracked model keeps the current status until the fetch lands.
function render(state, ctx) {
  const { provider, bare } = activeModel(ctx);
  state.shownModel = `${provider}/${bare}`;
  if (!isTrackedProvider(provider)) {
    ctx.ui.setStatus(STATUS_KEY, undefined);
    return;
  }
  const reports = state.data && Array.isArray(state.data.reports) ? state.data.reports : null;
  if (!reports) return;
  ctx.ui.setStatus(STATUS_KEY, lineFor(reports, provider, bare, modelIndex(state.models)) || undefined);
}

// Writes LINES_FILE:
// - models: every available model's entry keyed by chip name, { line, resets }
//   with resets from savedResets, or line "" when its provider isn't tracked.
//   Two models sharing a chip name but not an entry can't be told apart from
//   the chip: they get null, and the plugin keeps the main status.
// - providers: every tracked provider with limits, keyed by provider id, in
//   report order, as { label, line, resets } for its plan-wide windows (see
//   lineFor; no model is given, so tier/model-scoped windows are left out).
async function writeLines(state) {
  const reports = state.data && Array.isArray(state.data.reports) ? state.data.reports : null;
  const models = state.models;
  if (!reports || !Array.isArray(models)) return;
  const index = modelIndex(models);
  const entries = {};
  for (const m of models) {
    const name = chipName(m);
    if (!name) continue;
    const { provider, bare } = identity(m);
    const report = isTrackedProvider(provider) ? pickReport(reports, provider) : null;
    const entry = {
      line: lineFor(reports, provider, bare, index),
      resets: report ? savedResets(report, appliesTo(report, bare, index)) : [],
    };
    const same = name in entries && JSON.stringify(entries[name]) === JSON.stringify(entry);
    entries[name] = !(name in entries) || same ? entry : null;
  }
  const providers = {};
  for (const r of reports) {
    const provider = String(r?.provider ?? "").toLowerCase();
    if (!isTrackedProvider(provider) || provider in providers) continue;
    const report = pickReport(reports, provider);
    const line = lineFor(reports, provider, "", index);
    if (!report || !line) continue;
    providers[provider] = {
      label: shortProvider(provider),
      line,
      resets: savedResets(report, appliesTo(report, "", index)),
    };
  }
  const body = JSON.stringify({ entries, providers });
  // Unchanged data is still rewritten now and then, so generatedAt tells readers the file is live.
  const now = Date.now();
  if (body === state.writtenLines && now - state.writtenAt < LINES_REFRESH_MS) return;
  mkdirSync(dirname(LINES_FILE), { recursive: true });
  const tmp = `${LINES_FILE}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify({ generatedAt: now, models: entries, providers }));
  renameSync(tmp, LINES_FILE);
  state.writtenLines = body;
  state.writtenAt = now;
}

async function update(state, ctx) {
  try {
    // Fetched whatever the main model is: a viewed subagent can use another provider.
    const data = await fetchUsageJson();
    // A failed fetch keeps the last good reports; the next poll retries.
    if (data && Array.isArray(data.reports)) state.data = data;
    const models = await ctx.models?.list?.();
    if (Array.isArray(models)) state.models = models;
    render(state, ctx);
    await writeLines(state);
  } catch {
    // Keep the last good value; the next poll retries.
  }
}

function checkModel(state, ctx) {
  try {
    const { provider, bare } = activeModel(ctx);
    if (`${provider}/${bare}` === state.shownModel) return;
    render(state, ctx);
    void update(state, ctx);
  } catch {
    // The next check retries.
  }
}

export default function usageRemaining(pi) {
  // Per session: the last `omp usage --json` reports and available models, the
  // model last drawn and the lines last written to LINES_FILE, and when.
  const state = { data: null, models: null, shownModel: undefined, writtenLines: undefined, writtenAt: 0 };
  pi.on("session_start", async (_event, ctx) => {
    await update(state, ctx);
    ctx.setInterval(() => {
      void update(state, ctx);
    }, INTERVAL_MS);
    ctx.setInterval(() => checkModel(state, ctx), MODEL_CHECK_MS);
  });
  pi.on("turn_end", async (_event, ctx) => {
    await update(state, ctx);
  });
  // An auto-retry fallback can switch provider mid-turn.
  pi.on("retry_fallback_applied", async (_event, ctx) => {
    checkModel(state, ctx);
  });
}
