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
-- chosen ones (`selected`), in the user's order. While a subagent's transcript is viewed (omp adds a `Viewing
-- <agent>` row to the composer and its model chip shows the subagent's model, but the status stays the main
-- session's), `current` shows the line the cache holds for that chip; otherwise it shows the status, which is
-- fresher. Without a fresh cache every mode falls back to the status. A provider signed in with several accounts
-- shows all of them, in the user's order, or only the one chosen for it (see `account_view`); the card then sums
-- up the others.
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
local SHEET = "usage"
-- omp's composer bar extras: one `hook-N` fact per `ctx.ui.setStatus` key with `statusLine.showHookStatus`,
-- or one `status` fact (all keys joined) with the `status` statusline segment, beside the status line's own
-- segments (branch, git, …). Ids carry a generated prefix (`k.` in omp 18.6, `3.` in 18.7), so they are matched
-- by suffix inside the dock region, whose root id is `dock`. Tern renders each fact as a `.sf-seg` whose
-- `data-id` is the fact's id, which is how the line's facts are hidden in the bar.
local DOCK_ROOT = "dock"
local EXTRAS_SUFFIX = "bar/extras"
local FACT_PATTERNS = { "/status$", "/hook%-%d+$" }
-- In the same tree: the row omp adds while a subagent's transcript is viewed, and the model chip, whose text
-- node (id ending `/name`) is the chip name the cache is keyed by.
local FOCUS_ROLE = "omp.composer.focus"
local MODEL_ROLE = "omp.composer.model"
local NAME_SUFFIX = "/name"
local SEPARATOR = " · " -- omp joins setStatus values with it; usage-remaining joins its windows with it too
local CONTEXT_PREFIX = "◫" -- context-used.js
-- The extension's cache, under the home directory; older than this it is ignored.
local CACHE_FILE = "/.omp/cache/usage-remaining.json"
local CACHE_MAX_BYTES = 1048576
local CACHE_MAX_AGE_MS = 10 * 60 * 1000
-- usage-remaining.js window labels, spelled out in the card.
local WINDOW_NAMES: { [string]: string } = { ["5h"] = "5-hour", ["1d"] = "Daily", ["7d"] = "Weekly", mo = "Monthly" }
local WEEKDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
-- "N% left" at or below these tints a window (and rings the hover capsule).
local WARN_AT = 25
local BAD_AT = 10
-- A saved reset expiring this soon reads `--warn` in the card (the extension flags it with `!` in the line).
local RESET_WARN_MS = 5 * 86400 * 1000
-- How long a change's comets run; a comet for quota that came back is `--ok`, else its bar's color.
local PULSE_MS = 1400
local PULSE_UP = "var(--ok)"

-- The line's geometry. Its 10px var(--mono) is Berkeley Mono: every glyph it uses is 6px wide.
local GLYPH = 6
local NBSP = "\194\160" -- U+00A0, which joins a window's parts so it wraps whole
local BAR = "━"
local BAR_GLYPHS = 8
local COMPACT_BAR_GLYPHS = 6 -- with several providers on the line
local BAR_Y = 7.25 -- px: the bar glyphs' center in the line's 13px box
local TIP_W, TIP_H = 10, 6
-- The comet: its head and trail, and where in the run (0–1) it sets off, arrives and has flared.
local HEAD_W, HEAD_H = 18, 7
local TRAIL_W, TRAIL_H = 34, 2
local RUN_SET, RUN_ARRIVE, RUN_FLARE = 0.05, 0.6, 0.72
local RUN_STOPS = { 0, 0.05, 0.12, 0.2, 0.28, 0.36, 0.44, 0.52, 0.6, 0.66, 0.72, 0.84, 1 }
-- The card: 11px var(--mono) in 18px rows, at least 28 glyphs wide.
local CARD_ROW = 18
local CARD_MIN = 28
local CARD_INDENT = "  "

-- Providers, in the order the line lists them (anything else follows, by label), and the extension's one-word
-- labels for them.
local PROVIDER_ORDER = {
	"anthropic",
	"openai-codex",
	"openai",
	"kimi-code",
	"google-gemini-cli",
	"google-antigravity",
	"minimax-code",
	"opencode-go",
	"alibaba-token-plan",
	"synthetic",
	"devin",
}
local LABEL_IDS: { [string]: string } = {
	Claude = "anthropic",
	Codex = "openai-codex",
	OpenAI = "openai",
	Kimi = "kimi-code",
	Gemini = "google-gemini-cli",
	Antigravity = "google-antigravity",
	MiniMax = "minimax-code",
	Go = "opencode-go",
	Qwen = "alibaba-token-plan",
	Synthetic = "synthetic",
	Devin = "devin",
}
-- A provider's colors: `a` for its label and the start of its bars, `b` (else `a`) for where they end, their
-- tips and its comets. Each is a shade per theme, so it reads on light and dark alike.
type Palette = { name: string, a: string, b: string? }
local PRESETS: { [string]: Palette } = {
	anthropic = { name = "Clay", a = "light-dark(#c15f3c, #d97757)" },
	["openai-codex"] = {
		name = "Graphite to blue",
		a = "light-dark(#6b7785, #9aa7b4)",
		b = "light-dark(#3366d6, #6f9cff)",
	},
	openai = { name = "OpenAI green", a = "light-dark(#0d8a6a, #10a37f)" },
	["kimi-code"] = { name = "Kimi green", a = "light-dark(#3a8a2c, #7dd256)" },
	["google-gemini-cli"] = {
		name = "Blue to white",
		a = "light-dark(#1a66d9, #4f8ff7)",
		b = "light-dark(#7f9fd6, #f4f7ff)",
	},
	["google-antigravity"] = { name = "Antigravity blue", a = "light-dark(#3a58d6, #7390ff)" },
	["minimax-code"] = {
		name = "Red to pink",
		a = "light-dark(#d23f57, #f2576f)",
		b = "light-dark(#c2428e, #ff80c5)",
	},
	["opencode-go"] = { name = "Go cyan", a = "light-dark(#0a8aa1, #2ccde6)" },
	["alibaba-token-plan"] = { name = "Qwen purple", a = "light-dark(#6c4fd0, #a088ff)" },
	devin = { name = "Devin teal", a = "light-dark(#0e8c80, #34c8b6)" },
}
local ACCENT: Palette = { name = "Theme accent", a = "var(--accent)" }
-- The alternatives the settings offer for any provider.
local NAMED: { { key: string, palette: Palette } } = {
	{ key = "ember", palette = { name = "Ember", a = "light-dark(#c2410c, #fb923c)" } },
	{ key = "sunset", palette = { name = "Sunset", a = "light-dark(#c2410c, #fb923c)", b = "light-dark(#be123c, #fb7185)" } },
	{ key = "moss", palette = { name = "Moss", a = "light-dark(#4d7c0f, #a3e635)" } },
	{ key = "ocean", palette = { name = "Ocean", a = "light-dark(#0369a1, #38bdf8)", b = "light-dark(#0e7490, #67e8f9)" } },
	{ key = "orchid", palette = { name = "Orchid", a = "light-dark(#7e22ce, #c084fc)" } },
	{ key = "slate", palette = { name = "Slate", a = "light-dark(#475569, #94a3b8)", b = "light-dark(#1e293b, #e2e8f0)" } },
	{ key = "accent", palette = ACCENT },
}

-- Settings in `tern.kv` (every window shares them, so each refresh reads them again): the mode, the providers
-- `selected` shows, color choices by provider id (`named:<key>`, or one or two `#rrggbb`), the providers'
-- order (ids; providers it doesn't name follow in the preset order) and the windows hidden from the line, by
-- provider id (lowercased window labels: `5h`, `fable 7d`). For a provider with several accounts, by provider
-- id: the one account the line and card show (none: every account shown), the accounts' order (names; accounts it
-- doesn't name follow in omp's order) and the accounts switched off, which the line and card leave out entirely.
local KV_MODE = "omp-usage.mode"
local KV_SELECTED = "omp-usage.selected"
local KV_COLORS = "omp-usage.colors"
local KV_ORDER = "omp-usage.order"
local KV_HIDDEN = "omp-usage.hidden"
local KV_ACCOUNT = "omp-usage.account"
local KV_ACCOUNT_ORDER = "omp-usage.account-order"
local KV_ACCOUNT_HIDDEN = "omp-usage.account-hidden"
-- The card's height limit in rows: one of CARD_ROWS, 26 unless set. Rows are 18px, so 26 rows are a card about
-- 480px tall, which a full-height pane on a 1080p screen holds; the plugin can't see a pane's height, so taller
-- (or split) panes are the user's to set.
local KV_CARD_ROWS = "omp-usage.card-rows"
local CARD_ROWS = { 16, 20, 26, 32, 40, 50 }
local CARD_ROWS_DEFAULT = 26
-- In KV_ACCOUNT, in place of an account's name: show the provider's accounts combined, all in one set of windows
-- (COMBINED), or a set per plan (COMBINED_PLANS: the accounts that report the same windows); each window's share
-- their average (see `combined`).
local COMBINED = "\1combined"
local COMBINED_PLANS = "\1plans"

-- With several accounts, a window's `account` and its label without it (`bare`: `Fable 7d` for `alice Fable
-- 7d`), and `lead` on the first window of each account, where the line and card name the account. Combined (see
-- `combined`), a group's lead window's `plan` is its heading in the card, in place of its name, and a window only
-- some of the group's accounts have says how many in `covers` (`5 of the 10 accounts`), under it in the card.
type Window = {
	label: string,
	pct: number,
	reset: string?,
	saved: number?,
	expires: string?,
	account: string?,
	bare: string?,
	lead: boolean?,
	plan: string?,
	covers: string?,
}
type Reset = { at: number, count: number, window: string? }
-- A provider on the line: its key (provider id when known, else its label), label, windows and saved resets
-- (nil when the cache has none for it); `rest`, while one of its accounts is chosen, the other accounts' windows.
type Group = { key: string, id: string?, label: string, windows: { Window }, resets: { Reset }?, rest: { Window }? }
-- What the line and card show, where it came from (a change counts only between two lines from the same
-- source), and the card's title.
type Model = {
	groups: { Group },
	others: { string },
	source: string,
	title: string,
	signature: string,
}
-- `hide`: the ids of the status facts the line redraws, to hide in the bar.
type Dock = { status: string?, chip: string?, viewing: boolean, hide: { string } }
-- `windows`: every window the provider's accounts report, its plan's and those only some of its models have.
-- `accounts`: with several, their names in omp's order (as the line's labels start); else empty.
type Provider = { id: string, label: string, line: string, resets: { Reset }, windows: { Window }, accounts: { string } }
type Entry = { line: string, resets: { Reset } }
type Cache = { at: number, models: { [string]: Entry }, providers: { Provider }? }
type Settings = {
	mode: string,
	selected: { string },
	colors: { [string]: string },
	order: { string },
	hidden: { [string]: { string } },
	account: { [string]: string },
	account_order: { [string]: { string } },
	account_hidden: { [string]: { string } },
	card_rows: number,
}
-- `moved`: the windows (by provider and label) whose share changed, and which way.
type Pulse = { seq: number, until_ms: number, moved: { [string]: string } }
-- A card row: its text and color and, for a window, the share at its right and its meter's share and colors;
-- `rule` draws a hairline over it.
type Row = { text: string, color: string, right: string?, share: number?, a: string?, b: string?, rule: boolean? }

local last_css: string? = nil
local shown_pane: number? = nil
-- pane -> where its line came from and each window's share, by provider and window
local last_seen: { [number]: { source: string, values: { [string]: number } } } = {}
local pulse: Pulse? = nil
local pulse_seq = 0
-- The card's rows for the last model (see `card`).
local card_for: string? = nil
local card_rows: { Row } = {}
-- For the card `card` last built: how many rows each account shown in full takes, by `<group key>/<account>`
-- (the panel reads it straight after a `fixed = "all"` card, to find the picks that make the tallest card).
local card_runs: { [string]: number } = {}
-- The cache file as last read, its parse, and the last providers it listed (see `read_cache`).
local cache_raw: string? = nil
local cache_parsed: Cache? = nil
local providers_seen: { at: number, list: { Provider } }? = nil

local function now_ms(): number
	return os.time() * 1000
end

local function is_status_fact(id: any): boolean
	if type(id) ~= "string" then
		return false
	end
	for _, pattern in FACT_PATTERNS do
		if string.find(id, pattern) then
			return true
		end
	end
	return false
end

local function fact_text(node: any): string
	local spans = node.p and node.p.spans
	if type(spans) ~= "table" then
		return ""
	end
	local text = ""
	for _, span in ipairs(spans) do
		text ..= tostring(span.t or "")
	end
	return text
end

-- The first node, depth first, that `test` accepts.
local function find_node(node: any, test: (any) -> boolean): any
	if type(node) ~= "table" then
		return nil
	end
	if test(node) then
		return node
	end
	if type(node.c) == "table" then
		for _, child in ipairs(node.c) do
			local found = find_node(child, test)
			if found then
				return found
			end
		end
	end
	return nil
end

local function id_ends(suffix: string): (any) -> boolean
	return function(node: any): boolean
		return type(node.id) == "string" and string.sub(node.id, -#suffix) == suffix
	end
end

local function role_is(role: string): (any) -> boolean
	return function(node: any): boolean
		return type(node.p) == "table" and node.p.role == role
	end
end

-- The status's ` · `-separated parts, without context-used.js's gauge.
local function usage_pieces(status: string): { string }
	local kept: { string } = {}
	local start = 1
	while true do
		local i, j = string.find(status, SEPARATOR, start, true)
		local piece = string.sub(status, start, if i then i - 1 else nil)
		if piece ~= "" and string.sub(piece, 1, #CONTEXT_PREFIX) ~= CONTEXT_PREFIX then
			table.insert(kept, piece)
		end
		if i == nil then
			break
		end
		start = (j :: number) + 1
	end
	return kept
end

local function usage_part(status: string): string
	return table.concat(usage_pieces(status), SEPARATOR)
end

-- From a dock tree (`cx.session:surface`'s answer): the status facts joined, the ones the line redraws, the
-- model chip's name, and whether a subagent's transcript is being viewed.
local function dock_facts(tree: any): Dock
	local dock: Dock = { status = nil, chip = nil, viewing = false, hide = {} }
	if type(tree) ~= "table" then
		return dock
	end
	local function find(test: (any) -> boolean): any
		return find_node(tree.main, test) or find_node(tree.dock, test)
	end
	local extras = find(id_ends(EXTRAS_SUFFIX))
	if extras ~= nil and type(extras.c) == "table" then
		local parts: { string } = {}
		for _, child in ipairs(extras.c) do
			if type(child) == "table" and is_status_fact(child.id) then
				local text = fact_text(child)
				if text ~= "" then
					table.insert(parts, text)
					if #usage_pieces(text) > 0 then
						table.insert(dock.hide, child.id)
					end
				end
			end
		end
		dock.status = table.concat(parts, SEPARATOR)
	end
	local chip = find(role_is(MODEL_ROLE))
	local name = if chip then find_node(chip, id_ends(NAME_SUFFIX)) else nil
	local spans = if name and type(name.p) == "table" then name.p.spans else nil
	local first = if type(spans) == "table" then spans[1] else nil
	if type(first) == "table" and type(first.t) == "string" then
		local text = string.match(first.t, "^%s*(.-)%s*$")
		if text and text ~= "" then
			dock.chip = text
		end
	end
	dock.viewing = find(role_is(FOCUS_ROLE)) ~= nil
	return dock
end

local function read_dock(cx: WindowCx, pane: number): Dock
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { root = DOCK_ROOT })
	end)
	return dock_facts(if ok then tree else nil)
end

-- usage-remaining.js countdowns (`45m`, `2h 11m`, `5h`, `6d 4h`): minutes, and whether they are exact to the
-- minute (past a day the extension drops the minutes); nil for anything else.
local function countdown_minutes(s: string): (number?, boolean)
	if not string.match(s, "^%d+[dhm]") then
		return nil, false
	end
	local d = tonumber(string.match(s, "(%d+)d") or "0") :: number
	local h = tonumber(string.match(s, "(%d+)h") or "0") :: number
	local m = tonumber(string.match(s, "(%d+)m") or "0") :: number
	return d * 1440 + h * 60 + m, d == 0
end

local function clock(t: any): string
	local hour = t.hour % 12
	if hour == 0 then
		hour = 12
	end
	return string.format("%d:%02d %s", hour, t.min, if t.hour < 12 then "AM" else "PM")
end

-- The local time `minutes` from now: `1:12 AM`, `Mon 1:12 AM` past today, `~Mon 3 AM` when only the hour is known.
local function clock_at(minutes: number, exact: boolean): string?
	local now = os.time()
	local at = now + minutes * 60 + (if exact then 0 else 1800)
	local ok_now, today = pcall(os.date, "*t", now)
	local ok_at, t = pcall(os.date, "*t", at)
	if not ok_now or not ok_at or type(today) ~= "table" or type(t) ~= "table" then
		return nil
	end
	local time = if exact then clock(t) else string.format("%d %s", if (t :: any).hour % 12 == 0 then 12 else (t :: any).hour % 12, if (t :: any).hour < 12 then "AM" else "PM")
	local same_day = (t :: any).yday == (today :: any).yday and (t :: any).year == (today :: any).year
	if not same_day then
		time = WEEKDAYS[(t :: any).wday] .. " " .. time
	end
	return if exact then time else "~" .. time
end

-- How long until `ms` from now, as the extension writes countdowns: `45m`, `2h 11m`, `6d 4h`.
local function span(ms: number): string
	local minutes = math.max(1, math.floor(ms / 60000 + 0.5))
	if minutes < 60 then
		return string.format("%dm", minutes)
	end
	local hours, rest = math.floor(minutes / 60), minutes % 60
	if hours < 24 then
		return if rest > 0 then string.format("%dh %dm", hours, rest) else string.format("%dh", hours)
	end
	local days = math.floor(hours / 24)
	return if hours % 24 > 0 then string.format("%dd %dh", days, hours % 24) else string.format("%dd", days)
end

-- A saved reset's card row: `saved reset · in 10d 18h · Oct 22` (`2 saved resets · …` for a credit of two; the
-- year after the date when it isn't this year's), short so the card stays narrow; nil once it has expired.
local function reset_text(reset: Reset, now: number, fable: boolean): string?
	if reset.at <= now then
		return nil
	end
	local ok, t = pcall(os.date, "*t", math.floor(reset.at / 1000))
	local ok_now, today = pcall(os.date, "*t", math.floor(now / 1000))
	if not ok or type(t) ~= "table" or not ok_now or type(today) ~= "table" then
		return nil
	end
	local date = string.format("%s %d", MONTHS[(t :: any).month], (t :: any).day)
	if (t :: any).year ~= (today :: any).year then
		date ..= " " .. tostring((t :: any).year)
	end
	local kind = if fable then "Fable reset" else "saved reset"
	local what = if reset.count > 1 then string.format("%d %ss", reset.count, kind) else kind
	return string.format("%s · in %s · %s", what, span(reset.at - now), date)
end

-- One usage-remaining.js window, `[Provider ][Scope ]<span> <meter> <N>% left[ (<reset>)][ (+N) | (!N - <left> left)]`,
-- and the provider in front of it, if any. A window metered for one tier or model of the plan carries its scope
-- (`Fable 7d`), which stays in its label so it is told apart from the general window of the same span. The
-- provider's one-word label leads only a line's `first` window.
local function parse_window(piece: string, first: boolean): (Window?, string?)
	local head, span, pct, rest = string.match(piece, "^(.-)(%S+) %S+ (%d+)%% left(.*)$")
	if span == nil then
		return nil, nil
	end
	local provider: string? = nil
	local scope = string.match(head :: string, "^%s*(.-)%s*$") :: string
	if first then
		local word, after = string.match(scope, "^(%S*)%s*(.*)$")
		provider, scope = word, after :: string
	end
	local label = if scope ~= "" then scope .. " " .. (span :: string) else span :: string
	local window: Window = { label = label, pct = tonumber(pct) :: number }
	for group in string.gmatch(rest :: string, "%((.-)%)") do
		local plus = string.match(group, "^%+(%d+)$")
		local n, expires = string.match(group, "^!(%d+) %- (.+) left$")
		if plus then
			window.saved = tonumber(plus)
		elseif n then
			window.saved, window.expires = tonumber(n), expires
		else
			window.reset = group
		end
	end
	return window, if provider and provider ~= "" then provider else nil
end

-- A usage line, `<Label> <window> · <window>`, or a status with other parts between: the label in front of
-- the first window, the windows, and the other parts as they are.
local function parse_line(text: string): (string?, { Window }, { string })
	local label: string? = nil
	local windows: { Window } = {}
	local others: { string } = {}
	for _, piece in usage_pieces(text) do
		local window, provider = parse_window(piece, #windows == 0)
		if window then
			table.insert(windows, window)
			label = label or provider
		else
			table.insert(others, piece)
		end
	end
	return label, windows, others
end

local function tone_of(pct: number): string
	return if pct <= BAD_AT then "bad" elseif pct <= WARN_AT then "warn" else "ok"
end

local function resets_of(value: any): { Reset }
	local resets: { Reset } = {}
	if type(value) == "table" then
		for _, item in ipairs(value) do
			if type(item) == "table" and type(item.expiresAt) == "number" then
				local count = if type(item.count) == "number" and item.count >= 1 then item.count else 1
				table.insert(resets, { at = item.expiresAt, count = count, window = if type(item.window) == "string" then string.lower(item.window) else nil })
			end
		end
	end
	table.sort(resets, function(a, b)
		return a.at < b.at
	end)
	return resets
end

local function provider_rank(id: string): number
	return table.find(PROVIDER_ORDER, id) or #PROVIDER_ORDER + 1
end

local function sort_providers(list: { Provider })
	table.sort(list, function(a, b)
		local ra, rb = provider_rank(a.id), provider_rank(b.id)
		if ra ~= rb then
			return ra < rb
		end
		return a.label < b.label
	end)
end

-- Whether a window is Claude's Fable meter (`Fable 7d`, or `alice Fable 7d` with several accounts): its saved
-- resets are Fable resets, marked `+NF` on the line.
local function is_fable(provider: string?, label: string): boolean
	local key = string.lower(label)
	return provider == "anthropic" and (key == "fable 7d" or string.sub(key, -9) == " fable 7d")
end

-- Whether `windows` has one labeled `label` (without case: `fable 7d` is `Fable 7d`).
local function has_window(windows: { Window }, label: string): boolean
	local key = string.lower(label)
	for _, window in windows do
		if string.lower(window.label) == key then
			return true
		end
	end
	return false
end

-- The cache as decoded JSON: model entries by chip name (`null` ones, two models sharing a chip name, are
-- dropped by the decoder, which reads the same as missing) and the providers in the preset order (decoding
-- loses the file's). `providers` is nil when the file has none, as written before it listed them.
local function parse_cache(doc: any): Cache?
	if type(doc) ~= "table" or type(doc.generatedAt) ~= "number" then
		return nil
	end
	local cache: Cache = { at = doc.generatedAt, models = {}, providers = nil }
	if type(doc.models) == "table" then
		for name, item in pairs(doc.models) do
			if type(name) == "string" and type(item) == "table" and type(item.line) == "string" then
				cache.models[name] = { line = item.line, resets = resets_of(item.resets) }
			end
		end
	end
	if type(doc.providers) == "table" then
		local list: { Provider } = {}
		for id, item in pairs(doc.providers) do
			if type(id) == "string" and type(item) == "table" and type(item.line) == "string" and item.line ~= "" then
				local label = if type(item.label) == "string" and item.label ~= "" then item.label else id
				local _, windows = parse_line(item.line)
				-- a provider's accounts, listed only when it has several
				local accounts: { string } = {}
				if type(item.accounts) == "table" then
					for _, name in ipairs(item.accounts) do
						if type(name) == "string" and name ~= "" and not table.find(accounts, name) then
							table.insert(accounts, name)
						end
					end
				end
				table.insert(list, {
					id = id,
					label = label,
					line = item.line,
					resets = resets_of(item.resets),
					windows = windows,
					accounts = if #accounts > 1 then accounts else {},
				})
			end
		end
		-- after the plan's windows, those only some models have (Codex Spark's), from those models' lines
		local names: { string } = {}
		for name in cache.models do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local label, windows = parse_line(cache.models[name].line)
			for _, provider in list do
				if provider.label == label then
					for _, window in windows do
						if not has_window(provider.windows, window.label) then
							table.insert(provider.windows, window)
						end
					end
				end
			end
		end
		sort_providers(list)
		cache.providers = list
	end
	return cache
end

-- The cache to use now: nil when missing, unreadable or older than 10 minutes. A read that doesn't decode (a
-- half-replaced file) keeps the last good one, and a file without providers (an omp session still running an
-- extension from before they were listed) borrows the last ones seen, while they are fresh.
local function fresh_cache(parsed: Cache?, seen: { at: number, list: { Provider } }?, now: number): Cache?
	if parsed == nil or now - parsed.at > CACHE_MAX_AGE_MS then
		return nil
	end
	if parsed.providers == nil and seen and now - seen.at <= CACHE_MAX_AGE_MS then
		return { at = parsed.at, models = parsed.models, providers = seen.list }
	end
	return parsed
end

-- The cache file's text as last read (nil until it has been). `tern.fs.read` would read it on the window's thread,
-- and opening the file just after omp rewrites it can wait on another program (a virus scan) for longer than a
-- timer's 50 ms budget, which, tripped, turns off every timer of the plugin until a reload; so it is read with
-- `cx.docs:read`, whose answer comes back later, every few seconds.
local CACHE_POLL_MS = 3000
local cache_text: string? = nil

local CACHE_PATH: string? = (function(): string?
	local home = tern.getenv("USERPROFILE") or tern.getenv("HOME")
	return if home and home ~= "" then home .. CACHE_FILE else nil
end)()

local function poll_cache(cx: WindowCx?)
	tern.timer(CACHE_POLL_MS, poll_cache)
	local path = CACHE_PATH
	if cx == nil or path == nil then
		return
	end
	local ok, reading = pcall(function(): any
		return (cx :: WindowCx).docs:read(path :: string)
	end)
	if ok and reading then
		-- a failed read (the file being replaced, or gone) keeps the last text: it goes stale on its own
		reading:next(function(text: string?, _err: string?, _later: WindowCx?)
			if type(text) == "string" and #text <= CACHE_MAX_BYTES then
				cache_text = text
			end
		end)
	end
end

tern.timer(0, poll_cache)

local function read_cache(now: number): Cache?
	local raw = cache_text
	if raw == nil then
		return nil
	end
	if raw ~= cache_raw then
		local decoded, doc = pcall(tern.json.decode, raw)
		local parsed = if decoded then parse_cache(doc) else nil
		if parsed then
			cache_raw = raw
			cache_parsed = parsed
			if parsed.providers then
				providers_seen = { at = parsed.at, list = parsed.providers :: { Provider } }
			end
		end
	end
	return fresh_cache(cache_parsed, providers_seen, now)
end

-- The providers to offer: the cache's, else the known ones.
local function offered_providers(cache: Cache?): { Provider }
	if cache and cache.providers then
		return cache.providers :: { Provider }
	end
	local list: { Provider } = {}
	for label, id in LABEL_IDS do
		table.insert(list, { id = id, label = label, line = "", resets = {}, windows = {}, accounts = {} })
	end
	sort_providers(list)
	return list
end

-- What the settings read and write: `tern.kv`, and the providers to offer; behind a seam a self-test can swap.
local store = {
	get = function(key: string): any
		local ok, value = pcall(tern.kv.get, key)
		return if ok then value else nil
	end,
	set = function(key: string, value: any)
		tern.kv.set(key, value)
	end,
	providers = function(): { Provider }
		return offered_providers(read_cache(now_ms()))
	end,
}

-- A stored list of ids, each once.
local function id_list(value: any): { string }
	local list: { string } = {}
	if type(value) == "table" then
		for _, id in ipairs(value) do
			if type(id) == "string" and not table.find(list, id) then
				table.insert(list, id)
			end
		end
	end
	return list
end

local function load_settings(): Settings
	local settings: Settings = {
		mode = "current",
		selected = id_list(store.get(KV_SELECTED)),
		colors = {},
		order = id_list(store.get(KV_ORDER)),
		hidden = {},
		account = {},
		account_order = {},
		account_hidden = {},
		card_rows = CARD_ROWS_DEFAULT,
	}
	local mode = store.get(KV_MODE)
	if mode == "all" or mode == "selected" then
		settings.mode = mode
	end
	local rows = store.get(KV_CARD_ROWS)
	if type(rows) == "number" and table.find(CARD_ROWS, rows) then
		settings.card_rows = rows
	end
	local colors = store.get(KV_COLORS)
	if type(colors) == "table" then
		for id, spec in pairs(colors) do
			if type(id) == "string" and type(spec) == "string" then
				settings.colors[id] = spec
			end
		end
	end
	local hidden = store.get(KV_HIDDEN)
	if type(hidden) == "table" then
		for id, labels in pairs(hidden) do
			local list = id_list(labels)
			if type(id) == "string" and #list > 0 then
				settings.hidden[id] = list
			end
		end
	end
	local account = store.get(KV_ACCOUNT)
	if type(account) == "table" then
		for id, name in pairs(account) do
			if type(id) == "string" and type(name) == "string" and name ~= "" then
				settings.account[id] = name
			end
		end
	end
	local account_order = store.get(KV_ACCOUNT_ORDER)
	if type(account_order) == "table" then
		for id, names in pairs(account_order) do
			local list = id_list(names)
			if type(id) == "string" and #list > 0 then
				settings.account_order[id] = list
			end
		end
	end
	local account_hidden = store.get(KV_ACCOUNT_HIDDEN)
	if type(account_hidden) == "table" then
		for id, names in pairs(account_hidden) do
			local list = id_list(names)
			if type(id) == "string" and #list > 0 then
				settings.account_hidden[id] = list
			end
		end
	end
	return settings
end

-- The windows of provider `id` the settings leave on the line, in order.
local function shown_windows(settings: Settings, id: string?, windows: { Window }): { Window }
	local hidden = if id then settings.hidden[id :: string] else nil
	if hidden == nil then
		return windows
	end
	local kept: { Window } = {}
	for _, window in windows do
		if not table.find(hidden, string.lower(window.label)) then
			table.insert(kept, window)
		end
	end
	return kept
end

-- A provider's accounts in the user's order: those `order` names first, as it has them, then the rest in omp's.
local function accounts_in_order(accounts: { string }, order: { string }?): { string }
	local list: { string } = {}
	for _, name in (order or {}) :: { string } do
		if table.find(accounts, name) and not table.find(list, name) then
			table.insert(list, name)
		end
	end
	for _, name in accounts do
		if not table.find(list, name) then
			table.insert(list, name)
		end
	end
	return list
end

-- The account of `accounts` a window's label starts with (`alice` for `alice Fable 7d`), and the label without it.
local function account_of(label: string, accounts: { string }): (string?, string?)
	local key = string.lower(label)
	for _, name in accounts do
		local prefix = string.lower(name) .. " "
		if string.sub(key, 1, #prefix) == prefix then
			return name, string.sub(label, #prefix + 1)
		end
	end
	return nil, nil
end

-- Whether provider `id`'s account `name` is switched off.
local function account_off(settings: Settings, id: string, name: string): boolean
	local off = settings.account_hidden[id]
	return off ~= nil and table.find(off, name) ~= nil
end

-- The one account the line and card show for provider `id` (of `accounts`), while it is still signed in and
-- switched on; nil for every account that is.
local function chosen_account(settings: Settings, id: string, accounts: { string }): string?
	local chosen = settings.account[id]
	return if chosen and table.find(accounts, chosen) and not account_off(settings, id, chosen) then chosen else nil
end

-- A window's name in the card: `Weekly`, and a scoped one's with its scope, `Fable weekly`.
local function window_name(label: string): string
	local scope, span = string.match(label, "^(.-)%s*(%S+)$")
	local name = WINDOW_NAMES[span :: string] or span :: string
	return if scope ~= nil and scope ~= "" then scope .. " " .. string.lower(name) else name
end

-- A provider's accounts (`on`: each one's windows, in order, the first leading) combined, all in one group, or, `by
-- plan`, the accounts that report the same windows together (most likely one plan; omp doesn't say). Each group
-- gets one run of windows (every window any of its accounts has, in the order they first come), named for how many
-- accounts it holds (`6 accounts`; a group of one keeps the account's name). A window's share is the average of
-- the group's accounts that have it (`covers` says how many when not all do), its reset the soonest of theirs, its
-- saved resets all of theirs. `loose` (windows without an account) go first. When one window sets the groups
-- apart, the groups without it say so in their name (`4 accounts, no 5H`), and each group's lead window carries
-- `plan`, its heading in the card (`6 accounts with a 5-hour window`); with more than one, the heading lists the
-- group's windows (`4 accounts · 7D · FABLE 7D`). Also, for the panel: the chip's text and each account's group tag.
local function combined(on: { { Window } }, loose: { Window }, by_plan: boolean): ({ Window }, { chip: string, tags: { [string]: string } })
	local plans: { { key: string, lists: { { Window } } } } = {}
	for _, list in on do
		local labels: { string } = {}
		for _, window in list do
			table.insert(labels, string.lower(window.bare or window.label))
		end
		table.sort(labels)
		local key = if by_plan then table.concat(labels, "|") else ""
		local plan = nil
		for _, candidate in plans do
			if candidate.key == key then
				plan = candidate
			end
		end
		if plan == nil then
			plan = { key = key, lists = {} }
			table.insert(plans, plan)
		end
		table.insert(plan.lists, list)
	end
	-- What sets the groups apart: the windows only some of them have. With one, each group says whether it has it;
	-- else each lists its windows.
	local counts: { [string]: number } = {}
	local shown: { [string]: string } = {}
	for _, plan in plans do
		for _, window in plan.lists[1] do
			local key = string.lower(window.bare or window.label)
			counts[key] = (counts[key] or 0) + 1
			shown[key] = window.bare or window.label
		end
	end
	local differs: { string } = {}
	for key, n in counts do
		if n < #plans then
			table.insert(differs, key)
		end
	end
	local info = { chip = "", tags = {} :: { [string]: string } }
	-- each group's name on the line and in one-row summaries (`6 accounts`, `4 accounts, no 5H`), and its heading in
	-- the card (`4 accounts without a 5-hour window`)
	local names: { string } = {}
	local heads: { string } = {}
	local accounts = 0
	for p, plan in plans do
		accounts += #plan.lists
		names[p] = if #plan.lists == 1 then plan.lists[1][1].account :: string else tostring(#plan.lists) .. " accounts"
		heads[p] = names[p]
	end
	if #plans == 1 then
		info.chip = if by_plan
			then string.format("by plan · all %d alike", accounts)
			else string.format("combined · %d accounts", accounts)
	elseif #differs == 1 then
		local name = window_name(shown[differs[1]])
		local nice = if string.sub(name, 1, 5) == "Fable" then name else string.lower(name)
		-- the rows' tags go by the window's short label, as the rows' windows do (`5H`, `no 5H`), to keep the rows short
		local short = string.upper(shown[differs[1]])
		local with, without = 0, 0
		for p, plan in plans do
			local has = false
			for _, window in plan.lists[1] do
				has = has or string.lower(window.bare or window.label) == differs[1]
			end
			heads[p] = names[p] .. (if has then " with a " else " without a ") .. nice .. " window"
			if not has then
				names[p] ..= ", no " .. short
			end
			for _, list in plan.lists do
				info.tags[list[1].account :: string] = if has then short else "no " .. short
			end
			if has then
				with += #plan.lists
			else
				without += #plan.lists
			end
		end
		info.chip = string.format("by plan · %d with %s, %d without", with, short, without)
	else
		for p, plan in plans do
			local labels: { string } = {}
			for _, window in plan.lists[1] do
				table.insert(labels, string.upper(window.bare or window.label))
			end
			local list = table.concat(labels, " · ")
			heads[p] = names[p] .. " · " .. list
			for _, member in plan.lists do
				info.tags[member[1].account :: string] = list
			end
		end
		info.chip = string.format("by plan · %d groups by their windows", #plans)
	end
	local out: { Window } = table.clone(loose)
	-- how soon a countdown (`2h 11m`, `soon`) runs out, in minutes; anything else last
	local function minutes(s: string?): number
		if s == "soon" then
			return 0
		end
		local m = if s then countdown_minutes(s :: string) else nil
		return m or math.huge
	end
	for p, plan in plans do
		local name = names[p]
		-- every window the group's accounts have, in the order they first come
		local order: { Window } = {}
		local seen: { [string]: boolean } = {}
		for _, list in plan.lists do
			for _, window in list do
				local key = string.lower(window.bare or window.label)
				if not seen[key] then
					seen[key] = true
					table.insert(order, window)
				end
			end
		end
		for w, window in order do
			local bare = string.lower(window.bare or window.label)
			local total, count, saved = 0, 0, 0
			local reset, expires = window.reset, window.expires
			for _, list in plan.lists do
				for _, other in list do
					if string.lower(other.bare or other.label) == bare then
						total += other.pct
						count += 1
						saved += other.saved or 0
						if minutes(other.reset) < minutes(reset) then
							reset = other.reset
						end
						if other.expires and minutes(other.expires) < minutes(expires) then
							expires = other.expires
						end
					end
				end
			end
			table.insert(out, {
				label = name .. " " .. (window.bare or window.label),
				pct = math.floor(total / count + 0.5),
				reset = reset,
				saved = if saved > 0 then saved else nil,
				expires = if saved > 0 then expires else nil,
				account = name,
				bare = window.bare or window.label,
				lead = if w == 1 then true else nil,
				plan = if w == 1 and heads[p] ~= name then heads[p] else nil,
				covers = if count < #plan.lists then string.format("%d of the %d accounts", count, #plan.lists) else nil,
			})
		end
	end
	return out, info
end

-- A provider's windows as the settings show its accounts: every account switched on, in the user's order (one
-- after another, each window in the extension's order), only the account picked for it, the other accounts'
-- windows then coming back as `rest` for the card, or the accounts combined (see `combined`). Accounts switched
-- off are left out of all of it. Each window knows its account, and the first of each leads it (see `Window`).
-- With fewer than two accounts the windows come back as they are. Combined, the chip's text and the accounts' group
-- tags come back third (see `combined`).
local function account_view(
	settings: Settings,
	id: string?,
	accounts: { string },
	windows: { Window }
): ({ Window }, { Window }?, { chip: string, tags: { [string]: string } }?)
	if id == nil or #accounts < 2 then
		return windows, nil
	end
	local by: { [string]: { Window } } = {}
	local shown: { Window } = {}
	local loose: { Window } = {}
	for _, window in windows do
		local name, bare = account_of(window.label, accounts)
		if name then
			local copy = table.clone(window)
			copy.account, copy.bare = name, bare
			by[name] = by[name] or {}
			table.insert(by[name], copy)
		else
			table.insert(shown, window) -- none should be without one; any that is goes first
			table.insert(loose, window)
		end
	end
	local one = chosen_account(settings, id :: string, accounts)
	local rest: { Window }? = if one then {} else nil
	local on: { { Window } } = {}
	for _, name in accounts_in_order(accounts, settings.account_order[id :: string]) do
		local list = by[name]
		if list and not account_off(settings, id :: string, name) then
			list[1].lead = true
			table.insert(on, list)
			for _, window in list do
				table.insert(if one == nil or name == one then shown else rest :: { Window }, window)
			end
		end
	end
	local mode = settings.account[id :: string]
	if one == nil and (mode == COMBINED or mode == COMBINED_PLANS) then
		local together, info = combined(on, loose, mode == COMBINED_PLANS)
		return together, nil, info
	end
	return shown, rest
end

-- A provider's accounts switched on, in the user's order.
local function shown_accounts(settings: Settings, provider: Provider): { string }
	local list: { string } = {}
	for _, name in accounts_in_order(provider.accounts, settings.account_order[provider.id]) do
		if not account_off(settings, provider.id, name) then
			table.insert(list, name)
		end
	end
	return list
end

-- The accounts of provider `id` in the cache (empty with one, or without a cache).
local function accounts_of(cache: Cache?, id: string?): { string }
	if cache and cache.providers and id then
		for _, provider in cache.providers :: { Provider } do
			if provider.id == id then
				return provider.accounts
			end
		end
	end
	return {}
end

-- `list` in the user's order: the providers `order` names first, as it has them, then the rest in the preset order.
local function ordered(list: { Provider }, order: { string }): { Provider }
	local rank: { [string]: number } = {}
	for i, id in order do
		rank[id] = i
	end
	local sorted = table.clone(list)
	table.sort(sorted, function(a, b)
		local ra, rb = rank[a.id], rank[b.id]
		if ra and rb then
			return ra < rb
		elseif ra or rb then
			return ra ~= nil
		end
		local pa, pb = provider_rank(a.id), provider_rank(b.id)
		if pa ~= pb then
			return pa < pb
		end
		return a.label < b.label
	end)
	return sorted
end

-- The order to store once `id` moves among `shown`, the ids on offer in their order: `how` is a picker's move (`up`,
-- `down`, `top`, `bottom`) or a slot of the panel's pick and place (`at`: before what is `at`th once `id` is
-- lifted out, or last past the end). It names every id on offer; ids it named that aren't now keep their places.
local function moved(order: { string }, shown: { string }, id: string, how: string | number): { string }
	local full = table.clone(order)
	for _, item in shown do
		if not table.find(full, item) then
			table.insert(full, item)
		end
	end
	local i = table.find(shown, id)
	if i == nil then
		return full
	end
	-- the neighbor it goes before (or after)
	local anchor: string? = nil
	local after = false
	if type(how) == "number" then
		local rest = table.clone(shown)
		table.remove(rest, i)
		anchor, after = rest[how] or rest[#rest], rest[how] == nil
	elseif how == "up" then
		anchor = shown[i - 1]
	elseif how == "down" then
		anchor, after = shown[i + 1], true
	elseif how == "top" and i > 1 then
		anchor = shown[1]
	elseif how == "bottom" and i < #shown then
		anchor, after = shown[#shown], true
	end
	if anchor == nil then
		return full
	end
	table.remove(full, table.find(full, id) :: number)
	local at = table.find(full, anchor :: string) :: number
	table.insert(full, if after then at + 1 else at, id)
	return full
end

-- One or two hex colors (`#d97757`, `#9aa7b4, #5b8def`; `#rgb` too) as `#rrggbb`; else nil and the part that
-- isn't one.
local function parse_colors(text: string): ({ string }?, string?)
	local colors: { string } = {}
	for part in string.gmatch(text, "[^,%s]+") do
		local hex = string.lower(part)
		if string.match(hex, "^#%x%x%x$") then
			hex = "#"
				.. string.rep(string.sub(hex, 2, 2), 2)
				.. string.rep(string.sub(hex, 3, 3), 2)
				.. string.rep(string.sub(hex, 4, 4), 2)
		end
		if not string.match(hex, "^#%x%x%x%x%x%x$") then
			return nil, part
		end
		table.insert(colors, hex)
	end
	if #colors == 0 or #colors > 2 then
		return nil, text
	end
	return colors, nil
end

local function named_palette(key: string): Palette?
	for _, item in NAMED do
		if item.key == key then
			return item.palette
		end
	end
	return nil
end

-- A stored color choice as a palette; nil when it isn't one (then the preset applies).
local function palette_of_spec(spec: string): Palette?
	local key = string.match(spec, "^named:(.+)$")
	if key then
		return named_palette(key)
	end
	local colors = parse_colors(spec)
	if colors then
		return { name = table.concat(colors, ", "), a = colors[1], b = colors[2] }
	end
	return nil
end

-- What a provider's colors are keyed by: its id, else its label's preset id, else its label.
local function color_key(id: string?, label: string): string
	return id or LABEL_IDS[label] or label
end

local function preset_for(id: string?, label: string): Palette
	return PRESETS[color_key(id, label)] or PRESETS[LABEL_IDS[label] or ""] or ACCENT
end

-- A provider's colors: the user's choice for it, else its preset (by id, then by label), else the theme accent.
local function palette_for(settings: Settings, id: string?, label: string): Palette
	local spec = settings.colors[color_key(id, label)]
	local chosen = if spec then palette_of_spec(spec) else nil
	return chosen or preset_for(id, label)
end

-- A provider's id for a label: from the cache, else the extension's own labels.
local function provider_id(label: string, cache: Cache?): string?
	if cache and cache.providers then
		for _, provider in cache.providers :: { Provider } do
			if provider.label == label then
				return provider.id
			end
		end
	end
	return LABEL_IDS[label]
end

local function window_signature(window: Window): string
	local s = string.format("%s:%d:%s:%s:%s", window.label, window.pct, window.reset or "", tostring(window.saved or ""), window.expires or "")
	if window.account then
		s ..= "@" .. (window.account :: string) .. (if window.lead then "^" else "")
	end
	return s
end

local function signature_of(groups: { Group }, others: { string }, title: string): string
	local parts: { string } = { title }
	for _, group in groups do
		table.insert(parts, group.key .. "=" .. group.label)
		for _, window in group.windows do
			table.insert(parts, window_signature(window))
		end
		for _, window in (group.rest or {}) :: { Window } do
			table.insert(parts, "~" .. window_signature(window))
		end
		for _, reset in group.resets or {} do
			table.insert(parts, string.format("r%d*%d:%s", reset.at, reset.count, reset.window or ""))
		end
	end
	for _, other in others do
		table.insert(parts, other)
	end
	return table.concat(parts, "\n")
end

-- What the line shows. By the mode: every provider in the cache, or the chosen ones; or (with neither) the
-- focused agent's: while a subagent's transcript is viewed, the line the cache holds for its model's chip name
-- (an empty one: no usage line), else the status. The status's other parts follow either way, and saved resets
-- come from the cache entry the line came from (the status's model is the chip's). Windows hidden in the
-- settings are left out; a mode with providers to show shows them even when that leaves nothing. A provider with
-- several accounts shows them as the settings say (see `account_view`).
local function build_model(settings: Settings, dock: Dock, cache: Cache?): Model
	local label, windows, others = parse_line(if dock.status then usage_part(dock.status) else "")
	local groups: { Group } = {}
	local source = "status"
	local title: string? = nil
	local providers = if cache then cache.providers else nil
	local listed = false
	if settings.mode ~= "current" and providers then
		for _, provider in ordered(providers, settings.order) do
			if settings.mode == "all" or table.find(settings.selected, provider.id) then
				local provider_label, provider_windows = parse_line(provider.line)
				listed = listed or #provider_windows > 0
				provider_windows = shown_windows(settings, provider.id, provider_windows)
				local rest: { Window }? = nil
				provider_windows, rest = account_view(settings, provider.id, provider.accounts, provider_windows)
				if #provider_windows > 0 then
					table.insert(groups, {
						key = provider.id,
						id = provider.id,
						label = provider_label or provider.label,
						windows = provider_windows,
						resets = provider.resets,
						rest = rest,
					})
				end
			end
		end
		source = settings.mode
	end
	if not listed then
		local entry = if cache and dock.chip then cache.models[dock.chip :: string] else nil
		if dock.viewing and entry then
			label, windows = parse_line(entry.line)
			source = "model:" .. (dock.chip :: string)
		else
			source = "status"
		end
		local id = if label then provider_id(label, cache) else nil
		windows = shown_windows(settings, id, windows)
		local rest: { Window }? = nil
		windows, rest = account_view(settings, id, accounts_of(cache, id), windows)
		if #windows > 0 then
			table.insert(groups, {
				key = id or label or "usage",
				id = id,
				label = label or "",
				windows = windows,
				resets = if entry then entry.resets else nil,
				rest = rest,
			})
			title = (label or "") .. (if label then " usage" else "Usage")
			if source ~= "status" then
				title ..= " · " .. (dock.chip :: string)
			end
		end
	end
	if title == nil then
		title = if #groups > 1 then "Usage" elseif #groups == 1 then groups[1].label .. " usage" else "Status"
	end
	return {
		groups = groups,
		others = others,
		source = source,
		title = title :: string,
		signature = signature_of(groups, others, title :: string),
	}
end

-- Each window's share, by provider and window.
local function shares(model: Model): { [string]: number }
	local values: { [string]: number } = {}
	for _, group in model.groups do
		for _, window in group.windows do
			values[group.key .. "/" .. window.label] = window.pct
		end
	end
	return values
end

-- The windows whose share moved, and which way (`down`, `up`); nil when none did. Windows on only one side (a
-- provider switched, appeared or went) don't count.
local function changes(before: { [string]: number }?, after: { [string]: number }): { [string]: string }?
	if before == nil then
		return nil
	end
	local moved: { [string]: string } = {}
	local any = false
	for key, share in after do
		local old = before[key]
		if old ~= nil and old ~= share then
			moved[key] = if share < old then "down" else "up"
			any = true
		end
	end
	return if any then moved else nil
end

local function css_string(s: string): string
	return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", " ") .. '"'
end

-- Fills `$NAME` placeholders (CSS has no `$`).
local function fill(template: string, vars: { [string]: string }): string
	return (string.gsub(template, "%$([%w_]+)", function(name: string): string
		local value = vars[name]
		assert(value, "no value for $" .. name)
		return value
	end))
end

local function num(x: number, places: number?): string
	local s = string.format("%." .. tostring(places or 2) .. "f", x)
	s = (string.gsub(s, "0+$", ""))
	s = (string.gsub(s, "%.$", ""))
	return if s == "-0" then "0" else s
end

-- A color as a gradient stop: Tern drops a stop whose color is a `var()` holding `light-dark()` (the theme's
-- tokens can be), but takes it inside a relative color.
local function solid(color: string): string
	return "rgb(from " .. color .. " r g b)"
end

local function faded(color: string, percent: number): string
	return string.format("rgb(from %s r g b / %d%%)", color, percent)
end

-- A glyph offset on the line as a length: its 10px var(--mono) is Berkeley Mono, whose glyphs (letters, digits,
-- box drawing, `·`, no-break space) are all 0.6em wide.
local function em(glyph: number): string
	return num(glyph * 0.6, 3) .. "em"
end

local function glyph_count(s: string): number
	local _, n = string.gsub(s, "[^\128-\191]", "") -- UTF-8: every byte that doesn't continue a character
	return n
end

local function unbroken(s: string): string
	return (string.gsub(s, " ", NBSP))
end

-- A provider's color variables (set on the composer, see `palette_css`) and a window's: its provider's, unless
-- its share is low.
local function group_color(group: number, part: string): string
	return string.format("var(--ou-g%d-%s)", group, part)
end

local function window_colors(tone: string, group: number): (string, string)
	if tone == "ok" then
		return group_color(group, "a"), group_color(group, "b")
	end
	local color = if tone == "warn" then "var(--warn)" else "var(--bad)"
	return color, color
end

type Paint = { from: number, to: number, color: string }
-- A window's bar: its first glyph, its length and how many glyphs it fills (a fraction), the glyph its window
-- ends at, the window's key (provider and label) and its colors.
type Bar = { at: number, glyphs: number, fill: number, ends: number, key: string, a: string, b: string }
type Line = { text: string, glyphs: number, paints: { Paint }, bars: { Bar } }

-- One provider: `Claude  5H ━━━━━━━━ 98% left  3h 57m · 7D ━━━━━━━━ 71% left  11h 37m  +1 · <other statuses>`.
-- Several (the composer is at most ~115 glyphs wide) go compact, the countdowns and the word `left` left to the
-- card, and a `·` only between providers: `Claude  5H ━━━━━━ 98%  7D ━━━━━━ 71% +1 · Codex  7D ━━━━━━ 79% +2`.
-- A provider with several accounts names each once, in its color, before its first window, which a `·` sets
-- apart from the account before: `Claude alice  7D ━━━━━━━━ 68% left … · bob  5H ━━━━━━━━ 40% left …`.
-- Each window's parts are joined by no-break spaces (a provider's label with its first window) so it wraps
-- whole; with them, what colors each part. `compact` overrides the format the number of providers picks.
local function line_of(model: Model, compact: boolean?): Line
	local parts: { string } = {}
	local line: Line = { text = "", glyphs = 0, paints = {}, bars = {} }
	local several = if compact ~= nil then compact else #model.groups > 1
	local bar_glyphs = if several then COMPACT_BAR_GLYPHS else BAR_GLYPHS
	local function add(s: string, color: string?)
		local n = glyph_count(s)
		if color then
			table.insert(line.paints, { from = line.glyphs, to = line.glyphs + n, color = color })
		end
		table.insert(parts, s)
		line.glyphs += n
	end
	local function next_part()
		if line.glyphs > 0 then
			add(" ") -- a plain space: the only places the line may wrap
			add("·" .. NBSP, "var(--ou-sep)")
		end
	end
	for g, group in model.groups do
		for w, window in group.windows do
			local tone = tone_of(window.pct)
			local account = if window.lead then window.account else nil
			if w > 1 and several and account == nil then
				add(" " .. NBSP)
			else
				next_part()
			end
			if w == 1 and group.label ~= "" then
				add(group.label, group_color(g, "a"))
				add(if account then NBSP else NBSP .. NBSP)
			end
			if account then
				add(unbroken(account :: string), group_color(g, "a"))
				add(NBSP .. NBSP)
			end
			add(unbroken(string.upper(window.bare or window.label)), "var(--ou-lbl)")
			add(NBSP)
			local at = line.glyphs
			add(string.rep(BAR, bar_glyphs))
			add(NBSP)
			add(tostring(window.pct) .. "%", "var(--ou-num-" .. tone .. ")")
			if not several then
				add(NBSP .. "left", "var(--ou-dim)")
				if window.reset then
					add(NBSP .. NBSP .. unbroken(window.reset :: string), "var(--ou-soft)")
				end
			end
			if window.saved then
				local fable = is_fable(group.id, window.label)
				local saved = "+" .. tostring(window.saved) .. (if fable then "F" else "")
				if window.expires then
					saved ..= if several then "!" else NBSP .. "exp" .. NBSP .. unbroken(window.expires :: string)
				end
				add((if several then NBSP else NBSP .. NBSP) .. saved, if window.expires then "var(--ou-num-warn)" else group_color(g, "a"))
			end
			local a, b = window_colors(tone, g)
			table.insert(line.bars, {
				at = at,
				glyphs = bar_glyphs,
				fill = math.clamp(window.pct, 0, 100) / 100 * bar_glyphs,
				ends = line.glyphs,
				key = group.key .. "/" .. window.label,
				a = a,
				b = b,
			})
		end
	end
	for _, other in model.others do
		next_part()
		add(unbroken(other), "var(--ou-soft)")
	end
	line.text = table.concat(parts)
	return line
