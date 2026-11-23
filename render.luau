--!strict
-- How omp Usage draws: the line over the composer's context hairline, its tips and comets, the hover card, and the
-- sheets that carry them (window.luau's header tells the design). It builds them from a model of the line
-- (data.luau); window.luau decides when, and the settings panel (panel.luau) previews them.
local data = require("./data")
local detail_view = require("./details")

type Detail = data.Detail
type Model = data.Model
type Settings = data.Settings
type Window = data.Window

local now_ms = data.now_ms
local countdown_minutes = data.countdown_minutes
local clock_at = data.clock_at
local reset_text = data.reset_text
local tone_of = data.tone_of
local is_fable = data.is_fable
local window_name = data.window_name
local palette_for = data.palette_for
local plan_in = data.plan_in
local line_parts = data.line_parts
local share_of = data.share_of
local share_word = data.share_word

local SHEET = "usage"
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
-- Blocks' filled and empty blocks, and Ring's dials, a quarter apart (all 0.6em wide in the line's font, too).
local BLOCK_ON, BLOCK_OFF = "▰", "▱"
local DIALS = { "○", "◔", "◑", "◕", "●" }
-- A stacked line (Display's Stacked): at most this many rows, 15px apart (its font's line height).
local STACK_ROWS = 4
local LINE_ROW = 15
-- Above the hairline, the line's box ends this far over the meter: Tern (0.9.32) draws the context labels (`29%`,
-- `1M`) from 1px above the meter's top, and the backdrop's 1px rim and drop shadow reach below the box. 2px of room
-- left the rim on the labels' glyphs; LIFT_PX clears them, and the room above the composer grows by the same amount.
local LIFT_PX = 5
local ROOM_PX = 15 + LIFT_PX - 2
-- The plan pill's gold, in the card and on the line.
local PLAN_A, PLAN_B = "light-dark(#b7791f, #f6c453)", "light-dark(#975a16, #d69e2e)"
-- The comet: its head and trail, and where in the run (0–1) it sets off, arrives and has flared.
local HEAD_W, HEAD_H = 18, 7
local TRAIL_W, TRAIL_H = 34, 2
local RUN_SET, RUN_ARRIVE, RUN_FLARE = 0.05, 0.6, 0.72
local RUN_STOPS = { 0, 0.05, 0.12, 0.2, 0.28, 0.36, 0.44, 0.52, 0.6, 0.66, 0.72, 0.84, 1 }
-- The compact hover summary: 11px var(--mono) in 18px rows. Full quantities use native UI nodes.
local CARD_ROW = 18
local CARD_INDENT = "  "

-- `moved`: the windows (by provider and label) whose share changed, and which way.
export type Pulse = { seq: number, until_ms: number, moved: { [string]: string } }
-- Both views consume the same scoped rows. The hover uses text/meters; the native details view also uses
-- heading and semantic value fields, without parsing formatted labels or recalculating quota quantities.
type Row = detail_view.Row

local last_css: string? = nil
-- The card's rows for the last model (see `card`).
local card_for: string? = nil
local card_rows: { Row } = {}
-- For the card `card` last built: how many rows each account shown in full takes, by `<group key>/<account>`
-- (the panel reads it straight after a `fixed = "all"` card, to find the picks that make the tallest card).
local card_runs: { [string]: number } = {}

-- The card's memo and the rows each account took in the card `card` last built, for the panel's preview
-- (panel.luau): it builds trial cards to measure them, then puts the memo back.
local function card_memo(): (string?, { Row })
	return card_for, card_rows
end

local function set_card_memo(key: string?, rows: { Row })
	card_for, card_rows = key, rows
end

local function last_card_runs(): { [string]: number }
	return card_runs
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
-- A window's bar: its first glyph, its length and how many glyphs it fills (a fraction; whole blocks in Blocks),
-- the glyph its window ends at, the window's key (provider and label), its colors and its row (0 but on a stacked
-- line). `boxed`: drawn as boxes in the tips' layer under blank glyphs (a stacked line's Instrument bars: its rows
-- take a color each, so its text can't fill a bar).
type Bar = { at: number, glyphs: number, fill: number, ends: number, key: string, a: string, b: string, row: number, boxed: boolean }
-- A plan's pill around its glyphs (a no-break space of padding either side), as a bar is placed.
type Pill = { at: number, glyphs: number, ends: number, row: number }
-- `rows`: a stacked line's rows (`text` has them a line each), each in one color.
type Line = { text: string, glyphs: number, paints: { Paint }, bars: { Bar }, pills: { Pill }, rows: { { text: string, color: string } }? }

-- A window's bar in `style`, `n` glyphs long for a share of `share`%: its text and how many glyphs it fills.
-- Blocks fill whole blocks, at least one while anything is there.
local function bar_text(style: string, n: number, share: number): (string, number)
	local fill = math.clamp(share, 0, 100) / 100 * n
	if style == "blocks" then
		local on = math.round(fill)
		if share > 0 then
			on = math.max(on, 1)
		end
		return string.rep(BLOCK_ON, on) .. string.rep(BLOCK_OFF, n - on), on
	end
	return string.rep(BAR, n), fill
end

-- Ring's dial for a share: empty, a quarter, half, three quarters or full, whichever is nearest.
local function dial(share: number): string
	return DIALS[math.round(math.clamp(share, 0, 100) / 25) + 1]
end

-- A saved reset's count as the line has it: `+2`, `+2F` for Claude's Fable resets.
local function saved_text(group_id: string?, window: Window): string
	return "+" .. tostring(window.saved) .. (if is_fable(group_id, window.label) then "F" else "")
end

type StackRow = { head: string, plan: string?, label: string, share: number, tone: string, reset: string, saved: string, key: string, a: string, b: string, pct: number }

