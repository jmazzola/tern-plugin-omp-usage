--!strict
-- omp Usage's settings panel (`omp Usage: Settings panel`, Ctrl+Alt+U, or Settings in the quota details).
local data = require("./data")
local render = require("./render")
local pickers = require("./pickers")
local update = require("./update")
local detail_view = require("./details")

type Cache = data.Cache
type Dock = data.Dock
type Model = data.Model
type Palette = data.Palette
type Provider = data.Provider
type Settings = data.Settings
type Window = data.Window

local NAMED = data.NAMED
local KV_MODE = data.KV_MODE
local KV_SELECTED = data.KV_SELECTED
local KV_CARD_ROWS = data.KV_CARD_ROWS
local CARD_ROWS = data.CARD_ROWS
local COMBINED = data.COMBINED
local COMBINED_PLANS = data.COMBINED_PLANS
local now_ms = data.now_ms
local span = data.span
local tone_of = data.tone_of
local read_cache = data.read_cache
local offered_providers = data.offered_providers
local store = data.store
local load_settings = data.load_settings
local shown_windows = data.shown_windows
local accounts_in_order = data.accounts_in_order
local account_of = data.account_of
local account_off = data.account_off
local chosen_account = data.chosen_account
local account_view = data.account_view
local shown_accounts = data.shown_accounts
local ordered = data.ordered
local named_palette = data.named_palette
local palette_of_spec = data.palette_of_spec
local color_key = data.color_key
local preset_for = data.preset_for
local palette_for = data.palette_for
local build_model = data.build_model
local colors_key = data.colors_key
local hidden_key = data.hidden_key
local NO_DOCK = data.NO_DOCK
local CARD_ROW = render.CARD_ROW
local card_memo = render.card_memo
local set_card_memo = render.set_card_memo
local last_card_runs = render.last_card_runs
local fill = render.fill
local line_of = render.line_of
local line_paint = render.line_paint
local tips = render.tips
local palette_css = render.palette_css
local card = render.card
local card_css = render.card_css
local shortcut = render.shortcut
local settings_hint = render.settings_hint
local details_shortcut = render.details_shortcut
local label_of = pickers.label_of
local MODES = pickers.MODES
local mode_details = pickers.mode_details
local toggled = pickers.toggled
local color_name = pickers.color_name
local save_color = pickers.save_color
local toggle_window = pickers.toggle_window
local move_provider = pickers.move_provider
local choose_account = pickers.choose_account
local toggle_account = pickers.toggle_account
local move_account = pickers.move_account
local after_change = pickers.after_change
local prompt_color = pickers.prompt_color

-- The dock window.luau last read, which the preview of the line is drawn from, and how the quota details open.
-- window.luau requires this module, so it hands both over with `init`.
local last_dock: () -> Dock? = function(): Dock?
	return nil
end
local open_details: (cx: WindowCx) -> () = function(_cx: WindowCx) end

local function init(dock: () -> Dock?, details: (cx: WindowCx) -> ())
	last_dock, open_details = dock, details
end

-- The panel's pane while it is open, and what redraws it (below).
local panel_pane: number? = nil
local sync_panel: (cx: WindowCx, force: boolean, settings: Settings?, cache: Cache?) -> ()
local flush_panel: (cx: WindowCx) -> ()
-- The settings panel: a canvas of buttons beside the pane it was opened from, one per window (opening it again
-- shows the one there is). It redraws when a setting changes, from it or from the pickers, and as the line it
-- previews changes. Its clicks arrive as `canvas_action` events. Tern keeps canvases across reloads, so a
-- reload takes over the one it finds.
local PANEL_TITLE = "omp Usage settings"
local PANEL_ABOUT = "Settings for the omp Usage line above omp's composer: what it shows, the providers' order, "
	.. "their windows and their colors. Each button changes one setting at once and runs nothing else."
local PANEL_SHEET = "panel"
local PANEL_ROLE = "omp-usage.panel"
local DOCK_ROLE = "omp-usage.panel-dock"
local PANEL = "[data-role='" .. PANEL_ROLE .. "']"
local PANEL_DOCK = "[data-role='" .. DOCK_ROLE .. "']"
local ui = tern.ui

