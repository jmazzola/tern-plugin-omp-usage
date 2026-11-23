--!strict
-- The settings as pickers (`omp Usage: Settings…`, opened from window.luau), and the changes both they and the
-- settings panel (panel.luau) make: each stores one setting in `tern.kv`, then redraws the line and the panel.
local data = require("./data")
local update = require("./update")
local alerts = require("./alerts")

type Provider = data.Provider
type Settings = data.Settings

local NAMED = data.NAMED
local KV_MODE = data.KV_MODE
local KV_SELECTED = data.KV_SELECTED
local KV_COLORS = data.KV_COLORS
local KV_ORDER = data.KV_ORDER
local KV_HIDDEN = data.KV_HIDDEN
local KV_ACCOUNT = data.KV_ACCOUNT
local KV_ACCOUNT_ORDER = data.KV_ACCOUNT_ORDER
local KV_ACCOUNT_HIDDEN = data.KV_ACCOUNT_HIDDEN
local COMBINED = data.COMBINED
local COMBINED_PLANS = data.COMBINED_PLANS
local store = data.store
local load_settings = data.load_settings
local shown_windows = data.shown_windows
local accounts_in_order = data.accounts_in_order
local account_of = data.account_of
local account_off = data.account_off
local chosen_account = data.chosen_account
local window_name = data.window_name
local shown_accounts = data.shown_accounts
local ordered = data.ordered
local moved = data.moved
local parse_colors = data.parse_colors
local palette_of_spec = data.palette_of_spec
local color_key = data.color_key
local preset_for = data.preset_for

-- What a change redraws through: window.luau's `refresh` and the panel's `flush_panel`. Both modules require this
-- one, so window.luau hands them over with `init`.
local refresh: (cx: WindowCx) -> ()
local flush_panel: (cx: WindowCx) -> ()

local function init(on_refresh: (cx: WindowCx) -> (), on_flush: (cx: WindowCx) -> ())
	refresh, flush_panel = on_refresh, on_flush
end

-- The providers on offer, in the user's order.
local function providers_in_order(settings: Settings): { Provider }
	return ordered(store.providers(), settings.order)
end

local function label_of(providers: { Provider }, id: string): string
	for _, provider in providers do
		if provider.id == id then
			return provider.label
		end
	end
	return id
end

-- The providers `selected` shows, by label in the user's order; nil when there are none.
local function chosen_labels(settings: Settings, providers: { Provider }): string?
	local chosen: { string } = {}
	for _, provider in providers do
		if table.find(settings.selected, provider.id) then
			table.insert(chosen, provider.label)
		end
	end
	for _, id in settings.selected do
		if label_of(providers, id) == id then -- not on offer now
			table.insert(chosen, id)
		end
	end
	return if #chosen > 0 then table.concat(chosen, ", ") else nil
end

local MODES: { { mode: string, label: string } } = {
	{ mode = "current", label = "Current model" },
	{ mode = "all", label = "All providers" },
	{ mode = "selected", label = "Selected providers" },
}

