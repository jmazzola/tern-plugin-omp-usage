// CLIProxyAPI (CPA) v8 quota source.
//
// Lists every credential through CPA's management API and reads each one's
// quota through CPA's generic api-call endpoint: CPA puts the credential's own
// token where a request says `$TOKEN$`, so no upstream token ever reaches this
// process. Requests and parsing follow the public CPA Usage Keeper / CPA
// Management Center semantics for Codex, Claude, Gemini CLI, Antigravity, Kimi
// and xAI; any other credential is read through the CPA quota plugin serving
// it, when there is one. Read-only: nothing is reset, consumed, uploaded,
// edited or deleted, and credential files are never downloaded (CPA itself may
// renew an expiring token to fill in `$TOKEN$`).
import { HttpError, codexTier, durationMs, finite, mapConcurrent, normalizeProvider, request, timestamp } from "./common.js";
import { claudeResetCredits } from "./reset-credits.js";

const HOUR = 3_600_000;
const DAY = 86_400_000;
const PAGE_SIZE = 100;
const MAX_PAGES = 1_000;
// Latest time a Date can hold; later "timestamps" are garbage.
const MAX_TIME = 8.64e15;

const CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage";
const CODEX_RESET_CREDITS_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits";
const CODEX_HEADERS = {
  Authorization: "Bearer $TOKEN$",
  "Content-Type": "application/json",
  "User-Agent": "Codex Desktop/0.160.1 (Mac OS 27.0.1; arm64) unknown (Codex Desktop; 26.930.61225)",
};
const CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1";
const CLAUDE_PROFILE_URL = "https://api.anthropic.com/api/oauth/profile";
const CLAUDE_HEADERS = {
  Authorization: "Bearer $TOKEN$",
  "Content-Type": "application/json",
  "anthropic-beta": "oauth-2025-04-20",
  "User-Agent": "claude-cli/2.1.280 (external, cli)",
};
const GEMINI_QUOTA_URL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota";
const GEMINI_CODE_ASSIST_URL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist";
const GEMINI_HEADERS = { Authorization: "Bearer $TOKEN$", "Content-Type": "application/json" };
// Tried in order until one returns quota groups.
const ANTIGRAVITY_QUOTA_URLS = [
  "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
  "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:retrieveUserQuotaSummary",
  "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
];
const ANTIGRAVITY_PLAN_URLS = [
  "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
  "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
];
const ANTIGRAVITY_HEADERS = { ...GEMINI_HEADERS, "User-Agent": "antigravity/hub/2.23.0 darwin/arm64" };
const KIMI_USAGE_URLS = { com: "https://api.kimi.com/coding/v1/usages", ai: "https://api.kimi.ai/coding/v1/usages" };
// Weekly credits, then the monthly billing (spend) view.
const XAI_BILLING_URLS = ["https://cli-chat-proxy.grok.com/v1/billing?format=credits", "https://cli-chat-proxy.grok.com/v1/billing"];
const XAI_VERSION = "0.2.93";
const XAI_HEADERS = {
  Authorization: "Bearer $TOKEN$",
  "x-xai-token-auth": "xai-grok-cli",
  "x-grok-client-version": XAI_VERSION,
  Accept: "*/*",
  "User-Agent": `grok-pager/${XAI_VERSION} grok-shell/${XAI_VERSION} (macos; aarch64)`,
};
// Google Code Assist tier ids as CPA Management Center names their plans.
const GOOGLE_TIER_PLANS = new Map([
  ["free-tier", "free"],
  ["g1-pro-tier", "pro"],
  ["g1-ultra-lite-tier", "ultra-lite"],
  ["g1-ultra-tier", "ultra"],
]);
// Claude's usage windows. The 5h and 7d windows fall back to the `limits[]`
// entries of kind session and weekly_all. Model families (legacy Opus and
// Sonnet buckets, now weekly_scoped entries such as Fable), OAuth apps and
// Cowork are separate meters on the plan. Iguana Necktie has no documented
// length, so it stays details-only.
const CLAUDE_WINDOWS = [
  { keys: ["five_hour", "fiveHour"], fallback: "session", durationMs: 5 * HOUR },
  { keys: ["seven_day", "sevenDay"], fallback: "weekly_all", durationMs: 7 * DAY },
  { keys: ["seven_day_oauth_apps", "sevenDayOauthApps"], durationMs: 7 * DAY, label: "OAuth apps", tier: "oauth-apps" },
  { keys: ["seven_day_opus", "sevenDayOpus"], durationMs: 7 * DAY, label: "Opus", tier: "opus" },
  { keys: ["seven_day_sonnet", "sevenDaySonnet"], durationMs: 7 * DAY, label: "Sonnet", tier: "sonnet" },
  { keys: ["seven_day_cowork", "sevenDayCowork"], durationMs: 7 * DAY, label: "Cowork", tier: "cowork" },
  { keys: ["iguana_necktie", "iguanaNecktie"], key: "iguana-necktie", label: "Iguana Necktie" },
];
const NAMED_SPANS = new Map([
  ["hourly", HOUR],
  ["five-hour", 5 * HOUR],
  ["five_hour", 5 * HOUR],
  ["daily", DAY],
  ["day", DAY],
  ["weekly", 7 * DAY],
  ["week", 7 * DAY],
]);

// Built-in readers by CPA's provider key.
const BUILT_IN = new Map([
  ["codex", codexReport],
  ["claude", claudeReport],
  ["gemini-cli", geminiCliReport],
  ["antigravity", antigravityReport],
  ["kimi", kimiReport],
  ["kimi-ai", kimiReport],
  ["kimi.ai", kimiReport],
  ["kimi.com", kimiReport],
  ["xai", xaiReport],
]);

// An error whose message is written here and safe to show. Anything else
// (upstream bodies, unexpected exceptions) never reaches a report.
class QuotaError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

export function createCPASource(config, { fetch: fetchImpl = globalThis.fetch, env = process.env } = {}) {
  const settings = readConfig(config ?? {});
  if (typeof fetchImpl !== "function") throw new TypeError(`${settings.name}: no fetch implementation`);
  return {
    async poll() {
      const key = typeof env?.[settings.keyEnv] === "string" ? env[settings.keyEnv].trim() : "";
      if (!key) throw new QuotaError(`CPA management key is not set; export ${settings.keyEnv}`);
      const cpa = { fetch: fetchImpl, baseUrl: settings.baseUrl, key };
      const credentials = selectCredentials(await listCredentials(cpa), settings.providers);
      return mapConcurrent(credentials, (credential) => credentialReport(cpa, settings, credential));
    },
  };
}

