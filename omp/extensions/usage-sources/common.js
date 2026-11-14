// Shared transport and numeric rules for the CPA and Keeper quota sources.
const PROVIDERS = {
  codex: "openai-codex",
  claude: "anthropic",
  "gemini-cli": "google-gemini-cli",
  antigravity: "google-antigravity",
  kimi: "kimi-code",
  "kimi-ai": "kimi-code",
  "kimi.ai": "kimi-code",
  "kimi.com": "kimi-code",
};

export function normalizeProvider(value) {
  const key = String(value ?? "").trim().toLowerCase();
  return PROVIDERS[key] ?? key;
}

// Same tier names omp gives Codex's additional meters.
export function codexTier(limitName, meteredFeature) {
  const probe = `${limitName} ${meteredFeature}`.toLowerCase();
  if (probe.includes("spark") || probe.includes("bengalfox")) return "spark";
  const name = String(meteredFeature || limitName || "").toLowerCase().replace(/^codex[-_]/, "");
  return name.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "extra";
}

export function finite(value) {
  if (typeof value !== "number" && (typeof value !== "string" || !value.trim())) return undefined;
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}

export function timestamp(value) {
  const number = finite(value);
  if (number !== undefined) return number > 0 ? (number < 100_000_000_000 ? number * 1000 : number) : undefined;
  if (typeof value !== "string" || !value.trim()) return undefined;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : undefined;
}

export function durationMs(value, unit = "second") {
  const amount = finite(value);
  if (amount === undefined || amount <= 0) return undefined;
  const units = {
    ms: 1, millisecond: 1, milliseconds: 1,
    s: 1000, second: 1000, seconds: 1000,
    m: 60_000, minute: 60_000, minutes: 60_000,
    h: 3_600_000, hour: 3_600_000, hours: 3_600_000,
    d: 86_400_000, day: 86_400_000, days: 86_400_000,
    w: 604_800_000, week: 604_800_000, weeks: 604_800_000,
    month: 2_592_000_000, months: 2_592_000_000,
  };
  const multiplier = units[String(unit).toLowerCase()];
  const result = amount * multiplier;
  return Number.isFinite(result) ? result : undefined;
}

export async function mapConcurrent(items, mapper, limit = 4) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await mapper(items[index], index);
    }
  }));
  return results;
}

export class HttpError extends Error {
  constructor(status) {
    super(`HTTP ${status}`);
    this.status = status;
  }
}

export async function request(fetchImpl, baseUrl, path, { method = "GET", headers = {}, body } = {}) {
  const url = `${baseUrl.replace(/\/+$/, "")}/${path.replace(/^\/+/, "")}`;
  let response;
  try {
    response = await fetchImpl(url, {
      method,
      headers: body === undefined ? headers : { "Content-Type": "application/json", ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15_000),
      redirect: "error",
    });
  } catch {
    throw new Error("Quota service request failed or timed out");
  }
  if (!response.ok) throw new HttpError(response.status);
  return response;
}

export async function requestJson(fetchImpl, baseUrl, path, options) {
  const response = await request(fetchImpl, baseUrl, path, options);
  if (response.status === 204) return null;
  try {
    return await response.json();
  } catch {
    throw new Error("Quota service returned invalid JSON");
  }
}
