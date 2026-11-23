--!strict
-- A small test runner for the Luau tests: `describe`, `it`, and `defect` for a test that pins a known defect (it
-- fails today; the run reports it as known and stays green, and an unexpected pass fails the run so the marker
-- goes once the defect is fixed). Assertions raise with what was expected and what came.
local T = {}

type Case = { suite: string, name: string, fn: () -> (), defect: string? }
local cases: { Case } = {}
local suite_name = ""

function T.describe(name: string, body: () -> ())
	local outer = suite_name
	suite_name = if outer == "" then name else outer .. " › " .. name
	body()
	suite_name = outer
end

function T.it(name: string, fn: () -> ())
	table.insert(cases, { suite = suite_name, name = name, fn = fn })
end

-- A test of what the code should do but doesn't yet, tied to a defect id from the QA report.
function T.defect(id: string, name: string, fn: () -> ())
	table.insert(cases, { suite = suite_name, name = name, fn = fn, defect = id })
end

local function show(value: any, depth: number?): string
	local d = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) ~= "table" then
		return tostring(value)
	elseif d > 3 then
		return "{…}"
	end
	local keys: { any } = {}
	for key in value do
		table.insert(keys, key)
	end
	table.sort(keys, function(a: any, b: any): boolean
		if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then
			return a < b
		end
		return type(a) < type(b)
	end)
	local parts: { string } = {}
	for _, key in keys do
		local shown_key = if type(key) == "number" then "" else tostring(key) .. " = "
		table.insert(parts, shown_key .. show(value[key], d + 1))
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end
T.show = show

local function deep_equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not deep_equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function T.eq(actual: any, expected: any, what: string?)
	if not deep_equal(actual, expected) then
		error(string.format("%s\n      expected: %s\n      got:      %s", what or "values differ", show(expected), show(actual)), 2)
	end
end

function T.ok(value: any, what: string?)
	if not value then
		error((what or "expected a true value") .. ", got " .. show(value), 2)
	end
end

function T.near(actual: number?, expected: number, tolerance: number, what: string?)
	if actual == nil or math.abs((actual :: number) - expected) > tolerance then
		error(string.format("%s\n      expected: %s ± %s\n      got:      %s", what or "numbers differ", tostring(expected), tostring(tolerance), tostring(actual)), 2)
	end
end

function T.matches(actual: string?, pattern: string, what: string?)
	if type(actual) ~= "string" or string.find(actual :: string, pattern) == nil then
		error(string.format("%s\n      expected to match: %s\n      got:               %s", what or "string doesn't match", pattern, show(actual)), 2)
	end
end

-- Ends the running test as skipped (a tool or a file it needs isn't there), saying why.
function T.skip(why: string)
	error({ skip = why }, 0)
end

-- Runs every case whose suite or name contains `filter` (all without one); returns whether the run passed.
function T.run(filter: string?): boolean
	local passed, failed, known, fixed, skipped = 0, 0, 0, 0, 0
	local failures: { string } = {}
	local known_list: { string } = {}
	for _, case in cases do
		local full = (if case.suite ~= "" then case.suite .. " › " else "") .. case.name
		if filter == nil or filter == "" or string.find(full, filter, 1, true) then
			local ok, err = pcall(case.fn)
			if not ok and type(err) == "table" and err.skip then
				skipped += 1
				print("  skip   " .. full .. " (" .. tostring(err.skip) .. ")")
			elseif case.defect then
				if ok then
					fixed += 1
					table.insert(failures, "UNEXPECTED PASS (" .. case.defect .. " looks fixed: drop the marker) " .. full)
					print("  FIXED? " .. full)
				else
					known += 1
					table.insert(known_list, case.defect .. "  " .. full .. "\n      " .. tostring(err))
					print("  known  " .. case.defect .. "  " .. full)
				end
			elseif ok then
				passed += 1
				print("  ok     " .. full)
			else
				failed += 1
				table.insert(failures, full .. "\n      " .. tostring(err))
				print("  FAIL   " .. full)
			end
		end
	end
	print("")
	if #known_list > 0 then
		print("Known defects (failing as expected):")
		for _, line in known_list do
			print("  " .. line)
		end
		print("")
	end
	if #failures > 0 then
		print("Failures:")
		for _, line in failures do
			print("  " .. line)
		end
		print("")
	end
	print(string.format("%d passed, %d failed, %d known defects, %d unexpected passes, %d skipped", passed, failed, known, fixed, skipped))
	return failed == 0 and fixed == 0
end

return T
