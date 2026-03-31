--[[
SPDX-License-Identifier: MPL-2.0
]]

local env = require("./env")
local errors = require("./errors")
local value = require("./value")

local bind = {}

local function validate_symbol(item, label)
	if not value.is_symbol(item) then
		errors.raise("type", label)
	end

	return item.name
end

function bind.parse_param_spec(params_form)
	if value.is_symbol(params_form) then
		return value.param_spec({}, params_form.name, {})
	end

	if not value.is_list(params_form) then
		errors.raise("type", "lambda parameters must be a list or symbol")
	end

	local fixed = {}

	for index, param in ipairs(params_form.items) do
		fixed[index] = validate_symbol(param, "lambda parameters must be symbols")
	end

	local rest = nil

	if params_form.tail ~= nil then
		rest = validate_symbol(params_form.tail, "lambda rest parameter must be a symbol")
	end

	return value.param_spec(fixed, rest, {})
end

function bind.bind_args(parent_scope, param_spec, args)
	local scope = env.new(parent_scope)
	local fixed = param_spec.fixed or {}
	local rest = param_spec.rest

	if rest == nil and #fixed ~= #args then
		errors.raise(
			"arity",
			string.format("expected %d arguments, got %d", #fixed, #args)
		)
	end

	if rest ~= nil and #args < #fixed then
		errors.raise(
			"arity",
			string.format("expected at least %d arguments, got %d", #fixed, #args)
		)
	end

	for index, name in ipairs(fixed) do
		env.define(scope, name, args[index])
	end

	if rest ~= nil then
		local rest_items = {}

		for index = #fixed + 1, #args do
			table.insert(rest_items, args[index])
		end

		env.define(scope, rest, value.list(rest_items))
	end

	return scope
end

return bind