// CPA source parsing boundaries, against a fake CPA v8 management API: paging,
// zero vs missing numbers, window units, meter scopes, money units, provider
// failures and unsupported credentials.
import assert from "node:assert/strict";
import { test } from "node:test";

import { createCPASource } from "../omp/extensions/usage-sources/cpa.js";

const KEY = "cpa-management-key";
const BASE = "http://cpa.test/proxy";
const HOUR = 3_600_000;
const DAY = 86_400_000;

function json(status, value) {
  return new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });
}

const ok = (body) => ({ status: 200, body });

// A CPA v8 server under BASE's path prefix. It pages `credentials` at most
// `pageCap` per page whatever the client asks; `upstream(call)` answers
// api-call requests with { status, body } (body an object or text), { outer }
// for a refused api-call, or nothing for a missing endpoint; `plugins` maps a
// plugin id to its quota response.
function fakeCpa({ credentials = [], upstream = () => undefined, plugins = {}, pageCap = 2 } = {}) {
  return async (url, init = {}) => {
    const { origin, pathname, searchParams } = new URL(url);
    const full = `${origin}${pathname}`;
    if (!full.startsWith(`${BASE}/`)) return json(404, { error: "not found" });
    if (init.headers?.Authorization !== `Bearer ${KEY}`) return json(401, { error: "invalid management key" });
    const route = full.slice(BASE.length);
    if (route === "/v8/management/credentials" && init.method === "GET") {
      const size = Math.min(Number(searchParams.get("page_size")), pageCap);
      const page = Number(searchParams.get("page"));
      const files = credentials.slice((page - 1) * size, page * size);
      return json(200, { files, total: credentials.length, page, page_size: size, has_more: page * size < credentials.length });
    }
    if (route === "/v8/management/requests/api-call" && init.method === "POST") {
      const answer = upstream(JSON.parse(init.body));
      if (answer?.outer) return json(answer.outer, { error: "auth token not found" });
      if (!answer) return json(200, { status_code: 404, header: {}, body: "" });
      const body = typeof answer.body === "string" ? answer.body : JSON.stringify(answer.body);
      return json(200, { status_code: answer.status, header: { "Set-Cookie": ["session=upstream-secret"] }, body });
    }
    const plugin = /^\/v8\/management\/plugins\/([^/]+)\/quota$/.exec(route);
    if (plugin && init.method === "GET") {
      const quota = plugins[decodeURIComponent(plugin[1])];
      return quota ? json(200, quota(searchParams.get("auth_index"))) : json(404, { error: "quota provider not found for plugin" });
    }
    return json(404, { error: "not found" });
  };
}

function source(server, config = {}, env = { CPA_KEY: KEY }) {
  return createCPASource({ id: "test", type: "cpa", baseUrl: BASE, managementKeyEnv: "CPA_KEY", ...config }, { fetch: fakeCpa(server), env });
}

const poll = (server, config) => source(server, config).poll();
const account = (reports, id) => reports.find((report) => report.metadata.accountId === id);
const limitOf = (report, id) => report.limits.find((entry) => entry.id === id);

function close(actual, expected) {
  assert.ok(typeof actual === "number" && Math.abs(actual - expected) < 1e-9, `${actual} is not ${expected}`);
}

test("reads every credential page under the deployment prefix, skipping disabled and unselected ones", async () => {
  const credentials = [
    { auth_index: "a1", provider: "codex", email: "a@example.com" },
    { auth_index: "b2", provider: "claude", disabled: true },
    { auth_index: "c3", provider: "codex" },
    { auth_index: "d4", provider: "qwen" },
    { auth_index: "e5", provider: "codex", status: "disabled" },
    { auth_index: "c3", provider: "codex" },
  ];
  const upstream = () => ok({ rate_limit: { primary_window: { used_percent: 10, limit_window_seconds: 18000 } } });
  const reports = await poll({ credentials, upstream }, { providers: ["openai-codex"] });
  assert.deepEqual(reports.map((report) => report.metadata.accountId), ["a1", "c3"]);
  assert.equal(reports[0].provider, "openai-codex");
  assert.equal(reports[0].metadata.email, "a@example.com");
});

