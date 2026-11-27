--!strict
-- What omp Usage draws, before it is drawn: the providers and their colors, the settings in `tern.kv`, the
-- extension's cache, the facts read from an omp pane's composer, and the model of the line built from them.
-- render.luau draws the model; window.luau, the pickers (pickers.luau) and the settings panel (panel.luau) read
-- and change the settings through here.

-- omp's composer bar extras: one `hook-N` fact per `ctx.ui.setStatus` key with `statusLine.showHookStatus`,
-- or one `status` fact (all keys joined) with the `status` statusline segment, beside the status line's own
-- segments (branch, git, …). Ids carry a generated prefix (`k.` in omp 18.6, `3.` in 18.7) or, with omp 19.2
-- on Tern 0.9.36, a `~N` mark on some segments (`dock/composer/0/bar/extras~1/hook-2`), so they are matched by
-- suffix, without the marks, inside the dock region, whose root id is `dock`. Tern renders each fact as a
-- `.sf-seg` whose `data-id` is the fact's full id, which is how the line's facts are hidden in the bar.
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
-- The extension's cache, under the home directory. A file over CACHE_MAX_BYTES isn't read (the line says so).
local CACHE_FILE = "/.omp/cache/usage-remaining.json"
local CACHE_MAX_BYTES = 1048576
-- How old numbers may be: past FRESH_MS since they were observed they show dimmed, with how old they are; past
-- FALLBACK_MS they aren't shown at all (the line falls back to the status). omp's own usage reports are served
-- from a cache of about 5 minutes (up to 7.5), so healthy numbers are often that old: dimming starts past it. A
-- file whose writer has stopped (no heartbeat for FALLBACK_MS) is ignored as a whole.
local FRESH_MS = 10 * 60 * 1000
local FALLBACK_MS = 30 * 60 * 1000
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
-- tips and its comets. Each is a shade per theme, so it reads on light and dark alike. They follow each brand as
-- its own site, logo and style sheets show it (checked 2026-11-17), so brands that share a color look alike here
-- too: Gemini and Antigravity are both Google's #3186ff, and only how their bars end tells them apart.
export type Palette = { name: string, a: string, b: string? }
local PRESETS: { [string]: Palette } = {
	anthropic = { name = "Clay", a = "light-dark(#c6613f, #d97757)" },
	["openai-codex"] = { name = "Ultramarine", a = "light-dark(#3a35ff, #808cff)", b = "light-dark(#6987ff, #576dff)" },
	openai = { name = "Monochrome", a = "light-dark(#000000, #ffffff)" },
	["kimi-code"] = { name = "Kimi blue", a = "light-dark(#1170e8, #1a88ff)" },
	["google-gemini-cli"] = { name = "Aurora", a = "light-dark(#0b57d0, #3186ff)", b = "light-dark(#4c96ff, #e7f1ff)" },
	["google-antigravity"] = { name = "Arch", a = "light-dark(#3279f9, #3186ff)", b = "#00b95c" },
	["minimax-code"] = { name = "Magenta to coral", a = "light-dark(#e21680, #ff276f)", b = "light-dark(#ff643b, #ff7038)" },
	["opencode-go"] = { name = "Go steel", a = "light-dark(#4e81b1, #6c99c6)" },
	["alibaba-token-plan"] = { name = "Qwen blue", a = "light-dark(#082dff, #5c74ff)" },
	devin = { name = "Blue to ink", a = "light-dark(#317cff, #49b0ff)", b = "light-dark(#191919, #fcfcfc)" },
	xai = { name = "Grok mono", a = "light-dark(#52525b, #a1a1aa)", b = "light-dark(#18181b, #fafafa)" },
	["muse-code"] = { name = "Meta blue", a = "light-dark(#0064e0, #0082fb)", b = "light-dark(#0082fb, #9bcbff)" },
	["github-copilot"] = { name = "Lilac to green", a = "light-dark(#8250df, #c898fd)", b = "light-dark(#08872b, #23ea57)" },
	cursor = { name = "Ink to orange", a = "light-dark(#26251e, #edecec)", b = "#f54e00" },
	zai = { name = "Ink to silver", a = "light-dark(#141618, #f4f6f8)", b = "light-dark(#8d8e99, #a0a5b3)" },
	["zai-coding-plan"] = { name = "Ink to silver", a = "light-dark(#141618, #f4f6f8)", b = "light-dark(#8d8e99, #a0a5b3)" },
	["factory-droid"] = { name = "Orange to ink", a = "light-dark(#d15010, #ef6f2e)", b = "light-dark(#020202, #eeeeee)" },
	synthetic = { name = "Indigo to emerald", a = "light-dark(#625fff, #7d87ff)", b = "light-dark(#009767, #00bb7f)" },
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
-- By provider id, the accounts whose plan pill the card and the quota details leave out ("" for a provider with
-- one account). Combining by plan still groups by it.
local KV_PLAN_HIDDEN = "omp-usage.plan-hidden"
-- The card's height limit in rows: one of CARD_ROWS, 26 unless set. Rows are 18px, so 26 rows are a card about
-- 480px tall, which a full-height pane on a 1080p screen holds; the plugin can't see a pane's height, so taller
-- (or split) panes are the user's to set.
local KV_CARD_ROWS = "omp-usage.card-rows"
local CARD_ROWS = { 16, 20, 26, 32, 40, 50 }
local CARD_ROWS_DEFAULT = 26
-- What sits behind the line while it isn't hovered (see render.luau's LINE_CSS): Tern's chats scroll under the
-- composer, so a line over bare transcript text can be hard to read. Glass unless set.
local KV_BACKDROP = "omp-usage.backdrop"
local BACKDROPS: { { id: string, label: string, detail: string } } = {
	{ id = "glass", label = "Glass", detail = "frosted: what scrolls behind it blurs away" },
	{ id = "solid", label = "Solid", detail = "the card's glass, opaque" },
	{ id = "clear", label = "Clear", detail = "nothing: the line over whatever is behind it" },
}
local BACKDROP_DEFAULT = "glass"
-- What a click on the gauge in the widget bar's Plugin segments opens (see window.luau's STATUS). The settings panel
-- unless set.
local KV_USAGE_OPENS = "omp-usage.usage-opens"
local USAGE_OPENS: { { id: string, label: string, detail: string } } = {
	{ id = "panel", label = "Settings panel", detail = "every setting; its bottom bar opens the quota details" },
	{ id = "details", label = "Quota details", detail = "every account and window in full" },
}
local USAGE_OPENS_DEFAULT = "panel"
-- In KV_ACCOUNT, in place of an account's name: show the provider's accounts combined, all in one set of windows
-- (COMBINED), or a set per plan (COMBINED_PLANS: the plan each account reports, else the accounts that report the
-- same windows); each window's share their average (see `combined`).
local COMBINED = "\1combined"
local COMBINED_PLANS = "\1plans"
-- Show pace: which windows say their pace in the card and the quota details (`1.4× pace · empty ~9h`), and so
-- which can raise the widget bar's warning (see `furthest_ahead`). Those running ahead (PACE_AHEAD or more) unless
-- set.
local KV_PACE = "omp-usage.pace"
local PACES: { { id: string, label: string, detail: string } } = {
	{ id = "off", label = "Off", detail = "windows show what is left and when they reset, nothing more" },
	{ id = "ahead", label = "When ahead", detail = "marks a window used up faster than its time runs out; quiet while it keeps pace" },
	{ id = "always", label = "Always", detail = "every window's pace, also one that lasts past its reset" },
}
local PACE_DEFAULT = "ahead"
local PACE_AHEAD = 1.1
-- Show pace as it was kept before it had three choices: on unless false. Read only while KV_PACE is unset.
local KV_SHOW_PACE_BEFORE = "omp-usage.show-pace"
-- Whether low quota and expiring saved resets raise alerts (window.luau): off unless set on.
local KV_ALERTS = "omp-usage.alerts"

