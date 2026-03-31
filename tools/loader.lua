--[[
SPDX-License-Identifier: MPL-2.0
]]

local loader = {}

local cache = {}

local function file_exists(path)
	local handle = io.open(path, "r")

	if handle == nil then
		return false
	end

	handle:close()
	return true
end

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

local function resolve_path(base_path, spec)
	local root = normalize(dirname(base_path) .. "/" .. spec)
	local candidates = {
		root,
		root .. ".luau",
		root .. ".lua",
		root .. "/init.luau",
		root .. "/init.lua",
	}

	for _, candidate in ipairs(candidates) do
		if file_exists(candidate) then
			return candidate
		end
	end

	error(string.format("unable to resolve module '%s' from '%s'", spec, base_path), 0)
end

function loader.make_require(current_path)
	return function(spec)
		if type(spec) ~= "string" then
			return _G.require(spec)
		end

		if not string.match(spec, "^%.") then
			return _G.require(spec)
		end

		local resolved = resolve_path(current_path, spec)

		if cache[resolved] ~= nil then
			return cache[resolved]
		end

		local env = setmetatable({}, {
			__index = _G,
		})

		env.require = loader.make_require(resolved)

		local chunk, load_err = loadfile(resolved, "t", env)

		if chunk == nil then
			error(load_err, 0)
		end

		local result = chunk()

		if result == nil then
			result = true
		end

		cache[resolved] = result
		return result
	end
end

function loader.run(entry_path, argv)
	local env = setmetatable({}, {
		__index = _G,
	})

	env.require = loader.make_require(entry_path)

	local chunk, load_err = loadfile(entry_path, "t", env)

	if chunk == nil then
		error(load_err, 0)
	end

	return chunk(table.unpack(argv or {}))
end

function loader.normalize(path)
	return normalize(path)
end

function loader.dirname(path)
	return dirname(path)
end

return loader