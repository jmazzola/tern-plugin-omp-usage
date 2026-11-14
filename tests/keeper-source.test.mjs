import assert from "node:assert/strict";
import { test } from "node:test";
import { createKeeperSource } from "../omp/extensions/usage-sources/keeper.js";

const PASSWORD = "correct horse battery staple";
const BASE = "/keeper";
const HOUR = 3_600_000;
const DAY = 86_400_000;

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

// An in-memory Keeper behind a base path that enforces its login, session and
// request-intent rules.
function fakeKeeper({ identities = [], items = [] } = {}) {
  const server = { logins: 0, sessions: new Set(), refreshed: [], rejectSessions: false };
  server.fetch = async (url, init = {}) => {
    const { pathname } = new URL(url);
    const method = init.method ?? "GET";
    const headers = new Headers(init.headers);
    const body = init.body === undefined ? undefined : JSON.parse(init.body);
    if (!pathname.startsWith(`${BASE}/api/v1/`)) return json(404, { error: "not found" });
    const route = pathname.slice(BASE.length);
    if (method !== "GET" && headers.get("X-CPA-Usage-Keeper-Request") !== "fetch") return json(403, { error: "fetch request required" });
    if (method === "POST" && route === "/api/v1/auth/login") {
      server.logins += 1;
      if (body?.password !== PASSWORD) return json(401, { error: "invalid password" });
      const token = `session-${server.logins}`;
      server.sessions.add(token);
      return new Response(null, {
        status: 204,
        headers: { "Set-Cookie": `cpa_usage_keeper_session=${token}; Path=${BASE}; HttpOnly; SameSite=Lax` },
      });
    }
    const token = /(?:^|;\s*)cpa_usage_keeper_session=([^;]+)/.exec(headers.get("Cookie") ?? "")?.[1];
    if (server.rejectSessions || !server.sessions.has(token)) return json(401, { error: "authentication required" });
    if (method === "GET" && route === "/api/v1/usage/identities") return json(200, { identities });
    if (method === "POST" && route === "/api/v1/quota/cache") {
      const wanted = new Set(body.auth_indexes);
      return json(200, { items: items.filter((item) => wanted.has(item.auth_index)) });
    }
    if (method === "POST" && route === "/api/v1/quota/refresh") {
      server.refreshed.push(body.auth_indexes);
      const count = body.auth_indexes.length;
      return json(200, { tasks: body.auth_indexes.map((authIndex) => ({ authIndex })), rejected: null, accepted: count, skipped: 0, limit: count });
    }
    return json(404, { error: "not found" });
  };
  return server;
}

function source(server, overrides = {}) {
  return createKeeperSource(
    { id: "keeper", type: "keeper", baseUrl: `http://keeper.test${BASE}/`, passwordEnv: "KEEPER_PASSWORD", ...overrides },
    { fetch: server.fetch, env: { KEEPER_PASSWORD: PASSWORD, KEEPER_SESSION: "manual-token" } },
  );
}

function credential(authIndex, type) {
  return {
    id: "41",
    name: `${authIndex}@example.com`,
    displayName: `${authIndex}@example.com`,
    auth_type: 1,
    identity: authIndex,
    type,
    provider: type,
    disabled: false,
    is_deleted: false,
  };
}

function snapshot(authIndex, refreshedAt, rows) {
  return {
    auth_index: authIndex,
    status: "completed",
    quota: { id: authIndex, quota: rows },
    refreshed_at: new Date(refreshedAt).toISOString(),
  };
}

const byAccount = (reports, authIndex) => reports.find((report) => report.metadata.accountId === authIndex);
const byId = (report, id) => report.limits.find((limit) => limit.id === id);

test("reads Keeper's cache only and reports a missing snapshot as missing", async () => {
  const now = Date.now();
  const server = fakeKeeper({
    identities: [credential("codex-1", "codex"), credential("claude-1", "claude"), { ...credential("off-1", "codex"), disabled: true }],
    items: [
      snapshot("codex-1", now - 60_000, [
        { key: "rate_limit.primary_window", label: "5h", scope: "window", usedPercent: 25, window: { seconds: 18_000 }, resetAt: new Date(now + HOUR).toISOString() },
      ]),
    ],
  });
  const reports = await source(server).poll();
  assert.deepEqual(server.refreshed, []);
  assert.deepEqual(reports.map((report) => report.metadata.accountId), ["codex-1", "claude-1"]);
  const missing = byAccount(reports, "claude-1");
  assert.equal(missing.provider, "anthropic");
  assert.deepEqual(missing.limits, []);
  assert.equal(missing.observedAt, undefined);
  assert.match(missing.error, /no cached quota/);
  const primary = byId(byAccount(reports, "codex-1"), "openai-codex:primary");
  assert.equal(primary.window.id, "5h");
  assert.equal(primary.amount.remainingFraction, 0.75);
});

