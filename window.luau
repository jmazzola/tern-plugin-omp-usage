--!strict
-- Shows what omp's `usage-remaining` extension (omp/extensions/usage-remaining.js in this repo) reports, as one
-- line above the composer's context hairline (the `1% ──── 1M` row).
--
-- The extension stays the source of truth: it picks the active model's provider, its applicable windows,
-- saved resets and countdowns. It sets that line with `ctx.ui.setStatus`, which omp draws in the composer bar's
-- extras, and after every fetch it also writes ~/.omp/cache/usage-remaining.json: every model's line keyed by
-- the name omp's model chip shows, every provider's plan-wide line, and the saved resets' expiry dates. This
-- plugin reads both from the focused agent pane and draws the line with CSS above the hairline's meter,
-- rewritten with `tern.css` when it changes. Other `ctx.ui.setStatus` parts are drawn there too, except the
-- `◫ …` context gauge (context-used.js), which the hairline already shows. The rest of omp's status line (path,
-- git, cost, …) stays in the bar; only the facts the line redraws are hidden there, in the focused pane.
--
-- What the line shows depends on the mode (kept in `tern.kv`, set from the settings panel or the `omp Usage:
-- Settings…` picker): the focused agent's provider (`current`), every provider in the cache (`all`) or the
-- chosen ones (`selected`), in the user's order. `current` shows the line the cache holds for the model chip's
-- name: every omp session fetches on its own clock, and one started before an update keeps running the old code,
-- so their statuses can disagree (one pane `Fable 7d 57%`, another `56%`), while the cache holds the newest fetch
-- any up-to-date session made, the same for every pane. That also covers a viewed subagent's transcript (omp adds
-- a `Viewing <agent>` row to the composer and its model chip shows the subagent's model, but the status stays the
-- main session's). Without a fresh cache, or an entry for the chip, every mode falls back to the status. A
-- provider signed in with several accounts shows all of them, in the user's order, or only the one chosen for it
-- (see `account_view`); the card then sums up the others.
--
-- The line is an instrument strip: per provider its label, then per window its label, a slim bar filled to the
-- share left with a lit tip, the share and its reset countdown, then saved resets; other statuses last. Each
-- provider has its colors (a preset, or the user's choice), one for its label and one or two for its bars;
-- a window at 25% or less turns `--warn`, at 10% or less `--bad`. It is the meter's `::before`: 10px mono,
-- whose glyphs are all 0.6em wide, so one static gradient clipped to the text colors each part and fills each
-- bar to the exact share (Tern draws one `background-clip: text` layer per element, and doesn't repaint it when
-- its position animates, so nothing in it moves). A window's parts are joined by no-break spaces, so in a
-- narrow pane a window that doesn't fit wraps, whole, onto a second line the 13px box cuts off; its tip, on the
-- meter's `::after`, is sized to nothing past the box's width, so it goes too.
--
-- Hovering the line lifts it into a glass capsule at full strength and, after a beat, opens a card above it with
-- the facts spelled out: a row and a meter per window, with its reset countdown and clock time, each saved
-- reset's expiry date, and other statuses. Tern draws its own tooltips from `title` attributes, which a plugin
-- can't set on omp's nodes, and it shows the nearest `title` up the tree, so neither can hang off the meter
-- (its context tooltip would show too). The hover target is the composer's attachment-chips row instead: empty
-- and hidden unless something is attached, untitled all the way up, and a direct child of the composer like the
-- meter, so it can be laid over the line with the meter's own offsets. While attachments show, the target is the
-- first chip's end slot, as empty, hidden and untitled up the tree; the row stops clipping it and the chip stops
-- being its containing block, so it lies over the line with the same offsets, and hovering the chip doesn't count.
--
-- When a window's share changes (a window is its provider and its label, so switching providers or modes
-- doesn't count), the line prints again, left to right, while a comet runs each changed bar to its new level
-- and settles into its tip: in the provider's color when quota went down, `--ok` when it came back. Nothing
-- moves at rest, and Reduce Motion (either Tern's or the system's) drops every fade, rise and sweep.

-- Update checks for this copy (a linked clone or an installed one), and the prompt that offers them (update.luau).
local update = require("./update")

-- Re-reads the composer dock (~40 nodes) every second, and the cache's text (a few KB, decoded only when it
-- changed) as `poll_cache` last fetched it. The usage-remaining extension redraws within a second of a model
-- switch, so this follows it within about two.
local POLL_MS = 1000
local detail_view = require("./details")
-- What the line shows (data.luau) and how it is drawn (render.luau); the settings pickers and the settings panel.
local data = require("./data")
local render = require("./render")
local pickers = require("./pickers")
local panel = require("./panel")

