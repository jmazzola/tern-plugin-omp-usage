--!strict
-- Updates for this plugin's git clone (the README installs it as a clone that `tern plugin link` loads in place).
--
-- At the interval the user picks (every 6 hours unless changed, or never), and from `omp Usage: Check for updates…`
-- or the settings panel's Check for updates, it fetches the checked-out branch's upstream. When
-- the branch is behind, a picker lists the new commits under the choices: update (a fast-forward to the commit
-- the picker showed, after which Tern reloads the plugin) or keep this version (no automatic prompt again until
-- the upstream moves past that commit). Esc decides nothing: the next check asks again. Picking a commit, or
-- Read all changes…, opens the what's-new pane with every commit in full. An automatic prompt opens over
-- whatever has focus, so its first row decides nothing too: Enter typed for something else doesn't update.
--
-- What it remembers lives in `tern.kv`, which every window shares, so one window checks per interval (windows
-- that tick together claim the check, and the claim that lands last wins) and a version kept in one window is
-- kept in all of them.

-- How often the automatic check runs: `hours` nil is never.
export type Interval = { id: string, label: string, hours: number? }

type Module = {
	INTERVALS: { Interval },
	interval: () -> Interval,
	set_interval: (cx: WindowCx, id: string) -> (),
	check: (cx: WindowCx, manual: boolean) -> (),
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
local KV_CHECKED = "omp-usage.update-checked" -- os.time() of the last automatic check
local KV_KEPT = "omp-usage.update-kept" -- the upstream commit the user kept their version over
local KV_CLAIM = "omp-usage.update-claim" -- the window that claimed it

local FIRST_CHECK_MS = 20 * 1000 -- after a load, past Tern's own startup work
local CLAIM_SETTLE_MS = 2000 -- long enough for every window ticking with this one to write its claim
local TICK_MS = 60 * 60 * 1000 -- how often each window looks whether a check is due: the shortest interval
local SHOWN_COMMITS = 15 -- rows in the picker
local PANE_COMMITS = 100 -- commits the what's-new pane shows in full
local BODY_MAX = 4000 -- characters of one commit's message body the pane shows
-- No credential prompts or windows: a remote that needs them fails the check instead.
local GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GCM_INTERACTIVE = "never" }

type Git = { ok: boolean, out: string, err: string }
type Commit = { sha: string, short: string, when: string, author: string, subject: string, body: string }
type Offer = { head: string, behind: number, commits: { Commit }, web: string? }

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

local function plural(n: number, word: string): string
	return tostring(n) .. " " .. word .. (if n == 1 then "" else "s")
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

local busy = false -- a check, or the prompt it opened, is under way in this window

local function apply(cx: WindowCx, offer: Offer)
	local target = offer.commits[1]
	-- Whether the omp extension changed: omp loads it at session start, so open sessions need a restart.
	git(cx, { "diff", "--name-only", "HEAD", target.sha }, 10000, function(diff: Git, cx2: WindowCx)
		local extension = diff.ok and string.find("\n" .. diff.out, "\nomp/") ~= nil
		git(cx2, { "merge", "--ff-only", "--quiet", target.sha }, 30000, function(merge: Git, cx3: WindowCx)
			if not merge.ok then
				cx3:toast("error", "omp Usage didn't update", reason(merge.err))
				return
			end
			kv_set(KV_KEPT, nil)
			local sub = if extension then "The omp extension changed: restart omp sessions" else nil
			cx3:toast("success", "omp Usage updated to " .. target.short, sub)
			pcall(function()
				cx3:command("reload_plugins") -- Tern's watch of the clone reloads it too
			end)
		end)
	end)
end

local function keep(cx: WindowCx, offer: Offer)
	kv_set(KV_KEPT, offer.commits[1].sha)
	cx:toast("info", "Keeping omp Usage at " .. offer.head, "Update any time: omp Usage: Check for updates…")
end