-- With several accounts, a window's `account` and its label without it (`bare`: `Fable 7d` for `alice Fable
-- 7d`), and `lead` on the first window of each account, where the line and card name the account. Combined (see
-- `combined`), a group's lead window's `plan` is its heading in the card, in place of its name, and a window only
-- some of the group's accounts have says how many in `covers` (`5 of the 10 accounts`), under it in the card.
-- A detail's `text` is always the readable row (older caches write only that). When the writer also says what
-- the row is (`kind`) and the value it already formatted (`value`), the card can pair a window's observed
-- amounts with its estimates; the text still stands in when a kind is unknown or a value is missing.
-- `whole`: a note about the combined view itself (how many accounts it covers), never labelled as the provider's.
export type Detail = { text: string, account: string?, window: string?, kind: string?, value: string?, whole: boolean? }
-- A window's pace: how fast its quota goes, as the share used over the share of the window gone (1: it lasts
-- exactly to the reset), and, when it goes faster, how long until it runs out at that rate (only when that is
-- before the reset and still ahead: old numbers can project a time already gone).
export type Pace = { ratio: number, empty_in_ms: number? }
-- `under`: below 1% left (the share reads `<1%`). `passed`: its reset time has gone by, so the share shown is
-- the old window's; it reads `reset` (and `pct` is 100). `resets_at`: when it resets (epoch ms; `exact` to the
-- minute or not), from the cache's own time, never from when it was read. `remaining`: the share left as a
-- fraction, unrounded when the cache says it. `pace`: see Pace, while the settings show it.
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
	under: boolean?,
	passed: boolean?,
	resets_at: number?,
	exact: boolean?,
	remaining: number?,
	pace: Pace?,
}
-- A window as the cache (schema 2) states it: provider id, window key (`5h`, `7d`, `monthly`), the label its
-- line uses, the share left (0–1, unrounded), when it resets and how long it runs (ms); `observed_at`: when its
-- entry was observed.
export type CacheWindow = {
	provider: string?,
	key: string,
	label: string,
	account: string?,
	scope: string?,
	remaining: number,
	resets_at: number?,
	window_ms: number?,
	observed_at: number?,
}
export type Reset = { at: number, count: number, window: string? }
-- A provider on the line: its key (provider id when known, else its label), label, windows and saved resets
-- (nil when the cache has none for it); `rest`, while one of its accounts is chosen, the other accounts' windows.
-- `as_of`: while its numbers are older than FRESH_MS, how old (`as of 25m ago`, and `age` in ms); the line draws
-- it faint.
export type Group = { key: string, id: string?, label: string, windows: { Window }, resets: { Reset }?, rest: { Window }?, details: { Detail }?, as_of: string?, age: number? }
-- What the line and card show, where it came from (a change counts only between two lines from the same
-- source), and the card's title.
export type Model = {
	groups: { Group },
	others: { string },
	source: string,
	title: string,
	signature: string,
}
-- `hide`: the ids of the status facts the line redraws, to hide in the bar; `texts`: every status fact's text, by
-- id; `remote`: the pane is on another machine (its omp writes no cache here); `seen`: its surface could be read.
export type Dock = {
	status: string?,
	chip: string?,
	viewing: boolean,
	hide: { string },
	texts: { [string]: string },
	remote: boolean,
	seen: boolean,
}
-- `windows`: every window the provider's accounts report, its plan's and those only some of its models have.
-- `accounts`: with several, their names in omp's order (as the line's labels start); else empty.
-- `observed_at`: when its numbers were observed (the entry's own time, else the cache's last fetch, else the
-- file's heartbeat); `exact`: its windows as the cache states them (schema 2; empty before).
export type Provider = {
	id: string,
	label: string,
	line: string,
	resets: { Reset },
	windows: { Window },
	accounts: { string },
	details: { Detail }?,
	observed_at: number?,
	exact: { CacheWindow }?,
}
export type Entry = { line: string, resets: { Reset }, provider: string?, details: { Detail }?, observed_at: number?, exact: { CacheWindow }? }
-- `at`: the writer's heartbeat (generatedAt); `fetched_at`: its last successful fetch, when it says.
export type Cache = { at: number, fetched_at: number?, models: { [string]: Entry }, providers: { Provider }? }
export type Settings = {
	mode: string,
	selected: { string },
	colors: { [string]: string },
	order: { string },
	hidden: { [string]: { string } },
	account: { [string]: string },
	account_order: { [string]: { string } },
	account_hidden: { [string]: { string } },
	plan_hidden: { [string]: { string } },
	card_rows: number,
	backdrop: string,
	usage_opens: string,
	pace: string,
	alerts: boolean,
}

-- The cache file as last read (decoded or not: each text is decoded once), the last parse that decoded, the
-- last providers it listed (see `read_cache`), and what is wrong with the file, when something is: the line
-- shows it.
local cache_raw: string? = nil
local cache_parsed: Cache? = nil
local providers_seen: { at: number, list: { Provider } }? = nil
local cache_problem: string? = nil

local function now_ms(): number
	return os.time() * 1000
end

-- A node id without the `~N` segment marks omp 19.2 ids carry (`…/bar/extras~1/hook-2` reads `…/bar/extras/hook-2`).
local function plain_id(id: string): string
	return (string.gsub(id, "~%d+", ""))
end

local function is_status_fact(id: any): boolean
	if type(id) ~= "string" then
		return false
	end
	local plain = plain_id(id)
	for _, pattern in FACT_PATTERNS do
		if string.find(plain, pattern) then
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
		return type(node.id) == "string" and string.sub(plain_id(node.id), -#suffix) == suffix
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
	local dock: Dock = { status = nil, chip = nil, viewing = false, hide = {}, texts = {}, remote = false, seen = false }
	if type(tree) ~= "table" then
		return dock
	end
	dock.seen = true
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
					dock.texts[child.id] = text
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

-- Whether `pane` runs somewhere whose omp writes no cache here: on a remote host (a machine Tern reaches over SSH),
-- or, on Windows, in WSL (a Linux working directory, or one under `\\wsl$` / `\\wsl.localhost`).
local WINDOWS = tern.getenv("OS") == "Windows_NT"
local function on_remote(cx: WindowCx, pane: number): boolean
	local ok, hosts = pcall(function(): any
		return cx.hosts:list()
	end)
	if ok and type(hosts) == "table" then
		for _, host in hosts do
			if host.kind == "remote" and type(host.panes) == "table" and table.find(host.panes, pane) then
				return true
			end
		end
	end
	if WINDOWS then
		local found, info = pcall(function(): any
			return cx.session:pane(pane)
		end)
		local cwd = if found and type(info) == "table" and type(info.cwd) == "string" then string.lower(info.cwd) else ""
		return string.sub(cwd, 1, 1) == "/" or string.sub(cwd, 1, 5) == "\\\\wsl"
	end
	return false
end

local function read_dock(cx: WindowCx, pane: number): Dock
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { root = DOCK_ROOT })
	end)
	local dock = dock_facts(if ok then tree else nil)
	dock.remote = on_remote(cx, pane)
	return dock
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

-- A reset time to the nearest minute: omp states some resets from a countdown at fetch time, a few hundred ms either
-- side of the minute (…27999873, …28000246), and the same reset must read the same everywhere (`5:00 AM`, not
-- `4:59 AM` beside `5:00 AM`).
local function to_minute(at: number): number
	return math.floor(at / 60000 + 0.5) * 60000
end

-- The local time at `at` (epoch ms), to the nearest minute: `1:12 AM`, `Mon 1:12 AM` past today, `~Mon 3 AM` when
-- only the hour is known (not `exact`).
local function clock_of(at: number, exact: boolean): string?
	local ok_now, today = pcall(os.date :: any, "*t", os.time())
	local ok_at, t = pcall(os.date :: any, "*t", to_minute(at) // 1000)
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

-- The countdown from `now` to a reset at `at` (epoch ms), taken to the nearest minute first (see `to_minute`), so
-- one reset stated a little apart counts down the same: `2h 11m`.
local function span_to(at: number, now: number): string
	return span(to_minute(at) - now)
end

-- A rough length for a projection: `40m`, `9h`, `1d 23h`, `3d` (to the hour past a day, as the reset countdowns go).
local function rough(ms: number): string
	local minutes = math.max(1, math.floor(ms / 60000 + 0.5))
	if minutes < 60 then
		return string.format("%dm", minutes)
	end
	local hours = math.floor(minutes / 60 + 0.5)
	if hours < 24 then
		return string.format("%dh", hours)
	end
	local days, rest = math.floor(hours / 24), hours % 24
	return if rest > 0 then string.format("%dd %dh", days, rest) else string.format("%dd", days)
end

-- How old something seen `ms` ago is, for a note: `as of 25m ago`.
local function as_of(ms: number): string
	return "as of " .. span(ms) .. " ago"
end

-- A window's pace from the cache (see Pace): nil without a length and a reset time, once the reset has passed,
-- or while less than a tenth of the window has gone (too early to tell). Worked out at the time the numbers were
-- observed, so an older reading doesn't skew it; `empty_in_ms` counts from `now`.
local function pace(window: CacheWindow, now: number): Pace?
	local length, at = window.window_ms, window.resets_at
	if length == nil or at == nil or length <= 0 or length == math.huge then
		return nil
	end
	local seen = window.observed_at or now
	local left_ms = at - seen
	if left_ms <= 0 or at <= now then
		return nil
	end
	local gone = length - left_ms
	if gone < length * 0.1 then
		return nil
	end
	local remaining = math.clamp(window.remaining, 0, 1)
	local used = 1 - remaining
	local result: Pace = { ratio = used / (gone / length) }
	if used > 0 then
		local empty_at = seen + remaining * gone / used
		-- a projection that ran out before now (old numbers) promises nothing: the ratio stays, the time goes
		if empty_at < at and empty_at > now then
			result.empty_in_ms = empty_at - now
		end
	end
	return result
end

-- A pace as its row in the card says it, and whether it runs ahead (PACE_AHEAD or more: the row warns):
-- `1.4× pace · empty ~9h` when at that rate it runs out before the reset, `1.4× pace` alone when it would have run
-- out by now, `0.4× pace · lasts past reset` when it wouldn't run out at all; nil when unknown or already empty.
local function pace_text(p: Pace?, remaining: number?): (string?, boolean)
	if p == nil or (remaining ~= nil and remaining <= 0) then
		return nil, false
	end
	local text = string.format("%.1f× pace", p.ratio)
	if p.empty_in_ms then
		text ..= " · empty ~" .. rough(p.empty_in_ms :: number)
	elseif p.ratio <= 1 then
		text ..= " · lasts past reset"
	end
	return text, p.ratio >= PACE_AHEAD
end

-- A share left (0–1) as usage-remaining.js's `pctText` writes it, so the widget and the alerts read what the line
-- reads: whole percents rounded down (the epsilon keeps 1 - 0.71 at 29%), `<1%` below one percent.
local function share_text(remaining: number): string
	if remaining <= 0 then
		return "0%"
	elseif remaining < 0.01 then
		return "<1%"
	end
	return string.format("%d%%", math.floor(remaining * 100 + 1e-9))
end

-- A `<1%` share without the cache's own number stands in as half a percent: it reads `<1%` and isn't used up.
local UNDER_SHARE = 0.005

-- A window's share left (0–1): the cache's, else its percent (`<1%`: UNDER_SHARE).
local function left_of(window: Window): number
	return window.remaining or (if window.under then UNDER_SHARE else window.pct / 100)
end

-- A window's share as the line writes it: `64%`, `<1%`; `reset` once its reset has passed.
local function pct_text(window: Window): string
	if window.passed then
		return "reset"
	end
	return (if window.under then "<1" else tostring(window.pct)) .. "%"
end

-- A saved reset's card row: `saved reset · in 10d 18h · Oct 22` (`2 saved resets · …` for a credit of two; the
-- year after the date when it isn't this year's), short so the card stays narrow; nil once it has expired.
local function reset_text(reset: Reset, now: number, fable: boolean): string?
	if reset.at <= now then
		return nil
	end
	local ok, t = pcall(os.date :: any, "*t", to_minute(reset.at) // 1000)
	local ok_now, today = pcall(os.date :: any, "*t", math.floor(now / 1000))
	if not ok or type(t) ~= "table" or not ok_now or type(today) ~= "table" then
		return nil
	end
	local date = string.format("%s %d", MONTHS[(t :: any).month], (t :: any).day)
	if (t :: any).year ~= (today :: any).year then
		date ..= " " .. tostring((t :: any).year)
	end
	local kind = if fable then "Fable reset" else "saved reset"
	local what = if reset.count > 1 then string.format("%d %ss", reset.count, kind) else kind
	return string.format("%s · in %s · %s", what, span_to(reset.at, now), date)
end

-- One usage-remaining.js window, `[Provider ][Scope ]<span> <meter> <N>% left[ (<reset>)][ (+N) | (!N - <left> left)]`
-- (`<1% left` below one percent), or `[Provider ][Scope ]<span> reset[ (+N)…]` once its reset time has passed, and
-- the provider in front of it, if any. A window metered for one tier or model of the plan carries its scope
-- (`Fable 7d`), which stays in its label so it is told apart from the general window of the same span. The
-- provider's one-word label leads only a line's `first` window.
local function parse_window(piece: string, first: boolean): (Window?, string?)
	local head, span, under, pct, rest = string.match(piece, "^(.-)(%S+) %S+ (<?)(%d+)%% left(.*)$")
	local passed = false
	if span == nil then
		-- a reset window: its span must look like one (`5h`, `7d`, `mo`), so other statuses ending `reset` stay text
		head, span, rest = string.match(piece, "^(.-)(%S+) reset(.*)$")
		if span == nil or not (string.match(span :: string, "^%d+%a+$") or span == "mo") then
			return nil, nil
		end
		if rest ~= "" and string.sub(rest :: string, 1, 2) ~= " (" then
			return nil, nil
		end
		passed, under, pct = true, "", "100"
	end
	local provider: string? = nil
	local scope = string.match(head :: string, "^%s*(.-)%s*$") :: string
	if first then
		local word, after = string.match(scope, "^(%S*)%s*(.*)$")
		provider, scope = word, after :: string
	end
	local label = if scope ~= "" then scope .. " " .. (span :: string) else span :: string
	local window: Window = { label = label, pct = tonumber(pct) :: number }
	if passed then
		window.passed = true
	elseif under == "<" then
		window.pct, window.under = 0, true
	end
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
local detail_kinds: { [string]: boolean } = {
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
local detail_values: { [string]: boolean } = {
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
				local kind = if type(item.kind) == "string" and detail_kinds[item.kind] then item.kind else nil
				local value_text = if type(item.valueText) == "string" and item.valueText ~= "" then item.valueText else nil
				if kind ~= nil and detail_values[kind] and value_text == nil then
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

local function number_or_nil(value: any): number?
	return if type(value) == "number" and value == value then value else nil
end

-- An entry's windows as the cache states them (schema 2), each knowing when it was observed.
local function exact_of(value: any, provider: string?, observed_at: number?): { CacheWindow }
	local list: { CacheWindow } = {}
	if type(value) ~= "table" then
		return list
	end
	for _, item in ipairs(value) do
		if type(item) == "table" and type(item.label) == "string" and type(item.remaining) == "number" then
			table.insert(list, {
				provider = if type(item.provider) == "string" then item.provider else provider,
				key = if type(item.key) == "string" then item.key else item.label,
				label = item.label,
				account = if type(item.account) == "string" then item.account else nil,
				scope = if type(item.scope) == "string" then item.scope else nil,
				remaining = item.remaining,
				resets_at = number_or_nil(item.resetsAt),
				window_ms = number_or_nil(item.windowMs),
				observed_at = observed_at,
			})
		end
	end
	return list
end

-- A model entry made whole: the entry itself when it has its `line`; else (a compact one, see usage-remaining.js
-- compactEntry) with what it leaves out taken from `base`, its provider's entry: `windows`, `resets` and
-- `details` list base's items by index (from 0) beside their own, all of base's when left out; the line is `text`,
-- else base's line (with base's windows), else base's label and its windows' texts. nil when it doesn't resolve.
local function whole_entry(item: any, base: any): any
	if type(item) ~= "table" or type(item.line) == "string" then
		return item
	end
	if type(base) ~= "table" or type(base.line) ~= "string" then
		return nil
	end
	local ok = true
	local function pick(own: any, from: any): { any }
		local list = if type(from) == "table" then from else {}
		if own == nil then
			return list
		end
		local out = {}
		if type(own) ~= "table" then
			ok = false
			return out
		end
		for _, x in ipairs(own) do
			local found = if type(x) == "number" then list[x + 1] else x
			if type(found) ~= "table" then
				ok = false
			else
				table.insert(out, found)
			end
		end
		return out
	end
	local windows = pick(item.windows, base.windows)
	local line: string? = if type(item.text) == "string" then item.text elseif item.windows == nil then base.line else nil
	if line == nil then
		local texts: { string } = {}
		for _, window in windows do
			if type(window.text) ~= "string" then
				return nil
			end
			table.insert(texts, window.text)
		end
		line = if #texts == 0 then "" elseif type(base.label) == "string" then base.label .. " " .. table.concat(texts, " · ") else nil
	end
	local whole = {
		line = line,
		resets = pick(item.resets, base.resets),
		provider = item.provider,
		details = pick(item.details, base.details),
		windows = windows,
		observedAt = item.observedAt,
	}
	return if ok and line ~= nil then whole else nil
end

-- The cache as decoded JSON: model entries by chip name (`null` ones, two models sharing a chip name, are
-- dropped by the decoder, which reads the same as missing; a writer that tells them apart also keys each by
-- `<provider>/<chip name>`), each whole or compact against its provider's entry (see `whole_entry`; one that
-- doesn't resolve reads as missing too), and the providers in the preset order (decoding loses the file's).
-- `providers` is nil when the file has none, as written before it listed them. Each entry knows when it was
-- observed: its own `observedAt`, else the file's last fetch (`fetchedAt`), else its heartbeat (`generatedAt`, all
-- a first-version file has).
local function parse_cache(doc: any): Cache?
	if type(doc) ~= "table" or type(doc.generatedAt) ~= "number" then
		return nil
	end
	local fetched = number_or_nil(doc.fetchedAt)
	local cache: Cache = { at = doc.generatedAt, fetched_at = if fetched and fetched > 0 then fetched else nil, models = {}, providers = nil }
	local base = cache.fetched_at or cache.at
	if type(doc.models) == "table" then
		local bases = if type(doc.providers) == "table" then doc.providers else {}
		for name, raw in pairs(doc.models) do
			local item = whole_entry(raw, if type(raw) == "table" and type(raw.provider) == "string" then bases[raw.provider] else nil)
			if type(name) == "string" and type(item) == "table" and type(item.line) == "string" then
				local provider = if type(item.provider) == "string" then item.provider else nil
				local observed = number_or_nil(item.observedAt) or base
				cache.models[name] = {
					line = item.line,
					resets = resets_of(item.resets),
					provider = provider,
					details = details_of(item.details),
					observed_at = observed,
					exact = exact_of(item.windows, provider, observed),
				}
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
				local observed = number_or_nil(item.observedAt) or base
				table.insert(list, {
					id = id,
					label = label,
					line = item.line,
					resets = resets_of(item.resets),
					windows = windows,
					accounts = if #accounts > 1 then accounts else {},
					details = details_of(item.details),
					observed_at = observed,
					exact = exact_of(item.windows, id, observed),
				})
			end
		end
		-- after the plan's windows, those only some models have (Codex Spark's), from those models' lines: a model
		-- goes with its provider by id (by label for a writer that didn't name it)
		local names: { string } = {}
		for name in cache.models do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local entry = cache.models[name]
			local label, windows = parse_line(entry.line)
			for _, provider in list do
				if (entry.provider and entry.provider == provider.id) or (entry.provider == nil and provider.label == label) then
					for _, window in windows do
						if not has_window(provider.windows, window.label) then
							table.insert(provider.windows, window)
						end
					end
					local exact = provider.exact :: { CacheWindow }
					for _, window in (entry.exact or {}) :: { CacheWindow } do
						local known = false
						for _, other in exact do
							known = known or string.lower(other.label) == string.lower(window.label)
						end
						if not known then
							table.insert(exact, window)
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

-- How long ago `x` (a cache, or one of its entries or providers) was observed; nil when it doesn't say.
local function age_ms(x: any, now: number): number?
	if type(x) ~= "table" then
		return nil
	end
	local at = x.observed_at or x.fetched_at or x.at
	return if type(at) == "number" then math.max(0, now - at) else nil
end

-- Whether `x`'s numbers are fresh, to be shown dimmed with their age, or too old to show (see FRESH_MS).
local function freshness(x: any, now: number): string
	local age = age_ms(x, now)
	if age == nil or age > FALLBACK_MS then
		return "fallback"
	end
	return if age > FRESH_MS then "dim" else "fresh"
end

-- The cache to use now: nil when missing, never decoded, or its writer has stopped (no heartbeat for
-- FALLBACK_MS). A read that doesn't decode (a half-replaced file) keeps the last good one, and a file without
-- providers (an omp session still running an extension from before they were listed) borrows the last ones seen,
-- while they are recent. How old each entry's numbers are is the model's to judge (see `build_model`).
local function usable_cache(parsed: Cache?, seen: { at: number, list: { Provider } }?, now: number): Cache?
	if parsed == nil or now - parsed.at > FALLBACK_MS then
		return nil
	end
	if parsed.providers == nil and seen and now - seen.at <= FALLBACK_MS then
		return { at = parsed.at, fetched_at = parsed.fetched_at, models = parsed.models, providers = seen.list }
	end
	return parsed
end

-- The cache file's text as last read (nil until it has been). `tern.fs.read` would read it on the window's thread,
-- and opening the file just after omp rewrites it can wait on another program (a virus scan) for longer than a
-- timer's 50 ms budget, which, tripped, turns off every timer of the plugin until a reload; so it is read with
-- `cx.docs:read`, whose answer comes back later, every few seconds while something shows it (an omp pane, the
-- settings panel, the quota details: see `set_watching`), else every IDLE_POLL_MS.
local CACHE_POLL_MS = 3000
local IDLE_POLL_MS = 15000
local cache_text: string? = nil
-- The size of a file too big to read, while it is (see `cache_problem`).
local oversize: number? = nil
local watching: ((WindowCx) -> boolean)? = nil
local last_read: number? = nil

-- Tells the poll whether anything shows the cache's numbers now (window.luau's test).
local function set_watching(test: (WindowCx) -> boolean)
	watching = test
end

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
	local now = tern.now()
	if watching and last_read and now - (last_read :: number) < IDLE_POLL_MS then
		local ok, on = pcall(watching :: (WindowCx) -> boolean, cx :: WindowCx)
		if ok and not on then
			return
		end
	end
	last_read = now
	local ok, reading = pcall(function(): any
		return (cx :: WindowCx).docs:read(path :: string)
	end)
	if ok and reading then
		-- a failed read (the file being replaced, or gone) keeps the last text: it goes stale on its own. A file
		-- too big to read keeps it too, and says so.
		reading:next(function(text: string?, _err: string?, _later: WindowCx?)
			if type(text) ~= "string" then
				return
			end
			if #text > CACHE_MAX_BYTES then
				if oversize ~= #text then
					tern.log.warn("omp-usage: usage cache is " .. tostring(#text) .. " bytes, over the " .. tostring(CACHE_MAX_BYTES) .. " the plugin reads")
				end
				oversize = #text
			else
				oversize = nil
				cache_text = text
			end
		end)
	end
end

tern.timer(0, poll_cache)

-- Decodes the cache text once per text (a text that doesn't decode isn't tried again), and returns the last good
-- parse while it is usable (see `usable_cache`).
local function read_cache(now: number): Cache?
	local raw = cache_text
	if raw ~= nil and raw ~= cache_raw then
		cache_raw = raw
		local decoded, doc = pcall(tern.json.decode, raw)
		local parsed = if decoded then parse_cache(doc) else nil
		if parsed then
			cache_parsed = parsed
			cache_problem = nil
			if parsed.providers then
				providers_seen = { at = parsed.at, list = parsed.providers :: { Provider } }
			end
		else
			cache_problem = "usage cache unreadable"
		end
	end
	return usable_cache(cache_parsed, providers_seen, now)
end

-- What is wrong with the cache file, for the line to say: too big to read, or unreadable; nil when nothing is.
local function cache_trouble(): string?
	if oversize then
		return string.format("usage cache too big to read (%.1f MB)", (oversize :: number) / 1048576)
	end
	return cache_problem
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

-- What the settings read and write: `tern.kv`, and the providers to offer, in one place.
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

-- The USAGE_OPENS id set, else the default. Read on its own by every poll (window.luau), panel or not.
local function usage_opens(): string
	local opens = store.get(KV_USAGE_OPENS)
	for _, choice in USAGE_OPENS do
		if opens == choice.id then
			return choice.id
		end
	end
	return USAGE_OPENS_DEFAULT
end

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
		plan_hidden = {},
		card_rows = CARD_ROWS_DEFAULT,
		backdrop = BACKDROP_DEFAULT,
		usage_opens = usage_opens(),
		pace = PACE_DEFAULT,
		alerts = store.get(KV_ALERTS) == true,
	}
	local mode = store.get(KV_MODE)
	if mode == "all" or mode == "selected" then
		settings.mode = mode
	end
	local rows = store.get(KV_CARD_ROWS)
	if type(rows) == "number" and table.find(CARD_ROWS, rows) then
		settings.card_rows = rows
	end
	local backdrop = store.get(KV_BACKDROP)
	for _, choice in BACKDROPS do
		if backdrop == choice.id then
			settings.backdrop = choice.id
		end
	end
	local shown_pace = store.get(KV_PACE)
	if shown_pace == nil and store.get(KV_SHOW_PACE_BEFORE) == false then
		shown_pace = "off"
	end
	for _, choice in PACES do
		if shown_pace == choice.id then
			settings.pace = choice.id
		end
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
	local plan_hidden = store.get(KV_PLAN_HIDDEN)
	if type(plan_hidden) == "table" then
		for id, names in pairs(plan_hidden) do
			local list = id_list(names)
			if type(id) == "string" and #list > 0 then
				settings.plan_hidden[id] = list
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

-- Whether the plan of provider `id`'s account `name` ("" with one account) is left out of the card and details.
local function plan_off(settings: Settings, id: string, name: string): boolean
	local off = settings.plan_hidden[id]
	return off ~= nil and table.find(off, name) ~= nil
end

-- The plan `details` name for an account (`account` nil: the provider's single account), if they name one.
local function plan_in(details: { Detail }?, account: string?): string?
	for _, detail in (details or {}) :: { Detail } do
		if detail.kind == "plan" and detail.value and detail.window == nil and detail.account == account then
			return detail.value
		end
	end
	return nil
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
-- plan`, by plan: the plan each account is on (`reported`, by account name) when the provider names one for all of
-- them, else the accounts that report the same windows together (most likely one plan). Each group gets one run of
-- windows (every window any of its accounts has, in the order of the account with the most, then any it lacks),
-- named for how many accounts it holds (`6 accounts`, `2 Max 20x accounts`; a group of one keeps the account's
-- name). A window's share is the average of the group's accounts that have it (`<1%` below one percent; `covers`
-- says how many when not all do), its reset the soonest of theirs, its saved resets all of theirs. `loose` (windows
-- without an account) go first. Grouped by windows, when one window sets the groups apart, the groups without it
-- say so in their name (`4 accounts, no 5H`), and each group's lead window carries `plan`, its heading in the card
-- (`6 accounts with a 5-hour window`); with more than one, the heading lists the group's windows (`4 accounts ·
-- 7D · FABLE 7D`). Also, for the panel: the chip's text and each account's group tag.
local function combined(
	on: { { Window } },
	loose: { Window },
	by_plan: boolean,
	reported: { [string]: string }
): ({ Window }, { chip: string, tags: { [string]: string } })
	local named = by_plan and #on > 0
	for _, list in on do
		named = named and reported[list[1].account :: string] ~= nil
	end
	local plans: { { key: string, lists: { { Window } } } } = {}
	for _, list in on do
		local labels: { string } = {}
		for _, window in list do
			table.insert(labels, string.lower(window.bare or window.label))
		end
		table.sort(labels)
		local key = if named then reported[list[1].account :: string] elseif by_plan then table.concat(labels, "|") else ""
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
	if named then
		-- by the plans the provider reports: `2 Pro accounts`, a lone account `dev-bot (Plus)`
		local split: { string } = {}
		for p, plan in plans do
			local n = #plan.lists
			names[p] = if n == 1 then string.format("%s (%s)", names[p], plan.key) else string.format("%d %s accounts", n, plan.key)
			heads[p] = names[p]
			table.insert(split, string.format("%d %s", n, plan.key))
			for _, list in plan.lists do
				info.tags[list[1].account :: string] = plan.key
			end
		end
		info.chip = if #plans == 1
			then string.format("by plan · all %d %s", accounts, plans[1].key)
			else "by plan · " .. table.concat(split, ", ")
	elseif #plans == 1 then
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
		-- every window the group's accounts have: in the order of the account with the most (`5H`, `7D`, …), then
		-- any it lacks, in the order they first come
		local fullest = plan.lists[1]
		for _, list in plan.lists do
			if #list > #fullest then
				fullest = list
			end
		end
		local order: { Window } = {}
		local seen: { [string]: boolean } = {}
		for _, list in { fullest, table.unpack(plan.lists) } do
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
			local total, share, count, saved, passed = 0, 0, 0, 0, 0
			local reset, expires = window.reset, window.expires
			local resets_at: number?, exact: boolean? = nil, nil
			for _, list in plan.lists do
				for _, other in list do
					if string.lower(other.bare or other.label) == bare then
						total += other.pct
						share += left_of(other)
						count += 1
						saved += other.saved or 0
						if other.passed then
							passed += 1
						end
						if minutes(other.reset) < minutes(reset) then
							reset = other.reset
						end
						if other.resets_at and not other.passed and (resets_at == nil or (other.resets_at :: number) < (resets_at :: number)) then
							resets_at, exact = other.resets_at, other.exact
						end
						if other.expires and minutes(other.expires) < minutes(expires) then
							expires = other.expires
						end
					end
				end
			end
			-- under 1% on average (every account `<1%`, say) reads `<1%`, not a rounded `0%`
			local under = share / count > 0 and share / count < 0.01
			table.insert(out, {
				label = name .. " " .. (window.bare or window.label),
				pct = if under then 0 else math.floor(total / count + 0.5),
				under = if under then true else nil,
				reset = if passed == count then nil else reset,
				saved = if saved > 0 then saved else nil,
				expires = if saved > 0 then expires else nil,
				account = name,
				bare = window.bare or window.label,
				lead = if w == 1 then true else nil,
				plan = if w == 1 and heads[p] ~= name then heads[p] else nil,
				covers = if count < #plan.lists then string.format("%d of the %d accounts", count, #plan.lists) else nil,
				passed = if passed == count then true else nil,
				resets_at = resets_at,
				exact = exact,
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
-- tags come back third (see `combined`; `details`: the provider's, for the plan each account reports).
local function account_view(
	settings: Settings,
	id: string?,
	accounts: { string },
	windows: { Window },
	details: { Detail }?
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
		local reported: { [string]: string } = {}
		for _, detail in (details or {}) :: { Detail } do
			if detail.kind == "plan" and detail.value and detail.account and detail.window == nil then
				reported[detail.account :: string] = detail.value
			end
		end
		local together, info = combined(on, loose, mode == COMBINED_PLANS, reported)
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

-- A custom color as the theme shows it: the presets are light/dark pairs, a typed hex is one color for both, so
-- one that is nearly white would vanish on the light theme's card and one nearly black on the dark one. Those get
-- a counterpart for that theme, the same hue taken dark (a light color in the light theme) or light (a dark color
-- in the dark theme); anything in between reads on both as it is.
local function themed(hex: string): string
	local channels: { number } = {}
	for i = 0, 2 do
		table.insert(channels, (tonumber(string.sub(hex, 2 + i * 2, 3 + i * 2), 16) :: number) / 255)
	end
	local function linear(c: number): number
		return if c <= 0.04045 then c / 12.92 else ((c + 0.055) / 1.055) ^ 2.4
	end
	local luminance = 0.2126 * linear(channels[1]) + 0.7152 * linear(channels[2]) + 0.0722 * linear(channels[3])
	local function mixed(toward: number, amount: number): string
		local out = "#"
		for _, c in channels do
			out ..= string.format("%02x", math.floor((c + (toward - c) * amount) * 255 + 0.5))
		end
		return out
	end
	if luminance > 0.6 then
		return string.format("light-dark(%s, %s)", mixed(0, 0.7), hex)
	elseif luminance < 0.03 then
		return string.format("light-dark(%s, %s)", hex, mixed(1, 0.75))
	end
	return hex
end

-- A stored color choice as a palette; nil when it isn't one (then the preset applies).
local function palette_of_spec(spec: string): Palette?
	local key = string.match(spec, "^named:(.+)$")
	if key then
		return named_palette(key)
	end
	local colors = parse_colors(spec)
	if colors then
		return { name = table.concat(colors, ", "), a = themed(colors[1]), b = if colors[2] then themed(colors[2]) else nil }
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

-- Everything about a window that the line, the card or the details draw.
local function window_signature(window: Window): string
	local pace_row, ahead = pace_text(window.pace, window.remaining)
	local s = string.format(
		"%s:%s:%s:%s:%s:%s:%s:%s:%s%s",
		window.label,
		pct_text(window),
		window.reset or "",
		tostring(window.saved or ""),
		window.expires or "",
		window.covers or "",
		window.plan or "",
		tostring(window.resets_at or ""),
		pace_row or "",
		if ahead then "!" else ""
	)
	if window.account then
		s ..= "@" .. (window.account :: string) .. (if window.lead then "^" else "")
	end
	return s
end

local function signature_of(groups: { Group }, others: { string }, title: string): string
	local parts: { string } = { title }
	for _, group in groups do
		table.insert(parts, group.key .. "=" .. group.label .. ":" .. (group.as_of or ""))
		for _, window in group.windows do
			table.insert(parts, window_signature(window))
		end
		for _, window in (group.rest or {}) :: { Window } do
			table.insert(parts, "~" .. window_signature(window))
		end
		for _, reset in (group.resets or {}) :: { Reset } do
			table.insert(parts, string.format("r%d*%d:%s", reset.at, reset.count, reset.window or ""))
		end
		for _, detail in (group.details or {}) :: { Detail } do
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

-- Whether `details` hold anything to show on their own: a plan only labels its account's windows.
local function has_facts(details: { Detail }?): boolean
	for _, detail in (details or {}) :: { Detail } do
		if detail.kind ~= "plan" then
			return true
		end
	end
	return false
end

-- Quantities follow account visibility, but never average unlike units or estimates.
local function visible_details(settings: Settings, id: string?, accounts: { string }, details: { Detail }?): { Detail }
	local visible: { Detail } = {}
	local chosen = if id then chosen_account(settings, id, accounts) else nil
	for _, detail in (details or {}) :: { Detail } do
		if detail.kind == "plan" and id and plan_off(settings, id, detail.account or "") then
			continue
		end
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
	if #accounts > 1 and (mode == COMBINED or mode == COMBINED_PLANS) then
		-- combined, the plans name the groups instead (see `combined`); what an account's source says about its
		-- own state (stale, failed) still shows, under that account's name
		local kept: { Detail } = {}
		local quantities = false
		for _, detail in visible do
			if detail.kind == "stale" or detail.kind == "error" then
				table.insert(kept, detail)
			elseif detail.kind ~= "plan" then
				quantities = true
			end
		end
		if quantities then
			table.insert(kept, { text = "Quantities: choose one or All accounts" })
		end
		return kept
	end
	return visible
end

-- Combined (see `combined`), when some accounts switched on have no windows (their source is stale, failed or
-- reports none): a note naming how many accounts the windows stand for, and the ones left out.
local function combined_note(settings: Settings, id: string?, accounts: { string }, windows: { Window }): Detail?
	local mode = if id then settings.account[id :: string] else nil
	if id == nil or #accounts < 2 or (mode ~= COMBINED and mode ~= COMBINED_PLANS) or chosen_account(settings, id :: string, accounts) then
		return nil
	end
	local with: { [string]: boolean } = {}
	for _, window in windows do
		local name = account_of(window.label, accounts)
		if name then
			with[name] = true
		end
	end
	local on, missing = 0, {}
	for _, name in accounts_in_order(accounts, settings.account_order[id :: string]) do
		if not account_off(settings, id :: string, name) then
			on += 1
			if not with[name] then
				table.insert(missing, name)
			end
		end
	end
	if #missing == 0 or on < 2 then
		return nil
	end
	return {
		text = string.format("%d of %d accounts · no current numbers for %s", on - #missing, on, table.concat(missing, ", ")),
		kind = "stale",
		whole = true,
	}
end

-- `windows`, parsed from a line written at `base` (epoch ms), with what the cache states about each (`exact`, its
-- windows by label: share, reset time, length) and the time now: when each resets (the cache's time, else its
-- countdown from `base`), its countdown again from now, its pace when Show pace (`shown`, a PACES id) shows it, and
-- whether its reset has passed (then it reads `reset`). Changes the windows in place, and returns them.
local function timed(windows: { Window }, exact: { CacheWindow }?, base: number, now: number, shown: string): { Window }
	for _, window in windows do
		local key = string.lower(window.label)
		local stated: CacheWindow? = nil
		for _, item in (exact or {}) :: { CacheWindow } do
			if string.lower(item.label) == key then
				stated = item
				break
			end
		end
		if stated then
			window.remaining = stated.remaining
			window.resets_at = stated.resets_at
			window.exact = if stated.resets_at then true else nil
			if shown ~= "off" and not window.passed then
				local found = pace(stated, now)
				window.pace = if found and (shown == "always" or found.ratio >= PACE_AHEAD) then found else nil
			end
		elseif window.reset == "soon" then
			window.resets_at, window.exact = base, true
		elseif window.reset then
			local minutes, exact_minutes = countdown_minutes(window.reset :: string)
			if minutes then
				window.resets_at = base + minutes * 60000 + (if exact_minutes then 0 else 1800000)
				window.exact = exact_minutes
			end
		end
		if window.passed or (window.resets_at and (window.resets_at :: number) <= now) then
			window.passed, window.pct, window.under, window.reset, window.remaining, window.pace = true, 100, nil, nil, nil, nil
		elseif window.resets_at and window.exact then
			window.reset = span_to(window.resets_at :: number, now)
		end
		if window.remaining == nil and not window.passed then
			window.remaining = left_of(window)
		end
	end
	return windows
end

-- What the line shows. By the mode: every provider in the cache, or the chosen ones; or (with neither) the
-- focused agent's: the line the cache holds for its model chip's name (an empty one: no usage line), so every
-- pane shows the same, newest numbers; else the status. The status's other parts follow either way, and saved resets
-- come from the cache entry the line came from (the status's model is the chip's). Windows hidden in the
-- settings are left out; a mode with providers to show shows them even when that leaves nothing. A provider with
-- several accounts shows them as the settings say (see `account_view`). Numbers observed more than FRESH_MS ago
-- show dimmed, with a note of how old they are; past FALLBACK_MS a provider is left out, and an agent's line
-- falls back to the status (an entry with only details, which say how old they are themselves, stays). A cache
-- file the plugin can't read says so among the other parts.
local function build_model(settings: Settings, dock: Dock, cache: Cache?): Model
	local now = now_ms()
	local label, windows, others = parse_line(if dock.status then usage_part(dock.status) else "")
	local groups: { Group } = {}
	local source = "status"
	local title: string? = nil
	local providers = if cache then cache.providers else nil
	local entry: Entry? = nil
	if cache and dock.chip and not dock.remote then
		-- two models sharing a chip name are keyed by provider too; and an entry for another provider than the
		-- one the status names (two sessions that disagree on the model list) isn't this pane's
		local id = if label then provider_id(label, cache) else nil
		entry = (if id then cache.models[id .. "/" .. (dock.chip :: string)] else nil) or cache.models[dock.chip :: string]
		local known = false
		for _, provider in (providers or {}) :: { Provider } do
			known = known or provider.id == id
		end
		if entry and known and entry.provider and entry.provider ~= id then
			entry = nil
		end
		if entry then
			local _, entry_windows = parse_line(entry.line)
			if #entry_windows > 0 and freshness(entry, now) == "fallback" then
				entry = nil
			end
		end
	end
	local listed = false
	if settings.mode ~= "current" and providers then
		for _, provider in ordered(providers, settings.order) do
			if settings.mode == "all" or table.find(settings.selected, provider.id) then
				local provider_label, provider_windows = parse_line(provider.line)
				local fate = freshness(provider, now)
				if fate == "fallback" and #provider_windows > 0 then
					continue
				end
				timed(provider_windows, provider.exact, (cache :: Cache).at, now, settings.pace)
				listed = listed or #provider_windows > 0 or has_facts(provider.details)
				local dim = fate == "dim" and #provider_windows > 0
				provider_windows = shown_windows(settings, provider.id, provider_windows)
				local note = combined_note(settings, provider.id, provider.accounts, provider_windows)
				local rest: { Window }? = nil
				provider_windows, rest = account_view(settings, provider.id, provider.accounts, provider_windows, provider.details)
				local details = visible_details(settings, provider.id, provider.accounts, provider.details)
				if note then
					table.insert(details, 1, note)
				end
				if #provider_windows > 0 or has_facts(details) then
					table.insert(groups, {
						key = provider.id,
						id = provider.id,
						label = provider_label or provider.label,
						windows = provider_windows,
						resets = provider.resets,
						rest = rest,
						details = details,
						as_of = if dim then as_of(age_ms(provider, now) :: number) else nil,
						age = if dim then age_ms(provider, now) else nil,
					})
				end
			end
		end
		source = settings.mode
	end
	if not listed then
		local dim = false
		if entry then
			label, windows = parse_line(entry.line)
			source = "model:" .. (dock.chip :: string)
			timed(windows, entry.exact, (cache :: Cache).at, now, settings.pace)
			dim = #windows > 0 and freshness(entry, now) == "dim"
		else
			source = "status"
			timed(windows, nil, now, now, "off")
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
		local note = combined_note(settings, id, accounts, windows)
		local rest: { Window }? = nil
		windows, rest = account_view(settings, id, accounts, windows, if entry then entry.details else nil)
		local details = visible_details(settings, id, accounts, if entry then entry.details else nil)
		if has_facts(details) and #windows == 0 and entry then
			local kept: { string } = {}
			for _, other in others do
				if other ~= entry.line then table.insert(kept, other) end
			end
			others = kept
		end
		if note then
			table.insert(details, 1, note)
		end
		if #windows > 0 or has_facts(details) then
			table.insert(groups, {
				key = id or label or "usage",
				id = id,
				label = label or "",
				windows = windows,
				resets = if entry then entry.resets else nil,
				rest = rest,
				details = details,
				as_of = if dim then as_of(age_ms(entry, now) :: number) else nil,
				age = if dim then age_ms(entry, now) else nil,
			})
			title = (label or "") .. (if label then " usage" else "Usage")
			if dock.viewing and entry then title = (title :: string) .. " · " .. (dock.chip :: string) end
		end
	end
	if title == nil then
		title = if #groups > 1 then "Usage" elseif #groups == 1 then groups[1].label .. " usage" else "Status"
	end
	local trouble = cache_trouble()
	if trouble then
		table.insert(others, trouble :: string)
	end
	return {
		groups = groups,
		others = others,
		source = source,
		title = title :: string,
		signature = signature_of(groups, others, title :: string) .. "\npace " .. settings.pace,
	}
end

-- Each window's share, by provider and window (a window whose reset has passed has none yet).
local function shares(model: Model): { [string]: number }
	local values: { [string]: number } = {}
	for _, group in model.groups do
		for _, window in group.windows do
			if not window.passed then
				values[group.key .. "/" .. window.label] = window.pct
			end
		end
	end
	return values
end

-- The model's window running furthest ahead of its pace, for the widget bar's warning: its provider's label as the
-- line says it, and its pace. Only windows whose pace the settings show count (see `timed`: none with Show pace
-- off), at PACE_AHEAD or more, and not used up (as `pace_text`). The highest ratio as it reads (to a tenth), then
-- the soonest to run out (a projection already gone by counts as now). Nil while none runs ahead.
export type Ahead = { provider_label: string, label: string, pace: Pace }
local function furthest_ahead(model: Model?): Ahead?
	if model == nil then
		return nil
	end
	local best: Ahead? = nil
	local best_tenths, best_empty = 0, 0
	for _, group in (model :: Model).groups do
		for _, window in group.windows do
			local _, ahead = pace_text(window.pace, window.remaining)
			if ahead then
				local found = window.pace :: Pace
				local tenths = math.floor(found.ratio * 10 + 0.5)
				local empty = found.empty_in_ms or 0
				if best == nil or tenths > best_tenths or (tenths == best_tenths and empty < best_empty) then
					best = { provider_label = group.label, label = window.label, pace = found }
					best_tenths, best_empty = tenths, empty
				end
			end
		end
	end
	return best
end

-- What alerts could be raised now, from every provider and account in the cache whose numbers aren't too old
-- (shown or not): each window that hasn't reset yet (`window`: its share left, alerts.luau decides how low is worth
-- a toast) and each saved reset expiring within a day. A window's `id` (`<provider>/<label>`) is the same in every
-- period: its `resets_at` (`stated` when the cache says it, else a countdown's estimate) tells periods apart, so a
-- reset time stated a second off from one fetch to the next is still the same period. A saved reset's id
-- (`<provider>/<window>@<expiry>`) is its own. Either way the caller can claim each once.
local SAVED_RESET_ALERT_MS = 24 * 3600 * 1000
export type AlertCandidate = {
	id: string,
	provider_label: string,
	label: string,
	remaining: number,
	resets_at: number?,
	stated: boolean?,
	kind: string,
	expires_at: number?,
}
local function alert_candidates(now: number): { AlertCandidate }
	local list: { AlertCandidate } = {}
	local cache = read_cache(now)
	if cache == nil or cache.providers == nil then
		return list
	end
	for _, provider in cache.providers :: { Provider } do
		if freshness(provider, now) == "fallback" then
			continue
		end
		local _, windows = parse_line(provider.line)
		timed(windows, provider.exact, cache.at, now, "off")
		for _, window in windows do
			if not window.passed then
				local stated = false
				for _, item in (provider.exact or {}) :: { CacheWindow } do
					stated = stated or (item.resets_at ~= nil and string.lower(item.label) == string.lower(window.label))
				end
				table.insert(list, {
					id = provider.id .. "/" .. string.lower(window.label),
					provider_label = provider.label,
					label = window.label,
					remaining = left_of(window),
					resets_at = window.resets_at,
					stated = if stated and window.resets_at then true else nil,
					kind = "window",
				})
			end
		end
		for _, reset in provider.resets do
			if reset.at > now and reset.at - now <= SAVED_RESET_ALERT_MS then
				local label = reset.window or "7d"
				local remaining, resets_at = 1, nil
				for _, window in windows do
					if string.lower(window.label) == label then
						remaining, resets_at = left_of(window), window.resets_at
					end
				end
				table.insert(list, {
					id = provider.id .. "/" .. label .. "@" .. tostring(reset.at),
					provider_label = provider.label,
					label = label,
					remaining = remaining,
					resets_at = resets_at,
					kind = "saved_reset_expiring",
					expires_at = reset.at,
				})
			end
		end
	end
	return list
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
local NO_DOCK: Dock = { status = nil, chip = nil, viewing = false, hide = {}, texts = {}, remote = false, seen = false }

-- Whether a status fact's text is this extension's usage line and nothing else (each ` · ` part one of its
-- windows, or `<Label> quota details`), so hiding it hides no other extension's status.
local function own_fact(text: string): boolean
	local pieces = string.split(text, SEPARATOR)
	for p, piece in pieces do
		if parse_window(piece, p == 1) == nil and not string.match(piece, "^%S+ quota details$") then
			return false
		end
	end
	return #pieces > 0
end

-- The status facts to hide in every agent pane's bar, not only the focused one's (whose facts the line redraws):
-- this extension's usage status, where each pane that has it draws its line from the cache. omp shows it in every
-- pane by default, and unfocused panes would show the raw text the line already shows better. Fact ids
-- (`…/hook-1`) depend on the order a session set its statuses in, and a pane can't be told apart in CSS, so an
-- id is hidden only when every agent pane that has it holds this extension's status there and reads its numbers
-- from the cache: where the status is the line's fallback (a remote or WSL pane, no usable cache entry), it stays.
-- Nil when a pane's surface can't be read (then nothing is hidden beyond the focused pane).
local function shared_hidden(cx: WindowCx, settings: Settings, cache: Cache?): { string }?
	local ok, panes = pcall(function(): any
		return cx.session:panes()
	end)
	if not ok or type(panes) ~= "table" then
		return nil
	end
	local verdict: { [string]: boolean } = {}
	for _, info in panes do
		if info.kind == "agent" then
			local dock = read_dock(cx, info.pane)
			if not dock.seen then
				return nil
			end
			local cached = false
			if not dock.remote then
				cached = build_model(settings, dock, cache).source ~= "status"
			end
			for id, text in dock.texts do
				verdict[id] = verdict[id] ~= false and cached and own_fact(text)
			end
		end
	end
	local ids: { string } = {}
	for id, hide in verdict do
		if hide then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

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
	KV_PLAN_HIDDEN = KV_PLAN_HIDDEN,
	KV_CARD_ROWS = KV_CARD_ROWS,
	CARD_ROWS = CARD_ROWS,
	KV_BACKDROP = KV_BACKDROP,
	BACKDROPS = BACKDROPS,
	KV_USAGE_OPENS = KV_USAGE_OPENS,
	USAGE_OPENS = USAGE_OPENS,
	usage_opens = usage_opens,
	COMBINED = COMBINED,
	COMBINED_PLANS = COMBINED_PLANS,
	KV_PACE = KV_PACE,
	PACES = PACES,
	KV_ALERTS = KV_ALERTS,
	FRESH_MS = FRESH_MS,
	FALLBACK_MS = FALLBACK_MS,
	now_ms = now_ms,
	read_dock = read_dock,
	countdown_minutes = countdown_minutes,
	span_to = span_to,
	clock_of = clock_of,
	span = span,
	as_of = as_of,
	reset_text = reset_text,
	tone_of = tone_of,
	is_fable = is_fable,
	pct_text = pct_text,
	share_text = share_text,
	pace = pace,
	pace_text = pace_text,
	age_ms = age_ms,
	freshness = freshness,
	furthest_ahead = furthest_ahead,
	alert_candidates = alert_candidates,
	set_watching = set_watching,
	shared_hidden = shared_hidden,
	read_cache = read_cache,
	offered_providers = offered_providers,
	store = store,
	load_settings = load_settings,
	shown_windows = shown_windows,
	accounts_in_order = accounts_in_order,
	account_of = account_of,
	account_off = account_off,
	plan_off = plan_off,
	plan_in = plan_in,
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
