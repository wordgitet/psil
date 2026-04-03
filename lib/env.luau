--[[
SPDX-License-Identifier: MPL-2.0
]]

local errors = require("./errors")
local value = require("./value")

local env = {}

function env.new(parent, options)
	local opts = options or {}
	return {
		parent = parent,
		values = {},
		dialect = opts.dialect or (parent ~= nil and parent.dialect) or "scheme",
		specials = opts.specials,
		meta = opts.meta or (parent ~= nil and parent.meta) or {
			docs = {},
			cl_global_specials = {},
		},
	}
end

function env.dialect(scope)
	if scope ~= nil and scope.dialect ~= nil then
		return scope.dialect
	end

	return "scheme"
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

function env.root(scope)
	local frame = scope

	while frame ~= nil and frame.parent ~= nil do
		frame = frame.parent
	end

	return frame
end

function env.mark_specials(scope, names)
	scope.specials = scope.specials or {}

	if #names > 0 then
		for _, name in ipairs(names) do
			scope.specials[name] = true
		end
	else
		for name, enabled in pairs(names) do
			if enabled then
				scope.specials[name] = true
			end
		end
	end

	return scope.specials
end

function env.has_special(scope, name)
	return scope ~= nil and scope.specials ~= nil and scope.specials[name] == true
end

function env.mark_global_special(scope, name)
	scope.meta.cl_global_specials = scope.meta.cl_global_specials or {}
	scope.meta.cl_global_specials[name] = true
	return true
end

function env.is_global_special(scope, name)
	return scope ~= nil
		and scope.meta ~= nil
		and scope.meta.cl_global_specials ~= nil
		and scope.meta.cl_global_specials[name] == true
end

function env.unbind(scope, name)
	local frame = env.find_frame(scope, name)

	if frame ~= nil then
		frame.values[name] = nil
	end

	return nil
end

function env.set_doc(scope, namespace, name, item)
	scope.meta.docs[string.format("%s:%s", namespace, name)] = item
	return item
end

function env.get_doc(scope, namespace, name)
	return scope.meta.docs[string.format("%s:%s", namespace, name)]
end

return env
