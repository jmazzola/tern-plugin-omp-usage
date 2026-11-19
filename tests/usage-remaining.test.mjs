import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";

const run = promisify(execFile);
const extensionUrl = new URL("../omp/extensions/usage-remaining.js", import.meta.url).href;
const percentages = (line) => Array.from(line.matchAll(/(\d+(?:\.\d+)?)%/g), (match) => Number(match[1])).sort((a, b) => a - b);

test("CPA Spark quota applies to the Spark model, not an ordinary model or an unresolvable proxy alias", async (t) => {
  const home = await mkdtemp(join(tmpdir(), "omp-quota-scope-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const window = (used) => ({ used_percent: used, limit_window_seconds: 18000, reset_after_seconds: 7200 });
  const quota = {
    rate_limit: { primary_window: window(25) },
    additional_rate_limits: [{
      limit_name: "GPT-5.3-Codex-Spark",
      metered_feature: "codex_bengalfox",
      rate_limit: { primary_window: window(40) },
    }],
  };
  const server = createServer((req, res) => {
    res.setHeader("Content-Type", "application/json");
    if (req.headers.authorization !== "Bearer scope-test-key") {
      res.writeHead(401).end("{}");
    } else if (req.method === "GET" && req.url.startsWith("/proxy/v8/management/credentials?")) {
      res.end(JSON.stringify({ files: [{ auth_index: "scope-account", provider: "codex" }], total: 1, has_more: false }));
    } else if (req.method === "POST" && req.url === "/proxy/v8/management/requests/api-call") {
      res.end(JSON.stringify({ status_code: 200, header: {}, body: JSON.stringify(quota) }));
    } else {
      res.writeHead(404).end("{}");
    }
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve());
    server.closeAllConnections();
  }));
  const config = join(home, ".omp", "agent", "usage-sources.json");
  await mkdir(join(home, ".omp", "agent"), { recursive: true });
  await writeFile(config, JSON.stringify({
    sources: [{ id: "scopes", type: "cpa", baseUrl: `http://127.0.0.1:${server.address().port}/proxy`, managementKeyEnv: "CPA_SCOPE_TEST_KEY" }],
    modelMappings: [{ provider: "proxy", source: "scopes", quotaProvider: "codex" }],
  }));

  // The child isolates HOME and builtin patching. Only native OAuth reads are
  // suppressed; the CPA adapter still crosses a real local HTTP boundary.
  const script = `
    import childProcess from 'node:child_process';
    import { readFileSync } from 'node:fs';
    import { syncBuiltinESMExports } from 'node:module';
    import { join } from 'node:path';
    childProcess.execFile = (_file, _args, _options, callback) => {
      queueMicrotask(() => callback(null, '{"reports":[]}', ''));
    };
    syncBuiltinESMExports();
    const { default: extension } = await import(process.env.USAGE_EXTENSION_URL);
    const handlers = {}, statuses = [];
    const models = [
      { provider: 'proxy', id: 'gpt-5.3-codex-spark', name: 'Spark model' },
      { provider: 'proxy', id: 'gpt-5.3-codex', name: 'Base model' },
      { provider: 'proxy', id: 'local-alias', name: 'Alias model' },
    ];
    const ctx = {
      models: { current: () => models[0], list: async () => models },
      ui: { setStatus: (_key, value) => statuses.push(value), notify() {} },
      setInterval() {},
    };
    extension({ on: (event, callback) => { handlers[event] = callback; } });
    await handlers.session_start({}, ctx);
    const cache = JSON.parse(readFileSync(join(process.env.HOME, '.omp', 'cache', 'usage-remaining.json'), 'utf8'));
    console.log(JSON.stringify({ cache, status: statuses.at(-1) }));
  `;
  const { stdout } = await run(process.execPath, ["--input-type=module", "-e", script], {
    env: { ...process.env, HOME: home, USERPROFILE: home, OMP_USAGE_SOURCES_FILE: config, CPA_SCOPE_TEST_KEY: "scope-test-key", USAGE_EXTENSION_URL: extensionUrl },
    timeout: 15000,
  });
  const { cache, status } = JSON.parse(stdout);
  assert.deepEqual(percentages(cache.models["Spark model"].line), [60, 75]);
  assert.deepEqual(percentages(status), [60, 75]);
  assert.deepEqual(percentages(cache.models["Base model"].line), [75]);
  assert.deepEqual(percentages(cache.models["Alias model"].line), [75]);
  assert.deepEqual(percentages(cache.providers["cpa:scopes:openai-codex"].line), [60, 75]);
});