local PANEL_CSS = fill(
	[==[
/* the settings panel, in the line's voice: mono micro-labels over hairlines, each provider in its own colors */
$P {
	display: flex;
	flex-direction: column;
	gap: 26px;
	padding: 20px 22px 30px;
	font: 400 12.5px/18px var(--sans);
	color: var(--t2);
}
/* Tern 0.9 draws every view button (`button:where(.sf-el)`) as a 28px chip: centered on a filled, ringed
   background, one nowrap line. The panel's buttons draw themselves, so they start from nothing; each class below
   sets what it needs */
$P button {
	align-items: stretch;
	justify-content: flex-start;
	gap: 0;
	height: auto;
	padding: 0;
	border-radius: 0;
	font: inherit;
	letter-spacing: normal;
	white-space: normal;
	color: inherit;
	background: none;
	box-shadow: none;
	transform: none;
}
$P .oup-sec {
	display: flex;
	flex-direction: column;
	gap: 10px;
	max-width: 760px;
}
$P .oup-eyebrow {
	display: flex;
	flex-wrap: wrap;
	align-items: baseline;
	gap: 4px 12px;
	padding-bottom: 8px;
	border-bottom: 1px solid var(--l2);
}
$P .oup-title {
	font: 600 10px/14px var(--mono);
	letter-spacing: 0.16em;
	text-transform: uppercase;
	color: var(--t2);
}
$P .oup-note {
	font: 400 11.5px/14px var(--sans);
	color: var(--t3);
}
/* what the composer shows, drawn as the composer draws it: the card (open, as a hover opens it) over the line,
   8px apart as there, on a stage lit from its corner in the card's glow; a card wider than the panel is cut */
$P .oup-stage {
	display: flex;
	flex-direction: column;
	align-items: flex-start;
	gap: 8px;
	overflow: hidden;
	/* its height held (see `build.preview`) counts the padding; spare room goes over the card, which rises from
	   the line as on the composer. The scroll never anchors in here: a card that changes height would move the
	   panel with it */
	box-sizing: border-box;
	justify-content: flex-end;
	overflow-anchor: none;
	padding: 14px 16px;
	border-radius: 12px;
	background-color: var(--code-bg);
	background-image: radial-gradient(120% 160% at 0% 0%, rgb(from var(--ou-glow) r g b / 16%), transparent 62%);
	box-shadow: 0 0 0 1px var(--l2), inset 0 1px 0 var(--glass-hi);
	--ou-glow: var(--accent);
}
$P .oup-card {
	display: flex;
}
/* the composer's line box, font and colors at rest (see LINE_CSS), its bars' lit tips over it as there (see
   TIPS_CSS; `build.preview` sets them) */
$P .oup-line {
	position: relative;
	align-self: stretch;
	height: 15px;
	overflow: hidden;
	white-space: pre-wrap;
	text-overflow: ellipsis;
	font: 500 10px/15px var(--mono);
	font-variant-numeric: tabular-nums;
	color: transparent;
	background-repeat: no-repeat;
	background-clip: text;
	--ou-lbl: var(--t3);
	--ou-sep: var(--t4);
	--ou-num-ok: var(--t2);
	--ou-num-warn: var(--warn);
	--ou-num-bad: var(--bad);
	--ou-dim: var(--t4);
	--ou-soft: var(--t3);
	--ou-track: color-mix(in srgb, var(--t1) 13%, transparent);
}
$P .oup-empty {
	font: 400 12px/18px var(--sans);
	color: var(--t3);
}
/* the modes, side by side; the one in use is ringed in the accent and checked */
$P .oup-modes {
	display: flex;
	flex-wrap: wrap;
	gap: 8px;
}
$P .oup-opt {
	display: flex;
	flex: 1 1 130px;
	flex-direction: column;
	gap: 4px;
	min-width: 0;
	padding: 10px 12px 11px;
	border-radius: 10px;
	text-align: left;
	background-color: var(--well);
	box-shadow: 0 0 0 1px var(--l2);
	cursor: pointer;
	transition:
		background-color 0.16s var(--ease),
		box-shadow 0.16s var(--ease);
}
$P .oup-opt:hover {
	background-color: var(--l1);
	box-shadow: 0 0 0 1px var(--l3);
}
$P .oup-opt[data-on] {
	background-color: rgb(from var(--accent) r g b / 9%);
	box-shadow:
		0 0 0 1px rgb(from var(--accent) r g b / 60%),
		0 10px 24px -16px rgb(from var(--accent) r g b / 90%);
}
$P .oup-opt-head {
	display: flex;
	align-items: center;
	gap: 6px;
}
$P .oup-opt-t {
	flex: 1;
	font: 600 12.5px/16px var(--sans);
	color: var(--t1);
}
$P .oup-opt .sf-icon {
	color: var(--accent);
}
$P .oup-opt-d {
	font: 400 11.5px/15px var(--sans);
	color: var(--t3);
}
/* the providers, a row each in the line's order: grip, index, swatch and label, what is left, then the Selected
   switch, which drops under the rest when the pane is narrow */
$P .oup-rows {
	display: flex;
	flex-direction: column;
}
$P .oup-prow {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 4px 12px;
	min-height: 40px;
	padding: 4px 2px 4px 4px;
}
$P .oup-prow + .oup-prow {
	border-top: 1px solid var(--l1);
}
$P .oup-who {
	display: flex;
	align-items: center;
	gap: 9px;
	min-width: 0;
}
$P .oup-ctl {
	display: flex;
	flex: none;
	align-items: center;
	gap: 2px;
	margin-left: auto;
}
$P .oup-idx {
	flex: none;
	width: 16px;
	font: 500 10px/14px var(--mono);
	font-variant-numeric: tabular-nums;
	color: var(--t4);
}
$P .oup-swatch {
	flex: none;
	width: 20px;
	height: 6px;
	border-radius: 3px;
	background-image: linear-gradient(90deg, rgb(from var(--pa) r g b), rgb(from var(--pb) r g b));
	box-shadow: 0 0 10px -1px rgb(from var(--pb) r g b / 55%);
}
$P .oup-name {
	overflow: hidden;
	white-space: nowrap;
	text-overflow: ellipsis;
	font: 600 12.5px/16px var(--mono);
	color: rgb(from var(--pa) r g b);
}
/* takes the room the row has, but never less than its widest window: past that the controls drop to their own
   line instead of the shares running under the switch */
$P .oup-sum {
	display: flex;
	flex: 1 0 auto;
	flex-wrap: wrap;
	gap: 2px;
	white-space: nowrap;
	font: 500 10.5px/14px var(--mono);
	font-variant-numeric: tabular-nums;
}
/* each window a toggle: a click hides it from the line (faded, its share struck through) or shows it again */
$P .oup-wt {
	display: flex;
	flex: none;
	align-items: center;
	padding: 2px 6px;
	border-radius: 5px;
	white-space: nowrap;
	cursor: pointer;
	transition:
		opacity 0.18s var(--ease),
		background-color 0.18s var(--ease);
}
$P .oup-wt:hover {
	background-color: var(--l1);
}
$P .oup-wt[data-off] {
	opacity: 0.4;
}
$P .oup-wt[data-off] .oup-v {
	text-decoration-line: line-through;
}
$P .oup-w {
	margin-right: 5px;
	color: var(--t3);
}
$P .oup-v {
	color: var(--t1);
}
$P .oup-v[data-low='warn'] {
	color: var(--warn);
}
$P .oup-v[data-low='bad'] {
	color: var(--bad);
}
/* under Selected providers, the ones switched off fade: the line leaves them out */
$P .oup-prow[data-off] .oup-swatch,
$P .oup-prow[data-off] .oup-name,
$P .oup-prow[data-off] .oup-sum,
$P .oup-prow[data-off] .oup-aname {
	opacity: 0.4;
}
$P .oup-switch {
	position: relative;
	flex: none;
	margin-right: 4px;
	width: 30px;
	height: 18px;
	border-radius: 9px;
	background-color: var(--l3);
	cursor: pointer;
	transition: opacity 0.18s var(--ease);
}
/* the switch carries `aria-checked`, which Tern 0.9 draws as a ringed checkbox (`.sf-el[aria-checked]`, its
   `:checked` fill and its tick `::after`): as specific as those, and later, so the plain track stays */
$P .oup-switch[aria-checked] {
	background-color: var(--l3);
	box-shadow: none;
}
$P .oup-switch[aria-checked]::after {
	content: none;
}
$P .oup-knob {
	position: absolute;
	top: 3px;
	left: 3px;
	width: 12px;
	height: 12px;
	border-radius: 6px;
	background-color: var(--t2);
	box-shadow: 0 1px 2px rgba(0, 0, 0, 0.35);
	transition:
		transform 0.22s var(--out),
		background-color 0.18s var(--ease);
}
$P .oup-switch[data-on] {
	background-image: linear-gradient(90deg, rgb(from var(--pa) r g b), rgb(from var(--pb) r g b));
}
$P .oup-switch[data-on] .oup-knob {
	transform: translateX(12px);
	background-color: #fff;
}
/* the switches pick what Selected providers shows; under the other modes they wait, dimmed */
$P .oup-rows[data-idle] .oup-switch {
	opacity: 0.45;
}
$P .oup-rows[data-idle] .oup-switch:hover {
	opacity: 1;
}
/* reordering, by pick and place: a grip picks a row up; the row lifts, ringed (in the accent, an account in its
   provider's color) and its grip turns into a cross that puts it back; every gap it can go to opens as a slot, a
   line with its name, and a click on one puts it there */
$P .oup-grip {
	display: flex;
	flex: none;
	align-items: center;
	justify-content: center;
	width: 20px;
	height: 26px;
	border-radius: 6px;
	color: var(--t4);
	cursor: pointer;
	transition:
		color 0.14s var(--ease),
		background-color 0.14s var(--ease);
}
$P .oup-grip:hover {
	color: var(--t1);
	background-color: var(--l2);
}
$P .oup-prow[data-moving] {
	border-radius: 10px;
	background-color: rgb(from var(--accent) r g b / 7%);
	box-shadow:
		0 0 0 1px rgb(from var(--accent) r g b / 55%),
		0 14px 28px -18px rgb(from var(--accent) r g b / 90%);
}
$P .oup-arow[data-moving] {
	border-radius: 8px;
	background-color: rgb(from var(--pa) r g b / 9%);
	box-shadow:
		0 0 0 1px rgb(from var(--pa) r g b / 55%),
		0 12px 24px -16px rgb(from var(--pa) r g b / 90%);
}
$P .oup-prow[data-moving] > .oup-who > .oup-grip {
	color: var(--accent);
}
$P .oup-arow[data-moving] > .oup-grip {
	color: rgb(from var(--pa) r g b);
}
$P .oup-slot {
	display: flex;
	align-items: center;
	gap: 10px;
	height: 24px;
	padding: 0 8px;
	border-radius: 7px;
	font: 500 10px/14px var(--mono);
	color: rgb(from var(--slot) r g b);
	opacity: 0.7;
	cursor: pointer;
	transition:
		opacity 0.14s var(--ease),
		background-color 0.14s var(--ease);
	--slot: var(--accent);
}
$P .oup-accts .oup-slot {
	--slot: var(--pa);
}
$P .oup-slot:hover {
	opacity: 1;
	background-color: rgb(from var(--slot) r g b / 12%);
}
$P .oup-slot-line {
	flex: 1;
	height: 1px;
	background-color: rgb(from var(--slot) r g b / 60%);
}
/* a provider with several accounts: where its windows would be, one quiet chip saying what the line and card show
   (`all 8 accounts`), or, with one account picked, a button in the provider's color (`only dev.ops ✕`) that shows
   them all again; under it, on a guide from its swatch, a row per account in the line's order: grip, name (one
   column, so the windows line up; a click picks it), windows and its switch */
$P .oup-sum-pick {
	flex: 1 1 0;
	min-width: 0;
}
$P .oup-pick {
	display: flex;
	flex: 0 1 auto;
	align-items: center;
	gap: 5px;
	min-width: 0;
	max-width: 100%;
	height: 22px;
	padding: 0 9px;
	border-radius: 11px;
	white-space: nowrap;
	font: 500 10.5px/22px var(--mono);
	color: var(--t3);
	box-shadow: 0 0 0 1px var(--l2);
}
$P .oup-pick-t {
	min-width: 0;
	overflow: hidden;
	text-overflow: ellipsis;
}
$P button.oup-pick {
	color: rgb(from var(--pa) r g b);
	background-color: rgb(from var(--pa) r g b / 12%);
	box-shadow: 0 0 0 1px rgb(from var(--pa) r g b / 50%);
	cursor: pointer;
	transition: background-color 0.14s var(--ease);
}
$P button.oup-pick:hover {
	background-color: rgb(from var(--pa) r g b / 22%);
}
/* beside `all 8 accounts`, the button that combines them: quiet until pointed at */
$P .oup-picks {
	display: flex;
	align-items: center;
	gap: 6px;
	min-width: 0;
}
$P button.oup-combine {
	color: var(--t3);
	background-color: transparent;
	box-shadow: 0 0 0 1px var(--l2);
}
$P button.oup-combine:hover {
	color: rgb(from var(--pa) r g b);
	background-color: rgb(from var(--pa) r g b / 12%);
	box-shadow: 0 0 0 1px rgb(from var(--pa) r g b / 50%);
}
$P .oup-accts {
	display: flex;
	flex: 0 0 calc(100% - 64px);
	flex-direction: column;
	margin: 0 0 6px 64px;
	padding-left: 8px;
	border-left: 1px solid var(--l2);
}
$P .oup-arow {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 2px 10px;
	min-height: 30px;
	padding: 0 2px 0 2px;
}
$P .oup-aname {
	display: flex;
	flex: 0 1 172px;
	align-items: center;
	gap: 6px;
	min-width: 64px;
	margin-left: -6px;
	padding: 2px 6px;
	border-radius: 6px;
	font: 500 11.5px/16px var(--mono);
	color: rgb(from var(--pa) r g b);
	transition:
		opacity 0.18s var(--ease),
		background-color 0.14s var(--ease);
}
$P .oup-aname-t {
	min-width: 0;
	overflow: hidden;
	white-space: nowrap;
	text-overflow: ellipsis;
}
$P button.oup-aname {
	cursor: pointer;
}
$P button.oup-aname:hover {
	background-color: var(--l2);
}
/* the account picked to show alone: its row tinted, its name bold and tagged */
$P .oup-arow[data-picked] {
	border-radius: 8px;
	background-color: rgb(from var(--pa) r g b / 7%);
}
$P .oup-arow[data-picked] .oup-aname {
	font-weight: 600;
}
$P .oup-only {
	flex: none;
	padding: 0 5px;
	border-radius: 4px;
	font: 600 9px/14px var(--mono);
	letter-spacing: 0.08em;
	text-transform: uppercase;
	color: rgb(from var(--pa) r g b);
	background-color: rgb(from var(--pa) r g b / 16%);
	box-shadow: 0 0 0 1px rgb(from var(--pa) r g b / 45%);
}
/* combined: which group an account went into (`5H`, `no 5H`), at the end of its windows, so the tags
   line up in a column */
$P .oup-group {
	flex: none;
	margin-left: auto;
	padding: 0 6px;
	border-radius: 4px;
	font: 500 10px/16px var(--mono);
	color: var(--t3);
	box-shadow: 0 0 0 1px var(--l2);
}
$P .oup-arow[data-off] .oup-aname,
$P .oup-arow[data-off] .oup-sum,
$P .oup-arow[data-hidden] .oup-aname,
$P .oup-arow[data-hidden] .oup-sum {
	opacity: 0.4;
}
/* switched off: out of the line and the card */
$P .oup-arow[data-hidden] .oup-aname-t {
	text-decoration-line: line-through;
}
/* picked up, a row shows in full, whatever else it is */
$P .oup-arow[data-moving] .oup-aname,
$P .oup-arow[data-moving] .oup-sum {
	opacity: 1;
}
/* an account's switch is always live, whatever the mode */
$P .oup-rows[data-idle] .oup-aswitch {
	opacity: 1;
}
/* ten accounts of one provider make a column of switches: on, they take its color at half strength, so a row
   picked up or a share running low still stands out */
$P .oup-aswitch[data-on] {
	background-image: none;
	background-color: rgb(from var(--pa) r g b / 45%);
}
/* each provider's colors: its preset, the alternatives and its own, the one in use ringed; the swatches drop
   under the label when the pane is narrow */
$P .oup-crow {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 10px 16px;
	padding: 10px 4px;
}
$P .oup-crow + .oup-crow {
	border-top: 1px solid var(--l1);
}
$P .oup-chead {
	display: flex;
	flex: 0 0 150px;
	flex-direction: column;
	gap: 2px;
	min-width: 0;
}
$P .oup-dots {
	display: flex;
	flex: 1 1 250px;
	flex-wrap: wrap;
	align-items: center;
	gap: 7px;
	min-width: 0;
}
$P .oup-dot {
	position: relative;
	width: 18px;
	height: 18px;
	border-radius: 9px;
	background-image: linear-gradient(135deg, rgb(from var(--pa) r g b), rgb(from var(--pb) r g b));
	box-shadow:
		0 0 0 1px var(--l2),
		inset 0 1px 0 rgba(255, 255, 255, 0.22);
	outline: 1.5px solid transparent;
	outline-offset: 2px;
	cursor: pointer;
	transition:
		outline-color 0.14s var(--ease),
		box-shadow 0.14s var(--ease);
}
$P .oup-dot:hover {
	outline-color: var(--l4);
}
$P .oup-dot[data-on] {
	outline-color: rgb(from var(--pb) r g b);
	box-shadow:
		0 0 0 1px var(--l2),
		0 0 14px -2px rgb(from var(--pb) r g b / 70%);
}
/* a swatch's name, under it while it is pointed at */
$P .oup-dot:hover::after {
	content: attr(data-name);
	position: absolute;
	left: 50%;
	top: calc(100% + 7px);
	transform: translateX(-50%);
	padding: 1px 7px;
	border-radius: 6px;
	white-space: nowrap;
	font: 500 10.5px/16px var(--sans);
	color: var(--t1);
	background-color: rgb(from var(--pop-bg) r g b / 1);
	box-shadow:
		0 0 0 1px var(--l2),
		0 8px 18px -10px rgba(0, 0, 0, 0.6);
	pointer-events: none;
	z-index: 4;
}
$P .oup-acts {
	display: flex;
	gap: 6px;
}
$P .oup-btn {
	height: 24px;
	padding: 0 10px;
	border-radius: 7px;
	font: 500 11.5px/24px var(--sans);
	color: var(--t2);
	background-color: var(--raise);
	box-shadow: 0 0 0 1px var(--l2);
	cursor: pointer;
	transition:
		color 0.14s var(--ease),
		box-shadow 0.14s var(--ease);
}
$P .oup-btn:hover {
	color: var(--t1);
	box-shadow: 0 0 0 1px var(--l4);
}
$P .oup-ustat {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	justify-content: space-between;
	gap: 10px 16px;
	padding: 12px 14px;
	border-radius: 10px;
	box-shadow: 0 0 0 1px var(--l2);
}
$P .oup-ustat[data-ready] {
	background-color: rgb(from var(--accent) r g b / 8%);
	box-shadow: 0 0 0 1px rgb(from var(--accent) r g b / 40%);
}
$P .oup-say {
	display: flex;
	flex-direction: column;
	gap: 2px;
	min-width: 0;
}
$P .oup-utitle {
	font: 600 13px/18px var(--sans);
	color: var(--t1);
}
$P .oup-usub {
	font: 400 11.5px/15px var(--sans);
	color: var(--t3);
}
$P .oup-btn.oup-primary {
	color: #fff;
	background-color: var(--accent);
	box-shadow: none;
}
$P .oup-btn.oup-primary:hover {
	color: #fff;
	background-color: rgb(from var(--accent) r g b / 85%);
	box-shadow: none;
}
$P .oup-urow {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 10px 14px;
}
$P .oup-ulabel {
	font: 400 11.5px/14px var(--sans);
	color: var(--t3);
}
$P .oup-pills {
	display: flex;
	flex-wrap: wrap;
	gap: 6px;
}
$P .oup-pill {
	height: 24px;
	padding: 0 10px;
	border-radius: 12px;
	font: 500 11.5px/24px var(--sans);
	color: var(--t2);
	box-shadow: 0 0 0 1px var(--l2);
	cursor: pointer;
	transition:
		color 0.14s var(--ease),
		box-shadow 0.14s var(--ease),
		background-color 0.14s var(--ease);
}
$P .oup-pill:hover {
	color: var(--t1);
	box-shadow: 0 0 0 1px var(--l4);
}
$P .oup-pill[data-on] {
	color: var(--t1);
	background-color: rgb(from var(--accent) r g b / 16%);
	box-shadow: 0 0 0 1px rgb(from var(--accent) r g b / 55%);
}
/* under the Preview: the card's height limit, its note on a line of its own, and the warning while the card
   outgrows it */
$P .oup-limit {
	margin-top: 12px;
}
$P .oup-limit .oup-note {
	flex-basis: 100%;
}
$P .oup-over {
	margin-top: 10px;
	font: 400 11.5px/15px var(--sans);
	color: var(--warn);
}
$P .oup-cname {
	overflow: hidden;
	white-space: nowrap;
	text-overflow: ellipsis;
	font: 500 10px/14px var(--mono);
	color: var(--t3);
}
$P button:focus-visible {
	outline: 2px solid var(--accent);
	outline-offset: 2px;
}
/* the bottom bar: changes need no saving, and the shortcut */
$D {
	display: flex;
	flex-wrap: wrap;
	align-items: center;
	gap: 4px 8px;
	padding: 9px 22px;
	font: 400 11.5px/16px var(--sans);
	white-space: nowrap;
	color: var(--t3);
}
$D > .sf-icon {
	color: var(--ok);
}
$D .oup-sep {
	width: 1px;
	height: 12px;
	margin: 0 6px;
	background-color: var(--l3);
}
/* Quota details, at the bar's far end */
$D .oup-grow {
	flex: 1;
}
$D .oup-hint {
	display: flex;
	align-items: center;
	gap: 8px;
}
$D .oup-keys {
	display: flex;
	gap: 3px;
}
$D .oup-key {
	min-width: 18px;
	height: 18px;
	padding: 0 5px;
	border-radius: 5px;
	font: 500 10.5px/18px var(--mono);
	text-align: center;
	color: var(--t2);
	background-color: var(--l1);
	box-shadow:
		0 0 0 1px var(--l2),
		inset 0 -1px 0 var(--l2);
}
/* Reduce Motion, either way: switches and rings change at once */
.sf-still $P *,
.sf-still $D * {
	transition: none;
}
@media (prefers-reduced-motion: reduce) {
	$P *,
	$D * {
		transition: none;
	}
}
]==],
	{ P = PANEL, D = PANEL_DOCK }
)

