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
}

type Amounts = { tokens: string?, cost: string? }
type Window = { row: Row, notes: { Row }, used: Amounts, estimated: Amounts }
type Account = { title: string?, windows: { Window }, notes: { Row } }

local M = {
	pane = nil :: number?,
	signature = nil :: string?,
	selector = SELECTOR,
	title = TITLE,
}

local CSS = [==[
[data-role='omp-usage.details'] {
	display: flex;
	flex-direction: column;
	gap: 24px;
	max-width: 720px;
	margin: 0 auto;
	padding: 24px;
	font: 400 13px/20px var(--sans);
	color: var(--t2);
	--oc-head: var(--t1);
	--oc-win-ok: var(--t1);
	--oc-win-warn: var(--warn);
	--oc-win-bad: var(--bad);
	--oc-mute: var(--t3);
	--oc-soft: var(--t2);
	--oc-warn: var(--warn);
}
[data-role='omp-usage.details'] .oud-heading {
	display: flex;
	align-items: center;
	flex-wrap: wrap;
	gap: 10px;
}
[data-role='omp-usage.details'] .oud-title {
	font: 600 18px/24px var(--sans);
	color: var(--t1);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-plan {
	padding: 2px 8px;
	border-radius: 999px;
	background-color: var(--l1);
	font: 500 11px/16px var(--sans);
	color: var(--t2);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-account {
	display: flex;
	flex-direction: column;
	gap: 18px;
	min-width: 0;
}
[data-role='omp-usage.details'] .oud-account + .oud-account {
	padding-top: 24px;
	border-top: 1px solid var(--l2);
}
[data-role='omp-usage.details'] .oud-account-title {
	font: 600 14px/20px var(--sans);
	color: var(--t1);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-window {
	display: flex;
	flex-direction: column;
	gap: 10px;
	min-width: 0;
}
[data-role='omp-usage.details'] .oud-window + .oud-window {
	padding-top: 18px;
	border-top: 1px solid var(--l1);
}
[data-role='omp-usage.details'] .oud-quota {
	display: flex;
	align-items: baseline;
	justify-content: space-between;
	flex-wrap: wrap;
	gap: 8px 18px;
}
[data-role='omp-usage.details'] .oud-window-name {
	font: 500 13px/20px var(--sans);
	color: var(--t2);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-share {
	font: 600 24px/30px var(--sans);
	font-variant-numeric: tabular-nums;
	color: var(--oud-tone);
}
[data-role='omp-usage.details'] .oud-track {
	height: 4px;
	border-radius: 999px;
	background-color: var(--l2);
	overflow: hidden;
}
[data-role='omp-usage.details'] .oud-fill {
	width: var(--oud-share);
	height: 4px;
	border-radius: 999px;
	background-image: linear-gradient(90deg, var(--oud-a), var(--oud-b));
}
[data-role='omp-usage.details'] .oud-metrics {
	display: flex;
	flex-wrap: wrap;
	gap: 20px 32px;
	padding-top: 8px;
}
[data-role='omp-usage.details'] .oud-metric {
	display: flex;
	flex-direction: column;
	gap: 5px;
	flex: 1 1 220px;
	min-width: 0;
}
[data-role='omp-usage.details'] .oud-label {
	font: 400 12px/18px var(--sans);
	color: var(--t3);
}
[data-role='omp-usage.details'] .oud-value {
	font: 600 23px/30px var(--sans);
	font-variant-numeric: tabular-nums;
	color: var(--t1);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-cost {
	font: 400 12px/18px var(--sans);
	font-variant-numeric: tabular-nums;
	color: var(--t2);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-note {
	font: 400 12px/18px var(--sans);
	color: var(--t3);
	overflow-wrap: anywhere;
}
[data-role='omp-usage.details'] .oud-warning { color: var(--warn); }
[data-role='omp-usage.details'] .oud-error { color: var(--bad); }
[data-role='omp-usage.details'] .oud-disclaimer {
	padding-top: 16px;
	border-top: 1px solid var(--l1);
	font: 400 11px/17px var(--sans);
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

local function note(row: Row): Node
	local class = "oud-note"
	if row.kind == "stale" or row.color == "var(--oc-warn)" then class ..= " oud-warning" end
	if row.kind == "error" then class ..= " oud-error" end
	return ui.el("div", { class = class, text = string.gsub(row.text, "^%s+", "") })
end

local function metric(label: string, values: Amounts): Node?
	if values.tokens == nil and values.cost == nil then return nil end
	local children = { ui.el("span", { class = "oud-label", text = label }) }
	if values.tokens then
		table.insert(children, ui.el("span", { class = "oud-value", text = values.tokens }))
	end
	if values.cost then
		table.insert(children, ui.el("span", {
			class = if values.tokens then "oud-cost" else "oud-value",
			text = if values.tokens then "API-equivalent · " .. values.cost else values.cost,
		}))
		if values.tokens == nil then
			table.insert(children, ui.el("span", { class = "oud-cost", text = "API-equivalent value" }))
		end
	end
	return ui.el("div", { class = "oud-metric" }, children)
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
	local accounts = accounts_of(rows)
	local estimated, has_cost = false, false
	local window_index = 0
	local title = if rows[1] then rows[1].text else "Usage"
	if #accounts > 1 or (accounts[1] and accounts[1].title ~= nil) then
		table.insert(children, ui.el("div", { class = "oud-title", text = title }))
	end
	for index, account in accounts do
		local body: { Node } = {}
		local heading = { ui.el("span", {
			class = if #accounts == 1 and account.title == nil then "oud-title" else "oud-account-title",
			text = account.title or title,
		}) }
		local plan: string? = nil
		local conflicting_plan = false
		for _, row in account.notes do
			if row.kind == "plan" and row.value and not row.shared then
				if plan and plan ~= row.value then conflicting_plan = true end
				plan = row.value
			end
		end
		if plan and not conflicting_plan then
			table.insert(heading, ui.el("span", { class = "oud-plan", text = plan }))
		end
		table.insert(body, ui.el("div", { class = "oud-heading" }, heading))
		for _, window in account.windows do
			window_index += 1
			local row = window.row
			local id = tostring(window_index)
			table.insert(rules, string.format(
				"%s [data-window='%s'] { --oud-share: %.4f%%; --oud-a: %s; --oud-b: %s; --oud-tone: %s; }",
				SELECTOR, id, (row.share or 0) * 100, row.a or "var(--accent)", row.b or row.a or "var(--accent)", row.color
			))
			local content = {
				ui.el("div", { class = "oud-quota" }, {
					ui.el("span", { class = "oud-window-name", text = row.text }),
					ui.el("span", { class = "oud-share", text = row.right }),
				}),
				ui.el("div", { class = "oud-track", attrs = { role = "meter", ["aria-label"] = row.text .. " remaining", ["aria-valuenow"] = tostring((row.share or 0) * 100), ["aria-valuemin"] = "0", ["aria-valuemax"] = "100" } }, {
					ui.el("div", { class = "oud-fill" }),
				}),
			}
			for _, item in window.notes do table.insert(content, note(item)) end
			local metrics: { Node } = {}
			local observed = metric("Observed usage", window.used)
			local remaining = metric("Estimated remaining", window.estimated)
			if observed then table.insert(metrics, observed) end
			if remaining then table.insert(metrics, remaining); estimated = true end
			has_cost = has_cost or window.used.cost ~= nil or window.estimated.cost ~= nil
			if #metrics > 0 then table.insert(content, ui.el("div", { class = "oud-metrics" }, metrics)) end
			table.insert(body, ui.el("div", { class = "oud-window", attrs = { ["data-window"] = id } }, content))
		end
		for _, row in account.notes do
			if not (plan and not conflicting_plan and row.kind == "plan" and row.value == plan and not row.shared) then
				table.insert(body, note(row))
			end
		end
		table.insert(children, ui.el("section", { class = "oud-account", key = "account-" .. tostring(index) }, body))
	end
	if #rows <= 1 then
		table.insert(children, ui.el("div", { class = "oud-note", text = "No quota data for this view. Choose a provider in Settings, or focus an omp pane with a quota source." }))
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
