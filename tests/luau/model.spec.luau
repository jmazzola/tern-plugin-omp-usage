--!strict
-- data.luau end to end: the cache as the poll reads it, through `build_model` (what the line and card show) and
-- `alert_candidates` (what alerts may say), on the world's clock.
local T = require("./t")
local H = require("./harness")
local F = require("./fixtures")
local json = require("./json")

local describe, it, eq, ok = T.describe, T.it, T.eq, T.ok

local NOW = 1795400000000
local STATUS = "Claude 5h ███░░░░░ 33% left (1h 2m) · 7d ██████░░ 77% left (3d 4h)"

-- A world with data.luau loaded and `doc` read by its poll; `kv`: settings to store first.
local function setup(doc: any?, kv: { [string]: any }?): (any, any)
	local w = H.world({ now = NOW, kv = H.kv_store(kv) })
	local data = w:load("data")
	if doc ~= nil then
		w:write_cache(doc)
	end
	return data, w
end

local function model_of(data: any, dock: any): any
	return data.build_model(data.load_settings(), dock, data.read_cache(data.now_ms()))
end

local function shares_of(group: any): { [string]: string }
	local out: { [string]: string } = {}
	for _, window in group.windows do
		out[window.label] = tostring(window.pct) .. (if window.passed then "/reset" else "")
	end
	return out
end

