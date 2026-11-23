// The cache's size: model entries written compact against their provider's entry, read back whole, and the
// file kept under what the plugin reads (tests/fixtures/many-accounts.mjs).
import assert from "node:assert/strict";
import * as nodeFs from "node:fs";
import { test } from "node:test";
import {
  HOUR, MINUTE, OPUS, T0, cacheDir, claudeUsage, createClock, createOmp, createSession, limit, readCache, readRawCache,
} from "./fixtures/harness.mjs";
import { manyAccountsUsage, manyAliases } from "./fixtures/many-accounts.mjs";

test("32 accounts and 220 models make a cache under 1 MiB that reads back as each model's own line", async (t) => {
  const { file } = await cacheDir(t);
  const usage = manyAccountsUsage(T0, 32);
  const models = manyAliases(220);
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply(usage);
  const session = createSession({ clock, omp, file, models });
  await session.start();
  const bytes = nodeFs.statSync(file).size;
  // 15.5 MB with every entry whole
  assert.ok(bytes < 1024 * 1024 && bytes < 900_000, `${bytes} bytes`);
  assert.deepEqual(session.logs, []);
  const cache = readCache(file);
  assert.equal(Object.keys(cache.models).length, 220);
  for (const [name, entry] of Object.entries(cache.models)) assert.equal(typeof entry?.line, "string", name);
  // Each reads as the session draws it: a Fable model leads with Fable 7d, a Spark model has Spark 5h, others
  // read as their provider.
  const fable = models.find((m) => m.id.includes("fable"));
  const spark = models.find((m) => m.id.includes("spark"));
  const sol = models.find((m) => m.id.includes("sol"));
  const opus = models.find((m) => m.id.includes("opus"));
  for (const model of [spark, sol, opus, fable]) {
    session.switchTo(model);
    assert.equal(cache.models[model.name].line, session.statuses.at(-1), model.name);
  }
  assert.match(cache.models[fable.name].line, /^Claude seat-00 Fable 7d /);
  assert.match(cache.models[spark.name].line, /seat-00 Spark 5h /);
  assert.equal(cache.models[sol.name].line, cache.providers["openai-codex"].line);
  assert.deepEqual(cache.models[opus.name], { ...cache.models[opus.name], line: cache.providers.anthropic.line, details: cache.providers.anthropic.details });
});

test("plugin copies that read only whole entries find none they could misread", async (t) => {
  const { file } = await cacheDir(t);
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply(manyAccountsUsage(T0, 2));
  await createSession({ clock, omp, file, models: [...manyAliases(12), { provider: "zai", id: "glm-5", name: "GLM-5" }] }).start();
  const raw = readRawCache(file);
  assert.equal(raw.schema, 2);
  for (const [name, entry] of Object.entries(raw.models)) {
    if (typeof entry.line !== "string") {
      // compact: no `line`, so 0.7.10 passes over it and shows omp's status
      assert.ok(Object.hasOwn(raw.providers, entry.provider), name);
      continue;
    }
    // whole: everything 0.7.10 reads is there
    assert.ok(Array.isArray(entry.resets) && Array.isArray(entry.details) && Array.isArray(entry.windows), name);
  }
  // A model without a provider entry (no report) stays whole; one with a provider entry is compact.
  assert.equal(raw.models["GLM-5"].line, "");
  assert.equal(raw.models["opus-5-5 alias 1"].line, undefined);
  for (const provider of Object.values(raw.providers)) assert.equal(typeof provider.line, "string");
});

