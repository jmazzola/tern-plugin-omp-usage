--!strict
-- update.luau in a linked clone: Download Update's fast-forward, and what a window makes of its end when Tern's
-- reload ended the VM that started it (the end comes to the new VM as `process_exit`), plus the load-time check that
-- drops a pending update the clone already has (T2.3).
local T = require("./t")
local H = require("./harness")

local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local NOW = 1795400000000
local DIR = "C:/plugins/omp-usage"
local C2 = "c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2"
local KV_PENDING = "omp-usage.update-pending"
local KV_MERGING = "omp-usage.update-merging"
local KV_OUTCOME = "omp-usage.update-outcome"
local KV_APPLYING = "omp-usage.update-applying"
local PENDING = { sha = C2, short = "c2c2c2c", version = "9.1.0", latest = C2 }

local function merging(extra: any?): any
	local m: any = { sha = C2, name = "9.1.0", pid = 4242, window = "window-1", extension = false, at = NOW // 1000 }
	for key, value in extra or {} do
		m[key] = value
	end
	return m
end

-- A window of a linked clone (its `.git` is there) whose git answers `merge-base --is-ancestor` with `has` (0: HEAD
-- has the commit, 1: it doesn't); update checks are off, so only what a load does runs.
local function clone_window(kv: { [string]: any }, has: number): (any, any)
	local store = H.kv_store(kv)
	store.set("omp-usage.update-every", "off")
	local w = H.world({ now = NOW, kv = store, files = { [DIR .. "/.git"] = true } })
	w.tern.plugin.dir = DIR
	w.processes = function(argv: { string }, _opts: any): any
		if argv[2] == "merge-base" then
			return { status = has }
		elseif argv[2] == "diff" then
			return { status = 0, stdout = "render.luau\n" }
		elseif argv[2] == "merge" then
			return { status = 0, pid = 4242 }
		end
		return { status = 0, stdout = "" }
	end
	local update = w:load("update")
	return w, update
end

local function process_exit(w: any, ev: any)
	for _, handler in w.handlers.process_exit or {} do
		handler(ev, w.cx)
	end
end

local function exit_event(status: number, stderr: string?): any
	return { pid = 4242, status = status, stdout = "", stderr = stderr or "", timed_out = false }
end

describe("a clone's Download Update", function()
	it("fast-forwards with a process whose end lands it", function()
		local w, update = clone_window({ [KV_PENDING] = PENDING }, 1)
		update.download(w.cx)
		w:advance(1600) -- every window's panel gets to see it coming first
		eq(w.ran[#w.ran], "git merge --ff-only --quiet " .. C2, "the fast-forward")
		local m = w.kv.get(KV_MERGING)
		eq({ m and m.sha, m and m.pid, m and m.window }, { C2, 4242, "window-1" }, "its record, for the next VM")
		w.children[4242].opts.exit({ status = 0, stdout = "", stderr = "" }, w.cx)
		eq(#w.toasts, 1, "one toast")
		eq({ w.toasts[1].level, w.toasts[1].text }, { "success", "omp Usage updated to 9.1.0" })
		eq({ w.kv.get(KV_MERGING), w.kv.get(KV_PENDING) }, { nil, nil }, "nothing pending or merging")
	end)

	it("when a reload ends its VM first, reports the fast-forward's end once, from `process_exit`", function()
		local w = clone_window({ [KV_PENDING] = PENDING, [KV_MERGING] = merging() }, 1)
		w:advance(3000) -- the load's check: HEAD doesn't have it yet, and it's recent: wait for its end
		eq({ #w.toasts, w.kv.get(KV_MERGING) ~= nil }, { 0, true }, "still waiting")
		process_exit(w, exit_event(0))
		eq(#w.toasts, 1, "one toast")
		eq({ w.toasts[1].level, w.toasts[1].text }, { "success", "omp Usage updated to 9.1.0" })
		eq({ w.kv.get(KV_MERGING), w.kv.get(KV_PENDING) }, { nil, nil }, "nothing pending or merging")
		local outcome = w.kv.get(KV_OUTCOME)
		eq({ outcome.ok, outcome.reason, outcome.version }, { true, "updated", "9.1.0" }, "outcome")
		process_exit(w, exit_event(0))
		eq(#w.toasts, 1, "an end said twice is said once")
	end)

	it("when HEAD already has it at load (its end went with the old VM), says so once", function()
		local w = clone_window({ [KV_PENDING] = PENDING, [KV_MERGING] = merging() }, 0)
		w:advance(3000)
		eq({ #w.toasts, w.toasts[1] and w.toasts[1].text }, { 1, "omp Usage updated to 9.1.0" }, "the load says it")
		process_exit(w, exit_event(0))
		eq(#w.toasts, 1, "the late `process_exit` says nothing more")
	end)

	it("says why a fast-forward failed, and keeps the update on offer", function()
		local w = clone_window({ [KV_PENDING] = PENDING, [KV_MERGING] = merging(), [KV_APPLYING] = { name = "9.1.0", at = NOW // 1000 } }, 1)
		w:advance(3000)
		process_exit(w, exit_event(128, "fatal: Not possible to fast-forward, aborting.\n"))
		eq({ #w.toasts, w.toasts[1] and w.toasts[1].level, w.toasts[1] and w.toasts[1].text, w.toasts[1] and w.toasts[1].sub }, { 1, "error", "omp Usage didn't update", "Not possible to fast-forward, aborting." })
		eq({ w.kv.get(KV_MERGING), w.kv.get(KV_APPLYING) }, { nil, nil }, "nothing merging or applying")
		eq(w.kv.get(KV_PENDING) ~= nil, true, "still pending")
	end)

	it("ignores the end of another process", function()
		local w = clone_window({ [KV_PENDING] = PENDING, [KV_MERGING] = merging() }, 1)
		w:advance(3000)
		process_exit(w, { pid = 999, status = 0, stdout = "", stderr = "", timed_out = false })
		eq({ #w.toasts, w.kv.get(KV_MERGING) ~= nil }, { 0, true })
	end)

	it("toasts only in the window that started it, but every window drops the pending update", function()
		local w = clone_window({ [KV_PENDING] = PENDING, [KV_MERGING] = merging({ window = "window-2" }) }, 1)
		w:advance(3000)
		process_exit(w, exit_event(0))
		eq(#w.toasts, 0, "no toast here")
		eq({ w.kv.get(KV_MERGING), w.kv.get(KV_PENDING) }, { nil, nil }, "nothing pending or merging")
	end)

	it("forgets a fast-forward whose end never came, after two minutes", function()
		local w = clone_window({ [KV_PENDING] = PENDING, [KV_MERGING] = merging({ at = NOW // 1000 - 200 }) }, 1)
		w:advance(3000)
		eq({ w.kv.get(KV_MERGING), #w.toasts }, { nil, 0 })
	end)
end)

describe("a clone at load", function()
	it("drops a pending update its HEAD already has (pulled by hand)", function()
		local w, update = clone_window({ [KV_PENDING] = PENDING }, 0)
		ok(update.pending() ~= nil, "pending before")
		w:advance(3000)
		eq({ update.pending(), #w.toasts }, { nil, 0 })
	end)

	it("keeps a pending update its HEAD doesn't have", function()
		local w, update = clone_window({ [KV_PENDING] = PENDING }, 1)
		w:advance(3000)
		ok(update.pending() ~= nil)
	end)
end)

return true -- run.mjs checks it: the Luau CLI's `require` returns a file's compile error instead of raising it