-- The what's-new pane: a canvas beside the focused pane with every commit in full (the picker's rows are one
-- line each, so long subjects get cut and bodies don't show), and Update now / Keep this version / Close in its
-- bottom bar. It opens from the picker; its clicks arrive as `canvas_action` events. Tern keeps canvases across
-- reloads but the offer it shows lives in this VM, so a click on a pane that outlived it checks again.
local PANE_TITLE = "omp Usage: what's new"
local PANE_ABOUT = "The commits an omp Usage update would bring, in full. Update now fast-forwards the plugin's git "
	.. "clone to the newest of them and reloads Tern's plugins; Keep this version skips this update; Close closes "
	.. "this panel. Nothing changes until one of them is clicked."
local pane_offer: Offer? = nil

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

local function pane_md(offer: Offer): string
	local newest = offer.commits[1]
	local parts = {
		string.format(
			"**%s** · your clone is at `%s`, the newest is `%s`",
			plural(offer.behind, "new commit"),
			offer.head,
			newest.short
		),
	}
	for _, commit in offer.commits do
		local meta = "`" .. commit.short .. "` · " .. md_escape(commit.when) .. " · " .. md_escape(commit.author)
		if offer.web then
			meta ..= " · [on the web](" .. offer.web .. "/commit/" .. commit.sha .. ")"
		end
		local body = unwrap(commit.body)
		if #body > BODY_MAX then
			body = string.sub(body, 1, BODY_MAX) .. "…"
		end
		table.insert(parts, "---\n\n### " .. md_escape(commit.subject) .. "\n\n" .. meta .. (if body ~= "" then "\n\n" .. body else ""))
	end
	local rest = offer.behind - #offer.commits
	if rest > 0 then
		local more = "…and " .. plural(rest, "earlier commit")
		if offer.web then
			more = "[" .. more .. "](" .. offer.web .. "/compare/" .. offer.head .. "..." .. newest.sha .. ")"
		end
		table.insert(parts, "---\n\n" .. more)
	end
	return table.concat(parts, "\n\n")
end

local function find_pane(cx: WindowCx): number?
	local ok, list = pcall(function(): any
		return cx.canvas:list()
	end)
	if ok and type(list) == "table" then
		for _, info in list do
			if info.owner == tern.plugin.id and info.title == PANE_TITLE then
				return info.pane
			end
		end
	end
	return nil
end

local function close_pane(cx: WindowCx, pane: number)
	pane_offer = nil
	pcall(function()
		cx.layout:close(pane)
	end)
end

local function show_pane(cx: WindowCx, offer: Offer)
	pane_offer = offer
	local md = pane_md(offer)
	local dock = tern.ui.row({
		tern.ui.button("Update now", { icon = "download", variant = "primary", actions = { click = "update" } }),
		tern.ui.button("Keep this version", { icon = "pin", actions = { click = "keep" } }),
		tern.ui.button("Close", { variant = "quiet", actions = { click = "close" } }),
	})
	local pane = find_pane(cx)
	if pane and pcall(function()
		cx.canvas:set(pane :: number, { md = md, dock = dock })
		cx.layout:focus(pane :: number)
	end) then
		return
	end
	local ok, opened, err = pcall(function()
		return cx.canvas:open({ title = PANE_TITLE, about = PANE_ABOUT, md = md, dock = dock, how = "beside" })
	end)
	if not ok or opened == nil then
		pane_offer = nil
		cx:toast("error", "omp Usage couldn't show what's new", tostring(if ok then err else opened))
	end
end

tern.on("canvas_action", function(ev: CanvasAction, cx: WindowCx): boolean
	if ev.title ~= PANE_TITLE then
		return false
	end
	local offer = pane_offer
	if ev.act == "close" then
		close_pane(cx, ev.pane)
	elseif ev.act ~= "update" and ev.act ~= "keep" then
		return false
	elseif offer == nil then -- the plugin reloaded since the pane opened: what it shows may be stale
		close_pane(cx, ev.pane)
		M.check(cx, true)
	elseif ev.act == "update" then
		close_pane(cx, ev.pane)
		apply(cx, offer)
	else
		close_pane(cx, ev.pane)
		keep(cx, offer)
	end
	return true
end)