test("an old snapshot keeps Keeper's observation time and its reset clock", async () => {
  const refreshedAt = Date.now() - 3 * DAY;
  const server = fakeKeeper({
    identities: [credential("codex-1", "codex")],
    items: [
      snapshot("codex-1", refreshedAt, [
        { key: "rate_limit.primary_window", label: "5h", scope: "window", usedPercent: 50, window: { seconds: 18_000 }, resetAfterSeconds: 3600 },
      ]),
    ],
  });
  const [report] = await source(server).poll();
  assert.equal(report.observedAt, refreshedAt);
  const [limit] = report.limits;
  assert.equal(limit.window.resetsAt, refreshedAt + HOUR);
  assert.equal(limit.amount.remainingFraction, 0.5);
});

test("refresh queues missing, aging and rolled-over snapshots but not cached provider failures", async () => {
  const now = Date.now();
  const row = { key: "rate_limit.primary_window", label: "5h", scope: "window", usedPercent: 10, window: { seconds: 18_000 } };
  const later = new Date(now + HOUR).toISOString();
  const server = fakeKeeper({
    identities: ["fresh", "aging", "rolled", "missing", "rejected"].map((name) => credential(name, "codex")),
    items: [
      snapshot("fresh", now - 60_000, [{ ...row, resetAt: later }]),
      snapshot("aging", now - 2 * HOUR, [{ ...row, resetAt: later }]),
      snapshot("rolled", now - 120_000, [{ ...row, resetAt: new Date(now - 60_000).toISOString() }]),
      {
        auth_index: "rejected",
        status: "failed",
        error: "upstream said: token sk-live-123 revoked",
        http_status_code: 401,
        refreshed_at: new Date(now - 60_000).toISOString(),
        expires_at: later,
      },
    ],
  });
  const reports = await source(server, { refresh: true, maxAgeSeconds: 600 }).poll();
  assert.deepEqual(server.refreshed, [["aging", "rolled", "missing"]]);
  assert.match(byAccount(reports, "missing").error, /refresh was requested/);
  const rejected = byAccount(reports, "rejected");
  assert.deepEqual(rejected.limits, []);
  assert.match(rejected.error, /HTTP 401/);
  assert.doesNotMatch(JSON.stringify(reports), /sk-live-123/);
});

test("zero counters stay apart from counters Keeper zero-filled", async () => {
  const now = Date.now();
  const reset = new Date(now + HOUR).toISOString();
  const server = fakeKeeper({
    identities: [credential("kimi-1", "kimi"), credential("gemini-1", "gemini-cli"), credential("codex-1", "codex")],
    items: [
      snapshot("kimi-1", now, [
        // `remaining` was absent upstream; Keeper serialised it as 0.
        { key: "limits.a", label: "5h", scope: "limit", used: 25, limit: 100, remaining: 0, window: { duration: 300, unit: "TIME_UNIT_MINUTE", seconds: 18_000 } },
        // `used` was absent upstream.
        { key: "limits.b", label: "Limit", scope: "limit", used: 0, limit: 100, remaining: 75 },
        // A fresh window: the other counters confirm the zero.
        { key: "limits.c", label: "Limit", scope: "limit", used: 0, limit: 100, remaining: 100 },
        { key: "limits.d", label: "Limit", scope: "limit", used: 0, limit: 0, remaining: 0 },
      ]),
      snapshot("gemini-1", now, [
        { key: "bucket.gemini-2.5-pro.REQUESTS", label: "gemini-2.5-pro", scope: "model", metric: "REQUESTS", remaining: 0, remainingFraction: 0, resetAt: reset },
        { key: "bucket.gemini-2.5-flash.REQUESTS", label: "gemini-2.5-flash", scope: "model", metric: "REQUESTS", remaining: 0, remainingFraction: 0 },
        { key: "bucket.gemini-2.5-flash-lite.REQUESTS", label: "gemini-2.5-flash-lite", scope: "model", metric: "REQUESTS", remaining: 120, remainingFraction: 0.5, resetAt: reset },
      ]),
      snapshot("codex-1", now, [{ key: "rate_limit.secondary_window", label: "Weekly", scope: "window", usedPercent: 0, window: { seconds: 604_800 } }]),
    ],
  });
  const reports = await source(server).poll();
  const kimi = byAccount(reports, "kimi-1");
  assert.deepEqual(byId(kimi, "kimi-code:a").amount, { used: 25, limit: 100, remainingFraction: 0.75, usedFraction: 0.25 });
  assert.deepEqual(byId(kimi, "kimi-code:b").amount, { remaining: 75, limit: 100, remainingFraction: 0.75, usedFraction: 0.25 });
  assert.equal(byId(kimi, "kimi-code:c").amount.used, 0);
  assert.equal(byId(kimi, "kimi-code:d"), undefined);
  const gemini = byAccount(reports, "gemini-1");
  const exhausted = byId(gemini, "google-gemini-cli:gemini-2-5-pro:requests");
  assert.deepEqual(exhausted.amount, { remainingFraction: 0, usedFraction: 1 });
  // Gemini names no window length: the bucket keeps its reset but gets no window.
  assert.deepEqual(exhausted.window, { resetsAt: Date.parse(reset) });
  assert.equal(byId(gemini, "google-gemini-cli:gemini-2-5-flash:requests"), undefined);
  assert.deepEqual(byId(gemini, "google-gemini-cli:gemini-2-5-flash-lite:requests").amount, {
    remainingFraction: 0.5,
    usedFraction: 0.5,
    remaining: 120,
    unit: "requests",
  });
  assert.equal(byId(byAccount(reports, "codex-1"), "openai-codex:secondary").amount.remainingFraction, 1);
});

