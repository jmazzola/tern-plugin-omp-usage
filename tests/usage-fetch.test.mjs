// Replays of how the usage extension fetches, publishes and writes the cache (tests/fixtures/harness.mjs).
import assert from "node:assert/strict";
import * as nodeFs from "node:fs";
import { test } from "node:test";
import {
  CODEX, DAY, HOUR, MINUTE, OPUS, SONNET, T0, cacheDir, claudeUsage, createClock, createOmp, createSession, flush,
  limit, percents, readCache,
} from "./fixtures/harness.mjs";

test("the first fetch's timers are running before the fetch answers", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  const { file } = await cacheDir(t);
  const session = createSession({ clock, omp, file, models: [OPUS] });
  void session.start();
  await flush();
  assert.equal(omp.calls.length, 1);
  // Both the 60 s poll and the 1 s model check are installed while `omp usage` is still running.
  assert.deepEqual([...clock.timers].map((timer) => timer.every).sort((a, b) => a - b), [1000, MINUTE]);
  omp.calls[0].reply(claudeUsage(T0, 0.5, 0.5));
  await flush();
  assert.deepEqual(percents(readCache(file).providers.anthropic.line), ["50", "50"]);
});

test("overlapping requests share one fetch, and a turn that ended during it gets one more", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  const { file } = await cacheDir(t);
  const session = createSession({ clock, omp, file, models: [OPUS, SONNET] });
  void session.start();
  await clock.advance(1000);
  for (let i = 0; i < 4; i++) void session.turnEnd();
  session.use(SONNET);
  await clock.advance(1000);
  assert.equal(omp.calls.length, 1, "one omp usage for five overlapping requests");
  omp.calls[0].reply(claudeUsage(T0, 0.6, 0.6));
  await flush();
  assert.equal(omp.calls.length, 1);
  // The turns ended after that fetch started: one more, once 20 s have passed since its start.
  await clock.advance(17_000);
  assert.equal(omp.calls.length, 1);
  await clock.advance(1000);
  assert.equal(omp.calls.length, 2);
  assert.equal(omp.calls[1].startedAt, T0 + 20_000);
});

test("a burst of turn ends starts at most two fetches in 20 s, and the last turn is fetched after", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply(claudeUsage(call.startedAt, 0.8, 0.8));
  const { file } = await cacheDir(t);
  const session = createSession({ clock, omp, file, models: [OPUS] });
  await session.start();
  let lastTurn = 0;
  for (let i = 0; i < 40; i++) {
    await clock.advance(500);
    lastTurn = clock.now();
    void session.turnEnd();
    await flush();
  }
  const within = omp.calls.filter((call) => call.startedAt <= T0 + 20_000);
  assert.ok(within.length <= 2, `${within.length} fetches in the first 20 s`);
  await clock.advance(20_000);
  assert.ok(omp.calls.length <= 3, `${omp.calls.length} fetches in 40 s`);
  assert.ok(omp.calls.at(-1).startedAt >= lastTurn, "a fetch started after the last turn ended");
});

test("a fetch that started first but answered last doesn't replace newer numbers", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  const { file } = await cacheDir(t);
  const slow = createSession({ clock, omp, file, models: [OPUS] });
  const quick = createSession({ clock, omp, file, models: [OPUS] });
  void slow.start();
  await clock.advance(5000);
  void quick.start();
  await flush();
  assert.equal(omp.calls.length, 2);
  omp.calls[1].reply(claudeUsage(T0, 0.2, 0.2));
  await flush();
  await clock.advance(5000);
  omp.calls[0].reply(claudeUsage(T0, 0.9, 0.9));
  await flush();
  const cache = readCache(file);
  assert.deepEqual(percents(cache.providers.anthropic.line), ["20", "20"]);
  assert.deepEqual(percents(cache.models["Opus 5.5"].line), ["20", "20"]);
  assert.equal(cache.providers.anthropic.observedAt, T0 + 5000);
  assert.equal(cache.fetchedAt, T0 + 5000);
});

test("failed fetches keep the numbers' observation time while the heartbeat moves", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply(claudeUsage(T0, 0.7, 0.4));
  const { file } = await cacheDir(t);
  const session = createSession({ clock, omp, file, models: [OPUS] });
  await session.start();
  assert.equal(readCache(file).providers.anthropic.observedAt, T0);
  omp.auto = (call) => call.fail();
  await clock.advance(30 * MINUTE);
  assert.ok(omp.calls.length >= 30, "every minute's poll still asks");
  const cache = readCache(file);
  assert.equal(cache.schema, 2);
  assert.equal(cache.fetchedAt, T0);
  assert.equal(cache.providers.anthropic.observedAt, T0);
  assert.equal(cache.models["Opus 5.5"].observedAt, T0);
  assert.ok(cache.generatedAt >= T0 + 28 * MINUTE, "the heartbeat keeps moving");
  assert.deepEqual(percents(cache.providers.anthropic.line), ["70", "40"]);
});