-- A value for a `[data-ou-pal='…']` selector.
local function pal_key(s: string): string
	return (string.gsub(s, "[^%w%-_]", "_"))
end

-- The colors of whatever carries `data-ou-pal` = `pal`, as `--pa` and `--pb`.
local function palette_rule(pal: string, palette: Palette): string
	return string.format("%s [data-ou-pal='%s'] {\n\t--pa: %s;\n\t--pb: %s;\n}", PANEL, pal, palette.a, palette.b or palette.a)
end

local NAMED_CSS = (function(): string
	local rules: { string } = {}
	for _, item in NAMED do
		table.insert(rules, palette_rule("n-" .. item.key, item.palette))
	end
	return table.concat(rules, "\n")
end)()

-- A section: a mono title over a hairline, a note beside it, then `body`.
local function section(key: string, title: string, note: string?, body: { Node }): Node
	local head: { Node } = { ui.el("span", { class = "oup-title", text = title }) }
	if note then
		table.insert(head, ui.el("span", { class = "oup-note", text = note }))
	end
	local children: { Node } = { ui.el("div", { class = "oup-eyebrow" }, head) }
	for _, node in body do
		table.insert(children, node)
	end
	return ui.el("section", { key = key, class = "oup-sec" }, children)
end

-- The panel's sections and the account chip, as fields of one table.
local build = {}
-- `build.most_rows`' last result and what it was for
build.most_for = ""
build.most = 0