test("codex keeps explicit zeros, drops missing percentages and a meter's copy of the general window usage", async () => {
  const usage = {
    plan_type: "pro",
    rate_limit: {
      allowed: true,
      limit_reached: false,
      primary_window: { used_percent: 0, limit_window_seconds: 18000, reset_at: 1780331042, window_usage_tokens: 11368055, window_usage_cost: 14.83442025 },
      secondary_window: { limit_window_seconds: 604800, reset_after_seconds: 3600, window_usage_tokens: null, window_usage_cost: null },
    },
    code_review_rate_limit: { primary_window: { used_percent: "12.5", limit_window_seconds: 604800 } },
    additional_rate_limits: [{
      limit_name: "GPT-5.3-Codex-Spark",
      metered_feature: "codex_bengalfox",
      rate_limit: {
        primary_window: { used_percent: 40, limit_window_seconds: 18000, window_usage_tokens: 11368055, window_usage_cost: 14.83442025 },
        secondary_window: { used_percent: 10, limit_window_seconds: 604800, windowUsageTokens: 0, windowUsageCost: 0 },
      },
    }],
    rate_limit_reset_credits: { available_count: 0 },
  };
  const [report] = await poll({
    credentials: [{ auth_index: "cx", provider: "codex", id_token: { chatgpt_account_id: "acct-1", plan_type: "plus" } }],
    upstream: (call) => (call.url.endsWith("/wham/usage") ? ok(usage) : undefined),
  });
  assert.equal(report.error, undefined);
  assert.equal(report.metadata.plan, "pro");

  const fiveHour = limitOf(report, "openai-codex:5h");
  assert.equal(fiveHour.amount.usedFraction, 0);
  assert.equal(fiveHour.amount.remainingFraction, 1);
  assert.equal(fiveHour.window.durationMs, 5 * HOUR);
  assert.equal(fiveHour.window.resetsAt, 1780331042000);
  assert.deepEqual(fiveHour.usage, { tokens: 11368055, cost: 14.83442025, currency: "USD" });
  assert.equal(fiveHour.estimateEligible, true);
  assert.equal(fiveHour.displayLabel, undefined);

  // Missing utilization stays unknown even when the provider reports status.
  const weeklyStatus = limitOf(report, "openai-codex:7d");
  assert.equal(weeklyStatus.amount.usedFraction, undefined);
  assert.equal(weeklyStatus.amount.remainingFraction, undefined);
  assert.equal(weeklyStatus.allowed, true);

  const review = limitOf(report, "openai-codex:7d:code-review");
  assert.equal(review.displayLabel, "Code review");
  close(review.amount.usedFraction, 0.125);
  assert.equal(review.window.durationMs, 7 * DAY);

  const spark5h = limitOf(report, "openai-codex:5h:spark");
  assert.equal(spark5h.displayLabel, "GPT-5.3-Codex-Spark");
  assert.equal(spark5h.scope.modelId, "gpt-5.3-codex-spark");
  assert.equal(spark5h.scope.tier, "spark");
  close(spark5h.amount.usedFraction, 0.4);
  assert.equal(spark5h.usage, undefined);
  assert.equal(spark5h.estimateEligible, undefined);

  const spark7d = limitOf(report, "openai-codex:7d:spark");
  assert.deepEqual(spark7d.usage, { tokens: 0, cost: 0, currency: "USD" });
  close(spark7d.amount.remainingFraction, 0.9);

  assert.deepEqual(report.resetCredits, { availableCount: 0 });
});

