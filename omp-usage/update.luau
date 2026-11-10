--!strict
-- Updates for this plugin's git clone (the README installs it as a clone that `tern plugin link` loads in place),
-- the way Tern updates itself: quietly, until you choose.
--
-- At the interval the user picks (every 6 hours unless changed, or never), an automatic check fetches the checked-out
-- branch's upstream. When the branch is behind, it remembers the newest commit as the pending update, says so in a
-- toast, and every window shows an Update omp Usage button in its status line. That button, `omp Usage: Check for
-- updates…` and the settings panel's Check for Updates check again and open the update card: the version that's
-- available and the one you have (from `plugin.toml` on each side, else commit hashes), Download Update (a
-- fast-forward to the pending commit, after which Tern reloads the plugin), Skip This Version (no automatic toast or
-- button again until the upstream moves past it) and Not Now, over every new commit in full.
--
-- What it remembers lives in `tern.kv`, which every window shares, so one window checks per interval (windows that
-- tick together claim the check, and the claim that lands last wins), and the pending update, a skipped version and
-- the interval are the same in all of them.

-- How often the automatic check runs: `hours` nil is never.
export type Interval = { id: string, label: string, hours: number? }
-- The update an automatic or manual check found, until it's downloaded or skipped: the newest upstream commit and
-- the version its `plugin.toml` says, when it says one.
export type Pending = { sha: string, short: string, version: string? }

type Module = {
	INTERVALS: { Interval },
	interval: () -> Interval,
	set_interval: (cx: WindowCx, id: string) -> (),
	version: () -> string?,
	pending: () -> Pending?,
	last_checked: () -> number?,
	check: (cx: WindowCx, manual: boolean) -> (),
	download: (cx: WindowCx) -> (),
	status_segment: () -> StatusSegment?,
}
local M = {} :: Module

M.INTERVALS = {
	{ id = "1h", label = "Hourly", hours = 1 },
	{ id = "6h", label = "Every 6 hours", hours = 6 },
	{ id = "1d", label = "Daily", hours = 24 },
	{ id = "1w", label = "Weekly", hours = 24 * 7 },
	{ id = "off", label = "Off", hours = nil },
}
local DEFAULT_INTERVAL = "6h"

local KV_EVERY = "omp-usage.update-every" -- an INTERVALS id
local KV_AUTO = "omp-usage.update-auto" -- 0.2.0's on/off switch: false is read as `off` until an interval is set
local KV_CHECKED = "omp-usage.update-checked" -- os.time() of the last automatic check, reached or not
local KV_LAST = "omp-usage.update-last" -- os.time() of the last check that reached the remote
local KV_PENDING = "omp-usage.update-pending" -- a Pending
local KV_KEPT = "omp-usage.update-kept" -- the upstream commit the user skipped
local KV_CLAIM = "omp-usage.update-claim" -- the window that claimed the automatic check

local FIRST_CHECK_MS = 20 * 1000 -- after a load, past Tern's own startup work
local CLAIM_SETTLE_MS = 2000 -- long enough for every window ticking with this one to write its claim
local TICK_MS = 60 * 60 * 1000 -- how often each window looks whether a check is due: the shortest interval
local BADGE_POLL_MS = 10 * 1000 -- how soon a window shows (or drops) the status button another window decided
local CARD_COMMITS = 100 -- commits the update card shows in full
local BODY_MAX = 4000 -- characters of one commit's message body the card shows
local RELOAD_FALLBACK_MS = 5000 -- after an update, how long Tern's folder watch gets to reload the plugin
-- No credential prompts or windows: a remote that needs them fails the check instead.
local GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GCM_INTERACTIVE = "never" }
local UPDATE_ACTION = "plugin." .. tern.plugin.id .. ".update"

type Git = { ok: boolean, out: string, err: string }
type Commit = { sha: string, short: string, when: string, author: string, subject: string, body: string }
-- What a check found: the commits between HEAD and the upstream, newest first, and both sides' versions.
type Offer = {
	head: string,
	behind: number,
	commits: { Commit },
	web: string?,
	current: string?,
	available: string?,
}

local function kv_get(key: string): any
	local ok, value = pcall(tern.kv.get, key)
	return if ok then value else nil
end

local function kv_set(key: string, value: any)
	pcall(tern.kv.set, key, value)
end

local function trim(text: string): string
	return (string.gsub(text, "^%s+", ""):gsub("%s+$", ""))
end

