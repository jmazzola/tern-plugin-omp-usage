--!strict
-- Native quota details. The caller supplies the same account/window rows as the hover summary, with
-- semantic values intact. This view neither fetches quotas nor calculates or combines quantities.
local ui = tern.ui
local TITLE = "omp Usage details"
local ROLE = "omp-usage.details"
local DOCK_ROLE = "omp-usage.details-dock"
local SELECTOR = "[data-role='" .. ROLE .. "']"
local SHEET = "quota-details"

export type Row = {
	text: string,
	color: string,
	right: string?,
	share: number?,
	a: string?,
	b: string?,
	rule: boolean?,
	heading: boolean?,
	kind: string?,
	value: string?,
	account_note: boolean?,
	shared: boolean?,
	-- hover only: a pill at the row's right end (an account's plan), icons drawn over blank cells of the row's
	-- text (`cell`: the first of the icon's three cells; `kind`: "tokens" or "cost"), and on a heading, how many
	-- rows (its own first) the bar in its provider's colors (`a`, `b`) runs beside
	badge: string?,
	icons: { { cell: number, kind: string } }?,
	bar: number?,
}

type Amounts = { tokens: string?, cost: string? }
type Window = { row: Row, notes: { Row }, used: Amounts, estimated: Amounts }
-- `color`: its heading's (a provider's palette color, or a muted one for an account summed up on one row)
type Account = { title: string?, color: string?, windows: { Window }, notes: { Row } }

local M = {
	pane = nil :: number?,
	signature = nil :: string?,
	selector = SELECTOR,
	title = TITLE,
}