-- Asks. `busy` stays set while the picker is open, so a later check in this window (the next tick, the
-- command) can't stack a second picker behind it. `manual` (the user asked) puts Update now first.
local function prompt(cx: WindowCx, offer: Offer, manual: boolean)
	busy = true
	local newest = offer.commits[1]
	local items: { PickItem } = {}
	if not manual then
		table.insert(items, {
			label = "Decide later",
			detail = "ask again at the next check, like Esc",
			group = "omp Usage update",
			icon = "moon",
			pick = "later",
		})
	end
	table.insert(items, {
		label = "Update now",
		detail = plural(offer.behind, "new commit") .. " · " .. offer.head .. " → " .. newest.short,
		group = "omp Usage update",
		icon = "download",
		pick = "update",
	})
	table.insert(items, {
		label = "Keep this version",
		detail = "stay on " .. offer.head .. " until a newer update",
		group = "omp Usage update",
		icon = "pin",
		pick = "keep",
	})
	table.insert(items, {
		label = "Read all changes…",
		detail = "every commit in full, in a pane beside this one",
		group = "What's new",
		icon = "list",
		pick = "read",
	})
	for i, commit in offer.commits do
		if i > SHOWN_COMMITS then
			break
		end
		table.insert(items, {
			label = commit.subject,
			detail = commit.short .. " · " .. commit.when,
			group = "What's new",
			icon = "sparkle",
			pick = "read",
		})
	end
	local rest = offer.behind - math.min(#offer.commits, SHOWN_COMMITS)
	if rest > 0 then
		table.insert(items, {
			label = plural(rest, "earlier commit"),
			detail = "in the pane",
			group = "What's new",
			icon = "list",
			pick = "read",
		})
	end
	local function answer(item: PickItem?, _err: string?, next_cx: WindowCx?)
		busy = false
		if item == nil or (item :: any).pick == "later" then
			return
		end
		local choice = item :: any
		local cx2 = next_cx or cx
		if choice.pick == "update" then
			apply(cx2, offer)
		elseif choice.pick == "keep" then
			keep(cx2, offer)
		elseif choice.pick == "read" then
			show_pane(cx2, offer)
		end
	end
	local opened, err = pcall(function()
		cx:pick({ items = items, placeholder = "Update omp Usage? Esc to decide later", icon = "download" }):next(answer)
	end)
	if not opened then -- no picker (no pane to show it over, say): the next check asks again
		busy = false
		tern.log.warn("omp-usage update prompt didn't open: " .. tostring(err))
		if manual then
			pcall(function()
				cx:toast("error", "omp Usage couldn't show the update", tostring(err))
			end)
		end
	end
end

-- Fetches the upstream and offers what's new. `manual` reports every outcome; an automatic check stays quiet
-- unless there's an update the user hasn't kept their version over.
function M.check(cx: WindowCx, manual: boolean)
	if busy then
		if manual then
			cx:toast("info", "omp Usage's update check is already under way")
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
						if manual then
							cx4:toast("success", "omp Usage is up to date", head)
						end
						return
					end
					-- Local commits the upstream lacks: a fast-forward can't apply, so don't offer one. Merging or
					-- rebasing someone's own work is theirs to do.
					if (ahead :: number) > 0 then
						busy = false
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
						tostring(PANE_COMMITS),
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
						if not manual and kv_get(KV_KEPT) == commits[1].sha then
							busy = false -- the user kept their version over this one
							return
						end
						git(cx5, { "ls-remote", "--get-url" }, 10000, function(url: Git, cx6: WindowCx)
							prompt(cx6, {
								head = head,
								behind = behind :: number,
								commits = commits,
								web = if url.ok then web_base(trim(url.out)) else nil,
							}, manual)
						end)
					end)
				end)
			end)
		end)
	end)
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
