--> Build a Roblox-safe Psil module tree for Rojo sync.

local fs = require("@lune/fs")

local generated_root = "generated/roblox"
local package_root = generated_root .. "/ReplicatedStorage/Psil"

local function read(path)
	return fs.readFile(path)
end

local function write(path, contents)
	fs.writeFile(path, contents)
end

local function rewrite_lib_requires(source)
	return (source:gsub('require%("%./([%w_]+)"%)', "require(script.Parent.%1)"))
end

local function rewrite_roblox_requires(source)
	source = source:gsub(
		'require%("%./([%w_]+)"%)',
		"require(script.Parent.%1)"
	)
	source = source:gsub(
		'require%("%.%./lib/([%w_]+)"%)',
		"require(script.Parent.%1)"
	)
	return source
end

local function rewrite_roblox_root_requires(source)
	source = source:gsub('require%("%./([%w_]+)"%)', "require(script.%1)")
	source = source:gsub(
		'require%("%.%./lib/([%w_]+)"%)',
		"require(script.%1)"
	)
	return source
end

local function ensure_clean_dir(path)
	if fs.isDir(path) then
		fs.removeDir(path)
	end

	fs.writeDir(path)
end

local function build_lib_modules()
	for _, name in fs.readDir("lib") do
		if string.match(name, "%.luau$") and name ~= "init.luau" then
			local source = read("lib/" .. name)
			write(package_root .. "/" .. name, rewrite_lib_requires(source))
		end
	end
end

local function build_roblox_modules()
	for _, name in fs.readDir("roblox") do
		if string.match(name, "%.luau$")
			and string.match(name, "%.client%.luau$") == nil
			and string.match(name, "%.server%.luau$") == nil then
			local source = read("roblox/" .. name)
			local rewritten = rewrite_roblox_requires(source)

			if name == "init.luau" then
				rewritten = rewrite_roblox_root_requires(source)
			end

			write(
				package_root .. "/" .. name,
				rewritten
			)
		end
	end
end

ensure_clean_dir(generated_root)
fs.writeDir(generated_root .. "/ReplicatedStorage")
fs.writeDir(package_root)

build_lib_modules()
build_roblox_modules()

print("built Roblox package at " .. package_root)
--[[
SPDX-License-Identifier: MPL-2.0
]]
