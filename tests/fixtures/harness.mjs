// Replay harness for omp/extensions/usage-remaining.js: a fake clock with timers, a fake `omp usage --json`
// whose calls the test answers (or that answers itself), and omp sessions that share one cache file.
import * as nodeFs from "node:fs";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createUsageRemaining } from "../../omp/extensions/usage-remaining.js";

export const MINUTE = 60_000;
export const HOUR = 3_600_000;
export const DAY = 86_400_000;
export const T0 = Date.UTC(2026, 10, 23, 12, 0, 0);

// Lets every pending promise chain, timer callback and fake reply settle.
export async function flush(rounds = 20) {
  for (let i = 0; i < rounds; i++) await new Promise((resolve) => setImmediate(resolve));
}

// A clock that only moves when `advance` moves it, firing the timers due on the way in order.
export function createClock(start = T0) {
  let now = start;
  let seq = 0;
  const timers = new Set();
  const add = (fn, ms, every) => {
    const timer = { at: now + Math.max(0, ms), fn, every, seq: seq++ };
    timers.add(timer);
    return timer;
  };
  return {
    now: () => now,
    timers,
    setTimeout: (fn, ms) => add(fn, ms),
    setInterval: (fn, ms) => add(fn, ms, ms),
    clearTimer: (timer) => timers.delete(timer),
    async advance(ms) {
      const end = now + ms;
      for (;;) {
        let next;
        for (const timer of timers) {
          if (timer.at <= end && (!next || timer.at < next.at || (timer.at === next.at && timer.seq < next.seq))) next = timer;
        }
        if (!next) break;
        now = next.at;
        if (next.every) next.at += next.every;
        else timers.delete(next);
        next.fn();
        await flush();
      }
      now = end;
      await flush();
    },
  };
}

// `omp usage --json`: each call is recorded with the clock's time; the test answers it with `reply(usage)` or
// `fail()`, or sets `auto(call)` to answer every call as it comes.
export function createOmp(clock) {
  const omp = {
    calls: [],
    auto: null,
    execFile(_file, args, _options, callback) {
      const call = {
        args,
        startedAt: clock.now(),
        reply: (usage) => callback(null, JSON.stringify(usage), ""),
        fail: () => callback(new Error("omp usage failed"), "", ""),
      };
      omp.calls.push(call);
      if (omp.auto) queueMicrotask(() => omp.auto(call));
    },
  };
  return omp;
}

// A temporary directory holding the cache file; removed after the test.
export async function cacheDir(t) {
  const dir = await mkdtemp(join(tmpdir(), "omp-usage-harness-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return { dir, file: join(dir, "usage-remaining.json"), list: () => readdir(dir) };
}

// The cache file as written.
export function readRawCache(file) {
  return JSON.parse(nodeFs.readFileSync(file, "utf8"));
}

// A compact model entry made whole against its provider's entry, as the plugin reads it (see data.luau's
// `whole_entry`): `windows`, `resets` and `details` list the provider's items by index (from 0) beside their own,
// all of the provider's when left out; the line is `text`, else the provider's (windows left out), else the
// provider's label and the windows' texts. Whole entries come back as they are; null when it doesn't resolve.
export function wholeEntry(entry, base) {
  if (!entry || typeof entry.line === "string") return entry;
  if (!base || typeof base.line !== "string") return null;
  const pick = (own, from = []) => (own === undefined ? from : own.map((item) => (typeof item === "number" ? from[item] : item)));
  const windows = pick(entry.windows, base.windows);
  const line = typeof entry.text === "string" ? entry.text
    : entry.windows === undefined ? base.line
    : windows.length ? `${base.label} ${windows.map((w) => w.text).join(" · ")}` : "";
  const whole = { line, resets: pick(entry.resets, base.resets), provider: entry.provider, details: pick(entry.details, base.details), windows };
  if (entry.observedAt !== undefined) whole.observedAt = entry.observedAt;
  for (const list of [whole.windows, whole.resets, whole.details]) {
    if (!list.every((item) => item && typeof item === "object")) return null;
  }
  return whole;
}

// A decoded cache with every model entry made whole (see wholeEntry).
export function wholeCache(doc) {
  if (doc.models) {
    for (const [key, entry] of Object.entries(doc.models)) doc.models[key] = wholeEntry(entry, doc.providers?.[entry?.provider]);
  }
  return doc;
}

export function readCache(file) {
  return wholeCache(readRawCache(file));
}

// One omp session running the extension: `models` available (the first active), `sources` the configured
// CPA/Keeper sources (null for none), `fs` the file system the cache is written through.
export function createSession({ clock, omp, file, models, sources = null, fs = nodeFs }) {
  const extension = createUsageRemaining({
    execFile: omp.execFile,
    now: clock.now,
    fs,
    linesFile: file,
    loadSources: () => sources,
    sleep: async () => {},
    setTimeout: clock.setTimeout,
  });
  const handlers = {};
  const statuses = [];
  // what the extension wrote to omp's log
  const logs = [];
  let current = models[0];
  const ctx = {
    models: { current: () => current, list: async () => models },
    ui: { setStatus: (_key, value) => statuses.push(value), notify() {} },
    setInterval: clock.setInterval,
    setTimeout: clock.setTimeout,
    clearTimer: clock.clearTimer,
  };
  extension({ on: (event, callback) => { handlers[event] = callback; }, logger: { warn: (message) => logs.push(message) } });
  return {
    statuses,
    logs,
    start: () => handlers.session_start({}, ctx),
    turnEnd: () => handlers.turn_end({}, ctx),
    use: (model) => { current = model; },
    // Switches to `model` and has the session notice at once (as after an auto-retry fallback), the clock unmoved.
    switchTo: (model) => {
      current = model;
      handlers.retry_fallback_applied({}, ctx);
    },
  };
}

export const OPUS = { provider: "anthropic", id: "claude-opus-5-5", name: "Opus 5.5" };
export const SONNET = { provider: "anthropic", id: "claude-sonnet-5", name: "Sonnet 5" };
export const CODEX = { provider: "openai-codex", id: "gpt-5.6-sol", name: "GPT-5.6 Sol" };

// One of omp's limits: `remaining` fraction left of window `windowId` (`durationMs` long), resetting at
// `resetsAt` when given.
export function limit(provider, windowId, durationMs, remaining, resetsAt) {
  return {
    id: `${provider}:${windowId}`,
    scope: { provider, windowId, shared: true },
    window: { id: windowId, durationMs, ...(resetsAt !== undefined ? { resetsAt } : {}) },
    amount: { remainingFraction: remaining, usedFraction: 1 - remaining, unit: "percent" },
  };
}

// `omp usage --json` with one Claude account: 5h and 7d windows with `five` and `seven` left, measured at `at`.
export function claudeUsage(at, five, seven) {
  return {
    reports: [{
      provider: "anthropic",
      metadata: { email: "solo@example.com" },
      limits: [limit("anthropic", "5h", 5 * HOUR, five, at + 2 * HOUR), limit("anthropic", "7d", 7 * DAY, seven, at + 3 * DAY)],
    }],
  };
}

// The percents a line shows, in order.
export const percents = (line) => Array.from(line.matchAll(/(<?\d+)% left/g), (m) => m[1]);
