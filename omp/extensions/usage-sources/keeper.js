// CPA Usage Keeper source: reads the quota snapshots Keeper has cached for
// CLIProxyAPI credentials, through Keeper's admin API.
//
// - Auth: a password login (POST /api/v1/auth/login answers with a session
//   cookie) or a session token taken from the environment. The session lives
//   in memory only. An expired password session is renewed once per poll,
//   never in a loop. Every request carries Keeper's request-intent header,
//   which it requires on POSTs.
// - Accounts come from /api/v1/usage/identities, keyed by `identity` (the CPA
//   auth_index, not Keeper's row id). /api/v1/quota/cache answers by
//   auth_index without the provider, so the two are joined here.
// - Cache reads never reach the providers. A snapshot keeps Keeper's
//   refreshed_at as its observation time, however old; a missing one is an
//   explicit error, never an empty or a full meter. With `refresh: true`,
//   missing and aging snapshots are queued with /api/v1/quota/refresh and the
//   next poll reads the results.
// - Nothing is reset, redeemed, edited or deleted.
import { codexTier, durationMs, finite, HttpError, normalizeProvider, request, requestJson, timestamp } from "./common.js";
import { claudeResetCredits } from "./reset-credits.js";

const SESSION_COOKIE = "cpa_usage_keeper_session";
const SET_SESSION_COOKIE = /(?:^|,\s*)cpa_usage_keeper_session=([^;,\s]+)/;
const INTENT_HEADERS = { "X-CPA-Usage-Keeper-Request": "fetch" };
// RFC 6265 cookie-octets.
const COOKIE_VALUE = /^[\x21\x23-\x2b\x2d-\x3a\x3c-\x5b\x5d-\x7e]+$/;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const EMAIL = /^[^\s@]+@[^\s@]+\.[a-z]{2,}$/i;
// Usage identities of CPA credential files; 2 marks AI-provider API keys, which
// Keeper never queries for quota.
const CREDENTIAL_AUTH_TYPE = 1;
// Credential types Keeper's quota registry handles, matched by the identity's
// provider, then its type, as Keeper does.
const FAMILIES = new Map([
  ["codex", "codex"],
  ["claude", "claude"],
  ["gemini-cli", "gemini-cli"],
  ["antigravity", "antigravity"],
  ["kimi", "kimi"],
  ["kimi-ai", "kimi"],
  ["kimi.ai", "kimi"],
  ["kimi.com", "kimi"],
  ["xai", "xai"],
]);
const HOUR_MS = 3_600_000;
const DAY_MS = 86_400_000;
const DEFAULT_MAX_AGE_MS = 600_000;
const MISSING = "Keeper has no cached quota for this account yet";