test("omp's own report time is the observation time when omp answers from its cache", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  const usage = claudeUsage(T0, 0.5, 0.5);
  usage.reports[0].fetchedAt = T0 - 2 * MINUTE;
  omp.auto = (call) => call.reply(usage);
  const { file } = await cacheDir(t);
  await createSession({ clock, omp, file, models: [OPUS] }).start();
  const cache = readCache(file);
  assert.equal(cache.providers.anthropic.observedAt, T0 - 2 * MINUTE);
  assert.equal(cache.fetchedAt, T0);
});

test("a periodic fetch is skipped while another session's fetch is under 30 s old", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply(claudeUsage(call.startedAt, 0.5, 0.5));
  const { file } = await cacheDir(t);
  const first = createSession({ clock, omp, file, models: [OPUS] });
  await first.start();
  await clock.advance(1000);
  // A session without numbers of its own always fetches once.
  await createSession({ clock, omp, file, models: [OPUS] }).start();
  assert.equal(omp.calls.length, 2);
  // At 60 s the first session's poll fetches (the file's fetch is 59 s old); at 61 s the second's finds it 1 s old.
  await clock.advance(MINUTE + 1000);
  assert.equal(omp.calls.length, 3);
  assert.equal(readCache(file).fetchedAt, T0 + MINUTE);
});

test("a model switch redraws at once and fetches only when the last start is over 20 s old", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  const usage = {
    reports: [
      claudeUsage(T0, 0.5, 0.5).reports[0],
      { provider: "openai-codex", metadata: { email: "solo@example.com" }, limits: [limit("openai-codex", "5h", 5 * HOUR, 0.3, T0 + HOUR)] },
    ],
  };
  omp.auto = (call) => call.reply(usage);
  const { file } = await cacheDir(t);
  const session = createSession({ clock, omp, file, models: [OPUS, CODEX] });
  await session.start();
  assert.match(session.statuses.at(-1), /^Claude /);
  await clock.advance(4000);
  session.use(CODEX);
  await clock.advance(1000);
  assert.match(session.statuses.at(-1), /^Codex .*30% left/);
  assert.equal(omp.calls.length, 1);
  await clock.advance(30_000);
  session.use(OPUS);
  await clock.advance(1000);
  assert.match(session.statuses.at(-1), /^Claude /);
  assert.equal(omp.calls.length, 2);
});

test("a session whose own fetch never succeeded still writes its sources' numbers", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.fail();
  const { file } = await cacheDir(t);
  // Another session's numbers, already in the file.
  nodeFs.writeFileSync(file, JSON.stringify({
    schema: 2,
    generatedAt: T0 - 10_000,
    fetchedAt: T0 - 10_000,
    models: { "Opus 5.5": { line: "Claude 5h ████░░░░ 50% left", resets: [], provider: "anthropic", details: [], windows: [], observedAt: T0 - 10_000 } },
    providers: { anthropic: { label: "Claude", line: "Claude 5h ████░░░░ 50% left", resets: [], details: [], baseProvider: "anthropic", windows: [], observedAt: T0 - 10_000 } },
  }));
  const pool = "cpa:pool:openai-codex";
  const sources = {
    poll: async () => [{
      provider: pool,
      observedAt: T0 - 30_000,
      metadata: { sourceId: "pool", sourceType: "cpa", baseProvider: "openai-codex", accountId: "seat" },
      limits: [limit(pool, "5h", 5 * HOUR, 0.25, T0 + HOUR)],
    }],
    resolve: (provider) => (provider === "proxy" ? pool : provider),
  };
  const proxy = { provider: "proxy", id: "gpt-5.6-sol", name: "Proxy Sol" };
  await createSession({ clock, omp, file, models: [OPUS, proxy], sources }).start();
  const cache = readCache(file);
  assert.deepEqual(percents(cache.providers[pool].line), ["25"]);
  assert.equal(cache.providers[pool].observedAt, T0 - 30_000);
  assert.deepEqual(percents(cache.models["Proxy Sol"].line), ["25"]);
  // The other session's newer native numbers stay.
  assert.equal(cache.providers.anthropic.observedAt, T0 - 10_000);
  assert.equal(cache.models["Opus 5.5"].line, "Claude 5h ████░░░░ 50% left");
  assert.equal(cache.fetchedAt, T0 - 10_000);
});