test("money comes from cents with an explicit currency, never from Claude's unscaled credits", async () => {
  const now = Date.now();
  const server = fakeKeeper({
    identities: [credential("xai-1", "xai"), credential("claude-1", "claude"), credential("claude-2", "claude")],
    items: [
      snapshot("xai-1", now, [
        {
          key: "billing.weekly",
          label: "Weekly",
          scope: "billing",
          metric: "weekly",
          usedPercent: 25,
          window: { seconds: 604_800 },
          window_usage_tokens: 1_000_000,
          window_usage_cost: 12.5,
          usageBreakdown: [{ product: "Grok CLI", usedPercent: 50 }],
        },
        { key: "billing.monthly", label: "Monthly Spend", scope: "billing", metric: "usd_cents", used: 1250, limit: 5000, remaining: 3750, usedPercent: 25, window: { seconds: 2_592_000 } },
      ]),
      snapshot("claude-1", now, [{ key: "extra_usage", label: "Extra Usage", scope: "extra_usage", used: 1234, limit: 5000, usedPercent: 25, allowed: true }]),
      snapshot("claude-2", now, [
        { key: "five_hour", label: "5h", scope: "window", usedPercent: 50, window: { seconds: 18_000 } },
        { key: "extra_usage", label: "Extra Usage", scope: "extra_usage", used: 0, limit: 0, allowed: false },
      ]),
    ],
  });
  const reports = await source(server).poll();
  const xai = byAccount(reports, "xai-1");
  const monthly = byId(xai, "xai:monthly");
  assert.equal(monthly.window.id, "monthly");
  assert.deepEqual(monthly.amount, { used: 12.5, limit: 50, remaining: 37.5, remainingFraction: 0.75, usedFraction: 0.25, unit: "usd", currency: "USD" });
  const weekly = byId(xai, "xai:weekly");
  assert.deepEqual(weekly.usage, { tokens: 1_000_000, cost: 12.5, currency: "USD" });
  assert.deepEqual(weekly.breakdown, [{ label: "Grok CLI", usedFraction: 0.5 }]);
  const extra = byId(byAccount(reports, "claude-1"), "anthropic:extra");
  assert.deepEqual(extra.amount, { remainingFraction: 0.75, usedFraction: 0.25 });
  assert.deepEqual(extra.window, {});
  assert.equal(byId(byAccount(reports, "claude-2"), "anthropic:extra"), undefined);
});