test("claude reads utilization percents, skips empty windows and converts extra usage from minor units", async () => {
  const upstream = (call) => {
    const usage = call.url.includes("/api/oauth/usage");
    if (call.auth_index === "cl1") {
      return usage
        ? ok({
          five_hour: { utilization: 0, resets_at: "2026-11-13T12:00:00Z" },
          seven_day: { utilization: 37.5, resets_at: "2026-11-18T00:00:00+00:00" },
          seven_day_opus: null,
          seven_day_sonnet: { utilization: null, resets_at: "2026-11-18T00:00:00Z" },
          seven_day_oauth_apps: { utilization: 80, resets_at: "2026-11-18T00:00:00Z" },
          extra_usage: { is_enabled: true, monthly_limit: 5000, used_credits: 1234, utilization: 24.68 },
        })
        : { status: 500, body: "profile unavailable" };
    }
    return usage
      ? ok({ five_hour: { utilization: 12 }, extra_usage: { is_enabled: true, monthly_limit: null, used_credits: 4200, decimal_places: 3, currency: "eur" } })
      : ok({ account: { has_claude_max: true }, organization: { rate_limit_tier: "default_claude_max_20x" } });
  };
  const reports = await poll({ credentials: [{ auth_index: "cl1", provider: "claude" }, { auth_index: "cl2", provider: "claude" }], upstream });

  const first = account(reports, "cl1");
  assert.equal(first.error, undefined);
  assert.equal(first.metadata.plan, undefined);
  const fiveHour = limitOf(first, "anthropic:5h");
  assert.equal(fiveHour.amount.usedFraction, 0);
  assert.equal(fiveHour.window.resetsAt, Date.parse("2026-11-13T12:00:00Z"));
  close(limitOf(first, "anthropic:7d").amount.usedFraction, 0.375);
  assert.equal(limitOf(first, "anthropic:7d:opus"), undefined);
  assert.equal(limitOf(first, "anthropic:7d:sonnet"), undefined);
  const apps = limitOf(first, "anthropic:7d:oauth-apps");
  assert.equal(apps.displayLabel, "OAuth apps");
  assert.equal(apps.scope.tier, "oauth-apps");
  close(apps.amount.usedFraction, 0.8);
  const extra = limitOf(first, "anthropic:monthly:extra-usage").amount;
  assert.equal(extra.currency, "USD");
  close(extra.used, 12.34);
  close(extra.limit, 50);
  close(extra.remaining, 37.66);
  close(extra.usedFraction, 0.2468);

  const second = account(reports, "cl2");
  assert.equal(second.metadata.plan, "max-20x");
  const uncapped = limitOf(second, "anthropic:monthly:extra-usage").amount;
  assert.equal(uncapped.currency, "EUR");
  close(uncapped.used, 4.2);
  assert.equal(uncapped.limit, undefined);
  assert.equal(uncapped.usedFraction, undefined);
});

test("claude reads model-family weekly caps and missing general windows from limits[] entries", async () => {
  const usage = {
    five_hour: null,
    seven_day: null,
    seven_day_opus: null,
    seven_day_sonnet: null,
    limits: [
      { kind: "session", percent: 20, resets_at: "2026-11-13T15:00:00Z", is_active: false },
      { kind: "weekly_all", percent: "55", resets_at: "2026-11-18T00:00:00Z", is_active: false },
      { kind: "weekly_scoped", percent: 0, resets_at: "2026-11-19T00:00:00Z", is_active: false, scope: { model: { display_name: "Fable" } } },
      { kind: "weekly_scoped", percent: 90, scope: { model: { display_name: "fable" } } },
      { kind: "weekly_scoped", percent: 40, is_active: true, scope: { model: { display_name: "Mythos" } } },
      { kind: "weekly_scoped", percent: 10, scope: {} },
    ],
  };
  const [report] = await poll({
    credentials: [{ auth_index: "cl3", provider: "claude" }],
    upstream: (call) => (call.url.includes("/api/oauth/usage") ? ok(usage) : undefined),
  });

  assert.deepEqual(report.limits.map((entry) => entry.id), ["anthropic:5h", "anthropic:7d", "anthropic:7d:fable", "anthropic:7d:mythos"]);
  const fiveHour = limitOf(report, "anthropic:5h");
  close(fiveHour.amount.usedFraction, 0.2);
  assert.equal(fiveHour.window.resetsAt, Date.parse("2026-11-13T15:00:00Z"));
  close(limitOf(report, "anthropic:7d").amount.usedFraction, 0.55);
  const fable = limitOf(report, "anthropic:7d:fable");
  assert.equal(fable.amount.usedFraction, 0);
  assert.equal(fable.amount.remainingFraction, 1);
  assert.equal(fable.displayLabel, "Fable");
  assert.equal(fable.scope.tier, "fable");
  assert.equal(fable.scope.modelId, undefined);
  assert.equal(fable.window.durationMs, 7 * DAY);
  assert.equal(fable.window.resetsAt, Date.parse("2026-11-19T00:00:00Z"));
  close(limitOf(report, "anthropic:7d:mythos").amount.usedFraction, 0.4);
});

