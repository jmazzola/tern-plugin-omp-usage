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
-- That is the line as it comes. The panel's Display section (data.luau's PARTS, STYLES, PLACES; render.luau's
-- `line_of`) changes how it looks and where it sits: its windows drawn as blocks, a dial or text alone; the line
-- under the hairline in every chat style, or stacked, a row per window, over the meter's right or left end; any of
-- its parts left off; and shares said as used instead of left (the card and the quota details follow).
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
local PANEL_ACTION = render.PANEL_ACTION
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

-- The agent pane whose line was drawn last (cleared when it closes, see `pane_closed`).
local shown_pane: number? = nil
-- pane -> where its line came from and each window's share, by provider and window
local last_seen: { [number]: { source: string, values: { [string]: number } } } = {}
local pulse: Pulse? = nil
local pulse_seq = 0
-- The widget bar's segment: the pace warning `show_pane` last drew (nil: no window runs ahead, the icon alone).
local warning: string? = nil
local set_warning: (text: string?) -> ()

-- What redraws the quota details (with the commands, below), and the dock `show_pane` last read, which the
-- panel's preview of the line and the details are drawn from.
local sync_details: (cx: WindowCx, open: boolean, settings: Settings?, cache: Cache?) -> ()
local last_dock: Dock? = nil
local refresh: (cx: WindowCx) -> ()
local sync_status: () -> ()
-- What the installed sheet was built from (see `show_pane`).
local sheet_key: string? = nil

-- A line's pace warning, for the widget bar: `Claude 1.4× pace` for its window running furthest ahead (data.luau's
-- `furthest_ahead`, which follows Show pace). Nil while none does. Tern's own usage widgets show each provider's
-- share and reset, so the segment says only this.
local function warning_of(model: data.Model): string?
	local found = data.furthest_ahead(model)
	if found == nil then
		return nil
	end
	local pace = string.format("%.1f× pace", found.pace.ratio)
	return if found.provider_label == "" then pace else found.provider_label .. " " .. pace
end

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
	set_warning(warning_of(model))
	local hint = settings_hint(shortcut(cx))
	local running = if pulse and tern.now() < pulse.until_ms then pulse.seq else 0
	-- the facts the line redraws (with Other statuses off, only the extension's own: the rest stay in omp's bar)
	local redrawn = data.redrawn_facts(dock, settings)
	local hidden = table.concat(redrawn, "\n")
	local key = table.concat({ model.signature, colors_key(settings), settings.backdrop, tostring(settings.card_rows), settings.pace, data.display_key(settings), hint, tostring(running), hidden, line_pane() }, "\n")
	if key ~= sheet_key then
		sheet_key = key
		install(hide_css(redrawn) .. sheet(model, settings, pulse, hint))
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

-- The agent pane the line was last drawn from, while it is still open and still an agent; else nil (and forgotten).
local function live_shown(cx: WindowCx): number?
	local pane = shown_pane
	if pane == nil then
		return nil
	end
	local info = cx.session:pane(pane)
	if info and info.kind == "agent" then
		return pane
	end
	shown_pane, last_dock = nil, nil
	return nil
end

-- Shows the focused agent's usage; a focused non-agent pane keeps the last line (no composer shows it there),
-- but while the settings panel has focus the line it last showed follows the settings, for the panel's preview,
-- and is drawn on the agent pane beside the panel when that is its tab's only one (see `line_pane`).
-- Then redraws the panel if what it shows changed.
refresh = function(cx: WindowCx)
	sync_status()
	local target: number? = nil
	local scope = FOCUSED_PANE
	local pane = cx.session:focused()
	if pane ~= nil then
		local info = cx.session:pane(pane)
		if info and info.kind == "agent" then
			target = pane
		elseif info and (pane == panel_pane() or pane == detail_view.pane) then
			target = live_shown(cx) or some_agent(cx, info.tab)
			local beside = agents_in(cx, info.tab)
			if #beside == 1 and beside[1] == target then
				scope = ".tn-pane.agent"
			end
		end
	end
	if scope ~= line_pane() and target == nil then
		target = live_shown(cx) -- redraw the last line in its usual place, the focused pane
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

-- Opens the quota details: the `details` command, and Quota details in the settings panel.
local function open_details(cx: WindowCx)
	refresh(cx)
	sync_details(cx, true)
end

-- A change from the pickers or the panel redraws through `refresh` and the panel; the panel previews the dock
-- `show_pane` last read, and opens the details.
pickers.init(refresh, flush_panel)
panel.init(function(): Dock?
	return last_dock
end, open_details)

