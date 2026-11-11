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
  if (report.provider === "anthropic" && limit.id === "anthropic:7d:fable") {
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

// Expiries are associated with the same weekly window that displays the count.
function savedResets(report, applies, bares) {
  const credits = Array.isArray(report.resetCredits?.credits) ? report.resetCredits.credits : [];
  const now = Date.now();
  const out = [];
  for (const limit of report.limits ?? []) {
    const w = windowOf(limit);
    if (!applies(limit) || w?.key !== "7d") continue;
    const scope = scopeOf(limit, bares).name.replace(/\s+/g, "-");
    const label = scope ? `${scope[0].toUpperCase()}${scope.slice(1)} ${w.label}` : w.label;
    for (const c of credits) {
      if (!creditApplies(c, report, limit, !scope)) continue;
      const expiresAt = Date.parse(c.expiresAt);
      if (!Number.isFinite(expiresAt) || expiresAt <= now) continue;
      out.push({ expiresAt, count: typeof c.remainingCount === "number" ? c.remainingCount : 1, window: label });
    }
  }
  return out.sort((a, b) => a.expiresAt - b.expiresAt);
}

// The windows `applies` passes, joined: one per window, a limit with a
// tier/model scope (see scopeOf) on its own, labeled with it (`Fable 7d`) and
// keyed apart from the general window of the same length. `account` (set when
// the provider has several accounts) leads every label: `alice 5h`.
function renderRemaining(report, applies, bares, account) {
  const now = Date.now();
  const seen = new Map();
  for (const limit of report.limits) {
    if (!applies(limit)) continue;
    const w = windowOf(limit);
    if (!w) continue;
    const scope = scopeOf(limit, bares).name.replace(/\s+/g, "-");
    const key = scope ? `${scope}:${w.key}` : w.key;
    if (seen.has(key)) continue;
    const scoped = scope ? `${scope[0].toUpperCase()}${scope.slice(1)} ${w.label}` : w.label;
    const label = account ? `${account} ${scoped}` : scoped;
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
    const stash = w.key === "7d" ? stashFor(report, limit, w.key, !scope) : 0;
    const expiryLeft = stash > 0 ? expiringResetLeft(report, limit, w.key, now, !scope) : undefined;
    const extra = stash <= 0
      ? ""
      : expiryLeft === undefined
        ? ` (+${stash})`
        : ` (!${stash} - ${fmtResetShort(expiryLeft)} left)`;
    const resetsAt = limit.window?.resetsAt;
    const reset = typeof resetsAt === "number" ? ` (${fmtResetShort(resetsAt - now)})` : "";
    seen.set(key, { ms: w.ms, scoped: !!scope, text: `${label} ${meter} ${pct}% left${reset}${extra}` });
  }
  // Shortest window first; at the same length the general one before scoped ones.
  return [...seen.values()]
    .sort((a, b) => (a.ms !== b.ms ? (a.ms < b.ms ? -1 : 1) : Number(a.scoped) - Number(b.scoped)))
    .map((p) => p.text)
    .join(" · ");
}

// Every report with limits for `provider`, in omp's order: one per signed-in
// account, so a provider with several accounts has several.
function providerReports(reports, provider) {
  return reports.filter(
    (r) => r && Array.isArray(r.limits) && r.limits.length > 0 && String(r.provider).toLowerCase() === provider,
  );
}

// One word naming a report's account: its email's local part, else the start
// of its account id, else its place in omp's order.
function accountLabel(report, i) {
  const email = report?.metadata?.email;
  if (typeof email === "string" && email.includes("@")) return email.split("@")[0];
  const id = report?.metadata?.accountId;
  return typeof id === "string" && id ? id.slice(0, 8) : `#${i + 1}`;
}

function windowsFor(report, bare, index, account) {
  const bares = providerBares(report, index);
  const line = renderRemaining(report, appliesTo(bare, bares), bares, account);
  if (line || bare) return line;
  return renderRemaining(report, () => true, bares, account);
}

// The status for a model from fetched reports; "" when its provider isn't
// tracked or has no report. With no model (`bare` ""), the provider's windows
// that count toward every model; a provider whose limits are all scoped to
// some of its models shows those instead, so a provider with limits is never
// left out. With several accounts, each account's windows follow in omp's
// order, labeled with the account.
function lineFor(reports, provider, bare, index) {
  if (!isTrackedProvider(provider)) return "";
  const matches = providerReports(reports, provider);
  const many = matches.length > 1;
  const parts = matches.map((r, i) => windowsFor(r, bare, index, many ? accountLabel(r, i) : "")).filter(Boolean);
  return parts.length ? `${shortProvider(matches[0].provider)} ${parts.join(" · ")}` : "";
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
//   report order, as { label, line, resets } for the windows that count
//   toward every model, tier meters included (see lineFor; no model is given,
//   so model-scoped windows are left out).
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
    const bares = report ? providerBares(report, index) : undefined;
    const entry = {
      line: lineFor(reports, provider, bare, index),
      resets: report ? savedResets(report, appliesTo(bare, bares), bares) : [],
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
    const bares = providerBares(report, index);
    providers[provider] = {
      label: shortProvider(provider),
      line,
      resets: savedResets(report, appliesTo("", bares), bares),
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
