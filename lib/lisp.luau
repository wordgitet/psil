--[[
SPDX-License-Identifier: MPL-2.0
]]

local builtins = require("./builtins")
local env = require("./env")
local evaluator = require("./eval")
local expand = require("./expand")
local printer = require("./printer")
local reader = require("./reader")
local vm = require("./vm")

local lisp = {}

function lisp.parse(source, options)
	return reader.read(source, options)
end

function lisp.eval(source_or_form, scope, execution)
	local env_scope = scope or env.new(nil)
	local run_execution = execution or evaluator.new_execution()

	if type(source_or_form) == "string" then
		return evaluator.eval_source(source_or_form, env_scope, run_execution)
	end

	return evaluator.eval_form(source_or_form, env_scope, run_execution)
end

function lisp.compile(source_or_form, scope)
	local env_scope = scope or env.new(nil)

	if type(source_or_form) == "string" then
		local forms = reader.read_all(source_or_form, {
			dialect = env.dialect(env_scope),
		})
		local expanded = {}

		for index, form in ipairs(forms) do
			expanded[index] = expand.form(form, env_scope)
		end

		return vm.compile_forms(expanded, env_scope)
	end

	return vm.compile_form(expand.form(source_or_form, env_scope), env_scope)
end

function lisp.try_compile(source_or_form, scope)
	local env_scope = scope or env.new(nil)

	if type(source_or_form) == "string" then
		local forms = reader.read_all(source_or_form, {
			dialect = env.dialect(env_scope),
		})
		local expanded = {}

		for index, form in ipairs(forms) do
			expanded[index] = expand.form(form, env_scope)
		end

		return vm.try_compile_forms(expanded, env_scope)
	end

	return vm.try_compile_form(expand.form(source_or_form, env_scope), env_scope)
end

function lisp.run_chunk(chunk, scope, execution)
	local env_scope = scope or env.new(nil)
	local run_execution = execution or evaluator.new_execution()
	return vm.run_chunk(chunk, env_scope, run_execution, evaluator.apply_callable_direct)
end

function lisp.expand(source_or_form, scope)
	local env_scope = scope or env.new(nil)

	if type(source_or_form) == "string" then
		return expand.form(reader.read(source_or_form, {
			dialect = env.dialect(env_scope),
		}), env_scope)
	end

	return expand.form(source_or_form, env_scope)
end

function lisp.new_env(parent, options)
	return env.new(parent, options)
end

function lisp.add_builtins(scope, io_adapter)
	return builtins.add(scope, io_adapter)
end

function lisp.new_execution(options)
	return evaluator.new_execution(options)
end

function lisp.to_string(item, options)
	return printer.to_string(item, options)
end

return lisp
