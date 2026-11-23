--!strict
-- Alerts, opt-in (off until switched on in the settings panel or `omp Usage: Settings…`): a toast when a window
-- falls to 25%, 10% or nothing left, once per window, threshold and reset period, and one when a saved reset is
-- about to expire. Every Tern window runs this, so what each event has toasted is kept in `tern.kv`, which every
-- window shares, and only the window whose claim sticks toasts (as update.luau's automatic check claims its run).
-- Switching alerts on marks what is low already as said: alerts are about crossings, not a list of what is low.
local data = require("./data")

local store = data.store
local now_ms = data.now_ms
local span_to = data.span_to

-- event id -> { level, at (epoch s), and for a window the period it was toasted in: resets_at, stated, left }: how
-- far each one has been toasted
local KV_SEEN = "omp-usage.alerts-seen"
local KV_SEED = "omp-usage.alerts-seed" -- set when alerts are switched on: the next check marks, without toasts
local KV_CLAIM = "omp-usage.alerts-claim" -- the window that toasts what is due now
local POLL_MS = 15000
local CLAIM_SETTLE_MS = 2000 -- long enough for every window checking with this one to write its claim
local KEEP_S = 40 * 86400 -- an event older than every window's period is forgotten
local EXPIRY_NOTICE_MS = 24 * 3600 * 1000 -- a saved reset's toast comes within its last day
local WARN_EVERY_MS = 60000
-- How far a window's reset time can move and still be the same period: omp states some resets from a countdown at
-- fetch time, so the same reset comes a second or so apart from one fetch to the next (and a countdown's estimate,
-- an hour apart). Every window's period is longer than either.
local STATED_JITTER_MS = 5 * 60000
local ESTIMATE_JITTER_MS = 2 * 3600000
-- Without a reset time, a share this much above where it was toasted means the window came back: a new period.
local RISE = 0.05

type Candidate = data.AlertCandidate
type Due = { candidate: Candidate, level: number }
type Mark = { level: number, at: number, resets_at: number?, stated: boolean?, left: number? }
type Seen = { [string]: Mark }

local function enabled(): boolean
	return store.get(data.KV_ALERTS) == true
end

-- Switches alerts on or off, from the panel or the pickers. Switched on from off, the next check marks what is low
-- already, without toasts.
local function set_enabled(on: boolean)
	if on and not enabled() then
		store.set(KV_SEED, true)
	elseif not on then
		store.set(KV_SEED, nil)
	end
	store.set(data.KV_ALERTS, on)
end

-- How far a candidate has gone: 1 at 25% or less, 2 at 10% or less, 3 with nothing left; a saved reset within its
-- last day is 1. 0: nothing to say.
local function level_of(candidate: Candidate, now: number): number
	if candidate.kind == "saved_reset_expiring" then
		local at = candidate.expires_at
		return if at and at > now and at - now <= EXPIRY_NOTICE_MS then 1 else 0
	elseif candidate.kind ~= "window" then
		return 0
	end
	local left = candidate.remaining
	if left <= 0 then
		return 3
	elseif left <= 0.10 then
		return 2
	elseif left <= 0.25 then
		return 1
	end
	return 0
end

local function read_seen(): Seen
	local seen: Seen = {}
	local stored = store.get(KV_SEEN)
	if type(stored) == "table" then
		for id, item in pairs(stored) do
			if type(id) == "string" and type(item) == "table" and type(item.level) == "number" and type(item.at) == "number" then
				seen[id] = {
					level = item.level,
					at = item.at,
					resets_at = if type(item.resets_at) == "number" then item.resets_at else nil,
					stated = if item.stated == true then true else nil,
					left = if type(item.left) == "number" then item.left else nil,
				}
			end
		end
	end
	return seen
end

-- Whether a window's candidate is in the period `mark` was toasted in: its reset time within the jitter of the
-- toasted one's; without a reset time on either side, while its share hasn't come back by RISE.
local function same_period(mark: Mark, candidate: Candidate): boolean
	if candidate.kind ~= "window" then
		return true
	end
	local before, now = mark.resets_at, candidate.resets_at
	if before and now then
		local jitter = if mark.stated and candidate.stated then STATED_JITTER_MS else ESTIMATE_JITTER_MS
		return math.abs(now - before) < jitter
	end
	return mark.left == nil or candidate.remaining - (mark.left :: number) < RISE - 1e-9
end

-- What has gone further than `seen` says was toasted in its period.
local function due(candidates: { Candidate }, now: number, seen: Seen): { Due }
	local list: { Due } = {}
	for _, candidate in candidates do
		local level = level_of(candidate, now)
		local before = seen[candidate.id]
		if level > (if before and same_period(before, candidate) then before.level else 0) then
			table.insert(list, { candidate = candidate, level = level })
		end
	end
	return list
end

-- When a window comes back: `Resets in 2h 11m, at 4:05 PM`.
local function back_text(resets_at: number?, now: number): string?
	if resets_at == nil or resets_at <= now then
		return nil
	end
	local at = data.clock_of(resets_at :: number, true)
	return "Resets in " .. span_to(resets_at :: number, now) .. (if at then ", at " .. at else "")
end

-- A due event as a toast's level, headline and second line: `Claude 5h is down to 9% left` / `Resets in 2h 11m, at
-- 3:41 AM`; `Claude 5h is used up`; `Your saved Claude 7d reset expires in 5h` / `Use it before 6:32 AM`.
local function says(item: Due, now: number): (ToastLevel, string, string?)
	local c = item.candidate
	local name = c.provider_label .. " " .. c.label
	if c.kind == "saved_reset_expiring" then
		local at = c.expires_at or now
		local clock = data.clock_of(at, true)
		return "info", "Your saved " .. name .. " reset expires in " .. span_to(at, now), if clock then "Use it before " .. clock else nil
	elseif item.level >= 3 then
		return "error", name .. " is used up", back_text(c.resets_at, now)
	end
	return if item.level >= 2 then "error" else "info", name .. " is down to " .. data.share_text(c.remaining) .. " left", back_text(c.resets_at, now)
end

-- How a further event reads after the first: `Claude 7d 24% left`, `Claude 5h used up`, `saved Claude 7d reset`.
local function also(item: Due): string
	local c = item.candidate
	local name = c.provider_label .. " " .. c.label
	if c.kind == "saved_reset_expiring" then
		return "saved " .. name .. " reset expiring"
	end
	return name .. (if item.level >= 3 then " used up" else " " .. data.share_text(c.remaining) .. " left")
end

-- Marks `list` as toasted, each window with its period, and forgets what is too old to matter.
local function remember(seen: Seen, list: { Due })
	local stamp = os.time()
	for _, item in list do
		local c = item.candidate
		seen[c.id] = { level = item.level, at = stamp, resets_at = c.resets_at, stated = c.stated, left = c.remaining }
	end
	for id, item in seen do
		if stamp - item.at > KEEP_S then
			seen[id] = nil
		end
	end
	store.set(KV_SEEN, seen)
end

-- Toasts what this window claimed, if its claim stuck. Events due together make one toast (toasts shown back to
-- back can replace each other): the most pressing first, the others under it.
local function deliver(cx: WindowCx, claim: string)
	if store.get(KV_CLAIM) ~= claim or not enabled() then
		return
	end
	local now = now_ms()
	local seen = read_seen()
	local list = due(data.alert_candidates(now), now, seen)
	if #list == 0 then
		return
	end
	remember(seen, list)
	table.sort(list, function(a: Due, b: Due): boolean
		local ka = if a.candidate.kind == "window" then a.level else 0
		local kb = if b.candidate.kind == "window" then b.level else 0
		return if ka ~= kb then ka > kb else a.candidate.remaining < b.candidate.remaining
	end)
	local level: ToastLevel, text: string, sub: string? = says(list[1], now)
	if #list > 1 then
		local rest: { string } = {}
		for i = 2, #list do
			table.insert(rest, also(list[i]))
		end
		sub = (if sub then sub .. ". " else "") .. "Also " .. table.concat(rest, ", ")
	end
	cx:toast(level, text, sub)
end

local function check(cx: WindowCx)
	local now = now_ms()
	local candidates = data.alert_candidates(now)
	local seen = read_seen()
	-- A period that has ended is forgotten as soon as it shows: a window without a reset time shows it only while
	-- its share is back up, and by its next crossing nothing would tell.
	local ended = false
	for _, candidate in candidates do
		local before = seen[candidate.id]
		if before and not same_period(before, candidate) then
			seen[candidate.id] = nil
			ended = true
		end
	end
	if ended then
		store.set(KV_SEEN, seen)
	end
	if store.get(KV_SEED) then
		store.set(KV_SEED, nil)
		local low: { Due } = {}
		for _, item in due(candidates, now, seen) do
			if item.candidate.kind == "window" then
				table.insert(low, item)
			end
		end
		remember(seen, low)
		return
	end
	if #due(candidates, now, seen) == 0 then
		return
	end
	local claim = string.format("%d.%d@%d", math.random(1, 1073741824), math.floor(os.clock() * 1e6), tern.now())
	store.set(KV_CLAIM, claim)
	tern.timer(CLAIM_SETTLE_MS, function(later: WindowCx?)
		if later then
			local ok, err: any = pcall(deliver, later, claim)
			if not ok then
				tern.log.warn("omp Usage: alerts failed:", err)
			end
		end
	end)
end

local last_warn = -math.huge
local function tick(cx: WindowCx?)
	tern.timer(POLL_MS, tick)
	if cx == nil or not enabled() then
		return
	end
	local ok, err: any = pcall(check, cx)
	if not ok and tern.now() - last_warn >= WARN_EVERY_MS then
		last_warn = tern.now()
		tern.log.warn("omp Usage: alerts failed:", err)
	end
end

tern.timer(5000, tick)

return {
	enabled = enabled,
	set_enabled = set_enabled,
}