function readConfig(config) {
  const name = typeof config.id === "string" && config.id.trim() ? `CPA source "${config.id.trim()}"` : "CPA source";
  const invalid = (problem) => new TypeError(`${name}: ${problem}`);
  let url;
  try {
    url = new URL(config.baseUrl);
  } catch {
    throw invalid("baseUrl must be an http(s) URL");
  }
  if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw invalid("baseUrl must be an http(s) URL without credentials, query or fragment");
  }
  const keyEnv = typeof config.managementKeyEnv === "string" ? config.managementKeyEnv.trim() : "";
  if (!keyEnv) throw invalid("managementKeyEnv must name the environment variable holding the CPA management key");
  const providers = config.providers;
  if (providers !== undefined && (!Array.isArray(providers) || !providers.every((p) => typeof p === "string" && p.trim()))) {
    throw invalid("providers must be a list of provider names");
  }
  const pluginId = config.quotaPluginId;
  if (pluginId !== undefined && (typeof pluginId !== "string" || !pluginId.trim())) {
    throw invalid("quotaPluginId must be a CPA plugin id");
  }
  if (config.kimiDomain !== undefined && config.kimiDomain !== "com" && config.kimiDomain !== "ai") {
    throw invalid('kimiDomain must be "com" or "ai"');
  }
  return {
    name,
    // Keeps a deployment path prefix (https://host/cpa).
    baseUrl: `${url.origin}${url.pathname}`.replace(/\/+$/, ""),
    keyEnv,
    providers: providers && new Set(providers.map(normalizeProvider)),
    pluginId: pluginId?.trim(),
    kimiDomain: config.kimiDomain,
  };
}

// --- CPA management API ---------------------------------------------------

async function cpaJson(cpa, path, { method = "GET", body } = {}) {
  let response;
  try {
    response = await request(cpa.fetch, cpa.baseUrl, path, {
      method,
      headers: { Authorization: `Bearer ${cpa.key}`, Accept: "application/json" },
      body,
    });
  } catch (error) {
    if (error instanceof HttpError) throw error;
    throw new QuotaError("CPA could not be reached or did not answer in time");
  }
  if (response.status === 204) return null;
  try {
    return await response.json();
  } catch {
    throw new QuotaError("CPA returned invalid JSON");
  }
}

// What a refused management request means; `what` names the request.
function managementMessage(status, what) {
  if (status === 401) return "CPA rejected the management key (HTTP 401)";
  if (status === 403) return "CPA refused management access (HTTP 403); allow remote management or wait out an IP ban";
  if (status === 404) return "CPA v8 management API not found (HTTP 404); check baseUrl and the CPA version";
  return `${what} failed (HTTP ${status})`;
}

// Every credential, following CPA's pages until `has_more` ends.
async function listCredentials(cpa) {
  const files = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    let body;
    try {
      body = await cpaJson(cpa, `v8/management/credentials?page=${page}&page_size=${PAGE_SIZE}`);
    } catch (error) {
      throw error instanceof HttpError ? new QuotaError(managementMessage(error.status, "CPA credential list")) : error;
    }
    if (!isObject(body) || !Array.isArray(body.files)) throw new QuotaError("CPA returned an invalid credential list");
    files.push(...body.files);
    if (body.has_more !== true || body.files.length === 0) return files;
  }
  throw new QuotaError("CPA credential list did not end");
}

// Enabled credentials of the selected providers, once each.
function selectCredentials(files, providers) {
  const seen = new Set();
  const selected = [];
  let unindexed = 0;
  for (const entry of files) {
    if (!isObject(entry)) continue;
    const authIndex = text(entry.auth_index);
    if (!authIndex) {
      unindexed++;
      continue;
    }
    if (seen.has(authIndex)) continue;
    seen.add(authIndex);
    if (entry.disabled === true || text(entry.status).toLowerCase() === "disabled") continue;
    const credential = credentialOf(entry, authIndex);
    if (providers && !providers.has(credential.provider)) continue;
    selected.push(credential);
  }
  // CPA lists files without auth indexes only when its credential manager is
  // down; nothing can be queried then.
  if (seen.size === 0 && unindexed > 0) {
    throw new QuotaError("CPA listed credentials without auth indexes; its credential manager is not running");
  }
  return selected;
}

// The public list fields a quota query needs. `account` is never read: for
// API-key credentials CPA puts the key itself there.
function credentialOf(entry, authIndex) {
  const raw = (text(entry.provider) || text(entry.type)).toLowerCase();
  const idToken = parseObject(entry.id_token);
  return {
    authIndex,
    raw,
    provider: normalizeProvider(raw) || "unknown",
    email: cleanLabel(text(entry.email)),
    label: cleanLabel(text(entry.label)),
    apiKey: text(entry.account_type).toLowerCase() === "api_key",
    oauthProvider: text(entry.oauth_provider).toLowerCase(),
    projectId: text(entry.project_id),
    pluginId: text(entry.quota_plugin_id),
    chatgptAccountId: headerValue(str(idToken, "chatgpt_account_id", "chatgptAccountId")),
    planType: str(idToken, "plan_type", "planType"),
    xaiUserId: headerValue(xaiUserId(entry)),
  };
}

// The xAI user id CPA Management Center sends as x-userid, in its order.
function xaiUserId(entry) {
  const metadata = parseObject(entry.metadata);
  const attributes = parseObject(entry.attributes);
  const nested = (key) => parseObject([entry, metadata, attributes].map((object) => object?.[key]).find((value) => value != null));
  const ids = ["sub", "subject", "user_id", "userId"];
  return str(entry, ...ids) || str(metadata, ...ids) || str(attributes, ...ids)
    || str(nested("oauth"), "sub", "subject") || str(nested("user"), "sub", "id");
}

async function credentialReport(cpa, settings, credential) {
  try {
    const pluginId = credential.pluginId || settings.pluginId;
    if (pluginId) return await pluginReport(cpa, credential, pluginId);
    const builtIn = BUILT_IN.get(credential.raw);
    if (builtIn && !credential.apiKey) {
      const call = (spec) => apiCall(cpa, credential.authIndex, spec);
      return await builtIn({ call, credential, settings });
    }
    return report(credential, {
      error: builtIn
        ? "API-key credentials have no plan quota to read; only signed-in accounts do"
        : `Quota is not supported for ${credential.raw || "unknown"} credentials; a CPA quota plugin for them can provide it`,
    });
  } catch (error) {
    return report(credential, { error: error instanceof QuotaError ? error.message : "Quota could not be read" });
  }
}

