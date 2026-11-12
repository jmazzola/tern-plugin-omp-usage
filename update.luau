--!strict
-- Updates for this plugin's git clone (one that `tern plugin link` loads in place), the way Tern updates itself:
-- quietly, until you choose.
--
-- At the interval the user picks (every 6 hours unless changed, or never), an automatic check fetches the checked-out
-- branch's upstream. When the upstream has commits that change the plugin's folder or the omp extension (commits of
-- only the README or its pictures don't count), it remembers the update as pending, says so in a toast, and every
-- window shows an Update omp Usage button in its status line. That button, `omp Usage: Check for updates…` and the
-- settings panel's Check for Updates check again and open the update card: the version that's available and the
-- one you have (from `plugin.toml` on each side, else commit hashes), Download Update (a fast-forward to the
-- upstream's tip, after which Tern reloads the plugin), Skip This Version (no automatic toast or button again until
-- a newer commit changes the plugin) and Not Now, over every commit that changes it, in full.
--
-- A copy `tern plugin install` made (no `.git`, no extension) uses a mirror of the repo in its data directory as its
-- clone instead: updates write the plugin's files from it, and the omp extension goes to `~/.omp/agent/extensions`,
-- unless omp's config.yml already loads one.
--
-- What it remembers lives in `tern.kv`, which every window shares, so one window checks per interval (windows that
-- tick together claim the check, and the claim that lands last wins), and the pending update, a skipped version and
-- the interval are the same in all of them.

-- How often the automatic check runs: `hours` nil is never.
export type Interval = { id: string, label: string, hours: number? }
-- The update an automatic or manual check found, until it's downloaded or skipped: the upstream's tip (what
-- Download Update fast-forwards to), the version its `plugin.toml` says when it says one, and the newest commit that
-- changes the plugin (what Skip This Version skips: a later push of only the README doesn't bring it back).
export type Pending = { sha: string, short: string, version: string?, latest: string }

type Module = {
	INTERVALS: { Interval },
	interval: () -> Interval,
	set_interval: (cx: WindowCx, id: string) -> (),
	version: () -> string?,
	pending: () -> Pending?,
	last_checked: () -> number?,
	check: (cx: WindowCx, manual: boolean) -> (),
	download: (cx: WindowCx) -> (),
	applying: () -> string?,
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
local KV_APPLYING = "omp-usage.update-applying" -- `{ name, at }`: an update landing, for the settings panels

local FIRST_CHECK_MS = 20 * 1000 -- after a load, past Tern's own startup work
local CLAIM_SETTLE_MS = 2000 -- long enough for every window ticking with this one to write its claim
local TICK_MS = 60 * 60 * 1000 -- how often each window looks whether a check is due: the shortest interval
local BADGE_POLL_MS = 10 * 1000 -- how soon a window shows (or drops) the status button another window decided
local CARD_COMMITS = 100 -- commits the update card shows in full
local BODY_MAX = 4000 -- characters of one commit's message body the card shows
local RELOAD_FALLBACK_MS = 5000 -- after an update, how long Tern's folder watch gets to reload the plugin
local APPLY_WAIT_MS = 1500 -- before an update lands, for every window's once-a-second poll to see it coming
local APPLYING_STALE_S = 60 -- an announced update that never reloaded this window stops counting
local LOADED_AT = os.time() -- when this VM started: an update announced before it has already landed here
-- No credential prompts or windows: a remote that needs them fails the check instead.
local GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GCM_INTERACTIVE = "never" }
local UPDATE_ACTION = "plugin." .. tern.plugin.id .. ".update"
-- What an update covers: every file but the README, its pictures and the project's own notes. The omp extension
-- (`omp/`) is one of them.
local EXTENSION_DIR = "omp"
local EXTENSION_FILE = "omp/extensions/usage-remaining.js"
local PLUGIN_PATHS = { "--", ":/", ":(top,exclude)README.md", ":(top,exclude)docs", ":(top,exclude).omp" }
-- An installed copy's upstream, its mirror, and the ref there that follows the upstream's default branch, the only
-- one fetched. The upstream is the URL in the `upstream` file, where a fork names itself: Tern keeps no record of
-- where it installed a copy from, and plugin.toml takes no such field.
local REPOSITORY: string? = (function(): string?
	local ok, text = pcall(tern.fs.read, "upstream", 4096)
	return if ok then string.match(text, "^%s*(%S+)") else nil
end)()
local MIRROR = tern.plugin.data .. "/source"
local MIRROR_TIP = "refs/upstream"
-- Where an installed copy puts the omp extension: omp loads every module in its agent directory's `extensions/`.
local HOME = tern.getenv("USERPROFILE") or tern.getenv("HOME")
local EXTENSION_TARGET = if HOME and HOME ~= "" then HOME .. "/.omp/agent/extensions/usage-remaining.js" else nil
local EXTENSION_HEADER = "// Written by the omp Usage plugin for Tern, which replaces this file when it updates.\n"
	.. "// `tern plugin remove omp-usage` leaves it: delete it too to turn the usage line off.\n"
local KV_INSTALLED = "omp-usage.installed" -- `{ sha, version }`: the commit an installed copy last wrote
local SETUP_MS = 3000 -- after a load, before an installed copy sets up the omp extension

type Git = { ok: boolean, out: string, err: string }
type Commit = { sha: string, short: string, when: string, author: string, subject: string, body: string }
-- What a check found: the commits between HEAD and the upstream that change the plugin, newest first (`behind` of
-- them, `other` commits besides that don't), the upstream's tip, and both sides' versions.
type Offer = {
	head: string,
	tip: string,
	behind: number,
	other: number,
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

-- Runs git in `dir`; `done` gets a fresh cx when the window gave one, else `cx`.
local function git(cx: WindowCx, dir: string, args: { string }, timeout_ms: number, done: (Git, WindowCx) -> (), stdin: string?)
	local argv = { "git" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local opts = { cwd = dir, env = GIT_ENV, timeout_ms = timeout_ms, stdin = stdin }
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

-- Where the git side of an update lives. A linked clone: the plugin's own folder, `HEAD` what's loaded and the
-- branch's upstream what's available. An installed copy: the mirror, `head` the commit the copy is and the mirror's
-- MIRROR_TIP what's available.
type Source = { dir: string, head: string, tip: string, installed: boolean }
type Failure = { title: string, detail: string, offline: boolean }

-- A linked clone has its `.git` in the plugin folder; anything else is an installed copy.
local INSTALLED = not tern.fs.exists(tern.plugin.dir .. "/.git")

-- The plugin.toml versions in the mirror's history, newest first: each commit that set one and the version it set.
local function version_commits(text: string): { { sha: string, version: string } }
	local out = {}
	for record in string.gmatch(text, "\30([^\30]*)") do
		local sha = string.match(record, "^(%x+)")
		local version = string.match(record, '\n%+%s*version%s*=%s*"([^"\n]+)"')
		if sha and version then
			table.insert(out, { sha = sha, version = trim(version) })
		end
	end
	return out
end

-- The source of the plugin's updates, fetched first when `fetch` says so; an installed copy's mirror is cloned the
-- first time either way. `done` gets nil and why when there's none to be had (`offline`: a fetch or clone failed).
local function prepare(cx: WindowCx, fetch: boolean, done: (Source?, Failure?, WindowCx) -> ())
	local function fail(at: WindowCx, title: string, detail: string, offline: boolean?)
		done(nil, { title = title, detail = detail, offline = offline == true }, at)
	end
	if not INSTALLED then
		local src: Source = { dir = tern.plugin.dir, head = "HEAD", tip = "@{u}", installed = false }
		if not fetch then
			done(src, nil, cx)
			return
		end
		git(cx, src.dir, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }, 10000, function(up: Git, cx1: WindowCx)
			if not up.ok then
				fail(cx1, "omp Usage can't check for updates", reason(up.err))
				return
			end
			-- with no repository named, git fetches the current branch's remote
			git(cx1, src.dir, { "fetch", "--quiet" }, 60000, function(fetched: Git, cx2: WindowCx)
				if fetched.ok then
					done(src, nil, cx2)
				else
					fail(cx2, "omp Usage couldn't fetch updates", reason(fetched.err), true)
				end
			end)
		end)
		return
	end
	-- read now, not `M.version()`'s as of load: between an update's writes and the reload they bring, this VM still
	-- runs, and with the old version it would take the copy for the old commit and offer the update again
	local read, text = pcall(tern.fs.read, "plugin.toml", 64 * 1024)
	local version = if read then toml_version(text) else nil
	if version == nil then
		fail(cx, "omp Usage can't check for updates", "Its plugin.toml has no version")
		return
	end
	if REPOSITORY == nil then
		fail(cx, "omp Usage can't check for updates", "Its upstream file, which names its repository, is missing")
		return
	end
	local repository = REPOSITORY :: string
	local function source(head: string): Source
		return { dir = MIRROR, head = head, tip = MIRROR_TIP, installed = true }
	end
	-- Brings the mirror up to date (`then_` gets whether it fetched), cloning it the first time.
	local function sync(at: WindowCx, always: boolean, then_: (WindowCx, boolean) -> ())
		local function fetch_tip(at1: WindowCx)
			git(at1, MIRROR, { "fetch", "--quiet", "origin", "+HEAD:" .. MIRROR_TIP }, 60000, function(fetched: Git, at2: WindowCx)
				if fetched.ok then
					then_(at2, true)
				else
					fail(at2, "omp Usage couldn't fetch updates", reason(fetched.err), true)
				end
			end)
		end
		if tern.fs.exists(MIRROR .. "/" .. MIRROR_TIP) then
			if always then
				fetch_tip(at)
			else
				then_(at, false)
			end
			return
		end
		pcall(tern.fs.remove, MIRROR) -- a clone cut short
		pcall(tern.fs.mkdir, tern.plugin.data)
		local clone_args = { "clone", "--bare", "--single-branch", "--quiet", repository, MIRROR }
		git(at, tern.plugin.data, clone_args, 120000, function(clone: Git, at1: WindowCx)
			if clone.ok then
				fetch_tip(at1)
			else
				pcall(tern.fs.remove, MIRROR)
				fail(at1, "omp Usage couldn't download its repository", reason(clone.err), true)
			end
		end)
	end
	-- The commit the copy is: the one the last update wrote, while the copy is still that version; else the newest
	-- commit at its version, which a fetch may have to bring first (a copy installed after the mirror last fetched).
	local function resolve(at: WindowCx, fetched: boolean)
		local known = kv_get(KV_INSTALLED)
		if type(known) == "table" and known.version == version and type(known.sha) == "string" then
			done(source(known.sha), nil, at)
			return
		end
		local args = { "log", "-p", "-U0", "--no-color", "--format=%x1e%H", MIRROR_TIP, "--", "plugin.toml" }
		git(at, MIRROR, args, 20000, function(log: Git, at1: WindowCx)
			local commits = version_commits(log.out)
			local found: number? = nil
			for i, commit in commits do
				if commit.version == version then
					found = i
					break
				end
			end
			if not log.ok or found == nil then
				if fetched then
					local detail = if log.ok then "No commit of " .. repository .. " is version " .. version else reason(log.err)
					fail(at1, "omp Usage can't tell which version it is", detail)
				else
					sync(at1, true, resolve)
				end
				return
			end
			-- the newest commit at that version: the one before the next version's, else the tip
			local at_version = found :: number
			local rev = if at_version > 1 then commits[at_version - 1].sha .. "^" else MIRROR_TIP
			git(at1, MIRROR, { "rev-parse", rev }, 10000, function(parsed: Git, at2: WindowCx)
				local head = trim(parsed.out)
				if not parsed.ok or not string.match(head, "^%x+$") then
					fail(at2, "omp Usage can't tell which version it is", reason(parsed.err))
					return
				end
				kv_set(KV_INSTALLED, { sha = head, version = version })
				done(source(head), nil, at2)
			end)
		end)
	end
	sync(cx, fetch, resolve)
end

-- The contents of `<rev>:<path>` for each path, from one `git cat-file --batch`; a path `rev` lacks is left out.
local function blobs(cx: WindowCx, src: Source, rev: string, paths: { string }, done: ({ [string]: string }?, string?, WindowCx) -> ())
	local requests: { string } = {}
	for _, path in paths do
		table.insert(requests, rev .. ":" .. path)
	end
	git(cx, src.dir, { "cat-file", "--batch" }, 20000, function(batch: Git, cx1: WindowCx)
		if not batch.ok then
			done(nil, reason(batch.err), cx1)
			return
		end
		-- each answer: `<oid> blob <size>\n<content>\n`, or `<request> missing\n`
		local out: { [string]: string } = {}
		local pos = 1
		for _, path in paths do
			local eol = string.find(batch.out, "\n", pos, true)
			if eol == nil then
				break
			end
			local size = tonumber(string.match(string.sub(batch.out, pos, eol - 1), "^%x+ blob (%d+)$") or "")
			if size then
				out[path] = string.sub(batch.out, eol + 1, eol + size)
				pos = eol + size + 2
			else
				pos = eol + 1
			end
		end
		done(out, nil, cx1)
	end, table.concat(requests, "\n") .. "\n")
end

-- Writes the omp extension where omp loads it: "new" when there was none, "changed" when it was another, nil when
-- it was this one already, omp's config.yml loads one, or there's no home directory to put it in.
local function write_extension(text: string): string?
	if EXTENSION_TARGET == nil then
		return nil
	end
	local target = EXTENSION_TARGET :: string
	-- already installed another way: omp's config.yml loads one (a clone's), and a second copy would run it twice
	local config_ok, config = pcall(tern.fs.read, (HOME :: string) .. "/.omp/agent/config.yml", 1024 * 1024)
	if config_ok and string.find(config, "usage-remaining.js", 1, true) then
		return nil
	end
	local want = EXTENSION_HEADER .. text
	local found, have = pcall(tern.fs.read, target, 4 * 1024 * 1024)
	if found and have == want then
		return nil
	end
	tern.fs.mkdir((string.match(target, "^(.*)/[^/]*$")) :: string)
	tern.fs.write(target, want)
	return if found then "changed" else "new"
end

-- An installed copy's omp extension, from the copy itself; says so when it wrote one.
local function setup_extension(cx: WindowCx)
	local ok, wrote = pcall(function()
		return write_extension(tern.fs.read(EXTENSION_FILE, 4 * 1024 * 1024))
	end)
	if not ok then
		cx:toast("error", "omp Usage couldn't set up its omp extension", tostring(wrote))
	elseif wrote == "new" then
		cx:toast("success", "omp Usage is installed", "Restart omp sessions to see the usage line")
	elseif wrote == "changed" then
		cx:toast("info", "omp Usage updated its omp extension", "Restart omp sessions to use it")
	end
end

-- An installed copy's update: the repo's files as of `sha` written over the copy (those `sha` dropped deleted),
-- and the omp extension with them. All the writes happen in one go, so a reload Tern starts on the first change
-- finds them all. `done` gets why when nothing was written.
local function land(cx: WindowCx, src: Source, sha: string, done: (string?, WindowCx) -> ())
	local function names(text: string): { string }
		local out: { string } = {}
		for _, name in string.split(text, "\0") do
			if name ~= "" then
				table.insert(out, name)
			end
		end
		return out
	end
	git(cx, src.dir, { "ls-tree", "-r", "-z", "--name-only", sha }, 10000, function(tree: Git, cx1: WindowCx)
		local files = names(tree.out)
		if not tree.ok or #files == 0 then
			done(if tree.ok then "The update has no plugin files" else reason(tree.err), cx1)
			return
		end
		local diff_args = { "diff", "--name-only", "-z", "--diff-filter=D", src.head, sha }
		git(cx1, src.dir, diff_args, 10000, function(diff: Git, cx2: WindowCx)
			local gone: { string } = if diff.ok then names(diff.out) else {}
			blobs(cx2, src, sha, files, function(found: { [string]: string }?, err: string?, cx3: WindowCx)
				if found == nil then
					done(err or "git didn't give the update's files", cx3)
					return
				end
				for _, file in files do
					if found[file] == nil then
						done("git didn't give " .. file, cx3)
						return
					end
				end
				local dir = tern.plugin.dir
				local wrote, failure = pcall(function()
					for _, file in gone do
						pcall(tern.fs.remove, dir .. "/" .. file)
					end
					for _, file in files do
						local parent = string.match(file, "^(.*)/[^/]*$")
						if parent then
							tern.fs.mkdir(dir .. "/" .. parent)
						end
						tern.fs.write(dir .. "/" .. file, found[file])
					end
				end)
				if not wrote then
					done(tostring(failure), cx3)
					return
				end
				kv_set(KV_INSTALLED, { sha = sha, version = toml_version(found["plugin.toml"] or "") })
				local extension = found[EXTENSION_FILE]
				if extension then
					pcall(write_extension, extension)
				end
				done(nil, cx3)
			end)
		end)
	end)
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
			latest = if type(value.latest) == "string" then value.latest else value.sha,
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

-- An update about to land, for every window's settings panel (window.luau): its name, from when it's announced
-- until this window's plugin reloads (or the update fails). The plugin's style sheets go away while Tern reloads it,
-- so a panel left as it is would flash unstyled buttons; told in time, each window swaps its panel for an
-- Updating… view drawn in Tern's own styles. A VM started after the announcement is the reloaded one: it ignores it.
function M.applying(): string?
	local value = kv_get(KV_APPLYING)
	if type(value) == "table" and type(value.name) == "string" and type(value.at) == "number" then
		local age = os.time() - value.at
		if value.at >= LOADED_AT and age >= 0 and age < APPLYING_STALE_S then
			return value.name
		end
	end
	return nil
end

local function apply(cx: WindowCx, pending: Pending)
	if busy then
		cx:toast("info", "omp Usage is already checking or updating")
		return
	end
	busy = true
	local name = update_name(pending.version, M.version(), pending.short)
	kv_set(KV_APPLYING, { name = name, at = os.time() })
	-- Gives every window's once-a-second poll time to swap its panel out before the files change.
	tern.timer(APPLY_WAIT_MS, function(later: WindowCx?)
		local function failed(at: WindowCx, detail: string)
			busy = false
			kv_set(KV_APPLYING, nil) -- nothing landed: the panels come back as they were
			at:toast("error", "omp Usage didn't update", detail)
		end
		local function landed(at: WindowCx, extension: boolean)
			busy = false
			-- KV_APPLYING stays: the reloaded VMs ignore it, and until then the panels wait
			kv_set(KV_KEPT, nil)
			set_pending(nil)
			local sub = if extension then "The omp extension changed: restart omp sessions" else nil
			at:toast("success", "omp Usage updated to " .. name, sub)
			-- Tern watches the plugin's folder and reloads this window's plugins when the update changes it. Only
			-- if that didn't happen (this VM, which a reload replaces, is still here) ask for Reload plugins, which
			-- also empties every plugin canvas left open (the settings panel) until it's opened again.
			tern.timer(RELOAD_FALLBACK_MS, function(last: WindowCx?)
				if last then
					pcall(function()
						last:command("reload_plugins")
					end)
				end
			end)
		end
		prepare(later or cx, false, function(src: Source?, failure: Failure?, cx1: WindowCx)
			if src == nil then
				failed(cx1, if failure then failure.detail else "No update source")
				return
			end
			-- Whether the omp extension changed: omp loads it at session start, so open sessions need a restart.
			git(cx1, src.dir, { "diff", "--name-only", src.head, pending.sha }, 10000, function(diff: Git, cx2: WindowCx)
				local extension = diff.ok and string.find("\n" .. diff.out, "\n" .. EXTENSION_DIR .. "/") ~= nil
				if src.installed then
					land(cx2, src, pending.sha, function(err: string?, cx3: WindowCx)
						if err then
							failed(cx3, err)
						else
							landed(cx3, extension)
						end
					end)
					return
				end
				git(cx2, src.dir, { "merge", "--ff-only", "--quiet", pending.sha }, 30000, function(merge: Git, cx3: WindowCx)
					if merge.ok then
						landed(cx3, extension)
					else
						failed(cx3, reason(merge.err))
					end
				end)
			end)
		end)
	end)
end

-- The update card: a canvas beside the focused pane, headed by the version that's available and the one you have,
-- with Download Update, Skip This Version and Not Now in its bottom bar and every new commit in full beneath.
-- Its buttons act on the pending update in `tern.kv`, so a card left open across a reload still works.
local CARD_TITLE = "omp Usage update"
local CARD_ABOUT = "An update to the omp Usage plugin: the version that's available, the one installed, and every new "
	.. "commit. Download Update brings the plugin to that commit and reloads Tern's plugins; Skip This Version "
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
	local compare = if offer.web then offer.web .. "/compare/" .. offer.head .. "..." .. offer.tip else nil
	if rest > 0 then
		local more = "…and " .. plural(rest, "earlier commit")
		table.insert(parts, if compare then "[" .. more .. "](" .. compare .. ")" else more)
	end
	if offer.other > 0 then
		local besides = "Plus "
			.. (if offer.other == 1 then "1 commit that doesn't" else tostring(offer.other) .. " commits that don't")
			.. " change the plugin, such as README updates"
		table.insert(parts, if compare then "[" .. besides .. "](" .. compare .. ")" else besides)
	end
	return table.concat(parts, "\n\n---\n\n")
end

local function card_view(offer: Offer): Node
	local ui = tern.ui
	local name = update_name(offer.available, offer.current, string.sub(offer.tip, 1, 7))
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
	kv_set(KV_KEPT, pending.latest)
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
	prepare(cx, true, function(src: Source?, failure: Failure?, cx1: WindowCx)
		if src == nil then
			local hours = M.interval().hours
			if failure and failure.offline and not manual and hours then
				-- often just offline (Tern started before the network): the next hourly tick, in any window,
				-- tries again instead of waiting out the whole interval
				kv_set(KV_CHECKED, os.time() - hours * 3600 + TICK_MS // 1000)
			end
			stop(cx1, if failure then failure.title else "omp Usage can't check for updates", if failure then failure.detail else "")
			return
		end
		kv_set(KV_LAST, os.time())
		git(cx1, src.dir, { "rev-parse", "--short", src.head }, 10000, function(rev: Git, cx3: WindowCx)
			local head = trim(rev.out)
			git(cx3, src.dir, { "rev-list", "--left-right", "--count", src.head .. "..." .. src.tip }, 10000, function(count: Git, cx4: WindowCx)
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
				-- Only commits that change the plugin or the omp extension (PLUGIN_PATHS) make an update: a push of
				-- the README alone offers nothing. It comes along with the next real update, which goes to the
				-- upstream's tip.
				local paths = PLUGIN_PATHS
				local count_args = { "rev-list", "--count", src.head .. ".." .. src.tip }
				for _, path in paths do
					table.insert(count_args, path)
				end
				git(cx4, src.dir, count_args, 10000, function(relevant_count: Git, cx5: WindowCx)
					local relevant = tonumber(trim(relevant_count.out))
					if not relevant_count.ok or relevant == nil then
						stop(cx5, "omp Usage can't check for updates", reason(relevant_count.err))
						return
					end
					if relevant == 0 then
						busy = false
						set_pending(nil)
						if manual then
							local version = M.version()
							cx5:toast(
								"success",
								"omp Usage is up to date",
								(if version then version .. " · " else "") .. "newer commits don't change the plugin"
							)
						end
						return
					end
					local log_args = {
						"log",
						"-n",
						tostring(CARD_COMMITS),
						"--format=%H%x1f%h%x1f%cr%x1f%an%x1f%s%x1f%b%x1e",
						src.head .. ".." .. src.tip,
					}
					for _, path in paths do
						table.insert(log_args, path)
					end
					git(cx5, src.dir, log_args, 10000, function(log: Git, cx6: WindowCx)
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
							stop(cx6, "omp Usage can't list the update's commits", reason(log.err))
							return
						end
						local latest = commits[1].sha
						git(cx6, src.dir, { "rev-parse", src.tip }, 10000, function(up_rev: Git, cx7: WindowCx)
							local tip = trim(up_rev.out)
							if not up_rev.ok or not string.match(tip, "^%x+$") then
								stop(cx7, "omp Usage can't check for updates", reason(up_rev.err))
								return
							end
							local tip_short = string.sub(tip, 1, 7)
							git(cx7, src.dir, { "show", tip .. ":plugin.toml" }, 10000, function(toml: Git, cx8: WindowCx)
								local available = if toml.ok then toml_version(toml.out) else nil
								git(cx8, src.dir, { "ls-remote", "--get-url" }, 10000, function(url: Git, cx9: WindowCx)
									busy = false
									local offer: Offer = {
										head = head,
										tip = tip,
										behind = relevant :: number,
										other = (behind :: number) - (relevant :: number),
										commits = commits,
										web = if url.ok then web_base(trim(url.out)) else nil,
										current = M.version(),
										available = available,
									}
									if not manual and kv_get(KV_KEPT) == latest then
										set_pending(nil) -- the user skipped this one
										return
									end
									local before = M.pending()
									set_pending({ sha = tip, short = tip_short, version = available, latest = latest })
									if manual then
										show_card(cx9, offer)
									elseif before == nil or before.latest ~= latest then
										local name = update_name(available, offer.current, tip_short)
										cx9:toast(
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
-- An installed copy, once it loads, puts its omp extension where omp loads it.
if INSTALLED then
	tern.timer(SETUP_MS, function(cx: WindowCx?)
		if cx then
			setup_extension(cx)
		end
	end)
end

return M
