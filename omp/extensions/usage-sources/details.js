import { GOOGLE_TIER_PLANS, finite, normalizeProvider } from "./common.js";

// Keep server text on one UI row and out of the status-line separator grammar.
export function cleanText(value) {
  return String(value ?? "").replace(/[\x00-\x1f\x7f\u2028\u2029]/g, " ").replace(/\s+/g, " ").replace(/·/g, "/").trim();
}

function quantity(value) {
  const number = finite(value);
  if (number === undefined) return undefined;
  const magnitude = Math.abs(number);
  if (magnitude >= 1e9) return `${(number / 1e9).toFixed(2)}B`;
  if (magnitude >= 1e6) return `${(number / 1e6).toFixed(2)}M`;
  if (magnitude >= 1e3) return `${(number / 1e3).toFixed(2)}K`;
  return new Intl.NumberFormat("en-US", { maximumFractionDigits: 4 }).format(number);
}

function money(value, currency) {
  const number = finite(value);
  if (number === undefined) return undefined;
  return `${cleanText(currency)} ${new Intl.NumberFormat("en-US", { minimumFractionDigits: 2, maximumFractionDigits: number !== 0 && Math.abs(number) < 0.01 ? 6 : 2 }).format(number)}`;
}

export function remainingFraction(amount = {}) {
  const remaining = finite(amount.remainingFraction);
  const used = finite(amount.usedFraction);
  const fraction = remaining ?? (used === undefined ? undefined : 1 - used);
  return fraction === undefined ? undefined : Math.max(0, Math.min(1, fraction));
}

// Detail rows are { text, kind?, valueText? }. `text` stays the readable and
// accessible form; `kind`/`valueText` let a card group and draw the four
// quantity kinds without parsing prose. valueText is the same already
// formatted value the text embeds, never a second computation.
// Amounts are kept separate from percentage meters: opaque credits are never called tokens.
export function limitDetails(limit, { estimates = true, includeShare = false } = {}) {
  const rows = [];
  const amount = limit.amount ?? {};
  const reportedUnit = cleanText(amount.unit);
  const unit = !reportedUnit || reportedUnit === "unknown" ? "units (unit not reported)" : reportedUnit;
  const currency = cleanText(amount.currency);
  const format = (value) => currency ? money(value, currency) : reportedUnit === "percent" ? `${quantity(value)}%` : `${quantity(value)} ${unit}`;
  const share = remainingFraction(amount);
  if (includeShare && share !== undefined) rows.push({ text: `Remaining: ${quantity(share * 100)}%` });
  if (typeof limit.allowed === "boolean") rows.push({ text: `Requests allowed: ${limit.allowed ? "yes" : "no"}` });
  if (typeof limit.limitReached === "boolean") rows.push({ text: `Limit reached: ${limit.limitReached ? "yes" : "no"}` });
  for (const [key, label] of [["remaining", "Remaining"], ["used", "Used"], ["limit", "Limit"]]) {
    const value = finite(amount[key]);
    if (value !== undefined && value >= 0) rows.push({ text: `${label}: ${format(value)}` });
  }
  const usage = limit.usage ?? {};
  const tokens = finite(usage.tokens);
  const cost = finite(usage.cost);
  const costCurrency = cleanText(usage.currency);
  if (tokens !== undefined && tokens >= 0) {
    const usedTokens = `${quantity(tokens)} tokens`;
    rows.push({ text: `Observed used: ${usedTokens}`, kind: "tokens-used", valueText: usedTokens });
  }
  if (cost !== undefined && cost >= 0) {
    const usedCost = costCurrency ? money(cost, costCurrency) : `${quantity(cost)} (currency not reported)`;
    rows.push({ text: `API-equivalent used: ${usedCost}`, kind: "cost-used", valueText: usedCost });
  }
  const remaining = remainingFraction(amount);
  const used = finite(amount.usedFraction) ?? (remaining === undefined ? undefined : 1 - remaining);
  // Zero usage or zero utilization cannot establish a meaningful quota-to-work ratio.
  if (estimates && limit.estimateEligible === true && remaining !== undefined && used > 0 && used <= 1) {
    const scale = remaining / used;
    if (tokens > 0 && Number.isFinite(tokens * scale)) {
      const leftTokens = `${quantity(Math.floor(tokens * scale))} tokens`;
      rows.push({ text: `Est. left: ${leftTokens}`, kind: "tokens-estimate", valueText: leftTokens });
    }
    if (cost > 0 && costCurrency && Number.isFinite(cost * scale)) {
      const leftCost = money(cost * scale, costCurrency);
      rows.push({ text: `Est. API-equivalent left: ${leftCost}`, kind: "cost-estimate", valueText: leftCost });
    }
  }
  for (const item of limit.breakdown ?? []) {
    const fraction = finite(item.usedFraction);
    if (fraction !== undefined) rows.push({ text: `${cleanText(item.label)} share used: ${quantity(fraction * 100)}%` });
  }
  return rows;
}