-- In the settings panel's voice (panel.luau's PANEL_CSS): mono micro-labels over hairlines, each account in its
-- provider's colors (the palette rules set `--ou-g<N>-a|b`), quiet wells for the windows. Colors from the palette
-- go through relative colors: Tern drops a gradient stop whose `var()` holds `light-dark()`. No transitions or
-- animations, so Reduce Motion has nothing to stop.
local CSS = [==[
[data-role='omp-usage.details'] {
	display: flex;
	flex-direction: column;
	gap: 30px;
	box-sizing: border-box;
	width: 100%;
	max-width: 800px;
	margin: 0 auto;
	padding: 22px 22px 30px;
	font: 400 12.5px/18px var(--sans);
	color: var(--t2);
	--oc-head: var(--t1);
	--oc-win-ok: var(--t1);
	--oc-win-warn: var(--warn);
	--oc-win-bad: var(--bad);
	--oc-mute: var(--t3);
	--oc-soft: var(--t2);
	--oc-warn: var(--warn);
	--oud-pa: var(--accent);
	--oud-pb: var(--accent);
}
/* the view's title, over several accounts: a micro-label, as the panel heads its sections */
[data-role='omp-usage.details'] .oud-title {
	margin-bottom: -10px;
	font: 600 10px/14px var(--mono);
	letter-spacing: 0.16em;
	text-transform: uppercase;
	color: var(--t3);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-account {
	display: flex;
	flex-direction: column;
	gap: 12px;
	min-width: 0;
}
/* an account's head over a hairline: its provider's swatch and name, the plan it names, when it was observed */
[data-role='omp-usage.details'] .oud-heading {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 6px 10px;
	padding: 0 2px 9px;
	border-bottom: 1px solid var(--l2);
}
[data-role='omp-usage.details'] .oud-swatch {
	flex: none;
	width: 20px;
	height: 6px;
	border-radius: 3px;
	background-image: linear-gradient(90deg, rgb(from var(--oud-pa) r g b), rgb(from var(--oud-pb) r g b));
	box-shadow: 0 0 10px -1px rgb(from var(--oud-pb) r g b / 55%);
}
[data-role='omp-usage.details'] .oud-account-title {
	min-width: 0;
	font: 600 13px/18px var(--mono);
	color: rgb(from var(--oud-pa) r g b);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-plan {
	flex: none;
	height: 20px;
	padding: 0 8px;
	border-radius: 10px;
	font: 500 10.5px/20px var(--mono);
	white-space: nowrap;
	color: rgb(from var(--oud-pa) r g b);
	background-color: rgb(from var(--oud-pa) r g b / 10%);
	box-shadow: 0 0 0 1px rgb(from var(--oud-pa) r g b / 40%);
}
[data-role='omp-usage.details'] .oud-stamp {
	margin-left: auto;
	font: 500 10.5px/14px var(--mono);
	font-variant-numeric: tabular-nums;
	color: var(--t3);
	overflow-wrap: anywhere;
}
/* the account's windows: wells side by side, a column when the pane is narrow */
[data-role='omp-usage.details'] .oud-windows {
	display: flex;
	flex-wrap: wrap;
	gap: 10px;
}
[data-role='omp-usage.details'] .oud-window {
	display: flex;
	flex: 1 1 300px;
	flex-direction: column;
	gap: 9px;
	min-width: 0;
	padding: 12px 14px 13px;
	border-radius: 10px;
	background-color: var(--well);
	box-shadow:
		0 0 0 1px var(--l1),
		inset 0 1px 0 var(--glass-hi);
}
/* a window running low is ringed in its tone */
[data-role='omp-usage.details'] .oud-window.oud-low {
	background-color: rgb(from var(--oud-tone) r g b / 5%);
	box-shadow:
		0 0 0 1px rgb(from var(--oud-tone) r g b / 28%),
		inset 0 1px 0 var(--glass-hi);
}
[data-role='omp-usage.details'] .oud-quota {
	display: flex;
	flex-wrap: wrap;
	align-items: baseline;
	justify-content: space-between;
	gap: 4px 14px;
}
[data-role='omp-usage.details'] .oud-window-name {
	min-width: 0;
	font: 600 10px/14px var(--mono);
	letter-spacing: 0.14em;
	text-transform: uppercase;
	color: var(--t3);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-share {
	display: flex;
	align-items: baseline;
	gap: 5px;
	white-space: nowrap;
}
[data-role='omp-usage.details'] .oud-share-n {
	font: 600 22px/26px var(--sans);
	font-variant-numeric: tabular-nums;
	letter-spacing: -0.01em;
	color: rgb(from var(--oud-tone) r g b);
}
[data-role='omp-usage.details'] .oud-share-u {
	font: 500 10.5px/14px var(--mono);
	color: var(--t3);
}
/* the meter, drawn as the line draws its bars: from the provider's first color, faint, to its second, with a lit
   tip where the window stands */
[data-role='omp-usage.details'] .oud-track {
	height: 6px;
	border-radius: 3px;
	background-color: color-mix(in srgb, var(--t1) 10%, transparent);
}
[data-role='omp-usage.details'] .oud-fill {
	width: var(--oud-share);
	height: 6px;
	border-radius: 3px;
	background-image: linear-gradient(90deg, rgb(from var(--oud-a) r g b / 40%), rgb(from var(--oud-b) r g b));
	box-shadow: 4px 0 12px -3px rgb(from var(--oud-b) r g b / 75%);
}
[data-role='omp-usage.details'] .oud-notes {
	display: flex;
	flex-direction: column;
	gap: 3px;
	min-width: 0;
}
[data-role='omp-usage.details'] .oud-note {
	font: 500 11px/16px var(--mono);
	font-variant-numeric: tabular-nums;
	color: var(--t3);
	overflow-wrap: anywhere;
}
/* a saved reset, in its provider's color as on the line */
[data-role='omp-usage.details'] .oud-lit {
	color: rgb(from var(--oud-pa) r g b);
}
[data-role='omp-usage.details'] .oud-warning,
[data-role='omp-usage.details'] .oud-error {
	display: flex;
	align-items: center;
	gap: 8px;
	color: var(--warn);
}
[data-role='omp-usage.details'] .oud-error {
	color: var(--bad);
}
[data-role='omp-usage.details'] .oud-warning::before,
[data-role='omp-usage.details'] .oud-error::before {
	content: "";
	flex: none;
	width: 6px;
	height: 6px;
	border-radius: 3px;
	background-color: currentColor;
	box-shadow: 0 0 8px currentColor;
}
/* what the source observed and estimates for the window, under a hairline */
[data-role='omp-usage.details'] .oud-metrics {
	display: flex;
	flex-wrap: wrap;
	gap: 10px 18px;
	margin-top: 3px;
	padding-top: 11px;
	border-top: 1px solid var(--l1);
}
[data-role='omp-usage.details'] .oud-metric {
	display: flex;
	flex: 1 1 130px;
	flex-direction: column;
	gap: 3px;
	min-width: 0;
}
[data-role='omp-usage.details'] .oud-label {
	font: 600 9.5px/14px var(--mono);
	letter-spacing: 0.14em;
	text-transform: uppercase;
	color: var(--t4);
}
[data-role='omp-usage.details'] .oud-value {
	font: 600 16px/22px var(--sans);
	font-variant-numeric: tabular-nums;
	color: var(--t1);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-cost {
	display: flex;
	flex-wrap: wrap;
	gap: 0 6px;
	font: 500 10.5px/15px var(--mono);
	font-variant-numeric: tabular-nums;
	color: var(--t2);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-cost-k {
	color: var(--t4);
}
/* nothing to show: a quiet well, not a bare line */
[data-role='omp-usage.details'] .oud-empty {
	display: flex;
	align-items: flex-start;
	gap: 12px;
	padding: 16px 18px;
	border-radius: 10px;
	background-color: var(--well);
	box-shadow: 0 0 0 1px var(--l1);
}
[data-role='omp-usage.details'] .oud-empty > .sf-icon {
	flex: none;
	margin-top: 1px;
	color: var(--t3);
}
[data-role='omp-usage.details'] .oud-empty-t {
	font: 600 12.5px/18px var(--sans);
	color: var(--t1);
}
[data-role='omp-usage.details'] .oud-empty-d {
	font: 400 12px/18px var(--sans);
	color: var(--t3);
}
[data-role='omp-usage.details'] .oud-disclaimer {
	padding: 12px 2px 0;
	border-top: 1px solid var(--l1);
	font: 400 11px/16px var(--sans);
	color: var(--t3);
}
[data-role='omp-usage.details-dock'] {
	display: flex;
	flex-wrap: wrap;
	gap: 8px;
}
]==]

function M.color(kind: string?): string
	return if kind == "stale" then "var(--oc-warn)" elseif kind == "error" then "var(--bad)" else "var(--oc-soft)"
end

-- `lit`: the account's provider color; a row in it (a saved reset) keeps it.
local function note(row: Row, lit: string?): Node
	local class = "oud-note"
	if row.kind == "stale" or row.color == "var(--oc-warn)" then
		class ..= " oud-warning"
	elseif row.kind == "error" then
		class ..= " oud-error"
	elseif lit and row.color == lit then
		class ..= " oud-lit"
	end
	return ui.el("div", { class = class, text = string.gsub(row.text, "^%s+", "") })
end

local function metric(label: string, values: Amounts): Node?
	if values.tokens == nil and values.cost == nil then return nil end
	local children = { ui.el("span", { class = "oud-label", text = label }) }
	if values.tokens then
		table.insert(children, ui.el("span", { class = "oud-value", text = values.tokens }))
	end
	if values.cost then
		if values.tokens then
			table.insert(children, ui.el("span", { class = "oud-cost" }, {
				ui.el("span", { text = values.cost }),
				ui.el("span", { class = "oud-cost-k", text = "API-equivalent" }),
			}))
		else
			table.insert(children, ui.el("span", { class = "oud-value", text = values.cost }))
			table.insert(children, ui.el("span", { class = "oud-cost oud-cost-k", text = "API-equivalent value" }))
		end
	end
	return ui.el("div", { class = "oud-metric" }, children)
end

-- An account's provider color: the first a provider's palette gives among its rows (its heading's, a saved
-- reset's, a window's while its share is fine), as the line paints it.
local function account_color(account: Account): string?
	local candidates: { string? } = {}
	for _, window in account.windows do
		for _, row in window.notes do table.insert(candidates, row.color) end
		table.insert(candidates, window.row.a)
	end
	for _, row in account.notes do table.insert(candidates, row.color) end
	for _, color in candidates do
		if color and string.match(color, "^var%(%-%-ou%-g%d+%-a%)$") then return color end
	end
	return nil
end

-- Rows already follow the selected account/window scope. Only a window-scoped typed value enters its
-- metric; duplicates, unknown kinds and account-level quantities remain readable notes.
local function accounts_of(rows: { Row }): { Account }
	local accounts: { Account } = {}
	local current: Account = { title = nil, windows = {}, notes = {} }
	local window: Window? = nil
	table.insert(accounts, current)
	for index, row in rows do
		if index == 1 then continue end
		if row.heading then
			if #current.windows == 0 and #current.notes == 0 and current.title == nil then
				current.title = row.text
			else
				current = { title = row.text, windows = {}, notes = {} }
				table.insert(accounts, current)
			end
			current.color = row.color
			window = nil
		elseif row.right ~= nil and row.share ~= nil then
			window = { row = row, notes = {}, used = {}, estimated = {} }
			table.insert(current.windows, window :: Window)
		else
			local taken = false
			if window and not row.account_note and row.value then
				local amounts = if row.kind == "tokens-used" or row.kind == "cost-used" then window.used
					elseif row.kind == "tokens-estimate" or row.kind == "cost-estimate" then window.estimated else nil
				if amounts then
					local field = if row.kind == "tokens-used" or row.kind == "tokens-estimate" then "tokens" else "cost"
					if amounts[field] == nil then
						amounts[field] = row.value
						taken = true
					end
				end
			end
			if not taken then
				table.insert(if window and not row.account_note then window.notes else current.notes, row)
			end
		end
	end
	return accounts
end

local function view(rows: { Row }): (Node, string)
	local children: { Node } = {}
	local rules: { string } = {}
	local accounts: { Account } = if #rows > 1 then accounts_of(rows) else {}
	local estimated, has_cost = false, false
	local window_index = 0
	local title = if rows[1] then rows[1].text else "Usage"
	if #accounts > 1 or (accounts[1] and accounts[1].title ~= nil) then
		table.insert(children, ui.el("div", { class = "oud-title", text = title }))
	end
	for index, account in accounts do
		local body: { Node } = {}
		local lit = account_color(account)
		local color = account.color or lit
		if color then
			table.insert(rules, string.format("%s [data-account='%d'] { --oud-pa: %s; --oud-pb: %s; }",
				SELECTOR, index, color, (string.gsub(color, "^(var%(%-%-ou%-g%d+)%-a%)$", "%1-b)"))))
		end
		local heading = {
			ui.el("span", { class = "oud-swatch" }),
			ui.el("span", { class = "oud-account-title", text = account.title or title }),
		}
		local plan: string? = nil
		local conflicting_plan = false
		local stamp: Row? = nil
		for _, row in account.notes do
			if row.kind == "plan" and row.value and not row.shared then
				if plan and plan ~= row.value then conflicting_plan = true end
				plan = row.value
			elseif row.kind == "observed" and row.value and not row.shared and stamp == nil then
				stamp = row
			end
		end
		if plan and not conflicting_plan then
			table.insert(heading, ui.el("span", { class = "oud-plan", text = plan }))
		end
		if stamp then
			table.insert(heading, ui.el("span", { class = "oud-stamp", text = string.gsub(stamp.text, "^%s+", "") }))
		end
		table.insert(body, ui.el("div", { class = "oud-heading" }, heading))
		local wells: { Node } = {}
		for _, window in account.windows do
			window_index += 1
			local row = window.row
			local id = tostring(window_index)
			table.insert(rules, string.format(
				"%s [data-window='%s'] { --oud-share: %.4f%%; --oud-a: %s; --oud-b: %s; --oud-tone: %s; }",
				SELECTOR, id, (row.share or 0) * 100, row.a or "var(--accent)", row.b or row.a or "var(--accent)", row.color
			))
			-- `64% left`: the share large, the word after it small
			local share, unit = string.match(row.right or "", "^(%S+)%s+(.+)$")
			-- a window the line paints `--warn` or `--bad`
			local low = string.match(row.color, "%-warn%)$") ~= nil or string.match(row.color, "%-bad%)$") ~= nil
			local content = {
				ui.el("div", { class = "oud-quota" }, {
					ui.el("span", { class = "oud-window-name", text = row.text }),
					ui.el("span", { class = "oud-share" }, {
						ui.el("span", { class = "oud-share-n", text = share or row.right }),
						ui.el("span", { class = "oud-share-u", text = unit or "" }),
					}),
				}),
				ui.el("div", { class = "oud-track", attrs = { role = "meter", ["aria-label"] = row.text .. (if unit == "used" then " used" else " remaining"), ["aria-valuenow"] = tostring((row.share or 0) * 100), ["aria-valuemin"] = "0", ["aria-valuemax"] = "100" } }, {
					ui.el("div", { class = "oud-fill" }),
				}),
			}
			if #window.notes > 0 then
				local notes: { Node } = {}
				for _, item in window.notes do table.insert(notes, note(item, lit)) end
				table.insert(content, ui.el("div", { class = "oud-notes" }, notes))
			end
			local metrics: { Node } = {}
			local observed = metric("Observed usage", window.used)
			local remaining = metric("Estimated remaining", window.estimated)
			if observed then table.insert(metrics, observed) end
			if remaining then table.insert(metrics, remaining); estimated = true end
			has_cost = has_cost or window.used.cost ~= nil or window.estimated.cost ~= nil
			if #metrics > 0 then table.insert(content, ui.el("div", { class = "oud-metrics" }, metrics)) end
			table.insert(wells, ui.el("div", {
				class = if low then "oud-window oud-low" else "oud-window",
				attrs = { ["data-window"] = id },
			}, content))
		end
		if #wells > 0 then table.insert(body, ui.el("div", { class = "oud-windows" }, wells)) end
		local notes: { Node } = {}
		for _, row in account.notes do
			if not (plan and not conflicting_plan and row.kind == "plan" and row.value == plan and not row.shared) and row ~= stamp then
				table.insert(notes, note(row, lit))
			end
		end
		if #notes > 0 then table.insert(body, ui.el("div", { class = "oud-notes" }, notes)) end
		table.insert(children, ui.el("section", { class = "oud-account", key = "account-" .. tostring(index), attrs = { ["data-account"] = tostring(index) } }, body))
	end
	if #rows <= 1 then
		table.insert(children, ui.el("div", { class = "oud-empty" }, {
			ui.node("icon", { name = "gauge" }),
			ui.el("div", {}, {
				ui.el("div", { class = "oud-empty-t", text = "No quota data for this view" }),
				ui.el("div", { class = "oud-empty-d", text = "Choose a provider in Settings, or focus an omp pane with a quota source." }),
			}),
		}))
	end
	if estimated or has_cost then
		local text = if estimated then "Estimates assume the same workload mix; they are not official token allowances." else ""
		if has_cost then text ..= (if text ~= "" then " " else "") .. "API-equivalent values are not cash balances." end
		table.insert(children, ui.el("div", { class = "oud-disclaimer", text = text }))
	end
	return ui.el("div", { role = ROLE }, children), table.concat(rules, "\n")
end

local function dock(): Node
	return ui.el("div", { role = DOCK_ROLE }, {
		ui.button("Settings", { icon = "sliders", variant = "quiet", actions = { click = "settings" } }),
		ui.button("Close", { variant = "quiet", actions = { click = "close" } }),
	})
end

function M.restore(cx: WindowCx)
	M.pane, M.signature = nil, nil
	for _, info in cx.canvas:list() do
		if info.owner == tern.plugin.id and info.title == TITLE then M.pane = info.pane; return end
	end
end

function M.show(cx: WindowCx, rows: { Row }, palette: string, signature: string, open: boolean)
	if not open and (M.pane == nil or M.signature == signature) then return end
	local body, rules = view(rows)
	tern.css(SHEET, CSS .. "\n" .. palette .. "\n" .. rules)
	if M.pane then
		local ok = pcall(function()
			cx.canvas:set(M.pane :: number, { view = body, dock = dock() })
			if open then cx.layout:focus(M.pane :: number) end
		end)
		if ok then M.signature = signature; return end
		M.pane, M.signature = nil, nil
	end
	if not open then return end
	local pane, err = cx.canvas:open({
		title = TITLE,
		about = "Read-only quota details for the same source, accounts and windows as the usage line. Settings opens the plugin preferences; Close dismisses the view. No quota requests are made here.",
		view = body, dock = dock(), how = "glimpse",
	})
	if pane then
		M.pane, M.signature = pane, signature
		cx.layout:focus(pane)
	else
		cx:toast("error", "Usage details didn't open", err)
	end
end

function M.close(cx: WindowCx, pane: number)
	cx.layout:close(pane)
	M.pane, M.signature = nil, nil
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean
	if ev.title ~= TITLE or ev.act ~= "close" then return false end
	M.close(cx, ev.pane)
	return true
end)

tern.on("pane_closed", function(ev: { pane: number }, _cx: WindowCx)
	if ev.pane == M.pane then M.pane, M.signature = nil, nil end
end)

return M