test("only window totals that measure the same meter are estimate-eligible", async () => {
  const now = Date.now();
  const totals = { window_usage_tokens: 2_000_000, window_usage_cost: 4 };
  const server = fakeKeeper({
    identities: [credential("claude-1", "claude"), credential("codex-1", "codex"), credential("ag-1", "antigravity")],
    items: [
      snapshot("claude-1", now, [
        { key: "five_hour", label: "5h", scope: "window", usedPercent: 50, window: { seconds: 18_000 }, ...totals },
        // Keeper copies the credential's total into every window-scoped row.
        { key: "seven_day_oauth_apps", label: "7d OAuth Apps", scope: "window", usedPercent: 10, window: { seconds: 604_800 }, ...totals },
      ]),
      snapshot("codex-1", now, [
        { key: "code_review_rate_limit.primary_window", label: "Code Review 5h", scope: "code_review", usedPercent: 50, window: { seconds: 18_000 }, window_usage_tokens: 1000, window_usage_cost: 0.5 },
      ]),
      snapshot("ag-1", now, [
        {
          key: "bucket.antigravity-gemini-models.gemini-5h",
          label: "5h",
          scope: "quota_group",
          metric: "5h",
          groupKey: "antigravity-gemini-models",
          groupLabel: "Gemini Models",
          remainingFraction: 0.5,
          window: { seconds: 18_000 },
          ...totals,
        },
      ]),
    ],
  });
  const reports = await source(server).poll();
  const claude = byAccount(reports, "claude-1");
  const fiveHour = byId(claude, "anthropic:5h");
  assert.equal(fiveHour.displayLabel, undefined);
  assert.deepEqual(fiveHour.usage, { tokens: 2_000_000, cost: 4, currency: "USD" });
  assert.equal(fiveHour.estimateEligible, true);
  const oauthApps = byId(claude, "anthropic:7d:oauth-apps");
  assert.equal(oauthApps.displayLabel, "OAuth apps");
  assert.equal(oauthApps.usage, undefined);
  assert.equal(oauthApps.estimateEligible, undefined);
  const review = byId(byAccount(reports, "codex-1"), "openai-codex:code-review:primary");
  assert.equal(review.displayLabel, "Code review");
  assert.equal(review.estimateEligible, true);
  const group = byId(byAccount(reports, "ag-1"), "google-antigravity:gemini-models:gemini-5h");
  assert.equal(group.displayLabel, "Gemini Models");
  assert.equal(group.estimateEligible, true);
});

test("an expired password session is renewed once per poll, never in a loop", async () => {
  const server = fakeKeeper({ identities: [credential("codex-1", "codex")] });
  const keeper = source(server);
  await keeper.poll();
  assert.equal(server.logins, 1);
  server.sessions.clear();
  await keeper.poll();
  assert.equal(server.logins, 2);
  server.rejectSessions = true;
  await assert.rejects(keeper.poll(), (error) => {
    assert.match(error.message, /HTTP 401/);
    assert.ok(!error.message.includes(PASSWORD));
    return true;
  });
  assert.equal(server.logins, 3);
});

test("a session token is sent as the bare cookie value and never reaches reports or errors", async () => {
  const server = fakeKeeper({
    identities: [credential("codex-1", "codex")],
    items: [{
      ...snapshot("codex-1", Date.now(), [{ key: "rate_limit.primary_window", label: "5h", scope: "window", usedPercent: 25, window: { seconds: 18_000 } }]),
      file_name: "codex-1.json",
      upstream_responses: [{ status_code: 200, body: "{\"access_token\":\"sk-upstream-secret\"}" }],
    }],
  });
  server.sessions.add("manual-token");
  const keeper = source(server, { passwordEnv: undefined, sessionCookieEnv: "KEEPER_SESSION" });
  const reports = await keeper.poll();
  assert.equal(reports[0].limits.length, 1);
  assert.doesNotMatch(JSON.stringify(reports), /manual-token|sk-upstream-secret|codex-1\.json/);
  server.sessions.clear();
  await assert.rejects(keeper.poll(), (error) => {
    assert.match(error.message, /session token \(HTTP 401\)/);
    assert.ok(!error.message.includes("manual-token"));
    return true;
  });
  assert.equal(server.logins, 0);
});

test("allowed and reached flags do not invent a missing percentage", async () => {
  const server = fakeKeeper({
    identities: [credential("flags", "codex")],
    items: [snapshot("flags", Date.now(), [{ key: "rate_limit.primary_window", allowed: false, limitReached: true }])],
  });
  const [report] = await source(server).poll();
  assert.equal(report.limits[0].allowed, false);
  assert.equal(report.limits[0].limitReached, true);
  assert.equal(report.limits[0].amount.remainingFraction, undefined);
});

test("cached Claude grants preserve scoped resets and exclude expired grants from the available count", async () => {
  const item = snapshot("grants", Date.now(), [{ key: "seven_day", usedPercent: 25 }]);
  item.quota.claudeResetGrants = { eligible: true, nextGrantId: "fable", grants: [
    { id: "fable", resetsLeft: 2, endsAt: new Date(Date.now() + DAY).toISOString(), clears: ["seven_day_overage_included"], usableNow: true },
    { id: "expired", resetsLeft: 1, endsAt: new Date(Date.now() - DAY).toISOString(), clears: ["seven_day"], usableNow: false },
  ] };
  const [report] = await source(fakeKeeper({ identities: [credential("grants", "claude")], items: [item] })).poll();
  assert.equal(report.resetCredits.availableCount, 2);
  assert.deepEqual(report.resetCredits.credits[0].clears, ["anthropic:7d:fable"]);
  assert.equal(report.resetCredits.credits[1].status, "expired");
});
