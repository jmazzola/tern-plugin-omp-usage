# tern-plugin-omp-usage

Your omp usage limits, just above the omp composer's context bar in [Tern](https://stencil.so/tern) (in the Spine
chat style, just below it, on the composer's column):

![The usage line above the omp composer: Claude's 5-hour, 7-day and Fable 7-day windows with bars, share left, reset countdowns, a saved reset (+1) and two Fable resets (+2F)](docs/images/line-current.png)

Hover it for each window's meter, reset time and saved resets:

![The hover card: Claude's 5-hour, weekly and Fable weekly windows with meters and reset times, a saved reset under the weekly window and two Fable resets under the Fable window](docs/images/card-current.png)

- **Follows your model.** Shows the active model's provider (anything `omp usage` reports: Claude, Codex, Kimi,
  Gemini, Muse Code, …) and switches within ~2 s of Alt+P, or to a subagent's model while you view its transcript.
  New providers and windows show up without changes here.
- **Or every provider**, or the ones you pick, in your order.
- **Several accounts** for one provider each get their windows, labeled with the account's email name (`alice 7d`,
  `bob 5h`). Hide any of them in the panel to fit the line.
- **Reads at a glance.** Each window gets a bar in its provider's colors, amber at ≤25% left, red at ≤10%. When a
  share changes, a comet runs the bar to its new level. Saved resets show as `+N` (`+NF` for Claude's Fable resets).
- **Settings panel** (Ctrl+Alt+U) for what shows, the order, each provider's windows and colors.
- **Updates itself** like Tern does: an **Update omp Usage** pill in the status line, one click to see what's new
  and install it. Nothing pops up over your work.

![The update card: omp Usage 0.3.0 is available, You have 0.2.0 · 6 new commits, What's new with each commit's full message, and Download Update, Skip This Version and Not Now](docs/images/update-card.png)

| Part | What it does |
| --- | --- |
| `omp/extensions/usage-remaining.js` | omp extension: fetches `omp usage --json`, sets the line as an extension status, and caches every model's and provider's line. |
| `omp-usage/` | Tern plugin: draws the line above the context bar, hides the statuses it redraws from omp's bar (keeping the session cost), and adds the settings panel and updates. |

Tested with Tern 0.9.14 and omp 18.18.6 on Windows.

## Install

You need Tern with plugins on (Preferences › Plugins) and omp signed in to an account with limits (`omp usage`
should list them). Use forward slashes in paths, even on Windows.

1. **Clone** to a folder you'll keep; Tern and omp load the files from there:

   ```sh
   git clone https://github.com/jmazzola/tern-plugin-omp-usage.git
   cd tern-plugin-omp-usage
   ```

2. **Link the plugin.** `tern plugin list` should show `omp-usage … ready`; Tern loads it on every launch.

   ```sh
   tern plugin link ./omp-usage
   tern plugin list
   ```

3. **Load the extension** in `~/.omp/agent/config.yml`, with your clone's path:

   ```yaml
   extensions:
     - C:/Users/you/tern-plugin-omp-usage/omp/extensions/usage-remaining.js
   ```

4. **Show extension statuses** in omp's bar, where the plugin reads the line. Either:

   ```yaml
   statusLine:
     showHookStatus: true
   ```

   or, with `preset: custom`, add `status` to `leftSegments`.

5. **Restart omp sessions.** Click into an omp pane and the line appears above `1% ──── 1M` (below it in Spine)
   within seconds.

## Settings

Open the panel with **Ctrl+Alt+U** (rebind `plugin.omp-usage.panel`), **usage** in the status bar, or **omp Usage:
Settings panel** in the palette. Changes apply at once, in every window.

| Section | What it does |
| --- | --- |
| Line | Previews the line for the last omp pane you used |
| Show | **Current model** (default), **All providers** (countdowns move to the card), or **Selected providers** |
| Providers | Click a window to hide or show it everywhere; the switch adds the provider to Selected; arrows and **top** reorder |
| Colors | A preset, a named alternative (Ember, Sunset, Moss, Ocean, Orchid, Slate, Theme accent), or **Custom…** hex colors (`#d97757`, or two: `#9aa7b4, #5b8def`) |
| Updates | Status, **Check for Updates** or **Download Update**, and how often to check (see [Update](#update)) |

![The settings panel: a line preview, the Show choices, providers with their window toggles (Claude's 5H hidden and struck through), switches and move buttons, and color swatches](docs/images/settings-panel.png)

**omp Usage: Settings…** in the palette offers the same as keyboard menus.

**All providers**, one after another; Muse Code's 5-hour window has turned amber:

![All providers: Claude, Codex and Muse on one line, with a card listing each provider's windows and saved resets](docs/images/card-all.png)

**Selected providers**, here Codex and Muse while an Opus model is in use:

![Selected providers: Codex's weekly window and Muse's 5-hour window on the line](docs/images/line-selected.png)

**Colors**: Claude on Sunset, Codex on a custom `#22d3ee, #a78bfa`:

![Custom colors: Claude in a red-orange gradient and Codex in cyan to violet, on the line and in the card](docs/images/card-colors.png)

**Two Claude accounts**, alice and bob: the line fits alice's windows, the card has both, each with its own saved
resets:

![Two Claude accounts: the card lists alice's weekly and Fable weekly windows and bob's 5-hour, weekly and Fable weekly windows, each with its resets](docs/images/card-accounts.png)

The extension caches every line in `~/.omp/cache/usage-remaining.json`. All and Selected providers, subagent
models and the card's reset dates read it; a cache older than 10 minutes is ignored.

## Update

The plugin checks your clone's remote every 6 hours (Hourly, Daily, Weekly or Off in the panel). When there's a new
version, a toast says so once and an **Update omp Usage** pill sits in the status line until you deal with it:

![The settings panel's Updates section, omp Usage 0.3.0 is available, You have 0.2.0, with Download Update and What's New, and the Update omp Usage pill at the right of the status line](docs/images/update-status.png)

Click it (or **Check for Updates**) for the update card shown at the top: the version available, the one you have,
and every new commit in full.

| Button | What it does |
| --- | --- |
| **Download Update** | Fast-forwards the clone and reloads the plugin; the toast says if omp sessions need a restart |
| **Skip This Version** | Hides the pill until a newer plugin change |
| **Not Now** / Esc | Closes the card; the pill stays |

Open settings panels step aside while the update lands, so nothing flashes half-drawn:

![Updating omp Usage to 0.3.0, Downloading the update and reloading the plugin, then the toast omp Usage updated to 0.3.0](docs/images/update-landing.png)

- Only commits that change `omp-usage/` or `omp/` count; README-only pushes don't light the pill and come along with
  the next real update.
- It never merges or rebases your work. With local commits, or edits in the way, update by hand:
  `git pull`, then `tern plugin reload`.

## Turn it off

| To | Do |
| --- | --- |
| Turn the plugin off | `tern plugin unlink omp-usage`, or Preferences › Plugins |
| Turn it back on | `tern plugin link ./omp-usage` from the repo folder |
| Remove the extension | Delete its line from `~/.omp/agent/config.yml`, then restart omp |

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `tern plugin list` isn't `ready` | It prints the error; Tern's log is `%LOCALAPPDATA%\Tern\Logs\tern.log` |
| No line | Focused pane is omp; its provider has limits; omp restarted after install; extension statuses on (step 4) |
| All/Selected show only the current model | The cache is stale: restart omp sessions |
| Ctrl+Alt+U does nothing | Another binding took it; bind `plugin.omp-usage.panel` to another chord |
| Line stopped after an omp or Tern update | omp may have renamed what the plugin reads: ask omp to fix `omp-usage` |
| No update pill | Turn Tern's status bar on, or use the panel's Updates section; checks may be Off |
| `omp Usage can't check for updates` | Needs a git clone tracking a remote, and git on `PATH`; the toast shows git's reason |
| Edits to `window.luau` don't show | `tern plugin reload` |

Don't edit Tern's `settings.json` from PowerShell: it adds a BOM and Tern falls back to defaults.
