--!strict
-- What omp Usage draws, before it is drawn: the providers and their colors, the settings in `tern.kv`, the
-- extension's cache, the facts read from an omp pane's composer, and the model of the line built from them.
-- render.luau draws the model; window.luau, the pickers (pickers.luau) and the settings panel (panel.luau) read
-- and change the settings through here.
local detail_view = require("./details")

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
	"xai",
	"muse-code",
	"github-copilot",
	"cursor",
	"zai",
	"zai-coding-plan",
	"factory-droid",
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
	Grok = "xai",
	Muse = "muse-code",
	Copilot = "github-copilot",
	Cursor = "cursor",
	Zai = "zai",
	Factory = "factory-droid",
}
-- A provider's colors: `a` for its label and the start of its bars, `b` (else `a`) for where they end, their
-- tips and its comets. Each is a shade per theme, so it reads on light and dark alike.
export type Palette = { name: string, a: string, b: string? }
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
	["google-antigravity"] = {
		name = "Green to blue",
		a = "light-dark(#15803d, #4ade80)",
		b = "light-dark(#1d4ed8, #60a5fa)",
	},
	["minimax-code"] = {
		name = "Red to pink",
		a = "light-dark(#d23f57, #f2576f)",
		b = "light-dark(#c2428e, #ff80c5)",
	},
	["opencode-go"] = { name = "Go cyan", a = "light-dark(#0a8aa1, #2ccde6)" },
	["alibaba-token-plan"] = { name = "Qwen purple", a = "light-dark(#6c4fd0, #a088ff)" },
	devin = { name = "Teal to white", a = "light-dark(#0e8c80, #34c8b6)", b = "light-dark(#134e4a, #ecfeff)" },
	xai = { name = "Grok mono", a = "light-dark(#52525b, #a1a1aa)", b = "light-dark(#18181b, #fafafa)" },
	["muse-code"] = { name = "Pink to blue", a = "light-dark(#be185d, #f472b6)", b = "light-dark(#1d5fd6, #5b9bff)" },
	["github-copilot"] = { name = "Purple to cyan", a = "light-dark(#7c3aed, #b083f0)", b = "light-dark(#0e7490, #22d3ee)" },
	cursor = { name = "White to green", a = "light-dark(#27272a, #e4e4e7)", b = "light-dark(#047857, #34d399)" },
	zai = { name = "Indigo to teal", a = "light-dark(#4338ca, #818cf8)", b = "light-dark(#0f766e, #2dd4bf)" },
	["zai-coding-plan"] = { name = "Indigo to teal", a = "light-dark(#4338ca, #818cf8)", b = "light-dark(#0f766e, #2dd4bf)" },
	["factory-droid"] = { name = "Orange to violet", a = "light-dark(#c2410c, #fb923c)", b = "light-dark(#6d28d9, #a78bfa)" },
	synthetic = { name = "Violet to white", a = "light-dark(#7e22ce, #c084fc)", b = "light-dark(#581c87, #faf5ff)" },
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
-- A detail's `text` is always the readable row (older caches write only that). When the writer also says what
-- the row is (`kind`) and the value it already formatted (`value`), the card can pair a window's observed
-- amounts with its estimates; the text still stands in when a kind is unknown or a value is missing.
export type Detail = { text: string, account: string?, window: string?, kind: string?, value: string? }
export type Window = {
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
export type Reset = { at: number, count: number, window: string? }
-- A provider on the line: its key (provider id when known, else its label), label, windows and saved resets
-- (nil when the cache has none for it); `rest`, while one of its accounts is chosen, the other accounts' windows.
export type Group = { key: string, id: string?, label: string, windows: { Window }, resets: { Reset }?, rest: { Window }?, details: { Detail }? }
-- What the line and card show, where it came from (a change counts only between two lines from the same
-- source), and the card's title.
export type Model = {
	groups: { Group },
	others: { string },
	source: string,
	title: string,
	signature: string,
}
-- `hide`: the ids of the status facts the line redraws, to hide in the bar.
export type Dock = { status: string?, chip: string?, viewing: boolean, hide: { string } }
-- `windows`: every window the provider's accounts report, its plan's and those only some of its models have.
-- `accounts`: with several, their names in omp's order (as the line's labels start); else empty.
export type Provider = { id: string, label: string, line: string, resets: { Reset }, windows: { Window }, accounts: { string }, details: { Detail }? }
export type Entry = { line: string, resets: { Reset }, provider: string?, details: { Detail }? }
export type Cache = { at: number, models: { [string]: Entry }, providers: { Provider }? }
export type Settings = {
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
	-- an external source's provider keeps its own id after the source's (`keeper:dashboard:anthropic`)
	provider = if provider then (string.match(provider, "^[^:]+:[^:]+:(.+)$") or provider) else nil
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

-- The detail kinds the card understands. A kind it doesn't know (or one whose value is missing) leaves the row
-- as text: an older writer, or a newer one with more to say, never loses what it already said.
detail_view.kinds = {
	["tokens-used"] = true,
	["cost-used"] = true,
	["tokens-estimate"] = true,
	["cost-estimate"] = true,
	plan = true,
	observed = true,
	stale = true,
	error = true,
}
-- The kinds whose `value` is the fact itself, so without one they can only be text.
detail_view.values = {
	["tokens-used"] = true,
	["cost-used"] = true,
	["tokens-estimate"] = true,
	["cost-estimate"] = true,
	plan = true,
	observed = true,
}

local function details_of(value: any): { Detail }
	local details: { Detail } = {}
	if type(value) == "table" then
		for _, item in ipairs(value) do
			if type(item) == "table" and type(item.text) == "string" and item.text ~= "" then
				local kind = if type(item.kind) == "string" and detail_view.kinds[item.kind] then item.kind else nil
				local value_text = if type(item.valueText) == "string" and item.valueText ~= "" then item.valueText else nil
				if kind ~= nil and detail_view.values[kind] and value_text == nil then
					kind = nil
				end
				table.insert(details, {
					text = item.text,
					account = if type(item.account) == "string" then item.account else nil,
					window = if type(item.window) == "string" then item.window else nil,
					kind = kind,
					value = if kind ~= nil then value_text else nil,
				})
			end
		end
	end
	return details
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
				cache.models[name] = { line = item.line, resets = resets_of(item.resets), provider = if type(item.provider) == "string" then item.provider else nil, details = details_of(item.details) }
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
					details = details_of(item.details),
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
	-- an external source's provider takes the colors of the provider it reports (`keeper:dashboard:openai-codex`)
	id = if id then (string.match(id, "^[^:]+:[^:]+:(.+)$") or id) else nil
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
		for _, detail in group.details or {} do
			table.insert(
				parts,
				"d:"
					.. (detail.account or "")
					.. ":"
					.. (detail.window or "")
					.. ":"
					.. (detail.kind or "")
					.. ":"
					.. (detail.value or "")
					.. ":"
					.. detail.text
			)
		end
	end
	for _, other in others do
		table.insert(parts, other)
	end
	return table.concat(parts, "\n")
end

-- Quantities follow account visibility, but never average unlike units or estimates.
local function visible_details(settings: Settings, id: string?, accounts: { string }, details: { Detail }?): { Detail }
	local visible: { Detail } = {}
	local chosen = if id then chosen_account(settings, id, accounts) else nil
	for _, detail in details or {} do
		if detail.account and id and (account_off(settings, id, detail.account) or (chosen ~= nil and chosen ~= detail.account)) then
			continue
		end
		if detail.window and id then
			local hidden = settings.hidden[id] or {}
			local _, bare = account_of(detail.window, accounts)
			if table.find(hidden, string.lower(bare or detail.window)) or table.find(hidden, string.lower(detail.window)) then
				continue
			end
		end
		table.insert(visible, detail)
	end
	local mode = if id then settings.account[id] else nil
	if #accounts > 1 and #visible > 0 and (mode == COMBINED or mode == COMBINED_PLANS) then
		return { { text = "Quantities: choose one or All accounts" } }
	end
	return visible
end

-- What the line shows. By the mode: every provider in the cache, or the chosen ones; or (with neither) the
-- focused agent's: the line the cache holds for its model chip's name (an empty one: no usage line), so every
-- pane shows the same, newest numbers; else the status. The status's other parts follow either way, and saved resets
-- come from the cache entry the line came from (the status's model is the chip's). Windows hidden in the
-- settings are left out; a mode with providers to show shows them even when that leaves nothing. A provider with
-- several accounts shows them as the settings say (see `account_view`).
local function build_model(settings: Settings, dock: Dock, cache: Cache?): Model
	local label, windows, others = parse_line(if dock.status then usage_part(dock.status) else "")
	local groups: { Group } = {}
	local source = "status"
	local title: string? = nil
	local providers = if cache then cache.providers else nil
	local entry = if cache and dock.chip then cache.models[dock.chip :: string] else nil
	local listed = false
	if settings.mode ~= "current" and providers then
		for _, provider in ordered(providers, settings.order) do
			if settings.mode == "all" or table.find(settings.selected, provider.id) then
				local provider_label, provider_windows = parse_line(provider.line)
				listed = listed or #provider_windows > 0 or #(provider.details or {}) > 0
				provider_windows = shown_windows(settings, provider.id, provider_windows)
				local rest: { Window }? = nil
				provider_windows, rest = account_view(settings, provider.id, provider.accounts, provider_windows)
				local details = visible_details(settings, provider.id, provider.accounts, provider.details)
				if #provider_windows > 0 or #details > 0 then
					table.insert(groups, {
						key = provider.id,
						id = provider.id,
						label = provider_label or provider.label,
						windows = provider_windows,
						resets = provider.resets,
						rest = rest,
						details = details,
					})
				end
			end
		end
		source = settings.mode
	end
	if not listed then
		if entry then
			label, windows = parse_line(entry.line)
			source = "model:" .. (dock.chip :: string)
		else
			source = "status"
		end
		local id = if entry and entry.provider then entry.provider else if label then provider_id(label, cache) else nil
		if label == nil and id and providers then
			for _, provider in providers do
				if provider.id == id then
					label = provider.label
					break
				end
			end
		end
		local accounts = accounts_of(cache, id)
		windows = shown_windows(settings, id, windows)
		local rest: { Window }? = nil
		windows, rest = account_view(settings, id, accounts, windows)
		local details = visible_details(settings, id, accounts, if entry then entry.details else nil)
		if #details > 0 and #windows == 0 and entry then
			local kept: { string } = {}
			for _, other in others do
				if other ~= entry.line then table.insert(kept, other) end
			end
			others = kept
		end
		if #windows > 0 or #details > 0 then
			table.insert(groups, {
				key = id or label or "usage",
				id = id,
				label = label or "",
				windows = windows,
				resets = if entry then entry.resets else nil,
				rest = rest,
				details = details,
			})
			title = (label or "") .. (if label then " usage" else "Usage")
			if dock.viewing and entry then title ..= " · " .. (dock.chip :: string) end
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

-- A dock with nothing read from it (no pane has shown the line since a reload).
local NO_DOCK: Dock = { status = nil, chip = nil, viewing = false, hide = {} }

-- The cache text last decoded: window.luau's `refresh` compares it around a read, to tell a read that decoded a
-- rewritten cache.
local function cache_seen(): string?
	return cache_raw
end

return {
	NAMED = NAMED,
	KV_MODE = KV_MODE,
	KV_SELECTED = KV_SELECTED,
	KV_COLORS = KV_COLORS,
	KV_ORDER = KV_ORDER,
	KV_HIDDEN = KV_HIDDEN,
	KV_ACCOUNT = KV_ACCOUNT,
	KV_ACCOUNT_ORDER = KV_ACCOUNT_ORDER,
	KV_ACCOUNT_HIDDEN = KV_ACCOUNT_HIDDEN,
	KV_CARD_ROWS = KV_CARD_ROWS,
	CARD_ROWS = CARD_ROWS,
	COMBINED = COMBINED,
	COMBINED_PLANS = COMBINED_PLANS,
	now_ms = now_ms,
	read_dock = read_dock,
	countdown_minutes = countdown_minutes,
	clock_at = clock_at,
	span = span,
	reset_text = reset_text,
	tone_of = tone_of,
	is_fable = is_fable,
	read_cache = read_cache,
	offered_providers = offered_providers,
	store = store,
	load_settings = load_settings,
	shown_windows = shown_windows,
	accounts_in_order = accounts_in_order,
	account_of = account_of,
	account_off = account_off,
	chosen_account = chosen_account,
	window_name = window_name,
	account_view = account_view,
	shown_accounts = shown_accounts,
	ordered = ordered,
	moved = moved,
	parse_colors = parse_colors,
	named_palette = named_palette,
	palette_of_spec = palette_of_spec,
	color_key = color_key,
	preset_for = preset_for,
	palette_for = palette_for,
	build_model = build_model,
	shares = shares,
	changes = changes,
	colors_key = colors_key,
	hidden_key = hidden_key,
	NO_DOCK = NO_DOCK,
	cache_seen = cache_seen,
}