-- What each mode shows, for the menu and the panel.
local function mode_details(settings: Settings, providers: { Provider }): { [string]: string }
	-- the cache's providers carry their lines; the known ones offered without a cache don't
	local cached = providers[1] ~= nil and providers[1].line ~= ""
	return {
		current = "the focused agent's provider",
		all = if cached then string.format("%d with limits", #providers) else "waiting for omp's usage cache",
		selected = chosen_labels(settings, providers) or "none chosen yet",
	}
end

-- The first few providers, in order.
local function order_summary(providers: { Provider }): string
	local labels: { string } = {}
	for i, provider in providers do
		if i > 3 then
			table.insert(labels, "…")
			break
		end
		table.insert(labels, provider.label)
	end
	return table.concat(labels, ", ")
end

-- The providers with several accounts, in order.
local function with_accounts(providers: { Provider }): { Provider }
	local list: { Provider } = {}
	for _, provider in providers do
		if #provider.accounts > 1 then
			table.insert(list, provider)
		end
	end
	return list
end

-- What a provider's accounts show, for the menus: `only alice`, `all: bob, alice` in their order, or how many
-- are on when there are many or some are switched off.
local function accounts_summary(settings: Settings, provider: Provider): string
	local chosen = chosen_account(settings, provider.id, provider.accounts)
	if chosen then
		return "only " .. chosen
	elseif settings.account[provider.id] == COMBINED then
		return "combined"
	elseif settings.account[provider.id] == COMBINED_PLANS then
		return "combined by plan"
	end
	local shown = shown_accounts(settings, provider)
	if #shown < #provider.accounts then
		return string.format("%d of %d on", #shown, #provider.accounts)
	elseif #shown > 3 then
		return string.format("all %d", #shown)
	end
	return "all: " .. table.concat(shown, ", ")
end

-- Every account whose provider names its plan, as the Plans picker lists them.
local function plan_items(settings: Settings, providers: { Provider }): { PickItem }
	local items: { PickItem } = {}
	for _, provider in providers do
		local several = #provider.accounts > 1
		local keys: { string } = if several then accounts_in_order(provider.accounts, settings.account_order[provider.id]) else { "" }
		for _, key in keys do
			local account = if several then key else nil
			local plan = data.plan_in(provider.details, account)
			if plan then
				table.insert(items, {
					label = provider.label .. (if account then " " .. account else ""),
					detail = plan,
					current = not data.plan_off(settings, provider.id, key),
					id = provider.id,
					name = key,
				})
			end
		end
	end
	return items
end

-- What Alerts do, for the menu and the panel.
local ALERTS_DETAIL = "a toast at 25%, 10% and 0% left, and before a saved reset expires"

local function menu_items(settings: Settings, providers: { Provider }, keys: string?): { PickItem }
	local details = mode_details(settings, providers)
	local items: { PickItem } = {
		{
			label = "Open settings panel…",
			detail = "every setting in one place" .. (if keys then " · " .. keys else ""),
			icon = "sliders",
			pick = "panel",
		},
	}
	for _, mode in MODES do
		table.insert(items, {
			label = mode.label,
			detail = details[mode.mode],
			group = "Show",
			current = settings.mode == mode.mode,
			pick = "mode",
			mode = mode.mode,
		})
	end
	table.insert(items, { label = "Choose providers…", detail = details.selected, group = "Providers", pick = "choose" })
	-- only with something to reorder
	if #providers > 1 then
		table.insert(items, { label = "Reorder providers…", detail = order_summary(providers), group = "Providers", pick = "reorder" })
	end
	table.insert(items, { label = "Provider colors…", detail = "presets, alternatives or your own", group = "Providers", pick = "colors" })
	table.insert(items, { label = "Provider windows…", detail = "which of each provider's windows show", group = "Providers", pick = "windows" })
	-- only with a provider signed in more than once
	local several = with_accounts(providers)
	if #several > 0 then
		table.insert(items, {
			label = "Provider accounts…",
			detail = if #several == 1 then several[1].label .. ", " .. accounts_summary(settings, several[1]) else "all of a provider's accounts, combined, or one",
			group = "Providers",
			pick = "accounts",
		})
	end
	-- only with a plan to show or hide
	if #plan_items(settings, providers) > 0 then
		table.insert(items, { label = "Plans…", detail = "which accounts' plans show in the card", group = "Providers", pick = "plans" })
	end
	table.insert(items, { label = "Card height…", detail = string.format("%d rows; past it, accounts sum up, then fold", settings.card_rows), group = "Card", pick = "card-rows" })
	local pace = data.PACES[1]
	for _, choice in data.PACES do
		if choice.id == settings.pace then
			pace = choice
		end
	end
	table.insert(items, { label = "Show pace…", detail = pace.label .. ": " .. pace.detail, group = "Card", pick = "pace" })
	local backdrop = data.BACKDROPS[1].label
	for _, choice in data.BACKDROPS do
		if choice.id == settings.backdrop then
			backdrop = choice.label
		end
	end
	table.insert(items, { label = "Line background…", detail = backdrop .. "; keeps the line readable over the chat", group = "Card", pick = "backdrop" })
	local opens = data.USAGE_OPENS[1].label
	for _, choice in data.USAGE_OPENS do
		if choice.id == settings.usage_opens then
			opens = choice.label
		end
	end
	table.insert(items, { label = "Widget bar gauge…", detail = "a click opens the " .. string.lower(opens) .. "; it warns while a window runs ahead of its pace", group = "Widget bar", pick = "usage-opens" })
	table.insert(items, { label = "Alerts…", detail = if alerts.enabled() then "on: " .. ALERTS_DETAIL else "off", group = "Alerts", pick = "alerts" })
	table.insert(items, { label = "Check for updates…", detail = "fetch the plugin's repository and offer what's new", group = "Updates", icon = "download", pick = "update" })
	local every = update.interval()
	table.insert(items, {
		label = "Check automatically…",
		detail = every.label,
		group = "Updates",
		pick = "update-every",
	})
	return items
end

-- The selection with `id` added or taken out.
local function toggled(selected: { string }, id: string): { string }
	local list = table.clone(selected)
	local at = table.find(list, id)
	if at then
		table.remove(list, at)
	else
		table.insert(list, id)
	end
	return list
end

local function chooser_items(settings: Settings, providers: { Provider }): { PickItem }
	local items: { PickItem } = {}
	for _, provider in providers do
		table.insert(items, {
			label = provider.label,
			detail = provider.id,
			current = table.find(settings.selected, provider.id) ~= nil,
			pick = "toggle",
			id = provider.id,
		})
	end
	return items
end

local function reorder_items(providers: { Provider }): { PickItem }
	local items: { PickItem } = {}
	for i, provider in providers do
		table.insert(items, { label = provider.label, detail = string.format("%d of %d", i, #providers), pick = "provider", id = provider.id })
	end
	return items
end

-- The moves open to the `i`th of `n` providers.
local function move_items(i: number, n: number): { PickItem }
	local items: { PickItem } = {}
	if i > 1 then
		table.insert(items, { label = "Move up", icon = "arrow-up", pick = "up" })
	end
	if i < n then
		table.insert(items, { label = "Move down", icon = "arrow-down", pick = "down" })
	end
	if i > 1 then
		table.insert(items, { label = "Move to top", icon = "chev-up", pick = "top" })
	end
	if i < n then
		table.insert(items, { label = "Move to bottom", icon = "chev", pick = "bottom" })
	end
	return items
end

-- A color choice's name: the user's, else the preset's.
local function color_name(settings: Settings, provider: Provider): string
	local spec = settings.colors[color_key(provider.id, provider.label)]
	local chosen = if spec then palette_of_spec(spec) else nil
	return if chosen then chosen.name else preset_for(provider.id, provider.label).name .. " (preset)"
end

local function color_provider_items(settings: Settings, providers: { Provider }): { PickItem }
	local items: { PickItem } = {}
	for _, provider in providers do
		table.insert(items, {
			label = provider.label,
			detail = color_name(settings, provider),
			pick = "provider",
			id = provider.id,
			name = provider.label,
		})
	end
	return items
end

local function color_items(settings: Settings, provider: Provider): { PickItem }
	local spec = settings.colors[color_key(provider.id, provider.label)]
	local custom = spec ~= nil and string.sub(spec :: string, 1, 1) == "#"
	local items: { PickItem } = {
		{
			label = preset_for(provider.id, provider.label).name,
			detail = "preset",
			group = "Preset",
			current = spec == nil,
			pick = "set",
		},
	}
	for _, item in NAMED do
		table.insert(items, {
			label = item.palette.name,
			group = "Alternatives",
			current = spec == "named:" .. item.key,
			pick = "set",
			spec = "named:" .. item.key,
		})
	end
	table.insert(items, {
		label = "Custom…",
		detail = if custom then spec else "one or two hex colors",
		group = "Custom",
		current = custom,
		pick = "custom",
	})
	table.insert(items, { label = "Reset to preset", group = "Custom", pick = "set" })
	return items
end

local function save_color(id: string, spec: string?)
	local colors = load_settings().colors
	if spec then
		colors[id] = spec
	else
		colors[id] = nil
	end
	store.set(KV_COLORS, colors)
end

-- Hides provider `id`'s window `label` from the line, or shows it again.
local function toggle_window(id: string, label: string)
	local hidden = load_settings().hidden
	local list = toggled(hidden[id] or {}, string.lower(label))
	if #list > 0 then
		hidden[id] = list
	else
		hidden[id] = nil
	end
	store.set(KV_HIDDEN, hidden)
end

-- Moves provider `id` (`how`: see `moved`).
local function move_provider(id: string, how: string | number)
	local settings = load_settings()
	local shown: { string } = {}
	for _, provider in providers_in_order(settings) do
		table.insert(shown, provider.id)
	end
	store.set(KV_ORDER, moved(settings.order, shown, id, how))
end

-- The provider on offer as `id`.
local function offered(id: string): Provider?
	for _, provider in store.providers() do
		if provider.id == id then
			return provider
		end
	end
	return nil
end

-- Shows only account `name` of provider `id` on the line and in the card, its accounts combined (COMBINED, or by plan,
-- COMBINED_PLANS), or ("") every account again.
local function choose_account(id: string, name: string)
	local chosen = load_settings().account
	if name == "" then
		chosen[id] = nil
	else
		chosen[id] = name
	end
	store.set(KV_ACCOUNT, chosen)
end

-- Switches account `name` of provider `id` off (out of the line and the card) or on again. The account picked to
-- show alone can't stay picked while it is off, so switching it off shows the others again.
local function toggle_account(id: string, name: string)
	local settings = load_settings()
	local list = toggled(settings.account_hidden[id] or {}, name)
	if #list > 0 then
		settings.account_hidden[id] = list
	else
		settings.account_hidden[id] = nil
	end
	store.set(KV_ACCOUNT_HIDDEN, settings.account_hidden)
	if settings.account[id] == name and table.find(list, name) then
		choose_account(id, "")
	end
end

-- Shows the plan of provider `id`'s account `name` ("" for a provider's single account) in the card and the quota
-- details, or leaves it out.
local function toggle_plan(id: string, name: string)
	local settings = load_settings()
	local list = toggled(settings.plan_hidden[id] or {}, name)
	if #list > 0 then
		settings.plan_hidden[id] = list
	else
		settings.plan_hidden[id] = nil
	end
	store.set(data.KV_PLAN_HIDDEN, settings.plan_hidden)
end

-- Moves account `name` of provider `id` among its accounts (`how`: see `moved`).
local function move_account(id: string, name: string, how: string | number)
	local provider = offered(id)
	if provider == nil then
		return
	end
	local orders = load_settings().account_order
	local order = orders[id] or {}
	orders[id] = moved(order, accounts_in_order((provider :: Provider).accounts, order), name, how)
	store.set(KV_ACCOUNT_ORDER, orders)
end

-- After the user changed a setting: redraws the line and the panel at once.
local function after_change(cx: WindowCx?)
	if cx then
		refresh(cx)
		flush_panel(cx)
	end
end

-- Every account whose provider names its plan, to show each plan in the card or leave it out. Picking one
-- toggles it and opens the list again; Esc is done.
local function open_plans(cx: WindowCx)
	local settings = load_settings()
	local items = plan_items(settings, providers_in_order(settings))
	if #items == 0 then
		cx:toast("info", "No plans to choose from yet", "They come from omp's usage cache, for providers that name a plan")
		return
	end
	cx:pick({ items = items, placeholder = "Which plans show in the card? Esc when done", action = "toggle" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			toggle_plan((item :: any).id, (item :: any).name)
			local cx2 = next_cx or cx
			after_change(cx2)
			open_plans(cx2)
		end)
end

-- Alerts on or off (alerts.luau).
local function open_alerts(cx: WindowCx)
	local on = alerts.enabled()
	local items: { PickItem } = {
		{ label = "On", detail = ALERTS_DETAIL, current = on, on = true },
		{ label = "Off", detail = "no toasts; the line and card still turn warning colors", current = not on, on = false },
	}
	cx:pick({ items = items, placeholder = "Toast when a window runs low?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item then
				alerts.set_enabled((item :: any).on)
				after_change(next_cx or cx)
			end
		end)
end

-- What a click on the widget bar's gauge opens.
local function open_usage_opens(cx: WindowCx)
	local current = load_settings().usage_opens
	local items: { PickItem } = {}
	for _, choice in data.USAGE_OPENS do
		table.insert(items, { label = choice.label, detail = choice.detail, current = choice.id == current, opens = choice.id })
	end
	cx:pick({ items = items, placeholder = "What does a click on the gauge in the widget bar open?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item then
				store.set(data.KV_USAGE_OPENS, (item :: any).opens)
				after_change(next_cx or cx)
			end
		end)
end

-- Show pace: which windows say their pace in the card and the quota details.
local function open_pace(cx: WindowCx)
	local current = load_settings().pace
	local items: { PickItem } = {}
	for _, choice in data.PACES do
		table.insert(items, { label = choice.label, detail = choice.detail, current = choice.id == current, pace = choice.id })
	end
	cx:pick({ items = items, placeholder = "Which windows say their pace in the card?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item then
				store.set(data.KV_PACE, (item :: any).pace)
				after_change(next_cx or cx)
			end
		end)
end

-- Asks for a provider's own colors; a bad answer toasts and changes nothing, an empty one nothing at all.
local function prompt_color(cx: WindowCx, key: string, label: string)
	local spec = load_settings().colors[key]
	cx:prompt({
		value = if spec and string.sub(spec, 1, 1) == "#" then spec else "",
		placeholder = label .. ": #d97757, or two: #9aa7b4, #5b8def",
		icon = "palette",
	}):next(function(text: string?, _err: string?, next_cx: WindowCx?)
		if text == nil or not string.find(text :: string, "%S") then
			return
		end
		local cx2 = next_cx or cx
		local colors, bad = parse_colors(text :: string)
		if colors == nil then
			cx2:toast("error", "Not a color: " .. tostring(bad), "Use #rrggbb, or two of them separated by a comma")
			return
		end
		save_color(key, table.concat(colors, ", "))
		after_change(cx2)
	end)
end

local open_chooser: (WindowCx) -> ()
local open_reorder: (WindowCx) -> ()
local open_color_choices: (WindowCx, Provider) -> ()

open_chooser = function(cx: WindowCx)
	local settings = load_settings()
	cx:pick({ items = chooser_items(settings, providers_in_order(settings)), placeholder = "Show which providers? Esc when done", action = "toggle" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local id = (item :: any).id :: string
			store.set(KV_SELECTED, toggled(load_settings().selected, id))
			store.set(KV_MODE, "selected") -- choosing providers is choosing to show them
			local cx2 = next_cx or cx
			after_change(cx2)
			open_chooser(cx2)
		end)
end

open_reorder = function(cx: WindowCx)
	local providers = providers_in_order(load_settings())
	if #providers < 2 then
		cx:toast("info", "Nothing to reorder yet", "The order matters once omp's usage cache lists more than one provider")
		return
	end
	cx:pick({ items = reorder_items(providers), placeholder = "Move which provider? Esc when done", icon = "list" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local id = (item :: any).id :: string
			local at = 1
			for i, provider in providers do
				if provider.id == id then
					at = i
				end
			end
			local moves = move_items(at, #providers)
			if #moves == 0 then
				return
			end
			local cx2 = next_cx or cx
			cx2:pick({ items = moves, placeholder = "Move " .. (item :: PickItem).label, icon = "list" })
				:next(function(choice: PickItem?, _err2: string?, last_cx: WindowCx?)
					if choice == nil then
						return
					end
					move_provider(id, (choice :: any).pick)
					local cx3 = last_cx or cx2
					after_change(cx3)
					open_reorder(cx3)
				end)
		end)
end

open_color_choices = function(cx: WindowCx, provider: Provider)
	local settings = load_settings()
	local key = color_key(provider.id, provider.label)
	cx:pick({ items = color_items(settings, provider), placeholder = provider.label .. " colors", icon = "palette" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local cx2 = next_cx or cx
			if (item :: any).pick == "custom" then
				prompt_color(cx2, key, provider.label)
				return
			end
			save_color(key, (item :: any).spec)
			after_change(cx2)
		end)
end

local function open_colors(cx: WindowCx)
	local settings = load_settings()
	cx:pick({ items = color_provider_items(settings, providers_in_order(settings)), placeholder = "Color which provider?", icon = "palette" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local chosen = item :: any
			open_color_choices(next_cx or cx, { id = chosen.id, label = chosen.name, line = "", resets = {}, windows = {}, accounts = {} })
		end)
end

-- The windows a provider shows, by label: `5H, FABLE 7D`.
local function windows_summary(settings: Settings, provider: Provider): string
	local labels: { string } = {}
	for _, window in shown_windows(settings, provider.id, provider.windows) do
		table.insert(labels, string.upper(window.label))
	end
	return if #labels > 0 then table.concat(labels, ", ") else "all hidden"
end

-- A provider's windows, each checked while the line shows it.
local function window_items(settings: Settings, provider: Provider): { PickItem }
	local hidden = settings.hidden[provider.id] or {}
	local items: { PickItem } = {}
	for _, window in provider.windows do
		table.insert(items, {
			label = window_name(window.label) .. " window",
			detail = string.upper(window.label) .. " · " .. data.pct_text(window) .. (if window.passed then "" else " left"),
			current = table.find(hidden, string.lower(window.label)) == nil,
			pick = "window",
			window = string.lower(window.label),
		})
	end
	return items
end

-- Toggles provider `id`'s windows one at a time; the list stays open until Esc.
local function open_window_choices(cx: WindowCx, id: string)
	local provider: Provider? = nil
	for _, item in store.providers() do
		if item.id == id then
			provider = item
		end
	end
	if provider == nil or #(provider :: Provider).windows == 0 then
		return
	end
	local chosen = provider :: Provider
	cx:pick({
		items = window_items(load_settings(), chosen),
		placeholder = chosen.label .. ": show which windows? Esc when done",
		action = "toggle",
	}):next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
		if item == nil then
			return
		end
		toggle_window(id, (item :: any).window)
		local cx2 = next_cx or cx
		after_change(cx2)
		open_window_choices(cx2, id)
	end)
end

local function open_windows(cx: WindowCx)
	local settings = load_settings()
	local items: { PickItem } = {}
	for _, provider in providers_in_order(settings) do
		if #provider.windows > 0 then
			table.insert(items, { label = provider.label, detail = windows_summary(settings, provider), id = provider.id })
		end
	end
	if #items == 0 then
		cx:toast("info", "No windows to choose from yet", "They come from omp's usage cache: focus an omp pane")
		return
	end
	cx:pick({ items = items, placeholder = "Choose windows for which provider?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			open_window_choices(next_cx or cx, (item :: any).id)
		end)
end

-- A provider's accounts in the pickers: every account switched on or one on the line and in the card (the list
-- closes on a pick), or their order, a move at a time until Esc. With `switches`, which accounts are on instead,
-- toggled one at a time until Esc.
local open_account_order: (WindowCx, string) -> ()

local function open_account_choices(cx: WindowCx, id: string, switches: boolean?)
	local found = offered(id)
	if found == nil or #(found :: Provider).accounts < 2 then
		return
	end
	local provider = found :: Provider
	local settings = load_settings()
	local names = accounts_in_order(provider.accounts, settings.account_order[id])
	-- an account's windows: `7D 68% · FABLE 7D 45%`
	local function left(name: string): string
		local parts: { string } = {}
		for _, window in provider.windows do
			local owner, bare = account_of(window.label, provider.accounts)
			if owner == name then
				table.insert(parts, string.upper(bare :: string) .. " " .. data.pct_text(window))
			end
		end
		return table.concat(parts, " · ")
	end
	if switches then
		local items: { PickItem } = {}
		for _, name in names do
			table.insert(items, { label = name, detail = left(name), current = not account_off(settings, id, name), name = name })
		end
		cx:pick({ items = items, placeholder = provider.label .. ": which accounts show? Esc when done", action = "toggle" })
			:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
				if item == nil then
					return
				end
				toggle_account(id, (item :: any).name)
				local cx2 = next_cx or cx
				after_change(cx2)
				open_account_choices(cx2, id, true)
			end)
		return
	end
	local shown = shown_accounts(settings, provider)
	local chosen = chosen_account(settings, id, provider.accounts)
	local together = if chosen == nil then settings.account[id] else nil
	local items: { PickItem } = {
		{ label = "All accounts", detail = string.format("%d accounts, one after another", #shown), group = "Show", current = chosen == nil and together ~= COMBINED and together ~= COMBINED_PLANS, pick = "show", name = "" },
		{ label = "Combined", detail = "one set of windows, shares averaged", group = "Show", current = together == COMBINED, pick = "show", name = COMBINED },
		{ label = "Combined by plan", detail = "same plan together, shares averaged", group = "Show", current = together == COMBINED_PLANS, pick = "show", name = COMBINED_PLANS },
	}
	for _, name in shown do
		table.insert(items, { label = name, detail = left(name), group = "Show", current = chosen == name, pick = "show", name = name })
	end
	table.insert(items, {
		label = "Switch accounts on or off…",
		detail = string.format("%d of %d on", #shown, #names),
		group = "Accounts",
		icon = "check",
		pick = "switches",
	})
	table.insert(items, { label = "Reorder accounts…", detail = table.concat(names, ", "), group = "Accounts", icon = "list", pick = "order" })
	cx:pick({ items = items, placeholder = provider.label .. ": show which accounts?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local choice = item :: any
			local cx2 = next_cx or cx
			if choice.pick == "order" then
				open_account_order(cx2, id)
				return
			elseif choice.pick == "switches" then
				open_account_choices(cx2, id, true)
				return
			end
			choose_account(id, choice.name)
			after_change(cx2)
		end)
end

open_account_order = function(cx: WindowCx, id: string)
	local found = offered(id)
	if found == nil then
		return
	end
	local provider = found :: Provider
	local names = accounts_in_order(provider.accounts, load_settings().account_order[id])
	local items: { PickItem } = {}
	for i, name in names do
		table.insert(items, { label = name, detail = string.format("%d of %d", i, #names), pick = "account", name = name })
	end
	cx:pick({ items = items, placeholder = provider.label .. ": move which account? Esc when done", icon = "list" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			local name = (item :: any).name :: string
			local moves = move_items(table.find(names, name) or 1, #names)
			if #moves == 0 then
				return
			end
			local cx2 = next_cx or cx
			cx2:pick({ items = moves, placeholder = "Move " .. name, icon = "list" })
				:next(function(choice: PickItem?, _err2: string?, last_cx: WindowCx?)
					if choice == nil then
						return
					end
					move_account(id, name, (choice :: any).pick)
					local cx3 = last_cx or cx2
					after_change(cx3)
					open_account_order(cx3, id)
				end)
		end)
end

local function open_accounts(cx: WindowCx)
	local settings = load_settings()
	local several = with_accounts(providers_in_order(settings))
	if #several == 0 then
		cx:toast("info", "No provider has several accounts", "They come from omp's usage cache: focus an omp pane")
		return
	elseif #several == 1 then
		open_account_choices(cx, several[1].id)
		return
	end
	local items: { PickItem } = {}
	for _, provider in several do
		table.insert(items, { label = provider.label, detail = accounts_summary(settings, provider), id = provider.id })
	end
	cx:pick({ items = items, placeholder = "Accounts of which provider?", icon = "gauge" })
		:next(function(item: PickItem?, _err: string?, next_cx: WindowCx?)
			if item == nil then
				return
			end
			open_account_choices(next_cx or cx, (item :: any).id)
		end)
end

return {
	init = init,
	providers_in_order = providers_in_order,
	label_of = label_of,
	MODES = MODES,
	mode_details = mode_details,
	menu_items = menu_items,
	toggled = toggled,
	color_name = color_name,
	save_color = save_color,
	toggle_window = toggle_window,
	move_provider = move_provider,
	choose_account = choose_account,
	toggle_account = toggle_account,
	toggle_plan = toggle_plan,
	open_plans = open_plans,
	open_alerts = open_alerts,
	open_pace = open_pace,
	ALERTS_DETAIL = ALERTS_DETAIL,
	open_usage_opens = open_usage_opens,
	move_account = move_account,
	after_change = after_change,
	prompt_color = prompt_color,
	open_chooser = open_chooser,
	open_reorder = open_reorder,
	open_colors = open_colors,
	open_windows = open_windows,
	open_accounts = open_accounts,
}
