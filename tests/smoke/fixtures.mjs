// Cache documents for the smoke matrix, written as omp/extensions/usage-remaining.js writes
// ~/.omp/cache/usage-remaining.json (schema 2; `v1: true` leaves out what the first schema didn't have). Mirrors
// tests/luau/fixtures.luau.
export const M = 60_000;
export const H = 60 * M;
export const D = 24 * H;

export function meter(r) {
  const filled = Math.round(Math.min(1, Math.max(0, r)) * 8);
  return "█".repeat(filled) + "░".repeat(8 - filled);
}

// As the extension rounds: down, `<1%` under one percent.
export function pct(r) {
  if (r > 0 && r < 0.01) return "<1%";
  return `${Math.floor(r * 100 + 1e-9)}%`;
}

// The extension's countdowns: `45m`, `2h 11m`, `6d 4h`, `soon`.
export function short(ms) {
  if (ms <= 0) return "soon";
  const mins = Math.round(ms / M);
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  if (h < 24) return m ? `${h}h ${m}m` : `${h}h`;
  const d = Math.floor(h / 24);
  const hh = h % 24;
  return hh ? `${d}d ${hh}h` : `${d}d`;
}

// One window: { label, key, ms (length), r (share left), at (resetsAt), provider, account, scope, saved }.
export function win(opts) {
  return { key: opts.label, provider: "anthropic", ...opts };
}

export function piece(w, now, lead) {
  const head = lead ? `${lead} ` : "";
  const saved = w.saved ? ` (+${w.saved})` : "";
  if (w.at !== undefined && w.at <= now) return `${head}${w.label} reset${saved}`;
  const reset = w.at !== undefined ? ` (${short(w.at - now)})` : "";
  return `${head}${w.label} ${meter(w.r)} ${pct(w.r)} left${reset}${saved}`;
}

export function line(label, windows, now) {
  return windows.map((w, i) => piece(w, now, i === 0 ? label : undefined)).join(" · ");
}

export function cacheWindow(w) {
  const item = { provider: w.provider, key: w.key, label: w.label, remaining: w.r };
  if (w.account) item.account = w.account;
  if (w.scope) item.scope = w.scope;
  if (w.at !== undefined) item.resetsAt = w.at;
  if (w.ms) item.windowMs = w.ms;
  return item;
}

export function provider(id, label, windows, now, opts = {}) {
  const entry = { label, line: line(label, windows, now), resets: opts.resets ?? [], details: opts.details ?? [] };
  if (opts.accounts) entry.accounts = opts.accounts;
  if (!opts.v1) {
    entry.observedAt = opts.observed ?? now;
    entry.windows = windows.map(cacheWindow);
  }
  return entry;
}

export function model(id, label, windows, now, opts = {}) {
  const entry = { line: line(label, windows, now), resets: opts.resets ?? [], provider: id, details: opts.details ?? [] };
  if (!opts.v1) {
    entry.observedAt = opts.observed ?? now;
    entry.windows = windows.map(cacheWindow);
  }
  return entry;
}

// Claude's three windows at `now`: 5h (62% left, 2h to go), 7d (41%, 3d 4h, one saved reset), Fable 7d (83%).
export function claude(now, o = {}) {
  return [
    win({ label: "5h", key: "5h", ms: 5 * H, r: o.r5 ?? 0.62, at: now + (o.in5 ?? 2 * H) }),
    win({ label: "7d", key: "7d", ms: 7 * D, r: o.r7 ?? 0.41, at: now + (o.in7 ?? 3 * D + 4 * H), saved: 1 }),
    win({ label: "Fable 7d", key: "7d", ms: 7 * D, r: o.rf ?? 0.83, at: now + (o.inf ?? 3 * D + 4 * H), scope: "Fable" }),
  ];
}

// Codex's two windows.
export function codex(now, o = {}) {
  return [
    win({ label: "5h", key: "5h", ms: 5 * H, r: o.r5 ?? 0.91, at: now + 3 * H, provider: "openai-codex" }),
    win({ label: "7d", key: "7d", ms: 7 * D, r: o.r7 ?? 0.58, at: now + 5 * D, provider: "openai-codex" }),
  ];
}

// A whole cache. `o.observed` (every entry's observedAt), `o.written` (generatedAt), `o.chips` (Claude's model chip
// names), `o.codexChips`, `o.claude` / `o.codex` (windows), `o.resets`, `o.v1`, `o.providers` (more providers).
export function doc(now, o = {}) {
  const written = o.written ?? now;
  const observed = o.observed ?? now;
  const cl = o.claude ?? claude(written);
  const cx = o.codex ?? codex(written);
  const resets = o.resets ?? [{ expiresAt: now + 10 * D, count: 1, window: "7d" }];
  const models = {};
  for (const chip of o.chips ?? ["Opus 5.5"]) {
    models[chip] = model("anthropic", "Claude", cl, written, { observed, resets, v1: o.v1 });
  }
  for (const chip of o.codexChips ?? []) {
    models[chip] = model("openai-codex", "Codex", cx, written, { observed, v1: o.v1 });
  }
  const providers = {
    anthropic: provider("anthropic", "Claude", cl, written, { observed, resets, v1: o.v1 }),
    "openai-codex": provider("openai-codex", "Codex", cx, written, { observed, v1: o.v1 }),
    ...(o.providers ?? {}),
  };
  const out = { generatedAt: written, models, providers };
  if (!o.v1) {
    out.schema = 2;
    out.fetchedAt = o.fetched ?? observed;
  }
  return out;
}