// One upstream request through CPA's api-call, as the provider's JSON object.
async function apiCall(cpa, authIndex, { method = "GET", url, headers, data }) {
  let call;
  try {
    call = await cpaJson(cpa, "v8/management/requests/api-call", {
      method: "POST",
      body: { auth_index: authIndex, method, url, header: headers, ...(data === undefined ? {} : { data: JSON.stringify(data) }) },
    });
  } catch (error) {
    if (!(error instanceof HttpError)) throw error;
    if (error.status === 400) {
      throw new QuotaError("CPA has no usable token for this credential (HTTP 400); sign it in again in CPA");
    }
    if (error.status === 502) throw new QuotaError("CPA could not reach the provider (HTTP 502)");
    throw new QuotaError(managementMessage(error.status, "CPA api-call"));
  }
  const status = finite(call?.status_code);
  if (!isObject(call) || status === undefined) throw new QuotaError("CPA returned an invalid api-call response");
  if (status < 200 || status >= 300) throw new QuotaError(providerMessage(status), status);
  const body = parseObject(call.body);
  if (body) return body;
  const empty = typeof call.body !== "string" || !call.body.trim();
  throw new QuotaError(empty ? "Provider returned an empty quota response" : "Provider returned an unreadable quota response");
}

function providerMessage(status) {
  if (status === 401) return "Provider rejected the credential (HTTP 401); sign it in again in CPA";
  if (status === 402) return "Provider requires payment for this account (HTTP 402)";
  if (status === 403) return "Provider denied the quota request (HTTP 403)";
  if (status === 404) return "Provider quota endpoint not found (HTTP 404)";
  if (status === 429) return "Provider rate-limited the quota request (HTTP 429)";
  if (status >= 500) return `Provider quota service failed (HTTP ${status})`;
  return `Provider quota request failed (HTTP ${status})`;
}

// Of two failures, the one telling more: a credential problem (401/402) first.
function moreTelling(previous, next) {
  return previous?.status === 401 || previous?.status === 402 ? previous : next;
}

// --- Codex --------------------------------------------------------------------

async function codexReport({ call, credential }) {
  const headers = { ...CODEX_HEADERS };
  if (credential.chatgptAccountId) headers["Chatgpt-Account-Id"] = credential.chatgptAccountId;
  const body = await call({ url: CODEX_USAGE_URL, headers });
  const observedAt = Date.now();
  const general = codexWindows(child(body, "rate_limit", "rateLimit"), observedAt);
  const generalUsage = new Map(general.map((window) => [window.key, window.usage]));
  const limits = general.map((window) => codexLimit(window));
  // Separate meters. Usage equal to the general window's is the account's
  // total repeated, not this meter's own, so it is dropped.
  const meter = (info, spec) => {
    for (const window of codexWindows(info, observedAt)) {
      const repeated = sameUsage(window.usage, generalUsage.get(window.key));
      limits.push(codexLimit(repeated ? { ...window, usage: undefined } : window, spec));
    }
  };
  meter(child(body, "code_review_rate_limit", "codeReviewRateLimit"), { label: "Code review", tier: "code-review" });
  list(body, "additional_rate_limits", "additionalRateLimits").forEach((raw, index) => {
    const item = parseObject(raw);
    if (!item) return;
    const name = str(item, "limit_name", "limitName");
    const feature = str(item, "metered_feature", "meteredFeature");
    const label = name || feature || `Limit ${index + 1}`;
    meter(child(item, "rate_limit", "rateLimit"), { label, tier: codexTier(name, feature), modelId: name.toLowerCase() });
  });
  const balance = nonNegative(num(child(body, "credits"), "balance"));
  return report(credential, {
    limits,
    plan: str(body, "plan_type", "planType") || credential.planType,
    observedAt,
    summary: balance === undefined ? undefined : [{ label: "Credit balance", value: balance, unit: "credits" }],
    resetCredits: await codexResetCredits(call, headers, child(body, "rate_limit_reset_credits", "rateLimitResetCredits")),
  });
}

function codexWindows(info, now) {
  const windows = [];
  const allowed = flag(info, "allowed");
  const limitReached = flag(info, "limit_reached", "limitReached");
  for (const [role, keys] of [["primary", ["primary_window", "primaryWindow"]], ["secondary", ["secondary_window", "secondaryWindow"]]]) {
    const window = child(info, ...keys);
    if (!window) continue;
    const seconds = num(window, "limit_window_seconds", "limitWindowSeconds");
    const span = seconds > 0 ? seconds * 1000 : undefined;
    const resetAt = num(window, "reset_at", "resetAt");
    const resetAfter = num(window, "reset_after_seconds", "resetAfterSeconds");
    windows.push({
      // Without a length the window keeps the role Codex gives it.
      key: span ? spanId(span) : role,
      durationMs: span,
      windowId: span ? undefined : role,
      resetsAt: resetAt > 0 ? timestamp(resetAt) : resetAfter > 0 ? now + resetAfter * 1000 : undefined,
      amount: usedShare(percent(num(window, "used_percent", "usedPercent"))),
      usage: windowUsage(num(window, "window_usage_tokens", "windowUsageTokens"), num(window, "window_usage_cost", "windowUsageCost")),
      allowed,
      limitReached,
    });
  }
  if (windows.length === 0 && (allowed !== undefined || limitReached !== undefined)) {
    windows.push({ key: "status", amount: {}, allowed, limitReached });
  }
  return windows;
}

function codexLimit(window, { label, tier, modelId } = {}) {
  const { key, durationMs: span, windowId, resetsAt, amount, usage, allowed, limitReached } = window;
  return limit("openai-codex", { key, durationMs: span, windowId, resetsAt, label, tier, modelId, amount, usage, allowed, limitReached });
}

// Tokens and API-equivalent US dollars Codex reports for the window itself.
function windowUsage(tokens, cost) {
  const usage = {};
  if (tokens >= 0) usage.tokens = tokens;
  if (cost >= 0) Object.assign(usage, { cost, currency: "USD" });
  return Object.keys(usage).length ? usage : undefined;
}

function sameUsage(usage, general) {
  return Boolean(usage && general && usage.tokens === general.tokens && usage.cost === general.cost
    && (usage.tokens > 0 || usage.cost > 0));
}

