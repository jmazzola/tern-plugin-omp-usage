--!strict
-- Display (the settings panel's section): the line's styles, where it sits, which parts show and whether shares are
-- said as left or used, from the settings in `tern.kv` through `build_model` to the line's text, its card and the
-- sheet that places it.
local T = require("./t")
local H = require("./harness")
local F = require("./fixtures")
local json = require("./json")

local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local NOW = 1795400000000
-- The line 0.8.0 drew for the usual three windows (the no-break spaces that keep a window together read as spaces).
local LINE = "Claude  5H ━━━━━━━━ 62% left  2h · 7D ━━━━━━━━ 41% left  3d 4h  +1 · FABLE 7D ━━━━━━━━ 83% left  3d 4h"
local OTHER = "demo: other extension"

local function plain(s: string): string
	return (string.gsub(s, "\194\160", " "))
end

-- A world with render.luau (and so data.luau) loaded, `kv` stored and `doc` read by the poll.
local function setup(kv: { [string]: any }?, doc: any?): (any, any, any)
	local w = H.world({ now = NOW, kv = H.kv_store(kv) })
	w.tern.runtime.os = "ios" -- keeps the updater's git timers off, for the tests that load pickers.luau
	local render = w:load("render")
	local data = w:load("data")
	w:write_cache(doc or F.doc(NOW))
	return w, data, render
end

-- The line (and its model and settings) for the model chip's pane, with `status` as the pane's status facts.
local function drawn(data: any, render: any, status: string?): (any, any, any)
	local settings = data.load_settings()
	local model = data.build_model(settings, F.dock("Opus 5.5", status), data.read_cache(data.now_ms()))
	return render.line_of(model, settings), model, settings
end

local function text_of(kv: { [string]: any }?, doc: any?, status: string?): string
	local _, data, render = setup(kv, doc)
	return plain(drawn(data, render, status).text)
end

local function has(s: string, part: string): boolean
	return string.find(s, part, 1, true) ~= nil
end

-- Claude and Codex, for All providers: five windows.
local function two_providers(now: number, claude: any?): any
	local codex = {
		F.win({ label = "5h", key = "5h", ms = 5 * F.H, r = 0.91, at = now + 3 * F.H, provider = "openai-codex" }),
		F.win({ label = "7d", key = "7d", ms = 7 * F.D, r = 0.58, at = now + 5 * F.D, provider = "openai-codex" }),
	}
	return F.doc(now, { claude = claude, extra_providers = { ["openai-codex"] = F.provider("openai-codex", "Codex", codex, now) } })
end
local ALL = { ["omp-usage.mode"] = "all", ["omp-usage.order"] = { "anthropic", "openai-codex" } }

local function with(base: { [string]: any }, more: { [string]: any }): { [string]: any }
	local out = table.clone(base)
	for key, value in more do
		out[key] = value
	end
	return out
end

describe("Display, settings kept from before it", function()
	it("draws the line as before for settings that never had Display's", function()
		local w, data, render = setup()
		local settings = data.load_settings()
		eq({ settings.style, settings.place, settings.align, settings.metric }, { "instrument", "above", "right", "left" }, "the defaults")
		eq(
			settings.parts,
			{ provider = true, window = true, bar = true, share = true, reset = true, saved = true, plan = false, others = true },
			"every part but the plan"
		)
		local line, model = drawn(data, render, nil)
		eq(plain(line.text), LINE, "the line")
		eq({ model.used, line.rows, #line.pills }, { false, nil, 0 }, "shares left, one row, no plan pill")
		eq(#w.kv.writes, 0, "reading the settings stores nothing")
	end)

	it("takes a stored value it doesn't know as the default", function()
		local _, data, render = setup({
			["omp-usage.style"] = "neon",
			["omp-usage.place"] = 7,
			["omp-usage.align"] = "middle",
			["omp-usage.metric"] = true,
			["omp-usage.line-parts"] = { bar = "no", plan = 1, nonsense = false },
		})
		local settings = data.load_settings()
		eq({ settings.style, settings.place, settings.align, settings.metric }, { "instrument", "above", "right", "left" })
		eq({ settings.parts.bar, settings.parts.plan, settings.parts.nonsense }, { true, false, nil }, "parts")
		eq(plain(drawn(data, render, nil).text), LINE, "the line")
	end)
end)

describe("Display, styles", function()
	it("Blocks fills whole blocks", function()
		local _, data, render = setup({ ["omp-usage.style"] = "blocks" })
		local line = drawn(data, render, nil)
		eq(plain(line.text), "Claude  5H ▰▰▰▰▰▱▱▱ 62% left  2h · 7D ▰▰▰▱▱▱▱▱ 41% left  3d 4h  +1 · FABLE 7D ▰▰▰▰▰▰▰▱ 83% left  3d 4h")
		eq({ line.bars[1].fill, line.bars[2].fill, line.bars[3].fill }, { 5, 3, 7 }, "each bar's tip stands after its last filled block")
	end)

	it("Blocks keeps one block while anything is left, and none at 0%", function()
		local doc = F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.004, r7 = 0 }) })
		T.matches(text_of({ ["omp-usage.style"] = "blocks" }, doc), "5H ▰▱▱▱▱▱▱▱ <1%% left", "<1%")
		T.matches(text_of({ ["omp-usage.style"] = "blocks" }, doc), "7D ▱▱▱▱▱▱▱▱ 0%% left", "0%")
	end)

	it("Ring puts a dial, in quarter steps, before each window, and has no bars", function()
		local _, data, render = setup({ ["omp-usage.style"] = "ring" })
		local line = drawn(data, render, nil)
		eq(plain(line.text), "Claude  ◑ 5H 62% left  2h · ◑ 7D 41% left  3d 4h  +1 · ◕ FABLE 7D 83% left  3d 4h")
		eq(#line.bars, 0, "no bars, so no tips or comets")
		local doc = F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.04, r7 = 0.13, rf = 0.97 }) })
		T.matches(text_of({ ["omp-usage.style"] = "ring" }, doc), "○ 5H 4%% left.*◔ 7D 13%% left.*● FABLE 7D 97%% left", "empty, a quarter, full")
	end)

	it("Compact is text only, without the word after a share", function()
		local _, data, render = setup({ ["omp-usage.style"] = "compact" })
		local line = drawn(data, render, nil)
		eq(plain(line.text), "Claude  5H 62%  2h · 7D 41%  3d 4h  +1 · FABLE 7D 83%  3d 4h")
		eq(#line.bars, 0, "no bars")
	end)

	it("keeps each style with several providers on the line", function()
		local function line(style: string): string
			return text_of(with(ALL, { ["omp-usage.style"] = style }), two_providers(NOW))
		end
		eq(line("instrument"), "Claude  5H ━━━━━━ 62%  7D ━━━━━━ 41% +1  FABLE 7D ━━━━━━ 83% · Codex  5H ━━━━━━ 91%  7D ━━━━━━ 58%", "as before")
		eq(line("blocks"), "Claude  5H ▰▰▰▰▱▱ 62%  7D ▰▰▱▱▱▱ 41% +1  FABLE 7D ▰▰▰▰▰▱ 83% · Codex  5H ▰▰▰▰▰▱ 91%  7D ▰▰▰▱▱▱ 58%")
		eq(line("ring"), "Claude  ◑ 5H 62%  ◑ 7D 41% +1  ◕ FABLE 7D 83% · Codex  ● 5H 91%  ◑ 7D 58%")
		eq(line("compact"), "Claude  5H 62%  7D 41% +1  FABLE 7D 83% · Codex  5H 91%  7D 58%")
	end)

	it("reads `reset` for a window whose reset has passed, in every style", function()
		local doc = F.doc(NOW, { claude = F.claude(NOW, { in5 = -F.M }) })
		for _, style in { "instrument", "blocks", "ring", "compact" } do
			T.matches(text_of({ ["omp-usage.style"] = style }, doc), "^Claude  5H reset · ", style)
		end
		T.matches(text_of({ ["omp-usage.place"] = "stack" }, doc), "^Claude  5H       reset\n", "stacked: where the bars start")
	end)

	it("draws old numbers faint in every style", function()
		local doc = F.doc(NOW, { observed = NOW - 11 * F.M })
		for _, style in { "instrument", "blocks", "ring", "compact" } do
			local _, data, render = setup({ ["omp-usage.style"] = style }, doc)
			local line = drawn(data, render, nil)
			ok(line.paints[1].dim == true, style .. ": faint text")
			ok(has(render.line_paint(line), "r g b / 45%)"), style .. ": faint paint")
		end
	end)
end)

