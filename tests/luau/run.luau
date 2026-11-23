--!strict
-- Entry point for the Luau tests: tests/luau/run.mjs runs this in a temp folder beside `sources.luau` (the plugin's
-- files) and `specs.luau` (requires every *.spec.luau). Program arguments: an optional filter.
local T = require("./t")
require("./specs")

local filter: string? = ...
if not T.run(filter) then
	error("Luau tests failed", 0)
end
