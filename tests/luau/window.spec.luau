--!strict
-- window.luau in a simulated window: a fake omp pane (its composer's dock as Tern's surface read gives it) and the
-- cache, through the 1 s poll, to the line's style sheet, the hidden status facts and the widget bar's segment.
local T = require("./t")
local H = require("./harness")
local F = require("./fixtures")

local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local NOW = 1795400000000
local USAGE = "Claude 5h ███░░░░░ 33% left (1h 2m) · 7d ██████░░ 77% left (3d 4h)"
local OTHER = "demo: other extension"

-- An omp composer's dock: the model chip, and the bar's status facts (`hook-0`, `hook-1`, … in order).
local function dock_tree(chip: string, facts: { string }): any
	local extras = { id = "3.bar/extras", k = "row", c = {} :: { any } }
	for i, text in facts do
		table.insert(extras.c, { id = "3.bar/extras/hook-" .. tostring(i - 1), k = "text", p = { spans = { { t = text } } } })
	end
	local chip_node = { id = "3.bar/model", k = "row", p = { role = "omp.composer.model" }, c = { { id = "3.bar/model/name", k = "text", p = { spans = { { t = chip } } } } } }
	return { dock = { id = "dock", c = { { id = "3.bar", c = { extras, chip_node } } } } }
end

-- A window with one omp pane (or `opts.panes`), focused, showing `opts.chip` and `opts.facts`.
local function agent_window(opts: any?): any
	local o = opts or {}
	local w = H.world({ now = NOW, kv = H.kv_store(o.kv) })
	w.tern.runtime.os = "ios" -- keeps the updater's git timers off
	w.panes = o.panes or { { pane = 1, kind = "agent", tab = 1, cwd = "C:\\work", title = "omp" } }
	w.focused = o.focused or 1
	w.surfaces = o.surfaces or { [1] = dock_tree(o.chip or "Opus 5.5", o.facts or {}) }
	w.hosts = o.hosts
	w:load("window")
	return w
end

-- The widget bar's omp Usage segment for an agent pane.
local function widget(w: any): any
	local segments = w.status_formatter({ pane = 1, kind = "agent", program = "omp", busy = false, title = "omp" })
	return segments[#segments]
end

-- The line as the sheet draws it, its no-break spaces (which keep a window's parts together) read as spaces.
local function line_text(w: any): string?
	local content = string.match(w.sheets.usage or "", 'content: "([^"]*)"')
	return if content then (string.gsub(content, "\194\160", " ")) else nil
end

describe("the widget bar's segment", function()
	it("shows the tightest window", function()
		local w = agent_window()
		w:write_cache(F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.62, r7 = 0.41 }) }))
		w:advance(2000)
		eq({ widget(w).text, widget(w).tone }, { "Claude 41%", nil })
	end)

	it("turns warn at a quarter or less, error at a tenth or less, and muted while the numbers are old", function()
		local w = agent_window()
		w:write_cache(F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.2 }) }))
		w:advance(2000)
		eq({ widget(w).text, widget(w).tone }, { "Claude 20%", "warn" }, "20%")
		w:write_cache(F.doc(w.epoch_ms, { claude = F.claude(w.epoch_ms, { r5 = 0.09 }) }))
		w:advance(2000)
		eq({ widget(w).text, widget(w).tone }, { "Claude 9%", "error" }, "9%")
		w:write_cache(F.doc(w.epoch_ms, { observed = w.epoch_ms - 11 * F.M }))
		w:advance(2000)
		eq({ widget(w).text, widget(w).tone }, { "Claude 41%", "muted" }, "11 minutes old")
	end)

	it("says `usage` without data, and again once the line's pane closes", function()
		local w = agent_window()
		w:advance(2000)
		eq(widget(w).text, "usage", "no cache")
		w:write_cache(F.doc(w.epoch_ms))
		w:advance(2000)
		eq(widget(w).text, "Claude 41%", "data")
		for _, handler in w.handlers.pane_closed do
			handler({ pane = 1 }, w.cx)
		end
		eq(widget(w).text, "usage", "closed")
	end)

	it("shows the share the line shows (57% left reads 57%, not 56%)", function()
		local w = agent_window()
		w:write_cache(F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.57, r7 = 0.58, rf = 0.9 }) }))
		w:advance(2000)
		T.matches(line_text(w), "5H ━━━━━━━━ 57%% left", "the line")
		eq(widget(w).text, "Claude 57%", "the widget")
	end)