describe("Display, shares left or used", function()
	it("says what's used on the line, 100 less what's left as it reads", function()
		local _, data, render = setup({ ["omp-usage.metric"] = "used" })
		local line, model = drawn(data, render, nil)
		eq(plain(line.text), "Claude  5H ━━━━━━━━ 38% used  2h · 7D ━━━━━━━━ 59% used  3d 4h  +1 · FABLE 7D ━━━━━━━━ 17% used  3d 4h")
		eq(model.used, true)
		T.near(line.bars[1].fill, 0.38 * 8, 1e-9, "the bar fills to what's used")
		T.near(line.bars[3].fill, 0.17 * 8, 1e-9, "the bar fills to what's used")
	end)

	it("reads `>99%` used where left reads `<1%`, and `100%` at nothing left", function()
		local doc = F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.004, r7 = 0, rf = 0.714 }) })
		eq(
			text_of(nil, doc),
			"Claude  5H ━━━━━━━━ <1% left  2h · 7D ━━━━━━━━ 0% left  3d 4h  +1 · FABLE 7D ━━━━━━━━ 71% left  3d 4h",
			"left: rounded down, as the extension writes it"
		)
		eq(
			text_of({ ["omp-usage.metric"] = "used" }, doc),
			"Claude  5H ━━━━━━━━ >99% used  2h · 7D ━━━━━━━━ 100% used  3d 4h  +1 · FABLE 7D ━━━━━━━━ 29% used  3d 4h",
			"used: the two always add up to 100"
		)
		eq(
			text_of({ ["omp-usage.metric"] = "used", ["omp-usage.style"] = "compact" }, doc),
			"Claude  5H >99% used  2h · 7D 100% used  3d 4h  +1 · FABLE 7D 29% used  3d 4h",
			"Compact keeps `used`: a bare share reads as what's left"
		)
		eq(text_of({ ["omp-usage.style"] = "compact" }, doc), "Claude  5H <1%  2h · 7D 0%  3d 4h  +1 · FABLE 7D 71%  3d 4h", "Compact, left: as it was")
	end)

	it("names an account that has no windows by what its source says about it, not a bare heading", function()
		local alice = {
			F.win({ label = "alice 5h", key = "5h", ms = 5 * F.H, r = 0.64, at = NOW + 2 * F.H, account = "alice" }),
			F.win({ label = "alice 7d", key = "7d", ms = 7 * F.D, r = 0.41, at = NOW + 3 * F.D, account = "alice" }),
		}
		local function card_for(bob: { any }): { string }
			local doc = F.doc(NOW)
			local details = { { text = "Plan: Max", kind = "plan", valueText = "Max", account = "alice" }, { text = "Plan: Pro", kind = "plan", valueText = "Pro", account = "bob" } }
			for _, detail in bob do
				table.insert(details, detail)
			end
			doc.providers.anthropic = F.provider("anthropic", "Claude", alice, NOW, { accounts = { "alice", "bob" }, details = details })
			local _, data, render = setup({ ["omp-usage.mode"] = "all" }, doc)
			local _, model, settings = drawn(data, render, nil)
			local texts: { string } = {}
			for _, row in render.card(model, "hint", settings.card_rows) do
				table.insert(texts, row.text)
			end
			return texts
		end
		local observed = { text = "Observed 2026-11-27 01:34 UTC", kind = "observed", valueText = "2026-11-27 01:34 UTC", account = "bob" }
		local seen = card_for({ observed })
		local at = table.find(seen, "bob")
		ok(at ~= nil, "bob's heading")
		eq(seen[(at :: number) + 1], "  Observed 2026-11-27 01:34 UTC", "when nothing else is said: when it was observed")
		local stale = card_for({ observed, { text = "Stale Keeper snapshot: Keeper hasn't refreshed this quota recently", kind = "stale", account = "bob" } })
		at = table.find(stale, "bob")
		eq(
			{ stale[(at :: number) + 1], stale[(at :: number) + 2] },
			{ "  Stale Keeper snapshot: Keeper hasn't", "  refreshed this quota recently" },
			"its stale note first, on as many rows as it takes"
		)
		ok(table.find(stale, "  Observed 2026-11-27 01:34 UTC") == nil, "and once")
	end)

	it("marks where a line too wide for its pane wraps, and lets only its first window break, between parts", function()
		local _, data, render = setup()
		local line, model, settings = drawn(data, render, nil)
		-- `Claude  5H ━━━━━━━━ 62% left  2h · 7D …`: the first window's parts, then a break before each `·`
		local ats = {}
		for _, mark in line.marks do
			table.insert(ats, mark.at)
		end
		eq(ats, { 6, 10, 19, 28, 32, 66 }, "after Claude, 5H, its bar, its share, its countdown, and the 7D window")
		eq({ line.marks[1].ends, line.marks[5].ends, line.marks[6].ends }, { 10, 66, line.glyphs }, "each with where what follows ends")
		ok(has(line.text, "Claude  5H ━━━━━━━━ 62%\194\160left  2h ·\194\1607D\194\160━"), "plain spaces in the first window, no-break ones in the rest")
		eq(line.bars[1].ends, 19, "the first bar's tip goes with its bar")
		local sheet = render.sheet(model, settings, nil, "hint")
		ok(
			has(sheet, "194px 9px") and has(sheet, "min(clamp(0px, calc((100% - 203.75px) * 1000), 8px), clamp(0px, calc((407.75px - 100%) * 1000), 8px)) 2px"),
			"three dots after the first window, while it fits (with their room) and the second, ending at glyph 66, doesn't"
		)
		ok(has(sheet, "::before {\n\tpadding-right: clamp(0px, calc((611.5px - 100%) * 1000), 12px);\n}"), "in room the line keeps free at its end while it doesn't fit whole")
		ok(has(sheet, "\n\tpadding-right: clamp(0px, calc((611.5px - calc(100% - 12px)) * 1000), 12px);"), "the hover's copy too")
	end)

	it("gives a pane too narrow for the first window's share a narrow copy, so the share is the last thing lost", function()
		local _, data, render = setup()
		local line, model, settings = drawn(data, render, nil)
		eq(line.need, 28, "`Claude  5H ━━━━━━━━ 62% left`: the first window has its share by glyph 28")
		local short = line.short
		eq(plain(short.text), "5H 62% · 7D 41% +1", "the shares alone, unnamed, up to the last window that could show")
		eq({ line.from, short.to }, { 180, 180 }, "the line from the width its share needs (with the dots' room), the copy under it")
		eq(short.marks, { { at = 6, ends = 18 }, { at = 18, ends = 33 } }, "its windows wrap away whole, and dots follow the last")
		ok(has(short.text, "5H\194\16062% ·\194\1607D"), "its first window stays whole")
		local sheet = render.sheet(model, settings, nil, "hint")
		ok(has(sheet, "\tbackground-size: clamp(0px, calc((100% - 179.75px) * 1000000), 100000px) 100%;"), "the line's paint goes under that width")
		ok(has(sheet, '::after {\n\tcontent: "5H\194\16062% ·\194\1607D\194\16041%\194\160+1";\n\toverflow: hidden;\n\twhite-space: pre-wrap;'), "the copy is the tips' layer's text")
		ok(has(sheet, "clamp(0px, calc((179.75px - 100%) * 1000000), 100000px) 13px"), "painted under it")
		ok(has(sheet, '\n\tcontent: "5H\194\16062% ·\194\1607D\194\16041%\194\160+1\\A Claude  5H'), "the hover's copy has both, a row each")
		ok(has(sheet, "padding-top: clamp(0px, calc((191.75px - 100%) * 1000), 15px);"), "and moves the narrow one into view under the same width")
		-- bars' tips go with the line
		ok(has(sheet, "clamp(0px, calc((100% - 179.75px) * 1000), 10px) 6px"), "the first bar's tip shows from that width up")
		-- nothing to fall back to: a line whose first window is as short as it gets, a stacked line, the panel's preview
		local _, data2, render2 = setup({ ["omp-usage.style"] = "compact", ["omp-usage.line-parts"] = { provider = false } })
		eq(drawn(data2, render2, nil).short, nil, "`5H 62%` is the copy already")
		local _, data3, render3 = setup({ ["omp-usage.place"] = "stack" })
		eq(drawn(data3, render3, nil).short, nil, "Stacked rows don't wrap")
		eq(render.line_of(model, settings, true).short, nil, "the preview draws the line itself")
	end)

	it("keeps the narrow copy under a change's comets", function()
		local w, data, render = setup()
		local line, model, settings = drawn(data, render, nil)
		local sheet = render.sheet(model, settings, { seq = 3, until_ms = w.tern.now() + 1000, moved = { [line.bars[1].key] = "down" } }, "hint")
		ok(has(sheet, "@keyframes omp-usage-run-3 {"), "the comets run")
		-- the tips' layer's text is the copy, and its paint the one layer clipped to it, in every frame
		local copy_paint = "linear-gradient(90deg, rgb(from var(--ou-lbl) r g b) 0em 1.2em, "
		ok(has(sheet, "\t0% { background-image: " .. copy_paint), "first in the first frame")
		ok(has(sheet, "\t100% { background-image: " .. copy_paint), "and the last")
		ok(has(sheet, "linear 1 both;\n\tbackground-clip: text, border-box, border-box"), "clipped to the text, the comets not")
	end)

	it("keeps a `;` (and what else a sheet could trip on) in a status and in a source's note as text", function()
		local note = "Stale Keeper snapshot: Keeper hasn't refreshed this quota recently; turn on its scheduled quota refresh"
		local status = 'lint: 2 errors; "strict" {x} /* y */ a\\b'
		local doc = F.doc(NOW)
		doc.models["Opus 5.5"].details = json.array({ { text = note, kind = "stale" } })
		local _, data, render = setup(nil, doc)
		local line, model, settings = drawn(data, render, status)
		ok(has(plain(line.text), " · " .. status), "the status on the line as it came")
		local sheet = render.sheet(model, settings, nil, "hint")
		ok(has(sheet, 'lint:\194\1602\194\160errors;\194\160\\"strict\\"\194\160{x}\194\160/*\194\160y\194\160*/\194\160a\\\\b"'), "in the line's string: only the quote and the backslash escaped")
		ok(has(sheet, "\\A   refreshed this quota recently; turn on its\\A "), "the note's `;` in the card's string")
		ok(has(sheet, '\\A lint: 2 errors; \\"strict\\" {x} /* y */ a\\\\b\\A '), "and the status's")
		table.insert(model.others, "one\ntwo\tthree")
		ok(has(render.line_of(model, settings).text, "one\ntwo"), "(a line break in a status)")
		ok(has(render.sheet(model, settings, nil, "hint2"), "one two three"), "a control character reads as a space: it would end the string")
	end)

	it("puts a source's long note on several rows of the card, and whole in the quota details", function()
		local note = "Stale Keeper snapshot: Keeper hasn't refreshed this quota recently; turn on its scheduled quota refresh"
		local doc = F.doc(NOW)
		doc.models["Opus 5.5"].details = json.array({ { text = note, kind = "stale" } })
		local _, data, render = setup(nil, doc)
		local _, model, settings = drawn(data, render, nil)
		local texts: { string } = {}
		for _, row in render.card(model, "hint", settings.card_rows) do
			ok(#row.text <= 46, "no row wider than the card usually is: " .. row.text)
			table.insert(texts, row.text)
		end
		local at = table.find(texts, "  Stale Keeper snapshot: Keeper hasn't")
		ok(at ~= nil, "the note's first row")
		eq(
			{ texts[(at :: number) + 1], texts[(at :: number) + 2] },
			{ "  refreshed this quota recently; turn on its", "  scheduled quota refresh" },
			"and the rest of it, to its end"
		)
		local whole = false
		for _, row in render.card(model, "", settings.card_rows, "details") do
			whole = whole or row.text == "  " .. note
		end
		ok(whole, "the quota details keep the source's text as it came")
	end)

	it("reads a note an older extension broke into rows as the one note it was", function()
		-- 0.8's extension wrapped at 67 characters and dropped the kind: the Keeper note broke right after its `;`
		local doc = F.doc(NOW)
		doc.models["Opus 5.5"].details = json.array({
			{ text = "Plan: Max", kind = "plan", valueText = "Max" },
			{ text = "Stale Keeper snapshot: Keeper hasn't refreshed this quota recently;" },
			{ text = "turn on its scheduled quota refresh" },
			{ text = "Balance: 12 credits" },
			{ text = "Requests: 40" },
		})
		local _, data = setup(nil, doc)
		local texts: { string } = {}
		for _, detail in data.read_cache(data.now_ms()).models["Opus 5.5"].details do
			table.insert(texts, detail.text)
		end
		eq(
			texts,
			{
				"Plan: Max",
				"Stale Keeper snapshot: Keeper hasn't refreshed this quota recently; turn on its scheduled quota refresh",
				"Balance: 12 credits",
				"Requests: 40",
			},
			"the two halves joined; short rows stay apart"
		)
	end)

	it("keeps the hover card inside its pane: capped at the target's room, its text shrinking to fit", function()
		local _, data, render = setup()
		local line, model, settings = drawn(data, render, nil)
		local sheet = render.sheet(model, settings, nil, "details Alt+Shift+U · settings Ctrl+Alt+U")
		ok(has(sheet, "\n\tmax-width: calc(100% + 12px);\n\toverflow: hidden;\n\ttext-fit: shrink consistent;"), "a line longer than its card: the target is as wide as the pane's room when that is less")
		ok(has(sheet, "\twidth: min(624px, calc(100% - 32px));"), "(its target, as before)")
		-- a line shorter than its card: in a pane too narrow for the card its target takes the room, so the card can tell
		local _, data2, render2 = setup({ ["omp-usage.style"] = "compact", ["omp-usage.line-parts"] = { provider = false, reset = false, saved = false } })
		local short_line, model2, settings2 = drawn(data2, render2, nil)
		eq(plain(short_line.text), "5H 62% · 7D 41% · FABLE 7D 83%")
		local sheet2 = render2.sheet(model2, settings2, nil, "details Alt+Shift+U · settings Ctrl+Alt+U")
		ok(
			has(sheet2, "\twidth: calc(min(max(192px, clamp(0px, calc((282.35px - calc(100% - 32px)) * 100000), 282.35px)), calc(100% - 32px)) - clamp(0px, calc((1px - max(calc(100% - 32px) - 192px, 192px - calc(100% - 32px))) * 1000), 2px));"),
			"the target: its line's width, or the room in a pane with less than the card needs"
		)
		ok(
			has(sheet2, "\n\tmax-width: calc(100% + 12px + clamp(0px, calc((0.5px - max(100% - 192px, 192px - 100%)) * 100000), 100000px));"),
			"the card: no cap while the target is its line's width"
		)
		ok(not has(render2.card_css(render2.card(model2, "hint", settings2.card_rows), ".preview"), "max-width"), "the panel's preview is never capped")
		eq(line.glyphs, 102)
	end)

	it("says it the same way in the card and the quota details, toned by what's left", function()
		local doc = F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.08 }) })
		local _, data, render = setup({ ["omp-usage.metric"] = "used" }, doc)
		local line, model, settings = drawn(data, render, nil)
		local rows = render.card(model, "hint", settings.card_rows)
		eq({ rows[2].text, rows[2].right, rows[2].color }, { "5-hour window", "92% used", "var(--oc-win-bad)" }, "the card's row")
		T.near(rows[2].share, 0.92, 1e-9, "its meter fills to what's used")
		local details = render.card(model, "", settings.card_rows, "details")
		local found = false
		for _, row in details do
			found = found or (row.text == "Weekly window" and row.right == "59% used")
		end
		ok(found, "the quota details' row")
		ok(has(render.line_paint(line), "var(--ou-num-bad)"), "the line's share is red at 8% left")
		ok(has(render.palette_css(model, settings), "--ou-ring: rgb(from var(--bad)"), "the capsule's ring follows what's left")
	end)

	it("keeps `reset` for a passed window, and the signature apart", function()
		local doc = F.doc(NOW, { claude = F.claude(NOW, { in5 = -F.M }) })
		T.matches(text_of({ ["omp-usage.metric"] = "used" }, doc), "^Claude  5H reset · 7D ━━━━━━━━ 59%% used", "used")
		local _, data = setup()
		local left = data.build_model(data.load_settings(), F.dock("Opus 5.5", nil), data.read_cache(data.now_ms()))
		local settings = data.load_settings()
		settings.metric = "used"
		local used = data.build_model(settings, F.dock("Opus 5.5", nil), data.read_cache(data.now_ms()))
		ok(left.signature ~= used.signature, "a change of Shares redraws the line, the card and the details")
		eq({ data.share_word(left), data.share_word(used) }, { "left", "used" })
	end)