test("xai converts billing cents to dollars and splits the included allowance from pay-as-you-go", async () => {
  const weekly = {
    config: {
      current_period: { type: "weekly", end: "2026-07-13T00:00:00Z" },
      credit_usage_percent: 0,
      product_usage: [{ product: "Grok 4", usage_percent: 80 }, { product: "grok  4", usagePercent: "85" }, { product: "No Data", usage_percent: null }],
    },
  };
  const monthly = {
    config: {
      monthly_limit: { val: "1000" },
      used: 1250,
      on_demand_cap: { val: 500 },
      billing_period_start: "2026-07-01T00:00:00Z",
      billing_period_end: "2026-08-01T00:00:00Z",
    },
  };
  const [report] = await poll({
    credentials: [{ auth_index: "x1", provider: "xai" }],
    upstream: (call) => (call.url.endsWith("?format=credits") ? ok(weekly) : ok(monthly)),
  });

  const week = limitOf(report, "xai:7d");
  assert.equal(week.amount.usedFraction, 0);
  assert.equal(week.window.resetsAt, Date.parse("2026-07-13T00:00:00Z"));
  assert.deepEqual(week.breakdown, [{ label: "Grok 4", usedFraction: 0.85 }]);

  const included = limitOf(report, "xai:monthly");
  assert.equal(included.amount.currency, "USD");
  assert.equal(included.amount.limit, 10);
  assert.equal(included.amount.used, 10);
  assert.equal(included.amount.remaining, 0);
  assert.equal(included.amount.usedFraction, 1);
  assert.equal(included.window.durationMs, 31 * DAY);
  assert.equal(included.window.resetsAt, Date.parse("2026-08-01T00:00:00Z"));

  const onDemand = limitOf(report, "xai:monthly:on-demand");
  assert.equal(onDemand.displayLabel, "Pay-as-you-go");
  assert.equal(onDemand.amount.limit, 5);
  assert.equal(onDemand.amount.used, 2.5);
  assert.equal(onDemand.amount.remaining, 2.5);
  assert.equal(onDemand.amount.usedFraction, 0.5);
});

test("kimi reads string counts from detail, keeps a zero monthly ratio and picks kimi.com or kimi.ai without downloads", async () => {
  const payloads = {
    "api.kimi.com": {
      usage: { limit: "100", used: "28", remaining: "72", resetTime: "2026-07-31T02:59:25.127311Z" },
      limits: [{ window: { duration: 300, timeUnit: "TIME_UNIT_MINUTE" }, detail: { limit: "100", remaining: "85", resetTime: "2026-07-24T12:59:25.127311Z" } }],
      usages: { limit_month_total: { used_ratio: 0, reset_time: "2026-11-05T00:00:00Z" } },
    },
    "api.kimi.ai": {
      limits: [{ name: "daily", title: "Daily", used: 3, limit: 10, remaining: 7, window: { duration: 1, timeUnit: "day" }, detail: { resetIn: 3600 } }],
      usages: { limit_month_total: { used_ratio: -0.1 } },
    },
  };
  const server = {
    credentials: [{ auth_index: "k1", provider: "kimi" }, { auth_index: "k2", provider: "kimi-ai" }],
    upstream: (call) => ok(payloads[new URL(call.url).hostname]),
  };
  const before = Date.now();
  const reports = await poll(server);
  const after = Date.now();

  const com = account(reports, "k1");
  assert.equal(com.provider, "kimi-code");
  const fiveHour = limitOf(com, "kimi-code:5h");
  assert.equal(fiveHour.window.durationMs, 5 * HOUR);
  assert.equal(fiveHour.window.resetsAt, Date.parse("2026-07-24T12:59:25.127311Z"));
  assert.equal(fiveHour.amount.used, 15);
  assert.equal(fiveHour.amount.limit, 100);
  assert.equal(fiveHour.amount.remaining, 85);
  close(fiveHour.amount.usedFraction, 0.15);
  assert.equal(fiveHour.amount.unit, undefined);
  const week = limitOf(com, "kimi-code:7d");
  assert.equal(week.amount.used, 28);
  close(week.amount.remainingFraction, 0.72);
  const month = limitOf(com, "kimi-code:monthly");
  assert.equal(month.amount.usedFraction, 0);
  assert.equal(month.amount.remainingFraction, 1);

  const ai = account(reports, "k2");
  const daily = limitOf(ai, "kimi-code:1d");
  assert.equal(daily.displayLabel, undefined);
  close(daily.amount.usedFraction, 0.3);
  assert.ok(daily.window.resetsAt >= before + HOUR && daily.window.resetsAt <= after + HOUR);
  assert.equal(limitOf(ai, "kimi-code:monthly"), undefined);
  assert.equal(limitOf(ai, "kimi-code:7d"), undefined);

  const [configured] = await poll({ ...server, credentials: [{ auth_index: "k1", provider: "kimi" }] }, { kimiDomain: "ai" });
  assert.ok(limitOf(configured, "kimi-code:1d"));
});

