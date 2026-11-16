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
