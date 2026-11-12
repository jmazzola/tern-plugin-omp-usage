--!strict
-- 0.5.0 moved the plugin from this folder to the repo's root, so `tern plugin install` takes the repo's URL. A clone
-- linked before then still links this folder, which its update left with only this: it links the root instead, once,
-- and Tern loads the plugin from there. Remove this folder once clones from before 0.5.0 have updated.

local root = string.match(tern.plugin.dir, "^(.*)[/\\][^/\\]+[/\\]?$") or (tern.plugin.dir .. "/..")
local command = "tern plugin link " .. root

tern.timer(0, function(cx: WindowCx?)
	local ok = pcall(tern.process.run, { "tern", "plugin", "link", root }, nil, function(result: ProcessResult, later: WindowCx?)
		local at = later or cx
		if at == nil then
			return
		end
		if result.status == 0 then
			at:toast("success", "omp Usage moved to its repo's root", "Linked it there; no need to do anything")
		else
			at:toast("error", "omp Usage moved to its repo's root", "Link it there: " .. command)
		end
	end)
	if not ok and cx then
		cx:toast("error", "omp Usage moved to its repo's root", "Link it there: " .. command)
	end
end)
