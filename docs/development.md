# How omp Usage works

To work on it, link a clone (see [From a clone](../README.md#from-a-clone)).

| Part | What it does |
| --- | --- |
| `omp/extensions/usage-remaining.js` | The omp extension. Fetches omp's usage and the configured sources' quotas, sets the line as an extension status, and caches every model's and provider's line and details. `omp/package.json` names it, so `omp plugin link` loads the `omp/` folder as omp's plugin `omp-usage` |
| `omp/extensions/usage-sources/` | The CLIProxyAPI and Keeper clients, the sources file, freshness, and the amounts and estimates |
| `plugin.toml`, `bar.css` | The Tern plugin's manifest, and the style sheet for the Update omp Usage pill, the widget bar's gauge and omp's bar |
| `window.luau` | The Tern plugin's entry point. Polls the focused omp pane, draws its line, and registers the commands and the widget bar's segment (a gauge, with a warning while a window runs ahead of its pace) |
| `data.luau` | What the views draw from: the cache, the settings in `tern.kv`, the providers and their colors, and omp's composer as read from a pane |
| `render.luau` | The line, its comets and its card, as CSS |
| `pickers.luau`, `panel.luau` | The settings: the palette's pickers and the settings panel |
| `details.luau` | The quota details |
| `alerts.luau` | Alerts: a toast when a window falls to 25%, 10% or 0% left or a saved reset is about to expire, said once across every Tern window |
| `update.luau` | Update checks, the update card, and installing updates |
| `extension.luau` | Linking the omp extension into omp's plugins, for an installed copy |

Each `.luau` file is its own Luau chunk, and a chunk can only hold 200 locals at once (constants don't count). Go
over that and Tern refuses to load the plugin, with nothing but a warning in its log to show for it. A feature that
needs a lot of top-level locals gets a file of its own.

## The cache

The extension caches every line in `~/.omp/cache/usage-remaining.json`. Current model, All and Selected providers,
subagent models, accounts, the card's reset times, pace, the widget bar and alerts all read from it.

How old the numbers are goes by each entry's `observedAt`: when omp actually fetched them. omp answers `omp usage`
from its own cache, refreshing each account about every 5 minutes, and keeps serving the last good report for up to
a day when the provider can't be reached, so a fetch that succeeds doesn't mean new numbers; `observedAt` comes from
omp's own fetch time, and a fetch that fails doesn't move it. Numbers more than 10 minutes past `observedAt` are drawn
faded with their age (`as of 21m ago`); past 30 minutes they aren't drawn at all, and the line falls back to the
focused session's own status (as it does for a pane over SSH or in WSL, whose omp writes no cache here). Pace is
worked out at `observedAt` too, and reset times come from the windows' `resetsAt`, so neither drifts as the numbers
age.

`generatedAt` is a heartbeat, not a freshness stamp: every running session rewrites the file every 2 minutes even
when nothing changed, so it says a session is alive. A file whose heartbeat is more than 30 minutes old (no session
left writing it) is ignored as a whole. `fetchedAt` says when the newest successful `omp usage` run that any session
wrote started.

Every omp session writes the newest numbers it fetched there, which is why every pane shows the same ones. A session
whose numbers are older than the cache's leaves it alone, and one started before the extension was updated stops
writing to it, so neither can put older numbers back. Each session runs one `omp usage` at a time, at most one every
20 seconds, and skips it when another session fetched in the last 30 seconds.

A model's entry holds only what differs from its provider's entry (a Fable model's order, a Spark model's own
window), and points at the provider's windows, saved resets and details for the rest. That keeps 32 accounts and
220 models at about 560 KB instead of 15 MB; the plugin reads up to 1 MiB. A cache that would still pass 900 KB is
written without the details, then without the windows too (the lines stay), and omp's log says so once a session.
Plugin copies up to 0.7.10 don't know this layout: they skip those model entries, so Current model shows the
session's own status there, while All and Selected providers read as before, minus the windows only some models
have (such as Codex Spark 5h), which they took from the model entries.

Two models that share a chip name but not their numbers (the same name under two providers) get `null` under the
bare name and their entries under `<provider>/<chip name>`, so the plugin never draws one's numbers for the other. A
file over 1 MiB isn't read at all: the line keeps its last numbers and says `usage cache too big to read (1.1 MB)`.

## Tests

The extension's tests only need Node 22 or newer, no packages (`npm install` has nothing to install). They cover the
sources' API contracts (over local HTTP fixtures), freshness, keeping sources separate, the limits on estimates, and
how Current model picks a quota. They don't touch live accounts.

```sh
npm test
```

That runs `node --test "tests/*.test.mjs"`; to run one file, pass it to `node --test` directly. The root
`package.json` holds only this script and `test:luau` (below): Tern loads the plugin from `plugin.toml` and omp loads
the extension from `omp/package.json`, so neither reads it.

GitHub Actions runs the same tests on Node 22 on Ubuntu and Windows for every push and pull request
(`.github/workflows/ci.yml`). The Luau half's tests (below) need the Luau CLI, and the smoke matrix Tern itself, so CI
doesn't run them yet.

Tested with Tern 0.9.31 and omp 19.1.1 on Windows. The quota details with Keeper data were checked against a
redacted Keeper quota-cache replay on Linux (Tern 0.9.18, omp 18.18.9), not against every CPA quota plugin or a live
deployment.

### Luau tests

They test the Luau half without Tern: parsing the extension's line, combining accounts, moving providers, custom
colors, pace and freshness; the line's model from fixture caches (fresh, old, stale, passed resets, reset times,
first-version and compact caches, a cache too big or unreadable, Zai and Zai Coding Plan, remote and WSL panes);
alert candidates and the alerts across two windows; the line, the widget segment and the hidden status facts as a
window draws them; and a linked clone's Download Update.

They need the Luau CLI, `luau`, from the [Luau releases](https://github.com/luau-lang/luau/releases)
(`luau-windows.zip`, `luau-ubuntu.zip` or `luau-macos.zip`). Put it on PATH, or set `LUAU` to it.

```sh
node tests/luau/run.mjs            # every case
node tests/luau/run.mjs combined   # the cases whose name has that text
```

The Luau CLI can't read files, so `tests/luau/run.mjs` writes the plugin's `.luau` files into a temp folder as
strings (`sources.luau`), with the tests, and runs `run.luau` there. `harness.luau` loads them into a simulated
window, a "world":

- a `tern` stand-in: timers on a clock the test moves, a `tern.kv` several windows can share (optionally seeing each
  other's writes late), and a `tern.json` whose arrays carry the protected metatable Tern's do;
- `os.time` on that clock;
- a `cx` whose `docs:read` returns the cache the test sets, and whose panes, surfaces and hosts the test describes.

A test reaches a file's local functions through `expose`: they're added to its return value as `__test` when it
loads, and the file itself doesn't change. `release = "v0.7.10"` loads the last release's reader from git, for what
copies that haven't updated make of today's cache.

A case written as `T.defect("D-…", …)` pins a defect from QA's report. It fails until the defect is fixed, and the
run lists it as known and still passes; once it passes, the run fails until the case becomes a plain `it`. Each
spec file ends with `return true`: the Luau CLI's `require` hands back a file that doesn't compile as an error
string instead of raising it, so `run.mjs` checks for it.

### Smoke matrix (headless Tern)

`tests/smoke/matrix.mjs` drives a headless Tern (`tern.com serve`, `tern.com ctl`) with a real omp in an agent pane
and fixture caches. It checks freshness (fresh, 10 minutes, 30 minutes, back), reset times across cache age, passed
resets, Show pace, card height, a combined pool with a stale seat, Zai and Zai Coding Plan, a first-version and an
oversize cache, the widget segment, light and dark, Reduce Motion, a short pane, a model switch, the usage status in
unfocused panes, alerts with two windows open, and a pane on another host (`ctl remote loopback`).
`tests/smoke/updater.mjs` checks a linked clone's Download Update when Tern reloads the plugin during the
fast-forward, and a pending update the clone already has. For an installed copy, it checks Download Update and that it
drops the old `omp-usage/` folder, an update cut off before staging with three windows loading (also setting up the omp
extension once), and one cut off while copying in. Each window has an omp pane whose overlay sets a status every
250 ms: a headless window runs plugin timers only when something in it changes.

```sh
node tests/smoke/matrix.mjs [OUT_DIR] [--only freshness,widget]
node tests/smoke/updater.mjs [OUT_DIR] [--only clone,install,resume,staged]
```

They need Windows, `tern.com` on PATH, Tern's own omp with an account signed in (the omp pane uses it, read only),
Git, and, for cropped shots, Python with Pillow. The matrix takes about 13 minutes, the updater checks about 6.
`OUT_DIR/results.md` (or `updater.md`) says PASS or FAIL per check, with what was seen; the shots are in
`OUT_DIR/profile/shots/serve`. Light and dark, Reduce Motion (two shots frozen 250 ms into a change) and the short
pane are judged by eye.

They write only to `OUT_DIR`:

- Tern runs with its config, local data, home and fixtures there, and loads a snapshot of the plugin as a fixture,
  with update checks off. The snapshot's `render.luau` gets a marked scaffold that writes each sheet it installs to
  the plugin's data folder: a pseudo-element's text isn't in `ctl tree`, so that's how the matrix reads the line and
  the card.
- omp runs through a wrapper with a home of its own there, so no extension writes the cache the plugin reads, or
  yours. Its only extension is the overlay's, which sets a usage-shaped status the test controls.
- The updater checks use temp repositories, and a fake `omp`, built with the .NET Framework's `csc.exe` (part of
  Windows), first on PATH for the installed copies.
- No shot shows the computer's name: the host segment is hidden, and a shot whose layout names the computer is
  deleted.