// Plans as the providers sell them today, by provider and by the plan as reported (lowercase, words joined by single
// spaces, a Codex `chatgpt_` prefix dropped). OpenAI reports Codex's three Pro tiers as `prolite`, `pro` and
// `promax`. omp names Claude's Max plans by their old usage multiples (`Max 5x`, `Max 20x`, from the account's
// rate-limit tier); Anthropic now sells them as Max and Ultra.
const PLAN_NAMES = {
  "openai-codex": {
    prolite: "Pro 100",
    "pro lite": "Pro 100",
    pro: "Pro 200",
    promax: "Pro 500",
    "pro max": "Pro 500",
    edu: "Education",
  },
  anthropic: { "max 5x": "Max", "max 20x": "Ultra" },
};

// Sources report plan ids (`pro-20x`, `plus`); they read as plan names (`Pro 20x`). A name the source already
// cased (`Team Plan`) stays as reported, without the provider's own name in front (Kiro's `Kiro Pro` reads `Pro`).
// The plans PLAN_NAMES knows read as sold.
function planLabel(value, provider) {
  const words = cleanText(value).split(" ");
  const own = String(provider ?? "").toLowerCase().split(/[-_@\s]+/).filter(Boolean);
  let drop = 0;
  while (drop < own.length && drop < words.length - 1 && words[drop].toLowerCase() === own[drop]) drop++;
  const plan = words.slice(drop).join(" ");
  const key = plan.toLowerCase().replace(/[-_\s]+/g, " ").replace(/^chatgpt /, "");
  const known = PLAN_NAMES[normalizeProvider(provider)]?.[key];
  if (known) return known;
  if (plan !== plan.toLowerCase()) return plan;
  return plan.split(/[-_\s]+/).filter(Boolean).map((word) => word[0].toUpperCase() + word.slice(1)).join(" ");
}

// The plan a report names for its account, undefined when it names none: a quota source's `plan`, else where
// omp's own reports carry it (as `omp usage` reads them): Claude's `subscriptionPlan` (omp 19+), the `planType` of
// Codex, Z.ai, Kiro and others, Copilot's `plan`, Gemini CLI's tier and Muse Code's `tier`.
export function planOf(report) {
  const md = report?.metadata ?? {};
  const gemini = GOOGLE_TIER_PLANS.get(md.currentTierId) ?? md.currentTierName;
  const raw = [md.plan, md.subscriptionPlan, md.planType, gemini, md.tier].find((v) => typeof v === "string" && cleanText(v));
  return raw === undefined ? undefined : planLabel(raw, md.baseProvider ?? report.provider) || undefined;
}

// The detail row naming a report's plan; undefined without one.
export function planRow(report) {
  const plan = planOf(report);
  return plan ? { text: `Plan: ${plan}`, kind: "plan", valueText: plan } : undefined;
}

export function reportNotes(report) {
  const rows = [];
  if (report.stale) {
    // Keeper serves the snapshots it refreshed; its own schedule (or `refresh: true` here) makes them current.
    const text = report.metadata?.sourceType === "keeper"
      ? "Stale Keeper snapshot: Keeper hasn't refreshed this quota recently; turn on its scheduled quota refresh"
      : "Stale quota snapshot; refresh the source";
    rows.push({ text, kind: "stale" });
  }
  if (report.error) rows.push({ text: cleanText(report.error), kind: "error" });
  const plan = planRow(report);
  if (plan) rows.push(plan);
  for (const item of report.summary ?? []) {
    const label = cleanText(item.label);
    const value = typeof item.value === "string" ? cleanText(item.value) : item.currency ? money(item.value, item.currency) : quantity(item.value);
    if (label && value !== undefined) rows.push({ text: `${label}: ${value}${item.currency || !item.unit ? "" : ` ${cleanText(item.unit)}`}` });
  }
  const weekly = (report.limits ?? []).filter((limit) => limit.window?.id === "7d" || limit.scope?.windowId === "7d" || limit.window?.durationMs === 604_800_000);
  const grants = report.resetCredits?.credits ?? [];
  for (const grant of grants) {
    const left = finite(grant.remainingCount);
    if (!(left > 0) || grant.status === "expired") continue;
    if (weekly.some((limit) => grant.clears?.includes(limit.id))) continue;
    rows.push({ text: `${cleanText(grant.title) || "Reset grant"} held: ${quantity(left)} (${cleanText(grant.status) || "status unknown"})` });
  }
  const saved = finite(report.resetCredits?.availableCount);
  if (saved > 0 && weekly.length === 0 && !grants.some((grant) => finite(grant.remainingCount) > 0)) rows.push({ text: `Reported saved reset credits: ${quantity(saved)}` });
  if (report.metadata?.sourceId && finite(report.observedAt) !== undefined) {
    const date = new Date(report.observedAt);
    if (Number.isFinite(date.getTime())) {
      const observed = date.toISOString().slice(0, 16).replace("T", " ");
      rows.push({ text: `Observed ${observed} UTC`, kind: "observed", valueText: `${observed} UTC` });
    }
  }
  return rows;
}
