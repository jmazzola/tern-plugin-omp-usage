import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createCPASource } from "./cpa.js";
import { createKeeperSource } from "./keeper.js";
import { finite, normalizeProvider } from "./common.js";

const DEFAULT_CONFIG_FILE = join(homedir(), ".omp", "agent", "usage-sources.json");

function positive(value, fallback, name) {
  if (value === undefined) return fallback;
  const number = finite(value);
  if (number === undefined || number <= 0) throw new Error(`${name} must be positive`);
  return number;
}

function modelPattern(value) {
  return new RegExp(`^${value.toLowerCase().split("*").map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*")}$`);
}

// Source identities remain separate even when two services expose the same account.
export function sourceProvider(source, provider) {
  return `${source.type}:${source.id}:${normalizeProvider(provider)}`;
}

export function createUsageSources(config = {}, { fetch = globalThis.fetch, env = process.env, now = Date.now, factories } = {}) {
  if (!config || typeof config !== "object" || Array.isArray(config)) throw new Error("Usage sources configuration must be an object");
  if (config.sources !== undefined && !Array.isArray(config.sources)) throw new Error("sources must be an array");
  if (config.modelMappings !== undefined && !Array.isArray(config.modelMappings)) throw new Error("modelMappings must be an array");
  const ids = new Set();
  const sources = (config.sources ?? []).map((source) => {
    if (!source || !/^[a-z0-9][a-z0-9_-]*$/.test(source.id ?? "")) throw new Error("Each source needs a lowercase id using letters, digits, _ or -");
    if (ids.has(source.id)) throw new Error("Usage source ids must be unique");
    ids.add(source.id);
    if (source.type !== "cpa" && source.type !== "keeper") throw new Error(`Source ${source.id}: type must be cpa or keeper`);
    let url;
    try { url = new URL(source.baseUrl); } catch { throw new Error(`Source ${source.id}: baseUrl must be an HTTP(S) URL`); }
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
      throw new Error(`Source ${source.id}: baseUrl must be HTTP(S), without credentials, query or fragment`);
    }
    if (source.providers !== undefined && (!Array.isArray(source.providers) || source.providers.some((p) => typeof p !== "string" || !p.trim()))) {
      throw new Error(`Source ${source.id}: providers must be an array of provider ids`);
    }
    const settings = {
      ...source,
      baseUrl: url.href.replace(/\/+$/, ""),
      providers: source.providers?.map(normalizeProvider),
      intervalSeconds: positive(source.intervalSeconds, 60, "intervalSeconds"),
      maxAgeSeconds: positive(source.maxAgeSeconds, 600, "maxAgeSeconds"),
    };
    const factory = factories?.[source.type] ?? (source.type === "cpa" ? createCPASource : createKeeperSource);
    return { settings, factory, client: null, reports: [], checkedAt: -Infinity, pending: null };
  });
  const mappings = (config.modelMappings ?? []).map((mapping) => {
    const source = sources.find((item) => item.settings.id === mapping?.source);
    if (!source || typeof mapping.provider !== "string" || !mapping.provider.trim() || typeof mapping.quotaProvider !== "string" || !mapping.quotaProvider.trim()) {
      throw new Error("Each modelMapping needs provider, an existing source, and quotaProvider");
    }
    if (mapping.model !== undefined && typeof mapping.model !== "string") throw new Error("modelMapping.model must be a string");
    return { provider: mapping.provider.toLowerCase(), model: modelPattern(mapping.model ?? "*"), target: sourceProvider(source.settings, mapping.quotaProvider), source: source.settings };
  });

  function decorate(source, report) {
    return {
      ...report,
      provider: sourceProvider(source, report.provider),
      metadata: { ...report.metadata, sourceId: source.id, sourceType: source.type, baseProvider: normalizeProvider(report.provider), maxAgeMs: source.maxAgeSeconds * 1000 },
    };
  }

  async function pollSource(record) {
    if (record.pending) return record.pending;
    if (now() - record.checkedAt < record.settings.intervalSeconds * 1000) return;
    record.checkedAt = now();
    record.pending = (async () => {
      try {
        record.client ??= record.factory(record.settings, { fetch, env });
        const fetched = await record.client.poll();
        const previous = new Map(record.reports.map((report) => [`${report.provider}/${report.metadata?.accountId}`, report]));
        record.reports = fetched.map((report) => {
          const next = decorate(record.settings, report);
          const old = previous.get(`${next.provider}/${next.metadata?.accountId}`);
          // A failed lookup cannot advance the observation clock or erase the last good snapshot.
          return next.error && (old?.limits?.length || old?.summary?.length) ? { ...old, error: next.error } : next;
        });
      } catch (error) {
        // Adapters and transport errors are sanitized; never cache raw server bodies or URLs.
        const message = error instanceof Error ? error.message : "Quota source unavailable";
        record.reports = record.reports.length
          ? record.reports.map((report) => ({ ...report, error: message }))
          : [decorate(record.settings, { provider: "status", metadata: { accountId: "source" }, limits: [], error: message })];
      }
    })();
    try {
      return await record.pending;
    } finally {
      record.pending = null;
    }
  }

  return {
    async poll() {
      await Promise.all(sources.map(pollSource));
      const at = now();
      return sources.flatMap((record) => record.reports.map((report) => {
        const observed = finite(report.observedAt);
        const rolledOver = observed !== undefined && report.limits.some((limit) => limit.window?.resetsAt > observed && limit.window.resetsAt <= at);
        const hasSnapshot = report.limits.length > 0 || report.summary?.length > 0;
        const stale = hasSnapshot && (observed === undefined || observed > at + 60_000 || at - observed > record.settings.maxAgeSeconds * 1000 || rolledOver);
        return stale ? { ...report, stale: true } : report;
      }));
    },
    resolve(provider, bare, reports) {
      const match = mappings.find((mapping) => mapping.provider === provider.toLowerCase() && mapping.model.test(bare));
      if (!match) return provider;
      const diagnostic = sourceProvider(match.source, "status");
      return !reports.some((report) => report.provider === match.target) && reports.some((report) => report.provider === diagnostic)
        ? diagnostic : match.target;
    },
  };
}

export function loadUsageSources(options = {}) {
  const env = options.env ?? process.env;
  const filename = env.OMP_USAGE_SOURCES_FILE || DEFAULT_CONFIG_FILE;
  let text;
  try {
    text = readFileSync(filename, "utf8");
  } catch (error) {
    if (error.code === "ENOENT" && !env.OMP_USAGE_SOURCES_FILE) return createUsageSources({}, options);
    throw new Error("Cannot read usage-sources.json; check OMP_USAGE_SOURCES_FILE");
  }
  let config;
  try { config = JSON.parse(text); } catch { throw new Error("usage-sources.json is not valid JSON"); }
  return createUsageSources(config, options);
}
