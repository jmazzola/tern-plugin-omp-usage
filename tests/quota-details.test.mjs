import test from "node:test";
import assert from "node:assert/strict";
import { finite, timestamp, durationMs } from "../omp/extensions/usage-sources/common.js";
import { limitDetails, remainingFraction, reportNotes } from "../omp/extensions/usage-sources/details.js";

const window = (amount, usage, estimateEligible = true) => ({ amount, usage, estimateEligible });
const byKind = (rows, kind) => rows.find((row) => row.kind === kind);
const texts = (rows) => rows.map((row) => row.text);

test("missing values never become explicit zero quota or utilization", () => {
  for (const value of [null, undefined, "", " ", false, true, NaN, Infinity]) assert.equal(finite(value), undefined);
  assert.equal(finite("0"), 0);
  assert.equal(remainingFraction({}), undefined);
  assert.equal(remainingFraction({ usedFraction: 0 }), 1);
  assert.equal(remainingFraction({ remainingFraction: 0 }), 0);
  assert.equal(timestamp("2026-11-13T10:00:00Z"), 1794564000000);
  assert.equal(durationMs(5, "HOURS"), 18000000);
});

test("remaining workload estimates use matched window utilization, not observed usage as a balance", () => {
  const rows = limitDetails(window({ usedFraction: 0.25 }, { tokens: 1000, cost: 2, currency: "USD" }));
  const used = byKind(rows, "tokens-used");
  assert.equal(used.valueText, "1.00K tokens");
  const tokensLeft = byKind(rows, "tokens-estimate");
  assert.equal(tokensLeft.valueText, "3.00K tokens");
  const costLeft = byKind(rows, "cost-estimate");
  assert.equal(costLeft.valueText, "USD 6.00");
});

test("zero utilization, absent or zero usage, stale data and specialized totals do not produce estimates", () => {
  const examples = [
    [window({ usedFraction: 0 }, { tokens: 1000, cost: 2, currency: "USD" }), {}],
    [window({ usedFraction: 0.5 }, { tokens: 0, cost: 0, currency: "USD" }), {}],
    [window({ usedFraction: 0.5 }, {}), {}],
    [window({ usedFraction: 0.5 }, { tokens: 1000, cost: 2, currency: "USD" }, false), {}],
    [window({ usedFraction: 0.5 }, { tokens: 1000, cost: 2, currency: "USD" }), { estimates: false }],
  ];
  for (const [limit, options] of examples) {
    const rows = limitDetails(limit, options);
    assert.ok(!byKind(rows, "tokens-estimate") && !byKind(rows, "cost-estimate"));
  }
  const exhausted = byKind(limitDetails(window({ usedFraction: 1 }, { tokens: 1000 })), "tokens-estimate");
  assert.equal(exhausted.valueText, "0 tokens");
});

test("opaque credits and currency amounts remain distinct from tokens and cash", () => {
  const credits = limitDetails(window({ remaining: 500, limit: 1000, unit: "credits" }));
  assert.ok(texts(credits).includes("Remaining: 500 credits"));
  assert.ok(!credits.some((row) => row.kind || row.text.includes("tokens")));
  const dollars = limitDetails(window({ remaining: 3.25, unit: "currency", currency: "USD" }, { cost: 1 }));
  assert.ok(texts(dollars).includes("Remaining: USD 3.25"));
  const cost = byKind(dollars, "cost-used");
  assert.equal(cost.valueText, "1 (currency not reported)");
  assert.ok(!byKind(dollars, "tokens-estimate") && !byKind(dollars, "cost-estimate"));
});

test("a real percentage without a known time span remains visible without a fake window or denominator", () => {
  const rows = limitDetails({ amount: { remainingFraction: 0 }, allowed: false, limitReached: true }, { includeShare: true });
  assert.ok(texts(rows).some((text) => /0%/.test(text)));
  assert.ok(texts(rows).some((text) => /allowed: no/.test(text)));
  assert.ok(texts(rows).some((text) => /reached: yes/.test(text)));
  assert.ok(!rows.some((row) => row.kind || /tokens|USD/.test(row.text)));
});

test("a held reset grant is visible even when its meter is absent, without duplicating a matching weekly meter", () => {
  const report = { limits: [], resetCredits: { availableCount: 3, credits: [{ title: "Scoped reset", remainingCount: 3, status: "unavailable", clears: ["anthropic:7d:fable"] }] } };
  assert.ok(texts(reportNotes(report)).some((text) => /3.*unavailable/.test(text)));
  report.limits.push({ id: "anthropic:7d:fable", window: { id: "7d" } });
  assert.deepEqual(reportNotes(report), []);
});

test("untrusted notes stay single-line without losing status, plan or observation semantics", () => {
  const report = {
    stale: true,
    error: "  token\nexpired · retry  ",
    metadata: { plan: "Team\nPlan", sourceId: "cpa:acme" },
    observedAt: 1794564000000,
    limits: [],
  };
  const rows = reportNotes(report);
  assert.equal(byKind(rows, "stale").valueText, undefined);
  assert.equal(byKind(rows, "error").text, "token expired / retry");
  assert.equal(byKind(rows, "error").valueText, undefined);
  assert.equal(byKind(rows, "plan").valueText, "Team Plan");
  assert.equal(byKind(rows, "observed").valueText, "2026-11-13 10:00 UTC");
});