end

-- The text's paint: each part's color over its glyphs; each bar from its first color, faint, to its second up to
-- its share, then the track. Hard stops sit between glyphs, so nothing bleeds.
local function line_paint(line: Line): string
	local items: { { at: number, stops: string } } = {}
	for _, paint in line.paints do
		table.insert(items, {
			at = paint.from,
			stops = string.format("%s %s %s", solid(paint.color), em(paint.from), em(paint.to)),
		})
	end
	for _, bar in line.bars do
		local tip = bar.at + bar.fill
		local stops: { string } = {}
		if bar.fill > 0 then
			table.insert(stops, string.format("%s %s", faded(bar.a, 40), em(bar.at)))
			table.insert(stops, string.format("%s %s", solid(bar.b), em(tip)))
		end
		if bar.fill < bar.glyphs then
			table.insert(stops, string.format("%s %s %s", solid("var(--ou-track)"), em(tip), em(bar.at + bar.glyphs)))
		end
		table.insert(items, { at = bar.at, stops = table.concat(stops, ", ") })
	end
	table.sort(items, function(a, b)
		return a.at < b.at
	end)
	local stops: { string } = {}
	for _, item in items do
		table.insert(stops, item.stops)
	end
	return "linear-gradient(90deg, " .. table.concat(stops, ", ") .. ")"