// Saved rate-limit resets: the count Codex reports, with expiry dates from its
// read-only reset-credit list when some are banked.
async function codexResetCredits(call, headers, block) {
  const count = num(block, "available_count", "availableCount");
  if (count === undefined) return undefined;
  const credits = { availableCount: Math.max(0, Math.trunc(count)) };
  if (credits.availableCount === 0) return credits;
  try {
    const body = await call({
      url: CODEX_RESET_CREDITS_URL,
      headers: { ...headers, Accept: "application/json", "OpenAI-Beta": "codex-1", Originator: "Codex Desktop" },
    });
    const listed = num(body, "available_count", "availableCount");
    if (listed >= 0) credits.availableCount = Math.trunc(listed);
    const details = [];
    for (const raw of list(body, "credits")) {
      const credit = parseObject(raw);
      if (str(credit, "reset_type", "resetType") !== "codex_rate_limits" || str(credit, "status") !== "available") continue;
      const expiresAt = isoTime(field(credit, "expires_at", "expiresAt"));
      const grantedAt = isoTime(field(credit, "granted_at", "grantedAt"));
      if (expiresAt) details.push({ status: "available", expiresAt, ...(grantedAt ? { grantedAt } : {}) });
    }
    if (details.length) credits.credits = details;
  } catch {
    // Expiry dates are optional; the reported count stands.
  }
  return credits;
}

// --- Claude -------------------------------------------------------------------

async function claudeReport({ call, credential }) {
  const body = await call({ url: CLAUDE_USAGE_URL, headers: CLAUDE_HEADERS });
  const observedAt = Date.now();
  const entries = claudeLimitEntries(body);
  const limits = CLAUDE_WINDOWS.map(({ keys, fallback, ...spec }) => {
    const bucket = claudeBucket(child(body, ...keys)) ?? entries.find((entry) => entry.kind === fallback);
    return bucket && limit("anthropic", { ...spec, resetsAt: bucket.resetsAt, amount: usedShare(percent(bucket.utilization)) });
  });
  // Model-family weekly caps (Fable, ...) arrive only as weekly_scoped entries
  // named by the family; the legacy per-model buckets stay null.
  const families = new Set(limits.map((entry) => entry?.scope?.tier).filter(Boolean));
  for (const entry of entries) {
    const tier = entry.kind === "weekly_scoped" ? slug(entry.family) : "";
    if (!tier || families.has(tier)) continue;
    families.add(tier);
    limits.push(limit("anthropic", {
      durationMs: 7 * DAY,
      label: entry.family,
      tier,
      resetsAt: entry.resetsAt,
      amount: usedShare(percent(entry.utilization)),
    }));
  }
  limits.push(claudeExtraUsage(body));
  let plan;
  try {
    plan = claudePlan(await call({ url: CLAUDE_PROFILE_URL, headers: CLAUDE_HEADERS }));
  } catch {
    // The plan name is optional.
  }
  return report(credential, { limits, plan, observedAt, resetCredits: claudeResetCredits(child(body, "cedar_ember")) });
}

// A Claude window's utilization percentage and reset; undefined without a percentage.
function claudeBucket(window) {
  const utilization = num(window, "utilization");
  return utilization === undefined ? undefined : { utilization, resetsAt: timestamp(field(window, "resets_at", "resetsAt")) };
}

// The generic `limits[]` entries ({ kind, percent, resets_at, scope.model.display_name })
// that carry a percentage. `is_active` only marks the limit binding right now,
// so it doesn't decide which entries count.
function claudeLimitEntries(body) {
  return list(body, "limits").map((raw) => {
    const entry = parseObject(raw);
    const kind = str(entry, "kind");
    const utilization = num(entry, "percent");
    if (!kind || utilization === undefined) return undefined;
    return {
      kind,
      utilization,
      resetsAt: timestamp(field(entry, "resets_at", "resetsAt")),
      family: str(child(child(entry, "scope"), "model"), "display_name", "displayName"),
    };
  }).filter(Boolean);
}

// Pay-per-use spend beyond the plan, capped per month.
function claudeExtraUsage(body) {
  const spend = child(body, "spend");
  const spent = spend ? claudeSpend(spend) : claudeLegacyExtra(child(body, "extra_usage", "extraUsage"));
  if (!spent) return undefined;
  const amount = { used: spent.used, ...money(spent.currency) };
  if (spent.cap !== undefined) {
    Object.assign(amount, { limit: spent.cap, remaining: clean(Math.max(0, spent.cap - spent.used)) }, usedShare(spent.used / spent.cap));
  }
  return limit("anthropic", { windowId: "monthly", label: "Extra usage", tier: "extra-usage", amount });
}

// `extra_usage`: minor units with `decimal_places` (cents by default), USD
// unless a currency says otherwise; a null monthly_limit means no cap.
function claudeLegacyExtra(extra) {
  if (flag(extra, "is_enabled", "isEnabled") !== true) return undefined;
  const capKey = ["monthly_limit", "monthlyLimit"].find((key) => key in extra);
  if (!capKey) return undefined;
  const places = extra.decimal_places ?? extra.decimalPlaces ?? 2;
  const used = minorUnits(field(extra, "used_credits", "usedCredits"), places, extra.currency, false);
  if (!used) return undefined;
  if (extra[capKey] === null) return { used: used.value, currency: used.currency };
  const cap = minorUnits(extra[capKey], places, extra.currency, false);
  return cap && cap.value > 0 ? { used: used.value, cap: cap.value, currency: used.currency } : undefined;
}

// `spend`: { used, limit } as { amount_minor, exponent, currency } each.
function claudeSpend(spend) {
  if (flag(spend, "enabled") !== true || !("limit" in spend)) return undefined;
  const usedRaw = child(spend, "used");
  const used = usedRaw && minorUnits(usedRaw.amount_minor, usedRaw.exponent, usedRaw.currency, true);
  if (!used) return undefined;
  if (spend.limit === null) return { used: used.value, currency: used.currency };
  const capRaw = parseObject(spend.limit);
  const cap = capRaw && minorUnits(capRaw.amount_minor, capRaw.exponent, capRaw.currency, true);
  return cap && cap.value > 0 && cap.currency === used.currency ? { used: used.value, cap: cap.value, currency: used.currency } : undefined;
}

// Plan from the profile, as CPA Usage Keeper names it.
function claudePlan(profile) {
  const account = child(profile, "account");
  const organization = child(profile, "organization");
  const max = flag(account, "has_claude_max", "hasClaudeMax");
  const pro = flag(account, "has_claude_pro", "hasClaudePro");
  if (max === true) {
    const tier = str(organization, "rate_limit_tier", "rateLimitTier");
    return tier === "default_claude_max_5x" ? "max-5x" : tier === "default_claude_max_20x" ? "max-20x" : "max";
  }
  if (pro === true) return "pro";
  const type = str(organization, "organization_type", "organizationType").toLowerCase();
  const status = str(organization, "subscription_status", "subscriptionStatus").toLowerCase();
  if (type === "claude_team" && status === "active") return "team";
  if (type && type !== "claude_free") return undefined;
  return max === false && pro === false ? "free" : undefined;
}