local function plural(n: number, word: string): string
	return tostring(n) .. " " .. word .. (if n == 1 then "" else "s")
end

-- The `version = "…"` of a plugin.toml's text.
local function toml_version(text: string): string?
	local version = string.match("\n" .. text, '\n%s*version%s*=%s*"([^"\n]+)"')
	return if version then trim(version) else nil
end

-- git's message for a failure: its first `fatal:` or `error:` line without the prefix (git prints warnings, such
-- as line-ending ones, before it), else its first line that isn't a warning or hint.
local function reason(text: string): string
	local fallback: string? = nil
	for line in string.gmatch(text, "[^\r\n]+") do
		local message = string.match(line, "^fatal: (.*)$") or string.match(line, "^error: (.*)$")
		if message then
			return trim(message)
		end
		if fallback == nil and string.find(line, "%S") and not string.find(line, "^warning: ") and not string.find(line, "^hint: ") then
			fallback = trim(line)
		end
	end
	return fallback or "git failed"
end

-- Runs git in the plugin's directory; `done` gets a fresh cx when the window gave one, else `cx`.
local function git(cx: WindowCx, args: { string }, timeout_ms: number, done: (Git, WindowCx) -> ())
	local argv = { "git" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local opts = { cwd = tern.plugin.dir, env = GIT_ENV, timeout_ms = timeout_ms }
	local started, err = pcall(function()
		tern.process.run(argv, opts, function(result: ProcessResult, later: WindowCx?)
			local failure = if result.timed_out then "git took too long" else result.stderr
			done({ ok = result.status == 0, out = result.stdout, err = failure }, later or cx)
		end)
	end)
	if not started then
		done({ ok = false, out = "", err = "git didn't start: " .. tostring(err) }, cx)
	end
end

-- The web page of a remote (`https://host/owner/repo`) from its fetch URL: https with or without a user, scp-like
-- `git@host:owner/repo` and `ssh://`. Nil for anything else (a local path).
local function web_base(url: string): string?
	-- `scheme://[user@]host[:port]/path`, or scp-like `user@host:path`
	local address, path = string.match(url, "^https?://([^/]+)/(.+)$")
	if address == nil then
		address, path = string.match(url, "^ssh://([^/]+)/(.+)$")
	end
	if address == nil then
		address, path = string.match(url, "^([%w._-]+@[^:/]+):(.+)$")
	end
	if address == nil or path == nil then
		return nil
	end
	local host = string.match(address :: string, "([^@:]+):?%d*$")
	if host == nil then
		return nil
	end
	return "https://" .. host .. "/" .. (string.gsub(path :: string, "%.git/?$", ""):gsub("/$", ""))
end

function M.interval(): Interval
	local id = kv_get(KV_EVERY)
	if id == nil and kv_get(KV_AUTO) == false then
		id = "off"
	end
	local fallback = M.INTERVALS[1]
	for _, interval in M.INTERVALS do
		if interval.id == id then
			return interval
		end
		if interval.id == DEFAULT_INTERVAL then
			fallback = interval
		end
	end
	return fallback
end

-- Sets how often the automatic check runs.
function M.set_interval(cx: WindowCx, id: string)
	local chosen: Interval? = nil
	for _, interval in M.INTERVALS do
		if interval.id == id then
			chosen = interval
		end
	end
	if chosen == nil then
		return
	end
	kv_set(KV_EVERY, id)
	kv_set(KV_AUTO, nil)
	if chosen.hours then
		cx:toast("info", "omp Usage checks for updates " .. string.lower(chosen.label))
	else
		cx:toast("info", "omp Usage won't check for updates on its own", "Check any time: omp Usage: Check for updates…")
	end
end

-- This clone's version, from its plugin.toml (read once: an update reloads the plugin).
local this_version: string? = nil
local version_read = false
function M.version(): string?
	if not version_read then
		version_read = true
		local ok, text = pcall(tern.fs.read, "plugin.toml", 64 * 1024)
		this_version = if ok and type(text) == "string" then toml_version(text) else nil
	end
	return this_version
end

function M.pending(): Pending?
	local value = kv_get(KV_PENDING)
	if type(value) == "table" and type(value.sha) == "string" and type(value.short) == "string" then
		return {
			sha = value.sha,
			short = value.short,
			version = if type(value.version) == "string" then value.version else nil,
		}
	end
	return nil
end

function M.last_checked(): number?
	local value = kv_get(KV_LAST)
	return if type(value) == "number" then value else nil
end

-- What an update is called: its version when plugin.toml moved, else its commit.
local function update_name(version: string?, current: string?, short: string): string
	if version and version ~= current then
		return version
	end
	return short
end

-- The status line's Update omp Usage button: every pane of every window, while an update is pending. Formatters
-- must be pure and fast, so it reads what `refresh_badge` last saw rather than `tern.kv`.
local badge: Pending? = nil

function M.status_segment(): StatusSegment?
	if badge == nil then
		return nil
	end
	return { text = "Update omp Usage", icon = "download", command = UPDATE_ACTION } -- bar.css makes it a pill
end

local function refresh_badge()
	local now = M.pending()
	if (now and now.sha) ~= (badge and badge.sha) then
		badge = now
		pcall(tern.chrome.refresh)
	end
end

local function badge_poll(_cx: WindowCx?)
	tern.timer(BADGE_POLL_MS, badge_poll)
	refresh_badge()
end
tern.timer(0, badge_poll)

local function set_pending(pending: Pending?)
	kv_set(KV_PENDING, pending)
	refresh_badge()
end

local busy = false -- a check is under way in this window

local function apply(cx: WindowCx, pending: Pending)
	if busy then
		cx:toast("info", "omp Usage is already checking or updating")
		return
	end
	busy = true
	local name = update_name(pending.version, M.version(), pending.short)
	-- Whether the omp extension changed: omp loads it at session start, so open sessions need a restart.
	git(cx, { "diff", "--name-only", "HEAD", pending.sha }, 10000, function(diff: Git, cx2: WindowCx)
		local extension = diff.ok and string.find("\n" .. diff.out, "\nomp/") ~= nil
		git(cx2, { "merge", "--ff-only", "--quiet", pending.sha }, 30000, function(merge: Git, cx3: WindowCx)
			busy = false
			if not merge.ok then
				cx3:toast("error", "omp Usage didn't update", reason(merge.err))
				return
			end
			kv_set(KV_KEPT, nil)
			set_pending(nil)
			local sub = if extension then "The omp extension changed: restart omp sessions" else nil
			cx3:toast("success", "omp Usage updated to " .. name, sub)
			-- Tern watches a linked clone and reloads this window's plugins when the merge changes it. Only if that
			-- didn't happen (this VM, which a reload replaces, is still here) ask for Reload plugins, which also
			-- empties every plugin canvas left open (the settings panel) until it's opened again.
			tern.timer(RELOAD_FALLBACK_MS, function(later: WindowCx?)
				if later then
					pcall(function()
						later:command("reload_plugins")
					end)
				end
			end)
		end)
	end)
end

-- The update card: a canvas beside the focused pane, headed by the version that's available and the one you have,
-- with Download Update, Skip This Version and Not Now in its bottom bar and every new commit in full beneath.
-- Its buttons act on the pending update in `tern.kv`, so a card left open across a reload still works.
local CARD_TITLE = "omp Usage update"
local CARD_ABOUT = "An update to the omp Usage plugin: the version that's available, the one installed, and every new "
	.. "commit. Download Update fast-forwards the plugin's git clone and reloads Tern's plugins; Skip This Version "
	.. "hides this update until a newer one; Not Now closes this panel. Nothing changes until one of them is clicked."
local CARD_ROLE = "omp-usage.update"
local CARD_DOCK_ROLE = "omp-usage.update-dock"
local CARD_SHEET = "update-card"
local C = "[data-role='" .. CARD_ROLE .. "']"
local D = "[data-role='" .. CARD_DOCK_ROLE .. "']"
local CARD_CSS = (string.gsub(string.gsub(
	[==[
$C {
	display: flex;
	flex-direction: column;
	gap: 18px;
	padding: 22px 24px 30px;
	font: 400 12.5px/18px var(--sans);
	color: var(--t2);
}
$C .ouu-head {
	display: flex;
	align-items: center;
	gap: 14px;
	padding-bottom: 18px;
	border-bottom: 1px solid var(--l2);
}
$C .ouu-icon {
	display: flex;
	flex: none;
	align-items: center;
	justify-content: center;
	width: 40px;
	height: 40px;
	border-radius: 11px;
	color: var(--accent);
	background-color: rgb(from var(--accent) r g b / 14%);
	box-shadow: inset 0 0 0 1px rgb(from var(--accent) r g b / 30%);
}
$C .ouu-say {
	display: flex;
	flex-direction: column;
	gap: 3px;
	min-width: 0;
}
$C .ouu-title {
	font: 600 16px/22px var(--sans);
	color: var(--t1);
}
$C .ouu-sub {
	font: 400 12px/16px var(--sans);
	color: var(--t3);
}
$C .ouu-label {
	font: 600 10px/14px var(--mono);
	letter-spacing: 0.16em;
	text-transform: uppercase;
	color: var(--t2);
}
/* the buttons wrap in a narrow pane rather than run off its edge */
$D {
	display: flex;
	flex-wrap: wrap;
	gap: 8px;
}
]==],
	"%$C",
	C
), "%$D", D))

local function md_escape(text: string): string
	return (string.gsub(text, "([\\`*_%[%]<>|#])", "\\%1"))
end

-- A message body with its hard wraps undone (git messages wrap at ~72 columns, and Tern's Markdown keeps every
-- line break): a line joins the one before it unless either is blank, it starts a list item, heading, quote,
-- table row or code fence, or it's inside a fenced block.
local function unwrap(body: string): string
	local out: { string } = {}
	local fenced = false
	local joinable = false -- whether the last line out can take the next one
	for raw in string.gmatch(body .. "\n", "([^\n]*)\n") do
		local line = (string.gsub(raw, "\r$", ""))
		local fence = string.find(line, "^%s*```") ~= nil
		local starts_block = fence
			or string.find(line, "^%s*[-*+] ") ~= nil
			or string.find(line, "^%s*%d+[.)] ") ~= nil
			or string.find(line, "^%s*[#>|]") ~= nil
		local blank = string.find(line, "%S") == nil
		if not fenced and joinable and not blank and not starts_block then
			out[#out] ..= " " .. trim(line)
		else
			table.insert(out, line)
		end
		if fence then
			fenced = not fenced
		end
		joinable = not fenced and not fence and not blank
	end
	return table.concat(out, "\n")
end

-- Every new commit, newest first: its subject, hash, age, author and web link, then its message.
local function commits_md(offer: Offer): string
	local parts: { string } = {}
	for _, commit in offer.commits do
		local meta = "`" .. commit.short .. "` · " .. md_escape(commit.when) .. " · " .. md_escape(commit.author)
		if offer.web then
			meta ..= " · [on the web](" .. offer.web .. "/commit/" .. commit.sha .. ")"
		end
		local body = unwrap(commit.body)
		if #body > BODY_MAX then
			body = string.sub(body, 1, BODY_MAX) .. "…"
		end
		table.insert(parts, "### " .. md_escape(commit.subject) .. "\n\n" .. meta .. (if body ~= "" then "\n\n" .. body else ""))
	end
	local rest = offer.behind - #offer.commits
	if rest > 0 then
		local more = "…and " .. plural(rest, "earlier commit")
		if offer.web then
			more = "[" .. more .. "](" .. offer.web .. "/compare/" .. offer.head .. "..." .. offer.commits[1].sha .. ")"
		end
		table.insert(parts, more)
	end
	return table.concat(parts, "\n\n---\n\n")
end

local function card_view(offer: Offer): Node
	local ui = tern.ui
	local newest = offer.commits[1]
	local name = update_name(offer.available, offer.current, newest.short)
	local have = offer.current or offer.head
	local sub = "You have " .. have
	if offer.available == nil or offer.available == offer.current then
		sub ..= " (" .. offer.head .. ")"
	end
	sub ..= " · " .. plural(offer.behind, "new commit")
	return ui.el("div", { role = CARD_ROLE }, {
		ui.el("div", { class = "ouu-head" }, {
			ui.el("span", { class = "ouu-icon" }, { ui.node("icon", { name = "download" }) }),
			ui.el("div", { class = "ouu-say" }, {
				ui.el("span", { class = "ouu-title", text = "omp Usage " .. name .. " is available" }),
				ui.el("span", { class = "ouu-sub", text = sub }),
			}),
		}),
		ui.el("span", { class = "ouu-label", text = "What's new" }),
		ui.md(commits_md(offer)),
	})
end

local function card_dock(): Node
	local ui = tern.ui
	return ui.el("div", { role = CARD_DOCK_ROLE }, {
		ui.button("Download Update", { icon = "download", variant = "primary", actions = { click = "download" } }),
		ui.button("Skip This Version", { actions = { click = "skip" } }),
		ui.button("Not Now", { variant = "quiet", actions = { click = "later" } }),
	})
end

local function find_card(cx: WindowCx): number?
	local ok, list = pcall(function(): any
		return cx.canvas:list()
	end)
	if ok and type(list) == "table" then
		for _, info in list do
			if info.owner == tern.plugin.id and info.title == CARD_TITLE then
				return info.pane
			end
		end
	end
	return nil
end

local function close_card(cx: WindowCx, pane: number?)
	local card = pane or find_card(cx)
	if card then
		pcall(function()
			cx.layout:close(card :: number)
		end)
	end
end

local function show_card(cx: WindowCx, offer: Offer)
	pcall(tern.css, CARD_SHEET, CARD_CSS)
	local view, dock = card_view(offer), card_dock()
	local card = find_card(cx)
	if card and pcall(function()
		cx.canvas:set(card :: number, { view = view, dock = dock })
		cx.layout:focus(card :: number)
	end) then
		return
	end
	local ok, opened, err = pcall(function()
		-- a glimpse: over the whole tab in no split, so nothing it covers gets squeezed, until a click outside it
		return cx.canvas:open({ title = CARD_TITLE, about = CARD_ABOUT, view = view, dock = dock, how = "glimpse" })
	end)
	if not ok or opened == nil then
		cx:toast("error", "omp Usage couldn't show the update", tostring(if ok then err else opened))
	end
end

-- Download Update: the pending update, whichever window found it.
function M.download(cx: WindowCx)
	local pending = M.pending()
	if pending == nil then
		M.check(cx, true) -- nothing pending any more (taken or skipped elsewhere): look again
		return
	end
	apply(cx, pending)
end

local function skip(cx: WindowCx)
	local pending = M.pending()
	if pending == nil then
		return
	end
	kv_set(KV_KEPT, pending.sha)
	set_pending(nil)
	cx:toast("info", "Skipped omp Usage " .. update_name(pending.version, M.version(), pending.short), "Update any time: omp Usage: Check for updates…")
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean
	if ev.title ~= CARD_TITLE then
		return false
	end
	if ev.act == "download" then
		close_card(cx, ev.pane)
		M.download(cx)
	elseif ev.act == "skip" then
		close_card(cx, ev.pane)
		skip(cx)
	elseif ev.act == "later" then
		close_card(cx, ev.pane)
	else
		return false
	end
	return true
end)

-- A reload drops the card's sheet; put it back for a card Tern kept.
tern.timer(500, function(cx: WindowCx?)
	if cx and find_card(cx) then
		pcall(tern.css, CARD_SHEET, CARD_CSS)
	end
end)

-- Fetches the upstream and records what's new. `manual` (the user asked: the status button, the command, the
-- panel) opens the update card or says it's up to date, and reports failures; an automatic check stays quiet but
-- for a toast the first time it finds an update the user hasn't skipped.
function M.check(cx: WindowCx, manual: boolean)
	if busy then
		if manual then
			cx:toast("info", "omp Usage is already checking or updating")
		end
		return
	end
	busy = true
	local function stop(at: WindowCx, title: string, detail: string)
		busy = false
		if manual then
			at:toast("error", title, detail)
		else
			tern.log.warn("omp-usage update check: " .. title .. ": " .. detail)
		end
	end
	git(cx, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, 10000, function(up: Git, cx1: WindowCx)
		if not up.ok then
			stop(cx1, "omp Usage can't check for updates", reason(up.err))
			return
		end
		-- with no repository named, git fetches the current branch's remote
		git(cx1, { "fetch", "--quiet" }, 60000, function(fetch: Git, cx2: WindowCx)
			if not fetch.ok then
				local hours = M.interval().hours
				if not manual and hours then
					-- often just offline (Tern started before the network): the next hourly tick, in any window,
					-- tries again instead of waiting out the whole interval
					kv_set(KV_CHECKED, os.time() - hours * 3600 + TICK_MS // 1000)
				end
				stop(cx2, "omp Usage couldn't fetch updates", reason(fetch.err))
				return
			end
			kv_set(KV_LAST, os.time())
			git(cx2, { "rev-parse", "--short", "HEAD" }, 10000, function(rev: Git, cx3: WindowCx)
				local head = trim(rev.out)
				git(cx3, { "rev-list", "--left-right", "--count", "HEAD...@{u}" }, 10000, function(count: Git, cx4: WindowCx)
					local ahead_text, behind_text = string.match(count.out, "^%s*(%d+)%s+(%d+)")
					local ahead, behind = tonumber(ahead_text or ""), tonumber(behind_text or "")
					if not rev.ok or not count.ok or ahead == nil or behind == nil then
						stop(cx4, "omp Usage can't check for updates", reason(if rev.ok then count.err else rev.err))
						return
					end
					if behind == 0 then
						busy = false
						set_pending(nil)
						if manual then
							local version = M.version()
							cx4:toast("success", "omp Usage is up to date", (if version then version .. " · " else "") .. head)
						end
						return
					end
					-- Local commits the upstream lacks: a fast-forward can't apply, so don't offer one. Merging or
					-- rebasing someone's own work is theirs to do.
					if (ahead :: number) > 0 then
						busy = false
						set_pending(nil)
						local title = "omp Usage has an update, but your clone has " .. plural(ahead :: number, "local commit")
						if manual then
							cx4:toast("info", title, "Merge it by hand: git pull, in the repo folder")
						else
							tern.log.info("omp-usage update check: " .. title)
						end
						return
					end
					local log_args = {
						"log",
						"-n",
						tostring(CARD_COMMITS),
						"--format=%H%x1f%h%x1f%cr%x1f%an%x1f%s%x1f%b%x1e",
						"HEAD..@{u}",
					}
					git(cx4, log_args, 10000, function(log: Git, cx5: WindowCx)
						local commits: { Commit } = {}
						for record in string.gmatch(log.out, "([^\30]*)\30") do
							local sha, short, when, author, subject, body =
								string.match(record, "^%s*(%x+)\31(%x+)\31([^\31]*)\31([^\31]*)\31([^\31]*)\31(.*)$")
							if sha and short and when and author and subject and body then
								table.insert(commits, {
									sha = sha,
									short = short,
									when = when,
									author = trim(author),
									subject = trim(subject),
									body = trim(body),
								})
							end
						end
						if not log.ok or #commits == 0 then
							stop(cx5, "omp Usage can't list the update's commits", reason(log.err))
							return
						end
						local newest = commits[1]
						git(cx5, { "show", newest.sha .. ":./plugin.toml" }, 10000, function(toml: Git, cx6: WindowCx)
							local available = if toml.ok then toml_version(toml.out) else nil
							git(cx6, { "ls-remote", "--get-url" }, 10000, function(url: Git, cx7: WindowCx)
								busy = false
								local offer: Offer = {
									head = head,
									behind = behind :: number,
									commits = commits,
									web = if url.ok then web_base(trim(url.out)) else nil,
									current = M.version(),
									available = available,
								}
								if not manual and kv_get(KV_KEPT) == newest.sha then
									set_pending(nil) -- the user skipped this one
									return
								end
								local before = M.pending()
								set_pending({ sha = newest.sha, short = newest.short, version = available })
								if manual then
									show_card(cx7, offer)
								elseif before == nil or before.sha ~= newest.sha then
									local name = update_name(available, offer.current, newest.short)
									cx7:toast(
										"info",
										"omp Usage " .. name .. " is available",
										"Update omp Usage in the status bar, or Check for Updates in its settings"
									)
								end
							end)
						end)
					end)
				end)
			end)
		end)
	end)
end

-- An automatic check when the last one, in any window, is as old as the interval (less a minute's slack for a
-- timer that fires early); looked at hourly. Windows started together tick together: each writes its claim, and
-- only the window whose claim stuck checks.
local function tick(cx: WindowCx?)
	tern.timer(TICK_MS, tick)
	local hours = M.interval().hours
	if cx == nil or hours == nil then
		return
	end
	local now = os.time()
	local last = kv_get(KV_CHECKED)
	-- a last check in the future means the clock went back: it doesn't count
	if type(last) == "number" and last <= now and now - last < (hours :: number) * 3600 - 60 then
		return
	end
	local ok, key = pcall(function()
		return cx:window_key()
	end)
	local claim = (if ok then tostring(key) else "") .. "@" .. tostring(tern.now())
	kv_set(KV_CHECKED, now)
	kv_set(KV_CLAIM, claim)
	tern.timer(CLAIM_SETTLE_MS, function(later: WindowCx?)
		if later and kv_get(KV_CLAIM) == claim then
			M.check(later, false)
		end
	end)
end

if tern.runtime.os ~= "ios" then -- no processes there, so no git
	tern.timer(FIRST_CHECK_MS, tick)
end

return M
