# How omp Usage works

To work on it, link a clone: see [From a clone](../README.md#from-a-clone).

| Part | What it does |
| --- | --- |
| `omp/extensions/usage-remaining.js` | omp extension: fetches omp's usage and the configured sources' quotas, sets the line as an extension status, and caches every model's and provider's line and details. `omp/package.json` names it, so `omp plugin link` loads the `omp/` folder as omp's plugin `omp-usage` |
| `omp/extensions/usage-sources/` | The CLIProxyAPI and Keeper clients, the sources file, freshness, and the amounts and estimates |
| `plugin.toml`, `bar.css` | The Tern plugin's manifest, and the style sheet for the Update omp Usage pill and omp's bar |
| `window.luau` | The Tern plugin's entry: polls the focused omp pane, draws its line, and registers the commands and the `usage` segment |
| `data.luau` | What the views draw from: the cache, the settings in `tern.kv`, the providers and their colors, and omp's composer as read from a pane |
| `render.luau` | The line, its comets and its card, as CSS |
| `pickers.luau`, `panel.luau` | The settings: the palette's pickers and the settings panel |
| `details.luau` | The quota details |
| `update.luau` | Update checks, the update card and installing updates |
| `extension.luau` | Linking the omp extension into omp's plugins, for an installed copy |

Each `.luau` file is its own Luau chunk, and a chunk can hold at most 200 locals at once (constants aside): past
that, Tern refuses to load the plugin, with only a warning in its log. Give a feature that needs many top-level
locals a file of its own.

## The cache

The extension caches every line in `~/.omp/cache/usage-remaining.json`. Current model, All and Selected providers,
subagent models, accounts and the card's reset dates read it; a cache older than 10 minutes is ignored, and the line
then shows the focused session's own status. Every omp session writes the newest numbers it fetched there, so every
pane shows the same ones. A session whose numbers are older than the cache's leaves it alone, and one started before
the extension was updated stops writing it, so neither can put back older numbers.

## Tests

The extension's tests need only Node (no packages): they check the sources' API contracts over local HTTP fixtures,
freshness, keeping sources apart, the estimates' limits and Current model's choice of quota, not live accounts.

```sh
node --test tests/*.test.mjs
```

Tested with Tern 0.9.26 and omp 18.22.0 on Windows. The quota details with Keeper data were checked against a
redacted Keeper quota-cache replay on Linux (Tern 0.9.18, omp 18.18.9); not against every CPA quota plugin or a live
deployment.
