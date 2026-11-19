# External quota sources

On top of omp's own accounts, omp Usage can show the accounts behind
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) (CPA) and
[CPA Usage Keeper](https://github.com/Willxup/cpa-usage-keeper), each source as its own provider and account pool
(`Codex@dashboard`). The [README](../README.md#external-quota-sources) covers what they add.

## Set up

Nothing changes until `~/.omp/agent/usage-sources.json` exists (or whatever file `OMP_USAGE_SOURCES_FILE` points to).
Restart your omp sessions after changing it, or any of the environment variables it names.

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

The file only holds the **names** of environment variables, never the secrets themselves. Set those variables wherever
omp starts from (a secret manager, your launcher). Keep credentials out of URLs, Tern's settings and the repo, and use
HTTPS for anything that isn't a trusted local connection.

| Setting | Meaning |
| --- | --- |
| `id` | Unique lowercase source id (letters, digits, `_` or `-`). Shows up in labels like `Codex@proxy` |
| `type` | `cpa` or `keeper` |
| `baseUrl` | The service's root, including any path prefix. No credentials, query or fragment |
| `providers` | Optional: only these providers' accounts. Leave it out for all of them. Aliases include `codex`, `claude`, `gemini-cli`, `antigravity`, `kimi` and `xai` |
| `intervalSeconds` | The least time between polls of the source, per omp session. Default 60 |
| `maxAgeSeconds` | How old a quota can get before its meters are dropped and it shows as stale. Default 600 |
| `managementKeyEnv` | CPA only: the variable holding the management key (not an inference API key) |
| `quotaPluginId` | CPA only: the quota plugin for accounts that don't name their own. Plugins win over the built-in queries |
| `kimiDomain` | CPA only: `com` (default) or `ai`, for when an account's public data doesn't say which Kimi domain it's on |
| `passwordEnv` | Keeper only: the variable holding the administrator password |
| `sessionCookieEnv` | Keeper only, instead of `passwordEnv`: the variable holding an administrator session token, without the cookie name |
| `refresh` | Keeper only: `false` (default) reads its cache as is; `true` can queue refreshes of missing or stale quotas |
| `modelMappings` | Which source and pool an omp provider/model's quota comes from in **Current model**. See [Model mappings](#model-mappings) |

Sources stay separate. If two sources expose the same account, it shows up twice, so either switch one of them off
in the panel or drop it from the file. Picking which account to show here doesn't change which account CPA actually
sends requests to.

Protocol references: [CPA v8.0.69](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.69/docs/management-api-v8.md)
and [Keeper 7d28848](https://github.com/Willxup/cpa-usage-keeper/tree/7d28848). Management-only `/v0` deployments
aren't supported.

## Model mappings

`modelMappings` only matters for **Show: Current model** (the default) and a subagent's model. In those cases the
extension only knows the omp provider id (its key under `providers:` in `~/.omp/agent/models.yml`) and the model id,
and it never guesses a source from a `baseUrl`. Without a mapping, it looks for omp's own report for that provider,
which a provider pointed at a proxy usually doesn't have, so the line stays empty. **All providers** and **Selected
providers** list every source's windows and don't need a mapping.

| Field | Meaning |
| --- | --- |
| `provider` | The omp provider id, as in `models.yml` |
| `model` | Optional model id pattern. `*` matches anything, and leaving it out means every model of the provider |
| `source` | The `id` of an entry in `sources` |
| `quotaProvider` | The pool in that source: `codex`, `claude`, `antigravity`, `gemini-cli`, `kimi`, `xai` |

The first matching entry wins, so put narrow `model` patterns before broad ones.

A mapping only picks which pool's quota to **show**. It doesn't change which account CPA uses, so map a model to the
pool that actually serves it. When a proxy answers one provider's model ids from another provider's accounts (Claude
models served by Antigravity's Claude group, say), check CPA's or Keeper's request log to see which account really
served them. A mapping to a pool the source doesn't have fails quietly: no line for that model, or the source's own
error if the source itself is broken.

For example, omp's `openai-codex` provider sent through the CPA behind the `dashboard` Keeper, and a custom
`antigravity` provider sent through the one behind `proxy`:

```json
"modelMappings": [
  { "provider": "openai-codex", "source": "dashboard", "quotaProvider": "codex" },
  { "provider": "antigravity", "source": "proxy", "quotaProvider": "antigravity" }
]
```

Antigravity's quota groups aren't tied to a model id, so every group's windows show whichever of its models is active.

## CLIProxyAPI

omp Usage talks to CPA's documented v8 management API. It lists every account and asks for each one's quota through
`/v8/management/requests/api-call`. It never downloads OAuth tokens, uses reset credits, clears cooldowns or changes
accounts. The built-in queries cover Codex, Claude, Gemini CLI, Antigravity, Kimi and xAI, and installed quota plugins
can add more. Accounts it can't query say so in the quota details.

CPA's quota queries usually don't report any token or cost usage, so its accounts usually don't get estimates. For
those, use Keeper.

The management key can do a lot more than read quotas, including downloading credentials. Keep it private, and never
expose CPA's management interface to the network.

## CPA Usage Keeper

Keeper needs CPA v8.0.12 or newer. omp Usage reads `/api/v1/usage/identities` and `POST /api/v1/quota/cache` as an
administrator (Keeper's API-key viewer role can't read quotas). The session only lives in memory. With a password, it
logs back in after a 401. With a session token you supplied, renewing it is on you.

Reading Keeper's cache doesn't refresh anything. Entries can be old, and Keeper loses them all when it restarts (a
missing one means "not refreshed", not 0% left). Turn on Keeper's own scheduled refresh. Or set `refresh: true`, and
omp Usage queues `/api/v1/quota/refresh` - which makes real requests upstream - and picks up the results on the next
poll. Freshness always goes by Keeper's `refreshed_at`, never by when omp Usage happened to read the cache.

## What the views show

| Information | How it shows |
| --- | --- |
| Share left, scopes and reset times | Meters on the line, the card and the details, including separate model/group windows. A missing share never becomes 0% or 100% |
| Reported amounts | Remaining/used/limit in the details, with whatever unit and currency the source gives. Credits aren't relabeled as tokens |
| Observed usage | The tokens and API-equivalent cost a window has used, for that exact account and window. Keeper can work it out from the requests it recorded and its price catalog |
| Estimated remaining | `tokens used × share left ÷ share used`, only for windows with usage and a share used above 0%. In the card (tokens and value) and the details |
| API-equivalent value | Paired with observed cost, in the same currency. It's not cash, a subscription price, or a spending allowance |
| Stale, missing or rolled-over data | Notes and the observation time. Stale data gets no meters or estimates, and missing numbers are left out, never shown as 0 |
| Allowed / limit reached | Shown wherever the source says so, even without a share |
| Saved resets | Codex credits and Claude grants, where the source gives them, read-only |
| Provider and plugin summaries | Labeled, with units, in the details. No made-up percentage without a limit to divide by |
| Request history and billing | Not here. Use CPA's or Keeper's own pages. omp Usage collects no history and makes no extra requests |

Plan ids read as names (`team-business` shows as `Team Business`). A plan the source already capitalizes stays as it
is. Plans sold under another name today read as sold: Codex's `prolite`, `pro` and `promax` as Pro 100, Pro 200 and
Pro 500, and Claude's `Max 5x` and `Max 20x` as Max and Ultra.

Estimates assume you keep using the account the same way you have been. Different models, cache rates, quota
weights, requests Keeper missed and rounded shares all make them less accurate, and with no usage or a share used of
0%, there's no estimate at all.

All and Selected providers show every window a source reports, even for models omp doesn't list. Current model
applies a window's scope to the model id, and `modelMappings` only picks the pool.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| An external source only shows in All/Selected | Add a `modelMappings` entry for the omp provider/model. An OpenAI-compatible endpoint doesn't say which quota it draws on |
| An external source is stale or not refreshed | Check its observation time. For Keeper, turn on its scheduled quota refresh (the gear in its Auth Files inspection dialog) more often than `maxAgeSeconds` (10 minutes by default), or set `refresh`, then wait for the next poll |
| An external source returns 401/403 | CPA needs its management key. Keeper needs an administrator login, not an API-key viewer |
| No tokens or API-equivalent value | Only Keeper gives those, and only for windows with recorded usage and a share used above 0% |
| Tokens and costs disappear when combined | Combined and by plan don't add them up. Pick All accounts or a single account |
| Plans read as ids, or amounts as plain text in the details | Restart your omp sessions after updating, then `tern plugin reload omp-usage`. Older cache rows stay readable as text |