export function createKeeperSource(config, { fetch: fetchImpl = globalThis.fetch, env = process.env } = {}) {
  const baseUrl = typeof config?.baseUrl === "string" ? config.baseUrl.trim().replace(/\/+$/, "") : "";
  if (!/^https?:\/\/[^/?#]+/i.test(baseUrl)) throw new Error("Keeper baseUrl must be an HTTP(S) URL");
  const passwordEnv = envName(config.passwordEnv, "passwordEnv");
  const sessionCookieEnv = envName(config.sessionCookieEnv, "sessionCookieEnv");
  if (!passwordEnv === !sessionCookieEnv) throw new Error("Keeper source needs exactly one of passwordEnv or sessionCookieEnv");
  const providers = Array.isArray(config.providers) && config.providers.length
    ? new Set(config.providers.map(normalizeProvider))
    : undefined;
  const maxAgeSeconds = finite(config.maxAgeSeconds);
  // Ask for a new snapshot halfway to the age at which a snapshot reads as stale.
  const refreshAfterMs = (maxAgeSeconds > 0 ? maxAgeSeconds * 1000 : DEFAULT_MAX_AGE_MS) / 2;
  // undefined: no session yet; "": Keeper runs without login; otherwise the cookie value.
  let session;

  function secret() {
    const value = env?.[passwordEnv ?? sessionCookieEnv];
    if (typeof value !== "string" || !value.trim()) {
      throw new Error(`Keeper ${passwordEnv ? "password" : "session token"} environment variable is not set`);
    }
    if (passwordEnv) return value;
    const token = value.trim();
    if (!COOKIE_VALUE.test(token) || token.startsWith(`${SESSION_COOKIE}=`)) {
      throw new Error("Keeper session token must be the bare cookie value");
    }
    return token;
  }

  function failure(action, error) {
    if (!(error instanceof HttpError)) return new Error(`Keeper ${action} failed (network error, timeout or invalid response)`);
    if (error.status === 401) {
      return new Error(sessionCookieEnv ? "Keeper rejected the session token (HTTP 401)" : "Keeper rejected the login session (HTTP 401)");
    }
    if (error.status === 403) return new Error(`Keeper refused the ${action} (HTTP 403); an admin session is required`);
    return new Error(`Keeper ${action} failed (HTTP ${error.status})`);
  }

  return {
    async poll() {
      const credential = secret();
      if (sessionCookieEnv) session = credential;
      let loggedIn = false;

      async function login() {
        loggedIn = true;
        session = undefined;
        let response;
        try {
          response = await request(fetchImpl, baseUrl, "api/v1/auth/login", {
            method: "POST",
            headers: INTENT_HEADERS,
            body: { password: credential },
          });
        } catch (error) {
          if (error instanceof HttpError && error.status === 401) throw new Error("Keeper rejected the login password (HTTP 401)");
          if (error instanceof HttpError && error.status === 429) throw new Error("Keeper is rate-limiting logins (HTTP 429); try again later");
          throw failure("login", error);
        }
        // Keeper answers 204 with the session cookie; with login disabled it sets none.
        session = sessionCookie(response.headers) ?? "";
        await response.body?.cancel().catch(() => {});
      }

      async function call(action, path, options = {}) {
        if (passwordEnv && session === undefined) await login();
        const send = () => requestJson(fetchImpl, baseUrl, path, {
          ...options,
          headers: { ...INTENT_HEADERS, ...(session ? { Cookie: `${SESSION_COOKIE}=${session}` } : {}) },
        });
        try {
          return await send();
        } catch (error) {
          // A session renewed in this poll that is still refused is final.
          if (!(error instanceof HttpError) || error.status !== 401 || !passwordEnv || loggedIn) throw failure(action, error);
        }
        await login();
        try {
          return await send();
        } catch (error) {
          throw failure(action, error);
        }
      }

      const listing = await call("identity listing", "api/v1/usage/identities");
      if (!Array.isArray(listing?.identities)) throw new Error("Keeper returned an unexpected identity list");
      const accounts = credentials(listing.identities, providers);
      const authIndexes = accounts.filter((account) => account.family).map((account) => account.authIndex);
      const cached = new Map();
      if (authIndexes.length) {
        const cache = await call("quota cache read", "api/v1/quota/cache", { method: "POST", body: { auth_indexes: authIndexes } });
        if (!Array.isArray(cache?.items)) throw new Error("Keeper returned an unexpected quota cache");
        for (const item of cache.items) {
          const authIndex = isRecord(item) ? text(item.auth_index) : "";
          if (authIndex && !cached.has(authIndex)) cached.set(authIndex, item);
        }
      }

      const now = Date.now();
      const due = [];
      const reports = accounts.map((account) => {
        const item = cached.get(account.authIndex);
        const report = accountReport(account, item);
        if (config.refresh === true && account.family && refreshDue(item, report, now, refreshAfterMs)) {
          due.push({ authIndex: account.authIndex, report, missing: !item });
        }
        return report;
      });
      if (due.length) await queueRefresh(due, call);
      return reports;
    },
  };
}

function envName(value, field) {
  if (value === undefined || value === null) return undefined;
  // Never echo the value: a misplaced secret must not reach an error line.
  if (typeof value !== "string" || !ENV_NAME.test(value)) throw new Error(`Keeper ${field} must name an environment variable`);
  return value;
}

function sessionCookie(headers) {
  const values = typeof headers?.getSetCookie === "function" ? headers.getSetCookie() : [headers?.get?.("set-cookie") ?? ""];
  for (const value of values) {
    const match = SET_SESSION_COOKIE.exec(value);
    if (match) return match[1];
  }
  return undefined;
}

// Enabled CPA credentials, joined to Keeper's quota family by provider, then type.
function credentials(identities, providers) {
  const accounts = [];
  const seen = new Set();
  for (const identity of identities) {
    if (!isRecord(identity) || finite(identity.auth_type) !== CREDENTIAL_AUTH_TYPE) continue;
    if (identity.disabled === true || identity.is_deleted === true) continue;
    const authIndex = text(identity.identity);
    const family = FAMILIES.get(lower(identity.provider)) ?? FAMILIES.get(lower(identity.type));
    const provider = normalizeProvider(family ?? (text(identity.provider) || text(identity.type)));
    if (!authIndex || !provider || seen.has(authIndex) || (providers && !providers.has(provider))) continue;
    seen.add(authIndex);
    accounts.push({ authIndex, family, provider, metadata: accountMetadata(identity, authIndex) });
  }
  return accounts;
}

function accountMetadata(identity, authIndex) {
  const names = [identity.displayName, identity.alias, identity.name].map(text).filter(Boolean);
  return compact({
    accountId: authIndex,
    email: names.find((name) => EMAIL.test(name))?.toLowerCase(),
    label: names[0]?.slice(0, 80),
    plan: planName(identity.subscription),
  });
}

function planName(subscription) {
  return isRecord(subscription) ? (text(subscription.tierName) || text(subscription.plan) || undefined) : undefined;
}

function accountReport(account, item) {
  const report = { provider: account.provider, metadata: account.metadata, limits: [] };
  if (!account.family) {
    return { ...report, error: "Keeper cannot read quota for this credential type; leave it out with this source's providers list" };
  }
  if (!item) return { ...report, error: `${MISSING}; refresh it in Keeper or enable refresh for this source` };
  if (item.status === "failed") return { ...report, error: failedRefresh(finite(item.http_status_code)) };
  const quota = item.status === "completed" && isRecord(item.quota) ? item.quota : undefined;
  if (!quota) return { ...report, error: "Keeper returned an unreadable quota snapshot for this account" };
  const observedAt = timestamp(item.refreshed_at);
  const limits = quotaLimits(account, quota.quota, observedAt);
  const plan = planName(quota.subscription);
  return compact({
    ...report,
    metadata: plan ? { ...account.metadata, plan } : account.metadata,
    observedAt,
    limits,
    resetCredits: account.family === "codex" ? codexResetCredits(quota)
      : account.family === "claude" ? claudeResetCredits(quota.claudeResetGrants)
      : undefined,
    error: limits.length ? undefined : "Keeper's quota snapshot for this account has no readable limits",
  });
}

// Keeper caches only provider auth and billing failures (401/402) for display.
function failedRefresh(status) {
  if (status === 401) return "The provider rejected this credential (HTTP 401); sign in again in CLIProxyAPI";
  if (status === 402) return "The provider reports no active plan or credit (HTTP 402)";
  return Number.isInteger(status) && status >= 100 && status <= 599
    ? `Keeper's last quota refresh failed (HTTP ${status})`
    : "Keeper's last quota refresh failed";
}

function refreshDue(item, report, now, refreshAfterMs) {
  if (!item) return true;
  // Keeper holds provider auth and billing failures for hours; asking again only repeats them.
  if (item.status === "failed") return false;
  const observedAt = report.observedAt;
  if (observedAt === undefined || now - observedAt >= refreshAfterMs) return true;
  // A window that rolled over since the snapshot no longer describes the account.
  return report.limits.some((limit) => limit.window.resetsAt > observedAt && limit.window.resetsAt <= now);
}

// Queues provider queries without waiting: the next poll reads what Keeper cached.
async function queueRefresh(due, call) {
  let outcome;
  try {
    const result = await call("quota refresh", "api/v1/quota/refresh", {
      method: "POST",
      body: { auth_indexes: due.map((entry) => entry.authIndex) },
    });
    const queued = new Set((Array.isArray(result?.tasks) ? result.tasks : []).map((task) => text(task?.authIndex)));
    const rejected = new Map((Array.isArray(result?.rejected) ? result.rejected : []).map((entry) => [text(entry?.authIndex), text(entry?.error)]));
    outcome = (authIndex) => queued.has(authIndex) ? "a refresh was requested"
      : rejected.get(authIndex) === "duplicate" ? "a refresh is already running"
      : rejected.has(authIndex) ? "Keeper declined to refresh it"
      : "Keeper cannot refresh this credential";
  } catch (error) {
    outcome = () => error.message;
  }
  for (const entry of due) {
    if (entry.missing) entry.report.error = `${MISSING}; ${outcome(entry.authIndex)}`;
  }
}

const MAPPERS = {
  codex: codexLimit,
  claude: claudeLimit,
  "gemini-cli": geminiLimit,
  antigravity: antigravityLimit,
  kimi: kimiLimit,
  xai: xaiLimit,
};

function quotaLimits(account, rows, observedAt) {
  const context = { provider: account.provider, observedAt };
  const limits = [];
  const ids = new Set();
  for (const row of Array.isArray(rows) ? rows : []) {
    let limit = isRecord(row) ? MAPPERS[account.family](row, context) : undefined;
    if (isRecord(row) && (typeof row.allowed === "boolean" || typeof row.limitReached === "boolean")) {
      limit ??= meter({ id: `${account.provider}:${text(row.key) || "status"}`, displayLabel: text(row.label) || text(row.key) || "Quota status", scope: {}, ...windowTiming(row, observedAt), amount: {} });
      if (typeof row.allowed === "boolean") limit.allowed = row.allowed;
      if (typeof row.limitReached === "boolean") limit.limitReached = row.limitReached;
    }
    if (!limit || ids.has(limit.id)) continue;
    ids.add(limit.id);
    limits.push(limit);
  }
  return limits;
}

const CODEX_KEY = /^(rate_limit|code_review_rate_limit|additional_rate_limits\.(.+))\.(primary|secondary)_window$/;

function codexLimit(row, context) {
  const match = CODEX_KEY.exec(text(row.key));
  if (!match) return otherLimit(row, context);
  const amount = percentAmount(row);
  if (!amount) return undefined;
  const [, group, limitName, role] = match;
  const timing = windowTiming(row, context.observedAt);
  // Keeper fills the plan windows with the credential's totals for the same
  // range; feature windows carry only totals the provider reported for them.
  const fields = { ...timing, label: text(row.label), amount, usage: windowUsage(row), eligible: true };
  if (group === "rate_limit") {
    return meter({ ...fields, id: `openai-codex:${role}`, scope: { windowId: timing.windowId, shared: true } });
  }
  if (group === "code_review_rate_limit") {
    return meter({ ...fields, id: `openai-codex:code-review:${role}`, displayLabel: "Code review", scope: { tier: "code-review", windowId: timing.windowId } });
  }
  const tier = codexTier(limitName, text(row.metric));
  return meter({
    ...fields,
    id: `openai-codex:${tier}:${role}`,
    displayLabel: tier === "spark" ? "Spark" : limitName,
    scope: { tier, modelId: limitName, windowId: timing.windowId, shared: true },
  });
}

// Ids match omp's Claude limits, so reset credits clear the same windows.
const CLAUDE_WINDOWS = {
  five_hour: { id: "anthropic:5h", windowId: "5h" },
  seven_day: { id: "anthropic:7d", windowId: "7d" },
  seven_day_opus: { id: "anthropic:7d:opus", windowId: "7d", tier: "opus", label: "Opus" },
  seven_day_sonnet: { id: "anthropic:7d:sonnet", windowId: "7d", tier: "sonnet", label: "Sonnet" },
  seven_day_oauth_apps: { id: "anthropic:7d:oauth-apps", windowId: "7d", tier: "oauth-apps", label: "OAuth apps" },
  seven_day_cowork: { id: "anthropic:7d:cowork", windowId: "7d", tier: "cowork", label: "Cowork" },
};

function claudeLimit(row, context) {
  const key = text(row.key);
  const amount = percentAmount(row);
  if (key === "extra_usage") {
    // Keeper drops the currency and minor-unit scale and stores missing amounts
    // as 0, so only the utilization is reliable; disabled overage has no meter.
    // No window length is reported, so it stays a detail.
    return row.allowed === false || !amount ? undefined
      : meter({ id: "anthropic:extra", displayLabel: "Extra usage", scope: {}, amount });
  }
  const known = Object.hasOwn(CLAUDE_WINDOWS, key) ? CLAUDE_WINDOWS[key] : undefined;
  if (!known) return otherLimit(row, context);
  if (!amount) return undefined;
  // The key names the window when Keeper has no seconds for it.
  const timing = windowTiming(row, context.observedAt, known.windowId);
  if (!known.tier) {
    return meter({ ...timing, id: known.id, scope: { windowId: timing.windowId, shared: true }, amount, usage: windowUsage(row), eligible: true });
  }
  // Keeper fills every window-scoped row with the credential's total for the
  // range, which is not what a tier or app meter counts: leave it off.
  return meter({ ...timing, id: known.id, displayLabel: known.label, scope: { tier: known.tier, windowId: timing.windowId }, amount });
}

const GEMINI_UNITS = { requests: "requests", tokens: "tokens" };

function geminiLimit(row, context) {
  const key = text(row.key);
  if (key.startsWith("bucket.")) {
    const modelId = text(row.label);
    const tokenType = text(row.metric);
    const { resetsAt } = rowTiming(row, context.observedAt);
    // Keeper stores a missing fraction or amount as 0. An exhausted bucket still
    // names its reset, and only a positive amount is certain.
    let fraction = finite(row.remainingFraction);
    if (fraction === 0 && resetsAt === undefined) fraction = undefined;
    const remaining = finite(row.remaining);
    const unit = Object.hasOwn(GEMINI_UNITS, tokenType.toLowerCase()) ? GEMINI_UNITS[tokenType.toLowerCase()] : undefined;
    const amount = {
      ...(fraction === undefined ? {} : remainingShare(fraction)),
      ...(unit && remaining > 0 ? { remaining, unit } : {}),
    };
    if (!Object.keys(amount).length) return undefined;
    // Gemini reports no window length, so the bucket stays a detail of its model.
    return meter({
      id: `google-gemini-cli:${slug(modelId) || "model"}:${slug(tokenType) || "quota"}`,
      displayLabel: modelId || undefined,
      scope: { modelId: modelId || undefined },
      resetsAt,
      amount,
    });
  }
  if (key.startsWith("code_assist.")) {
    const creditType = text(row.metric);
    const remaining = finite(row.remaining);
    if (!(remaining > 0)) return undefined;
    // The same credits can be listed for the current and the paid tier; the first one wins.
    return meter({
      id: `google-gemini-cli:credits:${slug(creditType) || "credits"}`,
      displayLabel: creditType ? `Code Assist credits (${creditType})` : "Code Assist credits",
      scope: { tier: "credits" },
      amount: { remaining, unit: "credits" },
    });
  }
  return otherLimit(row, context);
}

function antigravityLimit(row, context) {
  const key = text(row.key);
  const group = text(row.groupKey);
  if (text(row.scope) !== "quota_group" || !group || !key.startsWith(`bucket.${group}.`)) return otherLimit(row, context);
  const amount = percentAmount(row);
  if (!amount) return undefined;
  const tier = slug(group.replace(/^antigravity-/, "")) || "group";
  const timing = windowTiming(row, context.observedAt);
  const groupLabel = text(row.groupLabel) || "Quota group";
  // Keeper sums these totals per model group, so they measure this meter.
  return meter({
    ...timing,
    id: `google-antigravity:${tier}:${slug(key.slice(`bucket.${group}.`.length)) || "bucket"}`,
    displayLabel: timing.windowId ? groupLabel : [groupLabel, text(row.label)].filter(Boolean).join(" "),
    scope: { tier, windowId: timing.windowId },
    amount,
    usage: windowUsage(row),
    eligible: true,
  });
}

function kimiLimit(row, context) {
  const key = text(row.key);
  if (key === "usages.limit_month_total") {
    // Reported only as a ratio: Keeper's used/limit here are percentages, not counts.
    const amount = percentAmount(row);
    const { resetsAt } = rowTiming(row, context.observedAt);
    return amount && meter({ id: "kimi-code:month-total", windowId: "monthly", resetsAt, scope: { windowId: "monthly", shared: true }, amount });
  }
  if (key !== "usage" && !key.startsWith("limits.")) return otherLimit(row, context);
  const amount = countAmount(row);
  if (!amount) return undefined;
  const timing = rowTiming(row, context.observedAt);
  // The summary names no length; Keeper labels it Weekly, as omp does.
  const ms = timing.durationMs ?? (key === "usage" && /week/i.test(text(row.label)) ? 7 * DAY_MS : undefined);
  const windowId = windowIdFor(ms);
  return meter({
    id: key === "usage" ? "kimi-code:summary" : `kimi-code:${slug(key.slice("limits.".length)) || "limit"}`,
    label: text(row.label),
    windowId,
    durationMs: ms,
    resetsAt: timing.resetsAt,
    scope: { windowId, shared: true },
    amount,
    usage: windowUsage(row),
    eligible: true,
  });
}

function xaiLimit(row, context) {
  const key = text(row.key);
  const timing = windowTiming(row, context.observedAt);
  if (key === "billing.weekly") {
    const amount = percentAmount(row);
    const breakdown = breakdownOf(row);
    if (!amount && !breakdown) return undefined;
    // Keeper fills this account-wide weekly meter with the credential's totals for the same week.
    return meter({
      ...timing,
      id: "xai:weekly",
      scope: { windowId: timing.windowId, shared: true },
      amount: amount ?? {},
      usage: windowUsage(row),
      eligible: true,
      breakdown,
    });
  }
  if (key === "billing.monthly" || key === "billing.on_demand") {
    const amount = moneyAmount(row);
    if (!amount) return undefined;
    return key === "billing.monthly"
      ? meter({ ...timing, id: "xai:monthly", scope: { windowId: timing.windowId, shared: true }, amount })
      : meter({ ...timing, id: "xai:pay-as-you-go", displayLabel: "Pay-as-you-go", scope: { tier: "pay-as-you-go", windowId: timing.windowId }, amount });
  }
  return otherLimit(row, context);
}

// Rows this adapter does not know keep their own named meter and only their
// percentage: their units, scope and totals cannot be confirmed.
function otherLimit(row, context) {
  const key = text(row.key);
  const amount = percentAmount(row);
  if (!key || !amount) return undefined;
  const tier = slug(key);
  const timing = windowTiming(row, context.observedAt);
  return meter({ ...timing, id: `${context.provider}:${tier}`, displayLabel: text(row.label) || key, scope: { tier, windowId: timing.windowId }, amount });
}

// A row without a known window length is listed as a detail, under Keeper's own name for it.
function meter({ id, displayLabel, label, scope, windowId, durationMs: ms, resetsAt, amount, usage, eligible, breakdown }) {
  return compact({
    id,
    displayLabel: displayLabel ?? (windowId ? undefined : label || undefined),
    scope: compact(scope),
    window: compact({ id: windowId, durationMs: ms, resetsAt }),
    amount,
    usage,
    estimateEligible: usage && eligible ? true : undefined,
    breakdown,
  });
}

function rowTiming(row, observedAt) {
  const window = isRecord(row.window) ? row.window : {};
  const seconds = finite(window.seconds);
  let ms = seconds > 0 ? seconds * 1000 : undefined;
  // Keeper leaves seconds empty for units it does not convert; read those only when named.
  if (ms === undefined && typeof window.unit === "string" && window.unit.trim()) {
    ms = durationMs(window.duration, window.unit.trim().toLowerCase().replace(/^time_unit_/, ""));
  }
  // resetAfterSeconds counts from Keeper's observation, not from this read.
  const after = finite(row.resetAfterSeconds);
  const resetsAt = timestamp(row.resetAt) ?? (after >= 0 && observedAt !== undefined ? observedAt + after * 1000 : undefined);
  return { durationMs: ms, resetsAt };
}

function windowTiming(row, observedAt, fallbackId) {
  const timing = rowTiming(row, observedAt);
  return { ...timing, windowId: windowIdFor(timing.durationMs) ?? fallbackId };
}

function windowIdFor(ms) {
  if (ms === undefined) return undefined;
  if (ms >= 28 * DAY_MS && ms <= 31 * DAY_MS) return "monthly";
  if (ms % DAY_MS === 0) return `${ms / DAY_MS}d`;
  if (ms % HOUR_MS === 0) return `${ms / HOUR_MS}h`;
  return `${Math.round(ms / 60_000)}m`;
}

// The share the provider reported is kept exact; only its complement is derived.
function percentAmount(row) {
  const usedPercent = finite(row.usedPercent);
  if (usedPercent !== undefined) return usedShare(usedPercent / 100);
  const remaining = finite(row.remainingFraction);
  return remaining === undefined ? undefined : remainingShare(remaining);
}

function usedShare(used) {
  const usedFraction = Math.min(1, Math.max(0, used));
  return { remainingFraction: 1 - usedFraction, usedFraction };
}

function remainingShare(remaining) {
  const remainingFraction = Math.min(1, Math.max(0, remaining));
  return { remainingFraction, usedFraction: 1 - remainingFraction };
}

// Kimi counters carry no unit. Keeper stores a counter the provider omitted as
// 0, so a zero is kept only when the other two counters confirm it.
function countAmount(row) {
  const limit = finite(row.limit);
  if (!(limit > 0)) return undefined;
  const usedValue = finite(row.used);
  const remainingValue = finite(row.remaining);
  const used = usedValue > 0 || (usedValue === 0 && remainingValue === limit) ? usedValue : undefined;
  const remaining = remainingValue > 0 || (remainingValue === 0 && used >= limit) ? remainingValue : undefined;
  if (used === undefined && remaining === undefined) return undefined;
  return compact({
    used,
    remaining,
    limit,
    ...(used === undefined ? remainingShare(remaining / limit) : usedShare(used / limit)),
  });
}

// xAI billing amounts are USD cents (metric usd_cents); anything else keeps only its percentage.
function moneyAmount(row) {
  const amount = { ...percentAmount(row) };
  if (lower(row.metric) === "usd_cents") {
    for (const field of ["used", "limit", "remaining"]) {
      const cents = finite(row[field]);
      if (cents >= 0) amount[field] = cents / 100;
    }
  }
  if (amount.used !== undefined || amount.limit !== undefined || amount.remaining !== undefined) {
    Object.assign(amount, { unit: "usd", currency: "USD" });
  }
  return Object.keys(amount).length ? amount : undefined;
}

// Keeper prices usage from models.dev or LiteLLM rates and shows these totals as USD.
function windowUsage(row) {
  const tokens = finite(row.window_usage_tokens);
  const cost = finite(row.window_usage_cost);
  const usage = compact({
    tokens: tokens >= 0 ? tokens : undefined,
    cost: cost >= 0 ? cost : undefined,
    currency: cost >= 0 ? "USD" : undefined,
  });
  return Object.keys(usage).length ? usage : undefined;
}

function breakdownOf(row) {
  const items = (Array.isArray(row.usageBreakdown) ? row.usageBreakdown : []).flatMap((item) => {
    const label = isRecord(item) ? text(item.product) : "";
    const percent = isRecord(item) ? finite(item.usedPercent) : undefined;
    return label && percent !== undefined ? [{ label, usedFraction: Math.min(1, Math.max(0, percent / 100)) }] : [];
  });
  return items.length ? items : undefined;
}

function codexResetCredits(quota) {
  const count = finite(quota.rateLimitResetCreditsAvailableCount);
  return count >= 0 ? { availableCount: Math.trunc(count) } : undefined;
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value) {
  return typeof value === "string" ? value.trim() : "";
}

function lower(value) {
  return text(value).toLowerCase();
}

function slug(value) {
  return String(value).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
}

function compact(object) {
  return Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));
}
