--!strict
-- alerts.luau as one or more Tern windows run it: opt-in, a toast per crossing (25%, 10%, nothing left) per reset
-- period, one window toasting for all of them, and the seed that keeps switching on from toasting what's low already.
local T = require("./t")
local H = require("./harness")
local F = require("./fixtures")

local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local NOW = 1795400000000
local KV_ALERTS = "omp-usage.alerts"
local KV_SEEN = "omp-usage.alerts-seen"

-- A window with data.luau and alerts.luau loaded, sharing `kv` with any other window made with it.
local function window(kv: any, key: string?): (any, any)
	local w = H.world({ now = NOW, kv = kv, key = key })
	w:load("data")
	local alerts = w:load("alerts")
	return w, alerts
end

-- The cache with Claude's 5h at `r5` left (resetting at `at`), nothing else low and no saved resets.
local function doc_with(r5: number, written: number, at: number?): any
	local claude = F.claude(written, { r5 = r5 })
	if at then
		claude[1].at = at
	end
	return F.doc(written, { claude = claude, resets = {} })
end

local RESET_AT = NOW + 2 * F.H

local function all_toasts(...: any): { any }
	local out: { any } = {}
	for _, w in { ... } do
		for _, toast in w.toasts do
			table.insert(out, toast)
		end
	end
	return out
end