// --- Gemini CLI and Antigravity ---------------------------------------------

async function geminiCliReport({ call, credential }) {
  const project = credential.projectId;
  if (!project) throw new QuotaError("This credential has no project_id in CPA; Gemini CLI quota needs one");
  const body = await call({ method: "POST", url: GEMINI_QUOTA_URL, headers: GEMINI_HEADERS, data: { project } });
  const observedAt = Date.now();
  // Buckets carry a reset time but no window length.
  const limits = list(body, "buckets").map((raw) => {
    const bucket = parseObject(raw);
    if (!bucket) return undefined;
    const model = str(bucket, "modelId", "model_id");
    const metric = str(bucket, "tokenType", "token_type");
    const amount = remainingShare(num(bucket, "remainingFraction", "remaining_fraction"));
    const remaining = nonNegative(num(bucket, "remainingAmount", "remaining_amount"));
    if (remaining !== undefined) Object.assign(amount, { remaining }, metricUnit(metric));
    return limit("google-gemini-cli", {
      key: "quota",
      scopeKey: slug(`${model} ${metric}`),
      label: model,
      modelId: model.toLowerCase(),
      resetsAt: timestamp(field(bucket, "resetTime", "reset_time")),
      amount,
    });
  });
  let tier;
  try {
    tier = codeAssistTier(await call({
      method: "POST",
      url: GEMINI_CODE_ASSIST_URL,
      headers: GEMINI_HEADERS,
      data: {
        cloudaicompanionProject: project,
        metadata: { ideType: "IDE_UNSPECIFIED", platform: "PLATFORM_UNSPECIFIED", pluginType: "GEMINI", duetProject: project },
      },
    }));
  } catch {
    // Plan and credits are optional.
  }
  return report(credential, { limits, plan: tierPlan(tier), summary: tierCredits(tier), observedAt });
}

async function antigravityReport({ call, credential }) {
  const project = credential.projectId;
  if (!project) throw new QuotaError("This credential has no project_id in CPA; Antigravity quota needs one");
  let groups;
  let failure;
  for (const url of ANTIGRAVITY_QUOTA_URLS) {
    try {
      const parsed = antigravityGroups(await call({ method: "POST", url, headers: ANTIGRAVITY_HEADERS, data: { project } }));
      if (!parsed) throw new QuotaError("Provider returned a quota response without quota groups");
      groups = parsed;
      if (parsed.length) break;
    } catch (error) {
      failure = moreTelling(failure, error);
    }
  }
  if (!groups) throw failure;
  const observedAt = Date.now();
  const limits = [];
  groups.forEach((group, index) => {
    const label = group.label || `Quota group ${index + 1}`;
    const tier = slug(label);
    const rows = group.buckets.map((bucket) => {
      const span = windowSpan(bucket.window);
      const known = span.durationMs !== undefined || span.windowId !== undefined;
      return limit("google-antigravity", {
        key: slug(bucket.id || bucket.name || bucket.window) || "quota",
        ...span,
        scopeKey: tier,
        tier,
        label: known ? label : `${label} ${bucket.name || bucket.id || bucket.window}`,
        resetsAt: bucket.resetsAt,
        amount: remainingShare(bucket.fraction),
      });
    });
    // Shortest window first, windows of unknown length last.
    limits.push(...rows.filter(Boolean).sort((a, b) => (a.window.durationMs ?? Infinity) - (b.window.durationMs ?? Infinity)));
  });
  let tierInfo;
  for (const url of ANTIGRAVITY_PLAN_URLS) {
    try {
      tierInfo = codeAssistTier(await call({ method: "POST", url, headers: ANTIGRAVITY_HEADERS, data: { metadata: { ideType: "ANTIGRAVITY" } } }));
    } catch {
      tierInfo = undefined;
    }
    if (tierInfo) break;
  }
  return report(credential, { limits, plan: tierPlan(tierInfo), summary: tierCredits(tierInfo), observedAt });
}

// Quota groups with their usable buckets; undefined when the body has none.
function antigravityGroups(body) {
  const object = "groups" in body ? body : (child(body, "body") ?? body);
  if (object.groups === null) return [];
  if (!Array.isArray(object.groups)) return undefined;
  return object.groups.map((raw) => {
    const group = parseObject(raw);
    if (!group) return undefined;
    const buckets = list(group, "buckets").map((entry) => parseObject(entry)).filter(Boolean).map((bucket) => ({
      id: str(bucket, "bucketId", "bucket_id"),
      name: str(bucket, "displayName", "display_name"),
      window: str(bucket, "window"),
      fraction: shareValue(field(bucket, "remainingFraction", "remaining_fraction")),
      resetsAt: timestamp(field(bucket, "resetTime", "reset_time")),
    }));
    return { label: str(group, "displayName", "display_name"), buckets: buckets.filter((bucket) => bucket.fraction !== undefined) };
  }).filter((group) => group?.buckets.length);
}

// The Code Assist tier CPA Management Center shows: the paid tier when it has
// an id, else the current one.
function codeAssistTier(body) {
  const paid = child(body, "paidTier", "paid_tier");
  const tier = str(paid, "id") ? paid : child(body, "currentTier", "current_tier");
  return str(tier, "id") || str(tier, "name") ? tier : undefined;
}

function tierPlan(tier) {
  if (!tier) return undefined;
  const id = str(tier, "id");
  return GOOGLE_TIER_PLANS.get(id) ?? (str(tier, "name") || id);
}

function tierCredits(tier) {
  return list(tier, "availableCredits", "available_credits").map((raw) => {
    const credit = parseObject(raw);
    const value = nonNegative(num(credit, "creditAmount", "credit_amount"));
    if (value === undefined) return undefined;
    const type = str(credit, "creditType", "credit_type");
    return { label: type ? `Credits (${type})` : "Credits", value, unit: "credits" };
  }).filter(Boolean);
}

// --- Kimi -----------------------------------------------------------------------