test("gemini cli keeps request counts with their unit, rejects shares outside 0..1 and needs a project id", async () => {
  const upstream = (call) => {
    if (JSON.parse(call.data ?? "{}").project !== "proj-1" && call.url.endsWith(":retrieveUserQuota")) return { status: 400, body: "project required" };
    if (call.url.endsWith(":retrieveUserQuota")) {
      return ok({
        buckets: [
          { modelId: "gemini-2.5-pro", tokenType: "REQUESTS", remainingFraction: 0, remainingAmount: "0", resetTime: "2026-11-14T00:00:00Z" },
          { modelId: "gemini-2.5-flash", tokenType: "REQUESTS", remainingFraction: 0.75 },
          { modelId: "gemini-2.0-flash", tokenType: "REQUESTS", remainingFraction: 1.5 },
        ],
      });
    }
    return ok({
      currentTier: { id: "free-tier" },
      paidTier: { id: "g1-pro-tier", name: "Google AI Pro", availableCredits: [{ creditType: "GOOGLE_ONE_AI", creditAmount: "250" }] },
    });
  };
  const reports = await poll({
    credentials: [{ auth_index: "g1", provider: "gemini-cli", project_id: "proj-1" }, { auth_index: "g2", provider: "gemini-cli" }],
    upstream,
  });

  const report = account(reports, "g1");
  assert.equal(report.provider, "google-gemini-cli");
  const pro = limitOf(report, "google-gemini-cli:quota:gemini-2-5-pro-requests");
  assert.equal(pro.displayLabel, "gemini-2.5-pro");
  assert.equal(pro.scope.modelId, "gemini-2.5-pro");
  assert.equal(pro.amount.remainingFraction, 0);
  assert.equal(pro.amount.usedFraction, 1);
  assert.equal(pro.amount.remaining, 0);
  assert.equal(pro.amount.unit, "requests");
  assert.equal(pro.window.durationMs, undefined);
  assert.equal(pro.window.resetsAt, Date.parse("2026-11-14T00:00:00Z"));
  const flash = limitOf(report, "google-gemini-cli:quota:gemini-2-5-flash-requests");
  assert.equal(flash.amount.remainingFraction, 0.75);
  assert.equal(flash.amount.remaining, undefined);
  assert.equal(flash.amount.unit, undefined);
  assert.equal(report.limits.length, 2);
  assert.equal(report.metadata.plan, "pro");
  assert.deepEqual(report.summary, [{ label: "Credits (GOOGLE_ONE_AI)", value: 250, unit: "credits" }]);

  const missing = account(reports, "g2");
  assert.match(missing.error, /project_id/);
  assert.deepEqual(missing.limits, []);
});