test("a kept entry from the file reads the same after it is written beside another session's provider entry", async (t) => {
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply(claudeUsage(T0, 0.5, 0.5));
  const { file } = await cacheDir(t);
  // Another session's file: its provider entry is older than this session's fetch, but a model only it lists
  // (Fable 5) was observed later; that entry lists its provider entry's windows by index.
  const window = (label, key, remaining, text) => ({ provider: "anthropic", key, label, remaining, windowMs: 18_000_000, text });
  const windows = [window("5h", "5h", 0.2, "5h ██░░░░░░ 20% left"), window("Fable 7d", "7d", 0.7, "Fable 7d ██████░░ 70% left")];
  nodeFs.writeFileSync(file, JSON.stringify({
    schema: 2,
    generatedAt: T0 - MINUTE,
    fetchedAt: T0 - 20 * MINUTE,
    models: { "Fable 5": { provider: "anthropic", windows: [1, 0], observedAt: T0 + 1000 } },
    providers: {
      anthropic: {
        label: "Claude", line: "Claude 5h ██░░░░░░ 20% left · Fable 7d ██████░░ 70% left", resets: [], details: [],
        baseProvider: "anthropic", windows, observedAt: T0 - 20 * MINUTE,
      },
    },
  }));
  await createSession({ clock, omp, file, models: [OPUS] }).start();
  const cache = readCache(file);
  assert.match(cache.providers.anthropic.line, /50% left/);
  assert.equal(cache.models["Fable 5"].line, "Claude Fable 7d ██████░░ 70% left · 5h ██░░░░░░ 20% left");
  assert.deepEqual(cache.models["Fable 5"].windows, [windows[1], windows[0]]);
  assert.equal(cache.models["Fable 5"].observedAt, T0 + 1000);
  // A compact entry whose provider entry is gone, or lists an index it lacks, is dropped rather than misread.
  nodeFs.writeFileSync(file, JSON.stringify({
    schema: 2,
    generatedAt: T0,
    fetchedAt: T0,
    models: { "Fable 5": { provider: "anthropic", windows: [7], observedAt: T0 + 2 * MINUTE }, "Ghost": { provider: "ghost", observedAt: T0 + 2 * MINUTE } },
    providers: readRawCache(file).providers,
  }));
  await clock.advance(2 * MINUTE);
  const after = readRawCache(file);
  assert.equal(after.models["Fable 5"], undefined);
  assert.equal(after.models.Ghost, undefined);
});

test("a file over 900 KB is written without details, then without windows, logged once", async (t) => {
  // Every model a Spark model with 32 seats: each has a window and details its provider entry doesn't.
  const sparks = (count) => Array.from({ length: count }, (_, i) => ({ provider: "openai-codex", id: `gpt-5.3-codex-spark-${i}`, name: `Spark ${i}` }));
  const usage = manyAccountsUsage(T0, 32);
  for (const [count, dropped] of [[60, "details"], [140, "details and windows"]]) {
    const { file } = await cacheDir(t);
    const clock = createClock();
    const omp = createOmp(clock);
    omp.auto = (call) => call.reply(usage);
    const session = createSession({ clock, omp, file, models: sparks(count) });
    await session.start();
    // a later write that drops the same says nothing more
    if (count === 60) {
      await clock.advance(MINUTE);
      assert.equal(readRawCache(file).generatedAt, T0 + MINUTE);
    }
    const bytes = nodeFs.statSync(file).size;
    assert.ok(bytes <= 900_000, `${count}: ${bytes} bytes`);
    assert.equal(session.logs.length, 1);
    assert.match(session.logs[0], new RegExp(`written without ${dropped} \\(\\d+ bytes\\)$`));
    const cache = readCache(file);
    const entry = cache.models["Spark 0"];
    assert.deepEqual(entry.details, []);
    assert.deepEqual(cache.providers["openai-codex"].details, []);
    assert.match(entry.line, /seat-00 Spark 5h /);
    assert.equal(entry.windows.length, dropped === "details" ? 96 : 0);
  }
});

test("a single account's cache reads back whole and shrinks", async (t) => {
  const { file } = await cacheDir(t);
  const clock = createClock();
  const omp = createOmp(clock);
  omp.auto = (call) => call.reply({
    reports: [
      claudeUsage(T0, 0.6, 0.4).reports[0],
      { provider: "openai-codex", metadata: {}, limits: [limit("openai-codex", "5h", 5 * HOUR, 0.9, T0 + HOUR)] },
    ],
  });
  const models = manyAliases(40);
  await createSession({ clock, omp, file, models }).start();
  const raw = readRawCache(file);
  const cache = readCache(file);
  const whole = Buffer.byteLength(JSON.stringify(cache));
  assert.ok(nodeFs.statSync(file).size * 2 < whole, `${nodeFs.statSync(file).size} of ${whole}`);
  assert.deepEqual(raw.models["sonnet-5 alias 4"], { provider: "anthropic", observedAt: T0 });
  assert.equal(cache.models["sonnet-5 alias 4"].line, cache.providers.anthropic.line);
});