async function kimiReport({ call, credential, settings }) {
  const url = KIMI_USAGE_URLS[kimiDomain(credential, settings.kimiDomain)];
  const body = await call({ url, headers: { Authorization: "Bearer $TOKEN$" } });
  const observedAt = Date.now();
  const limits = list(body, "limits").map((raw, index) => kimiLimit(parseObject(raw), index, observedAt));
  // The account-wide quota resets weekly; the payload gives only its reset time.
  const weekly = child(body, "usage");
  if (weekly) {
    limits.push(limit("kimi-code", {
      key: "usage",
      durationMs: 7 * DAY,
      resetsAt: kimiResetAt(weekly) ?? kimiResetIn(weekly, observedAt),
      amount: kimiAmount(weekly),
    }));
  }
  const month = child(child(body, "usages"), "limit_month_total");
  limits.push(limit("kimi-code", {
    windowId: "monthly",
    resetsAt: timestamp(field(month, "reset_time", "resetTime")),
    amount: usedShare(num(month, "used_ratio", "usedRatio")),
  }));
  return report(credential, { limits, observedAt });
}

// kimi.com or kimi.ai from what CPA lists publicly. The credential file (which
// can name its domain) is never downloaded, so a plain "kimi" credential uses
// the configured domain, else kimi.com as CPA does.
function kimiDomain(credential, configured) {
  for (const value of [credential.raw, credential.oauthProvider]) {
    if (value === "kimi-ai" || value === "kimi.ai" || value.endsWith(".kimi.ai")) return "ai";
    if (value === "kimi.com" || value.endsWith(".kimi.com")) return "com";
  }
  return configured ?? "com";
}

function kimiLimit(item, index, now) {
  if (!item) return undefined;
  const detail = child(item, "detail");
  // Newer payloads put the counts in `detail`, older ones only the reset.
  const counts = ["used", "limit", "remaining"].some((key) => num(detail, key) !== undefined) ? detail : item;
  const window = child(item, "window") ?? item;
  const name = str(item, "title") || str(item, "name");
  const scoped = !spanWord(name);
  return limit("kimi-code", {
    key: slug(str(item, "name")) || `limit-${index + 1}`,
    durationMs: kimiSpan(field(window, "duration"), str(window, "timeUnit", "time_unit")),
    label: scoped ? name : undefined,
    tier: scoped ? slug(name) : undefined,
    resetsAt: kimiResetAt(item) ?? kimiResetAt(detail) ?? kimiResetIn(item, now) ?? kimiResetIn(detail, now),
    amount: kimiAmount(counts),
  });
}

// Kimi's counts carry no unit, so none is claimed.
function kimiAmount(source) {
  const cap = nonNegative(num(source, "limit"));
  const remaining = nonNegative(num(source, "remaining"));
  let used = nonNegative(num(source, "used"));
  if (used === undefined && cap !== undefined && remaining !== undefined && cap >= remaining) used = cap - remaining;
  const amount = {};
  if (used !== undefined) amount.used = used;
  if (cap !== undefined) amount.limit = cap;
  if (remaining !== undefined) amount.remaining = remaining;
  if (cap > 0 && used !== undefined) Object.assign(amount, usedShare(used / cap));
  return amount;
}

function kimiResetAt(source) {
  return timestamp(field(source, "resetAt", "reset_at", "resetTime", "reset_time"));
}

function kimiResetIn(source, now) {
  const seconds = num(source, "resetIn", "reset_in");
  return seconds > 0 ? now + seconds * 1000 : undefined;
}

// A Kimi window length: duration in a time unit such as TIME_UNIT_MINUTE.
function kimiSpan(duration, unit) {
  const name = String(unit ?? "").trim().toLowerCase().replace(/^time_unit_/, "");
  return /^(s|seconds?|m|minutes?|h|hours?|d|days?|w|weeks?)$/.test(name) ? durationMs(duration, name) : undefined;
}

// --- xAI ------------------------------------------------------------------------

async function xaiReport({ call, credential }) {
  const headers = { ...XAI_HEADERS };
  if (credential.xaiUserId) headers["x-userid"] = credential.xaiUserId;
  // Either half is worth showing when the other fails.
  const [weekly, monthly] = await Promise.allSettled(XAI_BILLING_URLS.map((url) => call({ url, headers })));
  const observedAt = Date.now();
  const limits = [];
  if (weekly.status === "fulfilled") limits.push(xaiWeekly(xaiConfig(weekly.value)));
  if (monthly.status === "fulfilled") limits.push(...xaiMonthly(xaiConfig(monthly.value)));
  if (!limits.some(Boolean)) {
    const failure = [weekly, monthly].filter((result) => result.status === "rejected").map((result) => result.reason).reduce(moreTelling, undefined);
    throw failure ?? new QuotaError("xAI returned no billing quota for this credential");
  }
  return report(credential, { limits, observedAt });
}

function xaiConfig(body) {
  const object = "config" in body ? body : (child(body, "body") ?? body);
  return child(object, "config");
}

// Weekly credits: a usage percentage, with each product's share of it.
function xaiWeekly(config) {
  const period = child(config, "currentPeriod", "current_period");
  return limit("xai", {
    durationMs: 7 * DAY,
    resetsAt: timestamp(field(period, "end")) ?? timestamp(field(config, "billingPeriodEnd", "billing_period_end")),
    amount: usedShare(percent(num(config, "creditUsagePercent", "credit_usage_percent"))),
    breakdown: xaiBreakdown(config),
  });
}

function xaiBreakdown(config) {
  const products = new Map();
  for (const raw of list(config, "productUsage", "product_usage")) {
    const item = parseObject(raw);
    const label = str(item, "product").replace(/\s+/g, " ");
    const used = percent(num(item, "usagePercent", "usage_percent"));
    if (!label || !(used >= 0)) continue;
    const key = label.toLowerCase();
    const known = products.get(key);
    if (!known || used > known.usedFraction) products.set(key, { label: known?.label ?? label, usedFraction: clean(used) });
  }
  return [...products.keys()].sort().map((key) => products.get(key));
}

// Monthly spend in US cents: the included allowance, and pay-as-you-go spend
// beyond it up to its own cap. Used money past the allowance is on-demand.
function xaiMonthly(config) {
  const cap = xaiCents(config, "monthlyLimit", "monthly_limit");
  const total = xaiCents(config, "used");
  const onDemandCap = xaiCents(config, "onDemandCap", "on_demand_cap");
  let onDemandUsed = xaiCents(config, "onDemandUsed", "on_demand_used");
  if (onDemandUsed === undefined && total !== undefined && cap !== undefined) onDemandUsed = Math.max(0, total - cap);
  const start = timestamp(field(config, "billingPeriodStart", "billing_period_start"));
  const end = timestamp(field(config, "billingPeriodEnd", "billing_period_end"));
  const period = { windowId: "monthly", durationMs: start !== undefined && end > start ? end - start : undefined, resetsAt: end };
  const rows = [];
  if (cap !== undefined || total !== undefined) {
    const amount = money("USD");
    if (cap !== undefined) amount.limit = dollars(cap);
    if (total !== undefined) {
      const included = cap === undefined ? total : Math.min(total, cap);
      amount.used = dollars(included);
      if (cap !== undefined) {
        amount.remaining = dollars(cap - included);
        if (cap > 0) Object.assign(amount, usedShare(included / cap));
      }
    }
    rows.push(limit("xai", { ...period, amount }));
  }
  if (onDemandCap > 0) {
    const amount = { ...money("USD"), limit: dollars(onDemandCap) };
    if (onDemandUsed !== undefined) {
      Object.assign(amount, { used: dollars(onDemandUsed), remaining: dollars(Math.max(0, onDemandCap - onDemandUsed)) }, usedShare(onDemandUsed / onDemandCap));
    }
    rows.push(limit("xai", { ...period, label: "Pay-as-you-go", tier: "on-demand", amount }));
  }
  return rows;
}

