--!strict
-- Updates for this plugin's git clone (the README installs it as a clone that `tern plugin link` loads in place).
--
-- Every few hours, and from `omp Usage: Check for updates…`, it fetches the checked-out branch's upstream. When
-- the branch is behind, a picker lists the new commits under the choices: update (a fast-forward to the commit
-- the picker showed, after which Tern reloads the plugin) or keep this version (no automatic prompt again until
-- the upstream moves past that commit). Esc decides nothing: the next check asks again. Picking a commit opens
-- it on the web when the remote is a web host. An automatic prompt opens over whatever has focus, so its first
-- row decides nothing too: Enter typed for something else doesn't update.
--
-- What it remembers lives in `tern.kv`, which every window shares, so one window checks per interval (windows
-- that tick together claim the check, and the claim that lands last wins) and a version kept in one window is
-- kept in all of them.

local M = {}

local KV_AUTO = "omp-usage.update-auto" -- false: no automatic checks (absent: on)
local KV_CHECKED = "omp-usage.update-checked" -- os.time() of the last automatic check
local KV_KEPT = "omp-usage.update-kept" -- the upstream commit the user kept their version over
local KV_CLAIM = "omp-usage.update-claim" -- the window that claimed it

local FIRST_CHECK_MS = 20 * 1000 -- after a load, past Tern's own startup work
local CLAIM_SETTLE_MS = 2000 -- long enough for every window ticking with this one to write its claim
local TICK_MS = 60 * 60 * 1000
local CHECK_EVERY_S = 6 * 60 * 60
local SHOWN_COMMITS = 15
-- No credential prompts or windows: a remote that needs them fails the check instead.
local GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GCM_INTERACTIVE = "never" }

type Git = { ok: boolean, out: string, err: string }
type Commit = { sha: string, short: string, when: string, subject: string }
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

function M.auto(): boolean
	return kv_get(KV_AUTO) ~= false
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
	local web = offer.web
	for _, commit in offer.commits do
		table.insert(items, {
			label = commit.subject,
			detail = commit.short .. " · " .. commit.when,
			group = "What's new",
			icon = "sparkle",
			pick = "open",
			url = if web then web .. "/commit/" .. commit.sha else nil,
		})
	end
	local rest = offer.behind - #offer.commits
	if rest > 0 then
		table.insert(items, {
			label = plural(rest, "earlier commit"),
			detail = if web then "compare on the web" else nil,
			group = "What's new",
			icon = "list",
			pick = "open",
			url = if web then web .. "/compare/" .. offer.head .. "..." .. newest.sha else nil,
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
			kv_set(KV_KEPT, newest.sha)
			cx2:toast("info", "Keeping omp Usage at " .. offer.head, "Update any time: omp Usage: Check for updates…")
		elseif choice.url then
			cx2:open(choice.url)
		else
			prompt(cx2, offer, manual) -- nothing to open: back to the choice
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
					local log_args = { "log", "-n", tostring(SHOWN_COMMITS), "--format=%H%x1f%h%x1f%cr%x1f%s", "HEAD..@{u}" }
					git(cx4, log_args, 10000, function(log: Git, cx5: WindowCx)
						local commits: { Commit } = {}
						for line in string.gmatch(log.out, "[^\n]+") do
							local sha, short, when, subject = string.match(line, "^(%x+)\31(%x+)\31([^\31]*)\31(.*)$")
							if sha and short and when and subject then
								table.insert(commits, { sha = sha, short = short, when = when, subject = trim(subject) })
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

-- Turns automatic checks on or off.
function M.set_auto(cx: WindowCx, on: boolean)
	kv_set(KV_AUTO, if on then nil else false)
	if on then
		cx:toast("info", "omp Usage checks for updates every 6 hours")
	else
		cx:toast("info", "omp Usage won't check for updates on its own", "Check any time: omp Usage: Check for updates…")
	end
end

-- An automatic check when the last one, in any window, is CHECK_EVERY_S old; looked at hourly. Windows started
-- together tick together: each writes its claim, and only the window whose claim stuck checks.
local function tick(cx: WindowCx?)
	tern.timer(TICK_MS, tick)
	if cx == nil or not M.auto() then
		return
	end
	local now = os.time()
	local last = kv_get(KV_CHECKED)
	if type(last) == "number" and now - last < CHECK_EVERY_S then
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
