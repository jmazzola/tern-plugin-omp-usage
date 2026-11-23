--!strict
-- data.luau's pure functions: parsing the extension's line, the share as the line writes it, combining accounts,
-- moving a provider, custom colors, pace and freshness.
local T = require("./t")
local H = require("./harness")
local F = require("./fixtures")

local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local EXPOSE = { ["data.luau"] = { "parse_window", "parse_line", "combined", "timed" } }

local function data_module(opts: any?): (any, any)
	local o = opts or {}
	o.expose = o.expose or EXPOSE
	local w = H.world(o)
	return w:load("data"), w
end

describe("parse_window", function()
	local data = data_module()
	local parse_window = data.__test.parse_window

	it("reads the first window of a line with its provider, countdown and saved resets", function()
		local window, provider = parse_window("Claude 7d ███░░░░░ 38% left (3h 34m) (+1)", true)
		eq(provider, "Claude", "provider")
		eq(window, { label = "7d", pct = 38, reset = "3h 34m", saved = 1 }, "window")
	end)

	it("keeps a scope in the label, without a provider after the first window", function()
		local window, provider = parse_window("Fable 7d ░░░░░░░░ 0% left (3h)", false)
		eq(provider, nil, "provider")
		eq(window, { label = "Fable 7d", pct = 0, reset = "3h" }, "window")
	end)

	it("takes the first word as the provider and the rest as the scope on a line's first window", function()
		local window, provider = parse_window("Claude Fable 7d █░░░░░░░ 12% left", true)
		eq(provider, "Claude", "provider")
		eq(window and window.label, "Fable 7d", "label")
	end)

	it("keeps an account in front of the span (several accounts)", function()
		local window, provider = parse_window("Claude alice 5h ████░░░░ 55% left (2h)", true)
		eq(provider, "Claude", "provider")
		eq(window and window.label, "alice 5h", "label")
	end)

	it("reads `<1% left` as under one percent, with a share of 0", function()
		local window = parse_window("Claude 5h ░░░░░░░░ <1% left (2h)", true)
		eq(window, { label = "5h", pct = 0, under = true, reset = "2h" }, "window")
	end)

	it("reads `100% left`", function()
		local window = parse_window("7d ████████ 100% left (6d 4h)", false)
		eq(window and window.pct, 100, "pct")
	end)

	it("reads a passed reset as `reset` (share 100) and keeps its saved resets", function()
		local window, provider = parse_window("Claude 5h reset (+1)", true)
		eq(provider, "Claude", "provider")
		eq(window, { label = "5h", pct = 100, passed = true, saved = 1 }, "window")
	end)

	it("reads a monthly window's passed reset", function()
		local window = parse_window("mo reset", false)
		eq(window and window.passed, true, "passed")
		eq(window and window.label, "mo", "label")
	end)

	it("leaves other statuses that end in `reset` as text", function()
		eq(parse_window("demo: password reset", false), nil, "not a span")
		eq(parse_window("Claude 5h reset now", true), nil, "text after `reset` that isn't a group")
	end)

	it("reads an expiring saved reset `(!2 - 3d left)`", function()
		local window = parse_window("7d ████░░░░ 50% left (2d 1h) (!2 - 3d left)", false)
		eq(window, { label = "7d", pct = 50, reset = "2d 1h", saved = 2, expires = "3d" }, "window")
	end)

	it("takes `soon` as the countdown", function()
		local window = parse_window("5h ██░░░░░░ 21% left (soon)", false)
		eq(window and window.reset, "soon", "reset")
	end)

	it("leaves anything else alone", function()
		eq(parse_window("◫ 16.5K/1M (1.6%)", true), nil, "context gauge")
		eq(parse_window("demo: other extension", true), nil, "other status")
		eq(parse_window("", true), nil, "empty")
	end)
end)