-- The most rows the card can get with the usage last fetched, whatever is clicked in the panel. The card's
-- height doesn't only grow with what it shows (hiding a window can make room for another account in full), so
-- with nothing hidden and every account on, a card counts as tall as it would be without the limit, up to the
-- limit, or as it is with everything summed up and folded, if that still outgrows it: picked accounts stay in
-- full, so the most is with each provider's account picked that takes the most rows, all at once. That for the
-- focused agent's provider and for every provider, with no account picked, each picked alone, and those picks
-- together (combined accounts only ever take fewer rows). The order of providers and accounts changes neither.
-- It is worked out again only when the limit or the shape of the cards with no account picked changes (their
-- providers, accounts, windows and the rows under them; not what is left, which the extension rewrites every
-- minute), and the card's memo is put back after, so the composer's and the preview's rows stay the same rows
-- (their clock times included).
function build.most_rows(settings: Settings, providers: { Provider }, cache: Cache?, hint: string): number
	local limit = settings.card_rows
	local function model_for(mode: string, picks: { [string]: string }): Model
		local trial = table.clone(settings)
		trial.mode, trial.hidden, trial.account_hidden, trial.account = mode, {}, {}, picks
		return build_model(trial, last_dock() or NO_DOCK, cache)
	end
	local bases: { [string]: Model } = { current = model_for("current", {}), all = model_for("all", {}) }
	local shape: { string } = { hint, tostring(limit) }
	for _, base in { bases.current, bases.all } do
		table.insert(shape, base.title .. "#" .. tostring(#base.others))
		for _, group in base.groups do
			table.insert(shape, string.format("%s=%s r%d", group.key, group.label, #(group.resets or {})))
			for _, window in group.windows do
				table.insert(
					shape,
					string.format("%s|%s|%s|%s", window.label, tostring(window.saved), tostring(window.expires ~= nil), tostring(window.reset ~= nil))
				)
			end
		end
	end
	local key = table.concat(shape, "\n")
	if key == build.most_for then
		return build.most
	end
	local most = 0
	local memo_for, memo_rows = card_memo()
	-- the card's rows with every account in full, after counting the state toward `most`: as many, up to the
	-- limit; past it, the card sums accounts up, which only leaves it over the limit if summing up all of them
	-- does. Also how many rows each account in full takes (see `card_runs`).
	local function measure(model: Model): (number, { [string]: number })
		if #model.groups == 0 and #model.others == 0 then
			return 0, {}
		end
		local unlimited = #card(model, hint, limit, "all")
		local runs = last_card_runs()
		most = math.max(most, math.min(unlimited, limit))
		if unlimited > limit then
			most = math.max(most, #card(model, hint, limit, "least"))
		end
		return unlimited, runs
	end
	for mode, base in bases do
		-- a pick swaps an account's windows (two rows or more each) for a row per other account, so picks only
		-- matter when the card already outgrows the limit; then the tallest card picks, for each provider it
		-- shows with several accounts, the account that takes the most rows, all at once
		local unlimited, runs = measure(base)
		if unlimited <= limit then
			continue
		end
		local tallest: { [string]: string } = {}
		for _, provider in providers do
			local best = -1
			for _, name in provider.accounts do
				local rows = runs[provider.id .. "/" .. name]
				if rows and rows > best then
					best, tallest[provider.id] = rows, name
				end
			end
		end
		if next(tallest) ~= nil then
			measure(model_for(mode, tallest))
		end
	end
	set_card_memo(memo_for, memo_rows)
	build.most_for, build.most = key, most
	return most
end

-- What the composer shows, drawn by the composer's own code: its card open over the line, as a hover opens it,
-- with the same rows, text, paint and fonts. The line keeps the composer's one-line box (`.oup-line`), so a
-- window that doesn't fit wraps onto the line that is cut off here as it is there; the panel is seldom as wide
-- as the composer, so the line can end a window sooner or later. The stage is as tall as the card can get with
-- the usage last fetched (`most_rows`), so a click that changes the card leaves the rest of the panel, and the
-- pointer over it, where they were. Under it, the card's height limit, and a warning while the card outgrows it.
function build.preview(settings: Settings, preview: Model, rules: { string }, hint: string, providers: { Provider }, cache: Cache?): Node
	local limit = settings.card_rows
	local pills: { Node } = {}
	for _, rows in CARD_ROWS do
		local on = rows == limit
		table.insert(pills, ui.el("button", {
			class = "oup-pill",
			text = tostring(rows),
			actions = { click = "card-rows=" .. tostring(rows) },
			attrs = { ["data-on"] = if on then true else nil, ["aria-pressed"] = if on then "true" else "false" },
		}))
	end
	local height = ui.el("div", { class = "oup-urow oup-limit" }, {
		ui.el("span", { class = "oup-ulabel", text = "Card height, in rows" }),
		ui.el("div", { class = "oup-pills", attrs = { role = "group", ["aria-label"] = "How many rows the card may take" } }, pills),
		ui.el("span", {
			class = "oup-note",
			text = "Past it, accounts sum up to a row each, then fold into one. A row is 18px: pick what your omp pane holds above the composer.",
		}),
	})
	-- the stage's padding, the card (its rows and padding), the gap and the line: see `.oup-stage`, CARD_CSS
	local most = build.most_rows(settings, providers, cache, hint)
	if most > 0 then
		table.insert(rules, string.format("%s .oup-stage {\n\tmin-height: %dpx;\n}", PANEL, 28 + most * CARD_ROW + 14 + 8 + 15))
	end
	if #preview.groups == 0 and #preview.others == 0 then
		return section("preview", "Preview", "what the composer shows, its card open as on a hover", {
			ui.el("div", { class = "oup-stage" }, {
				ui.el("div", { class = "oup-empty", text = "Nothing to show. Focus an omp pane, or show a window below." }),
			}),
			height,
		})
	end
	local line = line_of(preview)
	table.insert(rules, palette_css(preview, settings, PANEL .. " .oup-stage"))
	local rest = tips(line, 55)
	table.insert(rules, string.format("%s .oup-line {\n\tbackground-image: %s;\n}", PANEL, line_paint(line)))
	if #rest.images > 0 then
		table.insert(
			rules,
			string.format(
				"%s .oup-line::after {\n\tcontent: \"\";\n\tposition: absolute;\n\tleft: 0;\n\tright: 0;\n\ttop: 0;\n\theight: 13px;\n\tbackground-image: %s;\n\tbackground-position: %s;\n\tbackground-size: %s;\n\tbackground-repeat: no-repeat;\n\tpointer-events: none;\n}",
				PANEL,
				table.concat(rest.images, ", "),
				table.concat(rest.positions, ", "),
				table.concat(rest.sizes, ", ")
			)
		)
	end
	local rows = card(preview, hint, limit)
	table.insert(rules, card_css(rows, PANEL .. " .oup-card::before"))
	local children: { Node } = {
		ui.el("div", { class = "oup-stage" }, {
			ui.el("div", { class = "oup-card" }),
			ui.el("div", { class = "oup-line", text = line.text }),
		}),
		height,
	}
	if #rows > limit then
		table.insert(
			children,
			ui.el("div", {
				class = "oup-over",
				text = string.format(
					"This card takes %d rows, more than %d: a picked account and the providers without accounts don't fold. A short pane cuts its top off; raise the limit, or show less.",
					#rows,
					limit
				),
			})
		)
	end
	return section("preview", "Preview", "what the composer shows, its card open as on a hover", children)
end

function build.show(settings: Settings, providers: { Provider }): Node
	local details = mode_details(settings, providers)
	local options: { Node } = {}
	for _, mode in MODES do
		local on = settings.mode == mode.mode
		local head: { Node } = { ui.el("span", { class = "oup-opt-t", text = mode.label }) }
		if on then
			table.insert(head, ui.node("icon", { name = "check" }))
		end
		table.insert(
			options,
			ui.el("button", {
				key = "mode-" .. mode.mode,
				class = "oup-opt",
				actions = { click = "mode=" .. mode.mode },
				attrs = { ["data-on"] = if on then true else nil, ["aria-pressed"] = if on then "true" else "false" },
			}, {
				ui.el("span", { class = "oup-opt-head" }, head),
				ui.el("span", { class = "oup-opt-d", text = details[mode.mode] }),
			})
		)
	end
	return section("show", "Show", nil, { ui.el("div", { class = "oup-modes" }, options) })
end

-- What a provider has left, by window (`windows`: its own, or one account's): each a toggle that hides it from
-- the line or shows it again. An account's windows go by their labels without it, as its row names it.
local function left_now(settings: Settings, provider: Provider, windows: { Window }): { Node }
	local hidden = settings.hidden[provider.id] or {}
	local nodes: { Node } = {}
	for _, window in windows do
		local tone = tone_of(window.pct)
		local key = string.lower(window.label)
		local off = table.find(hidden, key) ~= nil
		table.insert(
			nodes,
			ui.el("button", {
				key = "w-" .. key,
				class = "oup-wt",
				actions = { click = "window=" .. provider.id .. "/" .. key },
				attrs = {
					["aria-pressed"] = if off then "false" else "true",
					["aria-label"] = (if off then "Show " else "Hide ") .. provider.label .. " " .. window.label .. " on the line",
					["data-off"] = if off then true else nil,
				},
			}, {
				ui.el("span", { class = "oup-w", text = string.upper(window.bare or window.label) }),
				ui.el("span", { class = "oup-v", text = tostring(window.pct) .. "%", attrs = { ["data-low"] = if tone ~= "ok" then tone else nil } }),
			})
		)
	end
	if #nodes == 0 then
		table.insert(nodes, ui.el("span", { class = "oup-w", text = if provider.line == "" then "no data yet" else "no limits" }))
	end
	return nodes
end

-- Reordering in the panel is pick and place (Tern's views have no drag): a row's grip picks it up, every gap it
-- can go to opens as a slot, and a click on one puts it there. `moving` is what is picked up (a provider by id, or
-- an account of provider `id` by name) until it is placed, put back with its grip, or another setting changes.
type Moving = { kind: string, id: string, name: string? }
local moving: Moving? = nil

-- A row's grip (`grab=<what>`): picks it up, or, picked up, puts it back.
local function grip(what: string, label: string, lifted: boolean): Node
	return ui.el("button", {
		class = "oup-grip",
		actions = { click = "grab=" .. what },
		attrs = {
			["aria-label"] = if lifted then "Put " .. label .. " back" else "Pick up " .. label .. " to move it",
			["aria-pressed"] = if lifted then "true" else "false",
		},
	}, { ui.node("icon", { name = if lifted then "x" else "grip" }) })
end

-- `rows` (one per item of `items`, ids or names in order) and, while `lifted` (one of them, called `label`) is picked
-- up, a slot in every gap it can go to but its own: `place=<prefix><at>`, `at` as `moved` counts it.
local function with_slots(items: { string }, rows: { Node }, lifted: string?, label: string, prefix: string): { Node }
	if lifted == nil or not table.find(items, lifted :: string) then
		return rows
	end
	local function slot(key: string, at: number): Node
		return ui.el("button", {
			key = key,
			class = "oup-slot",
			actions = { click = "place=" .. prefix .. tostring(at) },
			attrs = { ["aria-label"] = "Move " .. label .. " here" },
		}, {
			ui.el("span", { class = "oup-slot-t", text = label .. " here" }),
			ui.el("span", { class = "oup-slot-line" }),
		})
	end
	local out: { Node } = {}
	local passed = 0 -- items before this one, the lifted one aside
	for i, item in items do
		if item ~= lifted and items[i - 1] ~= lifted then
			table.insert(out, slot("s-" .. tostring(i), passed + 1))
		end
		table.insert(out, rows[i])
		if item ~= lifted then
			passed += 1
		end
	end
	if items[#items] ~= lifted then
		table.insert(out, slot("s-end", passed + 1))
	end
	return out
end

-- Where a provider with several accounts would list its windows: one quiet chip saying what the line and card show
-- (`shown`: the accounts switched on, in order), and a button for the next way to show them: `all 8 accounts` with
-- `combine`; combined, `combined · 8 accounts ✕` with `by plan`; by plan, `by plan · 6 with 5H, 4 without ✕`
-- with `all in one` (see `combined`); with one picked, `only dev.ops ✕`. The ✕ chips are buttons that
-- show every account again. The accounts are picked on their rows (see `account_rows`).
function build.account_chip(settings: Settings, provider: Provider, shown: { string }): Node
	local chosen = chosen_account(settings, provider.id, provider.accounts)
	local function clear(text: string, label: string): Node
		return ui.el("button", {
			class = "oup-pick",
			actions = { click = "account=" .. provider.id .. "/" },
			attrs = { ["aria-label"] = label },
		}, {
			ui.el("span", { class = "oup-pick-t", text = text }),
			ui.node("icon", { name = "x" }),
		})
	end
	local function with_button(chip: Node, text: string, act: string, label: string): Node
		return ui.el("span", { class = "oup-picks" }, {
			chip,
			ui.el("button", {
				class = "oup-pick oup-combine",
				text = text,
				actions = { click = act .. "=" .. provider.id },
				attrs = { ["aria-label"] = label },
			}),
		})
	end
	if chosen then
		return clear("only " .. (chosen :: string), "Only " .. (chosen :: string) .. " shows: show every " .. provider.label .. " account again")
	end
	local mode = settings.account[provider.id]
	if #shown > 1 and (mode == COMBINED or mode == COMBINED_PLANS) then
		-- the groups as the line and card have them (hidden windows left out)
		local _, _, info = account_view(settings, provider.id, provider.accounts, shown_windows(settings, provider.id, provider.windows))
		local chip = clear(if info then info.chip else "combined", provider.label .. "'s accounts show combined: show each account again")
		if mode == COMBINED then
			return with_button(chip, "by plan", "combine-plans", "Combine " .. provider.label .. "'s accounts by plan: the accounts with the same windows together")
		end
		return with_button(chip, "all in one", "combine", "Combine all of " .. provider.label .. "'s accounts in one set of windows")
	end
	local text = if #shown > 1
		then string.format("all %d accounts", #shown)
		elseif #shown == 1 then "only " .. shown[1] .. " is on"
		else "every account is off"
	local chip = ui.el("span", { class = "oup-pick" }, { ui.el("span", { class = "oup-pick-t", text = text }) })
	if #shown < 2 then
		return chip
	end
	return with_button(chip, "combine", "combine", "Combine " .. provider.label .. "'s accounts: one set of windows, each window's share their average")
end

-- Under a provider with several accounts, a row per account in the line's order: its grip, name, windows (each a
-- toggle, as a provider's are) and a switch that takes it off the line and out of the card, or back. A click on
-- an account's name shows only that account; on the picked one's, every account again. The picked row's name is
-- lit and tagged `only`; the others fade (the card sums them up). Combined by plan, each row is tagged with its
-- group (`5H`, `no 5H`; see `combined`). Switched off, a row fades, its name is struck through and can't be
-- picked.
local function account_rows(settings: Settings, provider: Provider, names: { string }): Node
	local chosen = chosen_account(settings, provider.id, provider.accounts)
	local lifted = if moving and moving.kind == "account" and moving.id == provider.id then moving.name else nil
	local rows: { Node } = {}
	local tags: { [string]: string } = {}
	if chosen == nil and settings.account[provider.id] == COMBINED_PLANS then
		local _, _, info = account_view(settings, provider.id, provider.accounts, shown_windows(settings, provider.id, provider.windows))
		tags = if info then info.tags else {}
	end
	-- an account's name: a button that picks it (or, picked, shows all again), plain text while it is off
	local function account_name(name: string, off: boolean): Node
		local text = ui.el("span", { class = "oup-aname-t", text = name })
		if off then
			return ui.el("span", { class = "oup-aname" }, { text })
		end
		local picked = chosen == name
		local children: { Node } = { text }
		if picked then
			table.insert(children, ui.el("span", { class = "oup-only", text = "only" }))
		end
		return ui.el("button", {
			class = "oup-aname",
			actions = { click = "account=" .. provider.id .. "/" .. (if picked then "" else name) },
			attrs = {
				["aria-pressed"] = if picked then "true" else "false",
				["aria-label"] = if picked then "Show every " .. provider.label .. " account again" else "Show only " .. provider.label .. " " .. name,
			},
		}, children)
	end
	-- each account's windows, in one pass over the provider's
	local by: { [string]: { Window } } = {}
	for _, window in provider.windows do
		local owner, bare = account_of(window.label, provider.accounts)
		if owner then
			local copy = table.clone(window)
			copy.account, copy.bare = owner, bare
			by[owner] = by[owner] or {}
			table.insert(by[owner], copy)
		end
	end
	for _, name in names do
		local windows = by[name] or {}
		local off = account_off(settings, provider.id, name)
		local value = provider.id .. "/" .. name
		table.insert(
			rows,
			ui.el("div", {
				key = "a-" .. name,
				class = "oup-arow",
				attrs = {
					["data-hidden"] = if off then true else nil,
					["data-off"] = if chosen and chosen ~= name then true else nil,
					["data-picked"] = if chosen == name then true else nil,
					["data-moving"] = if lifted == name then true else nil,
				},
			}, {
				grip("account/" .. value, name, lifted == name),
				account_name(name, off),
				ui.el("span", { class = "oup-sum" }, (function(): { Node }
					local nodes = left_now(settings, provider, windows)
					if tags[name] and not off then
						table.insert(nodes, ui.el("span", { class = "oup-group", text = tags[name] }))
					end
					return nodes
				end)()),
				ui.el("span", { class = "oup-ctl" }, {
					ui.el("button", {
						class = "oup-switch oup-aswitch",
						actions = { click = "account-show=" .. value },
						attrs = {
							role = "switch",
							["aria-checked"] = if off then "false" else "true",
							["aria-label"] = provider.label .. " " .. name .. " on the line and in the card",
							["data-on"] = if off then nil else true,
						},
					}, { ui.el("span", { class = "oup-knob" }) }),
				}),
			})
		)
	end
	return ui.el("div", { class = "oup-accts" }, with_slots(names, rows, lifted, lifted or "", "account/" .. provider.id .. "/"))
end

local function provider_row(settings: Settings, provider: Provider, i: number): Node
	local on = table.find(settings.selected, provider.id) ~= nil
	local lifted = moving ~= nil and moving.kind == "provider" and moving.id == provider.id
	local names = accounts_in_order(provider.accounts, settings.account_order[provider.id])
	local several = #names > 1
	local children: { Node } = {
		ui.el("span", { class = "oup-who" }, {
			grip("provider/" .. provider.id, provider.label, lifted),
			ui.el("span", { class = "oup-idx", text = string.format("%02d", i) }),
			ui.el("span", { class = "oup-swatch" }),
			ui.el("span", { class = "oup-name", text = provider.label }),
		}),
		ui.el(
			"span",
			{ class = if several then "oup-sum oup-sum-pick" else "oup-sum" },
			if several then { build.account_chip(settings, provider, shown_accounts(settings, provider)) } else left_now(settings, provider, provider.windows)
		),
		ui.el("span", { class = "oup-ctl" }, {
			ui.el("button", {
				class = "oup-switch",
				actions = { click = "toggle=" .. provider.id },
				attrs = {
					role = "switch",
					["aria-checked"] = if on then "true" else "false",
					["aria-label"] = provider.label .. " under Selected providers",
					["data-on"] = if on then true else nil,
				},
			}, { ui.el("span", { class = "oup-knob" }) }),
		}),
	}
	if several then
		table.insert(children, account_rows(settings, provider, names))
	end
	return ui.el("div", {
		key = "p-" .. provider.id,
		class = "oup-prow",
		attrs = {
			["data-ou-pal"] = "p-" .. pal_key(color_key(provider.id, provider.label)),
			["data-off"] = if settings.mode == "selected" and not on then true else nil,
			["data-moving"] = if lifted then true else nil,
		},
	}, children)
end

function build.providers(settings: Settings, providers: { Provider }): Node
	local rows: { Node } = {}
	local ids: { string } = {}
	local accounts = false
	for i, provider in providers do
		table.insert(rows, provider_row(settings, provider, i))
		table.insert(ids, provider.id)
		accounts = accounts or #provider.accounts > 1
	end
	local note = "Top to bottom is the line's left to right: pick a row up by its grip, then click where it goes. "
		.. "Click a window to hide or show it; the switches pick what Selected providers shows."
	if accounts then
		note ..= " With several accounts, click an account's name to show only it (again for all); its switch takes it off the line and card."
	end
	local lifted = if moving and moving.kind == "provider" then moving.id else nil
	local label = if lifted then label_of(providers, lifted :: string) else ""
	return section("providers", "Providers", note, {
		ui.el(
			"div",
			{ class = "oup-rows", attrs = { ["data-idle"] = if settings.mode ~= "selected" then true else nil } },
			with_slots(ids, rows, lifted, label, "provider/")
		),
	})
end

local function color_row(settings: Settings, provider: Provider, rules: { string }): Node
	local key = color_key(provider.id, provider.label)
	local pk = pal_key(key)
	local spec = settings.colors[key]
	local preset = preset_for(provider.id, provider.label)
	local dots: { Node } = {}
	local function dot(pal: string, name: string, act: string, on: boolean)
		table.insert(
			dots,
			ui.el("button", {
				class = "oup-dot",
				actions = { click = act },
				attrs = {
					["data-ou-pal"] = pal,
					["aria-label"] = name,
					["data-name"] = name,
					["aria-pressed"] = if on then "true" else "false",
					["data-on"] = if on then true else nil,
				},
			})
		)
	end
	table.insert(rules, palette_rule("s-" .. pk, preset))
	dot("s-" .. pk, preset.name .. " (preset)", "preset=" .. key, spec == nil)
	for _, item in NAMED do
		dot("n-" .. item.key, item.palette.name, "named=" .. key .. "/" .. item.key, spec == "named:" .. item.key)
	end
	local custom = if spec and string.sub(spec, 1, 1) == "#" then palette_of_spec(spec) else nil
	if custom then
		table.insert(rules, palette_rule("c-" .. pk, custom))
		dot("c-" .. pk, "Your " .. custom.name, "custom=" .. key, true)
	end
	-- your own colors, and back to the preset, side by side wherever the swatches wrap
	local acts: { Node } = { ui.el("button", { class = "oup-btn", text = "Custom…", actions = { click = "custom=" .. key } }) }
	if spec then
		table.insert(acts, ui.el("button", { class = "oup-btn", text = "Reset", actions = { click = "reset=" .. key } }))
	end
	table.insert(dots, ui.el("span", { class = "oup-acts" }, acts))
	return ui.el("div", { key = "c-" .. provider.id, class = "oup-crow", attrs = { ["data-ou-pal"] = "p-" .. pk } }, {
		ui.el("span", { class = "oup-chead" }, {
			ui.el("span", { class = "oup-name", text = provider.label }),
			ui.el("span", { class = "oup-cname", text = color_name(settings, provider) }),
		}),
		ui.el("div", { class = "oup-dots" }, dots),
	})
end

function build.colors(settings: Settings, providers: { Provider }, rules: { string }): Node
	local rows: { Node } = {}
	for _, provider in providers do
		table.insert(rows, color_row(settings, provider, rules))
	end
	return section("colors", "Colors", "A label's color and its bars'. Point at a swatch for its name.", rows)
end

-- Updates (update.luau), in Tern's words: what's installed and whether an update is waiting, with Download Update
-- (and What's New, the update card) or Check for Updates, then how often the automatic check runs.
local function update_status(): (string, string?)
	local version = update.version()
	local name = "omp Usage" .. (if version then " " .. version else "")
	local pending = update.pending()
	if pending then
		local next = if pending.version and pending.version ~= version then pending.version else pending.short
		return "omp Usage " .. next .. " is available", "You have " .. (version or "an earlier version")
	end
	local last = update.last_checked()
	if last == nil then
		return name, nil
	end
	return name .. " is up to date", "Checked " .. span(math.max(0, os.time() - last) * 1000) .. " ago"
end

function build.updates(): Node
	local current = update.interval()
	local pills: { Node } = {}
	for _, interval in update.INTERVALS do
		local on = interval.id == current.id
		table.insert(pills, ui.el("button", {
			class = "oup-pill",
			text = interval.label,
			actions = { click = "update-every=" .. interval.id },
			attrs = { ["data-on"] = if on then true else nil, ["aria-pressed"] = if on then "true" else "false" },
		}))
	end
	local title, sub = update_status()
	local say: { Node } = { ui.el("span", { class = "oup-utitle", text = title }) }
	if sub then
		table.insert(say, ui.el("span", { class = "oup-usub", text = sub }))
	end
	local buttons: { Node }
	if update.pending() then
		buttons = {
			ui.el("button", { class = "oup-btn oup-primary", text = "Download Update", actions = { click = "update-download" } }),
			ui.el("button", { class = "oup-btn", text = "What's New", actions = { click = "update-check" } }),
		}
	else
		buttons = { ui.el("button", { class = "oup-btn", text = "Check for Updates", actions = { click = "update-check" } }) }
	end
	return section("updates", "Updates", nil, {
		ui.el("div", { class = "oup-ustat", attrs = { ["data-ready"] = if update.pending() then true else nil } }, {
			ui.el("span", { class = "oup-say" }, say),
			ui.el("span", { class = "oup-acts" }, buttons),
		}),
		ui.el("div", { class = "oup-urow" }, {
			ui.el("span", { class = "oup-ulabel", text = "Check automatically" }),
			ui.el("div", { class = "oup-pills", attrs = { role = "group", ["aria-label"] = "How often omp Usage checks for updates" } }, pills),
		}),
	})
end

local function panel_dock(keys: string?): Node
	local children: { Node } = {
		ui.node("icon", { name = "check" }),
		ui.el("span", { text = "Changes apply at once" }),
	}
	if keys then
		local caps: { Node } = {}
		for key in string.gmatch(keys :: string, "[^+ ]+") do
			table.insert(caps, ui.el("span", { class = "oup-key", text = key }))
		end
		table.insert(children, ui.el("span", { class = "oup-sep" }))
		table.insert(children, ui.el("span", { class = "oup-hint" }, {
			ui.el("span", { class = "oup-keys" }, caps),
			ui.el("span", { text = "opens this panel" }),
		}))
	end
	local keys_of_details = details_shortcut()
	table.insert(children, ui.el("span", { class = "oup-grow" }))
	table.insert(children, ui.button("Quota details", {
		icon = "gauge",
		variant = "quiet",
		title = if keys_of_details then "Open the quota details (" .. keys_of_details .. ")" else "Open the quota details",
		actions = { click = "details" },
	}))
	return ui.el("div", { role = DOCK_ROLE }, children)
end

-- What the panel shows now: the settings, the providers in order, the line it previews (the last pane's, drawn
-- with these settings), the cache it came from and the shortcut; `sig` changes whenever any of it does.
type PanelState = { settings: Settings, providers: { Provider }, preview: Model, cache: Cache?, keys: string?, sig: string }

local function panel_state(cx: WindowCx, settings: Settings, cache: Cache?): PanelState
	local providers = ordered(offered_providers(cache), settings.order)
	local preview = build_model(settings, last_dock() or NO_DOCK, cache)
	local keys = shortcut(cx)
	local parts: { string } = {
		settings.mode,
		table.concat(settings.selected, ","),
		table.concat(settings.order, ","),
		colors_key(settings),
		hidden_key(settings),
		keys or "",
		details_shortcut() or "",
		tostring(settings.card_rows),
		update.interval().id,
		(function(): string
			local title, sub = update_status()
			return title .. "|" .. (sub or "")
		end)(),
	}
	for _, provider in providers do
		local windows: { string } = {}
		for _, window in provider.windows do
			table.insert(windows, window.label .. ":" .. tostring(window.pct))
		end
		local accounts = table.concat(accounts_in_order(provider.accounts, settings.account_order[provider.id]), ",")
		local off = table.concat(settings.account_hidden[provider.id] or {}, ",")
		table.insert(
			parts,
			table.concat({ provider.id, provider.label, provider.line, table.concat(windows, ","), accounts, settings.account[provider.id] or "", off }, "|")
		)
	end
	table.insert(parts, if moving then moving.kind .. ":" .. moving.id .. ":" .. (moving.name or "") else "")
	table.insert(parts, preview.signature)
	return { settings = settings, providers = providers, preview = preview, cache = cache, keys = keys, sig = table.concat(parts, "\n") }
end

-- The panel's view, its bottom bar and its sheet.
local function panel_parts(state: PanelState): (Node, Node, string)
	local rules: { string } = { PANEL_CSS, NAMED_CSS }
	for _, provider in state.providers do
		local pal = "p-" .. pal_key(color_key(provider.id, provider.label))
		table.insert(rules, palette_rule(pal, palette_for(state.settings, provider.id, provider.label)))
	end
	local view = ui.el("div", { role = PANEL_ROLE }, {
		build.preview(state.settings, state.preview, rules, settings_hint(state.keys), state.providers, state.cache),
		build.show(state.settings, state.providers),
		build.providers(state.settings, state.providers),
		build.colors(state.settings, state.providers, rules),
		build.updates(),
	})
	return view, panel_dock(state.keys), table.concat(rules, "\n")
end

local panel_sig: string? = nil
-- While an update lands (update.luau), the panel shows an Updating… view instead and isn't redrawn.
local panel_paused = false
local panel_css: string? = nil

local function install_panel(css: string)
	if css ~= panel_css then
		panel_css = css
		tern.css(PANEL_SHEET, css)
	end
end

-- A drawing `sync_panel` scheduled and hasn't run yet; `flush_panel` runs it at once.
local pending_draw: ((cx: WindowCx) -> ())? = nil

-- Redraws the panel if what it shows changed (or `force`), from the poll's settings and cache when it has them.
-- The drawing (the view, its sheet and the update, ~10 ms) runs in a call of its own, so a poll that also drew
-- the line stays well inside its budget.
sync_panel = function(cx: WindowCx, force: boolean, settings: Settings?, cache: Cache?)
	local pane = panel_pane
	if pane == nil or panel_paused then
		return
	end
	local state = if settings then panel_state(cx, settings, cache) else panel_state(cx, load_settings(), read_cache(now_ms()))
	if state.sig == panel_sig and not force then
		return
	end
	panel_sig = state.sig
	local function draw(later: WindowCx)
		if pending_draw ~= draw then
			return -- drawn already, or a newer drawing replaced this one
		end
		pending_draw = nil
		if panel_pane ~= pane then
			return -- closed or replaced
		end
		local view, dock, css = panel_parts(state)
		install_panel(css)
		local ok = pcall(function()
			later.canvas:set(pane :: number, { view = view, dock = dock })
		end)
		if not ok then
			panel_pane = nil -- closed meanwhile
			panel_sig = nil
		end
	end
	pending_draw = draw
	tern.timer(0, function(later: WindowCx?)
		if later then
			draw(later)
		end
	end)
end

-- Draws a scheduled panel drawing now. Tern runs a timer set in an event handler (a click in the panel, a picker's
-- answer) only at the plugin's next poll, up to a second later, so a choice made there draws at once instead.
flush_panel = function(cx: WindowCx)
	local draw = pending_draw
	if draw then
		draw(cx)
	end
end

-- An update about to land, announced by any window: the plugin's sheets go away while Tern reloads it, so the
-- panel shows only Tern-styled nodes until then. The reloaded plugin draws the panel afresh (the reload timer
-- below); an update that failed brings the panel back here.
local function watch_update(cx: WindowCx?)
	tern.timer(1000, watch_update)
	local pane = panel_pane
	if cx == nil then
		return
	end
	local name = update.applying()
	if name and pane and not panel_paused then
		panel_paused = true
		panel_sig = nil
		pcall(function()
			cx.canvas:set(pane :: number, {
				view = ui.col({
					ui.card({ ui.span("Updating omp Usage to " .. name, "strong") }, {
						ui.progress(nil, "Downloading the update and reloading the plugin"),
					}, { icon = "download" }),
				}),
				dock = ui.text(ui.span("The settings come back as soon as it reloads", "muted")),
			})
		end)
	elseif name == nil and panel_paused then
		panel_paused = false
		sync_panel(cx, true)
	end
end
tern.timer(1000, watch_update)

-- This plugin's panel in this window, if one is open.
local function find_panel(cx: WindowCx): number?
	local ok, list = pcall(function(): any
		return cx.canvas:list()
	end)
	if ok and type(list) == "table" then
		for _, info in list do
			if info.owner == tern.plugin.id and info.title == PANEL_TITLE then
				return info.pane
			end
		end
	end
	return nil
end

local function open_panel(cx: WindowCx)
	local pane = find_panel(cx)
	if pane then
		panel_pane = pane
		sync_panel(cx, true)
		cx.layout:focus(pane :: number)
		return
	end
	local state = panel_state(cx, load_settings(), read_cache(now_ms()))
	local view, dock, css = panel_parts(state)
	install_panel(css)
	local opened, err = cx.canvas:open({ title = PANEL_TITLE, about = PANEL_ABOUT, view = view, dock = dock, how = "beside" })
	if opened == nil then
		cx:toast("error", "The omp Usage settings didn't open", err)
		return
	end
	panel_pane = opened
	panel_sig = state.sig
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean
	if ev.title == detail_view.title and ev.act == "settings" then
		detail_view.close(cx, ev.pane)
		open_panel(cx)
		return true
	end
	-- Quota details in the bottom bar: the details take the panel's place, as their Settings button gives it back.
	if ev.title == PANEL_TITLE and ev.act == "details" then
		cx.layout:close(ev.pane)
		panel_pane, panel_sig, moving = nil, nil, nil
		open_details(cx)
		return true
	end
	if ev.title ~= nil and ev.title ~= PANEL_TITLE then
		return false
	end
	panel_pane = ev.pane
	local act, value = ev.act, ev.value or ""
	-- What was picked up to move: a grab picks up (or puts back), a place puts it there, anything else puts it back.
	local lifted = moving
	moving = nil
	if act == "grab" then
		local id, name = string.match(value, "^account/([^/]+)/(.+)$")
		local picked: Moving? = if id and name then { kind = "account", id = id, name = name } else nil
		local provider = string.match(value, "^provider/(.+)$")
		if picked == nil and provider then
			picked = { kind = "provider", id = provider }
		end
		if picked == nil then
			moving = lifted
			return false
		end
		local again = lifted ~= nil and lifted.kind == picked.kind and lifted.id == picked.id and lifted.name == picked.name
		moving = if again then nil else picked
	elseif act == "place" then
		local kind, at = string.match(value, "^(%a+)/.-(%d+)$")
		local slot = tonumber(at)
		if lifted == nil or kind ~= lifted.kind or slot == nil then
			return false
		end
		if lifted.kind == "provider" then
			move_provider(lifted.id, slot :: number)
		elseif lifted.name then
			move_account(lifted.id, lifted.name :: string, slot :: number)
		end
	elseif act == "mode" then
		if value ~= "current" and value ~= "all" and value ~= "selected" then
			return false
		end
		store.set(KV_MODE, value)
	elseif act == "toggle" then
		store.set(KV_SELECTED, toggled(load_settings().selected, value))
		store.set(KV_MODE, "selected") -- switching a provider is choosing which to show
	elseif act == "window" then
		local id, label = string.match(value, "^([^/]+)/(.+)$")
		if id == nil or label == nil then
			return false
		end
		toggle_window(id, label)
	elseif act == "account" then
		local id, name = string.match(value, "^([^/]+)/(.*)$")
		if id == nil or name == nil then
			return false
		end
		choose_account(id, name)
	elseif act == "combine" then
		choose_account(value, COMBINED)
	elseif act == "combine-plans" then
		choose_account(value, COMBINED_PLANS)
	elseif act == "card-rows" then
		local rows = tonumber(value)
		if rows == nil or not table.find(CARD_ROWS, rows) then
			return false
		end
		store.set(KV_CARD_ROWS, rows)
	elseif act == "account-show" then
		local id, name = string.match(value, "^([^/]+)/(.+)$")
		if id == nil or name == nil then
			return false
		end
		toggle_account(id, name)
	elseif act == "named" then
		local key, name = string.match(value, "^(.*)/([^/]+)$")
		if key == nil or name == nil or named_palette(name) == nil then
			return false
		end
		save_color(key, "named:" .. name)
	elseif act == "preset" or act == "reset" then
		save_color(value, nil)
	elseif act == "custom" then
		prompt_color(cx, value, label_of(store.providers(), value))
		return true
	elseif act == "update-check" then
		update.check(cx, true)
		return true
	elseif act == "update-every" then
		update.set_interval(cx, value)
	elseif act == "update-download" then
		update.download(cx)
		return true
	else
		moving = lifted
		return false
	end
	after_change(cx)
	return true
end)

tern.on("pane_closed", function(ev: { pane: number }, _cx: WindowCx)
	if ev.pane == panel_pane then
		panel_pane = nil
		panel_sig = nil
		moving = nil
	end
end)

-- A reload finds the panel Tern kept, and draws it (its sheet went with the reload), once the first poll is done.
tern.timer(600, function(cx: WindowCx?)
	if cx then
		panel_pane = find_panel(cx)
		if panel_pane then
			sync_panel(cx, true)
		end
	end
end)

-- The panel's pane while it is open, for window.luau's `refresh`.
local function pane(): number?
	return panel_pane
end

return {
	init = init,
	pane = pane,
	sync_panel = sync_panel,
	flush_panel = flush_panel,
	open_panel = open_panel,
}