end)

describe("the line", function()
	it("follows a model switch within a poll", function()
		local doc = F.doc(NOW, { chips = { "Opus 5.5" } })
		local fable = F.claude(NOW, { r5 = 0.11, r7 = 0.12, rf = 0.13 })
		doc.models["Fable 5"] = F.model("anthropic", "Claude", fable, NOW)
		local w = agent_window()
		w:write_cache(doc)
		w:advance(1000)
		T.matches(line_text(w), "5H ━━━━━━━━ 62%% left", "Opus 5.5")
		w.surfaces[1] = dock_tree("Fable 5", {})
		w:advance(1000)
		T.matches(line_text(w), "5H ━━━━━━━━ 11%% left", "Fable 5, a second later")
	end)

	it("draws old numbers faint", function()
		local w = agent_window()
		w:write_cache(F.doc(NOW, { observed = NOW - 11 * F.M }))
		w:advance(1000)
		ok(string.find(w.sheets.usage or "", "r g b / 45%)", 1, true) ~= nil, "faded paint in the sheet")
	end)

	it("keeps polling after an error in a refresh, warning at most once a minute", function()
		local w = agent_window()
		w:write_cache(F.doc(NOW))
		local focused = w.cx.session.focused
		w.cx.session.focused = function(_self: any): number?
			error("surface gone")
		end
		w:advance(125000)
		local warnings = w:warnings()
		eq(#warnings, 3, "warnings in 125 s")
		T.matches(warnings[1], "the line's poll failed", "what they say")
		w.cx.session.focused = focused
		w:advance(1000)
		T.matches(line_text(w), "^Claude", "the line draws again")
	end)

	it("redraws when only the card's height changes", function()
		local now = NOW
		local accounts: { string } = {}
		local windows: { any } = {}
		for i = 1, 10 do
			local name = "acct" .. tostring(i)
			table.insert(accounts, name)
			table.insert(windows, F.win({ label = name .. " 5h", key = "5h", ms = 5 * F.H, r = 0.5 + i / 100, at = now + 2 * F.H, account = name }))
			table.insert(windows, F.win({ label = name .. " 7d", key = "7d", ms = 7 * F.D, r = 0.3 + i / 100, at = now + 3 * F.D, account = name }))
		end
		local doc = F.doc(now)
		doc.providers.anthropic = F.provider("anthropic", "Claude", windows, now, { accounts = accounts })
		doc.models["Opus 5.5"] = F.model("anthropic", "Claude", windows, now)
		local w = agent_window()
		w:write_cache(doc)
		w:advance(1000)
		local before = w.sheets.usage
		w.kv.set("omp-usage.card-rows", 16)
		w:advance(1000)
		ok(w.sheets.usage ~= before, "the sheet was rebuilt")
	end)

	it("redraws when Show pace changes", function()
		local w = agent_window()
		w:write_cache(F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.2, in5 = 2 * F.H }) }))
		w:advance(1000)
		ok(string.find(w.sheets.usage or "", "× pace", 1, true) ~= nil, "pace in the card")
		w.kv.set("omp-usage.show-pace", false)
		w:advance(1000)
		ok(string.find(w.sheets.usage or "", "× pace", 1, true) == nil, "no pace once off")
	end)

	it("says which accounts a combined view lacks on a note of its own, not as the provider's", function()
		local alice = {
			F.win({ label = "alice 5h", key = "5h", ms = 5 * F.H, r = 0.55, at = NOW + 2 * F.H, account = "alice" }),
			F.win({ label = "alice 7d", key = "7d", ms = 7 * F.D, r = 0.38, at = NOW + 3 * F.D, account = "alice" }),
		}
		local doc = F.doc(NOW)
		doc.providers.anthropic = F.provider("anthropic", "Claude", alice, NOW, { accounts = { "alice", "bob" } })
		local w = agent_window({ kv = { ["omp-usage.mode"] = "all", ["omp-usage.account"] = { anthropic = "\1combined" } } })
		w:write_cache(doc)
		w:advance(1000)
		local sheet = string.gsub(w.sheets.usage or "", "\194\160", " ")
		ok(string.find(sheet, "1 of 2 accounts · no current numbers for bob", 1, true) ~= nil, "the note in the card")
		ok(string.find(sheet, "Provider · 1 of 2 accounts", 1, true) == nil, "not labelled `Provider ·`")
	end)