describe("parse_line", function()
	local data = data_module()
	local parse_line = data.__test.parse_line

	it("splits a status into the label, the windows and the other parts", function()
		local label, windows, others = parse_line("Claude 5h ███░░░░░ 33% left (1h 2m) · 7d ██████░░ 77% left (3d 4h) · demo: other extension")
		eq(label, "Claude", "label")
		eq(#windows, 2, "windows")
		eq(windows[2].label, "7d", "second window")
		eq(others, { "demo: other extension" }, "others")
	end)
end)

describe("pct_text", function()
	local data = data_module()

	it("writes the share", function()
		eq(data.pct_text({ label = "5h", pct = 64 }), "64%")
	end)

	it("writes under one percent as `<1%`", function()
		eq(data.pct_text({ label = "5h", pct = 0, under = true }), "<1%")
	end)

	it("writes a passed reset as `reset`, whatever the share says", function()
		eq(data.pct_text({ label = "5h", pct = 100, passed = true }), "reset")
		eq(data.pct_text({ label = "5h", pct = 0, under = true, passed = true }), "reset")
	end)

	it("writes 0%", function()
		eq(data.pct_text({ label = "5h", pct = 0 }), "0%")
	end)
end)

describe("share_text", function()
	local data = data_module()

	it("writes a share left as usage-remaining.js does: rounded down, kept whole against float error", function()
		eq(data.share_text(0.57), "57%", "0.57")
		eq(data.share_text(0.58), "58%", "0.58")
		eq(data.share_text(0.29), "29%", "0.29")
		eq(data.share_text(1 - 0.71), "29%", "1 - 0.71")
		eq(data.share_text(0.649), "64%", "rounded down")
		eq(data.share_text(1), "100%", "full")
	end)

	it("writes `<1%` under one percent and `0%` for nothing left", function()
		eq(data.share_text(0.004), "<1%", "under")
		eq(data.share_text(0.01), "1%", "one")
		eq(data.share_text(0), "0%", "none")
		eq(data.share_text(-0.1), "0%", "below none")
	end)
end)

-- A window of an account, as `account_view` hands them to `combined`.
local function acct(account: string, bare: string, pct: number, extra: any?): any
	local w: any = { label = account .. " " .. bare, account = account, bare = bare, pct = pct }
	for key, value in extra or {} do
		w[key] = value
	end
	return w
end

-- Each account's list, its first window leading (as `account_view` marks it).
local function lists(...: { any }): { { any } }
	local out = { ... }
	for _, list in out do
		list[1].lead = true
	end
	return out
end

describe("combined", function()
	local data = data_module()
	local combined = data.__test.combined

	it("averages each window over the accounts, rounding half up, with the soonest countdown", function()
		local on = lists(
			{ acct("alice", "5h", 55, { reset = "2h" }), acct("alice", "7d", 38, { reset = "3d 1h" }) },
			{ acct("bob", "5h", 40, { reset = "1h 30m" }), acct("bob", "7d", 50, { reset = "2d" }) }
		)
		local out, info = combined(on, {}, false, {})
		eq(info.chip, "combined · 2 accounts", "chip")
		eq(#out, 2, "one run of windows")
		eq({ out[1].label, out[1].pct, out[1].reset, out[1].lead, out[1].account }, { "2 accounts 5h", 48, "1h 30m", true, "2 accounts" }, "5h")
		eq({ out[2].label, out[2].pct, out[2].reset, out[2].lead }, { "2 accounts 7d", 44, "2d", nil }, "7d")
	end)

	it("says how many accounts a window only some have stands for", function()
		local on = lists({ acct("alice", "5h", 55), acct("alice", "7d", 38) }, { acct("bob", "5h", 40) })
		local out = combined(on, {}, false, {})
		eq(out[2].covers, "1 of the 2 accounts", "covers")
		eq(out[2].pct, 38, "the one account's share")
		eq(out[1].covers, nil, "a window all have")
	end)

	it("takes `soon` as the soonest countdown", function()
		local on = lists({ acct("alice", "5h", 10, { reset = "45m" }) }, { acct("bob", "5h", 20, { reset = "soon" }) })
		eq(combined(on, {}, false, {})[1].reset, "soon")
	end)

	it("adds up saved resets and keeps the soonest expiry", function()
		local on = lists(
			{ acct("alice", "7d", 50, { saved = 1, expires = "5d" }) },
			{ acct("bob", "7d", 60, { saved = 2, expires = "3d" }) }
		)
		local out = combined(on, {}, false, {})
		eq({ out[1].saved, out[1].expires }, { 3, "3d" })
	end)

	it("keeps the soonest exact reset time of the windows that haven't reset", function()
		local on = lists(
			{ acct("alice", "5h", 50, { resets_at = 2000, exact = true }) },
			{ acct("bob", "5h", 60, { resets_at = 1000, exact = false }) },
			{ acct("carol", "5h", 100, { resets_at = 500, passed = true }) }
		)
		local out = combined(on, {}, false, {})
		eq({ out[1].resets_at, out[1].exact }, { 1000, false })
	end)

	it("reads a window `reset` only when every account's has reset", function()
		local all = lists({ acct("alice", "5h", 100, { passed = true }) }, { acct("bob", "5h", 100, { passed = true }) })
		local out = combined(all, {}, false, {})
		eq({ out[1].passed, out[1].reset, data.pct_text(out[1]) }, { true, nil, "reset" }, "all reset")
		local some = lists({ acct("alice", "5h", 100, { passed = true }) }, { acct("bob", "5h", 20, { reset = "2h" }) })
		local mixed = combined(some, {}, false, {})
		eq({ mixed[1].passed, mixed[1].reset, mixed[1].pct }, { nil, "2h", 60 }, "one reset: a fresh window is full")
	end)

	it("puts windows without an account first, as they are", function()
		local loose = { { label = "credits", pct = 70 } }
		local out = combined(lists({ acct("alice", "5h", 50) }, { acct("bob", "5h", 30) }), loose, false, {})
		eq(out[1], { label = "credits", pct = 70 }, "loose first")
		eq(out[2].label, "2 accounts 5h", "then the group")
	end)

	it("groups by the plans the provider reports", function()
		local on = lists({ acct("alice", "5h", 50) }, { acct("bob", "5h", 30) }, { acct("carol", "5h", 90) })
		local out, info = combined(on, {}, true, { alice = "Max 20x", bob = "Max 20x", carol = "Pro" })
		eq(info.chip, "by plan · 2 Max 20x, 1 Pro", "chip")
		eq(info.tags, { alice = "Max 20x", bob = "Max 20x", carol = "Pro" }, "tags")
		eq({ out[1].label, out[1].pct }, { "2 Max 20x accounts 5h", 40 }, "the plan of two")
		eq(out[2].label, "carol (Pro) 5h", "a plan of one keeps the account's name")
	end)

	it("one reported plan for all reads `all N <plan>`", function()
		local _, info = combined(lists({ acct("alice", "5h", 50) }, { acct("bob", "5h", 30) }), {}, true, { alice = "Pro", bob = "Pro" })
		eq(info.chip, "by plan · all 2 Pro")
	end)

	it("without reported plans, groups by windows and names the one window that sets them apart", function()
		local on = lists(
			{ acct("alice", "5h", 50), acct("alice", "7d", 60) },
			{ acct("bob", "7d", 30) },
			{ acct("carol", "5h", 70), acct("carol", "7d", 80) }
		)
		local out, info = combined(on, {}, true, {})
		eq(info.chip, "by plan · 2 with 5H, 1 without", "chip")
		eq(info.tags, { alice = "5H", bob = "no 5H", carol = "5H" }, "tags")
		eq({ out[1].label, out[1].plan, out[1].pct }, { "2 accounts 5h", "2 accounts with a 5-hour window", 60 }, "group with it")
		eq({ out[3].label, out[3].plan }, { "bob, no 5H 7d", "bob without a 5-hour window" }, "group without it")
	end)

	it("with several differing windows, lists each group's windows", function()
		local on = lists({ acct("alice", "5h", 50) }, { acct("bob", "7d", 30) })
		local out, info = combined(on, {}, true, {})
		eq(info.chip, "by plan · 2 groups by their windows", "chip")
		eq(info.tags, { alice = "5H", bob = "7D" }, "tags")
		eq(out[1].plan, "alice · 5H", "heading")
	end)

	it("keeps `<1%` when every account has less than one percent left", function()
		local on = lists({ acct("alice", "5h", 0, { under = true }) }, { acct("bob", "5h", 0, { under = true }) })
		local out = combined(on, {}, false, {})
		eq(data.pct_text(out[1]), "<1%", "the combined share")
	end)

	it("reads `<1%` for an average under one percent, and `0%` only when every account is out", function()
		local mixed = combined(lists({ acct("alice", "5h", 1) }, { acct("bob", "5h", 0, { under = true }) }), {}, false, {})
		eq(data.pct_text(mixed[1]), "<1%", "1% and <1%")
		local out = combined(lists({ acct("alice", "5h", 0) }, { acct("bob", "5h", 0) }), {}, false, {})
		eq(data.pct_text(out[1]), "0%", "both out")
		local two = combined(lists({ acct("alice", "5h", 2) }, { acct("bob", "5h", 0, { under = true }) }), {}, false, {})
		eq(data.pct_text(two[1]), "1%", "2% and <1%")
	end)
end)

describe("account_view", function()
	local data = data_module()
	local settings = data.load_settings()
	local windows = {
		{ label = "alice 5h", pct = 55, reset = "2h" },
		{ label = "alice 7d", pct = 38 },
		{ label = "bob 5h", pct = 40, reset = "1h" },
	}

	it("leaves one account's windows as they are", function()
		local shown, rest = data.account_view(settings, "anthropic", {}, { { label = "5h", pct = 50 } }, nil)
		eq({ #shown, rest }, { 1, nil })
	end)

	it("shows every account, in the user's order, each led by its first window", function()
		settings.account_order = { anthropic = { "bob", "alice" } }
		local shown = data.account_view(settings, "anthropic", { "alice", "bob" }, windows, nil)
		eq({ shown[1].label, shown[1].lead, shown[2].label, shown[2].lead, shown[3].lead }, { "bob 5h", true, "alice 5h", true, nil })
		settings.account_order = {}
	end)

	it("combines the accounts as set, and returns the chip's text third", function()
		settings.account = { anthropic = data.COMBINED }
		local shown, rest, info = data.account_view(settings, "anthropic", { "alice", "bob" }, windows, nil)
		eq(rest, nil, "no rest")
		eq(info and info.chip, "combined · 2 accounts", "chip")
		eq({ shown[1].label, shown[1].pct }, { "2 accounts 5h", 48 }, "averaged")
		settings.account = {}
	end)

	it("shows only the chosen account, and the others' windows as `rest`", function()
		settings.account = { anthropic = "bob" }
		local shown, rest = data.account_view(settings, "anthropic", { "alice", "bob" }, windows, nil)
		eq({ #shown, shown[1].label }, { 1, "bob 5h" }, "shown")
		eq(#(rest :: any), 2, "rest")
		settings.account = {}
	end)

	it("leaves accounts switched off out of all of it", function()
		settings.account_hidden = { anthropic = { "alice" } }
		local shown = data.account_view(settings, "anthropic", { "alice", "bob" }, windows, nil)
		eq({ #shown, shown[1].label }, { 1, "bob 5h" })
		settings.account_hidden = {}
	end)
end)

describe("moved", function()
	local data = data_module()
	local moved = data.moved
	local shown = { "a", "b", "c" }

	it("moves up, down, to the top and to the bottom", function()
		eq(moved({}, shown, "b", "up"), { "b", "a", "c" }, "up")
		eq(moved({}, shown, "b", "down"), { "a", "c", "b" }, "down")
		eq(moved({}, shown, "c", "top"), { "c", "a", "b" }, "top")
		eq(moved({}, shown, "a", "bottom"), { "b", "c", "a" }, "bottom")
	end)

	it("leaves the order as it is at either end", function()
		eq(moved({}, shown, "a", "up"), shown, "first up")
		eq(moved({}, shown, "c", "down"), shown, "last down")
		eq(moved({}, shown, "a", "top"), shown, "first to the top")
		eq(moved({}, shown, "c", "bottom"), shown, "last to the bottom")
	end)

	it("puts it before what is `at`th once it's lifted out, or last past the end", function()
		eq(moved({}, shown, "a", 1), { "a", "b", "c" }, "slot 1")
		eq(moved({}, shown, "a", 2), { "b", "a", "c" }, "slot 2")
		eq(moved({}, shown, "a", 3), { "b", "c", "a" }, "past the end")
		eq(moved({}, shown, "c", 1), { "c", "a", "b" }, "last to slot 1")
	end)

	it("keeps ids the order named that aren't on offer now in their places", function()
		-- the stored order names x (not signed in now) first; b and a follow it, c (unnamed) after them
		eq(moved({ "x", "b", "a" }, { "b", "a", "c" }, "c", "up"), { "x", "b", "c", "a" })
	end)

	it("returns the full order unchanged for an id not on offer", function()
		eq(moved({ "b" }, shown, "z", "up"), { "b", "a", "c" })
	end)

	it("doesn't change the order it was given", function()
		local order = { "a", "b", "c" }
		moved(order, shown, "c", "top")
		eq(order, { "a", "b", "c" })
	end)
end)

describe("parse_colors", function()
	local data = data_module()
	local parse_colors = data.parse_colors

	it("reads one or two hex colors, lowercased", function()
		eq({ parse_colors("#D97757") }, { { "#d97757" } }, "one")
		eq({ parse_colors("#9aa7b4, #5b8def") }, { { "#9aa7b4", "#5b8def" } }, "two with a comma")
		eq({ parse_colors("  #9aa7b4   #5b8def ") }, { { "#9aa7b4", "#5b8def" } }, "two with spaces")
	end)

	it("spells `#rgb` out", function()
		eq({ parse_colors("#aBc") }, { { "#aabbcc" } })
	end)

	it("names the part that isn't a color", function()
		eq({ parse_colors("#d97757, red") }, { nil, "red" }, "a name")
		eq({ parse_colors("#12345") }, { nil, "#12345" }, "five digits")
		eq({ parse_colors("#abcd") }, { nil, "#abcd" }, "four digits")
		eq({ parse_colors("d97757") }, { nil, "d97757" }, "no #")
	end)

	it("takes neither none nor three", function()
		eq({ parse_colors("") }, { nil, "" }, "empty")
		eq({ parse_colors("#111, #222, #333") }, { nil, "#111, #222, #333" }, "three")
	end)

	it("gives a typed color a counterpart where the theme would hide it", function()
		eq(data.palette_of_spec("#ffffff").a, "light-dark(#4d4d4d, #ffffff)", "near white")
		eq(data.palette_of_spec("#000000").a, "light-dark(#000000, #bfbfbf)", "near black")
		eq(data.palette_of_spec("#5b8def").a, "#5b8def", "in between")
	end)
end)

describe("pace", function()
	local data = data_module()
	local now = 1795400000000
	local H5 = 5 * F.H

	it("is the share used over the share of the window gone, and when it empties at that rate", function()
		local p = data.pace({ key = "5h", label = "5h", remaining = 0.2, window_ms = H5, resets_at = now + 2 * F.H, observed_at = now }, now)
		T.near(p and p.ratio, 0.8 / 0.6, 1e-9, "ratio")
		T.near(p and p.empty_in_ms, 45 * F.M, 1, "empty in")
		eq(data.pace_text(p, 0.2), "1.3× pace · empty ~45m", "text")
	end)

	it("works the rate out when the numbers were observed, and counts down from now", function()
		local p = data.pace({ key = "5h", label = "5h", remaining = 0.2, window_ms = H5, resets_at = now + 2 * F.H, observed_at = now - 10 * F.M }, now)
		T.near(p and p.ratio, 0.8 / (170 / 300), 1e-9, "ratio from the observation")
		T.near(p and p.empty_in_ms, 32.5 * F.M, 1, "empty in, from now")
		eq(data.pace_text(p, 0.2), "1.4× pace · empty ~33m", "text")
	end)

	it("says nothing too early in the window, after its reset, or without a length or a reset", function()
		local base = { key = "5h", label = "5h", remaining = 0.5, window_ms = H5, observed_at = now }
		local early = table.clone(base)
		early.resets_at = now + 4.6 * F.H -- 8% gone
		eq(data.pace(early, now), nil, "under a tenth gone")
		local passed = table.clone(base)
		passed.resets_at = now - 1000
		eq(data.pace(passed, now), nil, "passed")
		local no_length = table.clone(base)
		no_length.window_ms = nil
		no_length.resets_at = now + F.H
		eq(data.pace(no_length, now), nil, "no length")
		local zero = table.clone(base)
		zero.window_ms = 0
		zero.resets_at = now + F.H
		eq(data.pace(zero, now), nil, "zero length")
	end)

	it("notes only a pace 1.1× or more that runs out before the reset", function()
		local on_pace = data.pace({ key = "5h", label = "5h", remaining = 0.5, window_ms = H5, resets_at = now + 2.5 * F.H, observed_at = now }, now)
		eq(data.pace_text(on_pace, 0.5), nil, "on pace")
		local just = data.pace({ key = "5h", label = "5h", remaining = 0.45, window_ms = H5, resets_at = now + 2.5 * F.H, observed_at = now }, now)
		eq(data.pace_text(just, 0.45), "1.1× pace · empty ~2h", "1.1×")
		local slow = data.pace({ key = "5h", label = "5h", remaining = 0.6, window_ms = H5, resets_at = now + 2.5 * F.H, observed_at = now }, now)
		eq(data.pace_text(slow, 0.6), nil, "lasts to the reset")
		local empty = data.pace({ key = "5h", label = "5h", remaining = 0, window_ms = H5, resets_at = now + 2 * F.H, observed_at = now }, now)
		eq(data.pace_text(empty, 0), nil, "nothing left")
		eq(data.pace_text(nil, 0.4), nil, "unknown")
	end)

	it("keeps the ratio but drops `empty ~` for a projection that ran out before now", function()
		-- observed 60 min ago with 10% left at 3h of 5h gone: at that rate it ran out 40 minutes ago
		local p = data.pace({ key = "5h", label = "5h", remaining = 0.1, window_ms = H5, resets_at = now + 1 * F.H, observed_at = now - 60 * F.M }, now)
		T.near(p and p.ratio, 1.5, 1e-9, "ratio")
		eq(p and p.empty_in_ms, nil, "no time to empty")
		eq(data.pace_text(p, 0.1), "1.5× pace", "pace text")
	end)
end)

describe("age_ms and freshness", function()
	local data = data_module()
	local now = 1795400000000

	it("ages an entry from when it was observed, else the file's last fetch, else its heartbeat", function()
		eq(data.age_ms({ observed_at = now - 5000, fetched_at = now - 9000, at = now - 1 }, now), 5000, "observed")
		eq(data.age_ms({ fetched_at = now - 9000, at = now - 1 }, now), 9000, "fetched")
		eq(data.age_ms({ at = now - 7000 }, now), 7000, "heartbeat")
		eq(data.age_ms({}, now), nil, "nothing")
		eq(data.age_ms(nil, now), nil, "no entry")
		eq(data.age_ms({ observed_at = now + 60000 }, now), 0, "from the future")
	end)

	it("is fresh up to FRESH_MS, dim past it, and falls back past FALLBACK_MS", function()
		eq({ data.FRESH_MS, data.FALLBACK_MS }, { 10 * F.M, 30 * F.M }, "the settled thresholds")
		eq(data.freshness({ observed_at = now - 10 * F.M }, now), "fresh", "10 min")
		eq(data.freshness({ observed_at = now - 10 * F.M - 1 }, now), "dim", "10 min and a ms")
		eq(data.freshness({ observed_at = now - 30 * F.M }, now), "dim", "30 min")
		eq(data.freshness({ observed_at = now - 30 * F.M - 1 }, now), "fallback", "30 min and a ms")
		eq(data.freshness({}, now), "fallback", "no time at all")
	end)

	it("writes an age as the note says it", function()
		eq(data.as_of(25 * F.M), "as of 25m ago")
		eq(data.as_of(90 * F.M), "as of 1h 30m ago")
		eq(data.as_of(10), "as of 1m ago")
	end)
end)

return true -- run.mjs checks it: the Luau CLI's `require` returns a file's compile error instead of raising it