end

-- `size` while the bar's window fits on the line of the box drawing it, else 0, so a window that wrapped away
-- takes its tip along (in background sizes, 100% is that box's width).
local function fits(bar: Bar, size: number): string
	return string.format("clamp(0px, calc((100%% - %spx) * 1000), %spx)", num(bar.ends * GLYPH - 3), num(size))
end

local function tip_image(color: string, strength: number): string
	return string.format(
		"radial-gradient(closest-side, color-mix(in srgb, %s 45%%, white), rgb(from %s r g b / %d%%) 45%%, rgb(from %s r g b / 0%%))",
		color,
		color,
		strength,
		color
	)
end

local function trail_image(color: string): string
	return string.format("linear-gradient(90deg, rgb(from %s r g b / 0%%), rgb(from %s r g b / 80%%))", color, color)
end

type Layers = { images: { string }, positions: { string }, sizes: { string } }

-- Each bar's lit tip, where its window stands.
local function tips(line: Line, strength: number): Layers
	local layers: Layers = { images = {}, positions = {}, sizes = {} }
	for _, bar in line.bars do
		local x = (bar.at + bar.fill) * GLYPH
		table.insert(layers.images, tip_image(bar.b, strength))
		table.insert(layers.positions, string.format("%spx %spx", num(x - TIP_W / 2), num(BAR_Y - TIP_H / 2)))
		table.insert(layers.sizes, string.format("%s %spx", fits(bar, TIP_W), num(TIP_H)))
	end
	return layers
end

-- The hover target (see the header), laid over the usage line: the composer's chips row while it's empty, or the
-- first attachment chip's empty end slot while attachments show.
local CHIPS = ".sf-col[data-role^='omp.editor'] > .sf-row[data-role='omp.composer.chips']"
local HOST = ":is("
	.. CHIPS
	.. ":is(.sf-hidden, .sf-void), "
	.. CHIPS
	.. " > .sf-card:first-child > .sf-card-head > .sf-card-end:is(.sf-hidden, .sf-void))"
-- Spine's `--sp-side` (Tern's `max(calc(var(--sp-pad) + var(--tv-px, 0px)), calc(50% - 420px))` on the dock, with
-- `--sp-pad` its `max(16px, min(40px, 4%))`) for the column's box, used from the meter, which is that box less its
-- 16px right inset: both percentages are taken of `100% + 16px`.
local SPINE_SIDE =
	"max(calc(max(16px, min(40px, calc((100% + 16px) * 0.04))) + var(--tv-px, 0px)), calc((100% + 16px) / 2 - 420px))"

-- The pane the line is drawn in: the focused one (`.tn-pane.on`), or, while the settings panel has focus and its
-- tab holds a single agent pane, that pane (`.tn-pane.agent`), so a click in the panel shows on the line beside it at
-- once instead of when the agent pane has focus again. Set by `refresh` before it draws.
local FOCUSED_PANE = ".tn-pane.on"
local line_pane = FOCUSED_PANE

-- The context meter in the line's pane; `region` narrows it as in `host` (`.sf-chat-spine`).
local function meter(region: string?): string
	return line_pane .. " " .. (if region then region .. " " else "") .. ".sf-meter[data-role='omp.composer.context']"
end

-- The target in the line's pane; `region` narrows it by a class of the surface region (`.sf-chat-reader`,
-- `.sf-still`), which sits between the pane and the composer.
local function host(region: string?): string
	return line_pane .. " " .. (if region then region .. " " else "") .. HOST
end

-- The providers' colors as variables on the composer, which the line, its tips, the capsule and the card all
-- sit in; the capsule's ring and the card's glow follow the line's one provider (with several, the theme's), and
-- the ring turns `--warn` or `--bad` with the lowest window. `target` sets them elsewhere (the panel's preview).
local function palette_css(model: Model, settings: Settings, target: string?): string
	local lines: { string } = {}
	local lowest: number? = nil
	for g, group in model.groups do
		local palette = palette_for(settings, group.id, group.label)
		table.insert(lines, string.format("\t--ou-g%d-a: %s;", g, palette.a))
		table.insert(lines, string.format("\t--ou-g%d-b: %s;", g, palette.b or palette.a))
		for _, window in group.windows do
			lowest = if lowest == nil then window.pct else math.min(lowest :: number, window.pct)
		end
	end
	local low = if lowest then tone_of(lowest) else "ok"
	local one = #model.groups == 1
	local ring = if low == "warn"
		then faded("var(--warn)", 45)
		elseif low == "bad" then faded("var(--bad)", 50)
		elseif one then faded(group_color(1, "a"), 40)
		else "var(--l2)"
	table.insert(lines, "\t--ou-ring: " .. ring .. ";")
	table.insert(lines, "\t--ou-glow: " .. (if one then group_color(1, "a") else "var(--accent)") .. ";")
	-- Tern's popover glass is translucent and counts on a backdrop blur, which doesn't take on the card, so text
	-- behind it would show through: the capsule and card take the glass's color (the card's, in light) opaque
	table.insert(lines, "\t--ou-glass: light-dark(rgb(from var(--card) r g b / 1), rgb(from var(--pop-bg) r g b / 1));")
	return (target or line_pane .. " .sf-col[data-role^='omp.editor']") .. " {\n" .. table.concat(lines, "\n") .. "\n}"
end

-- The line twice: on the meter at rest, and on the hover target over it, at full strength. The target's two
-- pseudo-elements are all a hover can change: Tern restyles the hovered element and its own parts, not its
-- siblings (`:hover +` never updates there), and the line lives on the meter, which comes before the target. So
-- the target's box is the capsule, its `::before` the bright copy, glyph for glyph over the line, and its
-- `::after` the card.
local LINE_CSS = [==[
/* room above the hairline for the usage line, clear of the working row (in spine, under it: see below); every agent
   pane, so focus never shifts it */
.sf-dock .sf-col[data-role^='omp.editor'] {
	margin-top: 15px;
}
/* the providers' colors */
$PALETTE
/* the line: 10px mono in a 13px box whose second line (where a window that doesn't fit wraps) is cut off; one
   static gradient clipped to the text colors its parts and fills its bars */
$METER::before,
$HOST::before {
	content: $CONTENT;
	height: 13px;
	overflow: hidden;
	white-space: pre-wrap;
	text-overflow: ellipsis;
	font: 500 10px/15px var(--mono);
	font-variant-numeric: tabular-nums;
	color: transparent;
	background-image: $PAINT;
	background-repeat: no-repeat;
	background-clip: text;
	pointer-events: none;
	--ou-lbl: var(--t3);
	--ou-sep: var(--t4);
	--ou-num-ok: var(--t2);
	--ou-num-warn: var(--warn);
	--ou-num-bad: var(--bad);
	--ou-dim: var(--t4);
	--ou-soft: var(--t3);
	--ou-track: color-mix(in srgb, var(--t1) 13%, transparent);
}
/* the text is the focused agent's, so it shows on the focused pane only */
$METER::before {
	position: absolute;
	left: 0;
	right: 0;
	bottom: 100%;
	margin-bottom: 2px;
}
$TIPS_CSS
/* Spine lays the meter across the whole dock, from its left edge, with the working row right above it, and insets
   the composer's column by its `--sp-side`: there the line goes under the hairline instead, on the column, in the
   room the margin above leaves between the hairline and the input. Its tips and comets (`::after`) go with it.
   `--sp-side` takes half the width of the box it's used in, and the meter is 16px narrower than the column's box
   (`right: 16px`), so here it is Tern's formula over that box's width. */
$METER_SPINE::before,
$METER_SPINE::after {
	left: $SPINE_SIDE;
	right: calc($SPINE_SIDE - 16px);
	top: calc(100% + 4px);
	bottom: auto;
	margin-bottom: 0;
}
/* with attachments the target is the first chip's end slot: the row doesn't clip it, and the chip isn't its
   containing block, so it is placed from the composer, as the empty row is */
$CHIPS {
	overflow: visible;
}
$CHIPS > .sf-card:first-child {
	position: static;
}
/* the hover target over the line: the meter's place in each chat style, widened by the capsule's 6px pad, as
   long as the line (or the meter, if that's shorter) */
$HOST {
	display: block !important;
	position: absolute;
	left: 12px;
	top: -28px;
	width: min($WIDTH, calc(100% - 24px));
	height: 15px;
	min-height: 0;
	margin: 0;
	padding: 0;
	overflow: visible;
	opacity: 1;
	z-index: 5;
	pointer-events: auto;
	border-radius: 8px;
	background-color: transparent;
	box-shadow: 0 0 0 1px transparent, 0 8px 20px -12px transparent, inset 0 1px 0 transparent;
	transition:
		background-color 0.2s var(--ease),
		box-shadow 0.2s var(--ease);
}
$HOST_READER {
	left: 16px;
	width: min($WIDTH, calc(100% - 32px));
}
$HOST_SPINE {
	left: calc(var(--sp-side) - 6px);
	top: 5px;
	width: min($WIDTH, calc(100% - 2 * var(--sp-side) + 12px));
}
$HOST_CONSOLE {
	left: calc(max(0px, (100% - 1040px) / 2) + var(--cn-gut) - 12px);
	width: min($WIDTH, calc(min(100%, 1040px) - var(--cn-gut) + 12px));
}
/* hovered, the line lifts into a glass capsule, ringed in its provider's color (or the lowest window's tone) */
$HOST:hover {
	background-color: var(--ou-glass);
	box-shadow:
		0 0 0 1px var(--ou-ring),
		0 8px 20px -12px light-dark(rgba(0, 0, 0, 0.28), rgba(0, 0, 0, 0.8)),
		inset 0 1px 0 var(--glass-hi);
}
/* and comes up to full strength: the copy fades in over it, the capsule hiding the line beneath */
$HOST::before {
	position: absolute;
	left: 6px;
	right: 6px;
	top: 1px;
	background-image: $PAINT$HOVER_IMAGES;
	background-position: 0 0$HOVER_POSITIONS;
	background-size: auto$HOVER_SIZES;
	background-clip: text$HOVER_CLIPS;
	opacity: 0;
	transition: opacity 0.2s var(--ease);
	--ou-lbl: var(--t2);
	--ou-sep: var(--t3);
	--ou-num-ok: var(--t1);
	--ou-dim: var(--t3);
	--ou-soft: var(--t2);
	--ou-track: color-mix(in srgb, var(--t1) 20%, transparent);
}
$HOST:hover::before {
	opacity: 1;
}
]==]

