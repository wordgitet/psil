--[[
SPDX-License-Identifier: MPL-2.0
]]

local errors = require("./errors")
local value = require("./value")

local env = {}

function env.new(parent)
	return {
		parent = parent,
		values = {},
	}
end

function env.define(scope, name, item)
	scope.values[name] = item
	return item
end

function env.find_frame(scope, name)
	local frame = scope

	while frame ~= nil do
		if frame.values[name] ~= nil then
			return frame
		end

		frame = frame.parent
	end

	return nil
end

function env.get(scope, name)
	local frame = env.find_frame(scope, name)

	if frame == nil then
		errors.raise("name", string.format("undefined symbol '%s'", name))
	end

	local item = frame.values[name]

	if value.is_uninitialized(item) then
		errors.raise(
			"name",
			string.format("letrec binding '%s' accessed before initialization", name)
		)
	end

	return item
end

function env.set(scope, name, item)
	local frame = env.find_frame(scope, name)

	if frame == nil then
		errors.raise("name", string.format("cannot set undefined symbol '%s'", name))
	end

	frame.values[name] = item
	return item
end

function env.extend(parent, names, values)
	if #names ~= #values then
		errors.raise(
			"arity",
			string.format("expected %d arguments, got %d", #names, #values)
		)
	end

	local child = env.new(parent)

	for index, name in ipairs(names) do
		child.values[name] = values[index]
	end

	return child
end

return env