-- The poll re-arms first: an error in `refresh` would otherwise end it for good. Its error is logged at most once a
-- minute, and the next poll tries again.
local last_warn = -math.huge
local function tick(cx: WindowCx?)
	tern.timer(POLL_MS, tick)
	if cx == nil then
		return
	end
	local ok, err: any = pcall(refresh, cx)
	if not ok and tern.now() - last_warn >= 60000 then
		last_warn = tern.now()
		tern.log.warn("omp Usage: the line's poll failed:", err)
	end
end

-- A closed agent pane is no longer the line's source, nor the panel's preview: the next poll picks a live one.
tern.on("pane_closed", function(ev: { pane: number }, _cx: WindowCx)
	last_seen[ev.pane] = nil
	if ev.pane == shown_pane then
		shown_pane, last_dock = nil, nil
		set_warning(nil)
	end
end)

-- The cache is read every few seconds while something shows it (an omp pane, the panel or the details), else
-- seldom (data.luau's `poll_cache`).
data.set_watching(function(cx: WindowCx): boolean
	if panel_pane() ~= nil or detail_view.pane ~= nil then
		return true
	end
	for _, info in cx.session:panes() do
		if info.kind == "agent" then
			return true
		end
	end
	return false
end)

tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
	refresh(cx)
end)

-- the first poll waits out the reload's own work
tern.timer(300, tick)

-- Settings, two ways: the panel (a canvas beside the focused pane: `omp Usage: Settings panel`,
-- Ctrl+Alt+U) and pickers (`omp Usage: Settings…`). Native quota details open from Shift+Alt+U,
-- `omp Usage: Quota details` or the panel's bottom bar. The gauge in Plugin segments opens either, as set.
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
			elseif choice.pick == "plans" then
				pickers.open_plans(cx2)
			elseif choice.pick == "display" then
				pickers.open_display(cx2, choice.kind)
			elseif choice.pick == "parts" then
				pickers.open_parts(cx2)
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
			elseif choice.pick == "usage-opens" then
				pickers.open_usage_opens(cx2)
			elseif choice.pick == "backdrop" then
				local items: { PickItem } = {}
				for _, option in data.BACKDROPS do
					table.insert(items, { label = option.label, detail = option.detail, current = option.id == settings.backdrop, backdrop = option.id })
				end
				cx2:pick({ items = items, placeholder = "What sits behind the line, over the chat scrolling under the composer?", icon = "gauge" })
					:next(function(picked: PickItem?, _err2: string?, last_cx: WindowCx?)
						if picked then
							store.set(data.KV_BACKDROP, (picked :: any).backdrop)
							after_change(last_cx or cx2)
						end
					end)
			elseif choice.pick == "pace" then
				pickers.open_pace(cx2)
			elseif choice.pick == "alerts" then
				pickers.open_alerts(cx2)
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
	run = open_details,
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

-- The widget bar's Plugin segments show a gauge, alone while the focused omp pane's windows keep pace and with a
-- warning (`Claude 1.4× pace`, toned `warn`) while one runs ahead; a click opens the settings panel or the quota
-- details, as set (see data.luau's USAGE_OPENS). Segments must be pure and fast, so it reads what `show_pane` and
-- `sync_status` last saw rather than the cache or `tern.kv`. While an update is waiting, Update omp Usage
-- (update.luau) stays first.
-- Tern draws a segment with an empty text as its icon alone (bar.css centers it in its chip).
local function usage_segment(opens: string, text: string?): { StatusSegment }
	local command = if opens == "details" then DETAILS_ACTION else PANEL_ACTION
	return { { text = text or "", icon = "gauge", tone = if text then "warn" else nil, command = command } }
end
local status_opens = data.usage_opens()
local STATUS = usage_segment(status_opens, nil)

sync_status = function()
	local opens = data.usage_opens()
	if opens ~= status_opens then
		status_opens = opens
		STATUS = usage_segment(opens, warning)
		pcall(tern.chrome.refresh)
	end
end

set_warning = function(text: string?)
	if text ~= warning then
		warning = text
		STATUS = usage_segment(status_opens, text)
		pcall(tern.chrome.refresh)
	end
end

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local pending = update.status_segment()
	if pending == nil then
		return if pane.kind == "agent" then STATUS else nil
	end
	return if pane.kind == "agent" then { pending, STATUS[1] } else { pending }
end)