// xAI money: { val } objects or bare numbers, in US cents.
function xaiCents(config, ...keys) {
  const value = field(config, ...keys);
  return nonNegative(finite(isObject(value) ? value.val : value));
}

const dollars = (cents) => clean(cents / 100);

// --- CPA quota plugins ----------------------------------------------------------

// A plugin's normalized quota (pluginapi.QuotaFetchResponse): bucket groups of
// remaining shares, plus summary metrics.
async function pluginReport(cpa, credential, pluginId) {
  let body;
  try {
    body = await cpaJson(cpa, `v8/management/plugins/${encodeURIComponent(pluginId)}/quota?auth_index=${encodeURIComponent(credential.authIndex)}`);
  } catch (error) {
    if (!(error instanceof HttpError)) throw error;
    if (error.status === 404) throw new QuotaError(`CPA quota plugin ${pluginId} is not installed or does not serve this credential (HTTP 404)`);
    if (error.status === 502) throw new QuotaError(`CPA quota plugin ${pluginId} could not fetch quota (HTTP 502)`);
    throw new QuotaError(managementMessage(error.status, `CPA quota plugin ${pluginId}`));
  }
  if (!isObject(body)) throw new QuotaError(`CPA quota plugin ${pluginId} returned an invalid response`);
  const observedAt = Date.now();
  // How far the provider's clock runs ahead of CPA's; reset times are in its clock.
  const offset = num(body, "serverTimeOffsetMs", "server_time_offset_ms") ?? 0;
  const limits = [];
  list(body, "groups").forEach((rawGroup, groupIndex) => {
    const group = parseObject(rawGroup);
    const name = str(group, "displayName", "display_name");
    const groupLabel = spanWord(name) ? "" : name;
    list(group, "buckets").forEach((rawBucket, bucketIndex) => {
      const bucket = parseObject(rawBucket);
      if (!bucket) return;
      const span = windowSpan(str(bucket, "window"));
      const known = span.durationMs !== undefined || span.windowId !== undefined;
      const extra = known ? "" : str(bucket, "window") || str(bucket, "description");
      const reset = timestamp(field(bucket, "resetTime", "reset_time"));
      limits.push(limit(credential.provider, {
        key: slug(extra) || `bucket-${bucketIndex + 1}`,
        ...span,
        scopeKey: slug(name) || `group-${groupIndex + 1}`,
        tier: slug(groupLabel) || undefined,
        label: [groupLabel, extra].filter(Boolean).join(" "),
        resetsAt: reset === undefined ? undefined : reset - offset,
        amount: remainingShare(num(bucket, "remainingFraction", "remaining_fraction")),
      }));
    });
  });
  const subscription = child(body, "subscription");
  return report(credential, {
    limits,
    plan: str(subscription, "plan") || str(subscription, "tierName", "tier_name"),
    summary: list(body, "summary").map(pluginMetric).filter(Boolean),
    observedAt,
  });
}

// A summary metric; currency only for format "currency" with an ISO code, as CPA keeps it.
function pluginMetric(raw) {
  const metric = parseObject(raw);
  const label = cleanLabel(str(metric, "label"));
  const value = typeof metric?.value === "number" && Number.isFinite(metric.value) ? metric.value : undefined;
  if (!label || value === undefined) return undefined;
  const out = { label, value };
  const unit = str(metric, "unit");
  if (unit) out.unit = unit;
  const currency = str(metric, "format") === "currency" ? currencyCode(metric.currency) : "";
  if (currency) out.currency = currency;
  return out;
}

// --- Reports and limits -----------------------------------------------------------

function report(credential, { limits = [], plan, observedAt, summary, resetCredits, error } = {}) {
  const metadata = { accountId: credential.authIndex };
  if (credential.email) metadata.email = credential.email;
  if (credential.label) metadata.label = credential.label;
  const planLabel = cleanLabel(plan);
  if (planLabel) metadata.plan = planLabel;
  const out = { provider: credential.provider, metadata };
  if (observedAt !== undefined) out.observedAt = observedAt;
  out.limits = uniqueIds(limits.filter(Boolean));
  if (summary?.length) out.summary = summary;
  if (resetCredits) out.resetCredits = resetCredits;
  if (error) out.error = error;
  return out;
}

// One limit, or undefined when it holds nothing to show. Its id is
// `provider:window[:scope]`; a window of unknown length goes by `key`.
// `label` names a scoped meter, never the window's length.
function limit(provider, spec) {
  const amount = spec.amount ?? {};
  const counted = ["remainingFraction", "usedFraction", "used", "remaining", "limit"].some((key) => typeof amount[key] === "number");
  if (!counted && !spec.usage && !spec.breakdown?.length && typeof spec.allowed !== "boolean" && typeof spec.limitReached !== "boolean") return undefined;
  const windowId = spec.windowId ?? (spec.durationMs ? spanId(spec.durationMs) : undefined);
  const scope = {};
  if (spec.tier) scope.tier = spec.tier;
  if (spec.modelId) scope.modelId = spec.modelId;
  if (windowId) scope.windowId = windowId;
  const window = {};
  if (windowId) window.id = windowId;
  if (spec.durationMs) window.durationMs = spec.durationMs;
  if (Number.isFinite(spec.resetsAt) && Math.abs(spec.resetsAt) <= MAX_TIME) window.resetsAt = spec.resetsAt;
  const out = { id: [provider, windowId || spec.key || "quota", spec.scopeKey || spec.tier].filter(Boolean).join(":") };
  const label = cleanLabel(spec.label);
  if (label) out.displayLabel = label;
  if (Object.keys(scope).length) out.scope = scope;
  out.window = window;
  out.amount = amount;
  // Only usage reported for this very window and meter reaches here.
  if (spec.usage) Object.assign(out, { usage: spec.usage, estimateEligible: true });
  if (spec.breakdown?.length) out.breakdown = spec.breakdown;
  if (typeof spec.allowed === "boolean") out.allowed = spec.allowed;
  if (typeof spec.limitReached === "boolean") out.limitReached = spec.limitReached;
  return out;
}

