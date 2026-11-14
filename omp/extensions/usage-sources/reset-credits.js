import { finite, timestamp } from "./common.js";

const WINDOWS = new Map([
  ["five_hour", "anthropic:5h"],
  ["seven_day", "anthropic:7d"],
  ["seven_day_opus", "anthropic:7d:opus"],
  ["seven_day_sonnet", "anthropic:7d:sonnet"],
  ["seven_day_overage_included", "anthropic:7d:fable"],
]);

const field = (object, camel, snake) => object?.[camel] ?? object?.[snake];
const text = (value) => typeof value === "string" ? value.trim() : "";
const compact = (object) => Object.fromEntries(Object.entries(object).filter(([, value]) => value !== undefined));

function isoTime(value) {
  const ms = timestamp(value);
  if (ms === undefined) return undefined;
  const date = new Date(ms);
  return Number.isFinite(date.getTime()) ? date.toISOString() : undefined;
}

function clears(values) {
  const ids = [];
  for (const value of Array.isArray(values) ? values : []) {
    if (typeof value !== "string" || !/^[a-z0-9_-]{1,80}$/.test(value)) continue;
    const id = WINDOWS.get(value) ?? `anthropic:reset:${value}`;
    if (!ids.includes(id)) ids.push(id);
  }
  return ids;
}

// CPA returns cedar_ember's snake_case fields; Keeper caches the same grant as camelCase.
// Only describe grants. No caller can redeem or reset anything through this module.
export function claudeResetCredits(status) {
  if (!status || typeof status !== "object" || !Array.isArray(status.grants)) return undefined;
  const now = Date.now();
  const cooldown = field(status, "cooldownUntil", "cooldown_until");
  const cooling = timestamp(cooldown) > now;
  const eligible = status.eligible === true;
  const nextId = field(status, "nextGrantId", "next_grant_id");
  let availableCount = 0;
  let redeemableCount = 0;
  const credits = [];
  for (const grant of status.grants) {
    const left = finite(field(grant, "resetsLeft", "resets_left"));
    if (!(left >= 0)) continue;
    const endsAt = field(grant, "endsAt", "ends_at");
    const expiry = timestamp(endsAt);
    const expired = expiry <= now;
    const usable = eligible && text(grant.id) !== "" && grant.id === nextId
      && field(grant, "usableNow", "usable_now") === true
      && grant.paused !== true && !expired && !cooling && left > 0;
    if (!expired && left > 0) availableCount += left;
    if (usable) redeemableCount = left;
    credits.push(compact({
      title: text(grant.label) || "Claude limit reset",
      program: "cedar_ember",
      remainingCount: left,
      usable,
      requiresLimit: field(grant, "useRequiresLimit", "use_requires_limit") !== false,
      clears: clears(grant.clears),
      grantedAt: isoTime(field(grant, "startsAt", "starts_at")),
      expiresAt: isoTime(endsAt),
      status: expired ? "expired" : left === 0 ? "redeemed" : grant.paused === true ? "paused" : usable ? "available" : "unavailable",
    }));
  }
  return compact({
    availableCount,
    redeemableCount,
    eligible,
    reason: text(field(status, "ineligibleReason", "ineligible_reason")) || (cooling ? "cooldown" : undefined),
    cooldownUntil: isoTime(cooldown),
    credits,
  });
}