type Cache = data.Cache
type Dock = data.Dock
type Pulse = render.Pulse
type Settings = data.Settings

local KV_MODE = data.KV_MODE
local KV_CARD_ROWS = data.KV_CARD_ROWS
local CARD_ROWS = data.CARD_ROWS
local now_ms = data.now_ms
local read_dock = data.read_dock
local read_cache = data.read_cache
local store = data.store
local load_settings = data.load_settings
local build_model = data.build_model
local shares = data.shares
local changes = data.changes
local colors_key = data.colors_key
local NO_DOCK = data.NO_DOCK
local cache_seen = data.cache_seen
local PULSE_MS = render.PULSE_MS
local CARD_ROW = render.CARD_ROW
local FOCUSED_PANE = render.FOCUSED_PANE
local line_pane = render.line_pane
local set_line_pane = render.set_line_pane
local palette_css = render.palette_css
local card = render.card
local sheet = render.sheet
local hide_css = render.hide_css
local install = render.install
local PANEL_KEYS = render.PANEL_KEYS
local DETAILS_ACTION = render.DETAILS_ACTION
local shortcut = render.shortcut
local settings_hint = render.settings_hint
local providers_in_order = pickers.providers_in_order
local menu_items = pickers.menu_items
local after_change = pickers.after_change
local open_chooser = pickers.open_chooser
local open_reorder = pickers.open_reorder
local open_colors = pickers.open_colors
local open_windows = pickers.open_windows
local open_accounts = pickers.open_accounts
local panel_pane = panel.pane
local sync_panel = panel.sync_panel
local flush_panel = panel.flush_panel
local open_panel = panel.open_panel

local shown_pane: number? = nil
-- pane -> where its line came from and each window's share, by provider and window
local last_seen: { [number]: { source: string, values: { [string]: number } } } = {}
local pulse: Pulse? = nil
local pulse_seq = 0

-- What redraws the quota details (with the commands, below), and the dock `show_pane` last read, which the
-- panel's preview of the line and the details are drawn from.
local sync_details: (cx: WindowCx, open: boolean, settings: Settings?, cache: Cache?) -> ()
local last_dock: Dock? = nil

local refresh: (cx: WindowCx) -> ()
-- What the installed sheet was built from (see `show_pane`).
local sheet_key: string? = nil

