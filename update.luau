--!strict
-- Updates for this plugin, the way Tern updates itself: quietly, until you choose. A git clone (one that `tern plugin
-- link` loads in place) updates from its checked-out branch's upstream; a copy `tern plugin install` made (no `.git`)
-- from a mirror of the repo its `upstream` file names, kept in its data directory.
--
-- At the interval the user picks (every 6 hours unless changed, or never), an automatic check fetches the upstream.
-- When it has commits that change the plugin (PLUGIN_PATHS: every file but the README, its pictures, the tests and
-- the project's notes and tooling), it remembers the update as pending, says so in a toast, and every window shows an
-- Update omp Usage button in its widget bar. That button, `omp Usage: Check for updates…` and the settings panel's
-- Check for Updates check again and open the update card: the version that's available and the one you have (from
-- `plugin.toml` on each side, else commit hashes), Download Update (a clone fast-forwards to the upstream's tip; an
-- installed copy has the tip's plugin files landed over it, see `land`; either way Tern then reloads the plugin),
-- Skip This Version (no automatic toast or button again until a newer commit changes the plugin) and Not Now, over
-- every commit that changes it, in full. How the last check, skip or update went is kept for the settings panel
-- (`last_outcome`).
--
-- An installed copy also has omp load its extension, through omp's plugin manager (extension.luau).
--
-- What it remembers lives in `tern.kv`, which every window shares, so one window checks per interval (windows that
-- tick together claim the check, and the claim that lands last wins), and the pending update, a skipped version and
-- the interval are the same in all of them. Setting up the omp extension and finishing an interrupted update are
-- claimed the same way.

-- How often the automatic check runs: `hours` nil is never.
export type Interval = { id: string, label: string, hours: number? }
-- The update an automatic or manual check found, until it's downloaded or skipped: the upstream's tip (what
-- Download Update brings the plugin to), the version its `plugin.toml` says when it says one, and the newest commit
-- that changes the plugin (what Skip This Version skips: a later push of only the README doesn't bring it back).
export type Pending = { sha: string, short: string, version: string?, latest: string }
-- How the last check, skip or update went, for the settings panel. `reason`: "up_to_date", "available" (now pending),
-- "skipped" (Skip This Version, or an automatic check finding the skipped one), "updated" (Download Update landed),
-- "diverged" (a clone with local commits; `ok` false) or "failed" (the check failed; `ok` false). `at` is os.time();
-- `detail` says why in plain words when `ok` is false; `version` names the update (its version, else its commit)
-- or, for "up_to_date", the version installed.
export type Outcome = { ok: boolean, at: number, reason: string, detail: string?, version: string? }

type Module = {
	INTERVALS: { Interval },
	interval: () -> Interval,
	set_interval: (cx: WindowCx, id: string) -> (),
	version: () -> string?,
	pending: () -> Pending?,
	last_checked: () -> number?,
	last_outcome: () -> Outcome?,
	landing: () -> string?,
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
local KV_LAST = "omp-usage.update-last" -- os.time() of the last check that completed (failures don't count)
local KV_LAST_OUTCOME = "omp-usage.update-outcome" -- an Outcome
local KV_PENDING = "omp-usage.update-pending" -- a Pending
local KV_KEPT = "omp-usage.update-kept" -- the upstream commit the user skipped
local KV_CLAIM = "omp-usage.update-claim" -- the window that claimed the automatic check
local KV_APPLYING = "omp-usage.update-applying" -- `{ name, at }`: an update landing, for the settings panels
-- `{ sha, name, at }`: an installed copy's update that started landing and hasn't finished (see `land`)
local KV_LANDING = "omp-usage.update-landing"
local KV_LAND_CLAIM = "omp-usage.update-land-claim" -- the window that claimed finishing an interrupted update
-- `{ sha, name, pid, window, at }`: a clone's fast-forward under way, for the VM a reload starts before it ends
local KV_MERGING = "omp-usage.update-merging"
local KV_SETUP_CLAIM = "omp-usage.setup-claim" -- the window that claimed setting up the omp extension
local KV_SETUP_AT = "omp-usage.setup-at" -- os.time() a window last started setting it up
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
local MERGE_TIMEOUT_MS = 30000 -- a clone's fast-forward that takes longer is stopped
local MERGE_STALE_S = 120 -- a fast-forward whose end never came (its VM went) stops counting
local RESUME_MS = 500 -- after a load, before finishing an update a reload or restart interrupted
local SETUP_FRESH_S = 60 -- a window loading this soon after another set up the omp extension leaves it
-- No credential prompts or windows: a remote that needs them fails the check instead.
local GIT_ENV = { GIT_TERMINAL_PROMPT = "0", GCM_INTERACTIVE = "never" }
local UPDATE_ACTION = "plugin." .. tern.plugin.id .. ".update"
-- What an update covers: every file but the README, its pictures, the tests and the project's own notes and
-- tooling. The omp extension (`omp/`) is one of them.
local EXTENSION_DIR = "omp"
local PLUGIN_PATHS = {
	"--",
	":/",
	":(top,exclude)README.md",
	":(top,exclude)docs",
	":(top,exclude).omp",
	":(top,exclude).github",
	":(top,exclude)package.json",
	":(top,exclude)tests",
}
-- What an installed copy's update writes: the same files but for the `upstream` file (the copy's own names where the
-- user wants updates from). The old `omp-usage` folder is gone from the repo, so copies that still have it lose it
-- with the other files the history deleted.
local LAND_PATHS = table.clone(PLUGIN_PATHS)
table.insert(LAND_PATHS, ":(top,exclude)upstream")
-- An installed copy's mirror, and the ref there that follows the upstream's default branch, the only one fetched.
local MIRROR = tern.plugin.data .. "/source"
local MIRROR_TIP = "refs/upstream"
-- The file naming an installed copy's upstream, where a fork names itself: Tern keeps no record of where it
-- installed a copy from, and plugin.toml takes no such field. Updates leave the copy's own file as it is.
local UPSTREAM_FILE = "upstream"
-- Where an installed copy's update is staged before it's copied in (see `land`): one folder per landing VM, under
-- the plugin's data directory, which Tern doesn't watch.
local STAGING = tern.plugin.data .. "/staging"
local STAGED_MAX = 16 * 1024 * 1024 -- the biggest plugin file an update copies
local STAGE_STALE_S = 10 * 60 -- a staging folder this old was left by a VM that went: no landing takes that long
-- git writes files as they are in the repository (LF), whatever the user's line-ending settings say.
local CHECKOUT_CONFIG = { "-c", "core.autocrlf=false", "-c", "core.eol=lf", "-c", "core.symlinks=false" }
-- Plugin files an update copies first and last: the updater before anything else, so a copy left part-way can still
-- finish the job, and plugin.toml last, so the copy never says it's the new version before everything else is.
local COPY_FIRST = { ["update.luau"] = 1, ["extension.luau"] = 2 }
local COPY_LAST = "plugin.toml"
-- Has omp load the extension (extension.luau).
local extension = require("./extension")
local KV_INSTALLED = "omp-usage.installed" -- `{ sha, version }`: the commit an installed copy last wrote
local SETUP_MS = 3000 -- after a load, before an installed copy sets up the omp extension

-- `status` is git's exit code, -1 when it was stopped and -2 when it didn't start.
type Git = { ok: boolean, status: number, out: string, err: string }
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

-- A token no other VM makes at the same moment: windows that start the same thing at once (a claim, a staging
-- folder) tell theirs apart by it. Each part alone can repeat across VMs (a fresh VM's clock, its random seed).
local function unique(): string
	local address = string.match(tostring({}), "(%x+)$") or ""
	return string.format("%d.%d.%s.%d", math.floor(tern.now() * 1000), math.floor(os.clock() * 1000000), address, math.random(1, 1073741824))
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

-- Runs git in `dir`, with `env` added to GIT_ENV; `done` gets a fresh cx when the window gave one, else `cx`.
local function git(cx: WindowCx, dir: string, args: { string }, timeout_ms: number, done: (Git, WindowCx) -> (), env: { [string]: string }?)
	local argv = { "git" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local vars = GIT_ENV
	if env then
		vars = table.clone(GIT_ENV)
		for name, value in env do
			vars[name] = value
		end
	end
	local opts = { cwd = dir, env = vars, timeout_ms = timeout_ms }
	local started, err = pcall(function()
		tern.process.run(argv, opts, function(result: ProcessResult, later: WindowCx?)
			local failure = if result.timed_out then "git took too long" else result.stderr
			done({ ok = result.status == 0, status = result.status, out = result.stdout, err = failure }, later or cx)
		end)
	end)
	if not started then
		done({ ok = false, status = -2, out = "", err = "git didn't start: " .. tostring(err) }, cx)
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
	-- an update that hasn't finished landing: its plugin.toml may already say the new version, so nothing judges the
	-- copy until `resume` finishes it
	if type(kv_get(KV_LANDING)) == "table" then
		fail(cx, "omp Usage is finishing an update", "Check again once it's done")
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
	-- read at each check, like the version: an edit to the file counts from the next one
	local named, named_text = pcall(tern.fs.read, UPSTREAM_FILE, 4096)
	local named_repository = if named then string.match(named_text, "^%s*(%S+)") else nil
	if named_repository == nil then
		fail(cx, "omp Usage can't check for updates", "Its upstream file, which names its repository, is missing")
		return
	end
	local repository = named_repository :: string
	local function source(head: string): Source
		return { dir = MIRROR, head = head, tip = MIRROR_TIP, installed = true }
	end
	-- Brings the mirror up to date (`then_` gets whether it fetched), cloning it the first time.
	local function sync(at: WindowCx, always: boolean, then_: (WindowCx, boolean) -> ())
		-- from the repository the upstream file names now, not the one the mirror was cloned from
		local function fetch_tip(at1: WindowCx)
			git(at1, MIRROR, { "remote", "set-url", "origin", repository }, 10000, function(set: Git, at2: WindowCx)
				if not set.ok then
					fail(at2, "omp Usage can't check for updates", reason(set.err))
					return
				end
				git(at2, MIRROR, { "fetch", "--quiet", "origin", "+HEAD:" .. MIRROR_TIP }, 60000, function(fetched: Git, at3: WindowCx)
					if fetched.ok then
						then_(at3, true)
					else
						fail(at3, "omp Usage couldn't fetch updates", reason(fetched.err), true)
					end
				end)
			end)
		end
		local function clone(at1: WindowCx)
			pcall(tern.fs.remove, MIRROR) -- a clone cut short, or no repository at all
			pcall(tern.fs.mkdir, tern.plugin.data)
			local clone_args = { "clone", "--bare", "--single-branch", "--quiet", repository, MIRROR }
			git(at1, tern.plugin.data, clone_args, 120000, function(cloned: Git, at2: WindowCx)
				if cloned.ok then
					fetch_tip(at2)
				else
					pcall(tern.fs.remove, MIRROR)
					fail(at2, "omp Usage couldn't download its repository", reason(cloned.err), true)
				end
			end)
		end
		if not tern.fs.exists(MIRROR) then
			clone(at)
			return
		end
		-- Asks git for the tip rather than looking for its file: `git gc` packs refs, and a packed ref has none.
		-- `--git-dir=.`: a mirror that isn't a repository any more mustn't find one in a folder above it.
		local probe = { "--git-dir=.", "rev-parse", "--verify", "--quiet", MIRROR_TIP }
		git(at, MIRROR, probe, 10000, function(tip: Git, at1: WindowCx)
			if tip.ok then
				if always then
					fetch_tip(at1)
				else
					then_(at1, false)
				end
			elseif tip.status == 1 then
				fetch_tip(at1) -- a repository without the tip (a fetch cut short): fetching brings it
			elseif tip.status == -2 or tip.status == -1 then
				fail(at1, "omp Usage can't check for updates", reason(tip.err)) -- git, not the mirror, is the trouble
			else
				clone(at1) -- not a repository: a clone cut short
			end
		end)
	end
	-- The commit the copy is: the one the last update wrote, while the copy is still that version and the upstream's
	-- history still has it (a rewritten upstream drops it); else the newest commit at its version, which a fetch may
	-- have to bring first (a copy installed after the mirror last fetched).
	local function resolve(at: WindowCx, fetched: boolean)
		local function by_version(at0: WindowCx)
			-- along the branch's first parents, a merge diffed against its first parent: git shows no diff for a
			-- merge otherwise, so a version set in one (a pull request merged with a version bump) would never be
			-- found, and `<sha>^` below steps back along the same line
			local args =
				{ "log", "-m", "--first-parent", "-p", "-U0", "--no-color", "--format=%x1e%H", MIRROR_TIP, "--", "plugin.toml" }
			git(at0, MIRROR, args, 20000, function(log: Git, at1: WindowCx)
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
		local known = kv_get(KV_INSTALLED)
		if type(known) == "table" and known.version == version and type(known.sha) == "string" then
			local sha: string = known.sha
			git(at, MIRROR, { "merge-base", "--is-ancestor", sha, MIRROR_TIP }, 10000, function(kept: Git, at0: WindowCx)
				if kept.ok then
					done(source(sha), nil, at0)
				else
					by_version(at0)
				end
			end)
			return
		end
		by_version(at)
	end
	sync(cx, fetch, resolve)
end

-- An installed copy's update, landed so that no failure, reload or restart leaves the copy a mix of two versions that
-- passes for either:
-- 1. KV_LANDING names the commit before anything changes, and goes only once all of it has landed. While it's
--    there, no check judges the copy (its plugin.toml may already say the new version), and a VM that loads with it
--    set lands that commit again (`finish_staged` at once, else `resume`).
-- 2. git checks the commit's plugin files (LAND_PATHS) out into a staging folder in the plugin's data directory,
--    which Tern doesn't watch: a process of its own, so no budget stops it halfway, and the copy doesn't change yet.
--    The marker then names the folder and what's in it.
-- 3. One callback copies them in (`copy_in`). Tern's folder watch reloads the plugin once it's done. A failure
--    part-way leaves the marker and the staging folder, and the VM that loads next copies the rest in from there
--    before the rest of the plugin loads, so the mix never runs.
-- The README, pictures and tests aren't plugin files: it leaves them.

-- Copies the staged `files` from `tree` over the copy, each only when its contents differ (so a second try picks up
-- where the first stopped), the updater first and plugin.toml last, then deletes `gone`: the plugin files the
-- repository's history once had that the update doesn't, whichever commit the copy came from (files the history never
-- had are the user's and stay). Returns why it failed, whether it changed anything, whether the omp extension's files
-- changed, and the version the update's plugin.toml says.
local function copy_in(tree: string, files: { string }, gone: { string }): (string?, boolean, boolean, string?)
	local ordered = table.clone(files)
	local function rank(path: string): number
		return if path == COPY_LAST then 1000 else COPY_FIRST[path] or 100
	end
	table.sort(ordered, function(a: string, b: string): boolean
		local ra, rb = rank(a), rank(b)
		return if ra ~= rb then ra < rb else a < b
	end)
	local function is_extension(path: string): boolean
		return string.sub(path, 1, #EXTENSION_DIR + 1) == EXTENSION_DIR .. "/"
	end
	local dir = tern.plugin.dir
	local touched, extension_changed = false, false
	local version: string? = nil
	local copied, failure = pcall(function()
		for _, path in ordered do
			local text = tern.fs.read(tree .. "/" .. path, STAGED_MAX)
			if path == COPY_LAST then
				version = toml_version(text)
			end
			local read, current = pcall(tern.fs.read, dir .. "/" .. path, STAGED_MAX)
			if not read or current ~= text then
				touched = true
				local parent = string.match(path, "^(.*)/[^/]*$")
				if parent then
					tern.fs.mkdir(dir .. "/" .. parent)
				end
				tern.fs.write(dir .. "/" .. path, text)
				extension_changed = extension_changed or is_extension(path)
			end
		end
		for _, path in gone do
			if tern.fs.exists(dir .. "/" .. path) then
				touched = true
				tern.fs.remove(dir .. "/" .. path)
				extension_changed = extension_changed or is_extension(path)
			end
		end
		-- the folders those deletions left empty (the old `omp-usage` one), never one with anything left in it
		for _, path in gone do
			local parent = string.match(path, "^(.*)/[^/]*$")
			while parent do
				local full = dir .. "/" .. parent
				if not tern.fs.exists(full) or #tern.fs.list(full) > 0 then
					break
				end
				tern.fs.remove(full)
				parent = string.match(parent, "^(.*)/[^/]*$")
			end
		end
	end)
	return if copied then nil else tostring(failure), touched, extension_changed, version
end

-- Whether landing `files` and deleting `gone` changes the omp extension's files in the copy, worked out before any
-- of it is written, so an update a failure cut short still says so when the next load finishes it.
local function extension_differs(tree: string, files: { string }, gone: { string }): boolean
	local prefix = EXTENSION_DIR .. "/"
	local dir = tern.plugin.dir
	for _, path in files do
		if string.sub(path, 1, #prefix) == prefix then
			local ok, current = pcall(tern.fs.read, dir .. "/" .. path, STAGED_MAX)
			local staged_ok, text = pcall(tern.fs.read, tree .. "/" .. path, STAGED_MAX)
			if not ok or not staged_ok or current ~= text then
				return true
			end
		end
	end
	for _, path in gone do
		if string.sub(path, 1, #prefix) == prefix and tern.fs.exists(dir .. "/" .. path) then
			return true
		end
	end
	return false
end

-- A list from `tern.kv` (its tables have a protected metatable) as a plain list of strings, nil when it isn't one.
local function strings(value: any): { string }?
	if type(value) ~= "table" then
		return nil
	end
	local out: { string } = {}
	for _, item in ipairs(value) do
		if type(item) ~= "string" then
			return nil
		end
		table.insert(out, item)
	end
	return out
end

-- Removes staging folders older than STAGE_STALE_S (a VM a reload or restart ended left them, or a removal failed),
-- but `keep`, the one a landing marker still names.
local function prune_staging(keep: string?)
	local listed_ok, entries = pcall(tern.fs.list, STAGING)
	if not listed_ok then
		return
	end
	local kept = if keep then string.match(keep, "([^/\\]+)[/\\]*$") else nil
	for _, entry in entries do
		local born = tonumber(string.match(entry, "^(%d+)%-") or "")
		if born and entry ~= kept and os.time() - born > STAGE_STALE_S then
			pcall(tern.fs.remove, STAGING .. "/" .. entry)
		end
	end
end

-- `resuming`: the marker was there already (an earlier try may have changed files), so a failure keeps it. `done`
-- gets why it didn't land, and whether the omp extension's files changed.
local function land(cx: WindowCx, sha: string, name: string, resuming: boolean, done: (string?, boolean, WindowCx) -> ())
	kv_set(KV_LANDING, { sha = sha, name = name, at = os.time() })
	-- a folder of its own: windows finishing the same update at once don't trip over each other
	local stage = STAGING .. "/" .. tostring(os.time()) .. "-" .. unique()
	local tree = stage .. "/tree"
	local touched = false -- whether the copy changed yet: then the staging folder stays for the next load
	local function finish(err: string?, extension_changed: boolean, at: WindowCx)
		if err == nil or not touched then
			pcall(tern.fs.remove, stage)
		end
		if err and not touched and not resuming then
			kv_set(KV_LANDING, nil) -- nothing changed: there's nothing to finish
		end
		done(err, extension_changed, at)
	end
	prune_staging(nil) -- this try stages afresh, so an earlier try's folder isn't needed
	if not pcall(tern.fs.mkdir, tree) then
		finish("Couldn't make a staging folder in " .. STAGING, false, cx)
		return
	end
	-- the index lives in the staging folder too: the mirror's own, and the copy, stay as they are
	local index = { GIT_INDEX_FILE = stage .. "/index" }
	local function staged(args: { string }): { string }
		local out = { "--git-dir=" .. MIRROR, "--work-tree=" .. tree }
		for _, arg in CHECKOUT_CONFIG do
			table.insert(out, arg)
		end
		for _, arg in args do
			table.insert(out, arg)
		end
		return out
	end
	local checkout = staged({ "checkout", "--force", sha })
	for _, path in LAND_PATHS do
		table.insert(checkout, path)
	end
	git(cx, tree, checkout, 60000, function(out: Git, cx1: WindowCx)
		if not out.ok then
			finish(reason(out.err), false, cx1)
			return
		end
		git(cx1, tree, staged({ "ls-files", "-z" }), 10000, function(listed: Git, cx2: WindowCx)
			local files: { string } = {}
			local have: { [string]: boolean } = {} -- each file, and each folder one is in
			for _, path in string.split(listed.out, "\0") do
				if path ~= "" then
					table.insert(files, path)
					have[path] = true
					local parent = string.match(path, "^(.*)/[^/]*$")
					while parent do
						have[parent] = true
						parent = string.match(parent, "^(.*)/[^/]*$")
					end
				end
			end
			if not listed.ok or #files == 0 then
				finish(if listed.ok then "The update has no plugin files" else reason(listed.err), false, cx2)
				return
			end
			-- every plugin file a commit up to `sha` deleted (a rename counts as one)
			local removed = { "log", "--no-renames", "--diff-filter=D", "--name-only", "-z", "--format=", sha }
			for _, path in LAND_PATHS do
				table.insert(removed, path)
			end
			git(cx2, MIRROR, removed, 20000, function(history: Git, cx3: WindowCx)
				if not history.ok then
					finish(reason(history.err), false, cx3)
					return
				end
				local gone: { string } = {}
				local seen: { [string]: boolean } = {}
				for _, piece in string.split(history.out, "\0") do
					local path = trim(piece)
					if path ~= "" and not have[path] and not seen[path] then
						seen[path] = true
						table.insert(gone, path)
					end
				end
				local extension = extension_differs(tree, files, gone)
				kv_set(KV_LANDING, { sha = sha, name = name, at = os.time(), stage = stage, files = files, gone = gone, extension = extension })
				local err, changed, extension_changed, version = copy_in(tree, files, gone)
				touched = changed
				if err then
					finish(err, extension or extension_changed, cx3)
					return
				end
				kv_set(KV_INSTALLED, { sha = sha, version = version })
				kv_set(KV_LANDING, nil)
				finish(nil, extension or extension_changed, cx3)
			end)
		end, index)
	end, index)
end

-- At load, before the rest of the plugin loads (window.luau requires this module first): an update whose copy a
-- failure cut short is finished from the staging folder it left, so the mix of old and new files never runs. What
-- it finished, for the window to say once it's there (see the end of this file).
local staged_landed: { name: string, extension: boolean }? = nil
local function finish_staged()
	local marker = kv_get(KV_LANDING)
	if not INSTALLED or type(marker) ~= "table" or type(marker.sha) ~= "string" or type(marker.stage) ~= "string" then
		return
	end
	local files, gone = strings(marker.files), strings(marker.gone)
	local tree = marker.stage .. "/tree"
	if files == nil or gone == nil or #files == 0 or not tern.fs.exists(tree) then
		return -- `resume` lands it again
	end
	local name: string = if type(marker.name) == "string" then marker.name else string.sub(marker.sha, 1, 7)
	local err, changed, extension_changed, version = copy_in(tree, files :: { string }, gone :: { string })
	if err then
		tern.log.warn("omp-usage couldn't finish updating to " .. name .. " at load: " .. err)
		return
	end
	kv_set(KV_INSTALLED, { sha = marker.sha, version = version })
	kv_set(KV_LANDING, nil)
	-- as `updated` does, which comes later in this file
	kv_set(KV_KEPT, nil)
	kv_set(KV_PENDING, nil)
	kv_set(KV_LAST_OUTCOME, { ok = true, at = os.time(), reason = "updated", version = name })
	pcall(tern.fs.remove, marker.stage)
	if changed or marker.extension == true then
		staged_landed = { name = name, extension = marker.extension == true or extension_changed }
	end
end
finish_staged()
if INSTALLED then
	local marker = kv_get(KV_LANDING)
	prune_staging(if type(marker) == "table" and type(marker.stage) == "string" then marker.stage else nil)
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

-- When the last check that completed ran, in any window (one that failed or found a diverged clone doesn't count).
function M.last_checked(): number?
	local value = kv_get(KV_LAST)
	return if type(value) == "number" then value else nil
end

function M.last_outcome(): Outcome?
	local value = kv_get(KV_LAST_OUTCOME)
	if type(value) == "table" and type(value.ok) == "boolean" and type(value.at) == "number" and type(value.reason) == "string" then
		return {
			ok = value.ok,
			at = value.at,
			reason = value.reason,
			detail = if type(value.detail) == "string" then value.detail else nil,
			version = if type(value.version) == "string" then value.version else nil,
		}
	end
	return nil
end

local function record(ok: boolean, reason_code: string, detail: string?, version: string?)
	kv_set(KV_LAST_OUTCOME, { ok = ok, at = os.time(), reason = reason_code, detail = detail, version = version })
end

-- The name of an installed copy's update that started landing and hasn't finished (see `land`), nil when none.
-- Until it has, the copy is no version in particular: say it's finishing an update, never that it's up to date.
function M.landing(): string?
	local value = kv_get(KV_LANDING)
	if type(value) == "table" and type(value.sha) == "string" then
		return if type(value.name) == "string" then value.name else string.sub(value.sha, 1, 7)
	end
	return nil
end

-- What an update is called: its version when plugin.toml moved, else its commit.
local function update_name(version: string?, current: string?, short: string): string
	if version and version ~= current then
		return version
	end
	return short
end

-- The widget bar's Update omp Usage button, among its Plugin segments: every pane of every window, while an update
-- is pending. Formatters must be pure and fast, so it reads what `refresh_badge` last saw rather than `tern.kv`.
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

local function window_of(cx: WindowCx): string
	local ok, key = pcall(function()
		return cx:window_key()
	end)
	return if ok then tostring(key) else ""
end

-- One window of those that start the same thing together (they loaded together, or tick together) goes ahead:
-- each writes its claim to `key`, and only the one whose claim is still there CLAIM_SETTLE_MS later runs `go`.
local function claim(cx: WindowCx, key: string, go: (WindowCx) -> ())
	local mine = window_of(cx) .. "@" .. unique()
	kv_set(key, mine)
	tern.timer(CLAIM_SETTLE_MS, function(later: WindowCx?)
		if later and kv_get(key) == mine then
			go(later)
		end
	end)
end

-- An update to `name` is in: nothing is pending or skipped any more.
local function updated(name: string)
	kv_set(KV_KEPT, nil)
	set_pending(nil)
	record(true, "updated", nil, name)
end

local function updated_note(extension: boolean): string?
	return if extension then "The omp extension changed: restart omp sessions" else nil
end

-- Tern watches the plugin's folder and reloads this window's plugins when an update changes it. Only if that didn't
-- happen (this VM, which a reload replaces, is still here) ask for Reload plugins, which also empties every plugin
-- canvas left open (the settings panel) until it's opened again.
local function reload_soon()
	tern.timer(RELOAD_FALLBACK_MS, function(last: WindowCx?)
		if last then
			pcall(function()
				last:command("reload_plugins")
			end)
		end
	end)
end

-- Finishes an installed copy's update that a reload, a restart or a failure cut short (see `land`). `loud`: say
-- how it went either way (a load, or the user asked); else only a success.
local function resume(cx: WindowCx, loud: boolean)
	local marker = kv_get(KV_LANDING)
	if not INSTALLED or type(marker) ~= "table" or type(marker.sha) ~= "string" then
		return
	end
	if busy then
		if loud then
			cx:toast("info", "omp Usage is already checking or updating")
		end
		return
	end
	if not tern.fs.exists(MIRROR) then
		-- nothing to land it from. plugin.toml goes last, so a copy cut short still says its old version, and the
		-- next check, cloning the mirror again, offers the update again
		kv_set(KV_LANDING, nil)
		return
	end
	busy = true
	local name: string = if type(marker.name) == "string" then marker.name else string.sub(marker.sha, 1, 7)
	land(cx, marker.sha, name, true, function(err: string?, extension: boolean, at: WindowCx)
		busy = false
		if err then
			tern.log.warn("omp-usage couldn't finish updating to " .. name .. ": " .. err)
			if loud then
				at:toast("error", "omp Usage couldn't finish updating to " .. name, err)
			end
			return
		end
		updated(name)
		at:toast("success", "omp Usage finished updating to " .. name, updated_note(extension))
		reload_soon()
	end)
end

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
	if M.landing() then
		resume(cx, true) -- the copy is mid-update: finish that first
		return
	end
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
			updated(name)
			at:toast("success", "omp Usage updated to " .. name, updated_note(extension))
			reload_soon()
		end
		local at0 = later or cx
		if INSTALLED then
			-- the check that found the update brought the mirror up to date
			land(at0, pending.sha, name, false, function(err: string?, extension: boolean, at: WindowCx)
				if err then
					failed(at, err)
				else
					landed(at, extension)
				end
			end)
			return
		end
		local dir = tern.plugin.dir
		-- Whether the omp extension changed: omp loads it at session start, so open sessions need a restart.
		git(at0, dir, { "diff", "--name-only", "HEAD", pending.sha }, 10000, function(diff: Git, cx2: WindowCx)
			local extension = diff.ok and string.find("\n" .. diff.out, "\n" .. EXTENSION_DIR .. "/") ~= nil
			-- Started with `spawn` for its pid: the fast-forward changes the folder Tern watches, and if the reload
			-- that brings ends this VM first, its end comes to the new VM as a `process_exit` (see `reconcile`).
			local ended = false
			local stopped = false
			local function finish(status: number, stderr: string, at: WindowCx)
				if ended then
					return
				end
				ended = true
				kv_set(KV_MERGING, nil)
				if status == 0 then
					landed(at, extension)
				else
					failed(at, if stopped then "git took too long" else reason(stderr))
				end
			end
			local argv = { "git", "merge", "--ff-only", "--quiet", pending.sha }
			local started, child = pcall(tern.process.spawn, argv, {
				cwd = dir,
				env = GIT_ENV,
				exit = function(result: SpawnExit, at: WindowCx?)
					finish(result.status, result.stderr, at or cx2)
				end,
			})
			if not started then
				failed(cx2, "git didn't start: " .. tostring(child))
				return
			end
			local merge = child :: Child
			kv_set(KV_MERGING, {
				sha = pending.sha,
				name = name,
				pid = merge.pid,
				window = window_of(cx2),
				extension = extension,
				at = os.time(),
			})
			tern.timer(MERGE_TIMEOUT_MS, function(_later: WindowCx?)
				if not ended then
					stopped = true
					pcall(function()
						merge:kill()
					end)
				end
			end)
		end)
	end)
end

-- A linked clone, at load and when a child of the VM before it ends: a pending update the clone already has goes
-- (pulled by hand, or a fast-forward whose end went with the VM a reload replaced), and that fast-forward's end, if
-- it's this one, gets its say. `exit`: the child that ended; nil at load.
local function reconcile(cx: WindowCx, exit: ProcessExitEvent?)
	if INSTALLED then
		return
	end
	local function merging_now(): any
		local value = kv_get(KV_MERGING)
		return if type(value) == "table" and type(value.sha) == "string" then value else nil
	end
	local function say(merging: any, at: WindowCx)
		local name: string = if type(merging.name) == "string" then merging.name else string.sub(merging.sha, 1, 7)
		updated(name)
		if merging.window == window_of(at) then
			at:toast("success", "omp Usage updated to " .. name, updated_note(merging.extension == true))
		end
	end
	local merging = merging_now()
	if exit then
		if merging == nil or merging.pid ~= exit.pid then
			return
		end
		kv_set(KV_MERGING, nil)
		if exit.status == 0 then
			say(merging, cx)
		else
			kv_set(KV_APPLYING, nil)
			if merging.window == window_of(cx) then
				local why = if exit.timed_out then "git took too long" else reason(exit.stderr)
				cx:toast("error", "omp Usage didn't update", why)
			end
		end
		return
	end
	local pending = M.pending()
	local target: string? = if merging then merging.sha elseif pending then pending.sha else nil
	if target == nil then
		return
	end
	git(cx, tern.plugin.dir, { "merge-base", "--is-ancestor", target :: string, "HEAD" }, 10000, function(has: Git, at: WindowCx)
		local still = merging_now()
		if merging then
			-- the `process_exit` may have come meanwhile and said it all
			if still == nil or still.pid ~= merging.pid then
				return
			end
			if has.ok then
				kv_set(KV_MERGING, nil)
				say(merging, at)
			elseif type(merging.at) ~= "number" or os.time() - merging.at > MERGE_STALE_S or merging.at > os.time() then
				kv_set(KV_MERGING, nil) -- its end never came
			end
			return
		end
		local now = M.pending()
		if has.ok and now and now.sha == target then
			set_pending(nil)
		end
	end)
end

tern.on("process_exit", function(ev: ProcessExitEvent, cx: WindowCx?)
	if cx then
		reconcile(cx, ev)
	end
end)

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
	local name = update_name(pending.version, M.version(), pending.short)
	kv_set(KV_KEPT, pending.latest)
	set_pending(nil)
	record(true, "skipped", nil, name)
	cx:toast("info", "Skipped omp Usage " .. name, "Update any time: omp Usage: Check for updates…")
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
	if M.landing() then
		resume(cx, manual) -- an update that hasn't finished landing: the copy is no version to check yet
		return
	end
	if busy then
		if manual then
			cx:toast("info", "omp Usage is already checking or updating")
		end
		return
	end
	busy = true
	local function stop(at: WindowCx, title: string, detail: string)
		busy = false
		record(false, "failed", if detail ~= "" then detail else title)
		if manual then
			at:toast("error", title, detail)
		else
			tern.log.warn("omp-usage update check: " .. title .. ": " .. detail)
		end
	end
	-- A check that completed: KV_LAST says when, and the outcome what it found.
	local function completed(reason_code: string, version: string?)
		kv_set(KV_LAST, os.time())
		record(true, reason_code, nil, version)
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
		git(cx1, src.dir, { "rev-parse", "--short", src.head }, 10000, function(rev: Git, cx3: WindowCx)
			local head = trim(rev.out)
			-- Counts, and below lists, follow the main line's first parents: a merge stands for the commits it brings
			-- in (its message says what they change), so a merged branch's own commits aren't offered one by one.
			local divergence = { "rev-list", "--first-parent", "--left-right", "--count", src.head .. "..." .. src.tip }
			git(cx3, src.dir, divergence, 10000, function(count: Git, cx4: WindowCx)
				local ahead_text, behind_text = string.match(count.out, "^%s*(%d+)%s+(%d+)")
				local ahead, behind = tonumber(ahead_text or ""), tonumber(behind_text or "")
				if not rev.ok or not count.ok or ahead == nil or behind == nil then
					stop(cx4, "omp Usage can't check for updates", reason(if rev.ok then count.err else rev.err))
					return
				end
				if behind == 0 then
					busy = false
					set_pending(nil)
					completed("up_to_date", M.version())
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
					local commits_text = plural(ahead :: number, "local commit")
					local title = "omp Usage has an update, but your clone has " .. commits_text
					record(false, "diverged", "Your clone has " .. commits_text .. ": merge the update by hand with git pull")
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
				local count_args = { "rev-list", "--first-parent", "--count", src.head .. ".." .. src.tip }
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
						completed("up_to_date", M.version())
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
						"--first-parent",
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
									local name = update_name(available, offer.current, tip_short)
									if not manual and kv_get(KV_KEPT) == latest then
										set_pending(nil) -- the user skipped this one
										completed("skipped", name)
										return
									end
									local before = M.pending()
									set_pending({ sha = tip, short = tip_short, version = available, latest = latest })
									completed("available", name)
									if manual then
										show_card(cx9, offer)
									elseif before == nil or before.latest ~= latest then
										-- a toast the first time an automatic check finds it
										cx9:toast(
											"info",
											"omp Usage " .. name .. " is available",
											"Update omp Usage in the widget bar, or Check for Updates in its settings"
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
-- only the window whose claim stuck checks. An update that hasn't finished landing is tried again instead, each
-- tick, whatever the interval.
local function tick(cx: WindowCx?)
	tern.timer(TICK_MS, tick)
	if cx == nil then
		return
	end
	if M.landing() then
		claim(cx, KV_LAND_CLAIM, function(later: WindowCx)
			resume(later, false)
		end)
		return
	end
	local hours = M.interval().hours
	if hours == nil then
		return
	end
	local now = os.time()
	local last = kv_get(KV_CHECKED)
	-- a last check in the future means the clock went back: it doesn't count
	if type(last) == "number" and last <= now and now - last < (hours :: number) * 3600 - 60 then
		return
	end
	kv_set(KV_CHECKED, now)
	claim(cx, KV_CLAIM, function(later: WindowCx)
		M.check(later, false)
	end)
end

-- An update `finish_staged` finished as this VM loaded: said once there's a window to say it in.
if staged_landed then
	tern.timer(0, function(cx: WindowCx?)
		local landed = staged_landed
		if cx and landed then
			refresh_badge()
			cx:toast("success", "omp Usage finished updating to " .. landed.name, updated_note(landed.extension))
		end
	end)
end
if tern.runtime.os ~= "ios" then -- no processes there, so no git
	tern.timer(FIRST_CHECK_MS, tick)
	-- Soon after a load: an installed copy finishes an update that `finish_staged` couldn't (a reload or restart cut
	-- it short before it staged, or the copy keeps failing), in one window of those loading together; a clone drops
	-- a pending update it already has.
	tern.timer(RESUME_MS, function(cx: WindowCx?)
		if cx == nil then
			return
		end
		if INSTALLED then
			if M.landing() then
				claim(cx, KV_LAND_CLAIM, function(later: WindowCx)
					resume(later, true)
				end)
			end
		else
			reconcile(cx, nil)
		end
	end)
end
-- An installed copy, once it loads, has omp load its extension (no processes on iOS, so no omp either): one window of
-- those loading together, and not again within SETUP_FRESH_S of the last.
if INSTALLED and tern.runtime.os ~= "ios" then
	tern.timer(SETUP_MS, function(cx: WindowCx?)
		if cx == nil then
			return
		end
		claim(cx, KV_SETUP_CLAIM, function(later: WindowCx)
			local now = os.time()
			local last = kv_get(KV_SETUP_AT)
			if type(last) == "number" and last <= now and now - last < SETUP_FRESH_S then
				return
			end
			kv_set(KV_SETUP_AT, now)
			extension.setup(later, false)
		end)
	end)
end

return M
