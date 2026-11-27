// QA sweep only: realistic caches for the headless sweep, written by the real extension (omp/extensions/
// usage-remaining.js, run through tests/fixtures/harness.mjs) from fake `omp usage --json` reports and fake
// CPA/Keeper source reports, at the real time. Usage: node tests/smoke/sweep-caches.mjs KIND OUT.json [ageMin]
// KIND: single | multi | many | zai | sources | nolimits | edge | six. `ageMin` moves every observedAt (and the
// file's generatedAt/fetchedAt) back that many minutes, as an old cache would read.
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { DAY, HOUR, createClock, createOmp, createSession, limit } from "../fixtures/harness.mjs";

const MIN = 60_000;

// The chips the headless omp may show, and the models behind them.
export const MODELS = [
  { provider: "anthropic", id: "claude-opus-5-5", name: "Opus 5.5" },
  { provider: "anthropic", id: "claude-fable-5-2", name: "Fable 5.2" },
  { provider: "anthropic", id: "claude-mythos-5-2", name: "Mythos 5.2" },
  { provider: "anthropic", id: "claude-sonnet-5", name: "Sonnet 5" },
  { provider: "openai-codex", id: "gpt-6-luna", name: "GPT-6 Luna" },
  { provider: "openai-codex", id: "gpt-5.3-codex-spark", name: "GPT-5.3 Codex Spark" },
  { provider: "zai", id: "glm-5", name: "GLM-5" },
  { provider: "zai-coding-plan", id: "glm-5-coding", name: "GLM-5 Coding" },
];

const fable = (provider, r, at) => ({ ...limit(provider, "7d", 7 * DAY, r, at), id: "anthropic:7d:fable", scope: { provider, windowId: "7d", tier: "fable" } });
const spark = (provider, r, at) => ({ ...limit(provider, "5h", 5 * HOUR, r, at), id: `${provider}:5h:spark`, scope: { provider, windowId: "5h", modelId: "gpt-5.3-codex-spark", tier: "spark", shared: true } });
const credit = (clears, expiresAt, n = 1) => ({ status: "available", remainingCount: n, clears, expiresAt: new Date(expiresAt).toISOString() });

function claudeSeat(now, email, plan, r = {}) {
  return {
    provider: "anthropic",
    metadata: { email, ...(plan ? { subscriptionPlan: plan } : {}) },
    limits: [
      limit("anthropic", "5h", 5 * HOUR, r.r5 ?? 0.62, now + (r.in5 ?? 2 * HOUR)),
      limit("anthropic", "7d", 7 * DAY, r.r7 ?? 0.41, now + (r.in7 ?? 3 * DAY + 4 * HOUR)),
      fable("anthropic", r.rf ?? 0.83, now + (r.inf ?? 3 * DAY + 4 * HOUR)),
    ].filter((l) => !(r.no5 && l.window.id === "5h")),
    resetCredits: { availableCount: 2, credits: r.credits ?? [credit(["anthropic:7d"], now + (r.savedIn ?? 10 * DAY)), credit(["anthropic:7d:fable"], now + 12 * DAY)] },
  };
}

function codexSeat(now, email, plan, r = {}) {
  return {
    provider: "openai-codex",
    metadata: { email, ...(plan ? { planType: plan } : {}) },
    limits: [
      limit("openai-codex", "5h", 5 * HOUR, r.r5 ?? 0.91, now + 3 * HOUR),
      limit("openai-codex", "7d", 7 * DAY, r.r7 ?? 0.58, now + 5 * DAY),
      spark("openai-codex", r.rs ?? 0.4, now + 4 * HOUR),
    ],
    resetCredits: r.credits ? { availableCount: r.credits.length, credits: r.credits } : undefined,
  };
}

