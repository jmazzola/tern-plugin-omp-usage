--!strict
-- Has omp load the plugin's extension (`omp/extensions/usage-remaining.js`, which writes the cache the line is drawn
-- from) through omp's own plugin manager: `omp plugin link <plugin>/omp` links the `omp` folder, whose package.json
-- names the extension, into omp's plugins. omp then lists it as the plugin `omp-usage`: `/extensions` and
-- `omp plugin disable|enable omp-usage` turn it off and on, `omp plugin uninstall omp-usage` removes it, and an
-- update reaches omp because the link points at the files updates replace.
--
-- An installed copy sets this up a few seconds after it loads (one window of those that load together, see
-- update.luau), and leaves alone:
-- - a link that's there, on or off: whatever the user made of it stands;
-- - a link the user uninstalled: KV_LINKED remembers the folder this plugin last linked, so a link that's gone
--   from there stays gone until `omp Usage: Set up omp extension` asks again;
-- - omp's config.yml listing `usage-remaining.js` under `extensions` (a clone's): an extension loaded that way would
--   run twice. Only an entry that counts: not commented out, and naming a file that's there.
-- A link whose folder is gone (the plugin moved) is linked again. The loader 0.5.2 to 0.6.x wrote into
-- `~/.omp/agent/extensions` goes once omp loads the extension another way that's on, since it would run it a second
-- time; only a file that starts with that loader's own first line is removed.
local M = {}

local PACKAGE = "omp-usage"
local KV_LINKED = "omp-usage.omp-linked" -- the `omp` folder this plugin last had omp link
local HOME = tern.getenv("USERPROFILE") or tern.getenv("HOME")
local LOADER = if HOME and HOME ~= "" then HOME .. "/.omp/agent/extensions/usage-remaining.js" else nil
local LOADER_HEAD = "// Written by the omp Usage plugin for Tern"
local EXTENSION_FILE = "usage-remaining.js"
local OMP_ENV = { NO_COLOR = "1" }

local function folder(): string
	return (string.gsub(tern.plugin.dir, "\\", "/")) .. "/omp"
end

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

-- A YAML scalar as written: its quotes, or else a trailing comment, taken off.
local function scalar(text: string): string
	local value = trim(text)
	local quoted = string.match(value, '^"(.*)"') or string.match(value, "^'(.*)'")
	if quoted then
		return quoted
	end
	return trim((string.gsub(value, "%s+#.*$", "")))
end

-- Whether a path config.yml's `extensions` lists is this extension, and there. `~` is the home folder; a relative
-- path, which omp resolves on its own terms, counts as there.
local function live_entry(path: string): boolean
	if string.match(path, "[^/\\]+$") ~= EXTENSION_FILE then
		return false
	end
	local full = path
	if string.sub(path, 1, 1) == "~" then
		full = (HOME :: string) .. string.sub(path, 2)
	elseif not (string.find(path, "^[/\\]") or string.find(path, "^%a:[/\\]")) then
		return true
	end
	local ok, there = pcall(tern.fs.exists, full)
	return ok and there == true
end

-- Whether omp's config.yml loads the extension itself: an `extensions` entry, not commented out, naming the
-- extension's file where it is. A commented-out line, or a clone deleted since, doesn't count.
local function configured(): boolean
	if HOME == nil or HOME == "" then
		return false
	end
	local ok, config = pcall(tern.fs.read, (HOME :: string) .. "/.omp/agent/config.yml", 1024 * 1024)
	if not ok then
		return false
	end
	local block: number? = nil -- the `extensions:` key's indent, while its block lasts
	for raw in string.gmatch(config .. "\n", "([^\n]*)\n") do
		local lead, rest = string.match((string.gsub(raw, "\r$", "")), "^(%s*)(.-)%s*$")
		if rest == nil or rest == "" or string.sub(rest, 1, 1) == "#" then
			continue
		end
		local depth = #(lead :: string)
		local text = rest :: string
		if block ~= nil then
			local item = string.match(text, "^%-%s+(.*)$")
			if depth > block or (depth == block and item ~= nil) then
				if item and live_entry(scalar(item)) then
					return true
				end
				continue
			end
			block = nil
		end
		local value = string.match(text, "^extensions%s*:%s*(.*)$")
		if value then
			value = trim((string.gsub(value, "%s+#.*$", "")))
			if value == "" then
				block = depth
			else
				local list = string.match(value, "^%[(.*)%]$") or value
				for _, part in string.split(list, ",") do
					if live_entry(scalar(part)) then
						return true
					end
				end
			end
		end
	end
	return false
end

