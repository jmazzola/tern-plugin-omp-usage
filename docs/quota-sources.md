# External quota sources

Besides omp's own accounts, omp Usage can show the accounts behind
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (CPA) and
[CPA Usage Keeper](https://github.com/Willxup/cpa-usage-keeper), each source as its own provider and account pool
(`Codex@dashboard`). See the [README](../README.md#external-quota-sources) for what they add.

## Set up

Nothing changes until `~/.omp/agent/usage-sources.json` exists (or the file `OMP_USAGE_SOURCES_FILE` names). Restart
omp sessions after changing it or the environment variables it names.

```json
{
  "sources": [
    {
      "id": "proxy",
      "type": "cpa",
      "baseUrl": "http://127.0.0.1:8317",
      "managementKeyEnv": "CPA_MANAGEMENT_KEY",
      "providers": ["codex", "claude"],
      "intervalSeconds": 60,
      "maxAgeSeconds": 600
    },
    {
      "id": "dashboard",
      "type": "keeper",
      "baseUrl": "http://127.0.0.1:8080",
      "passwordEnv": "CPA_KEEPER_PASSWORD",
      "providers": ["codex", "claude"],
      "refresh": false
    }
  ],
  "modelMappings": [
    { "provider": "my-proxy", "model": "gpt-*", "source": "dashboard", "quotaProvider": "codex" },
    { "provider": "my-proxy", "model": "claude-*", "source": "proxy", "quotaProvider": "claude" }
  ]
}
```

The file holds the **names** of environment variables, never secrets: set those variables where omp starts (a secret
manager, your launcher). Don't put credentials in URLs, Tern's settings or the repo, and use HTTPS beyond a trusted
local connection.

| Setting | Meaning |
| --- | --- |
| `id` | Unique lowercase source id: letters, digits, `_` or `-`; appears in labels such as `Codex@proxy` |
| `type` | `cpa` or `keeper` |
| `baseUrl` | Service root, including any path prefix; no credentials, query or fragment |
| `providers` | Optional: only these providers' accounts; omit for all. Aliases include `codex`, `claude`, `gemini-cli`, `antigravity`, `kimi` and `xai` |
| `intervalSeconds` | Least time between polls of the source in each omp session; default 60 |
| `maxAgeSeconds` | How old a quota observation may be before its meters are dropped and it shows as stale; default 600 |
| `managementKeyEnv` | CPA only: variable holding the management key (not an inference API key) |
| `quotaPluginId` | CPA only: quota plugin for accounts that don't name their own; plugins take precedence over built-in queries |
| `kimiDomain` | CPA only: `com` (default) or `ai`, when an account's public data doesn't say which Kimi domain it uses |
| `passwordEnv` | Keeper only: variable holding the administrator password |
| `sessionCookieEnv` | Keeper only, instead of `passwordEnv`: variable holding an administrator session token, without the cookie name |
| `refresh` | Keeper only: `false` (default) reads its cache as is; `true` may queue refreshes of missing or stale quotas |
| `modelMappings` | Which source and pool an omp provider/model's quota comes from in **Current model**: see [Model mappings](#model-mappings) |

Sources stay apart: two sources that expose the same account show it twice, so turn one of them off for it in the
panel, or drop it from the file. Choosing an account to show here doesn't change which account CPA sends requests to.

Protocol references: [CPA v8.0.69](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.69/docs/management-api-v8.md)
and [Keeper 7d28848](https://github.com/Willxup/cpa-usage-keeper/tree/7d28848). Management-only `/v0` deployments
aren't supported.

## Model mappings

`modelMappings` matters only for **Show: Current model** (the default) and a subagent's model. There the extension
knows just the omp provider id (its key under `providers:` in `~/.omp/agent/models.yml`) and the model id; it never
guesses a source from a `baseUrl`. Without a mapping it looks for omp's own report for that provider, which a provider
pointed at a proxy usually doesn't have, so the line stays empty. **All providers** and **Selected providers** list
every source's windows and need no mapping.

| Field | Meaning |
| --- | --- |
| `provider` | The omp provider id, as in `models.yml` |
| `model` | Optional model id pattern; `*` matches anything; default: every model of the provider |
| `source` | The `id` of an entry in `sources` |
| `quotaProvider` | The pool in that source: `codex`, `claude`, `antigravity`, `gemini-cli`, `kimi`, `xai` |

The first matching entry wins, so put narrow `model` patterns before broad ones.

A mapping picks which pool's quota to **show**; it doesn't change which account CPA uses, so map a model to the pool
that actually serves it. When a proxy answers one provider's model ids from another provider's accounts (Claude
models from Antigravity's Claude group, say), check CPA's or Keeper's request log for which account served them. A
mapping to a pool the source doesn't have fails quietly: no line for that model, or the source's own error if it's
failing.

For example, omp's `openai-codex` provider sent to the CPA behind the `dashboard` Keeper, and a custom `antigravity`
provider sent to the one behind `proxy`:

```json
"modelMappings": [
  { "provider": "openai-codex", "source": "dashboard", "quotaProvider": "codex" },
  { "provider": "antigravity", "source": "proxy", "quotaProvider": "antigravity" }
]
```

Antigravity's quota groups aren't tied to a model id, so every group's windows show whichever of its models is active.

## CLIProxyAPI

omp Usage uses CPA's documented v8 management API: it lists every account and asks each one's quota through
`/v8/management/requests/api-call`. It never downloads OAuth tokens, uses reset credits, clears cooldowns or changes
accounts. Built-in queries cover Codex, Claude, Gemini CLI, Antigravity, Kimi and xAI; installed quota plugins can add
others. Accounts it can't query say so in the quota details. CPA's quota queries usually report no token or cost
usage, so its accounts usually get no estimates; for those, use Keeper.

The management key can do much more than this, including downloading credentials: keep it private, and never expose
CPA's management interface to the network.

## CPA Usage Keeper

Keeper needs CPA v8.0.12 or newer. omp Usage reads `/api/v1/usage/identities` and `POST /api/v1/quota/cache` as an
administrator (Keeper's API-key viewer can't read quotas). Its session stays in memory; with a password, it logs in
again after a 401, while a session token you supply must be renewed by you.

Reading Keeper's cache doesn't refresh anything: entries can be old, and Keeper loses them when it restarts (a missing
one means "not refreshed", not 0% left). Turn on Keeper's own scheduled refresh; or set `refresh: true`, and omp Usage
queues `/api/v1/quota/refresh`, which makes real requests upstream, and reads the results at the next poll. How fresh
a quota is goes by Keeper's `refreshed_at`, never by when omp Usage read it.

## What the views show

| Information | How it shows |
| --- | --- |
| Share left, scopes and reset times | Meters on the line, the card and the details, including separate model/group windows; a missing share never becomes 0% or 100% |
| Reported amounts | Remaining/used/limit in the details, with the unit and currency the source gives; credits aren't relabeled as tokens |
| Observed usage | Tokens and API-equivalent cost a window has used, for that account and window; Keeper may work it out from the requests it recorded and its price catalog |
| Estimated remaining | `tokens used × share left ÷ share used`, only for windows with usage and a share used above 0%; in the card (tokens and value) and the details |
| API-equivalent value | Paired with observed cost, in the same currency: not cash, a subscription price, or a spending allowance |
| Stale, missing or rolled-over data | Notes and the observation time; stale data gives no meters or estimates, and missing numbers are left out, never shown as 0 |
| Allowed / limit reached | Shown where the source says so, even without a share |
| Saved resets | Codex credits and Claude grants where the source gives them, read-only |
| Provider and plugin summaries | Labeled, with units, in the details; no made-up percentage without a limit |
| Request history and billing | Not here: use CPA's or Keeper's own pages. omp Usage collects no history and makes no extra requests |

Plan ids read as names (`pro-20x` shows as `Pro 20x`); a plan the source already capitalizes stays as it is.

Estimates assume you keep using the account the same way. Other models, cache rates, quota weights, requests Keeper
missed and rounded shares make them less accurate, and no usage or a share used of 0% gives no estimate.

All and Selected providers show every window a source reports, even for models omp doesn't list. Current model
applies a window's scope to the model id; `modelMappings` only picks a pool.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| External source shows only in All/Selected | Add a `modelMappings` entry for the omp provider/model: an OpenAI-compatible endpoint doesn't say which quota it draws on |
| External source is stale or not refreshed | Check its observation time. For Keeper, turn on its scheduled quota refresh (the gear in its Auth Files inspection dialog) more often than `maxAgeSeconds` (10 minutes by default), or set `refresh`; then wait for the next poll |
| External source returns 401/403 | CPA needs its management key; Keeper an administrator login, not an API-key viewer |
| No tokens or API-equivalent value | Only Keeper gives them, and only for windows with recorded usage and a share used above 0% |
| Tokens and costs disappear when combined | Combined and by plan don't add them up: pick All accounts or one account |
| Plans read as ids, or amounts as plain text in the details | Restart omp sessions after updating, then `tern plugin reload omp-usage`; older cache rows stay readable as text |
