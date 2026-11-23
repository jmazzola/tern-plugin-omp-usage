// A large setup for the cache's size: `accounts` Claude seats and as many Codex seats, each with its plan, token
// usage and (Claude) saved resets, and `aliases` models spread over both providers, among them Fable and Mythos
// models (Fable 7d leads their line) and Codex Spark models (a window only they have).
import { DAY, HOUR, limit } from "./harness.mjs";

function seat(provider, i, at, limits, extra = {}) {
  return {
    provider,
    metadata: { email: `seat-${String(i).padStart(2, "0")}@team${i % 4}.example.com`, planType: "pro-20x" },
    limits: limits.map((l) => ({ ...l, usage: { tokens: 1_000_000 + i * 7919, cost: 12.5 + i, currency: "USD" }, estimateEligible: true })),
    ...extra,
  };
}

export function manyAccountsUsage(at, accounts = 32) {
  const reports = [];
  for (let i = 0; i < accounts; i++) {
    const left = (n) => ((i * 13 + n * 29) % 97) / 100;
    reports.push(seat("anthropic", i, at, [
      limit("anthropic", "5h", 5 * HOUR, left(1), at + 2 * HOUR + i * 60_000),
      limit("anthropic", "7d", 7 * DAY, left(2), at + 3 * DAY + i * 60_000),
      { ...limit("anthropic", "7d", 7 * DAY, left(3), at + 4 * DAY + i * 60_000), id: "anthropic:7d:fable", scope: { provider: "anthropic", windowId: "7d", tier: "fable" } },
    ], {
      resetCredits: {
        availableCount: 2,
        credits: [
          { status: "available", remainingCount: 1, clears: ["anthropic:7d"], expiresAt: new Date(at + 2 * DAY + i * 3_600_000).toISOString() },
          { status: "available", remainingCount: 1, clears: ["anthropic:7d:fable"], expiresAt: new Date(at + 9 * DAY + i * 3_600_000).toISOString() },
        ],
      },
    }));
  }
  for (let i = 0; i < accounts; i++) {
    const left = (n) => ((i * 17 + n * 31) % 97) / 100;
    reports.push(seat("openai-codex", i, at, [
      limit("openai-codex", "5h", 5 * HOUR, left(1), at + HOUR + i * 60_000),
      limit("openai-codex", "7d", 7 * DAY, left(2), at + 5 * DAY + i * 60_000),
      { ...limit("openai-codex", "5h", 5 * HOUR, left(3), at + 3 * HOUR + i * 60_000), id: "openai-codex:5h:spark", scope: { provider: "openai-codex", windowId: "5h", modelId: "gpt-5.3-codex-spark", tier: "spark", shared: true } },
    ]));
  }
  return { reports };
}

// `count` models: two in three Claude (every fourth of those a Fable or Mythos model), the rest Codex (every
// fifth of those a Spark model).
export function manyAliases(count = 220) {
  const models = [];
  for (let i = 0; i < count; i++) {
    if (i % 3 !== 2) {
      const family = i % 12 === 0 ? "fable-5" : i % 12 === 3 ? "mythos-5" : i % 2 ? "opus-5-5" : "sonnet-5";
      models.push({ provider: "anthropic", id: `claude-${family}-alias-${i}`, name: `${family} alias ${i}` });
    } else {
      const spark = i % 15 === 2;
      models.push({ provider: "openai-codex", id: spark ? `gpt-5.3-codex-spark-alias-${i}` : `gpt-5.6-sol-alias-${i}`, name: `${spark ? "Spark" : "Sol"} alias ${i}` });
    }
  }
  return models;
}