end)

describe("status facts in omp's bar", function()
	it("hides the facts the line redraws in the focused pane, and draws other statuses on the line", function()
		local w = agent_window({ facts = { USAGE, OTHER } })
		w:write_cache(F.doc(NOW))
		w:advance(1000)
		local sheet = w.sheets.usage or ""
		ok(string.find(sheet, '.tn-pane.on [data-role=\'omp.composer.bar\'] [data-id="3.bar/extras/hook-0"]', 1, true) ~= nil, "usage fact hidden")
		T.matches(line_text(w), "demo: other extension$", "the other status ends the line")
	end)

	it("hides the extension's usage status in every agent pane while their lines come from the cache", function()
		local panes = { { pane = 1, kind = "agent", tab = 1, cwd = "C:\\work" }, { pane = 2, kind = "agent", tab = 1, cwd = "C:\\work" } }
		local surfaces = { [1] = dock_tree("Opus 5.5", { USAGE, OTHER }), [2] = dock_tree("Opus 5.5", { USAGE, OTHER }) }
		local w = agent_window({ panes = panes, surfaces = surfaces })
		w:write_cache(F.doc(NOW))
		w:advance(6000)
		eq(w.sheets["usage-facts"], ".tn-pane.agent [data-role='omp.composer.bar'] [data-id=\"3.bar/extras/hook-0\"] {\n\tdisplay: none !important;\n}\n", "usage hidden, the other status kept")
		w:write_cache(F.doc(w.epoch_ms, { observed = w.epoch_ms - 31 * F.M }))
		w:advance(6000)
		eq(w.sheets["usage-facts"], "", "the status is the line's fallback again: shown")
	end)

	it("keeps a remote pane's usage status, and its line on the status", function()
		local panes = { { pane = 1, kind = "agent", tab = 1, cwd = "C:\\work" }, { pane = 2, kind = "agent", tab = 1, cwd = "C:\\work" } }
		local surfaces = { [1] = dock_tree("Opus 5.5", { USAGE }), [2] = dock_tree("Opus 5.5", { USAGE }) }
		local hosts = {
			{ id = 0, name = "local", kind = "local", panes = { 1 }, sessions = {}, current = true, state = "connected" },
			{ id = 1, name = "box", kind = "remote", panes = { 2 }, sessions = {}, current = false, state = "connected" },
		}
		local w = agent_window({ panes = panes, surfaces = surfaces, hosts = hosts, focused = 2 })
		w:write_cache(F.doc(NOW))
		w:advance(6000)
		eq(w.sheets["usage-facts"], "", "nothing hidden across panes")
		T.matches(line_text(w), "5H ━━━━━━━━ 33%% left", "the remote pane's line is its status")
	end)
end)

describe("WSL panes", function()
	local function line_for(cwd: string): string?
		local w = agent_window({ panes = { { pane = 1, kind = "agent", tab = 1, cwd = cwd } }, facts = { USAGE } })
		w:write_cache(F.doc(NOW))
		w:advance(1000)
		return line_text(w)
	end

	it("read a Linux or \\\\wsl working directory as WSL and use the status", function()
		T.matches(line_for("/home/me/project"), "33%% left", "Linux path")
		T.matches(line_for("\\\\wsl.localhost\\Ubuntu\\home\\me"), "33%% left", "\\\\wsl.localhost")
		T.matches(line_for("\\\\wsl$\\Ubuntu\\home\\me"), "33%% left", "\\\\wsl$")
	end)

	it("read a Windows working directory as this machine and use the cache", function()
		T.matches(line_for("C:\\Users\\me\\project"), "62%% left", "drive path")
		T.matches(line_for(""), "62%% left", "unknown")
	end)
end)

return true -- run.mjs checks it: the Luau CLI's `require` returns a file's compile error instead of raising it