function uniqueIds(limits) {
  const seen = new Map();
  return limits.map((entry) => {
    const count = (seen.get(entry.id) ?? 0) + 1;
    seen.set(entry.id, count);
    return count === 1 ? entry : { ...entry, id: `${entry.id}-${count}` };
  });
}

// A window id from its length: 5h, 7d, monthly (28-31 days that aren't whole), 90m.
function spanId(ms) {
  if (ms % DAY === 0) return `${ms / DAY}d`;
  if (ms >= 28 * DAY && ms <= 31 * DAY) return "monthly";
  if (ms % HOUR === 0) return `${ms / HOUR}h`;
  return `${Math.max(1, Math.round(ms / 60_000))}m`;
}

// A window named in text: "5h", "weekly", "30 days"; "monthly" is a calendar
// month, so it has no fixed length.
function windowSpan(value) {
  const name = String(value ?? "").trim().toLowerCase();
  if (NAMED_SPANS.has(name)) return { durationMs: NAMED_SPANS.get(name) };
  if (name === "monthly" || name === "month") return { windowId: "monthly" };
  const match = /^(\d+(?:\.\d+)?)\s*(m|mins?|minutes?|h|hrs?|hours?|d|days?|w|wks?|weeks?)$/.exec(name);
  return match ? { durationMs: durationMs(match[1], match[2][0]) } : {};
}

// Whether a limit's name only names its span ("Daily", "5h", "Weekly limit").
function spanWord(value) {
  const words = String(value ?? "").toLowerCase().replace(/\b(limits?|quota|usage|window|rate)\b/g, " ").replace(/\s+/g, " ").trim();
  return !words || /^(hourly|daily|weekly|monthly|day|week|month|five[ -]hour|\d+[\s-]*(m|mins?|minutes?|h|hours?|d|days?|w|weeks?))$/.test(words);
}

// A unit only where the provider names its metric (REQUESTS, TOKENS, ...).
function metricUnit(metric) {
  const name = metric.trim().toLowerCase();
  if (name === "request" || name === "requests") return { unit: "requests" };
  if (name === "token" || name === "tokens") return { unit: "tokens" };
  return /^[a-z][a-z0-9_]*$/.test(name) ? { unit: name } : {};
}

// Fractions from a used share: 0 untouched, 1 spent, above 1 overage.
function usedShare(fraction) {
  if (!(fraction >= 0)) return {};
  return { usedFraction: clean(fraction), remainingFraction: clean(Math.max(0, 1 - fraction)) };
}

// Fractions from a remaining share; only 0..1 is one.
function remainingShare(fraction) {
  if (!(fraction >= 0 && fraction <= 1)) return {};
  return { usedFraction: clean(1 - fraction), remainingFraction: clean(fraction) };
}

const percent = (value) => (value === undefined ? undefined : value / 100);

// A share as a number, numeric string or "50%".
function shareValue(value) {
  if (typeof value === "string" && value.trim().endsWith("%")) {
    const share = finite(value.trim().slice(0, -1));
    return share === undefined ? undefined : share / 100;
  }
  return finite(value);
}

// Minor currency units (cents at exponent 2) as a major-unit amount.
function minorUnits(amount, exponent, currency, currencyRequired) {
  const minor = finite(amount);
  const places = finite(exponent);
  if (!(minor >= 0) || !Number.isInteger(places) || places < 0 || places > 6) return undefined;
  const code = currency === undefined || currency === null ? (currencyRequired ? "" : "USD") : currencyCode(currency);
  return code ? { value: clean(minor / 10 ** places), currency: code } : undefined;
}

function currencyCode(value) {
  return typeof value === "string" && /^[A-Za-z]{3}$/.test(value.trim()) ? value.trim().toUpperCase() : "";
}

function money(currency) {
  return { unit: currency.toLowerCase(), currency };
}

function isoTime(value) {
  const time = timestamp(value);
  return time !== undefined && Math.abs(time) <= MAX_TIME ? new Date(time).toISOString() : undefined;
}

// --- JSON field access ---------------------------------------------------------------

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

// A JSON object from a value or JSON text: CPA hands upstream bodies over as
// strings, some wrapped once more.
function parseObject(value, depth = 0) {
  if (isObject(value)) return value;
  if (typeof value !== "string" || depth > 2) return undefined;
  try {
    return parseObject(JSON.parse(value), depth + 1);
  } catch {
    return undefined;
  }
}

// The first of `keys` that is set (not null).
function field(object, ...keys) {
  if (!isObject(object)) return undefined;
  for (const key of keys) {
    if (object[key] !== undefined && object[key] !== null) return object[key];
  }
  return undefined;
}

function child(object, ...keys) {
  return parseObject(field(object, ...keys));
}

function list(object, ...keys) {
  const value = field(object, ...keys);
  return Array.isArray(value) ? value : [];
}

// The first of `keys` holding a finite number or numeric string.
function num(object, ...keys) {
  if (!isObject(object)) return undefined;
  for (const key of keys) {
    const value = finite(object[key]);
    if (value !== undefined) return value;
  }
  return undefined;
}

function text(value) {
  if (typeof value === "string") return value.trim();
  return typeof value === "number" && Number.isFinite(value) ? String(value) : "";
}

function str(object, ...keys) {
  if (!isObject(object)) return "";
  for (const key of keys) {
    const value = text(object[key]);
    if (value) return value;
  }
  return "";
}

function flag(object, ...keys) {
  const value = field(object, ...keys);
  if (typeof value === "boolean") return value;
  const word = typeof value === "string" ? value.trim().toLowerCase() : "";
  return word === "true" ? true : word === "false" ? false : undefined;
}

function nonNegative(value) {
  return value >= 0 ? value : undefined;
}

// Drops float noise (1 - 0.72 = 0.28000000000000003) without moving real digits.
function clean(value) {
  return Number(value.toPrecision(12));
}

// A lowercase kebab slug, as omp's slugify makes them.
function slug(value) {
  return String(value ?? "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

function cleanLabel(value) {
  const label = typeof value === "string" ? value.replace(/\s+/g, " ").trim() : "";
  return label ? label.slice(0, 80) : undefined;
}

// A header value CPA can send as is; anything else is left out.
function headerValue(value) {
  return /^[\x21-\x7e]{1,256}$/.test(value) ? value : "";
}