// Runs the extension in a child against `omp usage` JSON `usage` with `models` available (the first active), in
// an isolated HOME, and returns the cache it wrote.
async function nativeCache(t, usage, models) {
  const home = await mkdtemp(join(tmpdir(), "omp-native-"));
  t.after(() => rm(home, { recursive: true, force: true }));
  const script = `
    import childProcess from 'node:child_process';
    import { readFileSync } from 'node:fs';
    import { syncBuiltinESMExports } from 'node:module';
    import { join } from 'node:path';
    childProcess.execFile = (_file, _args, _options, callback) => {
      queueMicrotask(() => callback(null, process.env.USAGE_JSON, ''));
    };
    syncBuiltinESMExports();
    const { default: extension } = await import(process.env.USAGE_EXTENSION_URL);
    const handlers = {};
    const models = JSON.parse(process.env.USAGE_MODELS);
    const ctx = {
      models: { current: () => models[0], list: async () => models },
      ui: { setStatus() {}, notify() {} },
      setInterval() {},
    };
    extension({ on: (event, callback) => { handlers[event] = callback; } });
    await handlers.session_start({}, ctx);
    console.log(readFileSync(join(process.env.HOME, '.omp', 'cache', 'usage-remaining.json'), 'utf8'));
  `;
  const { stdout } = await run(process.execPath, ["--input-type=module", "-e", script], {
    env: {
      ...process.env, HOME: home, USERPROFILE: home, OMP_USAGE_SOURCES_FILE: join(home, "none.json"),
      USAGE_JSON: JSON.stringify(usage), USAGE_MODELS: JSON.stringify(models), USAGE_EXTENSION_URL: extensionUrl,
    },
    timeout: 15000,
  });
  return JSON.parse(stdout);
}

test("omp's own reports name each account's plan for the card and for combining by plan", async (t) => {
  const weekly = (provider) => ({
    id: `${provider}:7d`,
    scope: { provider, windowId: "7d", shared: true },
    window: { id: "7d", durationMs: 604800000, resetsAt: Date.now() + 86400000 },
    amount: { usedFraction: 0.25, remainingFraction: 0.75, unit: "percent" },
  });
  const usage = {
    reports: [
      { provider: "anthropic", metadata: { email: "solo@example.com", subscriptionPlan: "Max 20x" }, limits: [weekly("anthropic")] },
      { provider: "openai-codex", metadata: { email: "alice@example.com", planType: "pro" }, limits: [weekly("openai-codex")] },
      { provider: "openai-codex", metadata: { email: "bob@example.com", planType: "team_business" }, limits: [weekly("openai-codex")] },
      { provider: "kiro", metadata: { planType: "Kiro Pro" }, limits: [weekly("kiro")] },
    ],
  };
  const cache = await nativeCache(t, usage, [{ provider: "anthropic", id: "claude-opus-5-5", name: "Opus 5.5" }]);
  const plans = (details) => details.filter((d) => d.kind === "plan").map(({ account, valueText }) => ({ account, valueText }));
  // One account: the plan names the provider's heading, so it has no account. omp's `Max 20x` is sold as Ultra.
  assert.deepEqual(plans(cache.providers.anthropic.details), [{ account: undefined, valueText: "Ultra" }]);
  assert.deepEqual(plans(cache.models["Opus 5.5"].details), [{ account: undefined, valueText: "Ultra" }]);
  // Several: each account's plan under the name its windows carry; Codex's `pro` reads as the Pro 200 it's sold
  // as, and an unknown plan code reads as words.
  assert.deepEqual(cache.providers["openai-codex"].accounts, ["alice", "bob"]);
  assert.deepEqual(plans(cache.providers["openai-codex"].details), [
    { account: "alice", valueText: "Pro 200" },
    { account: "bob", valueText: "Team Business" },
  ]);
  // A plan named after its provider drops the provider's name.
  assert.deepEqual(plans(cache.providers.kiro.details), [{ account: undefined, valueText: "Pro" }]);
});

test("a Fable or Mythos model leads with the Fable weekly window it draws on", async (t) => {
  const limit = (id, scope, left) => ({
    id,
    scope: { provider: "anthropic", windowId: "7d", ...scope },
    window: { id: "7d", durationMs: 604800000, resetsAt: Date.now() + 86400000 },
    amount: { remainingFraction: left, usedFraction: 1 - left, unit: "percent" },
  });
  const fiveHour = {
    id: "anthropic:5h",
    scope: { provider: "anthropic", windowId: "5h", shared: true },
    window: { id: "5h", durationMs: 18000000, resetsAt: Date.now() + 3600000 },
    amount: { remainingFraction: 0.9, usedFraction: 0.1, unit: "percent" },
  };
  const usage = {
    reports: [{
      provider: "anthropic",
      metadata: { email: "solo@example.com" },
      limits: [fiveHour, limit("anthropic:7d", { shared: true }, 0.54), limit("anthropic:7d:fable", { tier: "fable" }, 0.14)],
    }],
  };
  const cache = await nativeCache(t, usage, [
    { provider: "anthropic", id: "claude-opus-5-5", name: "Opus 5.5" },
    { provider: "anthropic", id: "claude-fable-5-2", name: "Fable 5.2" },
    { provider: "anthropic", id: "claude-mythos-5-2", name: "Mythos 5.2" },
  ]);
  const order = (line) => Array.from(line.matchAll(/(?:^Claude |· )((?:Fable )?\w+) /g), (m) => m[1]);
  assert.deepEqual(order(cache.models["Opus 5.5"].line), ["5h", "7d", "Fable 7d"]);
  assert.deepEqual(order(cache.models["Fable 5.2"].line), ["Fable 7d", "5h", "7d"]);
  assert.deepEqual(order(cache.models["Mythos 5.2"].line), ["Fable 7d", "5h", "7d"]);
  // The provider's own line names no model, so it keeps the usual order.
  assert.deepEqual(order(cache.providers.anthropic.line), ["5h", "7d", "Fable 7d"]);
});
