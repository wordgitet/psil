--[[
SPDX-License-Identifier: MPL-2.0
]]

local function dirname(path)
	return path:match("^(.*)/[^/]+$") or "."
end

local function normalize(path)
	local prefix = ""

	if string.sub(path, 1, 1) == "/" then
		prefix = "/"
	end

	local parts = {}

	for part in string.gmatch(path, "[^/]+") do
		if part == "." then
			-- Skip.
		elseif part == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		else
			table.insert(parts, part)
		end
	end

	if prefix == "/" then
		return prefix .. table.concat(parts, "/")
	end

	if #parts == 0 then
		return "."
	end

	return table.concat(parts, "/")
end

local script_path = arg[0]
local root = normalize(dirname(script_path) .. "/..")
local loader = dofile(root .. "/tools/loader.lua")

loader.run(root .. "/tests/run.luau", {})