-- Draws the line of an agent pane's composer. Most polls change nothing it draws, and then the sheet isn't built
-- again: a slow call trips the window's 50 ms budget, which turns off every timer of the plugin until a reload.
local function show_pane(cx: WindowCx, pane: number, settings: Settings, cache: Cache?)
	local dock = read_dock(cx, pane)
	local model = build_model(settings, dock, cache)
	local values = shares(model)
	if pane ~= shown_pane then
		shown_pane = pane
		pulse = nil -- another pane's line: nothing changed, it is only shown
	else
		-- Another source (a mode, a viewed subagent's model, the status) shows other numbers, not a change in these.
		local before = last_seen[pane]
		local moved = if before and before.source == model.source then changes(before.values, values) else nil
		if moved then
			pulse_seq += 1 -- a new keyframes name restarts the animation
			pulse = { seq = pulse_seq, until_ms = tern.now() + PULSE_MS, moved = moved }
			-- drop the animation once it has run, so later rewrites don't carry it
			tern.timer(PULSE_MS + 50, function(later: WindowCx?)
				if later then
					refresh(later)
				end
			end)
		elseif before == nil or before.source ~= model.source then
			pulse = nil
		end
	end
	last_seen[pane] = { source = model.source, values = values }
	last_dock = dock
	local hint = settings_hint(shortcut(cx))
	local running = if pulse and tern.now() < pulse.until_ms then pulse.seq else 0
	local hidden = table.concat(dock.hide, "\n")
	local key = table.concat({ model.signature, colors_key(settings), hint, tostring(running), hidden, line_pane() }, "\n")
	if key ~= sheet_key then
		sheet_key = key
		install(hide_css(dock.hide) .. sheet(model, settings, pulse, hint))
	end
end

-- An agent pane for the panel to preview when none has shown its line yet (after a reload): one in the panel's
-- tab, else any.
local function some_agent(cx: WindowCx, tab: number?): number?
	local found: number? = nil
	for _, info in cx.session:panes() do
		if info.kind == "agent" then
			if info.tab == tab then
				return info.pane
			end
			found = found or info.pane
		end
	end
	return found
end

-- The agent panes in tab `tab`.
local function agents_in(cx: WindowCx, tab: number?): { number }
	local found: { number } = {}
	for _, info in cx.session:panes() do
		if info.kind == "agent" and info.tab == tab then
			table.insert(found, info.pane)
		end
	end
	return found
end

-- Shows the focused agent's usage; a focused non-agent pane keeps the last line (no composer shows it there),
-- but while the settings panel has focus the line it last showed follows the settings, for the panel's preview,
-- and is drawn on the agent pane beside the panel when that is its tab's only one (see `line_pane`).
-- Then redraws the panel if what it shows changed.
refresh = function(cx: WindowCx)
	local target: number? = nil
	local scope = FOCUSED_PANE
	local pane = cx.session:focused()
	if pane ~= nil then
		local info = cx.session:pane(pane)
		if info and info.kind == "agent" then
			target = pane
		elseif info and (pane == panel_pane() or pane == detail_view.pane) then
			target = shown_pane or some_agent(cx, info.tab)
			local beside = agents_in(cx, info.tab)
			if #beside == 1 and beside[1] == target then
				scope = ".tn-pane.agent"
			end
		end
	end
	if scope ~= line_pane() and target == nil then
		target = shown_pane -- redraw the last line in its usual place, the focused pane
	end
	set_line_pane(scope)
	if target == nil and panel_pane() == nil and detail_view.pane == nil then
		return
	end
	local settings = load_settings()
	local raw = cache_seen()
	local cache = read_cache(now_ms())
	if target ~= nil then
		show_pane(cx, target :: number, settings, cache)
	end
	-- A poll that just decoded a rewritten cache (the extension's, once a minute; tens of ms for a big one) has
	-- spent much of its timer's 50ms: the panel's redraw waits for the next poll.
	if panel_pane() ~= nil and cache_seen() == raw then
		sync_panel(cx, false, settings, cache)
	end
	if detail_view.pane ~= nil and cache_seen() == raw then
		sync_details(cx, false, settings, cache)
	end
end

-- A change from the pickers or the panel redraws through `refresh` and the panel; the panel previews the dock
-- `show_pane` last read.
pickers.init(refresh, flush_panel)
panel.init(function(): Dock?
	return last_dock
end)

local function tick(cx: WindowCx?)
	if cx then
		refresh(cx)
	end
	tern.timer(POLL_MS, tick)
end

tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	refresh(cx)
end)

-- the first poll waits out the reload's own work
tern.timer(300, tick)

-- Settings, two ways: the panel (a canvas beside the focused pane: `omp Usage: Settings panel`,
-- Ctrl+Alt+U) and pickers (`omp Usage: Settings…`). Native quota details open from `usage` (Plugin segments),
-- Shift+Alt+U or `omp Usage: Quota details`.
-- Both settings views store choices in `tern.kv` and redraw the line at once.

-- The details canvas follows the same selected sources and last agent as the preview. Its scrollable body
-- is not subject to the hover's row budget.
sync_details = function(cx: WindowCx, open: boolean, settings: Settings?, cache: Cache?)
	local current = settings or load_settings()
	local source = if settings then cache else read_cache(now_ms())
	local model = build_model(current, last_dock or NO_DOCK, source)
	local signature = model.signature .. "\n" .. colors_key(current)
	if not open and signature == detail_view.signature then return end
	detail_view.show(
		cx, card(model, "", current.card_rows, "details"),
		palette_css(model, current, detail_view.selector), signature, open
	)
end

-- A reload finds the quota details Tern kept, and draws them, once the first poll is done.
tern.timer(600, function(cx: WindowCx?)
	if cx then
		detail_view.restore(cx)
		if detail_view.pane then
			sync_details(cx, false)
		end
	end
end)

-- How often the automatic update check runs, as a picker.
local function open_intervals(cx: WindowCx)
	local current = update.interval()
	local items: { PickItem } = {}
	for _, interval in update.INTERVALS do
		table.insert(items, { label = interval.label, current = interval.id == current.id, every = interval.id })
	end
	cx:pick({ items = items, placeholder = "Check for omp Usage updates how often?", icon = "download" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item then
				update.set_interval(next_cx or cx, (item :: any).every)
				after_change(next_cx or cx)
			end
		end)
end

local function open_menu(cx: WindowCx)
	local settings = load_settings()
	cx:pick({ items = menu_items(settings, providers_in_order(settings), shortcut(cx)), placeholder = "omp Usage", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local choice = item :: any
			local cx2 = next_cx or cx
			if choice.pick == "panel" then
				open_panel(cx2)
			elseif choice.pick == "mode" then
				if choice.mode == "selected" and #settings.selected == 0 then
					open_chooser(cx2)
					return
				end
				store.set(KV_MODE, choice.mode)
				after_change(cx2)
			elseif choice.pick == "choose" then
				open_chooser(cx2)
			elseif choice.pick == "reorder" then
				open_reorder(cx2)
			elseif choice.pick == "colors" then
				open_colors(cx2)
			elseif choice.pick == "windows" then
				open_windows(cx2)
			elseif choice.pick == "accounts" then
				open_accounts(cx2)
			elseif choice.pick == "card-rows" then
				local items: { PickItem } = {}
				for _, rows in CARD_ROWS do
					table.insert(items, { label = string.format("%d rows", rows), detail = string.format("about %dpx", rows * CARD_ROW + 14), current = rows == settings.card_rows, rows = rows })
				end
				cx2:pick({ items = items, placeholder = "How many rows may the card take? Past it, accounts sum up, then fold", icon = "gauge" })
					:next(function(picked: PickItem?, _err2: string?, last_cx: WindowCx?)
						if picked then
							store.set(KV_CARD_ROWS, (picked :: any).rows)
							after_change(last_cx or cx2)
						end
					end)
			elseif choice.pick == "update" then
				update.check(cx2, true)
			elseif choice.pick == "update-every" then
				open_intervals(cx2)
			end
		end)
end

tern.command({
	id = "details",
	title = "omp Usage: Quota details",
	icon = "gauge",
	keys = { "shift+alt+u" },
	run = function(cx: WindowCx)
		refresh(cx)
		sync_details(cx, true)
	end,
})

tern.command({
	id = "panel",
	title = "omp Usage: Settings panel",
	icon = "sliders",
	keys = { PANEL_KEYS },
	run = open_panel,
})

tern.command({
	id = "settings",
	title = "omp Usage: Settings…",
	icon = "gauge",
	run = open_menu,
})

tern.command({
	id = "update",
	title = "omp Usage: Check for updates…",
	icon = "download",
	run = function(cx: WindowCx)
		update.check(cx, true)
	end,
})

-- `usage` in the widget bar's Plugin segments opens the read-only native details.
-- While an update is waiting, Update omp Usage (update.luau) stays first.
local STATUS: { StatusSegment } = { { text = "usage", icon = "gauge", command = DETAILS_ACTION } }

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local pending = update.status_segment()
	if pending == nil then
		return if pane.kind == "agent" then STATUS else nil
	end
	return if pane.kind == "agent" then { pending, STATUS[1] } else { pending }
end)