end)

describe("Display, On the line", function()
	local function without(part: string, status: string?): string
		return text_of({ ["omp-usage.line-parts"] = { [part] = false } }, nil, status)
	end

	it("takes each part off the line", function()
		eq(without("provider"), "5H ━━━━━━━━ 62% left  2h · 7D ━━━━━━━━ 41% left  3d 4h  +1 · FABLE 7D ━━━━━━━━ 83% left  3d 4h", "provider")
		eq(without("window"), "Claude  ━━━━━━━━ 62% left  2h · ━━━━━━━━ 41% left  3d 4h  +1 · ━━━━━━━━ 83% left  3d 4h", "window")
		eq(without("bar"), "Claude  5H 62% left  2h · 7D 41% left  3d 4h  +1 · FABLE 7D 83% left  3d 4h", "bar")
		eq(without("share"), "Claude  5H ━━━━━━━━  2h · 7D ━━━━━━━━  3d 4h  +1 · FABLE 7D ━━━━━━━━  3d 4h", "share")
		eq(without("reset"), "Claude  5H ━━━━━━━━ 62% left · 7D ━━━━━━━━ 41% left  +1 · FABLE 7D ━━━━━━━━ 83% left", "countdown")
		eq(without("saved"), "Claude  5H ━━━━━━━━ 62% left  2h · 7D ━━━━━━━━ 41% left  3d 4h · FABLE 7D ━━━━━━━━ 83% left  3d 4h", "saved resets")
		eq(text_of(nil, nil, OTHER), LINE .. " · " .. OTHER, "other statuses, on")
		eq(without("others", OTHER), LINE, "other statuses, off")
	end)

	it("keeps a window's bar or its share: with neither on, it shows its share", function()
		local _, data, render = setup({ ["omp-usage.line-parts"] = { bar = false, share = false } })
		local shown = data.line_parts(data.load_settings())
		eq({ shown.bar, shown.share }, { false, true }, "the share stands in")
		eq(plain(drawn(data, render, nil).text), "Claude  5H 62% left  2h · 7D 41% left  3d 4h  +1 · FABLE 7D 83% left  3d 4h")
		-- Compact draws no bar, so its share stays whatever is stored
		eq(text_of({ ["omp-usage.style"] = "compact", ["omp-usage.line-parts"] = { share = false } }), "Claude  5H 62%  2h · 7D 41%  3d 4h  +1 · FABLE 7D 83%  3d 4h", "Compact")
		eq(text_of({ ["omp-usage.style"] = "ring", ["omp-usage.line-parts"] = { share = false } }), "Claude  ◑ 5H  2h · ◑ 7D  3d 4h  +1 · ◕ FABLE 7D  3d 4h", "Ring: the dial is its bar")
	end)

	it("won't switch off the last of a window's bar and share, nor Compact's bar", function()
		local w, data = setup({ ["omp-usage.line-parts"] = { bar = false } })
		local pickers = w:load("pickers")
		eq(pickers.toggle_part("share"), false, "the share is all that's left of the window")
		eq(w.kv.raw("omp-usage.line-parts"), '{"bar":false}', "nothing stored")
		eq(pickers.toggle_part("bar"), true, "the bar comes back")
		eq(pickers.toggle_part("share"), true, "and then the share can go")
		eq(data.load_settings().parts.share, false)
		eq(pickers.toggle_part("nonsense"), false, "an unknown part")
		w.kv.set("omp-usage.style", "compact")
		eq(pickers.toggle_part("bar"), false, "Compact has no bar to switch")
	end)

	it("stores only the parts switched from their default", function()
		local w = setup()
		local pickers = w:load("pickers")
		eq(pickers.toggle_part("plan"), true)
		eq(pickers.toggle_part("reset"), true)
		eq(json.decode(w.kv.raw("omp-usage.line-parts") :: string), { plan = true, reset = false })
		eq(pickers.toggle_part("plan"), true)
		eq(json.decode(w.kv.raw("omp-usage.line-parts") :: string), { reset = false }, "back at its default")
	end)

	it("rides the plan after its provider as a pill, off unless switched on", function()
		local doc = F.doc(NOW)
		doc.models["Opus 5.5"].details = json.array({ { text = "Plan Max 20x", kind = "plan", valueText = "Max 20x" } })
		local _, data, render = setup({ ["omp-usage.line-parts"] = { plan = true } }, doc)
		local line = drawn(data, render, nil)
		T.matches(plain(line.text), "^Claude  Max 20x   5H ━━━━━━━━ 62%% left", "the plan between the provider and its first window")
		eq(#line.pills, 1, "one pill")
		eq({ line.pills[1].at, line.pills[1].glyphs, line.pills[1].row }, { 7, 9, 0 }, "around the plan and a space either side")
		ok(#render.tips(line, 55).images > 3, "drawn with the tips")
		eq(text_of(nil, doc), LINE, "off by default: the card has it either way")
	end)

	it("still says what is wrong with the cache file with Other statuses off", function()
		local _, data, render = setup({ ["omp-usage.line-parts"] = { others = false } })
		local settings = data.load_settings()
		local model = data.build_model(settings, F.dock("Opus 5.5", OTHER), data.read_cache(data.now_ms()))
		table.insert(model.others, "usage cache too big to read (1.1 MB)")
		model.trouble = "usage cache too big to read (1.1 MB)"
		eq(plain(render.line_of(model, settings).text), LINE .. " · usage cache too big to read (1.1 MB)")
		settings.place = "stack"
		T.matches(render.line_of(model, settings).text, "\nusage cache too big to read %(1.1 MB%)$", "stacked")
	end)

	it("draws nothing, and no sheet, when all it could show is switched off", function()
		local _, data, render = setup({ ["omp-usage.line-parts"] = { others = false } }, F.doc(NOW, { observed = NOW - 31 * F.M }))
		local settings = data.load_settings()
		local model = data.build_model(settings, F.dock("Opus 5.5", OTHER), data.read_cache(data.now_ms()))
		eq({ #model.groups, model.others }, { 0, { OTHER } }, "only another extension's status")
		eq(render.sheet(model, settings, nil, "hint"), "", "no sheet")
		eq(data.redrawn_facts(F.dock("Opus 5.5", OTHER, { hide = { "hook-0" }, texts = { ["hook-0"] = OTHER } }), settings), {}, "and the status stays in omp's bar")
	end)
end)

describe("Display, Stacked", function()
	local STACK = { ["omp-usage.place"] = "stack" }

	it("gives each window a row, its columns lined up", function()
		local _, data, render = setup(STACK)
		local line = drawn(data, render, nil)
		eq(line.text, table.concat({
			"Claude  5H                62% left  2h",
			"        7D                41% left  3d 4h  +1",
			"        FABLE 7D          83% left  3d 4h",
		}, "\n"), "Instrument: blank glyphs where its bars are drawn")
		eq(#line.rows, 3, "rows")
		eq(line.glyphs, 45, "as wide as its longest row")
		eq(render.line_height(line), 43, "three rows, 15px apart")
		local bars = {}
		for _, bar in line.bars do
			table.insert(bars, { bar.at, bar.row, bar.boxed })
		end
		eq(bars, { { 17, 0, true }, { 17, 1, true }, { 17, 2, true } }, "a boxed bar per row, in one column")
		eq(line.rows[1].color, "var(--ou-num-ok)", "a row takes its window's tone")
	end)

	it("repeats a provider, faint, on its other rows, so every row starts at the same column", function()
		for _, style in { "instrument", "blocks", "ring", "compact" } do
			local _, data, render = setup(with(STACK, { ["omp-usage.style"] = style }))
			local line, model, settings = drawn(data, render, OTHER)
			eq(line.ghosts, { "", "Claude", "Claude", "" }, style .. ": on the rows after its first, none on another status's")
			T.matches(line.rows[2].text, "^        %S", style .. ": the row's own text keeps the blanks they are drawn in")
			T.matches(line.hovered[2], "^Claude  %S", style .. ": the hover's copy has them in")
			eq(line.hovered[1], line.rows[1].text, style .. ": the first row as it is")
			local sheet = render.sheet(model, settings, nil, "hint")
			ok(has(sheet, '::after {\n\tcontent: "\\A Claude\\A Claude\\A ";\n\toverflow: hidden;\n\twhite-space: pre;\n\tfont: 500 10px/15px var(--mono);\n\tcolor: var(--t4);'), style .. ": drawn faint on the tips' layer")
			ok(has(sheet, "position: absolute;\n\tcontent: \"Claude  "), style .. ": the hover's copy")
		end
	end)

	it("repeats nothing with Provider switched off, nor on a single line", function()
		local _, data, render = setup(with(STACK, { ["omp-usage.line-parts"] = { provider = false } }))
		local line = drawn(data, render, nil)
		eq({ line.ghosts, line.hovered }, { nil, nil }, "Provider off: as before")
		T.matches(line.text, "^5H .-\n7D .-\nFABLE 7D ", "its rows start with their windows")
		local _, data2, render2 = setup()
		local single, model, settings = drawn(data2, render2, nil)
		eq(single.ghosts, nil, "Above the bar")
		ok(has(render2.sheet(model, settings, nil, "hint"), '::after {\n\tcontent: "5H\194\16062% ·\194\1607D'), "its tips' layer has its narrow copy for text, no repeats")
	end)

	it("repeats an account under its provider, and the provider before each further account", function()
		local seats = {
			F.win({ label = "alice 5h", key = "5h", ms = 5 * F.H, r = 0.55, at = NOW + 2 * F.H, account = "alice" }),
			F.win({ label = "alice 7d", key = "7d", ms = 7 * F.D, r = 0.38, at = NOW + 3 * F.D, account = "alice" }),
			F.win({ label = "bob 5h", key = "5h", ms = 5 * F.H, r = 0.9, at = NOW + 2 * F.H, account = "bob" }),
		}
		local doc = F.doc(NOW)
		doc.providers.anthropic = F.provider("anthropic", "Claude", seats, NOW, { accounts = { "alice", "bob" } })
		local _, data, render = setup(with(STACK, { ["omp-usage.mode"] = "all" }), doc)
		local line = drawn(data, render, nil)
		eq(line.ghosts, { "", "Claude alice", "Claude" }, "what each row repeats")
		T.matches(line.rows[1].text, "^Claude alice  5H", "the first row names both")
		T.matches(line.rows[2].text, "^              7D", "alice's second window")
		T.matches(line.rows[3].text, "^       bob    5H", "bob, under alice")
		T.matches(line.hovered[3], "^Claude bob    5H", "hovered")
	end)

	it("draws each style's rows", function()
		eq(text_of(with(STACK, { ["omp-usage.style"] = "blocks" })), table.concat({
			"Claude  5H       ▰▰▰▰▰▱▱▱ 62% left  2h",
			"        7D       ▰▰▰▱▱▱▱▱ 41% left  3d 4h  +1",
			"        FABLE 7D ▰▰▰▰▰▰▰▱ 83% left  3d 4h",
		}, "\n"), "Blocks")
		eq(text_of(with(STACK, { ["omp-usage.style"] = "ring" })), table.concat({
			"Claude  ◑ 5H       62% left  2h",
			"        ◑ 7D       41% left  3d 4h  +1",
			"        ◕ FABLE 7D 83% left  3d 4h",
		}, "\n"), "Ring")
		eq(text_of(with(STACK, { ["omp-usage.style"] = "compact" })), table.concat({
			"Claude  5H       62%  2h",
			"        7D       41%  3d 4h  +1",
			"        FABLE 7D 83%  3d 4h",
		}, "\n"), "Compact")
	end)

	it("lines shares up to the right, used or left", function()
		local doc = F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.004, r7 = 0.05 }) })
		eq(text_of(with(STACK, { ["omp-usage.style"] = "compact" }), doc), table.concat({
			"Claude  5H       <1%  2h",
			"        7D        5%  3d 4h  +1",
			"        FABLE 7D 83%  3d 4h",
		}, "\n"), "left")
		eq(text_of(with(STACK, { ["omp-usage.style"] = "compact", ["omp-usage.metric"] = "used" }), doc), table.concat({
			"Claude  5H       >99% used  2h",
			"        7D        95% used  3d 4h  +1",
			"        FABLE 7D  17% used  3d 4h",
		}, "\n"), "used")
	end)

	it("past four rows, sums up the rest in the last one: `+N more · lowest …`", function()
		local _, data, render = setup(with(ALL, STACK), two_providers(NOW))
		local settings = data.load_settings()
		local function stacked(status: string?): any
			return render.line_of(data.build_model(settings, F.dock("Opus 5.5", status), data.read_cache(data.now_ms())), settings)
		end
		local line = stacked(nil)
		eq(#line.rows, 4, "five windows in four rows")
		eq(line.rows[4].text, "+2 more · lowest 7D 58%", "Codex's two windows")
		eq(line.rows[4].color, "var(--ou-soft)", "nothing low among them")
		T.matches(line.rows[3].text, "FABLE 7D", "the first three stay")
		eq(stacked(OTHER).rows[4].text, "+3 more · lowest 7D 58%", "another extension's status counts too")
		settings.metric = "used"
		eq(stacked(nil).rows[4].text, "+2 more · most used 7D 42%", "used")
	end)

	it("tones the last row by the lowest window it sums up", function()
		local doc = two_providers(NOW)
		doc.providers["openai-codex"] = F.provider("openai-codex", "Codex", {
			F.win({ label = "5h", key = "5h", ms = 5 * F.H, r = 0.004, at = NOW + 3 * F.H, provider = "openai-codex" }),
			F.win({ label = "7d", key = "7d", ms = 7 * F.D, r = 0.58, at = NOW + 5 * F.D, provider = "openai-codex" }),
		}, NOW)
		local _, data, render = setup(with(ALL, STACK), doc)
		local line = drawn(data, render, nil)
		eq({ line.rows[4].text, line.rows[4].color }, { "+2 more · lowest 5H <1%", "var(--ou-num-bad)" })
	end)

	it("keeps four rows as they are", function()
		local _, data, render = setup(STACK)
		local line = drawn(data, render, OTHER)
		eq(#line.rows, 4, "three windows and another extension's status")
		eq({ line.rows[4].text, line.rows[4].color }, { OTHER, "var(--ou-soft)" })
	end)

	it("draws old numbers' rows faint", function()
		local _, data, render = setup(STACK, F.doc(NOW, { observed = NOW - 11 * F.M }))
		local line = drawn(data, render, nil)
		eq({ line.rows[1].dim, line.bars[1].dim }, { true, true })
		ok(has(render.line_paint(line), "rgb(from var(--ou-num-ok) r g b / 45%) 0px 15px"), "the first row's paint")
	end)
end)

describe("Display, where the line sits", function()
	local EDITOR = ".sf-col[data-role^='omp.editor']"
	local function sheet_of(kv: { [string]: any }?): string
		local _, data, render = setup(kv)
		local _, model, settings = drawn(data, render, nil)
		return render.sheet(model, settings, nil, "hint")
	end

	it("Above the bar: room over every composer, and the line lifted clear of the context bar's labels", function()
		local sheet = sheet_of(nil)
		ok(has(sheet, ".sf-dock " .. EDITOR .. " {\n\tmargin-top: 18px;\n}"), "the room")
		ok(has(sheet, ":not(:last-child) {\n\tmargin-bottom: 12px;\n}"), "another block above keeps clear")
		ok(has(sheet, "top: auto;\n\tbottom: 100%;\n\tmargin-bottom: 5px;"), "the line over the meter")
		ok(has(sheet, "top: -31px;"), "the hover target over it")
		ok(has(sheet, "height: 13px;") and has(sheet, "white-space: pre-wrap;"), "one row")
	end)

	it("Under the bar: the input moves down instead, outside Spine and the tray", function()
		local sheet = sheet_of({ ["omp-usage.place"] = "below" })
		ok(not has(sheet, ".sf-dock " .. EDITOR .. " {\n\tmargin-top"), "no room over every composer")
		ok(has(sheet, ".sf-dock.sf-chat-spine:not(.sf-tray-ctx) " .. EDITOR .. " {\n\tmargin-top: 18px;\n}"), "Spine keeps its room under the hairline")
		-- over Tern's agents tray the meter is lifted above the tray's cards: the line stays under it, the cards a line lower
		ok(has(sheet, ".sf-dock.sf-tray-ctx > .sf-col.sf-tray {\n\tpadding-top: 20px;\n}"), "the tray's cards move down a line, and 2px for the capsule's rim")
		ok(not has(sheet, ".sf-col.sf-tray {\n\tmargin-top"), "no room above the tray")
		ok(has(sheet, ".sf-tray-ctx .sf-meter[data-role='omp.composer.context']::after {\n\tleft: 0;\n\tright: 0;\n\ttop: calc(100% + 4px);\n\tbottom: auto;\n\tmargin-bottom: 0;\n}"), "the line under the lifted meter")
		ok(has(sheet, "top: calc(5px - var(--sf-tray-lift, 0px));"), "and its hover target with it")
		local above = sheet_of(nil)
		ok(has(above, ".sf-dock.sf-tray-ctx > .sf-col.sf-tray {\n\tmargin-top: 18px;\n}") and has(above, "top: calc(-31px - var(--sf-tray-lift, 0px));"), "Above the bar: over the lifted meter, as before")
		ok(has(sheet, ".sf-dock.sf-chat-reader:not(.sf-chat-spine):not(.sf-tray-ctx) " .. EDITOR .. " {\n\tpadding-top: 28px;\n}"), "Reader's input, a line lower")
		ok(has(sheet, ".sf-dock.sf-chat-console:not(.sf-chat-spine):not(.sf-tray-ctx) " .. EDITOR .. " {\n\tpadding-top: 22px;\n}"), "Console's")
		ok(has(sheet, "left: 0;\n\tright: 0;\n\ttop: calc(100% + 4px);\n\tbottom: auto;\n\tmargin-bottom: 0;"), "the line under the meter")
		ok(has(sheet, ":not(:last-child) {\n\tmargin-bottom: 12px;\n}"), "another block above still clears the context bar's labels")
	end)

	it("Stacked: a block as tall as its rows, and what omp shows above the composer clear of all of it", function()
		local sheet = sheet_of({ ["omp-usage.place"] = "stack" })
		ok(has(sheet, "height: 43px;") and has(sheet, "white-space: pre;"), "three rows")
		ok(has(sheet, "62% left  2h\\A "), "a row a line")
		ok(has(sheet, "left: auto;\n\tright: 0;\n\twidth: 270px;\n\tmax-width: 100%;"), "at the meter's right end, no wider than it")
		ok(has(sheet, ":not(:last-child) {\n\tmargin-bottom: 42px;\n}"), "another block above: 12px and the two rows more")
		ok(has(sheet, ".sf-dock:not(.sf-chat-spine) > .sf-row[data-role='omp.hud.activity'],"), "the working row too")
		ok(has(sheet, "margin-bottom: 36px;"), "by the two rows more")
		ok(has(sheet, ".sf-dock.sf-chat-spine:not(.sf-tray-ctx) > .sf-row[data-role='omp.hud.activity'] {\n\tmargin-bottom: 55px;\n}"), "Spine has no room above its hairline")
		ok(has(sheet_of(nil), ".sf-chat-spine :is(") and has(sheet_of(nil), "calc(100% - 2 * var(--sp-side) + 12px));\n\tz-index: 0;\n}"), "Spine's hover target takes the pointer at rest")
		ok(has(sheet, "position: absolute;\n\tright: 0;\n\tbottom: calc(100% + 8px);"), "the card opens from the right")
		local left = sheet_of({ ["omp-usage.place"] = "stack", ["omp-usage.align"] = "left" })
		ok(has(left, "left: 0;\n\tright: auto;\n\twidth: 270px;"), "at the left end")
		ok(has(left, "position: absolute;\n\tleft: 0;\n\tbottom: calc(100% + 8px);"), "the card from the left")
	end)

	it("Stacked with one row takes the room the line does", function()
		local doc = F.doc(NOW)
		doc.models["Opus 5.5"] = F.model("anthropic", "Claude", { F.win({ label = "5h", key = "5h", ms = 5 * F.H, r = 0.62, at = NOW + 2 * F.H }) }, NOW)
		local _, data, render = setup({ ["omp-usage.place"] = "stack" }, doc)
		local line, model, settings = drawn(data, render, nil)
		eq({ #line.rows, render.line_height(line) }, { 1, 13 })
		local sheet = render.sheet(model, settings, nil, "hint")
		ok(has(sheet, ":not(:last-child) {\n\tmargin-bottom: 12px;\n}"), "as Above the bar")
		ok(not has(sheet, ".sf-dock:not(.sf-chat-spine) > .sf-row[data-role='omp.hud.activity']"), "the working row as it is")
	end)

	it("Glass is Liquid Glass: a light tint and blur, a sheen and a rim", function()
		local sheet = sheet_of(nil)
		ok(has(sheet, "backdrop-filter: blur(2.5px) saturate(180%);"), "the chat behind stays visible")
		ok(has(sheet, "radial-gradient(90% 160% at 0% 0%"), "the sheen")
		local solid = sheet_of({ ["omp-usage.backdrop"] = "solid" })
		ok(not has(solid, "backdrop-filter: blur(2.5px)"), "Solid as before")
	end)

	it("redraws when a Display setting changes", function()
		local _, data = setup()
		local before = data.display_key(data.load_settings())
		for key, value in { ["omp-usage.style"] = "ring", ["omp-usage.place"] = "below", ["omp-usage.align"] = "left", ["omp-usage.line-parts"] = { plan = true } } :: { [string]: any } do
			local _, other = setup({ [key] = value })
			ok(other.display_key(other.load_settings()) ~= before, key)
		end
	end)
end)

return true -- run.mjs checks it: the Luau CLI's `require` returns a file's compile error instead of raising it