-- The tips at rest, on the meter's `::after`, which a change's comets take over (pulse_css).
local TIPS_CSS = [==[
/* each bar's lit tip, where its window stands */
$METER::after {
	content: "";
	position: absolute;
	left: 0;
	right: 0;
	bottom: 100%;
	margin-bottom: 2px;
	height: 13px;
	background-image: $IMAGES;
	background-position: $POSITIONS;
	background-size: $SIZES;
	background-repeat: no-repeat;
	pointer-events: none;
}]==]

local function line_css(line: Line, model: Model, settings: Settings): string
	local paint = line_paint(line)
	local rest = tips(line, 55)
	local lit = tips(line, 70)
	local function more(list: { string }): string
		return if #list > 0 then ", " .. table.concat(list, ", ") else ""
	end
	local clips: { string } = {}
	for _ in lit.images do
		table.insert(clips, "border-box")
	end
	return fill(LINE_CSS, {
		METER = meter(),
		METER_SPINE = meter(".sf-chat-spine"),
		SPINE_SIDE = SPINE_SIDE,
		CHIPS = line_pane .. " " .. CHIPS,
		HOST = host(nil),
		HOST_READER = host(".sf-chat-reader"),
		HOST_SPINE = host(".sf-chat-spine"),
		HOST_CONSOLE = host(".sf-chat-console"),
		PALETTE = palette_css(model, settings),
		CONTENT = css_string(line.text),
		PAINT = paint,
		TIPS_CSS = if #rest.images > 0
			then fill(TIPS_CSS, {
				METER = meter(),
				IMAGES = table.concat(rest.images, ", "),
				POSITIONS = table.concat(rest.positions, ", "),
				SIZES = table.concat(rest.sizes, ", "),
			})
			else "",
		WIDTH = num(line.glyphs * GLYPH + 12) .. "px",
		HOVER_IMAGES = more(lit.images),
		HOVER_POSITIONS = more(lit.positions),
		HOVER_SIZES = more(lit.sizes),
		HOVER_CLIPS = more(clips),
	})
end

-- The card's rows for a model (the first is the title): clock times are worked out when a model first shows, so
-- they don't drift with every poll between the extension's 60s refreshes. With several providers each gets a
-- row of its label in its color. A saved reset's row (its expiry date, from the cache) sits under the window
-- that counts it (`+N`); without dates the line's count stands in. `hint`, last, says how to open the settings.
-- A provider with several accounts gets a row in its color per account, over that account's windows (`alice`, or
-- `Claude alice` beside other providers), and while one account is chosen the others follow it a row each, what
-- they have left at a glance: the card can't be clicked, so it shows the rest rather than tabs. The card keeps to
-- the user's limit (`limit` rows, see CARD_ROWS): past it, the accounts the line starts with keep their windows in
-- full as long as the card fits, and the rest get that one row instead, colored by their lowest window; if even
-- that is too tall, the last of those rows fold into one, `+4 more accounts · lowest 7D 5%`. An account picked in
-- the panel always shows its windows in full: it was picked to be seen. Only when it and the providers without
-- accounts outgrow the limit on their own is the card taller (the panel says so).

-- An account's windows on one row, each window's saved resets beside it as the line has them (`+NF` for Fable
-- resets): `alice · 7D 65% +2 · FABLE 7D 81% +1F`.
local function account_summary(prefix: string, windows: { Window }, provider: string?): (string, number)
	local text = prefix
	local lowest = 100
	for _, window in windows do
		text ..= " · " .. string.upper(window.bare or window.label) .. " " .. tostring(window.pct) .. "%"
		if window.saved then
			text ..= " +" .. tostring(window.saved) .. (if is_fable(provider, window.bare or window.label) then "F" else "")
		end
		lowest = math.min(lowest, window.pct)
	end
	return text, lowest
end

