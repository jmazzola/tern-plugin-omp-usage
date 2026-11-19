# How omp Usage works

To work on it, link a clone (see [From a clone](../README.md#from-a-clone)).

| Part | What it does |
| --- | --- |
| `omp/extensions/usage-remaining.js` | The omp extension. Fetches omp's usage and the configured sources' quotas, sets the line as an extension status, and caches every model's and provider's line and details. `omp/package.json` names it, so `omp plugin link` loads the `omp/` folder as omp's plugin `omp-usage` |
| `omp/extensions/usage-sources/` | The CLIProxyAPI and Keeper clients, the sources file, freshness, and the amounts and estimates |
| `plugin.toml`, `bar.css` | The Tern plugin's manifest, and the style sheet for the Update omp Usage pill and omp's bar |
| `window.luau` | The Tern plugin's entry point. Polls the focused omp pane, draws its line, and registers the commands and the `usage` segment |
| `data.luau` | What the views draw from: the cache, the settings in `tern.kv`, the providers and their colors, and omp's composer as read from a pane |
| `render.luau` | The line, its comets and its card, as CSS |
| `pickers.luau`, `panel.luau` | The settings: the palette's pickers and the settings panel |
| `details.luau` | The quota details |
| `update.luau` | Update checks, the update card, and installing updates |
| `extension.luau` | Linking the omp extension into omp's plugins, for an installed copy |

Each `.luau` file is its own Luau chunk, and a chunk can only hold 200 locals at once (constants don't count). Go
over that and Tern refuses to load the plugin, with nothing but a warning in its log to show for it. A feature that
needs a lot of top-level locals gets a file of its own.

## The cache

The extension caches every line in `~/.omp/cache/usage-remaining.json`. Current model, All and Selected providers,
subagent models, accounts, and the card's reset dates all read from it. A cache older than 10 minutes is ignored, and
the line falls back to the focused session's own status.

Every omp session writes the newest numbers it fetched there, which is why every pane shows the same ones. A session
whose numbers are older than the cache's leaves it alone, and one started before the extension was updated stops
writing to it, so neither can put older numbers back.

## Tests

The extension's tests only need Node, no packages. They cover the sources' API contracts (over local HTTP fixtures),
freshness, keeping sources separate, the limits on estimates, and how Current model picks a quota. They don't touch
live accounts.

```sh
node --test tests/*.test.mjs
```

Tested with Tern 0.9.28 and omp 19.0.0 on Windows. The quota details with Keeper data were checked against a
redacted Keeper quota-cache replay on Linux (Tern 0.9.18, omp 18.18.9), not against every CPA quota plugin or a live
deployment.