-- Removes the loader an earlier version wrote; true when there was one. Only call it when something else that's on
-- loads the extension: the loader may be all that does.
local function drop_loader(): boolean
	if LOADER == nil then
		return false
	end
	local ok, text = pcall(tern.fs.read, LOADER :: string, 64 * 1024)
	if not ok or string.sub(text, 1, #LOADER_HEAD) ~= LOADER_HEAD then
		return false
	end
	return (pcall(tern.fs.remove, LOADER :: string))
end

-- Tern's own omp (`<Tern's data folder>/omp/bin/omp`), nil when there isn't one. Tern puts its folder on its
-- panes' PATH, not on the PATH Tern itself runs with, which on macOS is launchd's bare `/usr/bin:/bin:/usr/sbin:/sbin`.
-- The plugin's data folder is `<Tern's data folder>/plugin-data/<id>`.
local function managed_omp(): string?
	local data = (string.gsub(tern.plugin.data, "\\", "/"))
	local root = string.match(data, "^(.*)/plugin%-data/[^/]+/?$")
	if root == nil then
		return nil
	end
	for _, name in { "omp", "omp.exe" } do
		local path = root .. "/omp/bin/" .. name
		local ok, there = pcall(tern.fs.exists, path)
		if ok and there then
			return path
		end
	end
	return nil
end

-- Runs `omp plugin <args>` with the omp on PATH, and with Tern's own when that one doesn't start, exits non-zero or
-- gives an answer `usable` rejects (an omp too old or broken for `plugin`). `done` gets whether an omp answered
-- usably, its stdout and why none did (the last omp that ran says why, else why none started).
local function omp(cx: WindowCx, args: { string }, usable: ((string) -> boolean)?, done: (boolean, string, string, WindowCx) -> ())
	local candidates = { "omp" }
	local managed = managed_omp()
	if managed then
		table.insert(candidates, managed)
	end
	local answered: string? = nil -- why the last omp that ran didn't do
	local unstarted = "" -- why the last omp that didn't run didn't start
	local function try(i: number, at: WindowCx)
		local exe = candidates[i]
		if exe == nil then
			done(false, "", answered or ("omp isn't on PATH, and Tern has no omp of its own (" .. unstarted .. ")"), at)
			return
		end
		local argv = { exe, "plugin" }
		for _, arg in args do
			table.insert(argv, arg)
		end
		local function on_end(result: ProcessResult, later: WindowCx?)
			local at1 = later or at
			if result.status == 0 and not result.timed_out and (usable == nil or usable(result.stdout)) then
				done(true, result.stdout, "", at1)
				return
			end
			local why = if result.timed_out
				then "omp took too long"
				elseif result.status ~= 0 then (string.match(result.stderr, "%S[^\n]*") or ("omp exited with " .. tostring(result.status)))
				else "omp's answer to plugin " .. args[1] .. " wasn't one it understands"
			answered = (if i > 1 then exe .. ": " else "") .. why
			try(i + 1, at1)
		end
		local started, err = pcall(function()
			tern.process.run(argv, { env = OMP_ENV, timeout_ms = 30000 }, on_end)
		end)
		if not started then
			unstarted = tostring(err)
			try(i + 1, at)
		end
	end
	try(1, cx)
end

-- `omp plugin list --json`'s npm plugins, nil when the text isn't that list.
local function npm_plugins(listed: string): { any }?
	local ok, doc = pcall(tern.json.decode, listed)
	if not ok or type(doc) ~= "table" or type(doc.npm) ~= "table" then
		return nil
	end
	return doc.npm
end

-- omp's entry for the plugin's package: nil when it isn't one of omp's plugins.
local function entry(plugins: { any }): { path: string, enabled: boolean }?
	for _, item in plugins do
		if type(item) == "table" and item.name == PACKAGE and type(item.path) == "string" then
			return { path = item.path, enabled = item.enabled ~= false }
		end
	end
	return nil
end

local function failed(cx: WindowCx, why: string)
	tern.log.warn("omp-usage couldn't link its omp extension: " .. why .. "; run: omp plugin link " .. folder())
	cx:toast("error", "omp Usage couldn't set up its omp extension", "Tern's log says why, and what to run")
end

local running = false -- a setup is under way in this window

-- Sets up the link as described at the top. `asked`: the user asked for it, so a link they removed is made again.
function M.setup(cx: WindowCx, asked: boolean)
	if running then
		if asked then
			cx:toast("info", "omp Usage is already setting up its omp extension")
		end
		return
	end
	if configured() then
		drop_loader() -- config.yml loads it: that's on unless the user edits it out
		if asked then
			cx:toast("info", "omp loads omp Usage's extension from its config.yml", "Nothing to set up")
		end
		return
	end
	running = true
	local dir = folder()
	local function usable(out: string): boolean
		return npm_plugins(out) ~= nil
	end
	omp(cx, { "list", "--json" }, usable, function(listed: boolean, out: string, why: string, cx1: WindowCx)
		if not listed then
			running = false
			failed(cx1, why)
			return
		end
		local found = entry(npm_plugins(out) :: { any })
		-- there, and its folder too: on or off, it stays as it is
		if found and tern.fs.exists(found.path .. "/package.json") then
			running = false
			-- a link that's off loads nothing, so the loader, if any, stays the way it runs
			local dropped = found.enabled and drop_loader()
			if asked then
				local state = if found.enabled then "on" else "off: omp plugin enable " .. PACKAGE .. " turns it on"
				cx1:toast("info", "omp Usage's extension is set up", "It's " .. state)
			elseif dropped then
				cx1:toast("info", "omp Usage updated its omp extension", "Restart omp sessions to use it")
			end
			return
		end
		-- linked from here before and since uninstalled: that was the user's call
		if found == nil and not asked and kv_get(KV_LINKED) == dir then
			running = false
			return
		end
		omp(cx1, { "link", dir }, nil, function(linked: boolean, _out: string, why2: string, cx2: WindowCx)
			running = false
			if not linked then
				failed(cx2, why2)
				return
			end
			kv_set(KV_LINKED, dir)
			-- a new link is on; one made again over an entry that was off stays off
			local dropped = (found == nil or found.enabled) and drop_loader()
			if dropped or found then
				cx2:toast("info", "omp Usage updated its omp extension", "Restart omp sessions to use it")
			else
				cx2:toast("success", "omp Usage is installed", "Restart omp sessions to see the usage line")
			end
		end)
	end)
end

tern.command({
	id = "omp-extension",
	title = "omp Usage: Set up omp extension",
	icon = "gauge",
	run = function(cx: WindowCx)
		M.setup(cx, true)
	end,
})

return M