-- `fixed` builds the card as the panel measures it instead of fitting it to `limit`: "all", every account in full
-- and a row for every other; "least", every account summed up and every summary folded.
local function card(model: Model, hint: string, limit: number, fixed: string?): { Row }
	local key = model.signature .. "\n" .. hint .. "\n" .. tostring(limit) .. "\n" .. tostring(fixed)
	if key == card_for then
		return card_rows
	end
	local now = now_ms()
	-- an account's (or provider's) rows in full, by group and run: the same in every build, so made once
	local done: { [string]: { Row } } = {}
	-- `full`: how many accounts, in the line's order, show their windows; of the rest, `keep` get a row each (the
	-- accounts not chosen beside a picked one count too) and the others fold into one row per provider. A picked
	-- account (its provider has `rest`) always shows in full. The rows also carry `runs`: how many rows each
	-- account shown in full takes, by `<group key>/<account>` (the panel measures picks with them).
	local function build(full: number, keep: number): { Row }
		local shown, kept = 0, 0
		local rows: { Row } = { { text = model.title, color = "var(--oc-head)" } }
		local runs_rows: { [string]: number } = {}
		local several = #model.groups > 1
		for g, group in model.groups do
			local accent = group_color(g, "a")
			local first = group.windows[1]
			if several and not (first and first.lead) then
				table.insert(rows, { text = group.label, color = accent })
			end
			local resets = group.resets or {}
			local function add_resets(into: { Row }, label: string): boolean
				local fable = is_fable(group.id, label)
				local added = false
				for _, reset in resets do
					if reset.window == label or (reset.window == nil and label == "7d") then
						local text = reset_text(reset, now, fable)
						if text then
							added = true
							table.insert(into, {
								text = CARD_INDENT .. text,
								color = if reset.at - now <= RESET_WARN_MS then "var(--oc-warn)" else accent,
							})
						end
					end
				end
				return added
			end
			-- an account's row, or (past `keep`) its share of the provider's fold
			local folded, lowest, lowest_text, fold_muted = 0, 101, "", false
			local function one_row(name: string, windows: { Window }, color: string?, rule: boolean)
				if kept < keep then
					kept += 1
					local text, low = account_summary((if several then group.label .. " " else "") .. name, windows, group.id)
					local tone = tone_of(low)
					table.insert(rows, {
						text = text,
						color = color or (if tone == "ok" then accent else "var(--oc-win-" .. tone .. ")"),
						rule = rule,
					})
					return
				end
				folded += 1
				fold_muted = fold_muted or color ~= nil
				for _, window in windows do
					if window.pct < lowest then
						lowest, lowest_text = window.pct, string.upper(window.bare or window.label) .. " " .. tostring(window.pct) .. "%"
					end
				end
			end
			-- the group's windows by account (one run, for a provider without accounts)
			local runs: { { name: string?, windows: { Window } } } = {}
			for _, window in group.windows do
				if #runs == 0 or (window.lead and window.account) then
					table.insert(runs, { name = window.account, windows = {} })
				end
				table.insert(runs[#runs].windows, window)
			end
			for r, run in runs do
				if run.name and group.rest == nil and shown >= full then
					one_row(run.name :: string, run.windows, nil, r > 1)
					continue
				end
				if run.name and group.rest == nil then
					shown += 1
				end
				local made = g .. ":" .. tostring(r)
				local part = done[made]
				if part == nil then
					local new: { Row } = {}
					if run.name then
						table.insert(new, {
							text = (if several then group.label .. " " else "")
								.. (run.windows[1].plan or run.name :: string),
							color = accent,
							rule = r > 1,
						})
					end
					for _, window in run.windows do
						local tone = tone_of(window.pct)
						local a, b = window_colors(tone, g)
						table.insert(new, {
							text = window_name(window.bare or window.label) .. " window",
							right = tostring(window.pct) .. "% left",
							color = "var(--oc-win-" .. tone .. ")",
							share = math.clamp(window.pct, 0, 100) / 100,
							a = a,
							b = b,
						})
						if window.covers then
							table.insert(new, { text = CARD_INDENT .. (window.covers :: string), color = "var(--oc-mute)" })
						end
						local has_dates = add_resets(new, string.lower(window.label))
						if not has_dates and window.saved then
							local saved = window.saved :: number
							local kind = if is_fable(group.id, window.label) then "Fable reset" else "saved reset"
							local row = string.format("%d %s%s", saved, kind, if saved == 1 then "" else "s")
							if window.expires then
								row ..= " · expires in " .. (window.expires :: string)
							end
							table.insert(new, {
								text = CARD_INDENT .. row,
								color = if window.expires then "var(--oc-warn)" else accent,
							})
						end
						local reset = window.reset
						if reset == "soon" then
							table.insert(new, { text = CARD_INDENT .. "resets soon", color = "var(--oc-mute)" })
						elseif reset then
							local row = "resets in " .. reset
							local minutes, exact = countdown_minutes(reset)
							local at = if minutes then clock_at(minutes, exact) else nil
							if at then
								row ..= " · " .. at
							end
							table.insert(new, { text = CARD_INDENT .. row, color = "var(--oc-mute)" })
						end
					end
					done[made] = new
					part = new
				end
				for _, row in part :: { Row } do
					table.insert(rows, row)
				end
				if run.name then
					runs_rows[group.key .. "/" .. (run.name :: string)] = #(part :: { Row })
				end
			end
			-- the accounts not chosen: `bob · 5H 40% · 7D 17%`
			local rest: { { name: string, windows: { Window } } } = {}
			for _, window in (group.rest or {}) :: { Window } do
				if window.lead or #rest == 0 then
					table.insert(rest, { name = window.account or "", windows = {} })
				end
				table.insert(rest[#rest].windows, window)
			end
			for i, account in rest do
				one_row(account.name, account.windows, "var(--oc-mute)", i == 1)
			end
			if folded > 0 then
				local tone = tone_of(lowest)
				table.insert(rows, {
					text = string.format(
						"%s+%d more account%s · lowest %s",
						if several then group.label .. " " else "",
						folded,
						if folded == 1 then "" else "s",
						lowest_text
					),
					color = if fold_muted then "var(--oc-mute)" elseif tone == "ok" then accent else "var(--oc-win-" .. tone .. ")",
				})
			end
		end
		for _, other in model.others do
			table.insert(rows, { text = other, color = "var(--oc-soft)" })
		end
		table.insert(rows, { text = hint, color = "var(--oc-hint)", rule = true })
		card_runs = runs_rows
		return rows
	end
	-- the accounts that can show in full, and those that can only get a row (the ones beside a picked account)
	local accounts, others = 0, 0
	for _, group in model.groups do
		for _, window in group.windows do
			if window.account and window.lead and group.rest == nil then
				accounts += 1
			end
		end
		for i, window in (group.rest or {}) :: { Window } do
			if window.lead or i == 1 then
				others += 1
			end
		end
	end
	local every = accounts + others
	if fixed then
		card_for, card_rows = key, if fixed == "all" then build(accounts, every) else build(0, 0)
		return card_rows
	end
	-- every account in full, unless that outgrows the limit: then as many as fit, the first accounts first; with
	-- none in full still too tall, as many summary rows as fit. Fewer of either only shrinks the card, so halve.
	local rows = build(accounts, every)
	if #rows > limit then
		rows = build(0, every)
		if #rows <= limit then
			local low, high = 1, accounts - 1
			while low <= high do
				local mid = (low + high) // 2
				local trial = build(mid, every)
				if #trial <= limit then
					rows, low = trial, mid + 1
				else
					high = mid - 1
				end
			end
		else
			rows = build(0, 0)
			local low, high = 1, every - 1
			while low <= high do
				local mid = (low + high) // 2
				local trial = build(0, mid)
				if #trial <= limit then
					rows, low = trial, mid + 1
				else
					high = mid - 1
				end
			end
		end
	end
	card_for = key
	card_rows = rows
	return rows
end

local CARD_CSS = [==[
/* the card: the line's facts spelled out over it, a row each, in a glass panel with a title bar; one gradient,
   row by row, colors the text, and each window's row sits on a meter with a lit tip */
$TARGET {
	content: "$CONTENT";
	$PLACE
	padding: 5px 12px 9px;
	border-radius: 12px;
	white-space: pre;
	font: 500 11px/18px var(--mono);
	font-variant-numeric: tabular-nums;
	color: transparent;
	background-color: var(--ou-glass);
	background-image: $IMAGES;
	background-position: $POSITIONS;
	background-size: $SIZES;
	background-repeat: no-repeat;
	background-origin: $ORIGINS;
	background-clip: $CLIPS;
	box-shadow:
		0 0 0 1px var(--l2),
		0 22px 44px -18px light-dark(rgba(0, 0, 0, 0.3), rgba(0, 0, 0, 0.85)),
		0 6px 14px -8px light-dark(rgba(0, 0, 0, 0.12), rgba(0, 0, 0, 0.55)),
		inset 0 1px 0 var(--glass-hi);
	pointer-events: none;
	$MOTION
	--oc-head: var(--t1);
	--oc-win-ok: var(--t1);
	--oc-win-warn: var(--warn);
	--oc-win-bad: var(--bad);
	--oc-mute: var(--t3);
	--oc-soft: var(--t2);
	--oc-warn: var(--warn);
	--oc-track: color-mix(in srgb, var(--t1) 10%, transparent);
	--oc-hint: light-dark(var(--t3), color-mix(in srgb, var(--t3) 60%, var(--t4)));
}
$KEYFRAMES]==]

-- The card's rise and fill. Keyframe names are global, so only the composer's card brings them: the preview's
-- own (its meters) would replace the composer's.
local CARD_KEYFRAMES = [==[
@keyframes omp-usage-card {
	from { opacity: 0; transform: translateY(5px) scale(0.97); }
	to { opacity: 1; transform: none; }
}
@keyframes omp-usage-fill {
	from { background-size: $FROM_SIZES; }
	to { background-size: $SIZES; }
}
]==]

-- The card's sheet for its rows. By default it is the hover target's `::after` over the line, rising into place
-- after a beat; `target` (the settings panel's preview) draws the same card, still, on another element.
local function card_css(rows: { Row }, target: string?): string
	local width = CARD_MIN
	for _, row in rows do
		local n = glyph_count(row.text)
		if row.right then
			n += 4 + glyph_count(row.right :: string)
		end
		width = math.max(width, n)
	end
	local lines: { string } = {}
	local paint: { string } = {}
	-- [1] is the text's paint, set below; then a tip, fill and track per window, then the title bar
	local images: { string } = { "" }
	local positions: { string } = { "0 0" }
	local sizes: { string } = { "100% 100%" }
	local from_sizes: { string } = { "100% 100%" }
	local origins: { string } = { "content-box" }
	local clips: { string } = { "text" }
	local function layer(image: string, position: string, size: string, from: string, origin: string)
		table.insert(images, image)
		table.insert(positions, position)
		table.insert(sizes, size)
		table.insert(from_sizes, from)
		table.insert(origins, origin)
		table.insert(clips, "padding-box")
	end
	for i, row in rows do
		local y = (i - 1) * CARD_ROW
		local text = row.text
		if row.right then
			local right = row.right :: string
			text ..= string.rep(" ", width - glyph_count(row.text) - glyph_count(right)) .. right
			local a = row.a or "var(--accent)"
			local b = row.b or a
			local share = row.share or 0
			local meter = y + CARD_ROW - 1 -- under the row's descenders, above the next row's glyphs
			-- a background-position percentage places the layer's own share of the slack: this centers the tip on it
			layer(
				tip_image(b, 70),
				string.format("calc(%s%% + %spx) %spx", num(share * 100), num(share * TIP_W - TIP_W / 2), num(meter - 2)),
				string.format("%spx %spx", num(TIP_W), num(TIP_H)),
				string.format("%spx %spx", num(TIP_W), num(TIP_H)),
				"content-box"
			)
			layer(
				string.format("linear-gradient(90deg, %s, %s)", faded(a, 40), solid(b)),
				string.format("0 %spx", num(meter)),
				string.format("calc(100%% * %s) 2px", num(share, 4)),
				"0px 2px",
				"content-box"
			)
			layer(
				string.format("linear-gradient(%s, %s)", solid("var(--oc-track)"), solid("var(--oc-track)")),
				string.format("0 %spx", num(meter)),
				"100% 2px",
				"100% 2px",
				"content-box"
			)
		end
		if row.rule then
			layer(
				string.format("linear-gradient(90deg, %s, %s)", solid("var(--l2)"), faded("var(--l2)", 0)),
				string.format("0 %spx", num(y + 1)),
				"100% 1px",
				"100% 1px",
				"content-box"
			)
		end
		table.insert(lines, string.sub(css_string(text), 2, -2))
		table.insert(paint, string.format("%s %spx %spx", solid(row.color), num(y), num(y + CARD_ROW)))
	end
	images[1] = "linear-gradient(180deg, " .. table.concat(paint, ", ") .. ")"
	-- the title bar: a lighter band down to a hairline under the title, and a glow of the provider's color (with
	-- several, the theme accent) from its corner
	local band = string.format("%spx", num(5 + CARD_ROW - 1))
	layer(
		string.format("linear-gradient(90deg, %s, %s)", solid("var(--l3)"), solid("var(--l1)")),
		"0 " .. band,
		"100% 1px",
		"100% 1px",
		"padding-box"
	)
	layer(
		string.format("linear-gradient(%s, %s)", solid("var(--l1)"), solid("var(--l1)")),
		"0 0",
		"100% " .. band,
		"100% " .. band,
		"padding-box"
	)
	layer(
		string.format("radial-gradient(130%% 150%% at 0%% 0%%, %s, transparent 60%%)", faded("var(--ou-glow)", 14)),
		"0 0",
		"100% 100%",
		"100% 100%",
		"padding-box"
	)
	local sizes_css = table.concat(sizes, ", ")
	return fill(CARD_CSS, {
		TARGET = target or host(nil) .. ":hover::after",
		PLACE = if target then "display: block;" else "position: absolute;\n\tleft: 0;\n\tbottom: calc(100% + 8px);",
		MOTION = if target
			then ""
			else "transform-origin: 16px 100%;\n\t/* after a beat: it rises into place and its meters fill */\n\tanimation:\n\t\tomp-usage-card 0.28s var(--out) 0.35s both,\n\t\tomp-usage-fill 0.7s var(--out) 0.4s both;",
		KEYFRAMES = if target then "" else fill(CARD_KEYFRAMES, { FROM_SIZES = table.concat(from_sizes, ", "), SIZES = sizes_css }),
		CONTENT = table.concat(lines, "\\A "),
		IMAGES = table.concat(images, ", "),
		POSITIONS = table.concat(positions, ", "),
		SIZES = sizes_css,
		ORIGINS = table.concat(origins, ", "),
		CLIPS = table.concat(clips, ", "),
	})
end

-- Filled per sheet (sheet), so it follows the line's pane as the rest of the line does.
local STILL_CSS = [==[
/* Reduce Motion, either way: no fades, no rise, no fill, no change sweep; the card still waits its beat, then
   shows at once */
$HOST_STILL,
$HOST_STILL::before {
	transition: none;
}
$HOST_STILL:hover::after {
	animation: omp-usage-card-still 0s 0.35s both !important;
}
$METER_STILL::before,
$METER_STILL::after {
	animation: none !important;
}
@media (prefers-reduced-motion: reduce) {
	$HOST,
	$HOST::before {
		transition: none;
	}
	$HOST:hover::after {
		animation: omp-usage-card-still 0s 0.35s both !important;
	}
	$METER::before,
	$METER::after {
		animation: none !important;
	}
}
@keyframes omp-usage-card-still {
	from { opacity: 0; }
	to { opacity: 1; }
}
]==]

local PULSE_CSS = [==[
/* the change: the line prints again, left to right, while a comet runs each changed bar to its new level,
   flares and settles into its tip */
$METER::before {
	-stencil-text-effect: reveal;
	-stencil-text-offset: 0 3px;
	-stencil-text-blur: 2px;
	-stencil-text-stagger: 0.008;
	animation: $REVEAL 700ms var(--out) 1 both;
}
$METER::after {
	animation: $RUN $DURATION linear 1 both;
}
@keyframes $REVEAL {
	from { -stencil-progress: 0; }
	to { -stencil-progress: 1; }
}
@keyframes $RUN {
$FRAMES
}
]==]

local function eased(u: number): number
	return if u < 0.5 then 4 * u * u * u else 1 - ((2 - 2 * u) ^ 3) / 2
end

-- The comets, as keyframes over the tips' layers (a head and a trail per bar; a bar that didn't move keeps its
-- tip): the head appears at the bar's start, runs to the share, flares and shrinks into the tip, the trail behind
-- it; in the bar's color when quota went down, `--ok` when it came back.
local function pulse_css(line: Line, p: Pulse): string
	local frames: { string } = {}
	for _, at in RUN_STOPS do
		local images: { string } = {}
		local positions: { string } = {}
		local sizes: { string } = {}
		for _, bar in line.bars do
			local from = bar.at * GLYPH
			local to = (bar.at + bar.fill) * GLYPH
			local x, w, h, trail, ink, strength = to, TIP_W, TIP_H, 0, bar.b, 55
			local way = p.moved[bar.key]
			if way then
				local u = if at <= RUN_SET then 0 elseif at >= RUN_ARRIVE then 1 else (at - RUN_SET) / (RUN_ARRIVE - RUN_SET)
				x = from + (to - from) * eased(u)
				if at <= RUN_SET then
					w, h = HEAD_W * at / RUN_SET, HEAD_H * at / RUN_SET
				elseif at <= RUN_ARRIVE then
					w, h = HEAD_W, HEAD_H
				elseif at <= RUN_FLARE then
					local k = 1 + 0.3 * (at - RUN_ARRIVE) / (RUN_FLARE - RUN_ARRIVE)
					w, h = HEAD_W * k, HEAD_H * k
				else
					local k = (at - RUN_FLARE) / (1 - RUN_FLARE)
					w = HEAD_W * 1.3 + (TIP_W - HEAD_W * 1.3) * k
					h = HEAD_H * 1.3 + (TIP_H - HEAD_H * 1.3) * k
				end
				trail = math.min(TRAIL_W, x - from)
				if at > RUN_ARRIVE then
					trail *= math.max(0, 1 - (at - RUN_ARRIVE) / (RUN_FLARE - RUN_ARRIVE))
				end
				ink = if at < 0.9 and way == "up" then PULSE_UP else bar.b
				strength = 80
			end
			table.insert(images, tip_image(ink, strength))
			table.insert(images, trail_image(ink))
			table.insert(positions, string.format("%spx %spx", num(x - w / 2), num(BAR_Y - h / 2)))
			table.insert(positions, string.format("%spx %spx", num(x - trail), num(BAR_Y - TRAIL_H / 2)))
			table.insert(sizes, string.format("%s %spx", fits(bar, w), num(h)))
			table.insert(sizes, string.format("%s %spx", fits(bar, trail), num(TRAIL_H)))
		end
		table.insert(
			frames,
			string.format(
				"\t%s%% { background-image: %s; background-position: %s; background-size: %s; }",
				num(at * 100),
				table.concat(images, ", "),
				table.concat(positions, ", "),
				table.concat(sizes, ", ")
			)
		)
	end
	return fill(PULSE_CSS, {
		METER = meter(),
		REVEAL = "omp-usage-reveal-" .. tostring(p.seq), -- a new name per change restarts the animation
		RUN = "omp-usage-run-" .. tostring(p.seq),
		DURATION = tostring(PULSE_MS) .. "ms",
		FRAMES = table.concat(frames, "\n"),
	})
end

local function sheet(model: Model, settings: Settings, p: Pulse?, hint: string): string
	if #model.groups == 0 and #model.others == 0 then
		return ""
	end
	local line = line_of(model)
	local still = fill(STILL_CSS, { HOST = host(nil), HOST_STILL = host(".sf-still"), METER = meter(), METER_STILL = meter(".sf-still") })
	local css = line_css(line, model, settings) .. card_css(card(model, hint, settings.card_rows)) .. still
	-- Only while it runs: a sheet rewritten later (a countdown tick) must not replay it.
	if p and #line.bars > 0 and tern.now() < p.until_ms then
		css ..= pulse_css(line, p)
	end
	return css
end

-- Hides the status facts the line redraws from the focused pane's bar, by their exact ids: `hook-N` numbers
-- depend on which statuses a session has set, so another pane's `hook-1` may be another extension's.
local function hide_css(ids: { string }): string
	if #ids == 0 then
		return ""
	end
	local selectors: { string } = {}
	for _, id in ids do
		table.insert(selectors, line_pane .. " [data-role='omp.composer.bar'] [data-id=" .. css_string(id) .. "]")
	end
	return table.concat(selectors, ",\n") .. " {\n\tdisplay: none !important;\n}\n"
end

local function install(css: string)
	if css ~= last_css then
		last_css = css
		tern.css(SHEET, css)
	end
end

-- The settings panel's action (the `panel` command) and its default shortcut.
local PANEL_ACTION = "plugin." .. tern.plugin.id .. ".panel"
local PANEL_KEYS = "ctrl+alt+u"
-- The panel's pane while it is open, and what redraws it (see the panel section); the dock last read, which
-- the panel's preview of the line is drawn from.
local panel_pane: number? = nil
local sync_panel: (cx: WindowCx, force: boolean, settings: Settings?, cache: Cache?) -> ()
local flush_panel: (cx: WindowCx) -> ()
local last_dock: Dock? = nil

-- A chord as the keymap spells it (`ctrl+alt+u`) for people (`Ctrl+Alt+U`); a sequence's steps are spaced.
local function chord_label(chord: string): string
	local steps: { string } = {}
	for step in string.gmatch(chord, "[^>]+") do
		local keys: { string } = {}
		for key in string.gmatch(step, "[^+]+") do
			table.insert(keys, string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2))
		end
		table.insert(steps, table.concat(keys, "+"))
	end
	return table.concat(steps, " ")
end

-- The panel's shortcut as the keymap has it now (the user may rebind or unbind it): the shortest chord bound
-- to the panel, read at most every 30s (every 2s while there is none: the keymap takes the plugin's binds a
-- moment after a reload). `cx.actions:describe` doesn't know plugin commands, so it comes from the chords.
local SHORTCUT_TTL_MS = 30000
local SHORTCUT_RETRY_MS = 2000
local shortcut_text: string? = nil
local shortcut_read_at: number? = nil

local function shortcut(cx: WindowCx): string?
	local now = tern.now()
	local ttl = if shortcut_text then SHORTCUT_TTL_MS else SHORTCUT_RETRY_MS
	if shortcut_read_at == nil or now - (shortcut_read_at :: number) >= ttl then
		shortcut_read_at = now
		local ok, keymap = pcall(function(): any
			return cx.actions:keys()
		end)
		local best: string? = nil
		if ok and type(keymap) == "table" then
			for chord, actions in keymap do
				if type(chord) == "string" and type(actions) == "table" and table.find(actions, PANEL_ACTION) then
					if best == nil or #chord < #(best :: string) or (#chord == #(best :: string) and chord < (best :: string)) then
						best = chord
					end
				end
			end
		end
		shortcut_text = if best then chord_label(best :: string) else nil
	end
	return shortcut_text
end

-- The card's last row: how to open the settings.
local function settings_hint(keys: string?): string
	return "settings · " .. (keys or "omp Usage in the palette")
end

local refresh: (cx: WindowCx) -> ()
-- What the installed sheet was built from (see `show_pane`).
local sheet_key: string? = nil

-- The color choices as one string, in a fixed order.
local function colors_key(settings: Settings): string
	local ids: { string } = {}
	for id in settings.colors do
		table.insert(ids, id)
	end
	table.sort(ids)
	local parts: { string } = {}
	for _, id in ids do
		table.insert(parts, id .. "=" .. settings.colors[id])
	end
	return table.concat(parts, ";")
end

-- The hidden windows as one string, in a fixed order.
local function hidden_key(settings: Settings): string
	local parts: { string } = {}
	for id, labels in settings.hidden do
		table.insert(parts, id .. "=" .. table.concat(labels, ","))
	end
	table.sort(parts)
	return table.concat(parts, ";")
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
	local hint = settings_hint(shortcut(cx))
	local running = if pulse and tern.now() < pulse.until_ms then pulse.seq else 0
	local hidden = table.concat(dock.hide, "\n")
	local key = table.concat({ model.signature, colors_key(settings), hint, tostring(running), hidden, line_pane }, "\n")
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
		elseif info and pane == panel_pane then
			target = shown_pane or some_agent(cx, info.tab)
			local beside = agents_in(cx, info.tab)
			if #beside == 1 and beside[1] == target then
				scope = ".tn-pane.agent"
			end
		end
	end
	if scope ~= line_pane and target == nil then
		target = shown_pane -- redraw the last line in its usual place, the focused pane
	end
	line_pane = scope
	if target == nil and panel_pane == nil then
		return
	end
	local settings = load_settings()
	local raw = cache_raw
	local cache = read_cache(now_ms())
	if target ~= nil then
		show_pane(cx, target :: number, settings, cache)
	end
	-- A poll that just decoded a rewritten cache (the extension's, once a minute; tens of ms for a big one) has
	-- spent much of its timer's 50ms: the panel's redraw waits for the next poll.
	if panel_pane ~= nil and cache_raw == raw then
		sync_panel(cx, false, settings, cache)
	end
end

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

-- Settings, two ways: the panel (a canvas beside the focused pane: the `omp Usage: Settings panel` command,
-- Ctrl+Alt+U, or `usage` in the status bar) and pickers (`omp Usage: Settings…`). Both store what is chosen in
-- `tern.kv` and redraw the line at once; the menus and the panel are built by the plain functions below.

-- The providers on offer, in the user's order.
local function providers_in_order(settings: Settings): { Provider }
	return ordered(store.providers(), settings.order)
end

local function label_of(providers: { Provider }, id: string): string
	for _, provider in providers do
		if provider.id == id then
			return provider.label
		end
	end
	return id
end

-- The providers `selected` shows, by label in the user's order; nil when there are none.
local function chosen_labels(settings: Settings, providers: { Provider }): string?
	local chosen: { string } = {}
	for _, provider in providers do
		if table.find(settings.selected, provider.id) then
			table.insert(chosen, provider.label)
		end
	end
	for _, id in settings.selected do
		if label_of(providers, id) == id then -- not on offer now
			table.insert(chosen, id)
		end
	end
	return if #chosen > 0 then table.concat(chosen, ", ") else nil
end

local MODES: { { mode: string, label: string } } = {
	{ mode = "current", label = "Current model" },
	{ mode = "all", label = "All providers" },
	{ mode = "selected", label = "Selected providers" },
}

-- What each mode shows, for the menu and the panel.
local function mode_details(settings: Settings, providers: { Provider }): { [string]: string }
	-- the cache's providers carry their lines; the known ones offered without a cache don't
	local cached = providers[1] ~= nil and providers[1].line ~= ""
	return {
		current = "the focused agent's provider",
		all = if cached then string.format("%d with limits", #providers) else "waiting for omp's usage cache",
		selected = chosen_labels(settings, providers) or "none chosen yet",
	}
end

-- The first few providers, in order.
local function order_summary(providers: { Provider }): string
	local labels: { string } = {}
	for i, provider in providers do
		if i > 3 then
			table.insert(labels, "…")
			break
		end
		table.insert(labels, provider.label)
	end
	return table.concat(labels, ", ")
end

-- The providers with several accounts, in order.
local function with_accounts(providers: { Provider }): { Provider }
	local list: { Provider } = {}
	for _, provider in providers do
		if #provider.accounts > 1 then
			table.insert(list, provider)
		end
	end
	return list
end

-- What a provider's accounts show, for the menus: `only alice`, `all: bob, alice` in their order, or how many
-- are on when there are many or some are switched off.
local function accounts_summary(settings: Settings, provider: Provider): string
	local chosen = chosen_account(settings, provider.id, provider.accounts)
	if chosen then
		return "only " .. chosen
	elseif settings.account[provider.id] == COMBINED then
		return "combined"
	elseif settings.account[provider.id] == COMBINED_PLANS then
		return "combined by plan"
	end
	local shown = shown_accounts(settings, provider)
	if #shown < #provider.accounts then
		return string.format("%d of %d on", #shown, #provider.accounts)
	elseif #shown > 3 then
		return string.format("all %d", #shown)
	end
	return "all: " .. table.concat(shown, ", ")
end

local function menu_items(settings: Settings, providers: { Provider }, keys: string?): { PickItem }
	local details = mode_details(settings, providers)
	local items: { PickItem } = {
		{
			label = "Open settings panel…",
			detail = "every setting in one place" .. (if keys then " · " .. keys else ""),
			icon = "sliders",
			pick = "panel",
		},
	}
	for _, mode in MODES do
		table.insert(items, {
			label = mode.label,
			detail = details[mode.mode],
			group = "Show",
			current = settings.mode == mode.mode,
			pick = "mode",
			mode = mode.mode,
		})
	end
	table.insert(items, { label = "Choose providers…", detail = details.selected, group = "Providers", pick = "choose" })
	table.insert(items, { label = "Reorder providers…", detail = order_summary(providers), group = "Providers", pick = "reorder" })
	table.insert(items, { label = "Provider colors…", detail = "presets, alternatives or your own", group = "Providers", pick = "colors" })
	table.insert(items, { label = "Provider windows…", detail = "which of each provider's windows show", group = "Providers", pick = "windows" })
	-- only with a provider signed in more than once
	local several = with_accounts(providers)
	if #several > 0 then
		table.insert(items, {
			label = "Provider accounts…",
			detail = if #several == 1 then several[1].label .. ", " .. accounts_summary(settings, several[1]) else "all of a provider's accounts, combined, or one",
			group = "Providers",
			pick = "accounts",
		})
	end
	table.insert(items, { label = "Card height…", detail = string.format("%d rows; past it, accounts sum up, then fold", settings.card_rows), group = "Card", pick = "card-rows" })
	table.insert(items, { label = "Check for updates…", detail = "fetch the plugin's repository and offer what's new", group = "Updates", icon = "download", pick = "update" })
	local every = update.interval()
	table.insert(items, {
		label = "Check automatically…",
		detail = every.label,
		group = "Updates",
		pick = "update-every",
	})
	return items
end

-- The selection with `id` added or taken out.
local function toggled(selected: { string }, id: string): { string }
	local list = table.clone(selected)
	local at = table.find(list, id)
	if at then
		table.remove(list, at)
	else
		table.insert(list, id)
	end
	return list
end

local function chooser_items(settings: Settings, providers: { Provider }): { PickItem }
	local items: { PickItem } = {}
	for _, provider in providers do
		table.insert(items, {
			label = provider.label,
			detail = provider.id,
			current = table.find(settings.selected, provider.id) ~= nil,
			pick = "toggle",
			id = provider.id,
		})
	end
	return items
end

local function reorder_items(providers: { Provider }): { PickItem }
	local items: { PickItem } = {}
	for i, provider in providers do
		table.insert(items, { label = provider.label, detail = string.format("%d of %d", i, #providers), pick = "provider", id = provider.id })
	end
	return items
end

-- The moves open to the `i`th of `n` providers.
local function move_items(i: number, n: number): { PickItem }
	local items: { PickItem } = {}
	if i > 1 then
		table.insert(items, { label = "Move up", icon = "arrow-up", pick = "up" })
	end
	if i < n then
		table.insert(items, { label = "Move down", icon = "arrow-down", pick = "down" })
	end
	if i > 1 then
		table.insert(items, { label = "Move to top", icon = "chev-up", pick = "top" })
	end
	if i < n then
		table.insert(items, { label = "Move to bottom", icon = "chev", pick = "bottom" })
	end
	return items
end

-- A color choice's name: the user's, else the preset's.
local function color_name(settings: Settings, provider: Provider): string
	local spec = settings.colors[color_key(provider.id, provider.label)]
	local chosen = if spec then palette_of_spec(spec) else nil
	return if chosen then chosen.name else preset_for(provider.id, provider.label).name .. " (preset)"
end

local function color_provider_items(settings: Settings, providers: { Provider }): { PickItem }
	local items: { PickItem } = {}
	for _, provider in providers do
		table.insert(items, {
			label = provider.label,
			detail = color_name(settings, provider),
			pick = "provider",
			id = provider.id,
			name = provider.label,
		})
	end
	return items
end

local function color_items(settings: Settings, provider: Provider): { PickItem }
	local spec = settings.colors[color_key(provider.id, provider.label)]
	local custom = spec ~= nil and string.sub(spec :: string, 1, 1) == "#"
	local items: { PickItem } = {
		{
			label = preset_for(provider.id, provider.label).name,
			detail = "preset",
			group = "Preset",
			current = spec == nil,
			pick = "set",
		},
	}
	for _, item in NAMED do
		table.insert(items, {
			label = item.palette.name,
			group = "Alternatives",
			current = spec == "named:" .. item.key,
			pick = "set",
			spec = "named:" .. item.key,
		})
	end
	table.insert(items, {
		label = "Custom…",
		detail = if custom then spec else "one or two hex colors",
		group = "Custom",
		current = custom,
		pick = "custom",
	})
	table.insert(items, { label = "Reset to preset", group = "Custom", pick = "set" })
	return items
end

local function save_color(id: string, spec: string?)
	local colors = load_settings().colors
	colors[id] = spec
	store.set(KV_COLORS, colors)
end

-- Hides provider `id`'s window `label` from the line, or shows it again.
local function toggle_window(id: string, label: string)
	local hidden = load_settings().hidden
	local list = toggled(hidden[id] or {}, string.lower(label))
	hidden[id] = if #list > 0 then list else nil
	store.set(KV_HIDDEN, hidden)
end

-- Moves provider `id` (`how`: see `moved`).
local function move_provider(id: string, how: string | number)
	local settings = load_settings()
	local shown: { string } = {}
	for _, provider in providers_in_order(settings) do
		table.insert(shown, provider.id)
	end
	store.set(KV_ORDER, moved(settings.order, shown, id, how))
end

-- The provider on offer as `id`.
local function offered(id: string): Provider?
	for _, provider in store.providers() do
		if provider.id == id then
			return provider
		end
	end
	return nil
end

-- Shows only account `name` of provider `id` on the line and in the card, its accounts combined (COMBINED, or by plan,
-- COMBINED_PLANS), or ("") every account again.
local function choose_account(id: string, name: string)
	local chosen = load_settings().account
	if name == "" then
		chosen[id] = nil
	else
		chosen[id] = name
	end
	store.set(KV_ACCOUNT, chosen)
end

-- Switches account `name` of provider `id` off (out of the line and the card) or on again. The account picked to
-- show alone can't stay picked while it is off, so switching it off shows the others again.
local function toggle_account(id: string, name: string)
	local settings = load_settings()
	local list = toggled(settings.account_hidden[id] or {}, name)
	if #list > 0 then
		settings.account_hidden[id] = list
	else
		settings.account_hidden[id] = nil
	end
	store.set(KV_ACCOUNT_HIDDEN, settings.account_hidden)
	if settings.account[id] == name and table.find(list, name) then
		choose_account(id, "")
	end
end

-- Moves account `name` of provider `id` among its accounts (`how`: see `moved`).
local function move_account(id: string, name: string, how: string | number)
	local provider = offered(id)
	if provider == nil then
		return
	end
	local orders = load_settings().account_order
	local order = orders[id] or {}
	orders[id] = moved(order, accounts_in_order((provider :: Provider).accounts, order), name, how)
	store.set(KV_ACCOUNT_ORDER, orders)
end

-- After the user changed a setting: redraws the line and the panel at once.
local function after_change(cx: WindowCx?)
	if cx then
		refresh(cx)
		flush_panel(cx)
	end
end

-- Asks for a provider's own colors; a bad answer toasts and changes nothing, an empty one nothing at all.
local function prompt_color(cx: WindowCx, key: string, label: string)
	local spec = load_settings().colors[key]
	cx:prompt({
		value = if spec and string.sub(spec, 1, 1) == "#" then spec else "",
		placeholder = label .. ": #d97757, or two: #9aa7b4, #5b8def",
		icon = "palette",
	}):next(function(text: string?, _err: string?, next_cx: WindowCx?)
		if text == nil or not string.find(text :: string, "%S") then
			return
		end
		local cx2 = next_cx or cx
		local colors, bad = parse_colors(text :: string)
		if colors == nil then
			cx2:toast("error", "Not a color: " .. tostring(bad), "Use #rrggbb, or two of them separated by a comma")
			return
		end
		save_color(key, table.concat(colors, ", "))
		after_change(cx2)
	end)
end

local open_chooser: (WindowCx) -> ()
local open_reorder: (WindowCx) -> ()
local open_color_choices: (WindowCx, Provider) -> ()

open_chooser = function(cx: WindowCx)
	local settings = load_settings()
	cx:pick({ items = chooser_items(settings, providers_in_order(settings)), placeholder = "Show which providers? Esc when done", action = "toggle" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local id = (item :: any).id :: string
			store.set(KV_SELECTED, toggled(load_settings().selected, id))
			store.set(KV_MODE, "selected") -- choosing providers is choosing to show them
			local cx2 = next_cx or cx
			after_change(cx2)
			open_chooser(cx2)
		end)
end

open_reorder = function(cx: WindowCx)
	local providers = providers_in_order(load_settings())
	cx:pick({ items = reorder_items(providers), placeholder = "Move which provider? Esc when done", icon = "list" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local id = (item :: any).id :: string
			local at = 1
			for i, provider in providers do
				if provider.id == id then
					at = i
				end
			end
			local moves = move_items(at, #providers)
			if #moves == 0 then
				return
			end
			local cx2 = next_cx or cx
			cx2:pick({ items = moves, placeholder = "Move " .. (item :: PickItem).label, icon = "list" })
				:next(function(choice: PickItem?, _err2: string?, last_cx: WindowCx?)
					if choice == nil then
						return
					end
					move_provider(id, (choice :: any).pick)
					local cx3 = last_cx or cx2
					after_change(cx3)
					open_reorder(cx3)
				end)
		end)
end

open_color_choices = function(cx: WindowCx, provider: Provider)
	local settings = load_settings()
	local key = color_key(provider.id, provider.label)
	cx:pick({ items = color_items(settings, provider), placeholder = provider.label .. " colors", icon = "palette" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local cx2 = next_cx or cx
			if (item :: any).pick == "custom" then
				prompt_color(cx2, key, provider.label)
				return
			end
			save_color(key, (item :: any).spec)
			after_change(cx2)
		end)
end

local function open_colors(cx: WindowCx)
	local settings = load_settings()
	cx:pick({ items = color_provider_items(settings, providers_in_order(settings)), placeholder = "Color which provider?", icon = "palette" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local chosen = item :: any
			open_color_choices(next_cx or cx, { id = chosen.id, label = chosen.name, line = "", resets = {}, windows = {}, accounts = {} })
		end)
end

-- The windows a provider shows, by label: `5H, FABLE 7D`.
local function windows_summary(settings: Settings, provider: Provider): string
	local labels: { string } = {}
	for _, window in shown_windows(settings, provider.id, provider.windows) do
		table.insert(labels, string.upper(window.label))
	end
	return if #labels > 0 then table.concat(labels, ", ") else "all hidden"
end

-- A provider's windows, each checked while the line shows it.
local function window_items(settings: Settings, provider: Provider): { PickItem }
	local hidden = settings.hidden[provider.id] or {}
	local items: { PickItem } = {}
	for _, window in provider.windows do
		table.insert(items, {
			label = window_name(window.label) .. " window",
			detail = string.upper(window.label) .. " · " .. tostring(window.pct) .. "% left",
			current = table.find(hidden, string.lower(window.label)) == nil,
			pick = "window",
			window = string.lower(window.label),
		})
	end
	return items
end

-- Toggles provider `id`'s windows one at a time; the list stays open until Esc.
local function open_window_choices(cx: WindowCx, id: string)
	local provider: Provider? = nil
	for _, item in store.providers() do
		if item.id == id then
			provider = item
		end
	end
	if provider == nil or #(provider :: Provider).windows == 0 then
		return
	end
	local chosen = provider :: Provider
	cx:pick({
		items = window_items(load_settings(), chosen),
		placeholder = chosen.label .. ": show which windows? Esc when done",
		action = "toggle",
	}):next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
		if item == nil then
			return
		end
		toggle_window(id, (item :: any).window)
		local cx2 = next_cx or cx
		after_change(cx2)
		open_window_choices(cx2, id)
	end)
end

local function open_windows(cx: WindowCx)
	local settings = load_settings()
	local items: { PickItem } = {}
	for _, provider in providers_in_order(settings) do
		if #provider.windows > 0 then
			table.insert(items, { label = provider.label, detail = windows_summary(settings, provider), id = provider.id })
		end
	end
	if #items == 0 then
		cx:toast("info", "No windows to choose from yet", "They come from omp's usage cache: focus an omp pane")
		return
	end
	cx:pick({ items = items, placeholder = "Choose windows for which provider?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			open_window_choices(next_cx or cx, (item :: any).id)
		end)
end

-- A provider's accounts in the pickers: every account switched on or one on the line and in the card (the list
-- closes on a pick), or their order, a move at a time until Esc. With `switches`, which accounts are on instead,
-- toggled one at a time until Esc.
local open_account_order: (WindowCx, string) -> ()

local function open_account_choices(cx: WindowCx, id: string, switches: boolean?)
	local found = offered(id)
	if found == nil or #(found :: Provider).accounts < 2 then
		return
	end
	local provider = found :: Provider
	local settings = load_settings()
	local names = accounts_in_order(provider.accounts, settings.account_order[id])
	-- an account's windows: `7D 68% · FABLE 7D 45%`
	local function left(name: string): string
		local parts: { string } = {}
		for _, window in provider.windows do
			local owner, bare = account_of(window.label, provider.accounts)
			if owner == name then
				table.insert(parts, string.upper(bare :: string) .. " " .. tostring(window.pct) .. "%")
			end
		end
		return table.concat(parts, " · ")
	end
	if switches then
		local items: { PickItem } = {}
		for _, name in names do
			table.insert(items, { label = name, detail = left(name), current = not account_off(settings, id, name), name = name })
		end
		cx:pick({ items = items, placeholder = provider.label .. ": which accounts show? Esc when done", action = "toggle" })
			:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
				if item == nil then
					return
				end
				toggle_account(id, (item :: any).name)
				local cx2 = next_cx or cx
				after_change(cx2)
				open_account_choices(cx2, id, true)
			end)
		return
	end
	local shown = shown_accounts(settings, provider)
	local chosen = chosen_account(settings, id, provider.accounts)
	local together = if chosen == nil then settings.account[id] else nil
	local items: { PickItem } = {
		{ label = "All accounts", detail = string.format("%d accounts, one after another", #shown), group = "Show", current = chosen == nil and together ~= COMBINED and together ~= COMBINED_PLANS, pick = "show", name = "" },
		{ label = "Combined", detail = "one set of windows, shares averaged", group = "Show", current = together == COMBINED, pick = "show", name = COMBINED },
		{ label = "Combined by plan", detail = "same windows together, shares averaged", group = "Show", current = together == COMBINED_PLANS, pick = "show", name = COMBINED_PLANS },
	}
	for _, name in shown do
		table.insert(items, { label = name, detail = left(name), group = "Show", current = chosen == name, pick = "show", name = name })
	end
	table.insert(items, {
		label = "Switch accounts on or off…",
		detail = string.format("%d of %d on", #shown, #names),
		group = "Accounts",
		icon = "check",
		pick = "switches",
	})
	table.insert(items, { label = "Reorder accounts…", detail = table.concat(names, ", "), group = "Accounts", icon = "list", pick = "order" })
	cx:pick({ items = items, placeholder = provider.label .. ": show which accounts?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local choice = item :: any
			local cx2 = next_cx or cx
			if choice.pick == "order" then
				open_account_order(cx2, id)
				return
			elseif choice.pick == "switches" then
				open_account_choices(cx2, id, true)
				return
			end
			choose_account(id, choice.name)
			after_change(cx2)
		end)
end

open_account_order = function(cx: WindowCx, id: string)
	local found = offered(id)
	if found == nil then
		return
	end
	local provider = found :: Provider
	local names = accounts_in_order(provider.accounts, load_settings().account_order[id])
	local items: { PickItem } = {}
	for i, name in names do
		table.insert(items, { label = name, detail = string.format("%d of %d", i, #names), pick = "account", name = name })
	end
	cx:pick({ items = items, placeholder = provider.label .. ": move which account? Esc when done", icon = "list" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local name = (item :: any).name :: string
			local moves = move_items(table.find(names, name) or 1, #names)
			if #moves == 0 then
				return
			end
			local cx2 = next_cx or cx
			cx2:pick({ items = moves, placeholder = "Move " .. name, icon = "list" })
				:next(function(choice: PickItem?, _err2: string?, last_cx: WindowCx?)
					if choice == nil then
						return
					end
					move_account(id, name, (choice :: any).pick)
					local cx3 = last_cx or cx2
					after_change(cx3)
					open_account_order(cx3, id)
				end)
		end)
end

local function open_accounts(cx: WindowCx)
	local settings = load_settings()
	local several = with_accounts(providers_in_order(settings))
	if #several == 0 then
		cx:toast("info", "No provider has several accounts", "They come from omp's usage cache: focus an omp pane")
		return
	elseif #several == 1 then
		open_account_choices(cx, several[1].id)
		return
	end
	local items: { PickItem } = {}
	for _, provider in several do
		table.insert(items, { label = provider.label, detail = accounts_summary(settings, provider), id = provider.id })
	end
	cx:pick({ items = items, placeholder = "Accounts of which provider?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			open_account_choices(next_cx or cx, (item :: any).id)
		end)
end

-- The settings panel: a canvas of buttons beside the pane it was opened from, one per window (opening it again
-- shows the one there is). It redraws when a setting changes, from it or from the pickers, and as the line it
-- previews changes. Its clicks arrive as `canvas_action` events. Tern keeps canvases across reloads, so a
-- reload takes over the one it finds.
local PANEL_TITLE = "omp Usage settings"
local PANEL_ABOUT = "Settings for the omp Usage line above omp's composer: what it shows, the providers' order, "
	.. "their windows and their colors. Each button changes one setting at once and runs nothing else."
local PANEL_SHEET = "panel"
local PANEL_ROLE = "omp-usage.panel"
local DOCK_ROLE = "omp-usage.panel-dock"
local PANEL = "[data-role='" .. PANEL_ROLE .. "']"
local PANEL_DOCK = "[data-role='" .. DOCK_ROLE .. "']"
local NO_DOCK: Dock = { status = nil, chip = nil, viewing = false, hide = {} }
local ui = tern.ui

local PANEL_CSS = fill(
	[==[
/* the settings panel, in the line's voice: mono micro-labels over hairlines, each provider in its own colors */
$P {
	display: flex;
	flex-direction: column;
	gap: 26px;
	padding: 20px 22px 30px;
	font: 400 12.5px/18px var(--sans);
	color: var(--t2);
}
/* Tern 0.9 draws every view button (`button:where(.sf-el)`) as a 28px chip: centered on a filled, ringed
   background, one nowrap line. The panel's buttons draw themselves, so they start from nothing; each class below
   sets what it needs */
$P button {
	align-items: stretch;
	justify-content: flex-start;
	gap: 0;
	height: auto;
	padding: 0;
	border-radius: 0;
	font: inherit;
	letter-spacing: normal;
	white-space: normal;
	color: inherit;
	background: none;
	box-shadow: none;
	transform: none;
}
$P .oup-sec {
	display: flex;
	flex-direction: column;
	gap: 10px;
	max-width: 760px;
}
$P .oup-eyebrow {
	display: flex;
	flex-wrap: wrap;
	align-items: baseline;
	gap: 4px 12px;
	padding-bottom: 8px;
	border-bottom: 1px solid var(--l2);
}
$P .oup-title {
	font: 600 10px/14px var(--mono);
	letter-spacing: 0.16em;
	text-transform: uppercase;
	color: var(--t2);
}
$P .oup-note {
	font: 400 11.5px/14px var(--sans);
	color: var(--t3);
}
/* what the composer shows, drawn as the composer draws it: the card (open, as a hover opens it) over the line,
   8px apart as there, on a stage lit from its corner in the card's glow; a card wider than the panel is cut */
$P .oup-stage {
	display: flex;
	flex-direction: column;
	align-items: flex-start;
	gap: 8px;
	overflow: hidden;
	/* its height held (see `build.preview`) counts the padding; spare room goes over the card, which rises from
	   the line as on the composer. The scroll never anchors in here: a card that changes height would move the
	   panel with it */
	box-sizing: border-box;
	justify-content: flex-end;
	overflow-anchor: none;
	padding: 14px 16px;
	border-radius: 12px;
	background-color: var(--code-bg);
	background-image: radial-gradient(120% 160% at 0% 0%, rgb(from var(--ou-glow) r g b / 16%), transparent 62%);
	box-shadow: 0 0 0 1px var(--l2), inset 0 1px 0 var(--glass-hi);
	--ou-glow: var(--accent);
}
$P .oup-card {
	display: flex;
}
/* the composer's line box, font and colors at rest (see LINE_CSS), its bars' lit tips over it as there (see
   TIPS_CSS; `build.preview` sets them) */
$P .oup-line {
	position: relative;
	align-self: stretch;
	height: 15px;
	overflow: hidden;
	white-space: pre-wrap;
	text-overflow: ellipsis;
	font: 500 10px/15px var(--mono);
	font-variant-numeric: tabular-nums;
	color: transparent;
	background-repeat: no-repeat;
	background-clip: text;
	--ou-lbl: var(--t3);
	--ou-sep: var(--t4);
	--ou-num-ok: var(--t2);
	--ou-num-warn: var(--warn);
	--ou-num-bad: var(--bad);
	--ou-dim: var(--t4);
	--ou-soft: var(--t3);
	--ou-track: color-mix(in srgb, var(--t1) 13%, transparent);
}
$P .oup-empty {
	font: 400 12px/18px var(--sans);
	color: var(--t3);
}
/* the modes, side by side; the one in use is ringed in the accent and checked */
$P .oup-modes {
	display: flex;
	flex-wrap: wrap;
	gap: 8px;
}
$P .oup-opt {
	display: flex;
	flex: 1 1 130px;
	flex-direction: column;
	gap: 4px;
	min-width: 0;
	padding: 10px 12px 11px;
	border-radius: 10px;
	text-align: left;
	background-color: var(--well);
	box-shadow: 0 0 0 1px var(--l2);
	cursor: pointer;
	transition:
		background-color 0.16s var(--ease),
		box-shadow 0.16s var(--ease);
}
$P .oup-opt:hover {
	background-color: var(--l1);
	box-shadow: 0 0 0 1px var(--l3);
}
$P .oup-opt[data-on] {
	background-color: rgb(from var(--accent) r g b / 9%);
	box-shadow:
		0 0 0 1px rgb(from var(--accent) r g b / 60%),
		0 10px 24px -16px rgb(from var(--accent) r g b / 90%);
}
$P .oup-opt-head {
	display: flex;
	align-items: center;
	gap: 6px;
}
$P .oup-opt-t {
	flex: 1;
	font: 600 12.5px/16px var(--sans);
	color: var(--t1);
}
$P .oup-opt .sf-icon {
	color: var(--accent);
}
$P .oup-opt-d {
	font: 400 11.5px/15px var(--sans);
	color: var(--t3);
}
/* the providers, a row each in the line's order: grip, index, swatch and label, what is left, then the Selected
   switch, which drops under the rest when the pane is narrow */
$P .oup-rows {
	display: flex;
	flex-direction: column;
}
$P .oup-prow {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 4px 12px;
	min-height: 40px;
	padding: 4px 2px 4px 4px;
}
$P .oup-prow + .oup-prow {
	border-top: 1px solid var(--l1);
}
$P .oup-who {
	display: flex;
	align-items: center;
	gap: 9px;
	min-width: 0;
}
$P .oup-ctl {
	display: flex;
	flex: none;
	align-items: center;
	gap: 2px;
	margin-left: auto;
}
$P .oup-idx {
	flex: none;
	width: 16px;
	font: 500 10px/14px var(--mono);
	font-variant-numeric: tabular-nums;
	color: var(--t4);
}
$P .oup-swatch {
	flex: none;
	width: 20px;
	height: 6px;
	border-radius: 3px;
	background-image: linear-gradient(90deg, rgb(from var(--pa) r g b), rgb(from var(--pb) r g b));
	box-shadow: 0 0 10px -1px rgb(from var(--pb) r g b / 55%);
}
$P .oup-name {
	overflow: hidden;
	white-space: nowrap;
	text-overflow: ellipsis;
	font: 600 12.5px/16px var(--mono);
	color: rgb(from var(--pa) r g b);
}
/* takes the room the row has, but never less than its widest window: past that the controls drop to their own
   line instead of the shares running under the switch */
$P .oup-sum {
	display: flex;
	flex: 1 0 auto;
	flex-wrap: wrap;
	gap: 2px;
	white-space: nowrap;
	font: 500 10.5px/14px var(--mono);
	font-variant-numeric: tabular-nums;
}
/* each window a toggle: a click hides it from the line (faded, its share struck through) or shows it again */
$P .oup-wt {
	display: flex;
	flex: none;
	align-items: center;
	padding: 2px 6px;
	border-radius: 5px;
	white-space: nowrap;
	cursor: pointer;
	transition:
		opacity 0.18s var(--ease),
		background-color 0.18s var(--ease);
}
$P .oup-wt:hover {
	background-color: var(--l1);
}
$P .oup-wt[data-off] {
	opacity: 0.4;
}
$P .oup-wt[data-off] .oup-v {
	text-decoration-line: line-through;
}
$P .oup-w {
	margin-right: 5px;
	color: var(--t3);
}
$P .oup-v {
	color: var(--t1);
}
$P .oup-v[data-low='warn'] {
	color: var(--warn);
}
$P .oup-v[data-low='bad'] {
	color: var(--bad);
}
/* under Selected providers, the ones switched off fade: the line leaves them out */
$P .oup-prow[data-off] .oup-swatch,
$P .oup-prow[data-off] .oup-name,
$P .oup-prow[data-off] .oup-sum,
$P .oup-prow[data-off] .oup-aname {
	opacity: 0.4;
}
$P .oup-switch {
	position: relative;
	flex: none;
	margin-right: 4px;
	width: 30px;
	height: 18px;
	border-radius: 9px;
	background-color: var(--l3);
	cursor: pointer;
	transition: opacity 0.18s var(--ease);
}
/* the switch carries `aria-checked`, which Tern 0.9 draws as a ringed checkbox (`.sf-el[aria-checked]`, its
   `:checked` fill and its tick `::after`): as specific as those, and later, so the plain track stays */
$P .oup-switch[aria-checked] {
	background-color: var(--l3);
	box-shadow: none;
}
$P .oup-switch[aria-checked]::after {
	content: none;
}
$P .oup-knob {
	position: absolute;
	top: 3px;
	left: 3px;
	width: 12px;
	height: 12px;
	border-radius: 6px;
	background-color: var(--t2);
	box-shadow: 0 1px 2px rgba(0, 0, 0, 0.35);
	transition:
		transform 0.22s var(--out),
		background-color 0.18s var(--ease);
}
$P .oup-switch[data-on] {
	background-image: linear-gradient(90deg, rgb(from var(--pa) r g b), rgb(from var(--pb) r g b));
}
$P .oup-switch[data-on] .oup-knob {
	transform: translateX(12px);
	background-color: #fff;
}
/* the switches pick what Selected providers shows; under the other modes they wait, dimmed */
$P .oup-rows[data-idle] .oup-switch {
	opacity: 0.45;
}
$P .oup-rows[data-idle] .oup-switch:hover {
	opacity: 1;
}
/* reordering, by pick and place: a grip picks a row up; the row lifts, ringed (in the accent, an account in its
   provider's color) and its grip turns into a cross that puts it back; every gap it can go to opens as a slot, a
   line with its name, and a click on one puts it there */
$P .oup-grip {
	display: flex;
	flex: none;
	align-items: center;
	justify-content: center;
	width: 20px;
	height: 26px;
	border-radius: 6px;
	color: var(--t4);
	cursor: pointer;
	transition:
		color 0.14s var(--ease),
		background-color 0.14s var(--ease);
}
$P .oup-grip:hover {
	color: var(--t1);
	background-color: var(--l2);
}
$P .oup-prow[data-moving] {
	border-radius: 10px;
	background-color: rgb(from var(--accent) r g b / 7%);
	box-shadow:
		0 0 0 1px rgb(from var(--accent) r g b / 55%),
		0 14px 28px -18px rgb(from var(--accent) r g b / 90%);
}
$P .oup-arow[data-moving] {
	border-radius: 8px;
	background-color: rgb(from var(--pa) r g b / 9%);
	box-shadow:
		0 0 0 1px rgb(from var(--pa) r g b / 55%),
		0 12px 24px -16px rgb(from var(--pa) r g b / 90%);
}
$P .oup-prow[data-moving] > .oup-who > .oup-grip {
	color: var(--accent);
}
$P .oup-arow[data-moving] > .oup-grip {
	color: rgb(from var(--pa) r g b);
}
$P .oup-slot {
	display: flex;
	align-items: center;
	gap: 10px;
	height: 24px;
	padding: 0 8px;
	border-radius: 7px;
	font: 500 10px/14px var(--mono);
	color: rgb(from var(--slot) r g b);
	opacity: 0.7;
	cursor: pointer;
	transition:
		opacity 0.14s var(--ease),
		background-color 0.14s var(--ease);
	--slot: var(--accent);
}
$P .oup-accts .oup-slot {
	--slot: var(--pa);
}
$P .oup-slot:hover {
	opacity: 1;
	background-color: rgb(from var(--slot) r g b / 12%);
}
$P .oup-slot-line {
	flex: 1;
	height: 1px;
	background-color: rgb(from var(--slot) r g b / 60%);
}
/* a provider with several accounts: where its windows would be, one quiet chip saying what the line and card show
   (`all 8 accounts`), or, with one account picked, a button in the provider's color (`only dev.ops ✕`) that shows
   them all again; under it, on a guide from its swatch, a row per account in the line's order: grip, name (one
   column, so the windows line up; a click picks it), windows and its switch */
$P .oup-sum-pick {
	flex: 1 1 0;
	min-width: 0;
}
$P .oup-pick {
	display: flex;
	flex: 0 1 auto;
	align-items: center;
	gap: 5px;
	min-width: 0;
	max-width: 100%;
	height: 22px;
	padding: 0 9px;
	border-radius: 11px;
	white-space: nowrap;
	font: 500 10.5px/22px var(--mono);
	color: var(--t3);
	box-shadow: 0 0 0 1px var(--l2);
}
$P .oup-pick-t {
	min-width: 0;
	overflow: hidden;
	text-overflow: ellipsis;
}
$P button.oup-pick {
	color: rgb(from var(--pa) r g b);
	background-color: rgb(from var(--pa) r g b / 12%);
	box-shadow: 0 0 0 1px rgb(from var(--pa) r g b / 50%);
	cursor: pointer;
	transition: background-color 0.14s var(--ease);
}
$P button.oup-pick:hover {
	background-color: rgb(from var(--pa) r g b / 22%);
}
/* beside `all 8 accounts`, the button that combines them: quiet until pointed at */
$P .oup-picks {
	display: flex;
	align-items: center;
	gap: 6px;
	min-width: 0;
}
$P button.oup-combine {
	color: var(--t3);
	background-color: transparent;
	box-shadow: 0 0 0 1px var(--l2);
}
$P button.oup-combine:hover {
	color: rgb(from var(--pa) r g b);
	background-color: rgb(from var(--pa) r g b / 12%);
	box-shadow: 0 0 0 1px rgb(from var(--pa) r g b / 50%);
}
$P .oup-accts {
	display: flex;
	flex: 0 0 calc(100% - 64px);
	flex-direction: column;
	margin: 0 0 6px 64px;
	padding-left: 8px;
	border-left: 1px solid var(--l2);
}
$P .oup-arow {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 2px 10px;
	min-height: 30px;
	padding: 0 2px 0 2px;
}
$P .oup-aname {
	display: flex;
	flex: 0 1 172px;
	align-items: center;
	gap: 6px;
	min-width: 64px;
	margin-left: -6px;
	padding: 2px 6px;
	border-radius: 6px;
	font: 500 11.5px/16px var(--mono);
	color: rgb(from var(--pa) r g b);
	transition:
		opacity 0.18s var(--ease),
		background-color 0.14s var(--ease);
}
$P .oup-aname-t {
	min-width: 0;
	overflow: hidden;
	white-space: nowrap;
	text-overflow: ellipsis;
}
$P button.oup-aname {
	cursor: pointer;
}
$P button.oup-aname:hover {
	background-color: var(--l2);
}
/* the account picked to show alone: its row tinted, its name bold and tagged */
$P .oup-arow[data-picked] {
	border-radius: 8px;
	background-color: rgb(from var(--pa) r g b / 7%);
}
$P .oup-arow[data-picked] .oup-aname {
	font-weight: 600;
}
$P .oup-only {
	flex: none;
	padding: 0 5px;
	border-radius: 4px;
	font: 600 9px/14px var(--mono);
	letter-spacing: 0.08em;
	text-transform: uppercase;
	color: rgb(from var(--pa) r g b);
	background-color: rgb(from var(--pa) r g b / 16%);
	box-shadow: 0 0 0 1px rgb(from var(--pa) r g b / 45%);
}
/* combined: which group an account went into (`5H`, `no 5H`), at the end of its windows, so the tags
   line up in a column */
$P .oup-group {
	flex: none;
	margin-left: auto;
	padding: 0 6px;
	border-radius: 4px;
	font: 500 10px/16px var(--mono);
	color: var(--t3);
	box-shadow: 0 0 0 1px var(--l2);
}
$P .oup-arow[data-off] .oup-aname,
$P .oup-arow[data-off] .oup-sum,
$P .oup-arow[data-hidden] .oup-aname,
$P .oup-arow[data-hidden] .oup-sum {
	opacity: 0.4;
}
/* switched off: out of the line and the card */
$P .oup-arow[data-hidden] .oup-aname-t {
	text-decoration-line: line-through;
}
/* picked up, a row shows in full, whatever else it is */
$P .oup-arow[data-moving] .oup-aname,
$P .oup-arow[data-moving] .oup-sum {
	opacity: 1;
}
/* an account's switch is always live, whatever the mode */
$P .oup-rows[data-idle] .oup-aswitch {
	opacity: 1;
}
/* ten accounts of one provider make a column of switches: on, they take its color at half strength, so a row
   picked up or a share running low still stands out */
$P .oup-aswitch[data-on] {
	background-image: none;
	background-color: rgb(from var(--pa) r g b / 45%);
}
/* each provider's colors: its preset, the alternatives and its own, the one in use ringed; the swatches drop
   under the label when the pane is narrow */
$P .oup-crow {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 10px 16px;
	padding: 10px 4px;
}
$P .oup-crow + .oup-crow {
	border-top: 1px solid var(--l1);
}
$P .oup-chead {
	display: flex;
	flex: 0 0 150px;
	flex-direction: column;
	gap: 2px;
	min-width: 0;
}
$P .oup-dots {
	display: flex;
	flex: 1 1 250px;
	flex-wrap: wrap;
	align-items: center;
	gap: 7px;
	min-width: 0;
}
$P .oup-dot {
	position: relative;
	width: 18px;
	height: 18px;
	border-radius: 9px;
	background-image: linear-gradient(135deg, rgb(from var(--pa) r g b), rgb(from var(--pb) r g b));
	box-shadow:
		0 0 0 1px var(--l2),
		inset 0 1px 0 rgba(255, 255, 255, 0.22);
	outline: 1.5px solid transparent;
	outline-offset: 2px;
	cursor: pointer;
	transition:
		outline-color 0.14s var(--ease),
		box-shadow 0.14s var(--ease);
}
$P .oup-dot:hover {
	outline-color: var(--l4);
}
$P .oup-dot[data-on] {
	outline-color: rgb(from var(--pb) r g b);
	box-shadow:
		0 0 0 1px var(--l2),
		0 0 14px -2px rgb(from var(--pb) r g b / 70%);
}
/* a swatch's name, under it while it is pointed at */
$P .oup-dot:hover::after {
	content: attr(data-name);
	position: absolute;
	left: 50%;
	top: calc(100% + 7px);
	transform: translateX(-50%);
	padding: 1px 7px;
	border-radius: 6px;
	white-space: nowrap;
	font: 500 10.5px/16px var(--sans);
	color: var(--t1);
	background-color: rgb(from var(--pop-bg) r g b / 1);
	box-shadow:
		0 0 0 1px var(--l2),
		0 8px 18px -10px rgba(0, 0, 0, 0.6);
	pointer-events: none;
	z-index: 4;
}
$P .oup-acts {
	display: flex;
	gap: 6px;
}
$P .oup-btn {
	height: 24px;
	padding: 0 10px;
	border-radius: 7px;
	font: 500 11.5px/24px var(--sans);
	color: var(--t2);
	background-color: var(--raise);
	box-shadow: 0 0 0 1px var(--l2);
	cursor: pointer;
	transition:
		color 0.14s var(--ease),
		box-shadow 0.14s var(--ease);
}
$P .oup-btn:hover {
	color: var(--t1);
	box-shadow: 0 0 0 1px var(--l4);
}
$P .oup-ustat {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	justify-content: space-between;
	gap: 10px 16px;
	padding: 12px 14px;
	border-radius: 10px;
	box-shadow: 0 0 0 1px var(--l2);
}
$P .oup-ustat[data-ready] {
	background-color: rgb(from var(--accent) r g b / 8%);
	box-shadow: 0 0 0 1px rgb(from var(--accent) r g b / 40%);
}
$P .oup-say {
	display: flex;
	flex-direction: column;
	gap: 2px;
	min-width: 0;
}
$P .oup-utitle {
	font: 600 13px/18px var(--sans);
	color: var(--t1);
}
$P .oup-usub {
	font: 400 11.5px/15px var(--sans);
	color: var(--t3);
}
$P .oup-btn.oup-primary {
	color: #fff;
	background-color: var(--accent);
	box-shadow: none;
}
$P .oup-btn.oup-primary:hover {
	color: #fff;
	background-color: rgb(from var(--accent) r g b / 85%);
	box-shadow: none;
}
$P .oup-urow {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 10px 14px;
}
$P .oup-ulabel {
	font: 400 11.5px/14px var(--sans);
	color: var(--t3);
}
$P .oup-pills {
	display: flex;
	flex-wrap: wrap;
	gap: 6px;
}
$P .oup-pill {
	height: 24px;
	padding: 0 10px;
	border-radius: 12px;
	font: 500 11.5px/24px var(--sans);
	color: var(--t2);
	box-shadow: 0 0 0 1px var(--l2);
	cursor: pointer;
	transition:
		color 0.14s var(--ease),
		box-shadow 0.14s var(--ease),
		background-color 0.14s var(--ease);
}
$P .oup-pill:hover {
	color: var(--t1);
	box-shadow: 0 0 0 1px var(--l4);
}
$P .oup-pill[data-on] {
	color: var(--t1);
	background-color: rgb(from var(--accent) r g b / 16%);
	box-shadow: 0 0 0 1px rgb(from var(--accent) r g b / 55%);
}
/* under the Preview: the card's height limit, its note on a line of its own, and the warning while the card
   outgrows it */
$P .oup-limit {
	margin-top: 12px;
}
$P .oup-limit .oup-note {
	flex-basis: 100%;
}
$P .oup-over {
	margin-top: 10px;
	font: 400 11.5px/15px var(--sans);
	color: var(--warn);
}
$P .oup-cname {
	overflow: hidden;
	white-space: nowrap;
	text-overflow: ellipsis;
	font: 500 10px/14px var(--mono);
	color: var(--t3);
}
$P button:focus-visible {
	outline: 2px solid var(--accent);
	outline-offset: 2px;
}
/* the bottom bar: changes need no saving, and the shortcut */
$D {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 4px 8px;
	padding: 9px 22px;
	font: 400 11.5px/16px var(--sans);
	white-space: nowrap;
	color: var(--t3);
}
$D .sf-icon {
	color: var(--ok);
}
$D .oup-sep {
	width: 1px;
	height: 12px;
	margin: 0 6px;
	background-color: var(--l3);
}
$D .oup-hint {
	display: flex;
	align-items: center;
	gap: 8px;
}
$D .oup-keys {
	display: flex;
	gap: 3px;
}
$D .oup-key {
	min-width: 18px;
	height: 18px;
	padding: 0 5px;
	border-radius: 5px;
	font: 500 10.5px/18px var(--mono);
	text-align: center;
	color: var(--t2);
	background-color: var(--l1);
	box-shadow:
		0 0 0 1px var(--l2),
		inset 0 -1px 0 var(--l2);
}
/* Reduce Motion, either way: switches and rings change at once */
.sf-still $P *,
.sf-still $D * {
	transition: none;
}
@media (prefers-reduced-motion: reduce) {
	$P *,
	$D * {
		transition: none;
	}
}
]==],
	{ P = PANEL, D = PANEL_DOCK }
)

-- A value for a `[data-ou-pal='…']` selector.
local function pal_key(s: string): string
	return (string.gsub(s, "[^%w%-_]", "_"))
end

-- The colors of whatever carries `data-ou-pal` = `pal`, as `--pa` and `--pb`.
local function palette_rule(pal: string, palette: Palette): string
	return string.format("%s [data-ou-pal='%s'] {\n\t--pa: %s;\n\t--pb: %s;\n}", PANEL, pal, palette.a, palette.b or palette.a)
end

local NAMED_CSS = (function(): string
	local rules: { string } = {}
	for _, item in NAMED do
		table.insert(rules, palette_rule("n-" .. item.key, item.palette))
	end
	return table.concat(rules, "\n")
end)()

-- A section: a mono title over a hairline, a note beside it, then `body`.
local function section(key: string, title: string, note: string?, body: { Node }): Node
	local head: { Node } = { ui.el("span", { class = "oup-title", text = title }) }
	if note then
		table.insert(head, ui.el("span", { class = "oup-note", text = note }))
	end
	local children: { Node } = { ui.el("div", { class = "oup-eyebrow" }, head) }
	for _, node in body do
		table.insert(children, node)
	end
	return ui.el("section", { key = key, class = "oup-sec" }, children)
end

-- The panel's sections and the account chip, as fields of one table: each local of the main chunk takes one of
-- Luau's 200 registers (constants aside), and the chunk is close to them.
local build = {}
-- `build.most_rows`' last result and what it was for
build.most_for = ""
build.most = 0

-- The most rows the card can get with the usage last fetched, whatever is clicked in the panel. The card's
-- height doesn't only grow with what it shows (hiding a window can make room for another account in full), so
-- with nothing hidden and every account on, a card counts as tall as it would be without the limit, up to the
-- limit, or as it is with everything summed up and folded, if that still outgrows it: picked accounts stay in
-- full, so the most is with each provider's account picked that takes the most rows, all at once. That for the
-- focused agent's provider and for every provider, with no account picked, each picked alone, and those picks
-- together (combined accounts only ever take fewer rows). The order of providers and accounts changes neither.
-- It is worked out again only when the limit or the shape of the cards with no account picked changes (their
-- providers, accounts, windows and the rows under them; not what is left, which the extension rewrites every
-- minute), and the card's memo is put back after, so the composer's and the preview's rows stay the same rows
-- (their clock times included).
function build.most_rows(settings: Settings, providers: { Provider }, cache: Cache?, hint: string): number
	local limit = settings.card_rows
	local function model_for(mode: string, picks: { [string]: string }): Model
		local trial = table.clone(settings)
		trial.mode, trial.hidden, trial.account_hidden, trial.account = mode, {}, {}, picks
		return build_model(trial, last_dock or NO_DOCK, cache)
	end
	local bases: { [string]: Model } = { current = model_for("current", {}), all = model_for("all", {}) }
	local shape: { string } = { hint, tostring(limit) }
	for _, base in { bases.current, bases.all } do
		table.insert(shape, base.title .. "#" .. tostring(#base.others))
		for _, group in base.groups do
			table.insert(shape, string.format("%s=%s r%d", group.key, group.label, #(group.resets or {})))
			for _, window in group.windows do
				table.insert(
					shape,
					string.format("%s|%s|%s|%s", window.label, tostring(window.saved), tostring(window.expires ~= nil), tostring(window.reset ~= nil))
				)
			end
		end
	end
	local key = table.concat(shape, "\n")
	if key == build.most_for then
		return build.most
	end
	local most = 0
	local memo_for, memo_rows = card_for, card_rows
	-- the card's rows with every account in full, after counting the state toward `most`: as many, up to the
	-- limit; past it, the card sums accounts up, which only leaves it over the limit if summing up all of them
	-- does. Also how many rows each account in full takes (see `card_runs`).
	local function measure(model: Model): (number, { [string]: number })
		if #model.groups == 0 and #model.others == 0 then
			return 0, {}
		end
		local unlimited = #card(model, hint, limit, "all")
		local runs = card_runs
		most = math.max(most, math.min(unlimited, limit))
		if unlimited > limit then
			most = math.max(most, #card(model, hint, limit, "least"))
		end
		return unlimited, runs
	end
	for mode, base in bases do
		-- a pick swaps an account's windows (two rows or more each) for a row per other account, so picks only
		-- matter when the card already outgrows the limit; then the tallest card picks, for each provider it
		-- shows with several accounts, the account that takes the most rows, all at once
		local unlimited, runs = measure(base)
		if unlimited <= limit then
			continue
		end
		local tallest: { [string]: string } = {}
		for _, provider in providers do
			local best = -1
			for _, name in provider.accounts do
				local rows = runs[provider.id .. "/" .. name]
				if rows and rows > best then
					best, tallest[provider.id] = rows, name
				end
			end
		end
		if next(tallest) ~= nil then
			measure(model_for(mode, tallest))
		end
	end
	card_for, card_rows = memo_for, memo_rows
	build.most_for, build.most = key, most
	return most
end

-- What the composer shows, drawn by the composer's own code: its card open over the line, as a hover opens it,
-- with the same rows, text, paint and fonts. The line keeps the composer's one-line box (`.oup-line`), so a
-- window that doesn't fit wraps onto the line that is cut off here as it is there; the panel is seldom as wide
-- as the composer, so the line can end a window sooner or later. The stage is as tall as the card can get with
-- the usage last fetched (`most_rows`), so a click that changes the card leaves the rest of the panel, and the
-- pointer over it, where they were. Under it, the card's height limit, and a warning while the card outgrows it.
function build.preview(settings: Settings, preview: Model, rules: { string }, hint: string, providers: { Provider }, cache: Cache?): Node
	local limit = settings.card_rows
	local pills: { Node } = {}
	for _, rows in CARD_ROWS do
		local on = rows == limit
		table.insert(pills, ui.el("button", {
			class = "oup-pill",
			text = tostring(rows),
			actions = { click = "card-rows=" .. tostring(rows) },
			attrs = { ["data-on"] = if on then true else nil, ["aria-pressed"] = if on then "true" else "false" },
		}))
	end
	local height = ui.el("div", { class = "oup-urow oup-limit" }, {
		ui.el("span", { class = "oup-ulabel", text = "Card height, in rows" }),
		ui.el("div", { class = "oup-pills", attrs = { role = "group", ["aria-label"] = "How many rows the card may take" } }, pills),
		ui.el("span", {
			class = "oup-note",
			text = "Past it, accounts sum up to a row each, then fold into one. A row is 18px: pick what your omp pane holds above the composer.",
		}),
	})
	-- the stage's padding, the card (its rows and padding), the gap and the line: see `.oup-stage`, CARD_CSS
	local most = build.most_rows(settings, providers, cache, hint)
	if most > 0 then
		table.insert(rules, string.format("%s .oup-stage {\n\tmin-height: %dpx;\n}", PANEL, 28 + most * CARD_ROW + 14 + 8 + 15))
	end
	if #preview.groups == 0 and #preview.others == 0 then
		return section("preview", "Preview", "what the composer shows, its card open as on a hover", {
			ui.el("div", { class = "oup-stage" }, {
				ui.el("div", { class = "oup-empty", text = "Nothing to show. Focus an omp pane, or show a window below." }),
			}),
			height,
		})
	end
	local line = line_of(preview)
	table.insert(rules, palette_css(preview, settings, PANEL .. " .oup-stage"))
	local rest = tips(line, 55)
	table.insert(rules, string.format("%s .oup-line {\n\tbackground-image: %s;\n}", PANEL, line_paint(line)))
	if #rest.images > 0 then
		table.insert(
			rules,
			string.format(
				"%s .oup-line::after {\n\tcontent: \"\";\n\tposition: absolute;\n\tleft: 0;\n\tright: 0;\n\ttop: 0;\n\theight: 13px;\n\tbackground-image: %s;\n\tbackground-position: %s;\n\tbackground-size: %s;\n\tbackground-repeat: no-repeat;\n\tpointer-events: none;\n}",
				PANEL,
				table.concat(rest.images, ", "),
				table.concat(rest.positions, ", "),
				table.concat(rest.sizes, ", ")
			)
		)
	end
	local rows = card(preview, hint, limit)
	table.insert(rules, card_css(rows, PANEL .. " .oup-card::before"))
	local children: { Node } = {
		ui.el("div", { class = "oup-stage" }, {
			ui.el("div", { class = "oup-card" }),
			ui.el("div", { class = "oup-line", text = line.text }),
		}),
		height,
	}
	if #rows > limit then
		table.insert(
			children,
			ui.el("div", {
				class = "oup-over",
				text = string.format(
					"This card takes %d rows, more than %d: a picked account and the providers without accounts don't fold. A short pane cuts its top off; raise the limit, or show less.",
					#rows,
					limit
				),
			})
		)
	end
	return section("preview", "Preview", "what the composer shows, its card open as on a hover", children)
end

function build.show(settings: Settings, providers: { Provider }): Node
	local details = mode_details(settings, providers)
	local options: { Node } = {}
	for _, mode in MODES do
		local on = settings.mode == mode.mode
		local head: { Node } = { ui.el("span", { class = "oup-opt-t", text = mode.label }) }
		if on then
			table.insert(head, ui.node("icon", { name = "check" }))
		end
		table.insert(
			options,
			ui.el("button", {
				key = "mode-" .. mode.mode,
				class = "oup-opt",
				actions = { click = "mode=" .. mode.mode },
				attrs = { ["data-on"] = if on then true else nil, ["aria-pressed"] = if on then "true" else "false" },
			}, {
				ui.el("span", { class = "oup-opt-head" }, head),
				ui.el("span", { class = "oup-opt-d", text = details[mode.mode] }),
			})
		)
	end
	return section("show", "Show", nil, { ui.el("div", { class = "oup-modes" }, options) })
end

-- What a provider has left, by window (`windows`: its own, or one account's): each a toggle that hides it from
-- the line or shows it again. An account's windows go by their labels without it, as its row names it.
local function left_now(settings: Settings, provider: Provider, windows: { Window }): { Node }
	local hidden = settings.hidden[provider.id] or {}
	local nodes: { Node } = {}
	for _, window in windows do
		local tone = tone_of(window.pct)
		local key = string.lower(window.label)
		local off = table.find(hidden, key) ~= nil
		table.insert(
			nodes,
			ui.el("button", {
				key = "w-" .. key,
				class = "oup-wt",
				actions = { click = "window=" .. provider.id .. "/" .. key },
				attrs = {
					["aria-pressed"] = if off then "false" else "true",
					["aria-label"] = (if off then "Show " else "Hide ") .. provider.label .. " " .. window.label .. " on the line",
					["data-off"] = if off then true else nil,
				},
			}, {
				ui.el("span", { class = "oup-w", text = string.upper(window.bare or window.label) }),
				ui.el("span", { class = "oup-v", text = tostring(window.pct) .. "%", attrs = { ["data-low"] = if tone ~= "ok" then tone else nil } }),
			})
		)
	end
	if #nodes == 0 then
		table.insert(nodes, ui.el("span", { class = "oup-w", text = if provider.line == "" then "no data yet" else "no limits" }))
	end
	return nodes
end

-- Reordering in the panel is pick and place (Tern's views have no drag): a row's grip picks it up, every gap it
-- can go to opens as a slot, and a click on one puts it there. `moving` is what is picked up (a provider by id, or
-- an account of provider `id` by name) until it is placed, put back with its grip, or another setting changes.
type Moving = { kind: string, id: string, name: string? }
local moving: Moving? = nil

-- A row's grip (`grab=<what>`): picks it up, or, picked up, puts it back.
local function grip(what: string, label: string, lifted: boolean): Node
	return ui.el("button", {
		class = "oup-grip",
		actions = { click = "grab=" .. what },
		attrs = {
			["aria-label"] = if lifted then "Put " .. label .. " back" else "Pick up " .. label .. " to move it",
			["aria-pressed"] = if lifted then "true" else "false",
		},
	}, { ui.node("icon", { name = if lifted then "x" else "grip" }) })
end

-- `rows` (one per item of `items`, ids or names in order) and, while `lifted` (one of them, called `label`) is picked
-- up, a slot in every gap it can go to but its own: `place=<prefix><at>`, `at` as `moved` counts it.
local function with_slots(items: { string }, rows: { Node }, lifted: string?, label: string, prefix: string): { Node }
	if lifted == nil or not table.find(items, lifted :: string) then
		return rows
	end
	local function slot(key: string, at: number): Node
		return ui.el("button", {
			key = key,
			class = "oup-slot",
			actions = { click = "place=" .. prefix .. tostring(at) },
			attrs = { ["aria-label"] = "Move " .. label .. " here" },
		}, {
			ui.el("span", { class = "oup-slot-t", text = label .. " here" }),
			ui.el("span", { class = "oup-slot-line" }),
		})
	end
	local out: { Node } = {}
	local passed = 0 -- items before this one, the lifted one aside
	for i, item in items do
		if item ~= lifted and items[i - 1] ~= lifted then
			table.insert(out, slot("s-" .. tostring(i), passed + 1))
		end
		table.insert(out, rows[i])
		if item ~= lifted then
			passed += 1
		end
	end
	if items[#items] ~= lifted then
		table.insert(out, slot("s-end", passed + 1))
	end
	return out
end

-- Where a provider with several accounts would list its windows: one quiet chip saying what the line and card show
-- (`shown`: the accounts switched on, in order), and a button for the next way to show them: `all 8 accounts` with
-- `combine`; combined, `combined · 8 accounts ✕` with `by plan`; by plan, `by plan · 6 with 5H, 4 without ✕`
-- with `all in one` (see `combined`); with one picked, `only dev.ops ✕`. The ✕ chips are buttons that
-- show every account again. The accounts are picked on their rows (see `account_rows`).
function build.account_chip(settings: Settings, provider: Provider, shown: { string }): Node
	local chosen = chosen_account(settings, provider.id, provider.accounts)
	local function clear(text: string, label: string): Node
		return ui.el("button", {
			class = "oup-pick",
			actions = { click = "account=" .. provider.id .. "/" },
			attrs = { ["aria-label"] = label },
		}, {
			ui.el("span", { class = "oup-pick-t", text = text }),
			ui.node("icon", { name = "x" }),
		})
	end
	local function with_button(chip: Node, text: string, act: string, label: string): Node
		return ui.el("span", { class = "oup-picks" }, {
			chip,
			ui.el("button", {
				class = "oup-pick oup-combine",
				text = text,
				actions = { click = act .. "=" .. provider.id },
				attrs = { ["aria-label"] = label },
			}),
		})
	end
	if chosen then
		return clear("only " .. (chosen :: string), "Only " .. (chosen :: string) .. " shows: show every " .. provider.label .. " account again")
	end
	local mode = settings.account[provider.id]
	if #shown > 1 and (mode == COMBINED or mode == COMBINED_PLANS) then
		-- the groups as the line and card have them (hidden windows left out)
		local _, _, info = account_view(settings, provider.id, provider.accounts, shown_windows(settings, provider.id, provider.windows))
		local chip = clear(if info then info.chip else "combined", provider.label .. "'s accounts show combined: show each account again")
		if mode == COMBINED then
			return with_button(chip, "by plan", "combine-plans", "Combine " .. provider.label .. "'s accounts by plan: the accounts with the same windows together")
		end
		return with_button(chip, "all in one", "combine", "Combine all of " .. provider.label .. "'s accounts in one set of windows")
	end
	local text = if #shown > 1
		then string.format("all %d accounts", #shown)
		elseif #shown == 1 then "only " .. shown[1] .. " is on"
		else "every account is off"
	local chip = ui.el("span", { class = "oup-pick" }, { ui.el("span", { class = "oup-pick-t", text = text }) })
	if #shown < 2 then
		return chip
	end
	return with_button(chip, "combine", "combine", "Combine " .. provider.label .. "'s accounts: one set of windows, each window's share their average")
end

-- Under a provider with several accounts, a row per account in the line's order: its grip, name, windows (each a
-- toggle, as a provider's are) and a switch that takes it off the line and out of the card, or back. A click on
-- an account's name shows only that account; on the picked one's, every account again. The picked row's name is
-- lit and tagged `only`; the others fade (the card sums them up). Combined by plan, each row is tagged with its
-- group (`5H`, `no 5H`; see `combined`). Switched off, a row fades, its name is struck through and can't be
-- picked.
local function account_rows(settings: Settings, provider: Provider, names: { string }): Node
	local chosen = chosen_account(settings, provider.id, provider.accounts)
	local lifted = if moving and moving.kind == "account" and moving.id == provider.id then moving.name else nil
	local rows: { Node } = {}
	local tags: { [string]: string } = {}
	if chosen == nil and settings.account[provider.id] == COMBINED_PLANS then
		local _, _, info = account_view(settings, provider.id, provider.accounts, shown_windows(settings, provider.id, provider.windows))
		tags = if info then info.tags else {}
	end
	-- an account's name: a button that picks it (or, picked, shows all again), plain text while it is off
	local function account_name(name: string, off: boolean): Node
		local text = ui.el("span", { class = "oup-aname-t", text = name })
		if off then
			return ui.el("span", { class = "oup-aname" }, { text })
		end
		local picked = chosen == name
		local children: { Node } = { text }
		if picked then
			table.insert(children, ui.el("span", { class = "oup-only", text = "only" }))
		end
		return ui.el("button", {
			class = "oup-aname",
			actions = { click = "account=" .. provider.id .. "/" .. (if picked then "" else name) },
			attrs = {
				["aria-pressed"] = if picked then "true" else "false",
				["aria-label"] = if picked then "Show every " .. provider.label .. " account again" else "Show only " .. provider.label .. " " .. name,
			},
		}, children)
	end
	-- each account's windows, in one pass over the provider's
	local by: { [string]: { Window } } = {}
	for _, window in provider.windows do
		local owner, bare = account_of(window.label, provider.accounts)
		if owner then
			local copy = table.clone(window)
			copy.account, copy.bare = owner, bare
			by[owner] = by[owner] or {}
			table.insert(by[owner], copy)
		end
	end
	for _, name in names do
		local windows = by[name] or {}
		local off = account_off(settings, provider.id, name)
		local value = provider.id .. "/" .. name
		table.insert(
			rows,
			ui.el("div", {
				key = "a-" .. name,
				class = "oup-arow",
				attrs = {
					["data-hidden"] = if off then true else nil,
					["data-off"] = if chosen and chosen ~= name then true else nil,
					["data-picked"] = if chosen == name then true else nil,
					["data-moving"] = if lifted == name then true else nil,
				},
			}, {
				grip("account/" .. value, name, lifted == name),
				account_name(name, off),
				ui.el("span", { class = "oup-sum" }, (function(): { Node }
					local nodes = left_now(settings, provider, windows)
					if tags[name] and not off then
						table.insert(nodes, ui.el("span", { class = "oup-group", text = tags[name] }))
					end
					return nodes
				end)()),
				ui.el("span", { class = "oup-ctl" }, {
					ui.el("button", {
						class = "oup-switch oup-aswitch",
						actions = { click = "account-show=" .. value },
						attrs = {
							role = "switch",
							["aria-checked"] = if off then "false" else "true",
							["aria-label"] = provider.label .. " " .. name .. " on the line and in the card",
							["data-on"] = if off then nil else true,
						},
					}, { ui.el("span", { class = "oup-knob" }) }),
				}),
			})
		)
	end
	return ui.el("div", { class = "oup-accts" }, with_slots(names, rows, lifted, lifted or "", "account/" .. provider.id .. "/"))
end

local function provider_row(settings: Settings, provider: Provider, i: number): Node
	local on = table.find(settings.selected, provider.id) ~= nil
	local lifted = moving ~= nil and moving.kind == "provider" and moving.id == provider.id
	local names = accounts_in_order(provider.accounts, settings.account_order[provider.id])
	local several = #names > 1
	local children: { Node } = {
		ui.el("span", { class = "oup-who" }, {
			grip("provider/" .. provider.id, provider.label, lifted),
			ui.el("span", { class = "oup-idx", text = string.format("%02d", i) }),
			ui.el("span", { class = "oup-swatch" }),
			ui.el("span", { class = "oup-name", text = provider.label }),
		}),
		ui.el(
			"span",
			{ class = if several then "oup-sum oup-sum-pick" else "oup-sum" },
			if several then { build.account_chip(settings, provider, shown_accounts(settings, provider)) } else left_now(settings, provider, provider.windows)
		),
		ui.el("span", { class = "oup-ctl" }, {
			ui.el("button", {
				class = "oup-switch",
				actions = { click = "toggle=" .. provider.id },
				attrs = {
					role = "switch",
					["aria-checked"] = if on then "true" else "false",
					["aria-label"] = provider.label .. " under Selected providers",
					["data-on"] = if on then true else nil,
				},
			}, { ui.el("span", { class = "oup-knob" }) }),
		}),
	}
	if several then
		table.insert(children, account_rows(settings, provider, names))
	end
	return ui.el("div", {
		key = "p-" .. provider.id,
		class = "oup-prow",
		attrs = {
			["data-ou-pal"] = "p-" .. pal_key(color_key(provider.id, provider.label)),
			["data-off"] = if settings.mode == "selected" and not on then true else nil,
			["data-moving"] = if lifted then true else nil,
		},
	}, children)
end

function build.providers(settings: Settings, providers: { Provider }): Node
	local rows: { Node } = {}
	local ids: { string } = {}
	local accounts = false
	for i, provider in providers do
		table.insert(rows, provider_row(settings, provider, i))
		table.insert(ids, provider.id)
		accounts = accounts or #provider.accounts > 1
	end
	local note = "Top to bottom is the line's left to right: pick a row up by its grip, then click where it goes. "
		.. "Click a window to hide or show it; the switches pick what Selected providers shows."
	if accounts then
		note ..= " With several accounts, click an account's name to show only it (again for all); its switch takes it off the line and card."
	end
	local lifted = if moving and moving.kind == "provider" then moving.id else nil
	local label = if lifted then label_of(providers, lifted :: string) else ""
	return section("providers", "Providers", note, {
		ui.el(
			"div",
			{ class = "oup-rows", attrs = { ["data-idle"] = if settings.mode ~= "selected" then true else nil } },
			with_slots(ids, rows, lifted, label, "provider/")
		),
	})
end

local function color_row(settings: Settings, provider: Provider, rules: { string }): Node
	local key = color_key(provider.id, provider.label)
	local pk = pal_key(key)
	local spec = settings.colors[key]
	local preset = preset_for(provider.id, provider.label)
	local dots: { Node } = {}
	local function dot(pal: string, name: string, act: string, on: boolean)
		table.insert(
			dots,
			ui.el("button", {
				class = "oup-dot",
				actions = { click = act },
				attrs = {
					["data-ou-pal"] = pal,
					["aria-label"] = name,
					["data-name"] = name,
					["aria-pressed"] = if on then "true" else "false",
					["data-on"] = if on then true else nil,
				},
			})
		)
	end
	table.insert(rules, palette_rule("s-" .. pk, preset))
	dot("s-" .. pk, preset.name .. " (preset)", "preset=" .. key, spec == nil)
	for _, item in NAMED do
		dot("n-" .. item.key, item.palette.name, "named=" .. key .. "/" .. item.key, spec == "named:" .. item.key)
	end
	local custom = if spec and string.sub(spec, 1, 1) == "#" then palette_of_spec(spec) else nil
	if custom then
		table.insert(rules, palette_rule("c-" .. pk, custom))
		dot("c-" .. pk, "Your " .. custom.name, "custom=" .. key, true)
	end
	-- your own colors, and back to the preset, side by side wherever the swatches wrap
	local acts: { Node } = { ui.el("button", { class = "oup-btn", text = "Custom…", actions = { click = "custom=" .. key } }) }
	if spec then
		table.insert(acts, ui.el("button", { class = "oup-btn", text = "Reset", actions = { click = "reset=" .. key } }))
	end
	table.insert(dots, ui.el("span", { class = "oup-acts" }, acts))
	return ui.el("div", { key = "c-" .. provider.id, class = "oup-crow", attrs = { ["data-ou-pal"] = "p-" .. pk } }, {
		ui.el("span", { class = "oup-chead" }, {
			ui.el("span", { class = "oup-name", text = provider.label }),
			ui.el("span", { class = "oup-cname", text = color_name(settings, provider) }),
		}),
		ui.el("div", { class = "oup-dots" }, dots),
	})
end

function build.colors(settings: Settings, providers: { Provider }, rules: { string }): Node
	local rows: { Node } = {}
	for _, provider in providers do
		table.insert(rows, color_row(settings, provider, rules))
	end
	return section("colors", "Colors", "A label's color and its bars'. Point at a swatch for its name.", rows)
end

-- Updates (update.luau), in Tern's words: what's installed and whether an update is waiting, with Download Update
-- (and What's New, the update card) or Check for Updates, then how often the automatic check runs.
local function update_status(): (string, string?)
	local version = update.version()
	local name = "omp Usage" .. (if version then " " .. version else "")
	local pending = update.pending()
	if pending then
		local next = if pending.version and pending.version ~= version then pending.version else pending.short
		return "omp Usage " .. next .. " is available", "You have " .. (version or "an earlier version")
	end
	local last = update.last_checked()
	if last == nil then
		return name, nil
	end
	return name .. " is up to date", "Checked " .. span(math.max(0, os.time() - last) * 1000) .. " ago"
end

function build.updates(): Node
	local current = update.interval()
	local pills: { Node } = {}
	for _, interval in update.INTERVALS do
		local on = interval.id == current.id
		table.insert(pills, ui.el("button", {
			class = "oup-pill",
			text = interval.label,
			actions = { click = "update-every=" .. interval.id },
			attrs = { ["data-on"] = if on then true else nil, ["aria-pressed"] = if on then "true" else "false" },
		}))
	end
	local title, sub = update_status()
	local say: { Node } = { ui.el("span", { class = "oup-utitle", text = title }) }
	if sub then
		table.insert(say, ui.el("span", { class = "oup-usub", text = sub }))
	end
	local buttons: { Node }
	if update.pending() then
		buttons = {
			ui.el("button", { class = "oup-btn oup-primary", text = "Download Update", actions = { click = "update-download" } }),
			ui.el("button", { class = "oup-btn", text = "What's New", actions = { click = "update-check" } }),
		}
	else
		buttons = { ui.el("button", { class = "oup-btn", text = "Check for Updates", actions = { click = "update-check" } }) }
	end
	return section("updates", "Updates", nil, {
		ui.el("div", { class = "oup-ustat", attrs = { ["data-ready"] = if update.pending() then true else nil } }, {
			ui.el("span", { class = "oup-say" }, say),
			ui.el("span", { class = "oup-acts" }, buttons),
		}),
		ui.el("div", { class = "oup-urow" }, {
			ui.el("span", { class = "oup-ulabel", text = "Check automatically" }),
			ui.el("div", { class = "oup-pills", attrs = { role = "group", ["aria-label"] = "How often omp Usage checks for updates" } }, pills),
		}),
	})
end

local function panel_dock(keys: string?): Node
	local children: { Node } = {
		ui.node("icon", { name = "check" }),
		ui.el("span", { text = "Changes apply at once" }),
	}
	if keys then
		local caps: { Node } = {}
		for key in string.gmatch(keys :: string, "[^+ ]+") do
			table.insert(caps, ui.el("span", { class = "oup-key", text = key }))
		end
		table.insert(children, ui.el("span", { class = "oup-sep" }))
		table.insert(children, ui.el("span", { class = "oup-hint" }, {
			ui.el("span", { class = "oup-keys" }, caps),
			ui.el("span", { text = "opens this panel" }),
		}))
	end
	return ui.el("div", { role = DOCK_ROLE }, children)
end

-- What the panel shows now: the settings, the providers in order, the line it previews (the last pane's, drawn
-- with these settings), the cache it came from and the shortcut; `sig` changes whenever any of it does.
type PanelState = { settings: Settings, providers: { Provider }, preview: Model, cache: Cache?, keys: string?, sig: string }

local function panel_state(cx: WindowCx, settings: Settings, cache: Cache?): PanelState
	local providers = ordered(offered_providers(cache), settings.order)
	local preview = build_model(settings, last_dock or NO_DOCK, cache)
	local keys = shortcut(cx)
	local parts: { string } = {
		settings.mode,
		table.concat(settings.selected, ","),
		table.concat(settings.order, ","),
		colors_key(settings),
		hidden_key(settings),
		keys or "",
		tostring(settings.card_rows),
		update.interval().id,
		(function(): string
			local title, sub = update_status()
			return title .. "|" .. (sub or "")
		end)(),
	}
	for _, provider in providers do
		local windows: { string } = {}
		for _, window in provider.windows do
			table.insert(windows, window.label .. ":" .. tostring(window.pct))
		end
		local accounts = table.concat(accounts_in_order(provider.accounts, settings.account_order[provider.id]), ",")
		local off = table.concat(settings.account_hidden[provider.id] or {}, ",")
		table.insert(
			parts,
			table.concat({ provider.id, provider.label, provider.line, table.concat(windows, ","), accounts, settings.account[provider.id] or "", off }, "|")
		)
	end
	table.insert(parts, if moving then moving.kind .. ":" .. moving.id .. ":" .. (moving.name or "") else "")
	table.insert(parts, preview.signature)
	return { settings = settings, providers = providers, preview = preview, cache = cache, keys = keys, sig = table.concat(parts, "\n") }
end

-- The panel's view, its bottom bar and its sheet.
local function panel_parts(state: PanelState): (Node, Node, string)
	local rules: { string } = { PANEL_CSS, NAMED_CSS }
	for _, provider in state.providers do
		local pal = "p-" .. pal_key(color_key(provider.id, provider.label))
		table.insert(rules, palette_rule(pal, palette_for(state.settings, provider.id, provider.label)))
	end
	local view = ui.el("div", { role = PANEL_ROLE }, {
		build.preview(state.settings, state.preview, rules, settings_hint(state.keys), state.providers, state.cache),
		build.show(state.settings, state.providers),
		build.providers(state.settings, state.providers),
		build.colors(state.settings, state.providers, rules),
		build.updates(),
	})
	return view, panel_dock(state.keys), table.concat(rules, "\n")
end

local panel_sig: string? = nil
-- While an update lands (update.luau), the panel shows an Updating… view instead and isn't redrawn.
local panel_paused = false
local panel_css: string? = nil

local function install_panel(css: string)
	if css ~= panel_css then
		panel_css = css
		tern.css(PANEL_SHEET, css)
	end
end

-- A drawing `sync_panel` scheduled and hasn't run yet; `flush_panel` runs it at once.
local pending_draw: ((cx: WindowCx) -> ())? = nil

-- Redraws the panel if what it shows changed (or `force`), from the poll's settings and cache when it has them.
-- The drawing (the view, its sheet and the update, ~10 ms) runs in a call of its own, so a poll that also drew
-- the line stays well inside its budget.
sync_panel = function(cx: WindowCx, force: boolean, settings: Settings?, cache: Cache?)
	local pane = panel_pane
	if pane == nil or panel_paused then
		return
	end
	local state = if settings then panel_state(cx, settings, cache) else panel_state(cx, load_settings(), read_cache(now_ms()))
	if state.sig == panel_sig and not force then
		return
	end
	panel_sig = state.sig
	local function draw(later: WindowCx)
		if pending_draw ~= draw then
			return -- drawn already, or a newer drawing replaced this one
		end
		pending_draw = nil
		if panel_pane ~= pane then
			return -- closed or replaced
		end
		local view, dock, css = panel_parts(state)
		install_panel(css)
		local ok = pcall(function()
			later.canvas:set(pane :: number, { view = view, dock = dock })
		end)
		if not ok then
			panel_pane = nil -- closed meanwhile
			panel_sig = nil
		end
	end
	pending_draw = draw
	tern.timer(0, function(later: WindowCx?)
		if later then
			draw(later)
		end
	end)
end

-- Draws a scheduled panel drawing now. Tern runs a timer set in an event handler (a click in the panel, a picker's
-- answer) only at the plugin's next poll, up to a second later, so a choice made there draws at once instead.
flush_panel = function(cx: WindowCx)
	local draw = pending_draw
	if draw then
		draw(cx)
	end
end

-- An update about to land, announced by any window: the plugin's sheets go away while Tern reloads it, so the
-- panel shows only Tern-styled nodes until then. The reloaded plugin draws the panel afresh (the reload timer
-- below); an update that failed brings the panel back here.
local function watch_update(cx: WindowCx?)
	tern.timer(1000, watch_update)
	local pane = panel_pane
	if cx == nil then
		return
	end
	local name = update.applying()
	if name and pane and not panel_paused then
		panel_paused = true
		panel_sig = nil
		pcall(function()
			cx.canvas:set(pane :: number, {
				view = ui.col({
					ui.card({ ui.span("Updating omp Usage to " .. name, "strong") }, {
						ui.progress(nil, "Downloading the update and reloading the plugin"),
					}, { icon = "download" }),
				}),
				dock = ui.text(ui.span("The settings come back as soon as it reloads", "muted")),
			})
		end)
	elseif name == nil and panel_paused then
		panel_paused = false
		sync_panel(cx, true)
	end
end
tern.timer(1000, watch_update)

-- This plugin's panel in this window, if one is open.
local function find_panel(cx: WindowCx): number?
	local ok, list = pcall(function(): any
		return cx.canvas:list()
	end)
	if ok and type(list) == "table" then
		for _, info in list do
			if info.owner == tern.plugin.id and info.title == PANEL_TITLE then
				return info.pane
			end
		end
	end
	return nil
end

local function open_panel(cx: WindowCx)
	local pane = find_panel(cx)
	if pane then
		panel_pane = pane
		sync_panel(cx, true)
		cx.layout:focus(pane :: number)
		return
	end
	local state = panel_state(cx, load_settings(), read_cache(now_ms()))
	local view, dock, css = panel_parts(state)
	install_panel(css)
	local opened, err = cx.canvas:open({ title = PANEL_TITLE, about = PANEL_ABOUT, view = view, dock = dock, how = "beside" })
	if opened == nil then
		cx:toast("error", "The omp Usage settings didn't open", err)
		return
	end
	panel_pane = opened
	panel_sig = state.sig
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean
	if ev.title ~= nil and ev.title ~= PANEL_TITLE then
		return false
	end
	panel_pane = ev.pane
	local act, value = ev.act, ev.value or ""
	-- What was picked up to move: a grab picks up (or puts back), a place puts it there, anything else puts it back.
	local lifted = moving
	moving = nil
	if act == "grab" then
		local id, name = string.match(value, "^account/([^/]+)/(.+)$")
		local picked: Moving? = if id and name then { kind = "account", id = id, name = name } else nil
		local provider = string.match(value, "^provider/(.+)$")
		if picked == nil and provider then
			picked = { kind = "provider", id = provider }
		end
		if picked == nil then
			moving = lifted
			return false
		end
		local again = lifted ~= nil and lifted.kind == picked.kind and lifted.id == picked.id and lifted.name == picked.name
		moving = if again then nil else picked
	elseif act == "place" then
		local kind, at = string.match(value, "^(%a+)/.-(%d+)$")
		local slot = tonumber(at)
		if lifted == nil or kind ~= lifted.kind or slot == nil then
			return false
		end
		if lifted.kind == "provider" then
			move_provider(lifted.id, slot :: number)
		elseif lifted.name then
			move_account(lifted.id, lifted.name :: string, slot :: number)
		end
	elseif act == "mode" then
		if value ~= "current" and value ~= "all" and value ~= "selected" then
			return false
		end
		store.set(KV_MODE, value)
	elseif act == "toggle" then
		store.set(KV_SELECTED, toggled(load_settings().selected, value))
		store.set(KV_MODE, "selected") -- switching a provider is choosing which to show
	elseif act == "window" then
		local id, label = string.match(value, "^([^/]+)/(.+)$")
		if id == nil or label == nil then
			return false
		end
		toggle_window(id, label)
	elseif act == "account" then
		local id, name = string.match(value, "^([^/]+)/(.*)$")
		if id == nil or name == nil then
			return false
		end
		choose_account(id, name)
	elseif act == "combine" then
		choose_account(value, COMBINED)
	elseif act == "combine-plans" then
		choose_account(value, COMBINED_PLANS)
	elseif act == "card-rows" then
		local rows = tonumber(value)
		if rows == nil or not table.find(CARD_ROWS, rows) then
			return false
		end
		store.set(KV_CARD_ROWS, rows)
	elseif act == "account-show" then
		local id, name = string.match(value, "^([^/]+)/(.+)$")
		if id == nil or name == nil then
			return false
		end
		toggle_account(id, name)
	elseif act == "named" then
		local key, name = string.match(value, "^(.*)/([^/]+)$")
		if key == nil or name == nil or named_palette(name) == nil then
			return false
		end
		save_color(key, "named:" .. name)
	elseif act == "preset" or act == "reset" then
		save_color(value, nil)
	elseif act == "custom" then
		prompt_color(cx, value, label_of(store.providers(), value))
		return true
	elseif act == "update-check" then
		update.check(cx, true)
		return true
	elseif act == "update-every" then
		update.set_interval(cx, value)
	elseif act == "update-download" then
		update.download(cx)
		return true
	else
		moving = lifted
		return false
	end
	after_change(cx)
	return true
end)

tern.on("pane_closed", function(ev: { pane: number }, _cx: WindowCx)
	if ev.pane == panel_pane then
		panel_pane = nil
		panel_sig = nil
		moving = nil
	end
end)

-- A reload finds the panel Tern kept, and draws it (its sheet went with the reload), once the first poll is done.
tern.timer(600, function(cx: WindowCx?)
	if cx then
		panel_pane = find_panel(cx)
		if panel_pane then
			sync_panel(cx, true)
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

-- `usage` in the status bar, on an agent pane: a click opens the panel. On every pane, while an update is waiting,
-- Update omp Usage (update.luau) first.
local STATUS: { StatusSegment } = { { text = "usage", icon = "gauge", command = PANEL_ACTION } }

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local pending = update.status_segment()
	if pending == nil then
		return if pane.kind == "agent" then STATUS else nil
	end
	return if pane.kind == "agent" then { pending, STATUS[1] } else { pending }
end)
