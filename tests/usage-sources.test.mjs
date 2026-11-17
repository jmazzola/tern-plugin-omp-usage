import test from "node:test";
import assert from "node:assert/strict";
import { createUsageSources } from "../omp/extensions/usage-sources/index.js";

const source = { id: "local", type: "cpa", baseUrl: "http://127.0.0.1:8317", intervalSeconds: 60, maxAgeSeconds: 120 };
const report = (observedAt, extra = {}) => ({ provider: "openai-codex", metadata: { accountId: "a" }, observedAt, limits: [{ id: "5h", window: { durationMs: 18000000 }, amount: { remainingFraction: 0.5 } }], ...extra });

test("the observation clock survives cache rereads and failed refreshes, then becomes stale", async () => {
  let clock = 1000000;
  let reads = 0;
  const sources = createUsageSources({ sources: [source] }, { now: () => clock, factories: { cpa: () => ({ poll: async () => {
    reads++;
    if (reads > 1) throw new Error("HTTP 503");
    return [report(clock)];
  } }) } });
  const [initial] = await sources.poll();
  clock += 30000;
  assert.equal((await sources.poll())[0].observedAt, initial.observedAt);
  assert.equal(reads, 1);
  clock += 40000;
  const [failed] = await sources.poll();
  assert.equal(failed.observedAt, initial.observedAt);
  assert.equal(failed.error, "HTTP 503");
  assert.equal(failed.stale, undefined);
  clock += 60000;
  assert.equal((await sources.poll())[0].stale, true);
});

test("source identities do not merge, and an explicit model mapping chooses one pool", async () => {
  const sources = createUsageSources({ sources: [source, { ...source, id: "mirror", type: "keeper" }], modelMappings: [{ provider: "proxy", model: "gpt-*", source: "mirror", quotaProvider: "codex" }] }, { factories: { cpa: () => ({ poll: async () => [report(Date.now())] }), keeper: () => ({ poll: async () => [report(Date.now())] }) } });
  const reports = await sources.poll();
  assert.deepEqual(reports.map((r) => r.provider), ["cpa:local:openai-codex", "keeper:mirror:openai-codex"]);
  assert.equal(sources.resolve("proxy", "gpt-example", reports), "keeper:mirror:openai-codex");
  assert.equal(sources.resolve("proxy", "claude-example", reports), "proxy");
});

test("a successful inventory removes deleted accounts and old source errors", async () => {
  let clock = 1000000;
  let round = 0;
  const sources = createUsageSources({ sources: [source] }, { now: () => clock, factories: { cpa: () => ({ poll: async () => {
    round++;
    if (round === 1) throw new Error("HTTP 401");
    if (round === 2) return [report(clock)];
    return [];
  } }) } });
  assert.equal((await sources.poll())[0].provider, "cpa:local:status");
  clock += 60000;
  assert.equal((await sources.poll())[0].error, undefined);
  clock += 60000;
  assert.deepEqual(await sources.poll(), []);
});

test("overlapping polls share one source lookup", async () => {
  let finish;
  let reads = 0;
  const sources = createUsageSources({ sources: [source] }, { factories: { cpa: () => ({ poll: () => { reads++; return new Promise((resolve) => { finish = resolve; }); } }) } });
  const first = sources.poll();
  const second = sources.poll();
  finish([report(Date.now())]);
  assert.deepEqual(await first, await second);
  assert.equal(reads, 1);
});

test("a rolled-over window is stale even before the age limit", async () => {
  let clock = 1000000;
  const observation = report(clock);
  observation.limits[0].window.resetsAt = clock + 10000;
  const sources = createUsageSources({ sources: [source] }, { now: () => clock, factories: { cpa: () => ({ poll: async () => [observation] }) } });
  assert.equal((await sources.poll())[0].stale, undefined);
  clock += 10001;
  assert.equal((await sources.poll())[0].stale, true);
});

test("summary-only snapshots retain their observation time and age after a failed lookup", async () => {
  let clock = 1000000;
  let round = 0;
  const sources = createUsageSources({ sources: [source] }, { now: () => clock, factories: { cpa: () => ({ poll: async () => ++round === 1
    ? [report(clock, { limits: [], summary: [{ label: "Credits", value: 12 }] })]
    : [report(undefined, { limits: [], error: "HTTP 503" })] }) } });
  const [initial] = await sources.poll();
  clock += 121000;
  const [failed] = await sources.poll();
  assert.equal(failed.summary[0].value, 12);
  assert.equal(failed.observedAt, initial.observedAt);
  assert.equal(failed.stale, true);
});