test("antigravity falls through failing and empty endpoints to the first with quota groups", async () => {
  const groups = {
    groups: [{
      displayName: "Gemini Models",
      buckets: [
        { bucketId: "gemini-weekly", window: "weekly", remainingFraction: "50%", resetTime: "2026-11-20T00:00:00Z" },
        { bucketId: "gemini-5h", window: "5h", remainingFraction: 0.9 },
        { bucketId: "gemini-burst", displayName: "Burst", remainingFraction: 0.2 },
        { bucketId: "gemini-none", window: "5h" },
      ],
    }],
  };
  const upstream = (call) => {
    const { hostname, pathname } = new URL(call.url);
    if (pathname.endsWith(":loadCodeAssist")) return ok({ currentTier: { id: "g1-ultra-tier", name: "Google AI Ultra" } });
    if (hostname === "daily-cloudcode-pa.googleapis.com") return { status: 503, body: "busy" };
    if (hostname === "daily-cloudcode-pa.sandbox.googleapis.com") return ok({ groups: [] });
    return ok({ body: JSON.stringify(groups) });
  };
  const [report] = await poll({ credentials: [{ auth_index: "ag", provider: "antigravity", project_id: "proj-ag" }], upstream });

  assert.equal(report.error, undefined);
  assert.equal(report.provider, "google-antigravity");
  assert.equal(report.metadata.plan, "ultra");
  assert.deepEqual(report.limits.map((entry) => entry.id), [
    "google-antigravity:5h:gemini-models",
    "google-antigravity:7d:gemini-models",
    "google-antigravity:gemini-burst:gemini-models",
  ]);
  const [fiveHour, week, burst] = report.limits;
  assert.equal(fiveHour.displayLabel, "Gemini Models");
  assert.equal(fiveHour.amount.remainingFraction, 0.9);
  close(fiveHour.amount.usedFraction, 0.1);
  assert.equal(week.amount.remainingFraction, 0.5);
  assert.equal(week.window.durationMs, 7 * DAY);
  assert.equal(week.window.resetsAt, Date.parse("2026-11-20T00:00:00Z"));
  assert.equal(burst.displayLabel, "Gemini Models Burst");
  assert.equal(burst.window.durationMs, undefined);
});

test("quota plugins give windows, currency summaries and plan for providers without a built-in reader", async () => {
  const plugins = {
    "balance-plugin": () => ({
      subscription: { plan: "Top-up" },
      serverTimeOffsetMs: 2000,
      summary: [
        { key: "balance", label: "Balance", value: 12.5, format: "currency", currency: "usd" },
        { key: "bad", label: "Broken", value: "12" },
        { key: "tokens", label: "Tokens left", value: 0, unit: "tokens" },
      ],
      groups: [
        { displayName: "Daily", buckets: [{ window: "daily", remainingFraction: 0.4, resetTime: "2026-11-14T00:00:00Z" }, { window: "weekly", remainingFraction: 85 }] },
        { displayName: "Search", buckets: [{ window: "burst", remainingFraction: 0, description: "Burst searches" }] },
      ],
    }),
  };
  const reports = await poll(
    { credentials: [{ auth_index: "p1", provider: "DeepSeek", quota_plugin_id: "balance-plugin" }, { auth_index: "p2", provider: "openrouter" }], plugins },
    { quotaPluginId: "fallback-plugin" },
  );

  const report = account(reports, "p1");
  assert.equal(report.provider, "deepseek");
  assert.equal(report.metadata.plan, "Top-up");
  assert.deepEqual(report.summary, [
    { label: "Balance", value: 12.5, currency: "USD" },
    { label: "Tokens left", value: 0, unit: "tokens" },
  ]);
  const daily = limitOf(report, "deepseek:1d:daily");
  assert.equal(daily.displayLabel, undefined);
  assert.equal(daily.window.durationMs, DAY);
  assert.equal(daily.window.resetsAt, Date.parse("2026-11-14T00:00:00Z") - 2000);
  close(daily.amount.usedFraction, 0.6);
  const search = limitOf(report, "deepseek:burst:search");
  assert.equal(search.displayLabel, "Search burst");
  assert.equal(search.amount.remainingFraction, 0);
  assert.equal(search.amount.usedFraction, 1);
  assert.equal(report.limits.length, 2);

  const fallback = account(reports, "p2");
  assert.match(fallback.error, /fallback-plugin.*HTTP 404/);
  assert.deepEqual(fallback.limits, []);
});