function reportsFor(kind, now) {
  switch (kind) {
    case "single":
      return { reports: [claudeSeat(now, "dev.ops@lumen.dev", "max 20x"), codexSeat(now, "dev.ops@lumen.dev", "pro")] };
    case "multi":
      return {
        reports: [
          claudeSeat(now, "alice@lumen.dev", "max 5x", { r5: 0.55, r7: 0.38, rf: 0.7 }),
          claudeSeat(now, "bob@lumen.dev", "pro", { r5: 0.2, r7: 0.09, rf: 0.5 }),
          claudeSeat(now, "carol@lumen.dev", "max 20x", { r5: 0.95, r7: 0.81, rf: 0.9 }),
          codexSeat(now, "dev@lumen.dev", "plus", { r5: 0.7, r7: 0.44 }),
          codexSeat(now, "ops@lumen.dev", "pro", { r5: 0.33, r7: 0.27 }),
        ],
      };
    case "many": {
      const plans = ["max 5x", "pro", "max 20x", "pro", "max 5x", "pro", "max 20x", "pro", "max 20x", "max 20x"];
      const names = ["dev.ops", "a.k.chen", "max-plan-2", "lee", "mo", "nadia", "omar", "pat", "quinn", "ray"];
      return {
        reports: [
          ...names.map((n, i) => claudeSeat(now, `${n}@lumen.dev`, plans[i], { r5: 0.3 + i * 0.06, r7: 0.15 + i * 0.07, rf: 0.5 + i * 0.04, no5: plans[i] === "max 20x" })),
          codexSeat(now, "dev@lumen.dev", "pro"),
          codexSeat(now, "ops@lumen.dev", "plus", { r5: 0.15, r7: 0.08 }),
        ],
      };
    }
    case "zai":
      return {
        reports: [
          claudeSeat(now, "dev.ops@lumen.dev", "max 20x"),
          { provider: "zai", metadata: { planType: "pro" }, limits: [limit("zai", "5h", 5 * HOUR, 0.72, now + HOUR), limit("zai", "monthly", 30 * DAY, 0.64, now + 12 * DAY)] },
          { provider: "zai-coding-plan", metadata: { planType: "lite" }, limits: [limit("zai-coding-plan", "5h", 5 * HOUR, 0.18, now + 4 * HOUR)] },
        ],
      };
    case "nolimits":
      return {
        reports: [
          claudeSeat(now, "dev.ops@lumen.dev", undefined),
          { provider: "kimi-code", metadata: { email: "dev.ops@lumen.dev" }, limits: [] },
        ],
      };
    case "edge":
      return {
        reports: [
          claudeSeat(now, "dev.ops@lumen.dev", "max 20x", { r5: 0.004, r7: 0, rf: 1, savedIn: 12 * HOUR }),
          codexSeat(now, "dev.ops@lumen.dev", "pro", { r5: 1, r7: 0.995, rs: 0.25, credits: [credit(["openai-codex:7d"], now + 20 * HOUR, 4)] }),
        ],
      };
    case "six":
      return { reports: [claudeSeat(now, "dev.ops@lumen.dev", "max 20x"), codexSeat(now, "dev.ops@lumen.dev", "pro"), { provider: "zai", metadata: {}, limits: [limit("zai", "5h", 5 * HOUR, 0.72, now + HOUR)] }] };
    case "sources":
      return { reports: [claudeSeat(now, "dev.ops@lumen.dev", "max 20x")] };
    case "passed":
      return { reports: [claudeSeat(now, "dev.ops@lumen.dev", "max 20x", { in5: -5 * MIN }), codexSeat(now, "dev.ops@lumen.dev", "pro")] };
    case "clash":
      return { reports: [claudeSeat(now, "dev.ops@lumen.dev", "max 20x"), codexSeat(now, "dev.ops@lumen.dev", "pro")] };
    default:
      throw new Error(`unknown cache kind ${kind}`);
  }
}

// CPA and Keeper pools, as their source clients report them (see tests/usage-fetch.test.mjs).
function sourcesFor(kind, now) {
  if (kind !== "sources") return null;
  const cpa = "cpa:proxy:openai-codex";
  const keeper = "keeper:dashboard:anthropic";
  const usage = (tokens, cost) => ({ usage: { tokens, cost, currency: "USD" }, estimateEligible: true });
  return {
    poll: async () => [
      { provider: cpa, observedAt: now - 2 * MIN, metadata: { sourceId: "proxy", sourceType: "cpa", baseProvider: "openai-codex", accountId: "seat-a", email: "seat-a@acme.io", plan: "prolite" }, limits: [limit(cpa, "5h", 5 * HOUR, 0.81, now + 2 * HOUR), limit(cpa, "7d", 7 * DAY, 0.66, now + 4 * DAY)] },
      { provider: cpa, observedAt: now - 2 * MIN, metadata: { sourceId: "proxy", sourceType: "cpa", baseProvider: "openai-codex", accountId: "seat-b", email: "seat-b@acme.io", plan: "team-business" }, limits: [limit(cpa, "5h", 5 * HOUR, 0.23, now + HOUR), limit(cpa, "7d", 7 * DAY, 0.12, now + 2 * DAY)] },
      { provider: keeper, observedAt: now - 3 * MIN, metadata: { sourceId: "dashboard", sourceType: "keeper", baseProvider: "anthropic", accountId: "alice", email: "alice@acme.io", plan: "Max 5x" }, limits: [{ ...limit(keeper, "5h", 5 * HOUR, 0.64, now + 2 * HOUR), ...usage(1_210_000, 18.4) }, { ...limit(keeper, "7d", 7 * DAY, 0.41, now + 3 * DAY), ...usage(18_600_000, 280.1) }] },
      { provider: keeper, observedAt: now - 3 * MIN, stale: true, metadata: { sourceId: "dashboard", sourceType: "keeper", baseProvider: "anthropic", accountId: "bob", email: "bob@acme.io", plan: "pro" }, limits: [] },
    ],
    resolve: (provider) => provider,
  };
}

export async function build(kind, now = Date.now(), ageMin = 0) {
  const dir = mkdtempSync(join(tmpdir(), "qa-sweep-cache-"));
  try {
    const file = join(dir, "usage-remaining.json");
    const clock = createClock(now);
    const omp = createOmp(clock);
    const usage = reportsFor(kind, now);
    omp.auto = (call) => call.reply(usage);
    // clash: a Codex model whose display name is the Claude chip's
    const models = kind === "clash" ? [...MODELS, { provider: "openai-codex", id: "gpt-opus-lookalike", name: "Opus 5.5" }] : MODELS;
    await createSession({ clock, omp, file, models, sources: sourcesFor(kind, now) }).start();
    const doc = JSON.parse(readFileSync(file, "utf8"));
    if (ageMin) {
      const delta = ageMin * MIN;
      const bump = (o) => {
        if (o && typeof o === "object") {
          for (const key of ["observedAt"]) if (typeof o[key] === "number") o[key] -= delta;
          for (const value of Object.values(o)) bump(value);
        }
      };
      bump(doc);
      if (typeof doc.fetchedAt === "number") doc.fetchedAt -= delta;
    }
    return doc;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [kind, out, age = "0"] = process.argv.slice(2);
  const doc = await build(kind, Date.now(), Number(age));
  writeFileSync(out, JSON.stringify(doc));
  console.log(JSON.stringify({ kind, bytes: JSON.stringify(doc).length, providers: Object.fromEntries(Object.entries(doc.providers).map(([k, p]) => [k, p?.line])) }));
}
