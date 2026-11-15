--!strict
-- 0.5.0 moved the plugin from this folder to the repo's root, so `tern plugin install` takes the repo's URL. A clone
-- linked before then still links this folder, which its update left with only this: it links the root instead, once,
-- and Tern loads the plugin from there. Remove this folder once clones from before 0.5.0 have updated.

local root = string.match(tern.plugin.dir, "^(.*)[/\\][^/\\]+[/\\]?$") or (tern.plugin.dir .. "/..")
local failed = 'Link it yourself: tern plugin link "' .. root .. '"'

tern.timer(0, function(cx: WindowCx?)
	-- Said before linking: a link that works reloads the plugins, which ends this VM before the link's own end
	-- could reach it. Only a failure comes back here.
	if cx then
		cx:toast("info", "omp Usage moved to its repo's root", "Linking the repo folder in its place; no need to do anything")
	end
	local ok = pcall(tern.process.run, { "tern", "plugin", "link", root }, nil, function(result: ProcessResult, later: WindowCx?)
		local at = later or cx
		if at and result.status ~= 0 then
			at:toast("error", "omp Usage couldn't link its repo's root", failed)
		end
	end)
	if not ok and cx then
		cx:toast("error", "omp Usage couldn't link its repo's root", failed)
	end
end)