test("unsupported credentials and provider failures become controlled per-account errors", async () => {
  const upstream = (call) => {
    if (call.auth_index === "c401") return { status: 401, body: JSON.stringify({ error: { message: "token sk-secret-token-123 expired" } }) };
    if (call.auth_index === "c400") return { outer: 400 };
    return undefined;
  };
  const reports = await poll({
    credentials: [
      { auth_index: "q1", provider: "qwen" },
      { auth_index: "c401", provider: "codex" },
      { auth_index: "k-api", provider: "claude", account_type: "api_key", account: "sk-ant-api-key-value" },
      { auth_index: "c400", provider: "codex" },
    ],
    upstream,
  });

  const unsupported = account(reports, "q1");
  assert.match(unsupported.error, /not supported for qwen/);
  assert.deepEqual(unsupported.limits, []);
  assert.equal(unsupported.observedAt, undefined);

  const rejected = account(reports, "c401");
  assert.match(rejected.error, /HTTP 401/);
  assert.deepEqual(rejected.limits, []);

  const apiKey = account(reports, "k-api");
  assert.match(apiKey.error, /API-key/);

  assert.match(account(reports, "c400").error, /sign it in again/);

  const text = JSON.stringify(reports);
  for (const secret of ["sk-secret-token-123", "sk-ant-api-key-value", "upstream-secret", KEY]) assert.ok(!text.includes(secret), secret);
});

test("a missing or rejected management key fails the poll without exposing the key", async () => {
  await assert.rejects(source({}, {}, {}).poll(), /CPA_KEY/);
  await assert.rejects(source({}, {}, { CPA_KEY: "wrong-key-value" }).poll(), (error) => {
    assert.match(error.message, /HTTP 401/);
    assert.ok(!error.message.includes("wrong-key-value"));
    return true;
  });
});

test("rejects base URLs and Kimi domains it cannot use", () => {
  const create = (config) => createCPASource({ baseUrl: BASE, managementKeyEnv: "CPA_KEY", ...config }, { fetch: async () => json(200, {}), env: {} });
  assert.throws(() => create({ baseUrl: "http://cpa.test/?key=1" }), /baseUrl/);
  assert.throws(() => create({ baseUrl: "ftp://cpa.test" }), /baseUrl/);
  assert.throws(() => create({ kimiDomain: "cn" }), /kimiDomain/);
  assert.throws(() => create({ managementKeyEnv: "" }), /managementKeyEnv/);
});

test("an explicitly selected quota plugin overrides a built-in reader", async () => {
  const reports = await poll({
    credentials: [{ auth_index: "plugin-codex", type: "codex" }],
    plugins: { chosen: () => ({ groups: [{ displayName: "Plan", buckets: [{ window: "5h", remainingFraction: 0.42 }] }] }) },
  }, { quotaPluginId: "chosen" });
  assert.equal(reports[0].limits[0].amount.remainingFraction, 0.42);
});

test("Codex status without a usage percentage stays status, not zero remaining", async () => {
  const reports = await poll({
    credentials: [{ auth_index: "flags", type: "codex" }],
    upstream: () => ok({ rate_limit: { allowed: false, limit_reached: true } }),
  });
  assert.equal(reports[0].limits[0].allowed, false);
  assert.equal(reports[0].limits[0].limitReached, true);
  assert.equal(reports[0].limits[0].amount.remainingFraction, undefined);
});

test("Claude reset grants keep their scope and remaining count without a redemption request", async () => {
  const expiry = new Date(Date.now() + DAY).toISOString();
  const [report] = await poll({
    credentials: [{ auth_index: "grants", provider: "claude" }],
    upstream: (call) => call.url.includes("/api/oauth/usage") ? ok({
      seven_day: { utilization: 25, resets_at: expiry },
      cedar_ember: { eligible: true, next_grant_id: "weekly", grants: [{ id: "weekly", resets_left: 2, ends_at: expiry, clears: ["seven_day"], usable_now: true }] },
    }) : undefined,
  });
  assert.equal(report.resetCredits.availableCount, 2);
  assert.equal(report.resetCredits.credits[0].remainingCount, 2);
  assert.deepEqual(report.resetCredits.credits[0].clears, ["anthropic:7d"]);
  assert.equal(report.resetCredits.credits[0].usable, true);
});