-- A stacked line: a row per window, its columns lined up (what's before the window, its plan, Ring's dial, label,
-- bar, share, countdown and saved resets), then the other statuses a row each. Past STACK_ROWS rows the last one
-- sums up the rest: `+3 more · lowest 7D 5%`. A row takes one color (its window's tone), so the provider's colors
-- go to its bar: Instrument's are boxes laid under blank glyphs (see `statics`), Blocks' keep their glyphs.
local function stack_of(model: Model, settings: Settings): Line
	local on = line_parts(settings)
	local style = settings.style
	local entries: { StackRow } = {}
	for g, group in model.groups do
		for w, window in group.windows do
			local account = if window.lead then window.account else nil
			local head: { string } = {}
			if w == 1 and on.provider and group.label ~= "" then
				table.insert(head, group.label)
			end
			if account then
				table.insert(head, account :: string)
			end
			local a, b = window_colors(tone_of(window.pct), g)
			table.insert(entries, {
				head = table.concat(head, " "),
				plan = if on.plan and (w == 1 or account) then plan_in(group.details, account) else nil,
				label = if on.window then string.upper(window.bare or window.label) else "",
				share = share_of(model, window.pct),
				tone = tone_of(window.pct),
				reset = if on.reset and window.reset then window.reset :: string else "",
				saved = if on.saved and window.saved then saved_text(group.id, window) .. (if window.expires then "!" else "") else "",
				key = group.key .. "/" .. window.label,
				a = a,
				b = b,
				pct = window.pct,
			})
		end
	end
	local others = if on.others then model.others else {}
	local more: string? = nil
	local more_tone = "ok"
	if #entries + #others > STACK_ROWS then
		local keep = STACK_ROWS - 1
		local lowest: StackRow? = nil
		for i = keep + 1, #entries do
			if lowest == nil or entries[i].pct < (lowest :: StackRow).pct then
				lowest = entries[i]
			end
		end
		more = string.format("+%d more", #entries + #others - keep)
		if lowest then
			local low = lowest :: StackRow
			local name = if low.label ~= "" then low.label .. " " else ""
			more = (more :: string) .. string.format(" · %s %s%d%%", if model.used then "most used" else "lowest", name, low.share)
			more_tone = low.tone
		end
		others = table.move(others, 1, math.max(0, keep - #entries), 1, {})
		entries = table.move(entries, 1, math.min(keep, #entries), 1, {})
	end
	-- the columns' widths
	local head_w, label_w, share_w, reset_w = 0, 0, 0, 0
	local saved_any = false
	for _, entry in entries do
		local head = glyph_count(entry.head)
		if entry.plan then
			head += (if head > 0 then 1 else 0) + glyph_count(entry.plan :: string) + 2
		end
		head_w = math.max(head_w, head)
		label_w = math.max(label_w, glyph_count(entry.label))
		share_w = math.max(share_w, #tostring(entry.share) + 1)
		reset_w = math.max(reset_w, glyph_count(entry.reset))
		saved_any = saved_any or entry.saved ~= ""
	end
	local rows: { { text: string, color: string } } = {}
	local line: Line = { text = "", glyphs = 0, paints = {}, bars = {}, pills = {}, rows = rows }
	local word = if style == "compact" then "" else " " .. share_word(model)
	for r, entry in entries do
		local row = ""
		local function cell(s: string, width: number, gap: number)
			if row ~= "" then
				row ..= string.rep(" ", gap)
			end
			row ..= s .. string.rep(" ", width - glyph_count(s))
		end
		if head_w > 0 then
			local head = entry.head
			if entry.plan then
				local at = glyph_count(head) + (if head ~= "" then 1 else 0)
				head ..= (if head ~= "" then " " else "") .. " " .. (entry.plan :: string) .. " "
				table.insert(line.pills, { at = at, glyphs = glyph_count(head) - at, ends = 0, row = r - 1 })
			end
			cell(head, head_w, 0)
		end
		if style == "ring" and on.bar then
			cell(dial(entry.share), 1, 2)
		end
		if label_w > 0 then
			cell(entry.label, label_w, if style == "ring" and on.bar then 1 else 2)
		end
		if on.bar and (style == "instrument" or style == "blocks") then
			if row ~= "" then
				row ..= " "
			end
			local text, filled = bar_text(style, BAR_GLYPHS, entry.share)
			local boxed = style == "instrument"
			table.insert(line.bars, {
				at = glyph_count(row),
				glyphs = BAR_GLYPHS,
				fill = filled,
				ends = 0,
				key = entry.key,
				a = entry.a,
				b = entry.b,
				row = r - 1,
				boxed = boxed,
			})
			row ..= if boxed then string.rep(" ", BAR_GLYPHS) else text
		end
		if on.share then
			local share = tostring(entry.share) .. "%"
			cell(string.rep(" ", share_w - #share) .. share .. word, share_w + #word, 1)
		end
		if reset_w > 0 then
			cell(entry.reset, reset_w, 2)
		end
		if saved_any then
			cell(entry.saved, 0, 2)
		end
		table.insert(rows, { text = row, color = "var(--ou-num-" .. entry.tone .. ")" })
	end
	for _, other in others do
		table.insert(rows, { text = other, color = "var(--ou-soft)" })
	end
	if more then
		table.insert(rows, { text = more :: string, color = if more_tone == "ok" then "var(--ou-soft)" else "var(--ou-num-" .. more_tone .. ")" })
	end
	local texts: { string } = {}
	for _, row in rows do
		row.text = (string.gsub(row.text, "%s+$", ""))
		line.glyphs = math.max(line.glyphs, glyph_count(row.text))
		table.insert(texts, row.text)
	end
	line.text = table.concat(texts, "\n")
	return line
end

-- One provider: `Claude  5H ━━━━━━━━ 98% left  3h 57m · 7D ━━━━━━━━ 71% left  11h 37m  +1 · <other statuses>`.
-- Several (the composer is at most ~115 glyphs wide) go compact, the countdowns and the word `left` left to the
-- card, and a `·` only between providers: `Claude  5H ━━━━━━ 98%  7D ━━━━━━ 71% +1 · Codex  7D ━━━━━━ 79% +2`.
-- A provider with several accounts names each once, in its color, before its first window, which a `·` sets
-- apart from the account before: `Claude alice  7D ━━━━━━━━ 68% left … · bob  5H ━━━━━━━━ 40% left …`.
-- Each window's parts are joined by no-break spaces (a provider's label with its first window) so it wraps
-- whole; with them, what colors each part. Display's settings pick the parts (a plan rides after its provider or
-- account as a gold pill), the style (Blocks: `▰▰▰▱`, Ring: a dial before the window, Compact: no bar and no
-- `left`) and whether a share is what's left or what's used; Stacked gets a line of its own (`stack_of`).
local function line_of(model: Model, settings: Settings): Line
	if settings.place == "stack" then
		return stack_of(model, settings)
	end
	local on = line_parts(settings)
	local style = settings.style
	local parts: { string } = {}
	local line: Line = { text = "", glyphs = 0, paints = {}, bars = {}, pills = {} }
	local several = #model.groups > 1
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
		if #group.windows == 0 then
			next_part()
			add(unbroken(group.label .. " details"), group_color(g, "a"))
		end
		for w, window in group.windows do
			local tone = tone_of(window.pct)
			local share = share_of(model, window.pct)
			local accent = group_color(g, "a")
			local a, b = window_colors(tone, g)
			local account = if window.lead then window.account else nil
			if w > 1 and several and account == nil then
				add(" " .. NBSP)
			else
				next_part()
			end
			-- each part after the window's first `gap` no-break spaces after the one before: one between the
			-- window's own parts, two after what names it; returns the glyph the part starts at
			local started, own = false, false
			local function put(s: string, color: string?, gap: number?): number
				if started then
					add(string.rep(NBSP, gap or (if own then 1 else 2)))
				end
				local at = line.glyphs
				add(s, color)
				started = true
				return at
			end
			local named = w == 1 and group.label ~= "" and on.provider
			if named then
				put(group.label, accent)
			end
			if account then
				put(unbroken(account :: string), accent, 1)
			end
			local plan = if on.plan and (named or account) then plan_in(group.details, account) else nil
			if plan then
				local at = put(NBSP .. unbroken(plan :: string) .. NBSP, PLAN_A, 1)
				table.insert(line.pills, { at = at, glyphs = line.glyphs - at, ends = 0, row = 0 })
			end
			local bar: Bar? = nil
			if on.bar and style == "ring" then
				put(dial(share), b)
				own = true
			end
			if on.window then
				put(unbroken(string.upper(window.bare or window.label)), "var(--ou-lbl)")
				own = true
			end
			if on.bar and (style == "instrument" or style == "blocks") then
				local text, filled = bar_text(style, bar_glyphs, share)
				local at = put(text)
				own = true
				bar = { at = at, glyphs = bar_glyphs, fill = filled, ends = 0, key = group.key .. "/" .. window.label, a = a, b = b, row = 0, boxed = false }
			end
			if on.share then
				put(tostring(share) .. "%", "var(--ou-num-" .. tone .. ")")
				own = true
				if not several and style ~= "compact" then
					add(NBSP .. share_word(model), "var(--ou-dim)")
				end
			end
			if on.reset and not several and window.reset then
				put(unbroken(window.reset :: string), "var(--ou-soft)", 2)
			end
			if on.saved and window.saved then
				local saved = saved_text(group.id, window)
				if window.expires then
					saved ..= if several then "!" else NBSP .. "exp" .. NBSP .. unbroken(window.expires :: string)
				end
				put(saved, if window.expires then "var(--ou-num-warn)" else accent, if several then 1 else 2)
			end
			for _, pill in line.pills do
				if pill.ends == 0 then
					pill.ends = line.glyphs
				end
			end
			if bar then
				bar.ends = line.glyphs
				table.insert(line.bars, bar)
			end
		end
	end
	if on.others then
		for _, other in model.others do
			next_part()
			add(unbroken(other), "var(--ou-soft)")
		end
	end
	line.text = table.concat(parts)
	return line
end

-- The text's paint: each part's color over its glyphs; each bar from its first color, faint, to its second up to
-- its share, then the track. Hard stops sit between glyphs, so nothing bleeds. A stacked line's rows take a color
-- each, top to bottom.
local function line_paint(line: Line): string
	if line.rows then
		local stops: { string } = {}
		for r, row in line.rows :: { { text: string, color: string } } do
			table.insert(stops, string.format("%s %spx %spx", solid(row.color), num((r - 1) * LINE_ROW), num(r * LINE_ROW)))
		end
		return "linear-gradient(180deg, " .. table.concat(stops, ", ") .. ")"
	end
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

-- `size` while what ends at glyph `ends` fits on the line of the box drawing it, else 0, so a window that wrapped
-- away takes its tip and pill along (in background sizes, 100% is that box's width). A stacked line doesn't wrap
-- (`ends` 0).
local function fits(ends: number, size: number): string
	if ends == 0 then
		return num(size) .. "px"
	end
	return string.format("clamp(0px, calc((100%% - %spx) * 1000), %spx)", num(ends * GLYPH - 3), num(size))
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

local function layer(layers: Layers, image: string, x: number, y: number, w: string, h: number)
	table.insert(layers.images, image)
	table.insert(layers.positions, string.format("%spx %spx", num(x), num(y)))
	table.insert(layers.sizes, string.format("%s %spx", w, num(h)))
end

-- What the tips' layer draws that doesn't move: each plan's pill (a gold ring, faintly filled, around its text)
-- and a stacked line's boxed bars (the share in the bar's colors over the track). The comets keep them.
local function statics(line: Line): Layers
	local layers: Layers = { images = {}, positions = {}, sizes = {} }
	for _, pill in line.pills do
		local x, y = pill.at * GLYPH, pill.row * LINE_ROW + 0.5
		local w, h, r = pill.glyphs * GLYPH, 12, 6
		local edge = string.format("linear-gradient(90deg, %s, %s)", faded(PLAN_A, 80), faded(PLAN_B, 80))
		layer(layers, edge, x + r, y, fits(pill.ends, w - 2 * r), 1)
		layer(layers, edge, x + r, y + h - 1, fits(pill.ends, w - 2 * r), 1)
		for _, cap in { { color = PLAN_A, side = "100%", x = x }, { color = PLAN_B, side = "0%", x = x + w - r } } do
			layer(
				layers,
				string.format(
					"radial-gradient(%spx %spx at %s 50%%, %s 0%%, %s 80%%, %s 88%%, %s 96%%, %s 100%%)",
					num(r), num(r), cap.side,
					faded(cap.color, 22), faded(cap.color, 22), faded(cap.color, 80), faded(cap.color, 80), faded(cap.color, 0)
				),
				cap.x, y, fits(pill.ends, r), h
			)
		end
		layer(layers, string.format("linear-gradient(90deg, %s, %s)", faded(PLAN_A, 22), faded(PLAN_B, 22)), x + r, y, fits(pill.ends, w - 2 * r), h)
	end
	for _, bar in line.bars do
		if bar.boxed then
			local x, y = bar.at * GLYPH, bar.row * LINE_ROW + BAR_Y - 1
			if bar.fill > 0 then
				layer(layers, string.format("linear-gradient(90deg, %s, %s)", faded(bar.a, 40), solid(bar.b)), x, y, num(bar.fill * GLYPH) .. "px", 2)
			end
			layer(layers, string.format("linear-gradient(%s, %s)", solid("var(--ou-track)"), solid("var(--ou-track)")), x, y, num(bar.glyphs * GLYPH) .. "px", 2)
		end
	end
	return layers
end

-- The tips' layer at rest: what doesn't move, and each bar's lit tip where its window stands.
local function tips(line: Line, strength: number): Layers
	local layers = statics(line)
	for _, bar in line.bars do
		local x = (bar.at + bar.fill) * GLYPH
		layer(layers, tip_image(bar.b, strength), x - TIP_W / 2, bar.row * LINE_ROW + BAR_Y - TIP_H / 2, fits(bar.ends, TIP_W), TIP_H)
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
	margin-top: $ROOM_TOP;
}
/* Tern's agents and jobs tray lifts the meter (and the line on it) above itself, right under the working row: the
   same room again, above the tray */
.sf-dock.sf-tray-ctx > .sf-col.sf-tray {
	margin-top: $ROOM_TOP;
}
.sf-dock.sf-tray-ctx > .sf-col.sf-tray.under {
	margin-top: $ROOM_UNDER;
}
/* the providers' colors */
$PALETTE
/* the line: 10px mono in a box as tall as its rows, one but for Stacked (one row's box is 13px, its second line,
   where a window that doesn't fit wraps, cut off); one static gradient clipped to the text colors its parts and
   fills its bars */
$METER::before,
$HOST::before {
	content: $CONTENT;
	height: $HEIGHT;
	overflow: hidden;
	white-space: $WRAP;
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
}
$TIPS_CSS
$GEOMETRY
/* with attachments the target is the first chip's end slot: the row doesn't clip it, and the chip isn't its
   containing block, so it is placed from the composer, as the empty row is */
$CHIPS {
	overflow: visible;
}
$CHIPS > .sf-card:first-child {
	position: static;
}
/* the hover target over the line (placed above), widened by the capsule's 6px pad. At rest it sits under the
   line, as its backdrop (see below); hovered, over it */
$HOST {
	display: block !important;
	position: absolute;
	height: $HOST_HEIGHT;
	min-height: 0;
	margin: 0;
	padding: 0;
	overflow: visible;
	opacity: 1;
	z-index: -1;
	pointer-events: auto;
	border-radius: 8px;
	background-color: transparent;
	box-shadow: 0 0 0 1px transparent, 0 8px 20px -12px transparent, inset 0 1px 0 transparent;
	transition:
		background-color 0.2s var(--ease),
		box-shadow 0.2s var(--ease);
}
$BACKDROP
/* hovered, the line lifts into a glass capsule, ringed in its provider's color (or the lowest window's tone) */
$HOST:hover {
	z-index: 5;
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

-- Where the line sits, above the hairline or under it (Display's Position): the line and its tips' layer on the
-- meter, and the hover target over the line, the meter's place in each chat style, as long as the line (or the
-- meter, if that's shorter). Under it, outside Spine (which has the room) and the tray (where it rides above),
-- every composer's input moves down a line to make room, so focus never shifts one.
local ROW_CSS = [==[
$ROOM
$METER::before,
$METER::after {
	left: 0;
	right: 0;
	$LINE_Y
}
/* Spine lays the meter across the whole dock, from its left edge, with the working row right above it, and insets
   the composer's column by its `--sp-side`: there the line goes under the hairline, on the column, in the room the
   margin above leaves between the hairline and the input. Its tips and comets (`::after`) go with it.
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
/* except over the tray, where Tern lifts the meter onto the tray's sides in every chat style: the line rides above
   it, as in the other styles */
$METER_TRAY::before,
$METER_TRAY::after {
	left: 0;
	right: 0;
	top: auto;
	bottom: 100%;
	margin-bottom: $LIFT;
}
$HOST {
	left: 12px;
	top: $HOST_TOP;
	width: min($WIDTH, calc(100% - 24px));
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
/* over the tray, the target follows the meter Tern lifts above it: else it would sit on the tray's cards, taking
   their hover and clicks */
$HOST_TRAY {
	left: calc(var(--sf-tray-ctx-l, 22px) - 6px);
	top: calc($TRAY_TOP - var(--sf-tray-lift, 0px));
	width: min($WIDTH, calc(100% - var(--sf-tray-ctx-l, 22px) - var(--sf-tray-ctx-r, 22px) + 12px));
}]==]

-- Stacked: the block of rows over the meter's right (or left) end, in every chat style (Spine's too, beside its
-- working row), as wide as its longest row; the target over it, its edge as far in from the composer's as the
-- meter's widest copy of the line ends (Spine's `--sp-side`, Console's gutter, the tray's sides).
local STACK_CSS = [==[
$METER::before,
$METER::after {
	$METER_SIDE
	width: $LINE_WIDTH;
	top: auto;
	bottom: 100%;
	margin-bottom: $LIFT;
}
$METER_SPINE::before,
$METER_SPINE::after {
	$SPINE_METER_SIDE
}
$METER_TRAY::before,
$METER_TRAY::after {
	$METER_SIDE
}
$HOST {
	$HOST_SIDE
	top: $HOST_TOP;
	width: min($WIDTH, calc(100% - 24px));
}
$HOST_READER {
	$READER_SIDE
	width: min($WIDTH, calc(100% - 32px));
}
$HOST_SPINE {
	$SPINE_HOST_SIDE
	top: $HOST_TOP;
	width: min($WIDTH, calc(100% - 2 * var(--sp-side) + 12px));
}
$HOST_CONSOLE {
	$CONSOLE_SIDE
	width: min($WIDTH, calc(min(100%, 1040px) - var(--cn-gut) + 12px));
}
$HOST_TRAY {
	$TRAY_SIDE
	top: calc($HOST_TOP - var(--sf-tray-lift, 0px));
	width: min($WIDTH, calc(100% - var(--sf-tray-ctx-l, 22px) - var(--sf-tray-ctx-r, 22px) + 12px));
}]==]

-- The tips at rest, on the meter's `::after`, which a change's comets take over (pulse_css); it carries its own
-- track color (the plans' pills and a stacked line's bars use it), as its `::before` does.
local TIPS_CSS = [==[
/* each bar's lit tip, where its window stands */
$METER::after {
	content: "";
	position: absolute;
	height: $HEIGHT;
	background-image: $IMAGES;
	background-position: $POSITIONS;
	background-size: $SIZES;
	background-repeat: no-repeat;
	pointer-events: none;
	--ou-track: color-mix(in srgb, var(--t1) 13%, transparent);
}]==]

-- The line's backdrop at rest, by the Line background setting (see data.luau's BACKDROPS): the target under the
-- line as Liquid Glass, opaque in the card's glass, or nothing.
local BACKDROP_CSS: { [string]: string } = {
	-- Liquid Glass: a faint tint the chat shows through, softened rather than blurred away (a light blur, more
	-- saturation), a sheen falling from the top edge and the top-left corner, a lit rim above and a shaded one below.
	-- Each color is a relative one: Tern drops a gradient stop that is a bare `light-dark()`.
	glass = [==[
$HOST {
	background-color: light-dark(rgb(from var(--card) r g b / 30%), rgb(from var(--pop-bg) r g b / 22%));
	background-image:
		linear-gradient(180deg, rgb(from light-dark(rgb(255 255 255 / 55%), rgb(255 255 255 / 10%)) r g b / alpha), rgb(255 255 255 / 0%) 60%),
		radial-gradient(90% 160% at 0% 0%, rgb(from light-dark(rgb(255 255 255 / 40%), rgb(255 255 255 / 8%)) r g b / alpha), rgb(255 255 255 / 0%) 70%);
	backdrop-filter: blur(2.5px) saturate(180%);
	box-shadow:
		0 0 0 1px light-dark(rgb(255 255 255 / 55%), rgb(255 255 255 / 9%)),
		inset 0 1px 0 light-dark(rgb(255 255 255 / 85%), rgb(255 255 255 / 20%)),
		inset 0 -1px 0 light-dark(rgb(0 0 0 / 6%), rgb(0 0 0 / 30%)),
		0 6px 16px -10px light-dark(rgb(0 0 0 / 18%), rgb(0 0 0 / 60%));
}
/* hovered, the opaque capsule as with any background: no sheen, nothing behind to soften */
$HOST:hover {
	background-image: none;
	backdrop-filter: none;
}]==],
	solid = "$HOST {\n\tbackground-color: var(--ou-glass);\n}",
	clear = "",
}

-- The line's box height in px: a row's 13px, or a stacked line's rows 15px apart.
local function line_height(line: Line): number
	return if line.rows then math.max(1, #(line.rows :: { any })) * LINE_ROW - 2 else 13
end

-- The line as a `content` string: a stacked line's rows broken with `\A`.
local function line_content(line: Line): string
	if line.rows == nil then
		return css_string(line.text)
	end
	local rows: { string } = {}
	for _, row in line.rows :: { { text: string, color: string } } do
		table.insert(rows, string.sub(css_string(row.text), 2, -2))
	end
	return '"' .. table.concat(rows, "\\A ") .. '"'
end

-- The geometry for Display's Position (ROW_CSS or STACK_CSS), filled for the line's pane.
local function geometry_css(line: Line, settings: Settings): string
	local vars: { [string]: string } = {
		METER = meter(),
		METER_SPINE = meter(".sf-chat-spine"),
		METER_TRAY = meter(".sf-tray-ctx"),
		SPINE_SIDE = SPINE_SIDE,
		HOST = host(nil),
		HOST_READER = host(".sf-chat-reader"),
		HOST_SPINE = host(".sf-chat-spine"),
		HOST_CONSOLE = host(".sf-chat-console"),
		HOST_TRAY = host(".sf-tray-ctx"),
		WIDTH = num(line.glyphs * GLYPH + 12) .. "px",
		LIFT = num(LIFT_PX) .. "px",
	}
	-- the target's top above the hairline: the meter 12px above the column's top, the line LIFT_PX over the meter,
	-- `height` tall, and the target 1px above the line
	local function above_top(height: number): string
		return num(-(13 + LIFT_PX + height)) .. "px"
	end
	if settings.place ~= "stack" then
		local below = settings.place == "below"
		vars.LINE_Y = if below
			then "top: calc(100% + 4px);\n\tbottom: auto;\n\tmargin-bottom: 0;"
			else "top: auto;\n\tbottom: 100%;\n\tmargin-bottom: " .. vars.LIFT .. ";"
		vars.TRAY_TOP = above_top(line_height(line))
		vars.HOST_TOP = if below then "5px" else vars.TRAY_TOP
		-- Tern pads the column 14px above the input and its own rule wins over a plain one: the line's 14px more
		vars.ROOM = if below
			then ".sf-dock:not(.sf-chat-spine):not(.sf-tray-ctx) .sf-col[data-role^='omp.editor'] {\n\tpadding-top: 28px !important;\n}"
			else ""
		return fill(ROW_CSS, vars)
	end
	local right = settings.align == "right"
	local function side(left: string, right_inset: string?): string
		return if right then "left: auto;\n\tright: " .. (right_inset or left) .. ";" else "left: " .. left .. ";\n\tright: auto;"
	end
	vars.LINE_WIDTH = num(line.glyphs * GLYPH) .. "px"
	vars.HOST_TOP = above_top(line_height(line))
	vars.METER_SIDE = side("0")
	vars.SPINE_METER_SIDE = side(SPINE_SIDE, "calc(" .. SPINE_SIDE .. " - 16px)")
	vars.HOST_SIDE = side("12px")
	vars.READER_SIDE = side("16px")
	vars.SPINE_HOST_SIDE = side("calc(var(--sp-side) - 6px)")
	vars.CONSOLE_SIDE = side("calc(max(0px, (100% - 1040px) / 2) + var(--cn-gut) - 12px)", "max(0px, calc((100% - 1040px) / 2))")
	vars.TRAY_SIDE = side("calc(var(--sf-tray-ctx-l, 22px) - 6px)", "calc(var(--sf-tray-ctx-r, 22px) - 6px)")
	return fill(STACK_CSS, vars)
end

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
	local height = num(line_height(line)) .. "px"
	return fill(LINE_CSS, {
		METER = meter(),
		CHIPS = line_pane .. " " .. CHIPS,
		ROOM_TOP = num(ROOM_PX) .. "px",
		ROOM_UNDER = num(ROOM_PX + 4) .. "px",
		HOST = host(nil),
		PALETTE = palette_css(model, settings),
		BACKDROP = fill(BACKDROP_CSS[settings.backdrop] or "", { HOST = host(nil) }),
		CONTENT = line_content(line),
		HEIGHT = height,
		HOST_HEIGHT = num(line_height(line) + 2) .. "px",
		WRAP = if line.rows then "pre" else "pre-wrap",
		PAINT = paint,
		TIPS_CSS = if #rest.images > 0
			then fill(TIPS_CSS, {
				METER = meter(),
				HEIGHT = height,
				IMAGES = table.concat(rest.images, ", "),
				POSITIONS = table.concat(rest.positions, ", "),
				SIZES = table.concat(rest.sizes, ", "),
			})
			else "",
		GEOMETRY = geometry_css(line, settings),
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
-- Under a window's meter, the estimates its details carry for that window (tokens and API-equivalent value
-- left), each after its icon, as the writer formatted them; a plan its account names once rides on the
-- account's heading (the title, for a provider alone on the card) as a pill. The native details view gets
-- neither: it draws both itself.

-- An account's windows on one row, each window's saved resets beside it as the line has them (`+NF` for Fable
-- resets): `alice · 7D 65% +2 · FABLE 7D 81% +1F`, each share as the model says it (left or used). The lowest
-- share left comes back too, for the row's tone.
local function account_summary(model: Model, prefix: string, windows: { Window }, provider: string?): (string, number)
	local text = prefix
	local lowest = 100
	for _, window in windows do
		text ..= " · " .. string.upper(window.bare or window.label) .. " " .. tostring(share_of(model, window.pct)) .. "%"
		if window.saved then
			text ..= " +" .. tostring(window.saved) .. (if is_fable(provider, window.bare or window.label) then "F" else "")
		end
		lowest = math.min(lowest, window.pct)
	end
	return text, lowest
end

-- `fixed` bypasses fitting: "all" measures the hover in full, "least" measures its folded summary, and
-- "details" supplies every scoped fact to the scrollable native view.
local function card(model: Model, hint: string, limit: number, fixed: string?): { Row }
	local key = model.signature .. "\n" .. hint .. "\n" .. tostring(limit) .. "\n" .. tostring(fixed)
	if key == card_for then
		return card_rows
	end
	local now = now_ms()
	-- The plan an account's details name, if they name exactly one (`account` nil: the provider's single account).
	local function plan_of(details: { Detail }, account: string?): string?
		local plan: string? = nil
		for _, detail in details do
			if detail.kind == "plan" and detail.value and detail.window == nil and detail.account == account then
				if plan and plan ~= detail.value then return nil end
				plan = detail.value
			end
		end
		return plan
	end
	-- A window's estimates on one row, short (`633.04M`, `$533.10`): the icon names the unit, so `tokens` goes
	-- and a USD amount takes `$`. Each icon covers three blank cells (the cost's `$` glyph in its middle one).
	local function estimate_row(details: { Detail }, account: string?, window: string): Row?
		local tokens: string?, cost: string? = nil, nil
		for _, detail in details do
			if detail.window == window and detail.account == account and detail.value then
				if detail.kind == "tokens-estimate" and tokens == nil then
					tokens = (string.gsub(detail.value :: string, " tokens$", ""))
				elseif detail.kind == "cost-estimate" and cost == nil then
					cost = (string.gsub(detail.value :: string, "^USD ", "$"))
				end
			end
		end
		if tokens == nil and cost == nil then
			return nil
		end
		local text = ""
		local icons: { { cell: number, kind: string } } = {}
		if tokens then
			table.insert(icons, { cell = 0, kind = "tokens" })
			text = "    " .. (tokens :: string)
		end
		if cost then
			if text ~= "" then
				text ..= "   "
			end
			table.insert(icons, { cell = glyph_count(text), kind = "cost" })
			text ..= " $  " .. (cost :: string)
		end
		return { text = text, color = "var(--oc-head)", icons = icons }
	end
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
			local hover = fixed ~= "details"
			-- In the hover a heading is ink, as the title is, so its plan pill reads the same in every mode (the
			-- card's text takes one color a row); the provider's colors go to a bar down its rows (see `bar`). The
			-- details view takes its colors from the heading.
			local head = if hover then "var(--oc-head)" else accent
			local heading_at: number? = nil
			if several and not (first and first.lead) then
				table.insert(rows, {
					text = group.label,
					color = head,
					heading = true,
					badge = if hover then plan_of(group.details or {}, nil) else nil,
					a = accent,
					b = group_color(g, "b"),
				})
				heading_at = #rows
			elseif hover and not several then
				rows[1].badge = plan_of(group.details or {}, nil)
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
			local details = group.details or {}
			-- Full details keep every fact and its account/window boundary. The hover keeps status warnings
			-- and one opaque detail when there is no meter; quantities and metadata live in the native view.
			local function add_details(into: { Row }, account: string?, window: string?, first: boolean)
				local noted = false
				for _, detail in details do
					if detail.window == window and (detail.account == account or (detail.account == nil and first)) then
						local status = detail.kind == "stale" or detail.kind == "error"
						local opaque = #group.windows == 0 and not noted and detail.kind ~= "plan" and detail.kind ~= "observed"
						if fixed == "details" or status or opaque then
							local shared = detail.account == nil and account ~= nil
							table.insert(into, {
								text = CARD_INDENT .. (if shared then "Provider · " else "") .. detail.text,
								color = detail_view.color(detail.kind),
								kind = detail.kind, value = detail.value,
								account_note = window == nil, shared = shared,
							})
							noted = true
						end
					end
				end
			end
			-- an account's row, or (past `keep`) its share of the provider's fold
			local folded, lowest, lowest_text, fold_muted = 0, 101, "", false
			local function one_row(name: string, windows: { Window }, color: string?, rule: boolean)
				if kept < keep then
					kept += 1
					local text, low = account_summary(model, (if several then group.label .. " " else "") .. name, windows, group.id)
					if #windows == 0 then
						for _, detail in details do
							if detail.account == name and detail.kind ~= "plan" then
								text ..= " · " .. detail.text
								break
							end
						end
					end
					local tone = tone_of(low)
					table.insert(rows, {
						text = text,
						color = color or (if tone == "ok" then accent else "var(--oc-win-" .. tone .. ")"),
						rule = rule,
						heading = true,
					})
					return
				end
				folded += 1
				fold_muted = fold_muted or color ~= nil
				for _, window in windows do
					if window.pct < lowest then
						lowest, lowest_text = window.pct, string.upper(window.bare or window.label) .. " " .. tostring(share_of(model, window.pct)) .. "%"
					end
				end
				if #windows == 0 and lowest_text == "" then lowest_text = "details" end
			end
			-- the group's windows by account (one run, for a provider without accounts)
			local runs: { { name: string?, windows: { Window } } } = {}
			for _, window in group.windows do
				if #runs == 0 or (window.lead and window.account) then
					table.insert(runs, { name = window.account, windows = {} })
				end
				table.insert(runs[#runs].windows, window)
			end
			-- A source may report absolute amounts or an error without any percentage meter. A plan alone only labels
			-- an account's windows.
			for _, detail in details do
				if detail.kind == "plan" then continue end
				local found = false
				for _, run in runs do
					if run.name == detail.account or detail.account == nil then
						found = true
						break
					end
				end
				if not found then table.insert(runs, { name = detail.account, windows = {} }) end
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
						local heading = (if several then group.label .. " " else "")
							.. ((run.windows[1] and run.windows[1].plan) or run.name :: string)
						table.insert(new, {
							text = heading,
							color = head,
							rule = r > 1,
							heading = true,
							badge = if hover then plan_of(details, run.name) else nil,
							a = accent,
							b = group_color(g, "b"),
						})
					end
					for _, window in run.windows do
						local tone = tone_of(window.pct)
						local a, b = window_colors(tone, g)
						table.insert(new, {
							text = window_name(window.bare or window.label) .. " window",
							right = tostring(share_of(model, window.pct)) .. "% " .. share_word(model),
							color = "var(--oc-win-" .. tone .. ")",
							share = math.clamp(share_of(model, window.pct), 0, 100) / 100,
							a = a,
							b = b,
						})
						local estimates = if hover then estimate_row(details, run.name, window.label) else nil
						if estimates then
							table.insert(new, estimates)
						end
						if window.covers then
							table.insert(new, { text = CARD_INDENT .. (window.covers :: string), color = "var(--oc-mute)" })
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
						add_details(new, run.name, window.label, false)
					end
					add_details(new, run.name, nil, r == 1)
					if run.name and hover then
						new[1].bar = #new
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
						"%s+%d more account%s · %s %s",
						if several then group.label .. " " else "",
						folded,
						if folded == 1 then "" else "s",
						if model.used then "most used" else "lowest",
						lowest_text
					),
					color = if fold_muted then "var(--oc-mute)" elseif tone == "ok" then accent else "var(--oc-win-" .. tone .. ")",
				})
			end
			if heading_at and hover then
				rows[heading_at :: number].bar = #rows - (heading_at :: number) + 1
			end
		end
		for _, other in model.others do
			table.insert(rows, { text = other, color = "var(--oc-soft)", account_note = true })
		end
		if fixed ~= "details" then
			table.insert(rows, { text = hint, color = "var(--oc-hint)", rule = true })
		end
		card_runs = runs_rows
		return rows
	end
	-- the accounts that can show in full, and those that can only get a row (the ones beside a picked account)
	local accounts, others = 0, 0
	for _, group in model.groups do
		local names: { [string]: boolean } = {}
		for _, window in group.windows do
			if window.account then names[window.account] = true end
		end
		for _, detail in group.details or {} do
			if detail.account then names[detail.account] = true end
		end
		if group.rest == nil then
			for _ in names do accounts += 1 end
		end
		for i, window in (group.rest or {}) :: { Window } do
			if window.lead or i == 1 then
				others += 1
			end
		end
	end
	local every = accounts + others
	if fixed then
		card_for, card_rows = key, if fixed == "least" then build(0, 0) else build(accounts, every)
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
-- after a beat, from its left end (from its right end, `at_right`: over a stacked line at the composer's right
-- edge); `target` (the settings panel's preview) draws the same card, still, on another element.
local function card_css(rows: { Row }, target: string?, at_right: boolean?): string
	-- the card's 11px mono glyphs are 6.6px wide; the estimate icons' colors (tokens, API-equivalent value)
	local GLYPH_W = 6.6
	local TOKENS_ICON, COST_ICON = "light-dark(#4f5bd5, #8b95ff)", "var(--ok)"
	local width = 28
	for _, row in rows do
		local n = glyph_count(row.text)
		if row.right then
			n += 4 + glyph_count(row.right :: string)
		end
		if row.badge then
			n += 4 + glyph_count(row.badge :: string)
		end
		width = math.max(width, n)
	end
	local lines: { string } = {}
	local paint: { string } = {}
	-- Tern draws one text-clipped layer. The remaining layers are the compact meters, pills, icons and title band.
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
		end
		if row.badge then
			local badge = row.badge :: string
			text ..= string.rep(" ", width - glyph_count(row.text) - glyph_count(badge) - 1) .. badge .. " "
		end
		if row.right then
			local a = row.a or "var(--accent)"
			local b = row.b or a
			local share = row.share or 0
			local meter = y + CARD_ROW - 1
			-- a background-position percentage places the layer's own share of the slack: this centers the tip on it
			layer(
				tip_image(b, 70),
				string.format(
					"calc(%s%% + %spx) %spx",
					num(share * 100),
					num(share * TIP_W - TIP_W / 2),
					num(meter - 2)
				),
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
		-- a heading's bar: 2px in its provider's colors down the left margin, beside its rows, fading out at the end
		if row.bar and row.a then
			local a = row.a :: string
			local b = row.b or a
			local size = string.format("2px %spx", num((row.bar :: number) * CARD_ROW - 8))
			layer(
				string.format("linear-gradient(180deg, %s, %s 70%%, %s)", solid(a), solid(b), faded(b, 0)),
				string.format("-7px %spx", num(y + 4)),
				size,
				size,
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
		-- the plan pill: the badge's text and a cell either side, ringed in gold with a glow, measured from the
		-- right edge where the text's last cell ends (`calc(100% - Npx)` puts a layer's right edge N px in)
		if row.badge then
			local w = (glyph_count(row.badge :: string) + 2) * GLYPH_W
			local r = 7
			local top = y + 2
			local function at(right: number, down: number): string
				return string.format("calc(100%% %s %spx) %spx", if right < 0 then "+" else "-", num(math.abs(right)), num(top + down))
			end
			local edge = string.format("linear-gradient(90deg, %s, %s)", faded(PLAN_A, 80), faded(PLAN_B, 80))
			local rim = string.format("%spx 1px", num(w - 2 * r))
			layer(edge, at(r, 0), rim, rim, "content-box")
			layer(edge, at(r, 2 * r - 1), rim, rim, "content-box")
			for _, cap in { { color = PLAN_A, side = "100%", right = w - r }, { color = PLAN_B, side = "0%", right = 0 } } do
				local half = string.format("%spx %spx", num(r), num(2 * r))
				layer(
					string.format(
						"radial-gradient(%spx %spx at %s 50%%, %s 0%%, %s 76%%, %s 84%%, %s 94%%, %s 100%%)",
						num(r), num(r), cap.side,
						faded(cap.color, 30), faded(cap.color, 30), faded(cap.color, 80), faded(cap.color, 80), faded(cap.color, 0)
					),
					at(cap.right, 0), half, half, "content-box"
				)
			end
			local body = string.format("%spx %spx", num(w - 2 * r), num(2 * r))
			layer(string.format("linear-gradient(90deg, %s, %s)", faded(PLAN_A, 30), faded(PLAN_B, 30)), at(r, 0), body, body, "content-box")
			local glow = string.format("%spx %spx", num(w + 16), num(2 * r + 14))
			layer(string.format("radial-gradient(closest-side, %s, %s)", faded(PLAN_A, 22), faded(PLAN_A, 0)), at(-8, -7), glow, glow, "content-box")
		end
		-- an estimate's icon: a tinted disc ringed in its color over the icon's middle cell; the tokens icon
		-- draws its lines in the text's color (the cost icon's `$` is a glyph of the row)
		for _, icon in row.icons or {} do
			local color = if icon.kind == "tokens" then TOKENS_ICON else COST_ICON
			local cx = (icon.cell + 1.5) * GLYPH_W
			local cy = y + CARD_ROW / 2
			if icon.kind == "tokens" then
				for k, length in { 5, 5, 3 } do
					local size = string.format("%spx 1px", num(length))
					layer(
						string.format("linear-gradient(%s, %s)", solid("var(--oc-head)"), solid("var(--oc-head)")),
						string.format("%spx %spx", num(cx - 2.5), num(cy + (k - 2) * 2.5 - 0.5)),
						size, size, "content-box"
					)
				end
			end
			layer(
				string.format(
					"radial-gradient(closest-side, %s 0%%, %s 72%%, %s 80%%, %s 92%%, %s 100%%)",
					faded(color, 22), faded(color, 22), solid(color), solid(color), faded(color, 0)
				),
				string.format("%spx %spx", num(cx - 6.5), num(cy - 6.5)),
				"13px 13px", "13px 13px", "content-box"
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
		PLACE = if target
			then "display: block;"
			else "position: absolute;\n\t" .. (if at_right then "right: 0;" else "left: 0;") .. "\n\tbottom: calc(100% + 8px);",
		MOTION = if target
			then ""
			else "transform-origin: "
				.. (if at_right then "calc(100% - 16px)" else "16px")
				.. " 100%;\n\t/* after a beat: it rises into place and its meters fill */\n\tanimation:\n\t\tomp-usage-card 0.28s var(--out) 0.35s both,\n\t\tomp-usage-fill 0.7s var(--out) 0.4s both;",
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
-- tip; what doesn't move stays under them): the head appears at the bar's start, runs to the share, flares and
-- shrinks into the tip, the trail behind it; in the bar's color when quota went down, `--ok` when it came back.
local function pulse_css(line: Line, p: Pulse): string
	local frames: { string } = {}
	local still = statics(line)
	for _, at in RUN_STOPS do
		local images: { string } = table.clone(still.images)
		local positions: { string } = table.clone(still.positions)
		local sizes: { string } = table.clone(still.sizes)
		for _, bar in line.bars do
			local y = bar.row * LINE_ROW + BAR_Y
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
			table.insert(positions, string.format("%spx %spx", num(x - w / 2), num(y - h / 2)))
			table.insert(positions, string.format("%spx %spx", num(x - trail), num(y - TRAIL_H / 2)))
			table.insert(sizes, string.format("%s %spx", fits(bar.ends, w), num(h)))
			table.insert(sizes, string.format("%s %spx", fits(bar.ends, trail), num(TRAIL_H)))
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
	if #model.groups == 0 and (#model.others == 0 or not settings.parts.others) then
		return ""
	end
	local line = line_of(model, settings)
	local still = fill(STILL_CSS, { HOST = host(nil), HOST_STILL = host(".sf-still"), METER = meter(), METER_STILL = meter(".sf-still") })
	local right = settings.place == "stack" and settings.align == "right"
	local css = line_css(line, model, settings) .. card_css(card(model, hint, settings.card_rows), nil, right) .. still
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


-- The pane the line is drawn in (see `line_pane`), as window.luau's `refresh` reads and sets it.
local function current_line_pane(): string
	return line_pane
end

local function set_line_pane(scope: string)
	line_pane = scope
end

-- The settings panel's action (the `panel` command) and its default shortcut; the quota details' action.
local PANEL_ACTION = "plugin." .. tern.plugin.id .. ".panel"
local PANEL_KEYS = "ctrl+alt+u"
local DETAILS_ACTION = "plugin." .. tern.plugin.id .. ".details"

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

-- The panel's and the details' shortcuts as the keymap has them now (the user may rebind or unbind them): the
-- shortest chord bound to each, read at most every 30s (every 2s while the panel has none: the keymap takes the
-- plugin's binds a moment after a reload). `cx.actions:describe` doesn't know plugin commands, so they come from
-- the chords. `shortcut` returns the panel's; the same read leaves the details' in `details_keys`.
local SHORTCUT_TTL_MS = 30000
local SHORTCUT_RETRY_MS = 2000
local shortcut_text: string? = nil
local shortcut_read_at: number? = nil
local details_keys: string? = nil

local function shortcut(cx: WindowCx): string?
	local now = tern.now()
	local ttl = if shortcut_text then SHORTCUT_TTL_MS else SHORTCUT_RETRY_MS
	if shortcut_read_at == nil or now - (shortcut_read_at :: number) >= ttl then
		shortcut_read_at = now
		local ok, keymap = pcall(function(): any
			return cx.actions:keys()
		end)
		local best: { [string]: string } = {}
		if ok and type(keymap) == "table" then
			for chord, actions in keymap do
				if type(chord) == "string" and type(actions) == "table" then
					for _, action in { PANEL_ACTION, DETAILS_ACTION } do
						local had = best[action]
						if table.find(actions, action) and (had == nil or #chord < #had or (#chord == #had and chord < had)) then
							best[action] = chord
						end
					end
				end
			end
		end
		shortcut_text = if best[PANEL_ACTION] then chord_label(best[PANEL_ACTION]) else nil
		details_keys = if best[DETAILS_ACTION] then chord_label(best[DETAILS_ACTION]) else nil
	end
	return shortcut_text
end

-- The card's last row: how to open the details and the settings (the line itself takes no clicks).
local function settings_hint(keys: string?): string
	local parts: { string } = {}
	if details_keys then
		table.insert(parts, "details " .. details_keys)
	end
	if keys then
		table.insert(parts, "settings " .. keys)
	end
	return if #parts > 0 then table.concat(parts, " · ") else "details & settings · omp Usage in the palette"
end

-- The details' shortcut, as `shortcut` last read it.
local function details_shortcut(): string?
	return details_keys
end

return {
	PULSE_MS = PULSE_MS,
	CARD_ROW = CARD_ROW,
	card_memo = card_memo,
	set_card_memo = set_card_memo,
	last_card_runs = last_card_runs,
	fill = fill,
	line_of = line_of,
	line_paint = line_paint,
	line_height = line_height,
	tips = tips,
	FOCUSED_PANE = FOCUSED_PANE,
	line_pane = current_line_pane,
	set_line_pane = set_line_pane,
	palette_css = palette_css,
	card = card,
	card_css = card_css,
	sheet = sheet,
	hide_css = hide_css,
	install = install,
	PANEL_KEYS = PANEL_KEYS,
	PANEL_ACTION = PANEL_ACTION,
	DETAILS_ACTION = DETAILS_ACTION,
	shortcut = shortcut,
	settings_hint = settings_hint,
	details_shortcut = details_shortcut,
}