describe("alerts", function()
	it("stay quiet until switched on", function()
		local kv = H.kv_store()
		local w = window(kv)
		w:write_cache(doc_with(0.05, NOW, RESET_AT))
		w:advance(60000)
		eq(#w.toasts, 0, "no toasts")
		eq(kv.raw("omp-usage.alerts-claim"), nil, "no claims")
	end)

	it("toast each crossing once: a quarter left, a tenth left, used up", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local w = window(kv)
		w:write_cache(doc_with(0.30, NOW, RESET_AT))
		w:advance(20000)
		eq(#w.toasts, 0, "30%: nothing to say")
		w:write_cache(doc_with(0.20, w.epoch_ms, RESET_AT))
		w:advance(20000)
		eq(#w.toasts, 1, "20%")
		eq({ w.toasts[1].level, w.toasts[1].text }, { "info", "Claude 5h is down to 20% left" }, "first toast")
		T.matches(w.toasts[1].sub, "^Resets in 1h 5%dm, at ", "when it comes back")
		w:advance(60000)
		eq(#w.toasts, 1, "no repeat while it stays there")
		w:write_cache(doc_with(0.09, w.epoch_ms, RESET_AT))
		w:advance(20000)
		eq({ #w.toasts, w.toasts[2] and w.toasts[2].level, w.toasts[2] and w.toasts[2].text }, { 2, "error", "Claude 5h is down to 9% left" }, "9%")
		w:write_cache(doc_with(0, w.epoch_ms, RESET_AT))
		w:advance(20000)
		eq({ #w.toasts, w.toasts[3] and w.toasts[3].text }, { 3, "Claude 5h is used up" }, "0%")
		eq(#w.errors, 0, "no timer errors")
	end)

	it("switched on, mark what's low already instead of toasting it", function()
		local kv = H.kv_store()
		local w, alerts = window(kv)
		w:write_cache(doc_with(0.20, NOW, RESET_AT))
		alerts.set_enabled(true)
		w:advance(20000)
		eq(#w.toasts, 0, "already low: no toast")
		ok(kv.get(KV_SEEN) ~= nil, "marked as seen")
		w:write_cache(doc_with(0.09, w.epoch_ms, RESET_AT))
		w:advance(20000)
		eq({ #w.toasts, w.toasts[1] and w.toasts[1].text }, { 1, "Claude 5h is down to 9% left" }, "the next crossing toasts")
	end)

	it("say several events due together in one toast", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local w = window(kv)
		local claude = F.claude(NOW, { r5 = 0.08, r7 = 0.2 })
		w:write_cache(F.doc(NOW, { claude = claude, resets = {} }))
		w:advance(20000)
		eq(#w.toasts, 1, "one toast")
		eq(w.toasts[1].text, "Claude 5h is down to 8% left", "the most pressing first")
		T.matches(w.toasts[1].sub, "Also Claude 7d 20%% left$", "the others under it")
	end)

	it("say when a saved reset expires within a day", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local w = window(kv)
		w:write_cache(F.doc(NOW, { resets = { { expiresAt = NOW + 5 * F.H, count = 1, window = "7d" } } }))
		w:advance(20000)
		eq(#w.toasts, 1, "one toast")
		T.matches(w.toasts[1].text, "^Your saved Claude 7d reset expires in 5h$", "headline (4h 59m 37s rounds to 5h)")
		T.matches(w.toasts[1].sub, "^Use it before ", "second line")
	end)

	it("toast again in the next reset period", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local w = window(kv)
		w:write_cache(doc_with(0.20, NOW, RESET_AT))
		w:advance(20000)
		eq(#w.toasts, 1, "this period")
		-- the window reset: new numbers, and the next reset time
		w:write_cache(doc_with(0.20, w.epoch_ms, RESET_AT + 5 * F.H))
		w:advance(20000)
		eq(#w.toasts, 2, "next period")
	end)

	it("stop toasting once switched off, even with a claim under way", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local w, alerts = window(kv)
		w:write_cache(doc_with(0.30, NOW, RESET_AT))
		w:advance(4000) -- the first check, 5 s after the load, finds nothing due
		w:set_cache(doc_with(0.20, w.epoch_ms, RESET_AT))
		w:advance(13100) -- the poll reads it; the next check, 15 s on, claims; its toast would come 2 s later
		ok(kv.raw("omp-usage.alerts-claim") ~= nil, "claimed")
		alerts.set_enabled(false)
		w:advance(30000)
		eq(#w.toasts, 0, "no toast")
	end)
end)

describe("alerts across windows", function()
	it("toast a crossing once when two windows check at the same moment", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local a = window(kv, "a")
		local b = window(kv, "b")
		for _, w in { a, b } do
			w:write_cache(doc_with(0.20, NOW, RESET_AT))
		end
		-- both check at 5 s, before either delivers at 7 s
		a:advance(2000)
		b:advance(2000)
		a:advance(2000)
		b:advance(2000)
		eq(#all_toasts(a, b), 1, "one toast between them")
	end)

	it("toast a crossing once when the windows check a second apart, or seconds apart", function()
		for _, offset in { 1000, 1900, 2500, 7000 } do
			local kv = H.kv_store({ [KV_ALERTS] = true })
			local a = window(kv, "a")
			local b = window(kv, "b")
			a:write_cache(doc_with(0.20, NOW, RESET_AT))
			b:write_cache(doc_with(0.20, NOW, RESET_AT))
			-- a runs `offset` ahead, so b checks `offset` after a does
			a:advance(offset)
			local step = 100
			for _ = 1, 200 do
				a:advance(step)
				b:advance(step)
			end
			eq(#all_toasts(a, b), 1, "offset " .. offset .. " ms")
		end
	end)

	it("toast a crossing once when each window sees the other's writes half a second late", function()
		local kv = H.kv_store({ [KV_ALERTS] = true }, { lag_ms = 500 })
		local a = window(kv, "a")
		local b = window(kv, "b")
		for _, w in { a, b } do
			w:write_cache(doc_with(0.20, NOW, RESET_AT))
		end
		-- both check at 5 s and deliver at 7 s, each before it could see what the other toasted
		a:advance(2000)
		b:advance(2000)
		a:advance(2000)
		b:advance(2000)
		eq(#all_toasts(a, b), 1, "one toast between them")
	end)

	-- omp states some resets to the millisecond from a countdown at fetch time: the same reset can come back on the
	-- other side of a minute, or a little further off, and is still the same period.
	it("don't toast the same crossing again when the reset time moves by less than a second, or a few minutes", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local w = window(kv)
		w:write_cache(doc_with(0.20, NOW, 1795427999873))
		w:advance(20000)
		w:write_cache(doc_with(0.19, w.epoch_ms, 1795428000250))
		w:advance(20000)
		w:write_cache(doc_with(0.18, w.epoch_ms, 1795427999873 + 4 * F.M))
		w:advance(20000)
		eq(#w.toasts, 1, "toasts for one crossing")
		w:write_cache(doc_with(0.09, w.epoch_ms, 1795428000250))
		w:advance(20000)
		eq({ #w.toasts, w.toasts[2] and w.toasts[2].text }, { 2, "Claude 5h is down to 9% left" }, "the next threshold still toasts")
	end)
end)

describe("alerts without a reset time", function()
	-- The cache with Claude's 5h at `r5` left and no reset time for it.
	local function no_reset(r5: number, written: number): any
		local claude = F.claude(written, { r5 = r5 })
		claude[1].at = nil
		return F.doc(written, { claude = claude, resets = {} })
	end

	it("toast once while the share stays down, and again once it has come back and falls again", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local w = window(kv)
		w:write_cache(no_reset(0.20, NOW))
		w:advance(20000)
		eq(#w.toasts, 1, "20%")
		for _, r in { 0.22, 0.18, 0.21 } do
			w:write_cache(no_reset(r, w.epoch_ms))
			w:advance(20000)
		end
		eq(#w.toasts, 1, "no repeat while it hovers there")
		w:write_cache(no_reset(1, w.epoch_ms))
		w:advance(20000)
		eq(#w.toasts, 1, "back to full: nothing to say")
		w:write_cache(no_reset(0.20, w.epoch_ms))
		w:advance(20000)
		eq({ #w.toasts, w.toasts[2] and w.toasts[2].text }, { 2, "Claude 5h is down to 20% left" }, "the next period's crossing")
		eq(w.toasts[2].sub, nil, "no reset time to tell")
	end)
end)

describe("alerts' wording", function()
	it("say the share the line says (19% for 1 - 0.81, not 18%)", function()
		local kv = H.kv_store({ [KV_ALERTS] = true })
		local w = window(kv)
		w:write_cache(doc_with(1 - 0.81, NOW, RESET_AT))
		w:advance(20000)
		eq(w.toasts[1] and w.toasts[1].text, "Claude 5h is down to 19% left")
	end)
end)

return true -- run.mjs checks it: the Luau CLI's `require` returns a file's compile error instead of raising it
