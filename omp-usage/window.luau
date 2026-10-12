--!strict
-- Shows what omp's `usage-remaining` extension (omp/extensions/usage-remaining.js in this repo) reports, as one
-- line above the composer's context hairline (the `1% ──── 1M` row).
--
-- The extension stays the source of truth: it picks the active model's provider, its applicable windows,
-- saved resets and countdowns. It sets that line with `ctx.ui.setStatus`, which omp draws in the composer bar's
-- extras, and after every fetch it also writes ~/.omp/cache/usage-remaining.json: every model's line keyed by
-- the name omp's model chip shows, every provider's plan-wide line, and the saved resets' expiry dates. This
-- plugin reads both from the focused agent pane and draws the line with CSS above the hairline's meter,
-- rewritten with `tern.css` when it changes; bar.css hides the extras in the bar. Other `ctx.ui.setStatus`
-- parts are kept, except the `◫ …` context gauge (context-used.js), which the hairline already shows.
--
-- What the line shows depends on the mode (kept in `tern.kv`, set from the settings panel or the `omp Usage:
-- Settings…` picker): the focused agent's provider (`current`), every provider in the cache (`all`) or the
-- chosen ones (`selected`), in the user's order. While a subagent's transcript is viewed (omp adds a `Viewing
-- <agent>` row to the composer and its model chip shows the subagent's model, but the status stays the main
-- session's), `current` shows the line the cache holds for that chip; otherwise it shows the status, which is
-- fresher. Without a fresh cache every mode falls back to the status.
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
-- meter, so it can be laid over the line with the meter's own offsets. While attachments show, the line stays
-- but doesn't react to hover.
--
-- When a window's share changes (a window is its provider and its label, so switching providers or modes
-- doesn't count), the line prints again, left to right, while a comet runs each changed bar to its new level
-- and settles into its tip: in the provider's color when quota went down, `--ok` when it came back. Nothing
-- moves at rest, and Reduce Motion (either Tern's or the system's) drops every fade, rise and sweep.

-- Re-reads the composer dock (~40 nodes) every second, and the cache's text (a few KB, decoded only when it
-- changed) as `poll_cache` last fetched it. The usage-remaining extension redraws within a second of a model
-- switch, so this follows it within about two.
local POLL_MS = 1000
local SHEET = "usage"
-- omp's composer bar extras: one `hook-N` fact per `ctx.ui.setStatus` key with `statusLine.showHookStatus`,
-- or one `status` fact (all keys joined) with the `status` statusline segment. Ids carry a generated prefix
-- (`k.` in omp 18.6, `3.` in 18.7), so they are matched by suffix inside the dock region, whose root id is `dock`.
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
-- `selected` shows, color choices by provider id (`named:<key>`, or one or two `#rrggbb`), and the providers'
-- order (ids; providers it doesn't name follow in the preset order).
local KV_MODE = "omp-usage.mode"
local KV_SELECTED = "omp-usage.selected"
local KV_COLORS = "omp-usage.colors"
local KV_ORDER = "omp-usage.order"

type Window = { label: string, pct: number, reset: string?, saved: number?, expires: string? }
type Reset = { at: number, count: number }
-- A provider on the line: its key (provider id when known, else its label), label, windows and saved resets
-- (nil when the cache has none for it).
type Group = { key: string, id: string?, label: string, windows: { Window }, resets: { Reset }? }
-- What the line and card show, where it came from (a change counts only between two lines from the same
-- source), and the card's title.
type Model = {
	groups: { Group },
	others: { string },
	source: string,
	title: string,
	signature: string,
}
type Dock = { status: string?, chip: string?, viewing: boolean }
type Provider = { id: string, label: string, line: string, resets: { Reset } }
type Entry = { line: string, resets: { Reset } }
type Cache = { at: number, models: { [string]: Entry }, providers: { Provider }? }
type Settings = { mode: string, selected: { string }, colors: { [string]: string }, order: { string } }
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

-- From a dock tree (`cx.session:surface`'s answer): the status facts joined, the model chip's name, and whether
-- a subagent's transcript is being viewed.
local function dock_facts(tree: any): Dock
	local dock: Dock = { status = nil, chip = nil, viewing = false }
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

-- A saved reset's card row: `saved reset · expires Thu Oct 22, 12:00 PM · in 10d 18h` (`2 saved resets · …` for
-- a credit of two); nil once it has expired.
local function reset_text(reset: Reset, now: number): string?
	if reset.at <= now then
		return nil
	end
	local ok, t = pcall(os.date, "*t", math.floor(reset.at / 1000))
	local ok_now, today = pcall(os.date, "*t", math.floor(now / 1000))
	if not ok or type(t) ~= "table" or not ok_now or type(today) ~= "table" then
		return nil
	end
	local date = string.format("%s %s %d", WEEKDAYS[(t :: any).wday], MONTHS[(t :: any).month], (t :: any).day)
	if (t :: any).year ~= (today :: any).year then
		date ..= " " .. tostring((t :: any).year)
	end
	local what = if reset.count > 1 then string.format("%d saved resets", reset.count) else "saved reset"
	return string.format("%s · expires %s, %s · in %s", what, date, clock(t), span(reset.at - now))
end

-- One usage-remaining.js window, `[Provider ]<label> <meter> <N>% left[ (<reset>)][ (+N) | (!N - <left> left)]`,
-- and the provider in front of it, if any.
local function parse_window(piece: string): (Window?, string?)
	local head, label, pct, rest = string.match(piece, "^(.-)(%S+) %S+ (%d+)%% left(.*)$")
	if label == nil then
		return nil, nil
	end
	local window: Window = { label = label :: string, pct = tonumber(pct) :: number }
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
	local provider = string.match(head :: string, "^(.-)%s*$")
	return window, if provider and provider ~= "" then provider else nil
end

-- A usage line, `<Label> <window> · <window>`, or a status with other parts between: the label in front of
-- the first window, the windows, and the other parts as they are.
local function parse_line(text: string): (string?, { Window }, { string })
	local label: string? = nil
	local windows: { Window } = {}
	local others: { string } = {}
	for _, piece in usage_pieces(text) do
		local window, provider = parse_window(piece)
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
				table.insert(resets, { at = item.expiresAt, count = count })
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
				table.insert(list, { id = id, label = label, line = item.line, resets = resets_of(item.resets) })
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
		table.insert(list, { id = id, label = label, line = "", resets = {} })
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
	local settings: Settings = { mode = "current", selected = id_list(store.get(KV_SELECTED)), colors = {}, order = id_list(store.get(KV_ORDER)) }
	local mode = store.get(KV_MODE)
	if mode == "all" or mode == "selected" then
		settings.mode = mode
	end
	local colors = store.get(KV_COLORS)
	if type(colors) == "table" then
		for id, spec in pairs(colors) do
			if type(id) == "string" and type(spec) == "string" then
				settings.colors[id] = spec
			end
		end
	end
	return settings
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

-- The order to store once `id` moves (`up`, `down`, `top`, `bottom`) among `shown`, the ids of the providers on
-- offer in their order. It names every one of them; ids it named that aren't on offer now keep their places.
local function moved(order: { string }, shown: { string }, id: string, how: string): { string }
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
	if how == "up" then
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

local function signature_of(groups: { Group }, others: { string }, title: string): string
	local parts: { string } = { title }
	for _, group in groups do
		table.insert(parts, group.key .. "=" .. group.label)
		for _, window in group.windows do
			table.insert(
				parts,
				string.format("%s:%d:%s:%s:%s", window.label, window.pct, window.reset or "", tostring(window.saved or ""), window.expires or "")
			)
		end
		for _, reset in group.resets or {} do
			table.insert(parts, string.format("r%d*%d", reset.at, reset.count))
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
-- come from the cache entry the line came from (the status's model is the chip's).
local function build_model(settings: Settings, dock: Dock, cache: Cache?): Model
	local label, windows, others = parse_line(if dock.status then usage_part(dock.status) else "")
	local groups: { Group } = {}
	local source = "status"
	local title: string? = nil
	local providers = if cache then cache.providers else nil
	if settings.mode ~= "current" and providers then
		for _, provider in ordered(providers, settings.order) do
			if settings.mode == "all" or table.find(settings.selected, provider.id) then
				local provider_label, provider_windows = parse_line(provider.line)
				if #provider_windows > 0 then
					table.insert(groups, {
						key = provider.id,
						id = provider.id,
						label = provider_label or provider.label,
						windows = provider_windows,
						resets = provider.resets,
					})
				end
			end
		end
		source = settings.mode
	end
	if #groups == 0 then
		local entry = if cache and dock.chip then cache.models[dock.chip :: string] else nil
		if dock.viewing and entry then
			label, windows = parse_line(entry.line)
			source = "model:" .. (dock.chip :: string)
		else
			source = "status"
		end
		if #windows > 0 then
			local id = if label then provider_id(label, cache) else nil
			table.insert(groups, {
				key = id or label or "usage",
				id = id,
				label = label or "",
				windows = windows,
				resets = if entry then entry.resets else nil,
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
			if w > 1 and several then
				add(" " .. NBSP)
			else
				next_part()
			end
			if w == 1 and group.label ~= "" then
				add(group.label, group_color(g, "a"))
				add(NBSP .. NBSP)
			end
			add(string.upper(window.label), "var(--ou-lbl)")
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
				local saved = "+" .. tostring(window.saved)
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

-- The hover target: the composer's empty chips row (see the header), laid over the usage line.
local HOST = "%s.sf-col[data-role^='omp.editor'] > .sf-row[data-role='omp.composer.chips']:is(.sf-hidden, .sf-void)"
local METER = ".tn-pane.on .sf-meter[data-role='omp.composer.context']"

-- The target in the focused pane; `region` narrows it by a class of the surface region (`.sf-chat-reader`,
-- `.sf-still`), which sits between the pane and the composer.
local function host(region: string?): string
	return ".tn-pane.on " .. string.format(HOST, if region then region .. " " else "")
end

-- The providers' colors as variables on the composer, which the line, its tips, the capsule and the card all
-- sit in; the capsule's ring and the card's glow follow the line's one provider (with several, the theme's), and
-- the ring turns `--warn` or `--bad` with the lowest window.
local function palette_css(model: Model, settings: Settings): string
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
	return ".tn-pane.on .sf-col[data-role^='omp.editor'] {\n" .. table.concat(lines, "\n") .. "\n}"
end

-- The line twice: on the meter at rest, and on the hover target over it, at full strength. The target's two
-- pseudo-elements are all a hover can change: Tern restyles the hovered element and its own parts, not its
-- siblings (`:hover +` never updates there), and the line lives on the meter, which comes before the target. So
-- the target's box is the capsule, its `::before` the bright copy, glyph for glyph over the line, and its
-- `::after` the card.
local LINE_CSS = [==[
/* room above the hairline for the usage line, clear of the working row; every agent pane, so focus never shifts it */
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
	left: -6px;
	width: min($WIDTH, calc(100% - 4px));
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
		METER = METER,
		HOST = host(nil),
		HOST_READER = host(".sf-chat-reader"),
		HOST_SPINE = host(".sf-chat-spine"),
		HOST_CONSOLE = host(".sf-chat-console"),
		PALETTE = palette_css(model, settings),
		CONTENT = css_string(line.text),
		PAINT = paint,
		TIPS_CSS = if #rest.images > 0
			then fill(TIPS_CSS, {
				METER = METER,
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
local function card(model: Model, hint: string): { Row }
	local key = model.signature .. "\n" .. hint
	if key == card_for then
		return card_rows
	end
	local now = now_ms()
	local rows: { Row } = { { text = model.title, color = "var(--oc-head)" } }
	local several = #model.groups > 1
	for g, group in model.groups do
		local accent = group_color(g, "a")
		if several then
			table.insert(rows, { text = group.label, color = accent })
		end
		local resets = group.resets or {}
		local carrier: number? = nil
		for w, window in group.windows do
			if window.saved then
				carrier = w
			end
		end
		if carrier == nil and #resets > 0 then
			for w, window in group.windows do
				if window.label == "7d" then
					carrier = w
				end
			end
		end
		local function add_resets()
			for _, reset in resets do
				local text = reset_text(reset, now)
				if text then
					table.insert(rows, {
						text = CARD_INDENT .. text,
						color = if reset.at - now <= RESET_WARN_MS then "var(--oc-warn)" else accent,
					})
				end
			end
		end
		for w, window in group.windows do
			local tone = tone_of(window.pct)
			local a, b = window_colors(tone, g)
			table.insert(rows, {
				text = (WINDOW_NAMES[window.label] or window.label) .. " window",
				right = tostring(window.pct) .. "% left",
				color = "var(--oc-win-" .. tone .. ")",
				share = math.clamp(window.pct, 0, 100) / 100,
				a = a,
				b = b,
			})
			local reset = window.reset
			if reset == "soon" then
				table.insert(rows, { text = CARD_INDENT .. "resets soon", color = "var(--oc-mute)" })
			elseif reset then
				local row = "resets in " .. reset
				local minutes, exact = countdown_minutes(reset)
				local at = if minutes then clock_at(minutes, exact) else nil
				if at then
					row ..= " · " .. at
				end
				table.insert(rows, { text = CARD_INDENT .. row, color = "var(--oc-mute)" })
			end
			if w == carrier and #resets > 0 then
				add_resets()
			elseif window.saved then
				local saved = window.saved :: number
				local row = string.format("%d saved reset%s", saved, if saved == 1 then "" else "s")
				if window.expires then
					row ..= " · expires in " .. (window.expires :: string)
				end
				table.insert(rows, {
					text = CARD_INDENT .. row,
					color = if window.expires then "var(--oc-warn)" else accent,
				})
			end
		end
		if carrier == nil then
			add_resets()
		end
	end
	for _, other in model.others do
		table.insert(rows, { text = other, color = "var(--oc-soft)" })
	end
	table.insert(rows, { text = hint, color = "var(--oc-hint)", rule = true })
	card_for = key
	card_rows = rows
	return rows
end

local CARD_CSS = [==[
/* the card: the line's facts spelled out over it, a row each, in a glass panel with a title bar; one gradient,
   row by row, colors the text, and each window's row sits on a meter with a lit tip */
$HOST:hover::after {
	content: "$CONTENT";
	position: absolute;
	left: 0;
	bottom: calc(100% + 8px);
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
	transform-origin: 16px 100%;
	/* after a beat: it rises into place and its meters fill */
	animation:
		omp-usage-card 0.28s var(--out) 0.35s both,
		omp-usage-fill 0.7s var(--out) 0.4s both;
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
@keyframes omp-usage-card {
	from { opacity: 0; transform: translateY(5px) scale(0.97); }
	to { opacity: 1; transform: none; }
}
@keyframes omp-usage-fill {
	from { background-size: $FROM_SIZES; }
	to { background-size: $SIZES; }
}
]==]

local function card_css(rows: { Row }): string
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
	return fill(CARD_CSS, {
		HOST = host(nil),
		CONTENT = table.concat(lines, "\\A "),
		IMAGES = table.concat(images, ", "),
		POSITIONS = table.concat(positions, ", "),
		SIZES = table.concat(sizes, ", "),
		FROM_SIZES = table.concat(from_sizes, ", "),
		ORIGINS = table.concat(origins, ", "),
		CLIPS = table.concat(clips, ", "),
	})
end

local STILL_CSS = fill(
	[==[
/* Reduce Motion, either way: no fades, no rise, no fill, no change sweep; the card still waits its beat, then
   shows at once */
$HOST_STILL,
$HOST_STILL::before {
	transition: none;
}
$HOST_STILL:hover::after {
	animation: omp-usage-card-still 0s 0.35s both !important;
}
.tn-pane.on .sf-still .sf-meter[data-role='omp.composer.context']::before,
.tn-pane.on .sf-still .sf-meter[data-role='omp.composer.context']::after {
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
]==],
	{ HOST = host(nil), HOST_STILL = host(".sf-still"), METER = METER }
)

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
		METER = METER,
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
	local css = line_css(line, model, settings) .. card_css(card(model, hint)) .. STILL_CSS
	-- Only while it runs: a sheet rewritten later (a countdown tick) must not replay it.
	if p and #line.bars > 0 and tern.now() < p.until_ms then
		css ..= pulse_css(line, p)
	end
	return css
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
local function settings_hint(cx: WindowCx): string
	return "settings · " .. (shortcut(cx) or "omp Usage in the palette")
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
	local hint = settings_hint(cx)
	local running = if pulse and tern.now() < pulse.until_ms then pulse.seq else 0
	local key = table.concat({ model.signature, colors_key(settings), hint, tostring(running) }, "\n")
	if key ~= sheet_key then
		sheet_key = key
		install(sheet(model, settings, pulse, hint))
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

-- Shows the focused agent's usage; a focused non-agent pane keeps the last line (no composer shows it there),
-- but while the settings panel has focus the line it last showed follows the settings, for the panel's preview.
-- Then redraws the panel if what it shows changed.
refresh = function(cx: WindowCx)
	local target: number? = nil
	local pane = cx.session:focused()
	if pane ~= nil then
		local info = cx.session:pane(pane)
		if info and info.kind == "agent" then
			target = pane
		elseif info and pane == panel_pane then
			target = shown_pane or some_agent(cx, info.tab)
		end
	end
	if target == nil and panel_pane == nil then
		return
	end
	local settings = load_settings()
	local cache = read_cache(now_ms())
	if target ~= nil then
		show_pane(cx, target :: number, settings, cache)
	end
	if panel_pane ~= nil then
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

local function move_provider(id: string, how: string)
	local settings = load_settings()
	local shown: { string } = {}
	for _, provider in providers_in_order(settings) do
		table.insert(shown, provider.id)
	end
	store.set(KV_ORDER, moved(settings.order, shown, id, how))
end

local function after_change(cx: WindowCx?)
	if cx then
		refresh(cx)
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
			open_color_choices(next_cx or cx, { id = chosen.id, label = chosen.name, line = "", resets = {} })
		end)
end

-- The settings panel: a canvas of buttons beside the pane it was opened from, one per window (opening it again
-- shows the one there is). It redraws when a setting changes, from it or from the pickers, and as the line it
-- previews changes. Its clicks arrive as `canvas_action` events. Tern keeps canvases across reloads, so a
-- reload takes over the one it finds.
local PANEL_TITLE = "omp Usage settings"
local PANEL_ABOUT = "Settings for the omp Usage line above omp's composer: what it shows, the providers' order "
	.. "and their colors. Each button changes one setting at once and runs nothing else."
local PANEL_SHEET = "panel"
local PANEL_ROLE = "omp-usage.panel"
local DOCK_ROLE = "omp-usage.panel-dock"
local PANEL = "[data-role='" .. PANEL_ROLE .. "']"
local PANEL_DOCK = "[data-role='" .. DOCK_ROLE .. "']"
local NO_DOCK: Dock = { status = nil, chip = nil, viewing = false }
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
/* the line as the composer draws it, a window at a time so it wraps between windows as the composer's does, on
   a stage lit from its corner in the provider's color */
$P .oup-stage {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 10px 26px;
	min-height: 48px;
	padding: 14px 16px;
	border-radius: 12px;
	background-color: var(--code-bg);
	background-image: radial-gradient(120% 160% at 0% 0%, rgb(from var(--ou-stage) r g b / 16%), transparent 62%);
	box-shadow: 0 0 0 1px var(--l2), inset 0 1px 0 var(--glass-hi);
}
$P .oup-pv {
	display: flex;
	flex-wrap: wrap;
	gap: 6px 14px;
	min-width: 0;
}
$P .oup-chip {
	max-width: 100%;
	overflow: hidden;
	white-space: pre;
	font: 500 11px/16px var(--mono);
	font-variant-numeric: tabular-nums;
	color: transparent;
	background-repeat: no-repeat;
	background-clip: text;
	--ou-lbl: var(--t2);
	--ou-sep: var(--t3);
	--ou-num-ok: var(--t1);
	--ou-num-warn: var(--warn);
	--ou-num-bad: var(--bad);
	--ou-dim: var(--t3);
	--ou-soft: var(--t2);
	--ou-track: color-mix(in srgb, var(--t1) 18%, transparent);
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
/* the providers, a row each in the line's order: index, swatch and label, what is left, then the Selected switch
   and the moves, which drop under the rest when the pane is narrow */
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
$P .oup-sum {
	display: flex;
	flex: 1 1 0;
	gap: 14px;
	min-width: 0;
	overflow: hidden;
	white-space: nowrap;
	font: 500 10.5px/14px var(--mono);
	font-variant-numeric: tabular-nums;
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
$P .oup-prow[data-off] .oup-sum {
	opacity: 0.4;
}
$P .oup-switch {
	position: relative;
	flex: none;
	margin-right: 10px;
	width: 30px;
	height: 18px;
	border-radius: 9px;
	background-color: var(--l3);
	cursor: pointer;
	transition: opacity 0.18s var(--ease);
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
$P .oup-mv {
	display: flex;
	flex: none;
	align-items: center;
	justify-content: center;
	width: 26px;
	height: 26px;
	border-radius: 7px;
	font: 600 9.5px/12px var(--mono);
	letter-spacing: 0.1em;
	text-transform: uppercase;
	color: var(--t3);
	cursor: pointer;
	transition:
		color 0.14s var(--ease),
		background-color 0.14s var(--ease);
}
$P .oup-mv:hover {
	color: var(--t1);
	background-color: var(--l2);
}
$P .oup-gap {
	visibility: hidden;
}
$P .oup-top {
	width: 34px;
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

-- The line as it shows now, painted as the composer paints it: a window at a time (the provider's label with its
-- first), so it wraps between windows as the composer's does.
local function preview_section(settings: Settings, preview: Model, rules: { string }): Node
	local providers: { Node } = {}
	local several = #preview.groups > 1
	local n = 0
	for g, group in preview.groups do
		local palette = palette_for(settings, group.id, group.label)
		local chips: { Node } = {}
		for w, window in group.windows do
			local part: Group = { key = group.key, id = group.id, label = if w == 1 then group.label else "", windows = { window }, resets = group.resets }
			local line = line_of({ groups = { part }, others = {}, source = preview.source, title = "", signature = "" }, several)
			n += 1
			table.insert(chips, ui.el("div", { key = "w" .. w, class = "oup-chip", text = line.text, attrs = { ["data-ou-chip"] = n } }))
			table.insert(
				rules,
				string.format(
					"%s .oup-chip[data-ou-chip='%d'] {\n\t--ou-g1-a: %s;\n\t--ou-g1-b: %s;\n\tbackground-image: %s;\n}",
					PANEL,
					n,
					palette.a,
					palette.b or palette.a,
					line_paint(line)
				)
			)
		end
		table.insert(providers, ui.el("div", { key = "g" .. g, class = "oup-pv" }, chips))
	end
	local glow = if #preview.groups == 1 then palette_for(settings, preview.groups[1].id, preview.groups[1].label).a else "var(--accent)"
	table.insert(rules, string.format("%s .oup-stage {\n\t--ou-stage: %s;\n}", PANEL, glow))
	if #providers == 0 then
		table.insert(providers, ui.el("div", { class = "oup-empty", text = "Nothing to show yet. Focus an omp pane and its line appears here." }))
	end
	return section("preview", "Line", "as the composer shows it", { ui.el("div", { class = "oup-stage" }, providers) })
end

local function show_section(settings: Settings, providers: { Provider }): Node
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

-- What a provider has left, by window.
local function left_now(provider: Provider): { Node }
	local _, windows = parse_line(provider.line)
	local nodes: { Node } = {}
	for _, window in windows do
		local tone = tone_of(window.pct)
		table.insert(
			nodes,
			ui.el("span", {}, {
				ui.el("span", { class = "oup-w", text = string.upper(window.label) }),
				ui.el("span", { class = "oup-v", text = tostring(window.pct) .. "%", attrs = { ["data-low"] = if tone ~= "ok" then tone else nil } }),
			})
		)
	end
	if #nodes == 0 then
		table.insert(nodes, ui.el("span", { class = "oup-w", text = if provider.line == "" then "no data yet" else "no limits" }))
	end
	return nodes
end

local function provider_row(settings: Settings, provider: Provider, i: number, n: number): Node
	local on = table.find(settings.selected, provider.id) ~= nil
	local function move(act: string, label: string, can: boolean, icon: string?, text: string?): Node
		local class = if icon then "oup-mv" else "oup-mv oup-top"
		if not can then
			return ui.el("span", { class = class .. " oup-gap", attrs = { ["aria-hidden"] = "true" } })
		end
		return ui.el("button", {
			class = class,
			text = text,
			actions = { click = act .. "=" .. provider.id },
			attrs = { ["aria-label"] = label },
		}, if icon then { ui.node("icon", { name = icon }) } else nil)
	end
	return ui.el("div", {
		key = "p-" .. provider.id,
		class = "oup-prow",
		attrs = {
			["data-ou-pal"] = "p-" .. pal_key(color_key(provider.id, provider.label)),
			["data-off"] = if settings.mode == "selected" and not on then true else nil,
		},
	}, {
		ui.el("span", { class = "oup-who" }, {
			ui.el("span", { class = "oup-idx", text = string.format("%02d", i) }),
			ui.el("span", { class = "oup-swatch" }),
			ui.el("span", { class = "oup-name", text = provider.label }),
		}),
		ui.el("span", { class = "oup-sum" }, left_now(provider)),
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
			move("up", "Move " .. provider.label .. " up", i > 1, "chev-up", nil),
			move("down", "Move " .. provider.label .. " down", i < n, "chev", nil),
			move("top", "Move " .. provider.label .. " to the top", i > 1, nil, "top"),
		}),
	})
end

local function providers_section(settings: Settings, providers: { Provider }): Node
	local rows: { Node } = {}
	for i, provider in providers do
		table.insert(rows, provider_row(settings, provider, i, #providers))
	end
	return section("providers", "Providers", "Top to bottom is the line's left to right. The switches pick what Selected providers shows.", {
		ui.el("div", { class = "oup-rows", attrs = { ["data-idle"] = if settings.mode ~= "selected" then true else nil } }, rows),
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

local function colors_section(settings: Settings, providers: { Provider }, rules: { string }): Node
	local rows: { Node } = {}
	for _, provider in providers do
		table.insert(rows, color_row(settings, provider, rules))
	end
	return section("colors", "Colors", "A label's color and its bars'. Point at a swatch for its name.", rows)
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
-- with these settings) and the shortcut; `sig` changes whenever any of it does.
type PanelState = { settings: Settings, providers: { Provider }, preview: Model, keys: string?, sig: string }

local function panel_state(cx: WindowCx, settings: Settings, cache: Cache?): PanelState
	local providers = ordered(offered_providers(cache), settings.order)
	local preview = build_model(settings, last_dock or NO_DOCK, cache)
	local keys = shortcut(cx)
	local parts: { string } = {
		settings.mode,
		table.concat(settings.selected, ","),
		table.concat(settings.order, ","),
		colors_key(settings),
		keys or "",
	}
	for _, provider in providers do
		table.insert(parts, provider.id .. "|" .. provider.label .. "|" .. provider.line)
	end
	table.insert(parts, preview.signature)
	return { settings = settings, providers = providers, preview = preview, keys = keys, sig = table.concat(parts, "\n") }
end

-- The panel's view, its bottom bar and its sheet.
local function panel_parts(state: PanelState): (Node, Node, string)
	local rules: { string } = { PANEL_CSS, NAMED_CSS }
	for _, provider in state.providers do
		local pal = "p-" .. pal_key(color_key(provider.id, provider.label))
		table.insert(rules, palette_rule(pal, palette_for(state.settings, provider.id, provider.label)))
	end
	local view = ui.el("div", { role = PANEL_ROLE }, {
		preview_section(state.settings, state.preview, rules),
		show_section(state.settings, state.providers),
		providers_section(state.settings, state.providers),
		colors_section(state.settings, state.providers, rules),
	})
	return view, panel_dock(state.keys), table.concat(rules, "\n")
end

local panel_sig: string? = nil
local panel_css: string? = nil

local function install_panel(css: string)
	if css ~= panel_css then
		panel_css = css
		tern.css(PANEL_SHEET, css)
	end
end

-- Redraws the panel if what it shows changed (or `force`), from the poll's settings and cache when it has them.
-- The drawing (the view, its sheet and the update, ~10 ms) runs in a call of its own, so a poll that also drew
-- the line stays well inside its budget.
sync_panel = function(cx: WindowCx, force: boolean, settings: Settings?, cache: Cache?)
	local pane = panel_pane
	if pane == nil then
		return
	end
	local state = if settings then panel_state(cx, settings, cache) else panel_state(cx, load_settings(), read_cache(now_ms()))
	if state.sig == panel_sig and not force then
		return
	end
	panel_sig = state.sig
	tern.timer(0, function(later: WindowCx?)
		if later == nil or panel_pane ~= pane or panel_sig ~= state.sig then
			return -- closed, replaced, or a newer drawing is on its way
		end
		local view, dock, css = panel_parts(state)
		install_panel(css)
		local ok = pcall(function()
			(later :: WindowCx).canvas:set(pane :: number, { view = view, dock = dock })
		end)
		if not ok then
			panel_pane = nil -- closed meanwhile
			panel_sig = nil
		end
	end)
end

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
	if act == "mode" then
		if value ~= "current" and value ~= "all" and value ~= "selected" then
			return false
		end
		store.set(KV_MODE, value)
	elseif act == "toggle" then
		store.set(KV_SELECTED, toggled(load_settings().selected, value))
		store.set(KV_MODE, "selected") -- switching a provider is choosing which to show
	elseif act == "up" or act == "down" or act == "top" or act == "bottom" then
		move_provider(value, act)
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
	else
		return false
	end
	after_change(cx)
	return true
end)

tern.on("pane_closed", function(ev: { pane: number }, _cx: WindowCx)
	if ev.pane == panel_pane then
		panel_pane = nil
		panel_sig = nil
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

-- `usage` in the status bar, on an agent pane: a click opens the panel.
local STATUS: { StatusSegment } = { { text = "usage", icon = "gauge", command = PANEL_ACTION } }

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	return if pane.kind == "agent" then STATUS else nil
end)