test("a failed rename is retried once and never leaves the temporary file", async (t) => {
  for (const failures of [1, 2]) {
    const clock = createClock();
    const omp = createOmp(clock);
    omp.auto = (call) => call.reply(claudeUsage(T0, 0.5, 0.5));
    const { file, list } = await cacheDir(t);
    let renames = 0;
    const fs = {
      ...nodeFs,
      renameSync(from, to) {
        renames++;
        if (renames <= failures) throw Object.assign(new Error("EPERM: file in use"), { code: "EPERM" });
        return nodeFs.renameSync(from, to);
      },
    };
    await createSession({ clock, omp, file, models: [OPUS], fs }).start();
    assert.deepEqual((await list()).filter((name) => name.endsWith(".tmp")), [], `no temporary file after ${failures} failure(s)`);
    if (failures === 1) {
      assert.equal(renames, 2);
      assert.equal(readCache(file).schema, 2);
    } else {
      assert.equal(nodeFs.existsSync(file), false);
      // The next poll writes it.
      await clock.advance(MINUTE);
      assert.equal(readCache(file).schema, 2);
    }
  }
});

test("a window whose reset time has passed reads reset, not its old percent", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply({
    reports: [{
      provider: "anthropic",
      metadata: { email: "solo@example.com" },
      limits: [limit("anthropic", "5h", 5 * HOUR, 0.05, T0 - MINUTE), limit("anthropic", "7d", 7 * DAY, 0.4, T0 + DAY)],
    }],
  });
  const { file } = await cacheDir(t);
  await createSession({ clock, omp, file, models: [OPUS] }).start();
  const { line, windows } = readCache(file).providers.anthropic;
  assert.match(line, /^Claude 5h reset · 7d /);
  assert.doesNotMatch(line, /soon/);
  assert.deepEqual(percents(line), ["40"]);
  assert.equal(windows[0].resetsAt, T0 - MINUTE);
});

test("percents round down, and anything left under 1% reads <1%", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  const used = (windowId, durationMs, fraction) => ({
    id: `anthropic:${windowId}`,
    scope: { provider: "anthropic", windowId, shared: true },
    window: { id: windowId, durationMs },
    amount: { usedFraction: fraction, unit: "percent" },
  });
  omp.auto = (call) => call.reply({
    reports: [{
      provider: "anthropic",
      metadata: { email: "solo@example.com" },
      limits: [
        limit("anthropic", "5h", 5 * HOUR, 0.004),
        limit("anthropic", "1d", DAY, 0.996),
        limit("anthropic", "7d", 7 * DAY, 0),
        used("monthly", 30 * DAY, 0.71),
      ],
    }],
  });
  const { file } = await cacheDir(t);
  await createSession({ clock, omp, file, models: [OPUS] }).start();
  const { line, windows } = readCache(file).providers.anthropic;
  assert.deepEqual(percents(line), ["<1", "99", "0", "29"]);
  assert.deepEqual(windows.map((w) => w.remaining.toFixed(3)), ["0.004", "0.996", "0.000", "0.290"]);
});

test("providers that would share a label get distinct ones, and windows name their provider", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply({
    reports: [
      { provider: "zai", metadata: {}, limits: [limit("zai", "5h", 5 * HOUR, 0.5)] },
      { provider: "zai-coding-plan", metadata: {}, limits: [limit("zai-coding-plan", "5h", 5 * HOUR, 0.25)] },
    ],
  });
  const { file } = await cacheDir(t);
  await createSession({ clock, omp, file, models: [{ provider: "zai", id: "glm-5", name: "GLM-5" }] }).start();
  const { providers } = readCache(file);
  assert.equal(providers.zai.label, "Zai");
  assert.equal(providers["zai-coding-plan"].label, "Zai-Coding");
  assert.match(providers["zai-coding-plan"].line, /^Zai-Coding 5h /);
  assert.deepEqual(providers["zai-coding-plan"].windows.map((w) => w.provider), ["zai-coding-plan"]);
  assert.deepEqual(providers.zai.windows.map((w) => w.provider), ["zai"]);
});

test("two models with one chip name both resolve under their provider, and the bare name under neither", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply({
    reports: [
      { provider: "openai", metadata: {}, limits: [limit("openai", "5h", 5 * HOUR, 0.9)] },
      { provider: "openai-codex", metadata: {}, limits: [limit("openai-codex", "5h", 5 * HOUR, 0.1)] },
    ],
  });
  const { file } = await cacheDir(t);
  const models = [{ provider: "openai", id: "gpt-5", name: "GPT-5" }, { provider: "openai-codex", id: "gpt-5", name: "GPT-5" }];
  await createSession({ clock, omp, file, models }).start();
  const cache = readCache(file);
  assert.deepEqual(percents(cache.models["openai/GPT-5"].line), ["90"]);
  assert.deepEqual(percents(cache.models["openai-codex/GPT-5"].line), ["10"]);
  // A reader that knows only the chip name keeps omp's status instead of showing the other model's numbers.
  assert.equal(cache.models["GPT-5"], null);
});

