--!strict
-- Cache documents for the Luau tests, written the way omp/extensions/usage-remaining.js writes
-- ~/.omp/cache/usage-remaining.json (schema 2; `v1 = true` leaves out what schema 1 didn't have): each window as a
-- line piece (`Claude 5h ████░░░░ 62% left (2h)`) and, in schema 2, as a `windows` item with the unrounded share,
-- `resetsAt` and `windowMs`; `observedAt` per entry; `fetchedAt` for the last fetch.
local json = require("./json")

local F = {}

F.M = 60 * 1000
F.H = 60 * F.M
F.D = 24 * F.H

export type Win = {
	label: string,
	key: string,
	ms: number?,
	r: number,
	at: number?,
	provider: string,
	account: string?,
	scope: string?,
	saved: number?,
	passed_text: boolean?,
}

function F.meter(r: number): string
	local filled = math.floor(math.clamp(r, 0, 1) * 8 + 0.5)
	return string.rep("█", filled) .. string.rep("░", 8 - filled)
end

-- As the extension rounds: down, `<1%` under one percent.
function F.pct(r: number): string
	if r > 0 and r < 0.01 then
		return "<1%"
	end
	return string.format("%d%%", math.floor(r * 100 + 1e-9))
end

-- The extension's countdowns: `45m`, `2h 11m`, `6d 4h`, `soon`.
function F.short(ms: number): string
	if ms <= 0 then
		return "soon"
	end
	local mins = math.floor(ms / F.M + 0.5)
	if mins < 60 then
		return string.format("%dm", mins)
	end
	local h, m = mins // 60, mins % 60
	if h < 24 then
		return if m > 0 then string.format("%dh %dm", h, m) else string.format("%dh", h)
	end
	local d, hh = h // 24, h % 24
	return if hh > 0 then string.format("%dd %dh", d, hh) else string.format("%dd", d)
end

-- One window: `opts` has label, key, ms (length), r (share left), at (resetsAt), provider, account, scope, saved.
function F.win(opts: any): Win
	return {
		label = opts.label,
		key = opts.key or opts.label,
		ms = opts.ms,
		r = opts.r,
		at = opts.at,
		provider = opts.provider or "anthropic",
		account = opts.account,
		scope = opts.scope,
		saved = opts.saved,
	}
end

-- A window as its line piece, written at `now` (`lead`: the provider's label in front).
function F.piece(w: Win, now: number, lead: string?): string
	local head = if lead then lead .. " " else ""
	local saved = if w.saved then string.format(" (+%d)", w.saved) else ""
	if w.at and w.at <= now then
		return head .. w.label .. " reset" .. saved
	end
	local reset = if w.at then " (" .. F.short(w.at - now) .. ")" else ""
	return string.format("%s%s %s %s left%s%s", head, w.label, F.meter(w.r), F.pct(w.r), reset, saved)
end

function F.line(label: string, windows: { Win }, now: number): string
	local pieces: { string } = {}
	for i, w in windows do
		table.insert(pieces, F.piece(w, now, if i == 1 then label else nil))
	end
	return table.concat(pieces, " · ")
end

function F.cache_window(w: Win): { [string]: any }
	local item: { [string]: any } = { provider = w.provider, key = w.key, label = w.label, remaining = w.r }
	if w.account then
		item.account = w.account
	end
	if w.scope then
		item.scope = w.scope
	end
	if w.at then
		item.resetsAt = w.at
	end
	if w.ms then
		item.windowMs = w.ms
	end
	return item
end

local function windows_of(list: { Win }): { any }
	local out = json.array({})
	for _, w in list do
		table.insert(out, F.cache_window(w))
	end
	return out
end

-- A provider entry. `opts`: observed (observedAt), accounts, resets, details, v1.
function F.provider(id: string, label: string, windows: { Win }, now: number, opts: any?): { [string]: any }
	local o = opts or {}
	local entry: { [string]: any } = {
		label = label,
		line = F.line(label, windows, now),
		resets = json.array(o.resets or {}),
		details = json.array(o.details or {}),
	}
	if o.accounts then
		entry.accounts = json.array(o.accounts)
	end
	if not o.v1 then
		entry.observedAt = o.observed or now
		entry.windows = windows_of(windows)
	end
	return entry
end

-- A model entry (keyed by its chip name in `models`).
function F.model(id: string, label: string, windows: { Win }, now: number, opts: any?): { [string]: any }
	local o = opts or {}
	local entry: { [string]: any } = {
		line = F.line(label, windows, now),
		resets = json.array(o.resets or {}),
		provider = id,
		details = json.array(o.details or {}),
	}
	if not o.v1 then
		entry.observedAt = o.observed or now
		entry.windows = windows_of(windows)
	end
	return entry
end

-- Claude's usual three windows at `now`: 5h (62% left, resets in 2h), 7d (41%, 3d 4h, one saved reset) and Fable 7d.
function F.claude(now: number, o: any?): { Win }
	local opts = o or {}
	return {
		F.win({ label = "5h", key = "5h", ms = 5 * F.H, r = opts.r5 or 0.62, at = now + (opts.in5 or 2 * F.H) }),
		F.win({ label = "7d", key = "7d", ms = 7 * F.D, r = opts.r7 or 0.41, at = now + (opts.in7 or (3 * F.D + 4 * F.H)), saved = 1 }),
		F.win({ label = "Fable 7d", key = "7d", ms = 7 * F.D, r = opts.rf or 0.83, at = now + (opts.inf or (3 * F.D + 4 * F.H)), scope = "Fable" }),
	}
end

-- A whole cache: `opts.observed` (observedAt for every entry), `opts.written` (generatedAt; `now` unless set),
-- `opts.chips` (model chip names for Claude's entry), `opts.v1`, `opts.claude` (windows), `opts.extra_providers`.
function F.doc(now: number, opts: any?): { [string]: any }
	local o = opts or {}
	local written = o.written or now
	local observed = o.observed or now
	local claude = o.claude or F.claude(written)
	local resets = o.resets or { { expiresAt = now + 10 * F.D, count = 1, window = "7d" } }
	local models: { [string]: any } = {}
	for _, chip in o.chips or { "Opus 5.5" } do
		models[chip] = F.model("anthropic", "Claude", claude, written, { observed = observed, resets = resets, v1 = o.v1 })
	end
	local providers: { [string]: any } = {
		anthropic = F.provider("anthropic", "Claude", claude, written, { observed = observed, resets = resets, v1 = o.v1 }),
	}
	for id, entry in o.extra_providers or {} do
		providers[id] = entry
	end
	local doc: { [string]: any } = { generatedAt = written, models = models, providers = providers }
	if not o.v1 then
		doc.schema = 2
		doc.fetchedAt = o.fetched or observed
	end
	return doc
end

-- A dock as data.luau's `read_dock` gives it: `status` (the joined status facts), `chip` (the model chip's name).
function F.dock(chip: string?, status: string?, extra: any?): { [string]: any }
	local e = extra or {}
	return {
		status = status,
		chip = chip,
		viewing = e.viewing == true,
		hide = e.hide or {},
		texts = e.texts or {},
		remote = e.remote == true,
		seen = true,
	}
end

return F
