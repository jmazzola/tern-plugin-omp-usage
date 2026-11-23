--!strict
-- Loads the plugin's own .luau files into a simulated Tern window ("world") for the Luau tests: a `tern` test
-- double (timers on a controlled clock, `tern.kv` backed by a store several worlds can share, `tern.json` as
-- json.luau, logs, style sheets and toasts recorded), an `os` whose time is the world's, and a `cx` whose
-- `docs:read` answers with the cache text a test sets. Each world loads the files afresh, so module state
-- (the cache poll's last text, the alerts' claims) never leaks from one test to the next.
--
-- The plugin's files reach the tests as text (run.mjs writes them into `sources`), because the Luau CLI has no file
-- reading; they're compiled here with `loadstring` and run with the world's globals (`setfenv`). `expose` names
-- file-local functions a test calls directly: they are added to the file's return value as `__test`, without
-- changing the file itself.
local sources = require("./sources") :: { [string]: string }
local json = require("./json")

local H = {}

export type KvStore = {
	get: (key: string, reader: any?) -> any,
	set: (key: string, value: any, writer: any?) -> (),
	raw: (key: string) -> string?,
	writes: { { key: string, value: string? } },
}

-- Every Tern window of a profile shares one `tern.kv` (kv.json): values go through JSON, so each get returns a fresh
-- copy whose arrays carry the protected metatable Tern's do. `opts.lag_ms`: a window sees another window's write only
-- that long after it was made (by the windows' own clocks, which tests keep in step), as when each window re-reads
-- kv.json only once it notices the file changed; its own writes it sees at once.
function H.kv_store(initial: { [string]: any }?, opts: { lag_ms: number? }?): KvStore
	local lag = if opts and opts.lag_ms then opts.lag_ms else 0
	local history: { [string]: { { at: number, by: string?, text: string? } } } = {}
	local writes: { { key: string, value: string? } } = {}
	local store: KvStore = {
		get = function(key: string, reader: any?): any
			local entries = history[key] or {}
			for i = #entries, 1, -1 do
				local entry = entries[i]
				if lag == 0 or reader == nil or entry.by == nil or entry.by == reader.key or entry.at <= reader.epoch_ms - lag then
					return if entry.text then json.decode(entry.text) else nil
				end
			end
			return nil
		end,
		set = function(key: string, value: any, writer: any?)
			local text = if value == nil then nil else json.encode(value)
			history[key] = history[key] or {}
			table.insert(history[key], { at = if writer then writer.epoch_ms else -math.huge, by = if writer then writer.key else nil, text = text })
			table.insert(writes, { key = key, value = text })
		end,
		raw = function(key: string): string?
			local entries = history[key]
			return if entries and #entries > 0 then entries[#entries].text else nil
		end,
		writes = writes,
	}
	for key, value in initial or {} do
		store.set(key, value)
	end
	table.clear(writes)
	return store
end

local function awaitable(value: any, err: string?, cx: any): any
	local a = {}
	function a.next(self: any, cb: (any, string?, any) -> ()): any
		cb(value, err, cx)
		return self
	end
	return a
end

-- Inserts `__test = { name = name, … }` into a file's return value, just before it returns.
local function exposed(text: string, file: string, names: { string }): string
	local fields: { string } = {}
	for _, name in names do
		table.insert(fields, name .. " = " .. name)
	end
	local list = "{ " .. table.concat(fields, ", ") .. " }"
	local at: number? = nil
	local search = 1
	while true do
		local i = string.find(text, "\nreturn {", search, true)
		if i == nil then
			break
		end
		at, search = i, i + 1
	end
	if at then
		local cut = (at :: number) + #"\nreturn {"
		return string.sub(text, 1, cut - 1) .. "\n\t__test = " .. list .. "," .. string.sub(text, cut)
	end
	local module_return = string.find(text, "\nreturn M%s*$")
	if module_return then
		return string.sub(text, 1, module_return) .. "M.__test = " .. list .. "\n" .. string.sub(text, module_return + 1)
	end
	error("harness: can't expose locals of " .. file .. ": it doesn't end with `return {` or `return M`")
end

export type Timer = { at: number, seq: number, fn: (any) -> (), cancelled: boolean }

-- A simulated window. `opts.now`: the wall clock (epoch ms) to start at; `opts.kv`: a shared KvStore; `opts.os`:
-- the OS environment variable (`Windows_NT` unless set); `opts.expose`: file -> local names, see `exposed`.
function H.world(opts: any?): any
	local o = opts or {}
	local w: any = {
		epoch_ms = o.now or 1795400000000,
		mono = 1000,
		timers = {} :: { Timer },
		seq = 0,
		logs = {} :: { { level: string, text: string } },
		errors = {} :: { string },
		sheets = {} :: { [string]: string },
		toasts = {} :: { { level: string, text: string, sub: string? } },
		handlers = {} :: { [string]: { (...any) -> any } },
		commands = {} :: { [string]: any },
		kv = o.kv or H.kv_store(),
		cache_text = nil :: string?,
		reads = {} :: { string },
		modules = {} :: { [string]: any },
		key = o.key or "window-1",
		env_vars = { OS = o.os or "Windows_NT", USERPROFILE = o.home or "C:\\Users\\tester" } :: { [string]: string },
		files = o.files or {} :: { [string]: boolean },
		ran = {} :: { string },
		children = {} :: { [number]: any },
	}
	local cx: any = {}
	w.cx = cx
	cx.docs = {
		read = function(_self: any, path: string): any
			table.insert(w.reads, path)
			return awaitable(w.cache_text, if w.cache_text == nil then "not found" else nil, cx)
		end,
	}
	cx.session = {
		panes = function(_self: any): { any }
			return w.panes or {}
		end,
		pane = function(_self: any, id: number): any
			for _, info in w.panes or {} do
				if info.pane == id then
					return info
				end
			end
			return nil
		end,
		focused = function(_self: any): number?
			return w.focused
		end,
		surface = function(_self: any, pane: number, _opts: any): any
			local trees = w.surfaces or {}
			return trees[pane]
		end,
	}
	cx.hosts = {
		list = function(_self: any): { any }
			return w.hosts or { { id = 0, name = "local", kind = "local", panes = {}, sessions = {}, current = true, state = "connected" } }
		end,
	}
	function cx.toast(_self: any, level: string, text: string, sub: string?)
		table.insert(w.toasts, { level = level, text = text, sub = sub })
	end
	function cx.window_key(_self: any): string
		return w.key
	end
	cx.canvas = {
		list = function(_self: any): { any }
			return {}
		end,
		set = function(_self: any, _pane: number, _view: any) end,
		open = function(_self: any, _spec: any): (number?, string?)
			return nil, "no canvases in the Luau tests"
		end,
	}
	cx.layout = {
		focus = function(_self: any, _pane: number) end,
		close = function(_self: any, _pane: number) end,
	}
	cx.actions = {
		keys = function(_self: any): { [string]: { string } }
			return w.keymap or {}
		end,
	}

	local function log(level: string): (...any) -> ()
		return function(...: any)
			local parts: { string } = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(w.logs, { level = level, text = table.concat(parts, "\t") })
		end
	end

	local stub_ui: any = setmetatable({}, {
		__index = function(_t: any, name: string): any
			return function(...: any): any
				return { ui = name, args = { ... } }
			end
		end,
	})

	local tern_stub: any = {
		context = "window",
		plugin = { id = "omp-usage", dir = "C:/plugins/omp-usage", data = "C:/plugin-data/omp-usage", version = "test" },
		runtime = { os = "windows" },
		getenv = function(name: string): string?
			return w.env_vars[name]
		end,
		now = function(): number
			return w.mono
		end,
		timer = function(ms: number, fn: (any) -> ()): any
			w.seq += 1
			local timer: Timer = { at = w.mono + math.max(0, ms), seq = w.seq, fn = fn, cancelled = false }
			table.insert(w.timers, timer)
			return {
				cancel = function(_self: any)
					timer.cancelled = true
				end,
			}
		end,
		json = { decode = json.decode, encode = json.encode, array = json.array, null = json.null },
		kv = {
			get = function(key: string): any
				return w.kv.get(key, w)
			end,
			set = function(key: string, value: any)
				w.kv.set(key, value, w)
			end,
		},
		log = { debug = log("debug"), info = log("info"), warn = log("warn"), error = log("error") },
		css = function(name: string, text: string?)
			w.sheets[name] = text
		end,
		on = function(event: string, fn: (...any) -> any)
			w.handlers[event] = w.handlers[event] or {}
			table.insert(w.handlers[event], fn)
		end,
		command = function(spec: any)
			w.commands[spec.id] = spec
		end,
		chrome = {
			status = function(fn: any)
				w.status_formatter = fn
			end,
			tab_title = function(_fn: any) end,
			window_title = function(_fn: any) end,
			refresh = function()
				w.chrome_refreshes = (w.chrome_refreshes or 0) + 1
			end,
		},
		ui = stub_ui,
		fs = {
			exists = function(path: string): boolean
				return (w.files or {})[path] ~= nil
			end,
			read = function(path: string, _max: number?): string
				error("tern.fs.read isn't available in the Luau tests: " .. path)
			end,
			write = function(path: string, _text: string)
				error("tern.fs.write isn't available in the Luau tests: " .. path)
			end,
			list = function(_path: string): { string }
				return {}
			end,
			mkdir = function(_path: string) end,
			remove = function(_path: string) end,
		},
		-- `w.processes(argv, opts)` answers a command as `{ status, stdout?, stderr?, pid? }` (nil: it can't start);
		-- `run` calls back at once, `spawn` returns a child whose `exit` the test calls (`w:exit(pid)`).
		process = {
			run = function(argv: { string }, opts: any, cb: (any, any) -> ())
				local answer = if w.processes then w.processes(argv, opts) else nil
				if answer == nil then
					error("tern.process.run can't start " .. table.concat(argv, " ") .. " in the Luau tests")
				end
				table.insert(w.ran, table.concat(argv, " "))
				cb({ status = answer.status, stdout = answer.stdout or "", stderr = answer.stderr or "", timed_out = false }, cx)
			end,
			spawn = function(argv: { string }, opts: any): any
				local answer = if w.processes then w.processes(argv, opts) else nil
				if answer == nil then
					error("tern.process.spawn can't start " .. table.concat(argv, " ") .. " in the Luau tests")
				end
				table.insert(w.ran, table.concat(argv, " "))
				local pid = answer.pid or 4242
				w.children[pid] = { opts = opts, answer = answer }
				return { pid = pid, kill = function(_self: any) end }
			end,
		},
	}
	w.tern = tern_stub

	local fake_os = {
		time = function(t: any?): number
			if t ~= nil then
				return os.time(t)
			end
			return math.floor(w.epoch_ms / 1000)
		end,
		date = os.date,
		clock = os.clock,
		difftime = os.difftime,
	}

	local base_env = getfenv(1)
	local env: any = setmetatable({ tern = tern_stub, os = fake_os }, { __index = base_env })
	local expose: { [string]: { string } } = o.expose or {}

	local function load(name: string): any
		local file = string.match(name, "^%./(.+)$") or name
		if not string.match(file, "%.luau$") then
			file ..= ".luau"
		end
		local cached = w.modules[file]
		if cached ~= nil then
			return cached
		end
		-- `opts.release`: that release's copy of a file (run.mjs embeds them as `<release>/<file>`), else today's
		local text = (if o.release then sources[o.release .. "/" .. file] else nil) or sources[file]
		if text == nil then
			error("harness: no plugin file " .. file)
		end
		if expose[file] then
			text = exposed(text, file, expose[file])
		end
		local chunk, err = loadstring(text, "=" .. file)
		if chunk == nil then
			error("harness: " .. file .. " doesn't compile: " .. tostring(err))
		end
		setfenv(chunk :: any, env)
		local result = (chunk :: any)()
		w.modules[file] = result
		return result
	end
	env.require = load
	w.load = function(_self: any, name: string): any
		return load(name)
	end

	-- Runs every timer due within `ms`, in order, each with `cx` (as Tern gives a window timer a fresh cx), moving
	-- both clocks; a callback's error is recorded in `errors`, as Tern logs it instead of stopping.
	w.advance = function(_self: any, ms: number)
		local target = w.mono + ms
		while true do
			local next_timer: Timer? = nil
			local index = 0
			for i, timer in w.timers do
				if not timer.cancelled and timer.at <= target and (next_timer == nil or timer.at < (next_timer :: Timer).at or (timer.at == (next_timer :: Timer).at and timer.seq < (next_timer :: Timer).seq)) then
					next_timer, index = timer, i
				end
			end
			if next_timer == nil then
				break
			end
			local timer = next_timer :: Timer
			table.remove(w.timers, index)
			w.epoch_ms += timer.at - w.mono
			w.mono = timer.at
			local ok, err = pcall(timer.fn, cx)
			if not ok then
				table.insert(w.errors, tostring(err))
			end
		end
		w.epoch_ms += target - w.mono
		w.mono = target
	end

	-- What `cx.docs:read` answers with from now on: a doc (encoded here) or text; nil: the file is gone.
	w.set_cache = function(_self: any, doc: any)
		w.cache_text = if type(doc) == "table" then json.encode(doc) else doc
	end

	-- Sets the cache and lets the plugin's 3 s cache poll read it.
	w.write_cache = function(self: any, doc: any)
		self:set_cache(doc)
		self:advance(3000)
	end

	w.warnings = function(_self: any): { string }
		local out: { string } = {}
		for _, entry in w.logs do
			if entry.level == "warn" or entry.level == "error" then
				table.insert(out, entry.text)
			end
		end
		return out
	end

	return w
end

-- Whether run.mjs embedded a file (a release's copy, `v0.7.10/data.luau`, needs git and that commit).
function H.has_source(key: string): boolean
	return sources[key] ~= nil
end

H.json = json

return H