describe("build_model, Current model", function()
	it("shows the cache's line for the model chip while it's fresh", function()
		local data = setup(F.doc(NOW, { observed = NOW - 60000 }))
		local model = model_of(data, F.dock("Opus 5.5", STATUS))
		eq(model.source, "model:Opus 5.5", "source")
		eq(#model.groups, 1, "one provider")
		eq(model.groups[1].label, "Claude", "label")
		eq(shares_of(model.groups[1]), { ["5h"] = "62", ["7d"] = "41", ["Fable 7d"] = "83" }, "the cache's numbers, not the status's")
		eq(model.groups[1].as_of, nil, "not dimmed")
	end)

	it("dims numbers observed over 10 minutes ago and says how old they are", function()
		local data = setup(F.doc(NOW, { observed = NOW - 11 * F.M }))
		local model = model_of(data, F.dock("Opus 5.5", STATUS))
		eq(model.source, "model:Opus 5.5", "still the cache's")
		eq(model.groups[1].as_of, "as of 11m ago", "age note")
	end)

	it("falls back to the status past 30 minutes, and comes back with fresh numbers", function()
		local data, w = setup(F.doc(NOW, { observed = NOW - 31 * F.M }))
		local model = model_of(data, F.dock("Opus 5.5", STATUS))
		eq(model.source, "status", "fallback")
		eq(shares_of(model.groups[1]), { ["5h"] = "33", ["7d"] = "77" }, "the status's numbers")
		w:write_cache(F.doc(w.epoch_ms, { observed = w.epoch_ms - 30000 }))
		local back = model_of(data, F.dock("Opus 5.5", STATUS))
		eq(back.source, "model:Opus 5.5", "recovered")
		eq(back.groups[1].as_of, nil, "fresh again")
	end)

	it("shows nothing past 30 minutes without a status to fall back to", function()
		local data = setup(F.doc(NOW, { observed = NOW - 31 * F.M }))
		local model = model_of(data, F.dock("Opus 5.5", nil))
		eq({ #model.groups, model.title }, { 0, "Status" })
	end)

	it("ignores the whole file once its writer has stopped for 30 minutes", function()
		local data = setup(F.doc(NOW, { written = NOW - 31 * F.M, observed = NOW - 31 * F.M }))
		eq(data.read_cache(data.now_ms()), nil, "no usable cache")
	end)

	it("never uses this machine's cache for a remote or WSL pane", function()
		local data = setup(F.doc(NOW, { observed = NOW - 60000 }))
		local model = model_of(data, F.dock("Opus 5.5", STATUS, { remote = true }))
		eq(model.source, "status")
	end)

	it("ignores an entry for another provider than the one the status names", function()
		local doc = F.doc(NOW, { observed = NOW - 60000 })
		doc.models["Opus 5.5"].provider = "openai"
		local data = setup(doc)
		eq(model_of(data, F.dock("Opus 5.5", STATUS)).source, "status")
	end)

	it("reads `reset` once a window's reset time passes while the cache is read", function()
		local claude = F.claude(NOW, { inf = 20 * 1000 })
		local data, w = setup(F.doc(NOW, { claude = claude, observed = NOW - 1000 }))
		local before = model_of(data, F.dock("Opus 5.5", nil)).groups[1].windows[3]
		eq({ before.label, before.passed }, { "Fable 7d", nil }, "before")
		w:advance(25 * 1000)
		local after = model_of(data, F.dock("Opus 5.5", nil)).groups[1].windows[3]
		eq({ after.passed, data.pct_text(after), after.reset, after.pace }, { true, "reset", nil, nil }, "after")
	end)

	it("reads `reset` from a line the writer wrote after the reset passed", function()
		local claude = F.claude(NOW, { in5 = -5 * F.M })
		local data = setup(F.doc(NOW, { claude = claude }))
		local window = model_of(data, F.dock("Opus 5.5", nil)).groups[1].windows[1]
		eq({ window.label, window.passed, data.pct_text(window) }, { "5h", true, "reset" })
	end)

	it("keeps each reset time the cache states, however old the numbers get", function()
		local claude = F.claude(NOW)
		local at = claude[1].at
		local data, w = setup(F.doc(NOW, { claude = claude, observed = NOW }))
		local first = model_of(data, F.dock("Opus 5.5", nil)).groups[1].windows[1]
		w:advance(9 * F.M)
		-- the heartbeat rewrites the file with the same numbers: its countdowns are counted from the new write
		w:write_cache(F.doc(w.epoch_ms, { claude = F.claude(NOW), written = w.epoch_ms, observed = NOW }))
		local later = model_of(data, F.dock("Opus 5.5", nil)).groups[1].windows[1]
		eq({ first.resets_at, later.resets_at }, { at, at }, "the stated time both times")
		eq(later.reset, F.short(at - w.epoch_ms), "the countdown from now")
	end)

	-- omp states some resets from a countdown at fetch time: Claude's 7d and Fable 7d, the same reset, came as
	-- …27999873 and …28000246. Both read the same clock time and countdown, to the nearest minute.
	it("reads one reset stated a few hundred ms either side of a minute as one time and one countdown", function()
		local x = 1795428000000 -- a whole minute, 7h 46m 40s after NOW
		local claude = F.claude(NOW)
		claude[2].at = x - 127
		claude[3].at = x + 246
		local data, w = setup(F.doc(NOW, { claude = claude }))
		-- now 7h 46m 29.95s before x: unrounded, x - 127 counts down 7h 46m and x + 246 counts 7h 47m
		w:advance(10050)
		local windows: { [string]: any } = {}
		for _, window in model_of(data, F.dock("Opus 5.5", nil)).groups[1].windows do
			windows[window.label] = window
		end
		local week, fable = windows["7d"], windows["Fable 7d"]
		eq({ week.reset, fable.reset }, { "7h 46m", "7h 46m" }, "countdowns")
		local clock = data.clock_of(x, true)
		eq({ data.clock_of(week.resets_at, true), data.clock_of(fable.resets_at, true) }, { clock, clock }, "clock times")
		ok(data.clock_of(x - 60000, true) ~= clock, "a whole minute earlier still reads earlier")
	end)

	it("counts an old cache's countdowns from when it was written, not when it's read", function()
		local data, w = setup(F.doc(NOW, { v1 = true }))
		local first = model_of(data, F.dock("Opus 5.5", nil)).groups[1].windows[1]
		w:advance(8 * F.M)
		local later = model_of(data, F.dock("Opus 5.5", nil)).groups[1].windows[1]
		eq(first.resets_at, NOW + 2 * F.H, "written + countdown")
		eq(later.resets_at, first.resets_at, "8 minutes later")
	end)

	it("reads a first-version cache, fresh from its heartbeat", function()
		local data = setup(F.doc(NOW, { v1 = true }))
		local model = model_of(data, F.dock("Opus 5.5", STATUS))
		eq({ model.source, model.groups[1].as_of }, { "model:Opus 5.5", nil })
		eq(shares_of(model.groups[1]), { ["5h"] = "62", ["7d"] = "41", ["Fable 7d"] = "83" })
	end)

	it("leaves pace out, and changes the signature, while Show pace is off", function()
		local claude = F.claude(NOW, { r5 = 0.2, in5 = 2 * F.H })
		local data, w = setup(F.doc(NOW, { claude = claude }))
		local on = model_of(data, F.dock("Opus 5.5", nil))
		eq(data.pace_text(on.groups[1].windows[1].pace, on.groups[1].windows[1].remaining), "1.3× pace · empty ~45m", "on by default")
		w.kv.set(data.KV_SHOW_PACE, false)
		local off = model_of(data, F.dock("Opus 5.5", nil))
		eq(off.groups[1].windows[1].pace, nil, "off")
		ok(on.signature ~= off.signature, "the signature changes, so the line redraws")
	end)
end)

describe("build_model, the cache file", function()
	it("reads the cache from the home directory", function()
		local _, w = setup(F.doc(NOW))
		eq(w.reads[1], "C:\\Users\\tester/.omp/cache/usage-remaining.json")
	end)

	it("keeps the last numbers and says so when the file grows over 1 MiB, warning once", function()
		local data, w = setup(F.doc(NOW))
		local big = json.encode(F.doc(w.epoch_ms))
		big = string.sub(big, 1, #big - 1) .. ',"padding":"' .. string.rep("x", 1100 * 1024) .. '"}'
		w:write_cache(big)
		w:advance(9000)
		local model = model_of(data, F.dock("Opus 5.5", nil))
		eq(model.others, { "usage cache too big to read (1.1 MB)" }, "the note")
		eq(#model.groups, 1, "the last numbers stay")
		eq(#w:warnings(), 1, "one warning")
		w:write_cache(F.doc(w.epoch_ms))
		eq(model_of(data, F.dock("Opus 5.5", nil)).others, {}, "a normal file again clears it")
	end)

	it("decodes a file that won't decode once, keeps the last numbers, and says it's unreadable", function()
		local data, w = setup(F.doc(NOW))
		eq(#model_of(data, F.dock("Opus 5.5", nil)).groups, 1, "the good file, decoded (the line's poll decodes what the cache poll read)")
		local decodes = 0
		local decode = w.tern.json.decode
		w.tern.json.decode = function(text: string): any
			decodes += 1
			return decode(text)
		end
		w:write_cache('{"generatedAt": 1, "models": {')
		model_of(data, F.dock("Opus 5.5", nil))
		w:advance(9000)
		local model = model_of(data, F.dock("Opus 5.5", nil))
		eq(decodes, 1, "decoded once")
		eq(model.others, { "usage cache unreadable" }, "the note")
		eq(#model.groups, 1, "the last numbers stay")
	end)

	it("reads every 3 s while something shows the numbers, else every 15 s", function()
		local data, w = setup(nil)
		w:set_cache(F.doc(NOW))
		local watching = true
		data.set_watching(function(_cx: any): boolean
			return watching
		end)
		w:advance(30000)
		local busy = #w.reads
		watching = false
		table.clear(w.reads)
		w:advance(30000)
		ok(busy >= 9, "every 3 s: " .. busy .. " reads in 30 s")
		ok(#w.reads >= 1 and #w.reads <= 2, "every 15 s: " .. #w.reads .. " reads in 30 s")
	end)
end)

describe("build_model, providers", function()
	-- zai and zai-coding-plan both signed in: the extension labels them Zai and Zai-Coding, and keys a chip name both
	-- have (GLM-5) by provider, with the plain name null (left out here, as the decoder drops it).
	local function zai_doc(now: number): any
		local zai = { F.win({ label = "5h", ms = 5 * F.H, r = 0.72, at = now + F.H, provider = "zai" }), F.win({ label = "mo", key = "monthly", ms = 30 * F.D, r = 0.64, at = now + 12 * F.D, provider = "zai" }) }
		local coding = { F.win({ label = "5h", ms = 5 * F.H, r = 0.18, at = now + 4 * F.H, provider = "zai-coding-plan" }) }
		local doc = F.doc(now, {
			extra_providers = {
				zai = F.provider("zai", "Zai", zai, now),
				["zai-coding-plan"] = F.provider("zai-coding-plan", "Zai-Coding", coding, now),
			},
		})
		doc.models["zai/GLM-5"] = F.model("zai", "Zai", zai, now)
		doc.models["zai-coding-plan/GLM-5"] = F.model("zai-coding-plan", "Zai-Coding", coding, now)
		return doc
	end

	it("keeps Zai's and Zai Coding Plan's windows apart in All providers", function()
		local data = setup(zai_doc(NOW), { ["omp-usage.mode"] = "all" })
		local model = model_of(data, F.dock(nil, nil))
		local by: { [string]: any } = {}
		for _, group in model.groups do
			by[group.id] = group
		end
		eq({ by.zai.label, by["zai-coding-plan"].label }, { "Zai", "Zai-Coding" }, "labels")
		eq(shares_of(by.zai), { ["5h"] = "72", mo = "64" }, "Zai")
		eq(shares_of(by["zai-coding-plan"]), { ["5h"] = "18" }, "Zai-Coding")
	end)

	it("finds a shared chip name's entry by the provider its status names", function()
		local data = setup(zai_doc(NOW))
		local coding = model_of(data, F.dock("GLM-5", "Zai-Coding 5h █░░░░░░░ 18% left (4h)"))
		eq({ coding.source, coding.groups[1].id }, { "model:GLM-5", "zai-coding-plan" }, "Zai-Coding")
		local zai = model_of(data, F.dock("GLM-5", "Zai 5h ██████░░ 72% left (1h) · mo █████░░░ 64% left (12d)"))
		eq({ zai.groups[1].id, shares_of(zai.groups[1]) }, { "zai", { ["5h"] = "72", mo = "64" } }, "Zai")
	end)

	it("shows nothing, never the other provider's numbers, for a shared chip name without a status", function()
		local data = setup(zai_doc(NOW))
		eq(#model_of(data, F.dock("GLM-5", nil)).groups, 0)
	end)

	it("combined, names the accounts that have no current numbers", function()
		local now = NOW
		local alice = {
			F.win({ label = "alice 5h", key = "5h", ms = 5 * F.H, r = 0.55, at = now + 2 * F.H, account = "alice" }),
			F.win({ label = "alice 7d", key = "7d", ms = 7 * F.D, r = 0.38, at = now + 3 * F.D, account = "alice" }),
		}
		local doc = F.doc(now)
		doc.providers.anthropic = F.provider("anthropic", "Claude", alice, now, { accounts = { "alice", "bob" } })
		local data = setup(doc, { ["omp-usage.mode"] = "all", ["omp-usage.account"] = { anthropic = "\1combined" } })
		local group = model_of(data, F.dock(nil, nil)).groups[1]
		eq(group.details[1], { text = "1 of 2 accounts · no current numbers for bob", kind = "stale", whole = true }, "the note")
		eq(group.windows[1].label, "alice 5h", "a group of one keeps the account's name")
	end)

	it("redraws when only what a window covers changes", function()
		local now = NOW
		local function with_bob(bob_has_7d: boolean): any
			local ws = {
				F.win({ label = "alice 5h", key = "5h", ms = 5 * F.H, r = 0.55, at = now + 2 * F.H, account = "alice" }),
				F.win({ label = "alice 7d", key = "7d", ms = 7 * F.D, r = 0.38, at = now + 3 * F.D, account = "alice" }),
				F.win({ label = "bob 5h", key = "5h", ms = 5 * F.H, r = 0.55, at = now + 2 * F.H, account = "bob" }),
			}
			if bob_has_7d then
				table.insert(ws, F.win({ label = "bob 7d", key = "7d", ms = 7 * F.D, r = 0.38, at = now + 3 * F.D, account = "bob" }))
			end
			local doc = F.doc(now)
			doc.providers.anthropic = F.provider("anthropic", "Claude", ws, now, { accounts = { "alice", "bob" } })
			return doc
		end
		local data, w = setup(with_bob(false), { ["omp-usage.mode"] = "all", ["omp-usage.account"] = { anthropic = "\1combined" } })
		local a = model_of(data, F.dock(nil, nil))
		w:write_cache(with_bob(true))
		local b = model_of(data, F.dock(nil, nil))
		eq({ a.groups[1].windows[2].covers, b.groups[1].windows[2].covers }, { "1 of the 2 accounts", nil }, "covers")
		eq(a.groups[1].windows[2].pct, b.groups[1].windows[2].pct, "same share")
		ok(a.signature ~= b.signature, "the signature changes")
	end)
end)

describe("alert_candidates", function()
	-- the candidate for one window, by its id
	local function by_id(list: { any }, id: string): any
		for _, item in list do
			if item.id == id then
				return item
			end
		end
		return nil
	end

	it("lists each window that hasn't reset, by provider and label, with its share and stated reset time", function()
		local claude = F.claude(NOW, { r5 = 0.2 })
		local data = setup(F.doc(NOW, { claude = claude, resets = {} }))
		local list = data.alert_candidates(data.now_ms())
		eq(#list, 3, "every window, low or not")
		local five = by_id(list, "anthropic/5h")
		eq(
			{ five.kind, five.provider_label, five.label, five.remaining, five.resets_at, five.stated },
			{ "window", "Claude", "5h", 0.2, claude[1].at, true }
		)
		eq(by_id(list, "anthropic/7d").remaining, 0.41, "7d")
	end)

	it("lists a saved reset expiring within a day, not one further off or gone", function()
		local now = NOW
		local data = setup(F.doc(now, {
			resets = {
				{ expiresAt = now + 5 * F.H, count = 1, window = "7d" },
				{ expiresAt = now + 25 * F.H, count = 1, window = "7d" },
				{ expiresAt = now - F.H, count = 1, window = "7d" },
			},
		}))
		local saved: { any } = {}
		for _, item in data.alert_candidates(data.now_ms()) do
			if item.kind == "saved_reset_expiring" then
				table.insert(saved, item)
			end
		end
		eq(#saved, 1, "one")
		eq({ saved[1].id, saved[1].expires_at }, { "anthropic/7d@" .. tostring(now + 5 * F.H), now + 5 * F.H })
	end)

	it("leaves out numbers past 30 minutes old and windows whose reset has passed", function()
		local stale = setup(F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.05 }), observed = NOW - 31 * F.M, resets = {} }))
		eq(#stale.alert_candidates(stale.now_ms()), 0, "stale")
		local passed = setup(F.doc(NOW, { claude = F.claude(NOW, { r5 = 0.05, in5 = -F.M }), resets = {} }))
		local list = passed.alert_candidates(passed.now_ms())
		eq(by_id(list, "anthropic/5h"), nil, "passed")
		eq(#list, 2, "the others stay")
	end)

	-- omp states some resets to the millisecond from a countdown at fetch time (the real cache had Claude's Fable 7d at
	-- …27999873, 127 ms before a whole minute): the id leaves the reset time out, so one fetch's time on each side of
	-- a minute is the same window (alerts.luau tells the periods apart by `resets_at`).
	it("keeps a window's id when its stated reset time moves by less than a second across a minute", function()
		local claude = F.claude(NOW, { r5 = 0.2 })
		claude[1].at = 1795427999873
		local data, w = setup(F.doc(NOW, { claude = claude, resets = {} }))
		local first = by_id(data.alert_candidates(data.now_ms()), "anthropic/5h")
		local moved = F.claude(NOW, { r5 = 0.2 })
		moved[1].at = 1795428000250
		w:write_cache(F.doc(w.epoch_ms, { claude = moved, written = w.epoch_ms, resets = {} }))
		local again = by_id(data.alert_candidates(data.now_ms()), "anthropic/5h")
		eq({ first.resets_at, again.resets_at }, { 1795427999873, 1795428000250 }, "each fetch's reset time")
	end)

	it("lists a window without any reset time with no `resets_at`", function()
		local claude = F.claude(NOW, { r5 = 0.2 })
		claude[1].at = nil
		local data = setup(F.doc(NOW, { claude = claude, resets = {} }))
		local five = by_id(data.alert_candidates(data.now_ms()), "anthropic/5h")
		eq({ five.remaining, five.resets_at, five.stated }, { 0.2, nil, nil })
	end)
end)

-- The compact layout (usage-remaining.js `compactEntry`): a model entry names its provider and carries only what
-- differs from the provider's entry: `windows` as indexes into the provider's (0-based) or whole windows, `text` when
-- the line isn't the provider's label and the windows' pieces, `resets` and `details` the same way.
local function compact_doc(now: number): any
	local claude = F.claude(now)
	local doc = F.doc(now, { claude = claude })
	local base = json.array({})
	for _, w in claude do
		local item = F.cache_window(w)
		item.text = F.piece(w, now, nil)
		table.insert(base, item)
	end
	doc.providers.anthropic.windows = base
	local spark = F.win({ label = "Spark 5h", key = "5h", ms = 5 * F.H, r = 0.5, at = now + F.H, scope = "Spark" })
	local spark_item = F.cache_window(spark)
	spark_item.text = F.piece(spark, now, nil)
	doc.models = {
		["Opus 5.5"] = { provider = "anthropic" },
		["Haiku 5.5"] = { provider = "anthropic", windows = json.array({ 0, 1 }) },
		["Sonnet 5.5"] = { provider = "anthropic", windows = json.array({ 0, spark_item }) },
		["Broken 5"] = { provider = "anthropic", windows = json.array({ 0, 7 }) },
		["Orphan 5"] = { provider = "nowhere" },
	}
	return doc
end

describe("build_model, compact model entries", function()
	it("reads an entry that is its provider's view as the provider's line, saved resets and all", function()
		local data = setup(compact_doc(NOW))
		local model = model_of(data, F.dock("Opus 5.5", STATUS))
		eq(model.source, "model:Opus 5.5", "from the cache")
		eq(shares_of(model.groups[1]), { ["5h"] = "62", ["7d"] = "41", ["Fable 7d"] = "83" }, "windows")
		eq(#(model.groups[1].resets or {}), 1, "the provider's saved reset")
	end)

	it("reads windows by index into the provider's, and whole windows of its own", function()
		local data = setup(compact_doc(NOW))
		eq(shares_of(model_of(data, F.dock("Haiku 5.5", STATUS)).groups[1]), { ["5h"] = "62", ["7d"] = "41" }, "a subset")
		eq(shares_of(model_of(data, F.dock("Sonnet 5.5", STATUS)).groups[1]), { ["5h"] = "62", ["Spark 5h"] = "50" }, "its own window")
	end)

	it("treats an entry that doesn't resolve as missing: the status, never other numbers", function()
		local data = setup(compact_doc(NOW))
		eq(model_of(data, F.dock("Broken 5", STATUS)).source, "status", "an index the provider doesn't have")
		eq(model_of(data, F.dock("Orphan 5", STATUS)).source, "status", "a provider the file doesn't have")
	end)
end)

describe("the 0.7.10 reader (copies that haven't updated) on today's cache", function()
	local function released(doc: any): any
		if not H.has_source("v0.7.10/data.luau") then
			T.skip("needs git and commit 24208a0")
		end
		local w = H.world({ now = NOW, release = "v0.7.10" })
		local data = w:load("data")
		w:write_cache(doc)
		return data
	end

	it("falls back to the status for compact entries, never showing other numbers", function()
		local data = released(compact_doc(NOW))
		for _, chip in { "Opus 5.5", "Haiku 5.5", "Sonnet 5.5" } do
			local model = model_of(data, F.dock(chip, STATUS))
			eq({ model.source, shares_of(model.groups[1]) }, { "status", { ["5h"] = "33", ["7d"] = "77" } }, chip)
		end
	end)

	it("still reads whole schema-2 entries", function()
		local data = released(F.doc(NOW))
		local model = model_of(data, F.dock("Opus 5.5", STATUS))
		eq({ model.source, shares_of(model.groups[1]) }, { "model:Opus 5.5", { ["5h"] = "62", ["7d"] = "41", ["Fable 7d"] = "83" } })
	end)
end)

return true -- run.mjs checks it: the Luau CLI's `require` returns a file's compile error instead of raising it
