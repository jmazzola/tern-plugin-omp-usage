--!strict
-- Has omp load the plugin's extension (`omp/extensions/usage-remaining.js`, which writes the cache the line is drawn
-- from) through omp's own plugin manager: `omp plugin link <plugin>/omp` links the `omp` folder, whose package.json
-- names the extension, into omp's plugins. omp then lists it as the plugin `omp-usage`: `/extensions` and
-- `omp plugin disable|enable omp-usage` turn it off and on, `omp plugin uninstall omp-usage` removes it, and an
-- update reaches omp because the link points at the files updates replace.
--
-- An installed copy sets this up a few seconds after it loads, and leaves alone:
-- - a link that's there, on or off: whatever the user made of it stands;
-- - a link the user uninstalled: KV_LINKED remembers the folder this plugin last linked, so a link that's gone
--   from there stays gone until `omp Usage: Set up omp extension` asks again;
-- - omp's config.yml naming `usage-remaining.js`: an extension loaded that way (a clone's) would run twice.
-- A link whose folder is gone (the plugin moved) is linked again. The loader 0.5.2 to 0.6.x wrote into
-- `~/.omp/agent/extensions` goes once omp loads the extension another way, since it would run it a second time; only
-- a file that starts with that loader's own first line is removed.
local M = {}

local PACKAGE = "omp-usage"
local KV_LINKED = "omp-usage.omp-linked" -- the `omp` folder this plugin last had omp link
local HOME = tern.getenv("USERPROFILE") or tern.getenv("HOME")
local LOADER = if HOME and HOME ~= "" then HOME .. "/.omp/agent/extensions/usage-remaining.js" else nil
local LOADER_HEAD = "// Written by the omp Usage plugin for Tern"
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

-- Whether omp's config.yml loads the extension itself.
local function configured(): boolean
	if HOME == nil or HOME == "" then
		return false
	end
	local ok, config = pcall(tern.fs.read, (HOME :: string) .. "/.omp/agent/config.yml", 1024 * 1024)
	return ok and string.find(config, "usage-remaining.js", 1, true) ~= nil
end

-- Removes the loader an earlier version wrote; true when there was one.
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

-- Runs `omp plugin <args>`; `done` gets whether it exited 0, its stdout and why it didn't.
local function omp(cx: WindowCx, args: { string }, done: (boolean, string, string, WindowCx) -> ())
	local argv = { "omp", "plugin" }
	for _, arg in args do
		table.insert(argv, arg)
	end
	local started, err = pcall(tern.process.run, argv, { env = OMP_ENV, timeout_ms = 30000 }, function(result: ProcessResult, later: WindowCx?)
		local why = if result.timed_out then "omp took too long" else (string.match(result.stderr, "%S[^\n]*") or "")
		done(result.status == 0, result.stdout, why, later or cx)
	end)
	if not started then
		done(false, "", "omp isn't on PATH (" .. tostring(err) .. ")", cx)
	end
end

-- omp's entry for the plugin's package: nil when it isn't one of omp's plugins.
local function entry(listed: string): { path: string, enabled: boolean }?
	local ok, doc = pcall(tern.json.decode, listed)
	if not ok or type(doc) ~= "table" or type(doc.npm) ~= "table" then
		return nil
	end
	for _, item in doc.npm do
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

-- Sets up the link as described at the top. `asked`: the user asked for it, so a link they removed is made again.
function M.setup(cx: WindowCx, asked: boolean)
	if configured() then
		drop_loader()
		if asked then
			cx:toast("info", "omp loads omp Usage's extension from its config.yml", "Nothing to set up")
		end
		return
	end
	local dir = folder()
	omp(cx, { "list", "--json" }, function(listed: boolean, out: string, why: string, cx1: WindowCx)
		if not listed then
			failed(cx1, why)
			return
		end
		local found = entry(out)
		-- there, and its folder too: on or off, it stays as it is
		if found and tern.fs.exists(found.path .. "/package.json") then
			local dropped = drop_loader()
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
			return
		end
		omp(cx1, { "link", dir }, function(linked: boolean, _out: string, why2: string, cx2: WindowCx)
			if not linked then
				failed(cx2, why2)
				return
			end
			kv_set(KV_LINKED, dir)
			local dropped = drop_loader()
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
