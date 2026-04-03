--[[
SPDX-License-Identifier: MPL-2.0
]]

local env = require("./env")
local errors = require("./errors")
local value = require("./value")

local bind = {}
local cl_lambda_markers = {
	["&optional"] = true,
	["&rest"] = true,
	["&key"] = true,
	["&aux"] = true,
}

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
	local optional = {}
	local key_params = {}
	local aux = {}
	local cl_style = false
	local mode = "fixed"
	local rest = nil

	local function parse_binding_spec(item, label)
		if value.is_symbol(item) then
			return {
				name = item.name,
				init = nil,
			}
		end

		if not value.is_list(item) or #item.items == 0 or not value.is_symbol(item.items[1]) then
			errors.raise("type", label)
		end

		return {
			name = item.items[1].name,
			init = item.items[2],
			supplied = value.is_symbol(item.items[3]) and item.items[3].name or nil,
		}
	end

	for _, param in ipairs(params_form.items) do
		if value.is_symbol(param) and cl_lambda_markers[param.name] then
			cl_style = true
			mode = string.sub(param.name, 2)
		elseif mode == "fixed" then
			fixed[#fixed + 1] = validate_symbol(param, "lambda parameters must be symbols")
		elseif mode == "optional" then
			optional[#optional + 1] = parse_binding_spec(
				param,
				"lambda optional parameters must be symbols or (name init [supplied])"
			)
		elseif mode == "rest" then
			if rest ~= nil then
				errors.raise("type", "lambda may only declare one &rest parameter")
			end

			rest = validate_symbol(param, "lambda rest parameter must be a symbol")
			mode = "post_rest"
		elseif mode == "key" then
			key_params[#key_params + 1] = parse_binding_spec(
				param,
				"lambda keyword parameters must be symbols or (name init [supplied])"
			)
		elseif mode == "aux" or mode == "post_rest" then
			aux[#aux + 1] = parse_binding_spec(
				param,
				"lambda aux parameters must be symbols or (name init)"
			)
		else
			errors.raise("type", "unsupported lambda list syntax")
		end
	end

	if params_form.tail ~= nil then
		rest = validate_symbol(params_form.tail, "lambda rest parameter must be a symbol")
	end

	return value.param_spec(fixed, rest, {
		cl = cl_style,
		optional = optional,
		keys = key_params,
		aux = aux,
	})
end

local function bind_default(scope, spec, eval_default, execution)
	if spec.init == nil then
		return value.list({})
	end

	return eval_default(spec.init, scope, execution)
end

local function bind_supplied(scope, name, supplied)
	if name ~= nil then
		env.define(scope, name, supplied and true or value.list({}))
	end
end

local function bind_cl_args_common(parent_scope, param_spec, args, eval_default, execution)
	local scope = env.new(parent_scope)
	local fixed = param_spec.fixed or {}
	local rest = param_spec.rest
	local extra = param_spec.keywords or {}
	local optional = extra.optional or {}
	local keys = extra.keys or {}
	local aux = extra.aux or {}
	local arg_index = 1

	if #args < #fixed then
		errors.raise(
			"arity",
			string.format("expected at least %d arguments, got %d", #fixed, #args)
		)
	end

	for _, name in ipairs(fixed) do
		env.define(scope, name, args[arg_index])
		arg_index = arg_index + 1
	end

	for _, spec in ipairs(optional) do
		if arg_index <= #args and not (value.is_symbol(args[arg_index]) and string.sub(args[arg_index].name, 1, 1) == ":") then
			env.define(scope, spec.name, args[arg_index])
			bind_supplied(scope, spec.supplied, true)
			arg_index = arg_index + 1
		else
			env.define(scope, spec.name, bind_default(scope, spec, eval_default, execution))
			bind_supplied(scope, spec.supplied, false)
		end
	end

	local remaining = {}

	for index = arg_index, #args do
		remaining[#remaining + 1] = args[index]
	end

	if #keys > 0 then
		if #remaining % 2 ~= 0 then
			errors.raise("arity", "keyword arguments must appear in pairs")
		end

		local key_values = {}
		local key_supplied = {}

		for index = 1, #remaining, 2 do
			local key = remaining[index]
			local value_now = remaining[index + 1]

			if not value.is_symbol(key) or string.sub(key.name, 1, 1) ~= ":" then
				errors.raise("type", "keyword arguments must use keyword symbols")
			end

			key_values[key.name] = value_now
			key_supplied[key.name] = true
		end

		for _, spec in ipairs(keys) do
			local keyword_name = ":" .. spec.name

			if key_supplied[keyword_name] then
				env.define(scope, spec.name, key_values[keyword_name])
				bind_supplied(scope, spec.supplied, true)
			else
				env.define(scope, spec.name, bind_default(scope, spec, eval_default, execution))
				bind_supplied(scope, spec.supplied, false)
			end
		end

		if rest ~= nil then
			env.define(scope, rest, value.list(remaining))
		elseif #remaining > 0 then
			errors.raise("arity", string.format("unexpected keyword arguments, got %d extra arguments", #remaining))
		end
	elseif rest ~= nil then
		env.define(scope, rest, value.list(remaining))
	elseif #remaining > 0 then
		errors.raise(
			"arity",
			string.format("expected %d arguments, got %d", #fixed + #optional, #args)
		)
	end

	for _, spec in ipairs(aux) do
		env.define(scope, spec.name, bind_default(scope, spec, eval_default, execution))
	end

	return scope
end

function bind.bind_args(parent_scope, param_spec, args)
	if param_spec.keywords ~= nil and param_spec.keywords.cl then
		errors.raise("type", "CL lambda lists need bind_cl_args in this path")
	end

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

function bind.bind_cl_args(parent_scope, param_spec, args, eval_default, execution)
	return bind_cl_args_common(parent_scope, param_spec, args, eval_default, execution)
end

return bind