test("a clash is keyed by the provider each line is drawn from, as its status names it", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply({
    reports: [{ provider: "openai-codex", metadata: {}, limits: [limit("openai-codex", "5h", 5 * HOUR, 0.9)] }],
  });
  const pool = "cpa:pool:openai-codex";
  const sources = {
    poll: async () => [{
      provider: pool,
      observedAt: T0,
      metadata: { sourceId: "pool", sourceType: "cpa", baseProvider: "openai-codex", accountId: "seat" },
      limits: [limit(pool, "5h", 5 * HOUR, 0.25)],
    }],
    resolve: (provider, bare) => (provider === "proxy" || bare === "gpt-5-pool" ? pool : provider),
  };
  const { file } = await cacheDir(t);
  // Native Codex, a Codex model sent to the pool, and a proxy model sent to the same pool: all read "GPT-5".
  const models = [
    { provider: "openai-codex", id: "gpt-5", name: "GPT-5" },
    { provider: "openai-codex", id: "gpt-5-pool", name: "GPT-5" },
    { provider: "proxy", id: "gpt-5", name: "GPT-5" },
  ];
  await createSession({ clock, omp, file, models, sources }).start();
  const cache = readCache(file);
  assert.equal(cache.models["GPT-5"], null);
  assert.match(cache.models["openai-codex/GPT-5"].line, /^Codex 5h .*90% left/);
  assert.match(cache.models[`${pool}/GPT-5`].line, /^Codex@pool 5h .*25% left/);
  assert.equal(cache.models["proxy/GPT-5"], undefined);
});

test("a session that lists fewer models keeps another session's clash", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply({
    reports: [{ provider: "openai-codex", metadata: {}, limits: [limit("openai-codex", "5h", 5 * HOUR, 0.9)] }],
  });
  const pool = "cpa:pool:openai-codex";
  const sources = {
    poll: async () => [{
      provider: pool,
      observedAt: clock.now(),
      metadata: { sourceId: "pool", sourceType: "cpa", baseProvider: "openai-codex", accountId: "seat" },
      limits: [limit(pool, "5h", 5 * HOUR, 0.25)],
    }],
    resolve: (provider) => (provider === "proxy" ? pool : provider),
  };
  const { file } = await cacheDir(t);
  const native = { provider: "openai-codex", id: "gpt-5", name: "GPT-5" };
  const proxy = { provider: "proxy", id: "gpt-5", name: "GPT-5" };
  // A lists both and polls the pool; B (another project's config) lists only the native one and has no sources.
  await createSession({ clock, omp, file, models: [native, proxy], sources }).start();
  await clock.advance(2 * MINUTE);
  await createSession({ clock, omp, file, models: [native] }).start();
  const cache = readCache(file);
  assert.equal(cache.models["GPT-5"], null);
  assert.match(cache.models["openai-codex/GPT-5"].line, /90% left/);
  assert.equal(cache.models["openai-codex/GPT-5"].observedAt, T0 + 2 * MINUTE);
  assert.match(cache.models[`${pool}/GPT-5`].line, /25% left/);
  assert.match(cache.providers[pool].line, /25% left/);
});

test("the cache lists each line's windows with their numbers", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply(claudeUsage(T0, 0.4567, 0.9));
  const { file } = await cacheDir(t);
  await createSession({ clock, omp, file, models: [OPUS] }).start();
  const cache = readCache(file);
  assert.equal(cache.schema, 2);
  assert.equal(cache.generatedAt, T0);
  assert.equal(cache.fetchedAt, T0);
  assert.deepEqual(cache.providers.anthropic.windows, [
    { provider: "anthropic", key: "5h", label: "5h", remaining: 0.4567, resetsAt: T0 + 2 * HOUR, windowMs: 5 * HOUR, text: "5h ████░░░░ 45% left (2h)" },
    { provider: "anthropic", key: "7d", label: "7d", remaining: 0.9, resetsAt: T0 + 3 * DAY, windowMs: 7 * DAY, text: "7d ███████░ 90% left (3d)" },
  ]);
  assert.deepEqual(cache.models["Opus 5.5"].windows, cache.providers.anthropic.windows);
  assert.equal(cache.models["Opus 5.5"].observedAt, T0);
  assert.equal(cache.providers.anthropic.line, "Claude 5h ████░░░░ 45% left (2h) · 7d ███████░ 90% left (3d)");
});
