--[[
SPDX-License-Identifier: MPL-2.0
]]

--!native
--!optimize 2

-- Core evaluator for Psil's Scheme runtime.
-- This module owns ordinary evaluation, special-form semantics, the CPS bridge
-- used for re-entrant continuations, and dynamic-wind-aware control transfers.

local bind = require("./bind")
local builtins = require("./builtins")
local env = require("./env")
local errors = require("./errors")
local expand = require("./expand")
local reader = require("./reader")
local syntax_rules = require("./syntax_rules")
local value = require("./value")
local vm = require("./vm")

local evaluator = {}
local special_forms = {}
local special_forms_cps = {}
local install_syntax_callable_wrappers
local setq_like
local cl_only_special_forms = {
	block = true,
	decf = true,
	declare = true,
	defparameter = true,
	defvar = true,
	dolist = true,
	flet = true,
	["function"] = true,
	go = true,
	["ignore-errors"] = true,
	incf = true,
	locally = true,
	loop = true,
	macrolet = true,
	prog = true,
	["return-from"] = true,
	["return"] = true,
	["signals-error"] = true,
	setf = true,
	setq = true,
	tagbody = true,
}
local eval_expanded_form
local eval_form
local eval_expanded_form_cps
local eval_form_cps
local apply_callable_cps
local run_cps
local eval_expanded_sequence_cps
local expand_syntax_binding
local apply_callable_direct
local eval_sequence_direct
local eval_form_direct
local eval_expanded_form_direct
local eval_expanded_sequence_direct
local cl_compat_enabled
local collect_special_names

-- Every evaluation path shares the same cooperative budget/cancellation rules
-- so host runs, Roblox runs, and long compatibility-suite cases behave the
-- same way.
local function checkpoint(execution)
	if execution == nil then
		return
	end

	if execution.cancelled then
		errors.raise("interrupt", "evaluation cancelled")
	end

	execution.steps = (execution.steps or 0) + 1

	if execution.step_budget ~= nil then
		execution.step_budget = execution.step_budget - 1

		if execution.step_budget < 0 then
			errors.raise("interrupt", "evaluation budget exceeded")
		end
	end

	if execution.on_yield ~= nil and execution.yield_every ~= nil and execution.yield_every > 0 then
		execution.yield_counter = (execution.yield_counter or 0) + 1

		if execution.yield_counter >= execution.yield_every then
			execution.yield_counter = 0
			execution.on_yield(execution)

			if execution.cancelled then
				errors.raise("interrupt", "evaluation cancelled")
			end
		end
	end
end

local function expect_form_count(name, items, min_count, max_count)
	local count = #items - 1

	if count < min_count or (max_count ~= nil and count > max_count) then
		local expected

		if max_count == nil then
			expected = string.format("at least %d", min_count)
		elseif min_count == max_count then
			expected = tostring(min_count)
		else
			expected = string.format("%d..%d", min_count, max_count)
		end

		errors.raise(
			"arity",
			string.format("%s expected %s arguments, got %d", name, expected, count)
		)
	end
end

local function eval_sequence(forms, scope, _, execution)
	local result = value.list({})
	local eval_form_impl = _ or eval_form_direct or eval_form

	for _, form in ipairs(forms) do
		checkpoint(execution)
		result = eval_form_impl(form, scope, execution)
	end

	return result
end

local function eval_expanded_sequence(forms, scope, execution)
	local result = value.list({})
	local eval_expanded_form_impl = eval_expanded_form_direct or eval_expanded_form

	for _, form in ipairs(forms) do
		checkpoint(execution)
		result = eval_expanded_form_impl(form, scope, execution)
	end

	return result
end

local function apply_callable(callable, args, execution)
	if value.is_builtin(callable) then
		if callable.is_parameter then
			if #args == 0 then
				return callable.current
			end

			if #args ~= 1 then
				errors.raise(
					"arity",
					string.format("%s expected 0..1 arguments, got %d", callable.name, #args)
				)
			end

			local next_value = args[1]

			if callable.converter ~= nil then
				next_value = apply_callable_direct(callable.converter, {
					next_value,
				}, execution)
			end

			callable.current = next_value
			return value.list({})
		end

		if callable.cps then
			return run_cps(execution, function(k)
				return callable.fn(args, apply_callable_cps, execution, k)
			end)
		end

		return callable.fn(args, apply_callable_direct, execution)
	end

	if value.is_closure(callable) then
		if callable.vm_chunk ~= nil then
			return vm.run_chunk(callable.vm_chunk, callable.env, execution, apply_callable_direct, callable.vm_captures, args)
		end

		local call_scope

		if callable.param_spec.keywords ~= nil and callable.param_spec.keywords.cl then
			call_scope = bind.bind_cl_args(callable.env, callable.param_spec, args, eval_form_direct, execution)
		else
			call_scope = bind.bind_args(callable.env, callable.param_spec, args)
		end

		-- Closures can stay on the simpler direct path when their bodies do not
		-- need continuation-aware evaluation. Pre-expanding once per call keeps
		-- local macro definitions visible without re-expanding each form later.
		local body_scope = call_scope
		local body_forms = callable.body

		if cl_compat_enabled(call_scope, execution) then
			local stripped_body, special_names = collect_special_names(callable.body, 1)

			if next(special_names) ~= nil then
				body_scope = env.new(call_scope)
				env.mark_specials(body_scope, special_names)
				body_forms = stripped_body
			elseif #stripped_body ~= #callable.body then
				body_forms = stripped_body
			end
		end

		if callable.preexpand_body then
			local expanded_body = callable.expanded_body

			if expanded_body == nil then
				expanded_body = {}

				for index, form in ipairs(body_forms) do
					expanded_body[index] = expand.form(form, body_scope)
				end
			end

			if callable.needs_cps then
				return run_cps(execution, function(k)
					return eval_expanded_sequence_cps(expanded_body, body_scope, execution, k)
				end)
			end

			return eval_expanded_sequence_direct(expanded_body, body_scope, execution)
		end

		if callable.needs_cps then
			return run_cps(execution, function(k)
				return eval_sequence_cps(body_forms, body_scope, execution, k)
			end)
		end

		return eval_sequence_direct(body_forms, body_scope, eval_form_direct, execution)
	end

	errors.raise("type", "attempted to call a non-function value")
end

local function copy_dynamic_stack(stack)
	local copy = {}

	for index, frame in ipairs(stack or {}) do
		copy[index] = frame
	end

	return copy
end

local function current_dynamic_stack(execution)
	if execution == nil then
		return {}
	end

	execution.dynamic_stack = execution.dynamic_stack or {}
	return execution.dynamic_stack
end

local function stack_contains_frame(stack, frame)
	for _, item in ipairs(stack) do
		if item == frame then
			return true
		end
	end

	return false
end

local function common_dynamic_prefix(left, right)
	local limit = math.min(#left, #right)
	local index = 0

	while index < limit and left[index + 1] == right[index + 1] do
		index = index + 1
	end

	return index
end

-- Normal returns, continuation jumps, and parameter restoration all funnel
-- through the same dynamic-wind transition logic so before/after thunks keep a
-- single ordering model.
local function run_dynamic_transition(execution, from_stack, to_stack)
	local active_from = copy_dynamic_stack(from_stack)
	local active_to = copy_dynamic_stack(to_stack)
	local prefix = common_dynamic_prefix(active_from, active_to)

	for index = #active_from, prefix + 1, -1 do
		apply_callable_direct(active_from[index].after, {}, execution)
	end

	if execution ~= nil then
		execution.dynamic_stack = copy_dynamic_stack(active_from)
	end

	for index = prefix + 1, #active_to do
		apply_callable_direct(active_to[index].before, {}, execution)
	end

	if execution ~= nil then
		execution.dynamic_stack = active_to
	end
end

local function perform_dynamic_wind(before_fn, thunk_fn, after_fn, execution)
	local previous_stack = copy_dynamic_stack(current_dynamic_stack(execution))
	local frame = {
		before = before_fn,
		after = after_fn,
	}
	local entered_stack = copy_dynamic_stack(previous_stack)

	apply_callable_direct(before_fn, {}, execution)
	entered_stack[#entered_stack + 1] = frame

	if execution ~= nil then
		execution.dynamic_stack = entered_stack
	end

	local ok, result = pcall(function()
		return apply_callable_direct(thunk_fn, {}, execution)
	end)
	local active_stack = current_dynamic_stack(execution)

	if stack_contains_frame(active_stack, frame) then
		if execution ~= nil then
			execution.dynamic_stack = previous_stack
		end

		apply_callable_direct(after_fn, {}, execution)
	end

	if ok then
		return result
	end

	error(result, 0)
end

local function normalize_values(item)
	if value.is_multi_values(item) then
		return item.items
	end

	return {
		item,
	}
end

local function bind_clause_values(scope, formals, produced)
	local param_spec = bind.parse_param_spec(formals)
	local clause_scope = bind.bind_args(scope, param_spec, produced)

	for name, item in pairs(clause_scope.values) do
		env.define(scope, name, item)
	end
end

local function binding_scope(scope, symbol)
	if symbol.scope ~= nil then
		return symbol.scope
	end

	return scope
end

local function lookup_binding(scope, symbol)
	local frame = env.find_frame(binding_scope(scope, symbol), symbol.name)

	if frame == nil then
		return nil
	end

	return frame.values[symbol.name]
end

cl_compat_enabled = function(scope, execution)
	if scope ~= nil and scope.dialect == "cl-compat" then
		return true
	end

	if execution ~= nil and execution.dialect == "cl-compat" then
		return true
	end

	return false
end

local function current_special_binding(execution, name)
	local bindings = execution ~= nil and execution.cl_special_bindings or nil
	local stack = bindings ~= nil and bindings[name] or nil

	if stack ~= nil and #stack > 0 then
		return stack[#stack], true
	end

	return nil, false
end

local function with_special_bindings(execution, bindings, fn)
	if execution == nil or #bindings == 0 then
		return fn()
	end

	execution.cl_special_bindings = execution.cl_special_bindings or {}

	for _, binding in ipairs(bindings) do
		local stack = execution.cl_special_bindings[binding.name]

		if stack == nil then
			stack = {}
			execution.cl_special_bindings[binding.name] = stack
		end

		stack[#stack + 1] = binding.value
	end

	local ok, result = pcall(fn)

	for index = #bindings, 1, -1 do
		local name = bindings[index].name
		local stack = execution.cl_special_bindings[name]

		if stack ~= nil then
			stack[#stack] = nil

			if #stack == 0 then
				execution.cl_special_bindings[name] = nil
			end
		end
	end

	if ok then
		return result
	end

	error(result, 0)
end

local function resolve_special_value(scope, name, execution)
	local bound, ok = current_special_binding(execution, name)

	if ok then
		return bound
	end

	local root = env.root(scope)

	if root ~= nil and root.values[name] ~= nil then
		return env.get(root, name)
	end

	return env.get(scope, name)
end

local function use_special_lookup(scope, name, execution)
	return cl_compat_enabled(scope, execution)
		and (env.has_special(scope, name) or env.is_global_special(scope, name))
end

collect_special_names = function(items, start_index)
	local special_names = {}
	local ordered = {}
	local index = start_index

	while index <= #items do
		local item = items[index]

		if not (value.is_list(item) and value.is_symbol(item.items[1]) and item.items[1].name == "declare") then
			break
		end

		for declare_index = 2, #item.items do
			local spec = item.items[declare_index]

			if value.is_list(spec) and value.is_symbol(spec.items[1]) and spec.items[1].name == "special" then
				for symbol_index = 2, #spec.items do
					local symbol = spec.items[symbol_index]

					if value.is_symbol(symbol) and not special_names[symbol.name] then
						special_names[symbol.name] = true
						ordered[#ordered + 1] = symbol.name
					end
				end
			end
		end

		index = index + 1
	end

	local body = {}

	for body_index = index, #items do
		body[#body + 1] = items[body_index]
	end

	return body, special_names, ordered
end

local function add_global_special_bindings(scope, special_names, ordered_names, bindings_form)
	for _, binding in ipairs(bindings_form.items) do
		if value.is_list(binding) and value.is_symbol(binding.items[1]) then
			local name = binding.items[1].name

			if env.is_global_special(scope, name) and not special_names[name] then
				special_names[name] = true
				ordered_names[#ordered_names + 1] = name
			end
		end
	end
end

local function make_special_binding_list(names, values_by_name)
	local bindings = {}

	for _, name in ipairs(names) do
		if values_by_name[name] ~= nil then
			bindings[#bindings + 1] = {
				name = name,
				value = values_by_name[name],
			}
		end
	end

	return bindings
end

local function cl_setter_name(target)
	return string.format("(setf %s)", target)
end

local function closure_simple_place(closure)
	if not value.is_closure(closure) then
		return nil
	end

	if closure.param_spec.keywords ~= nil and closure.param_spec.keywords.cl then
		return nil
	end

	local fixed = closure.param_spec.fixed or {}

	if #fixed ~= 1 or closure.param_spec.rest ~= nil then
		return nil
	end

	local body = closure.body

	if #body == 1
		and value.is_list(body[1])
		and value.is_symbol(body[1].items[1])
		and body[1].items[1].name == "block" then
		local block_items = {}

		for index = 3, #body[1].items do
			block_items[#block_items + 1] = body[1].items[index]
		end

		body = block_items
	end

	if #body ~= 1 then
		return nil
	end

	local form = body[1]

	if not value.is_list(form)
		or #form.items ~= 2
		or not value.is_symbol(form.items[1])
		or not value.is_symbol(form.items[2]) then
		return nil
	end

	if form.items[2].name ~= fixed[1] then
		return nil
	end

	local head_name = form.items[1].name

	if head_name == "car" or head_name == "cdr" then
		return head_name
	end

	return nil
end

local function is_truthy_for_mode(item, scope, execution)
	if value.is_multi_values(item) then
		if #item.items == 0 then
			item = value.list({})
		else
			item = item.items[1]
		end
	end

	if cl_compat_enabled(scope, execution) then
		return item ~= false and not (value.is_list(item) and #item.items == 0 and item.tail == nil)
	end

	return value.is_truthy(item)
end

local function primary_value(item)
	if value.is_multi_values(item) then
		if #item.items == 0 then
			return value.list({})
		end

		return item.items[1]
	end

	return item
end

local function is_cl_keyword_symbol(item, scope, execution)
	return cl_compat_enabled(scope, execution)
		and value.is_symbol(item)
		and string.sub(item.name, 1, 1) == ":"
end

local function cl_function_name(item)
	if value.is_symbol(item) then
		return item.name, item
	end

	if value.is_list(item)
		and #item.items == 2
		and value.is_symbol(item.items[1])
		and item.items[1].name == "setf"
		and value.is_symbol(item.items[2]) then
		return cl_setter_name(item.items[2].name), item.items[2]
	end

	return nil, nil
end

local function find_block_frame(execution, name)
	local blocks = execution.cl_blocks

	if blocks == nil then
		return nil
	end

	for index = #blocks, 1, -1 do
		local frame = blocks[index]

		if frame.name == name then
			return frame
		end
	end

	return nil
end

local function datum_tag_key(item)
	if value.is_symbol(item) then
		return "sym:" .. item.name
	end

	if type(item) == "number" then
		return "num:" .. tostring(item)
	end

	return nil
end

local function find_tagbody_frame(execution, tag_item)
	local tagbodies = execution.cl_tagbodies
	local key = datum_tag_key(tag_item)

	if tagbodies == nil or key == nil then
		return nil
	end

	for index = #tagbodies, 1, -1 do
		local frame = tagbodies[index]

		if frame.tags[key] ~= nil then
			return frame, key
		end
	end

	return nil
end

local function with_block_frame(execution, name, token, fn)
	execution.cl_blocks = execution.cl_blocks or {}
	execution.cl_blocks[#execution.cl_blocks + 1] = {
		name = name,
		token = token,
	}

	local ok, result = pcall(fn)
	table.remove(execution.cl_blocks)

	if ok then
		return result
	end

	if type(result) == "table" and result.kind == "block_return" and result.token == token then
		return result.value
	end

	error(result, 0)
end

local function with_block_frame_cps(execution, name, token, fn, k)
	execution.cl_blocks = execution.cl_blocks or {}
	execution.cl_blocks[#execution.cl_blocks + 1] = {
		name = name,
		token = token,
	}

	local ok, result = pcall(fn)
	table.remove(execution.cl_blocks)

	if ok then
		return result
	end

	if type(result) == "table" and result.kind == "block_return" and result.token == token then
		return k(result.value)
	end

	error(result, 0)
end

local function cl_numeric_delta(name, item)
	if type(item) ~= "number" then
		errors.raise("type", string.format("%s expected numeric values", name))
	end

	return item
end

local function cl_block_name(item)
	if value.is_symbol(item) then
		return item.name
	end

	if value.is_list(item) and #item.items == 0 and item.tail == nil then
		return "nil"
	end

	return nil
end

local function eval_cl_local_function_form(form, scope, eval_form_impl, execution)
	expect_form_count(form.items[1].name, form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", form.items[1].name))
	end

	local local_scope = env.new(scope)

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items < 2 or not value.is_symbol(binding.items[1]) then
			errors.raise("type", string.format("%s bindings must be (name formals body...) lists", form.items[1].name))
		end

		local lambda_items = {
			value.symbol("lambda"),
			binding.items[2],
		}

		for index = 3, #binding.items do
			lambda_items[#lambda_items + 1] = binding.items[index]
		end

		local closure = eval_form_impl(value.list(lambda_items), scope, execution)
		env.define(local_scope, binding.items[1].name, closure)
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", string.format("%s expected at least one body form", form.items[1].name))
	end

		return eval_sequence(body, local_scope, eval_form_impl, execution)
end

local function eval_cl_local_function_form_cps(form, scope, execution, k)
	expect_form_count(form.items[1].name, form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", form.items[1].name))
	end

	local local_scope = env.new(scope)

	local function install_binding(index)
		if index > #bindings_form.items then
			local body = {}

			for body_index = 3, #form.items do
				body[#body + 1] = form.items[body_index]
			end

			if #body == 0 then
				errors.raise("arity", string.format("%s expected at least one body form", form.items[1].name))
			end

			return eval_sequence_cps(body, local_scope, execution, k)
		end

		local binding = bindings_form.items[index]

		if not value.is_list(binding) or #binding.items < 2 or not value.is_symbol(binding.items[1]) then
			errors.raise("type", string.format("%s bindings must be (name formals body...) lists", form.items[1].name))
		end

		local lambda_items = {
			value.symbol("lambda"),
			binding.items[2],
		}

		for body_index = 3, #binding.items do
			lambda_items[#lambda_items + 1] = binding.items[body_index]
		end

		return eval_form_cps(value.list(lambda_items), scope, execution, function(closure)
			env.define(local_scope, binding.items[1].name, closure)
			return install_binding(index + 1)
		end)
	end

	return install_binding(1)
end

local function compile_cl_macro(name, binding, scope)
	local closure_scope = env.new(scope)
	install_syntax_callable_wrappers(closure_scope, scope)

	local lambda_items = {
		value.symbol("lambda"),
		binding.items[2],
	}

	for index = 3, #binding.items do
		lambda_items[#lambda_items + 1] = binding.items[index]
	end

	local closure = evaluator.eval_form(value.list(lambda_items), closure_scope, evaluator.new_execution())

	return value.syntax(name, {
		kind = "cl_macro",
		syntax_name = name,
		definition_scope = scope,
		closure = closure,
	})
end

local function eval_cl_macrolet_form(form, scope, execution)
	expect_form_count("macrolet", form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", "macrolet bindings must be a list")
	end

	local local_scope = env.new(scope)

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items < 2 or not value.is_symbol(binding.items[1]) then
			errors.raise("type", "macrolet bindings must be (name lambda-list body...) lists")
		end

		env.define(local_scope, binding.items[1].name, compile_cl_macro(binding.items[1].name, binding, local_scope))
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", "macrolet expected at least one body form")
	end

		return eval_sequence(body, local_scope, eval_form, execution)
end

local function eval_cl_macrolet_form_cps(form, scope, execution, k)
	expect_form_count("macrolet", form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", "macrolet bindings must be a list")
	end

	local local_scope = env.new(scope)

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items < 2 or not value.is_symbol(binding.items[1]) then
			errors.raise("type", "macrolet bindings must be (name lambda-list body...) lists")
		end

		env.define(local_scope, binding.items[1].name, compile_cl_macro(binding.items[1].name, binding, local_scope))
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", "macrolet expected at least one body form")
	end

	return eval_sequence_cps(body, local_scope, execution, k)
end

local function parse_loop_spec(form)
	local clauses = {}
	local index = 2

	while index <= #form.items do
		local head = form.items[index]

		if not value.is_symbol(head) then
			errors.raise("syntax", "loop expected clause keywords")
		end

		if head.name == "for" then
			local var = form.items[index + 1]
			local mode = form.items[index + 2]

			if not value.is_symbol(var) or not value.is_symbol(mode) then
				errors.raise("syntax", "loop for clauses must be 'for var ...'")
			end

			if mode.name == "in" then
				clauses[#clauses + 1] = {
					kind = "for_in",
					name = var.name,
					source = form.items[index + 3],
				}
				index = index + 4
			elseif mode.name == "below" then
				clauses[#clauses + 1] = {
					kind = "for_below",
					name = var.name,
					limit = form.items[index + 3],
				}
				index = index + 4
			elseif mode.name == "=" then
				local clause = {
					kind = "for_assign",
					name = var.name,
					init = form.items[index + 3],
				}

				index = index + 4

				if index + 1 <= #form.items
					and value.is_symbol(form.items[index])
					and form.items[index].name == "then" then
					clause.step = form.items[index + 1]
					index = index + 2
				end

				clauses[#clauses + 1] = clause
			else
				errors.raise("syntax", string.format("unsupported loop for mode '%s'", mode.name))
			end
		elseif head.name == "when" or head.name == "unless" then
			local collect_kw = form.items[index + 2]

			if not value.is_symbol(collect_kw) or collect_kw.name ~= "collect" then
				errors.raise("syntax", "loop only supports when/unless ... collect ...")
			end

			clauses[#clauses + 1] = {
				kind = head.name,
				test = form.items[index + 1],
				collect = form.items[index + 3],
			}
			index = index + 4
		else
			errors.raise("syntax", string.format("unsupported loop clause '%s'", head.name))
		end
	end

	return clauses
end

local function eval_loop_clauses(form, scope, eval_form_impl, execution)
	local clauses = parse_loop_spec(form)
	local loop_scope = env.new(scope)
	local states = {}
	local terminal = nil

	for _, clause in ipairs(clauses) do
		if clause.kind == "for_in" then
			local source = eval_form_impl(clause.source, scope, execution)

			if not value.is_list(source) or source.tail ~= nil then
				errors.raise("type", "loop for ... in expected a proper list")
			end

			states[#states + 1] = {
				kind = clause.kind,
				name = clause.name,
				items = source.items,
				index = 1,
			}
		elseif clause.kind == "for_below" then
			states[#states + 1] = {
				kind = clause.kind,
				name = clause.name,
				limit = eval_form_impl(clause.limit, scope, execution),
				current = 0,
			}
			elseif clause.kind == "for_assign" then
				states[#states + 1] = {
					kind = clause.kind,
					name = clause.name,
					init = clause.init,
					value = nil,
					has_value = false,
					step = clause.step,
				}
			else
			terminal = clause
		end
	end

	local results = {}

	while true do
		local active = true

		for _, state in ipairs(states) do
			if state.kind == "for_in" then
				if state.index > #state.items then
					active = false
					break
				end

				setq_like(loop_scope, state.name, state.items[state.index])
				elseif state.kind == "for_below" then
				if state.current >= state.limit then
					active = false
					break
				end

					setq_like(loop_scope, state.name, state.current)
				else
					if state.step == nil then
						state.value = eval_form_impl(state.init, loop_scope, execution)
						state.has_value = true
					elseif not state.has_value then
						state.value = eval_form_impl(state.init, loop_scope, execution)
						state.has_value = true
					end

					setq_like(loop_scope, state.name, state.value)
				end
			end

		if not active then
			break
		end

		if terminal ~= nil then
			local test_value = eval_form_impl(terminal.test, loop_scope, execution)
			local matches = terminal.kind == "when"
				and is_truthy_for_mode(test_value, scope, execution)
				or terminal.kind == "unless"
					and not is_truthy_for_mode(test_value, scope, execution)

			if matches then
				setq_like(loop_scope, "it", test_value)
				local collected

				if value.is_symbol(terminal.collect) and terminal.collect.name == "it" then
					collected = test_value
				else
					collected = eval_form_impl(terminal.collect, loop_scope, execution)
				end

				results[#results + 1] = collected
			end
		end

		for _, state in ipairs(states) do
			if state.kind == "for_in" then
				state.index = state.index + 1
			elseif state.kind == "for_below" then
				state.current = state.current + 1
			elseif state.step ~= nil then
				state.value = eval_form_impl(state.step, loop_scope, execution)
				state.has_value = true
			end
		end
	end

	return value.list(results)
end

setq_like = function(scope, name, item)
	local frame = env.find_frame(scope, name)

	if frame ~= nil then
		frame.values[name] = item
		return item
	end

	return env.define(scope, name, item)
end

install_syntax_callable_wrappers = function(target_scope, definition_scope)
	local seen = {}
	local frame = definition_scope

	while frame ~= nil do
		for name, item in pairs(frame.values) do
			if not seen[name] then
				seen[name] = true

				if value.is_syntax(item) then
					env.define(target_scope, name, value.builtin(name, function(args, _, execution)
						local items = {
							value.symbol(name),
						}

						for index, arg in ipairs(args) do
							items[index + 1] = arg
						end

						return expand_syntax_binding(item.transformer, value.list(items), definition_scope, execution)
					end))
				end
			end
		end

		frame = frame.parent
	end
end

-- Procedural macro transformers still run as ordinary callables, but they need
-- syntax objects and definition-site scope preserved at expansion time.
local function compile_transformer(name, transformer_form, definition_scope)
	if value.is_list(transformer_form)
		and value.is_symbol(transformer_form.items[1])
		and transformer_form.items[1].name == "sc-macro-transformer" then
		expect_form_count("sc-macro-transformer", transformer_form.items, 1, 1)
		local closure_scope = env.new(definition_scope)
		install_syntax_callable_wrappers(closure_scope, definition_scope)
		local closure = evaluator.eval_form(transformer_form.items[2], closure_scope, evaluator.new_execution())

		return value.syntax(name, {
			kind = "sc_macro",
			syntax_name = name,
			definition_scope = definition_scope,
			closure = closure,
		})
	end

	return value.syntax(
		name,
		syntax_rules.compile(transformer_form, definition_scope, name)
	)
end

local function copy_name_set(items)
	local copy = {}

	for name, enabled in pairs(items or {}) do
		copy[name] = enabled
	end

	return copy
end

local function mark_param_names(formals, names)
	if value.is_symbol(formals) then
		names[formals.name] = true
		return
	end

	if not value.is_list(formals) then
		return
	end

	for _, item in ipairs(formals.items) do
		if value.is_symbol(item) then
			names[item.name] = true
		end
	end

	if value.is_symbol(formals.tail) then
		names[formals.tail.name] = true
	end
end

local function mark_binding_names(bindings_form, names)
	if not value.is_list(bindings_form) then
		return
	end

	for _, binding in ipairs(bindings_form.items) do
		if value.is_list(binding) and value.is_symbol(binding.items[1]) then
			names[binding.items[1].name] = true
		end
	end
end

local resolve_syntactic_closures

local function resolve_with_capture(datum, capture_scope, introduced_names)
	if value.is_symbol(datum) then
		if datum.scope ~= nil then
			return datum
		end

		if introduced_names[datum.name] then
			return datum
		end

		return value.symbol(datum.name, capture_scope)
	end

	if value.is_syntactic_closure(datum) then
		return resolve_with_capture(datum.expr, datum.scope, introduced_names)
	end

	if value.is_list(datum) then
		local items = {}
		local head = datum.items[1]
		local head_name = value.is_symbol(head) and head.name or nil

		if head_name == "lambda" and datum.items[2] ~= nil then
			items[1] = resolve_with_capture(datum.items[1], capture_scope, introduced_names)
			items[2] = datum.items[2]

			local body_names = copy_name_set(introduced_names)
			mark_param_names(datum.items[2], body_names)

			for index = 3, #datum.items do
				items[index] = resolve_with_capture(datum.items[index], capture_scope, body_names)
			end

			local tail

			if datum.tail ~= nil then
				tail = resolve_with_capture(datum.tail, capture_scope, introduced_names)
			end

			return value.list(items, tail)
		end

		if (head_name == "let" or head_name == "let*" or head_name == "letrec")
			and datum.items[2] ~= nil then
			items[1] = resolve_with_capture(datum.items[1], capture_scope, introduced_names)
			local body_names = copy_name_set(introduced_names)
			local binding_index = 2

			if value.is_symbol(datum.items[2]) and datum.items[3] ~= nil then
				items[2] = datum.items[2]
				body_names[datum.items[2].name] = true
				binding_index = 3
			end

			items[binding_index] = resolve_with_capture(datum.items[binding_index], capture_scope, introduced_names)
			mark_binding_names(datum.items[binding_index], body_names)

			for index = binding_index + 1, #datum.items do
				items[index] = resolve_with_capture(datum.items[index], capture_scope, body_names)
			end

			local tail

			if datum.tail ~= nil then
				tail = resolve_with_capture(datum.tail, capture_scope, introduced_names)
			end

			return value.list(items, tail)
		end

		for index, item in ipairs(datum.items) do
			items[index] = resolve_with_capture(item, capture_scope, introduced_names)
		end

		local tail

		if datum.tail ~= nil then
			tail = resolve_with_capture(datum.tail, capture_scope, introduced_names)
		end

		return value.list(items, tail)
	end

	if value.is_vector(datum) then
		local items = {}

		for index, item in ipairs(datum.items) do
			items[index] = resolve_with_capture(item, capture_scope, introduced_names)
		end

		return value.vector(items)
	end

	return datum
end

-- Syntactic closures carry "resolve free identifiers in this scope" metadata.
-- Expansion repeatedly routes datums through this helper before evaluation.
function resolve_syntactic_closures(datum, introduced_names)
	introduced_names = introduced_names or {}

	if value.is_syntactic_closure(datum) then
		return resolve_with_capture(datum.expr, datum.scope, introduced_names)
	end

	if value.is_list(datum) then
		local items = {}
		local head = datum.items[1]
		local head_name = value.is_symbol(head) and head.name or nil

		if head_name == "lambda" and datum.items[2] ~= nil then
			items[1] = resolve_syntactic_closures(datum.items[1], introduced_names)
			items[2] = datum.items[2]

			local body_names = copy_name_set(introduced_names)
			mark_param_names(datum.items[2], body_names)

			for index = 3, #datum.items do
				items[index] = resolve_syntactic_closures(datum.items[index], body_names)
			end
		elseif (head_name == "let" or head_name == "let*" or head_name == "letrec")
			and datum.items[2] ~= nil then
			items[1] = resolve_syntactic_closures(datum.items[1], introduced_names)
			local body_names = copy_name_set(introduced_names)
			local binding_index = 2

			if value.is_symbol(datum.items[2]) and datum.items[3] ~= nil then
				items[2] = datum.items[2]
				body_names[datum.items[2].name] = true
				binding_index = 3
			end

			items[binding_index] = resolve_syntactic_closures(datum.items[binding_index], introduced_names)
			mark_binding_names(datum.items[binding_index], body_names)

			for index = binding_index + 1, #datum.items do
				items[index] = resolve_syntactic_closures(datum.items[index], body_names)
			end
		else
			for index, item in ipairs(datum.items) do
				items[index] = resolve_syntactic_closures(item, introduced_names)
			end
		end

		local tail

		if datum.tail ~= nil then
			tail = resolve_syntactic_closures(datum.tail, introduced_names)
		end

		return value.list(items, tail)
	end

	if value.is_vector(datum) then
		local items = {}

		for index, item in ipairs(datum.items) do
			items[index] = resolve_syntactic_closures(item, introduced_names)
		end

		return value.vector(items)
	end

	return datum
end

function expand_syntax_binding(transformer, form, scope, execution)
	if transformer == nil then
		errors.raise("syntax", "unsupported macro transformer")
	end

	if transformer.kind == "syntax_rules" then
		return syntax_rules.expand(transformer, form)
	end

	if transformer.kind == "sc_macro" then
		local expanded = apply_callable(transformer.closure, {
			form,
			transformer.definition_scope,
		}, execution)
		return resolve_syntactic_closures(expanded)
	end

	if transformer.kind == "cl_macro" then
		local args = {}

		for index = 2, #form.items do
			args[#args + 1] = form.items[index]
		end

		local expanded = apply_callable(transformer.closure, args, execution)
		return resolve_syntactic_closures(expanded)
	end

	errors.raise("syntax", "unsupported macro transformer")
end

local function datum_eqv(left, right)
	if value.is_symbol(left) and value.is_symbol(right) then
		return left.name == right.name
	end

	if value.is_list(left) or value.is_list(right) then
		if value.is_list(left)
			and value.is_list(right)
			and #left.items == 0
			and left.tail == nil
			and #right.items == 0 then
			return true
		end

		return left == right
	end

	return left == right
end

local cps_sensitive_names = {
	block = true,
	["call-with-current-continuation"] = true,
	["call/cc"] = true,
	["with-exception-handler"] = true,
	["raise"] = true,
	["raise-continuable"] = true,
	["error"] = true,
	go = true,
	["guard"] = true,
	["dynamic-wind"] = true,
	["parameterize"] = true,
	prog = true,
	["return-from"] = true,
	["return"] = true,
	tagbody = true,
}

local function form_needs_cps(form)
	if value.is_symbol(form) then
		return cps_sensitive_names[form.name] == true
	end

	if value.is_list(form) then
		for _, item in ipairs(form.items) do
			if form_needs_cps(item) then
				return true
			end
		end

		if form.tail ~= nil then
			return form_needs_cps(form.tail)
		end

		return false
	end

	if value.is_vector(form) then
		for _, item in ipairs(form.items) do
			if form_needs_cps(item) then
				return true
			end
		end
	end

	return false
end

local function body_needs_cps(forms)
	for _, form in ipairs(forms) do
		if form_needs_cps(form) then
			return true
		end
	end

	return false
end

-- Pre-expansion is only safe for bodies that will not introduce new dynamic
-- control boundaries later in evaluation.
local function body_allows_preexpand(forms)
	for _, form in ipairs(forms) do
		if value.is_list(form) and #form.items > 0 then
			local head = form.items[1]

			if value.is_symbol(head) then
				local name = head.name

				if name == "define-syntax" or name == "let-syntax" or name == "letrec-syntax" then
					return false
				end
			end
		end
	end

	return true
end

local function cached_expanded_body(forms, scope)
	local stripped_body, special_names = collect_special_names(forms, 1)

	if next(special_names) ~= nil or #stripped_body ~= #forms then
		return nil
	end

	local expanded_body = {}

	for index, form in ipairs(forms) do
		expanded_body[index] = expand.form(form, scope)
	end

	return expanded_body
end

function eval_form(form, scope, execution)
	return eval_expanded_form_direct(expand.form(form, scope), scope, execution)
end

function eval_expanded_form(form, scope, execution)
	checkpoint(execution)

	if is_cl_keyword_symbol(form, scope, execution) then
		return form
	end

	if value.is_symbol(form) then
		if use_special_lookup(scope, form.name, execution) then
			return resolve_special_value(binding_scope(scope, form), form.name, execution)
		end

		return env.get(binding_scope(scope, form), form.name)
	end

	if not value.is_list(form) then
		return form
	end

	if #form.items == 0 then
		return form
	end

	local head = form.items[1]

	if value.is_symbol(head) then
		local binding = lookup_binding(scope, head)

		if value.is_syntax(binding) then
			local expanded = expand_syntax_binding(binding.transformer, form, scope, execution)
			return eval_form_direct(expanded, scope, execution)
		end

		local handler = special_forms[head.name]

		if handler ~= nil and binding == nil then
			if cl_only_special_forms[head.name] and not cl_compat_enabled(scope, execution) then
				handler = nil
			end
		end

		if handler ~= nil and binding == nil then
			return handler(form, scope, eval_expanded_form_direct, execution)
		end
	end

	local callable = eval_form_direct(form.items[1], scope, execution)
	local args = {}

	for index = 2, #form.items do
		args[index - 1] = eval_form_direct(form.items[index], scope, execution)
	end

	return apply_callable_direct(callable, args, execution)
end

local function register_special_form(name, handler)
	special_forms[name] = handler
end

local function expect_template_form_count(name, form)
	expect_form_count(name, form.items, 1, 1)
end

local function is_unbound_keyword(scope, symbol, name)
	return value.is_symbol(symbol) and symbol.name == name and lookup_binding(scope, symbol) == nil
end

local quasiquote_item

local function quasiquote_sequence(items_source, make_result, scope, eval_form_impl, execution, depth)
	local items = {}

	for _, child in ipairs(items_source) do
		if value.is_list(child) and #child.items > 0 then
			local child_head = child.items[1]

			if is_unbound_keyword(scope, child_head, "unquote-splicing") then
				expect_template_form_count("unquote-splicing", child)

				if depth == 1 then
					local spliced = eval_form_impl(child.items[2], scope, execution)

					if not value.is_list(spliced) then
						errors.raise("type", "unquote-splicing expected a list")
					end

					for _, spliced_item in ipairs(spliced.items) do
						table.insert(items, spliced_item)
					end
				else
					table.insert(items, value.list({
						value.symbol("unquote-splicing"),
						quasiquote_item(child.items[2], scope, eval_form_impl, execution, depth - 1),
					}))
				end
			else
				table.insert(items, quasiquote_item(child, scope, eval_form_impl, execution, depth))
			end
		else
			table.insert(items, quasiquote_item(child, scope, eval_form_impl, execution, depth))
		end
	end

	return make_result(items)
end

-- Quasiquote is evaluated directly instead of lowering into nested cons calls
-- so vectors, dotted tails, and splicing stay aligned with the runtime's value
-- representation.
function quasiquote_item(item, scope, eval_form_impl, execution, depth)
	if not value.is_list(item) then
		if value.is_vector(item) then
			return quasiquote_sequence(item.items, value.vector, scope, eval_form_impl, execution, depth)
		end

		return item
	end

	if #item.items == 0 then
		return value.list({})
	end

	local head = item.items[1]

	if is_unbound_keyword(scope, head, "unquote") then
		expect_template_form_count("unquote", item)

		if depth == 1 then
			return eval_form_impl(item.items[2], scope, execution)
		end

		return value.list({
			value.symbol("unquote"),
			quasiquote_item(item.items[2], scope, eval_form_impl, execution, depth - 1),
		})
	end

	if is_unbound_keyword(scope, head, "unquote-splicing") then
		errors.raise("syntax", "unquote-splicing must appear inside a list")
	end

	if is_unbound_keyword(scope, head, "quasiquote") then
		expect_template_form_count("quasiquote", item)
		return value.list({
			value.symbol("quasiquote"),
			quasiquote_item(item.items[2], scope, eval_form_impl, execution, depth + 1),
		})
	end

	return quasiquote_sequence(item.items, value.list, scope, eval_form_impl, execution, depth)
end

register_special_form("quote", function(form)
	expect_form_count("quote", form.items, 1, 1)
	return form.items[2]
end)

register_special_form("quasiquote", function(form, scope, eval_form_impl, execution)
	expect_template_form_count("quasiquote", form)
	return quasiquote_item(form.items[2], scope, eval_form_impl, execution, 1)
end)

register_special_form("unquote", function()
	errors.raise("syntax", "unquote may only appear inside quasiquote")
end)

register_special_form("unquote-splicing", function()
	errors.raise("syntax", "unquote-splicing may only appear inside quasiquote")
end)

register_special_form("if", function(form, scope, eval_form_impl, execution)
	expect_form_count("if", form.items, 2, 3)

	local condition = eval_form_impl(form.items[2], scope, execution)

	if is_truthy_for_mode(condition, scope, execution) then
		return eval_form_impl(form.items[3], scope, execution)
	end

	if form.items[4] ~= nil then
		return eval_form_impl(form.items[4], scope, execution)
	end

	return value.list({})
end)

register_special_form("guard", function(form, scope, eval_form_impl, execution)
	expect_form_count("guard", form.items, 2)

	local clause_spec = form.items[2]

	if not value.is_list(clause_spec) or #clause_spec.items < 1 then
		errors.raise("type", "guard expected a clause spec list")
	end

	local condition_name = clause_spec.items[1]

	if not value.is_symbol(condition_name) then
		errors.raise("type", "guard expected a condition variable symbol")
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", "guard expected at least one body form")
	end

	local token = {}
	local handler = value.builtin("guard-handler", function(args)
		local condition = args[1]

		error({
			kind = "guard_raise",
			token = token,
			condition = condition,
		}, 0)
	end)

	local handlers = execution.exception_handlers or {}
	execution.exception_handlers = handlers
	table.insert(handlers, handler)

	local ok, result = pcall(function()
		return eval_sequence(body, scope, eval_form_impl, execution)
	end)

	if handlers[#handlers] == handler then
		table.remove(handlers)
	end

	if ok then
		return result
	end

	local condition

	if errors.is_flow_control(result) then
		if type(result) ~= "table" or result.kind ~= "guard_raise" or result.token ~= token then
			error(result, 0)
		end

		condition = result.condition
	else
		condition = errors.to_condition(result)
	end
	local clause_scope = env.new(scope)
	env.define(clause_scope, condition_name.name, condition)

	for index = 2, #clause_spec.items do
		local clause = clause_spec.items[index]

		if not value.is_list(clause) or #clause.items == 0 then
			errors.raise("type", "guard clauses must be non-empty lists")
		end

		local test_form = clause.items[1]
		local matches = false
		local test_value = nil
		local test_value = false

		if is_unbound_keyword(clause_scope, test_form, "else") then
			if index ~= #clause_spec.items then
				errors.raise("syntax", "guard else clause must be last")
			end

			matches = true
			test_value = condition
		else
			test_value = eval_form_impl(test_form, clause_scope, execution)
			matches = is_truthy_for_mode(test_value, scope, execution)
		end

		if matches then
			if #clause.items == 1 then
				return test_value
			end

			if #clause.items == 3
				and is_unbound_keyword(clause_scope, clause.items[2], "=>") then
				local recipient = eval_form_impl(clause.items[3], clause_scope, execution)
				return apply_callable(recipient, {
					test_value,
				}, execution)
			end

			local clause_body = {}

			for clause_index = 2, #clause.items do
				clause_body[#clause_body + 1] = clause.items[clause_index]
			end

			return eval_sequence(clause_body, clause_scope, eval_form_impl, execution)
		end
	end

	error({
		kind = "scheme_raise",
		object = condition,
		continuable = false,
	}, 0)
end)

register_special_form("and", function(form, scope, eval_form_impl, execution)
	local result = true

	for index = 2, #form.items do
		result = eval_form_impl(form.items[index], scope, execution)

		if not is_truthy_for_mode(result, scope, execution) then
			if index == #form.items then
				return result
			end

			return primary_value(result)
		end
	end

	return result
end)

register_special_form("or", function(form, scope, eval_form_impl, execution)
	for index = 2, #form.items do
		local result = eval_form_impl(form.items[index], scope, execution)

		if is_truthy_for_mode(result, scope, execution) then
			if index == #form.items then
				return result
			end

			return primary_value(result)
		end

		if index == #form.items then
			return result
		end
	end

	return false
end)

register_special_form("define", function(form, scope, eval_form_impl, execution)
	expect_form_count("define", form.items, 2, 2)
	local target = form.items[2]

	if value.is_symbol(target) then
		local item = eval_form_impl(form.items[3], scope, execution)
		return env.define(scope, target.name, item)
	end

	errors.raise("type", "define expected a symbol or function signature")
end)

register_special_form("define-values", function(form, scope, eval_form_impl, execution)
	expect_form_count("define-values", form.items, 2, 2)

	local formals = form.items[2]
	local produced = normalize_values(eval_form_impl(form.items[3], scope, execution))
	local clause_scope = bind.bind_args(scope, bind.parse_param_spec(formals), produced)

	for name, item in pairs(clause_scope.values) do
		env.define(scope, name, item)
	end

	return value.list({})
end)

register_special_form("define-syntax", function(form, scope)
	expect_form_count("define-syntax", form.items, 2, 2)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "define-syntax expected a symbol name")
	end

	env.define(scope, target.name, value.syntax(target.name, nil))
	return env.set(scope, target.name, compile_transformer(target.name, form.items[3], scope))
end)

register_special_form("define-record-type", function(form, scope)
	expect_form_count("define-record-type", form.items, 3)

	local type_name = form.items[2]
	local constructor_spec = form.items[3]
	local predicate_name = form.items[4]

	if not value.is_symbol(type_name) then
		errors.raise("type", "define-record-type expected a type name symbol")
	end

	if not value.is_list(constructor_spec) or #constructor_spec.items < 1 then
		errors.raise("type", "define-record-type expected a constructor spec")
	end

	if not value.is_symbol(constructor_spec.items[1]) then
		errors.raise("type", "define-record-type constructor name must be a symbol")
	end

	if not value.is_symbol(predicate_name) then
		errors.raise("type", "define-record-type predicate name must be a symbol")
	end

	local constructor_name = constructor_spec.items[1]
	local field_names = {}

	for index = 2, #constructor_spec.items do
		local field_name = constructor_spec.items[index]

		if not value.is_symbol(field_name) then
			errors.raise("type", "define-record-type constructor fields must be symbols")
		end

		field_names[#field_names + 1] = field_name.name
	end

	local constructor = value.builtin(constructor_name.name, function(args)
		if #args ~= #field_names then
			errors.raise(
				"arity",
				string.format("%s expected %d arguments, got %d", constructor_name.name, #field_names, #args)
			)
		end

		local fields = {}

		for index, field_name in ipairs(field_names) do
			fields[field_name] = args[index]
		end

		return value.record(type_name.name, fields)
	end)

	env.define(scope, constructor_name.name, constructor)
	env.define(scope, predicate_name.name, value.builtin(predicate_name.name, function(args)
		expect_form_count(predicate_name.name, {
			false,
			args[1],
		}, 1, 1)
		return value.is_record(args[1]) and args[1].type_name == type_name.name
	end))

	for index = 5, #form.items do
		local field_spec = form.items[index]

		if not value.is_list(field_spec) or (#field_spec.items ~= 2 and #field_spec.items ~= 3) then
			errors.raise("type", "define-record-type field specs must be (field accessor [mutator])")
		end

		local field_name = field_spec.items[1]
		local accessor_name = field_spec.items[2]
		local mutator_name = field_spec.items[3]

		if not value.is_symbol(field_name) or not value.is_symbol(accessor_name) then
			errors.raise("type", "define-record-type field specs must use symbols")
		end

		env.define(scope, accessor_name.name, value.builtin(accessor_name.name, function(args)
			if #args ~= 1 then
				errors.raise(
					"arity",
					string.format("%s expected 1 argument, got %d", accessor_name.name, #args)
				)
			end

			if not value.is_record(args[1]) or args[1].type_name ~= type_name.name then
				errors.raise("type", string.format("%s expected a %s record", accessor_name.name, type_name.name))
			end

			return args[1].fields[field_name.name]
		end))

		if mutator_name ~= nil then
			if not value.is_symbol(mutator_name) then
				errors.raise("type", "define-record-type mutator names must be symbols")
			end

			env.define(scope, mutator_name.name, value.builtin(mutator_name.name, function(args)
				if #args ~= 2 then
					errors.raise(
						"arity",
						string.format("%s expected 2 arguments, got %d", mutator_name.name, #args)
					)
				end

				if not value.is_record(args[1]) or args[1].type_name ~= type_name.name then
					errors.raise("type", string.format("%s expected a %s record", mutator_name.name, type_name.name))
				end

				args[1].fields[field_name.name] = args[2]
				return value.list({})
			end))
		end
	end

	return value.list({})
end)

register_special_form("lambda", function(form, scope)
	expect_form_count("lambda", form.items, 2)
	local body = {}

	for index = 3, #form.items do
		table.insert(body, form.items[index])
	end

	if #body == 0 then
		errors.raise("arity", "lambda expected at least one body form")
	end

	return value.closure(bind.parse_param_spec(form.items[2]), body, scope, {
		needs_cps = body_needs_cps(body),
		preexpand_body = body_allows_preexpand(body),
		expanded_body = body_allows_preexpand(body) and cached_expanded_body(body, scope) or nil,
	})
end)

register_special_form("case-lambda", function(form, scope)
	expect_form_count("case-lambda", form.items, 1)
	local clauses = {}

	for index = 2, #form.items do
		local clause = form.items[index]

		if not value.is_list(clause) or #clause.items < 2 then
			errors.raise("type", "case-lambda clauses must be (formals body...) lists")
		end

		local body = {}

		for body_index = 2, #clause.items do
			body[#body + 1] = clause.items[body_index]
		end

		clauses[#clauses + 1] = {
			param_spec = bind.parse_param_spec(clause.items[1]),
			body = body,
			needs_cps = body_needs_cps(body),
			preexpand_body = body_allows_preexpand(body),
			expanded_body = body_allows_preexpand(body) and cached_expanded_body(body, scope) or nil,
		}
	end

	return value.builtin("case-lambda", function(args, _, execution)
		for _, clause in ipairs(clauses) do
			local fixed = clause.param_spec.fixed or {}
			local rest = clause.param_spec.rest
			local matches

			if rest == nil then
				matches = #args == #fixed
			else
				matches = #args >= #fixed
			end

			if matches then
				local clause_scope = bind.bind_args(scope, clause.param_spec, args)
				local expanded_body = clause.expanded_body

				if clause.preexpand_body and expanded_body == nil then
					expanded_body = {}

					for body_index, body_form in ipairs(clause.body) do
						expanded_body[body_index] = expand.form(body_form, clause_scope)
					end
				end

				if clause.needs_cps then
					return run_cps(execution, function(k)
						if expanded_body ~= nil then
							return eval_expanded_sequence_cps(expanded_body, clause_scope, execution, k)
						end

						return eval_sequence_cps(clause.body, clause_scope, execution, k)
					end)
				end

				if expanded_body ~= nil then
					return eval_expanded_sequence(expanded_body, clause_scope, execution)
				end

				return eval_sequence(clause.body, clause_scope, eval_form, execution)
			end
		end

		errors.raise("arity", string.format("case-lambda did not match %d arguments", #args))
	end)
end)

register_special_form("delay", function(form, scope, eval_form_impl, execution)
	expect_form_count("delay", form.items, 1, 1)

	return value.promise(function(run_execution)
		return eval_form_impl(form.items[2], scope, run_execution or execution)
	end)
end)

register_special_form("delay-force", function(form, scope, eval_form_impl, execution)
	expect_form_count("delay-force", form.items, 1, 1)

	return value.promise(function(run_execution)
		return eval_form_impl(form.items[2], scope, run_execution or execution)
	end)
end)

register_special_form("dynamic-wind", function(form, scope, eval_form_impl, execution)
	expect_form_count("dynamic-wind", form.items, 3, 3)
	local before_fn = eval_form_impl(form.items[2], scope, execution)
	local thunk_fn = eval_form_impl(form.items[3], scope, execution)
	local after_fn = eval_form_impl(form.items[4], scope, execution)
	return perform_dynamic_wind(before_fn, thunk_fn, after_fn, execution)
end)

local function eval_binding_form(name, form, scope, eval_form_impl, sequential, execution)
	expect_form_count(name, form.items, 2)
	local bindings_index = 2
	local named_target = nil

	if name == "let" and value.is_symbol(form.items[2]) then
		named_target = form.items[2]
		bindings_index = 3
	end

	local bindings_form = form.items[bindings_index]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	if named_target ~= nil then
		local fixed = {}
		local args = {}

		for _, binding in ipairs(bindings_form.items) do
			if not value.is_list(binding) or #binding.items ~= 2 then
				errors.raise("type", string.format("%s bindings must be pairs", name))
			end

			if not value.is_symbol(binding.items[1]) then
				errors.raise("type", string.format("%s binding names must be symbols", name))
			end

			table.insert(fixed, binding.items[1].name)
			table.insert(args, eval_form_impl(binding.items[2], scope, execution))
		end

		local let_scope = env.new(scope)
		local body = {}

		for index = 4, #form.items do
			table.insert(body, form.items[index])
		end

		if #body == 0 then
			errors.raise("arity", string.format("%s expected at least one body form", name))
		end

		env.define(let_scope, named_target.name, value.uninitialized(named_target.name))

		local closure = value.closure(value.param_spec(fixed, nil, {}), body, let_scope, {
			needs_cps = body_needs_cps(body),
			preexpand_body = body_allows_preexpand(body),
		})
		env.set(let_scope, named_target.name, closure)
		return apply_callable(closure, args, execution)
	end

	local body, special_names, ordered_special_names = collect_special_names(form.items, bindings_index + 1)
	add_global_special_bindings(scope, special_names, ordered_special_names, bindings_form)

	if #body == 0 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	local let_scope

	if sequential then
		let_scope = env.new(scope)
		local special_values = {}

		local function bind_next(index)
			if index > #bindings_form.items then
				if next(special_names) == nil then
					return eval_sequence(body, let_scope, eval_form_impl, execution)
				end

				local body_scope = env.new(let_scope)
				env.mark_specials(body_scope, special_names)

				for _, special_name in ipairs(ordered_special_names) do
					if special_values[special_name] ~= nil then
						body_scope.values[special_name] = nil
					end
				end

				return with_special_bindings(
					execution,
					make_special_binding_list(ordered_special_names, special_values),
					function()
						return eval_sequence(body, body_scope, eval_form_impl, execution)
					end
				)
			end

			local binding = bindings_form.items[index]

			if not value.is_list(binding) or #binding.items ~= 2 then
				errors.raise("type", string.format("%s bindings must be pairs", name))
			end

			local name_form = binding.items[1]

			if not value.is_symbol(name_form) then
				errors.raise(
					"type",
					string.format("%s binding names must be symbols", name)
				)
			end

			local item = eval_form_impl(binding.items[2], let_scope, execution)

			if special_names[name_form.name] then
				special_values[name_form.name] = item
			end

			env.define(let_scope, name_form.name, item)
			return bind_next(index + 1)
		end

		return bind_next(1)
	else
		local names = {}
		local values = {}
		local special_values = {}

		for _, binding in ipairs(bindings_form.items) do
			if not value.is_list(binding) or #binding.items ~= 2 then
				errors.raise("type", string.format("%s bindings must be pairs", name))
			end

			local name_form = binding.items[1]

			if not value.is_symbol(name_form) then
				errors.raise(
					"type",
					string.format("%s binding names must be symbols", name)
				)
			end

			table.insert(names, name_form.name)
			local item = eval_form_impl(binding.items[2], scope, execution)
			table.insert(values, item)

			if special_names[name_form.name] then
				special_values[name_form.name] = item
			end
		end

		let_scope = env.extend(scope, names, values)
		env.mark_specials(let_scope, special_names)

		for _, special_name in ipairs(ordered_special_names) do
			let_scope.values[special_name] = nil
		end

		return with_special_bindings(
			execution,
			make_special_binding_list(ordered_special_names, special_values),
			function()
				return eval_sequence(body, let_scope, eval_form_impl, execution)
			end
		)
	end

	return eval_sequence(body, let_scope, eval_form_impl, execution)
end

-- letrec and letrec* need placeholder bindings so mutually recursive closures
-- and syntax bindings can refer to each other during initialization.
local function eval_letrec_form(name, form, scope, eval_form_impl, execution)
	expect_form_count(name, form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	local let_scope = env.new(scope)
	local bindings = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", string.format("%s bindings must be pairs", name))
		end

		local name_form = binding.items[1]

		if not value.is_symbol(name_form) then
			errors.raise(
				"type",
				string.format("%s binding names must be symbols", name)
			)
		end

		table.insert(bindings, binding)
		env.define(let_scope, name_form.name, value.uninitialized(name_form.name))
	end

	for _, binding in ipairs(bindings) do
		local name_form = binding.items[1]
		local item = eval_form_impl(binding.items[2], let_scope, execution)
		env.set(let_scope, name_form.name, item)
	end

	local body = {}

	for index = 3, #form.items do
		table.insert(body, form.items[index])
	end

	if #body == 0 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	return eval_sequence(body, let_scope, eval_form_impl, execution)
end

register_special_form("begin", function(form, scope, eval_form_impl, execution)
	expect_form_count("begin", form.items, 0)
	local body = {}

	for index = 2, #form.items do
		table.insert(body, form.items[index])
	end

	return eval_sequence(body, scope, eval_form_impl, execution)
end)

register_special_form("cond", function(form, scope, eval_form_impl, execution)
	expect_form_count("cond", form.items, 1)

	for index = 2, #form.items do
		local clause = form.items[index]

		if not value.is_list(clause) or #clause.items == 0 then
			errors.raise("type", "cond clauses must be non-empty lists")
		end

		local test_form = clause.items[1]
		local matches = false

		if is_unbound_keyword(scope, test_form, "else") then
			if index ~= #form.items then
				errors.raise("syntax", "cond else clause must be last")
			end

			matches = true
		else
			test_value = eval_form_impl(test_form, scope, execution)
			matches = is_truthy_for_mode(test_value, scope, execution)
		end

		if matches then
			if #clause.items == 3
				and is_unbound_keyword(scope, clause.items[2], "=>") then
				if is_unbound_keyword(scope, test_form, "else") then
					test_value = true
				end

				local recipient = eval_form_impl(clause.items[3], scope, execution)
				return apply_callable(recipient, {
					test_value,
				}, execution)
			end

			if #clause.items == 1 then
				return test_value
			end

			local body = {}

			for clause_index = 2, #clause.items do
				table.insert(body, clause.items[clause_index])
			end

			return eval_sequence(body, scope, eval_form_impl, execution)
		end
	end

	return value.list({})
end)

register_special_form("case", function(form, scope, eval_form_impl, execution)
	expect_form_count("case", form.items, 2)

	local key = eval_form_impl(form.items[2], scope, execution)

	for index = 3, #form.items do
		local clause = form.items[index]

		if not value.is_list(clause) or #clause.items < 2 then
			errors.raise("type", "case clauses must be lists with a matcher and body")
		end

		local matcher = clause.items[1]
		local matches = false

		if is_unbound_keyword(scope, matcher, "else") then
			if index ~= #form.items then
				errors.raise("syntax", "case else clause must be last")
			end

			matches = true
		else
			if not value.is_list(matcher) then
				errors.raise("type", "case matchers must be datum lists")
			end

			for _, datum in ipairs(matcher.items) do
				if datum_eqv(key, datum) then
					matches = true
					break
				end
			end
		end

		if matches then
			if #clause.items == 3
				and is_unbound_keyword(scope, clause.items[2], "=>") then
				local recipient = eval_form_impl(clause.items[3], scope, execution)
				return apply_callable(recipient, {
					key,
				}, execution)
			end

			local body = {}

			for clause_index = 2, #clause.items do
				table.insert(body, clause.items[clause_index])
			end

			return eval_sequence(body, scope, eval_form_impl, execution)
		end
	end

	return value.list({})
end)

register_special_form("let", function(form, scope, eval_form_impl, execution)
	return eval_binding_form("let", form, scope, eval_form_impl, false, execution)
end)

register_special_form("let*", function(form, scope, eval_form_impl, execution)
	return eval_binding_form("let*", form, scope, eval_form_impl, true, execution)
end)

register_special_form("letrec", function(form, scope, eval_form_impl, execution)
	return eval_letrec_form("letrec", form, scope, eval_form_impl, execution)
end)

register_special_form("letrec*", function(form, scope, eval_form_impl, execution)
	return eval_letrec_form("letrec*", form, scope, eval_form_impl, execution)
end)

register_special_form("let-values", function(form, scope, eval_form_impl, execution)
	expect_form_count("let-values", form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", "let-values bindings must be a list")
	end

	local let_scope = env.new(scope)

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", "let-values bindings must be pairs")
		end

		bind_clause_values(
			let_scope,
			binding.items[1],
			normalize_values(eval_form_impl(binding.items[2], scope, execution))
		)
	end

	local body = {}

	for index = 3, #form.items do
		table.insert(body, form.items[index])
	end

	if #body == 0 then
		errors.raise("arity", "let-values expected at least one body form")
	end

	return eval_sequence(body, let_scope, eval_form_impl, execution)
end)

register_special_form("let*-values", function(form, scope, eval_form_impl, execution)
	expect_form_count("let*-values", form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", "let*-values bindings must be a list")
	end

	local let_scope = env.new(scope)

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", "let*-values bindings must be pairs")
		end

		bind_clause_values(
			let_scope,
			binding.items[1],
			normalize_values(eval_form_impl(binding.items[2], let_scope, execution))
		)
	end

	local body = {}

	for index = 3, #form.items do
		table.insert(body, form.items[index])
	end

	if #body == 0 then
		errors.raise("arity", "let*-values expected at least one body form")
	end

	return eval_sequence(body, let_scope, eval_form_impl, execution)
end)

register_special_form("do", function(form, scope, eval_form_impl, execution)
	expect_form_count("do", form.items, 2)

	local bindings_form = form.items[2]
	local test_clause = form.items[3]

	if not value.is_list(bindings_form) then
		errors.raise("type", "do bindings must be a list")
	end

	if not value.is_list(test_clause) or #test_clause.items == 0 then
		errors.raise("type", "do termination clause must be a non-empty list")
	end

	local binding_specs = {}
	local names = {}
	local initial_values = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items < 2 or #binding.items > 3 then
			errors.raise("type", "do bindings must be (name init [step]) forms")
		end

		local name_form = binding.items[1]

		if not value.is_symbol(name_form) then
			errors.raise("type", "do binding names must be symbols")
		end

		table.insert(binding_specs, {
			name = name_form.name,
			step = binding.items[3],
		})
		table.insert(names, name_form.name)
		table.insert(initial_values, eval_form_impl(binding.items[2], scope, execution))
	end

	local body = {}

	for index = 4, #form.items do
		table.insert(body, form.items[index])
	end

	local function iterate(values_now)
		local loop_scope = env.extend(scope, names, values_now)
		local done = eval_form_impl(test_clause.items[1], loop_scope, execution)

		if is_truthy_for_mode(done, scope, execution) then
			if #test_clause.items == 1 then
				return value.list({})
			end

			local results = {}

			for index = 2, #test_clause.items do
				table.insert(results, test_clause.items[index])
			end

			return eval_sequence(results, loop_scope, eval_form_impl, execution)
		end

		if #body > 0 then
			eval_sequence(body, loop_scope, eval_form_impl, execution)
		end

		local next_values = {}

		for index, binding in ipairs(binding_specs) do
			if binding.step ~= nil then
				next_values[index] = eval_form_impl(binding.step, loop_scope, execution)
			else
				next_values[index] = values_now[index]
			end
		end

		return iterate(next_values)
	end

	return iterate(initial_values)
end)

register_special_form("parameterize", function(form, scope, eval_form_impl, execution)
	expect_form_count("parameterize", form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", "parameterize bindings must be a list")
	end

	local parameters = {}
	local converted_values = {}
	local previous_values = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", "parameterize bindings must be pairs")
		end

		local parameter = eval_form_impl(binding.items[1], scope, execution)

		if not value.is_builtin(parameter) or parameter.is_parameter ~= true then
			errors.raise("type", "parameterize expected parameter objects")
		end

		local next_value = eval_form_impl(binding.items[2], scope, execution)

		if parameter.converter ~= nil then
			next_value = apply_callable(parameter.converter, {
				next_value,
			}, execution)
		end

		parameters[#parameters + 1] = parameter
		converted_values[#converted_values + 1] = next_value
		previous_values[#previous_values + 1] = parameter.current
	end

	local before_fn = value.builtin("parameterize-before", function()
		for index, parameter in ipairs(parameters) do
			parameter.current = converted_values[index]
		end

		return value.list({})
	end)
	local after_fn = value.builtin("parameterize-after", function()
		for index, parameter in ipairs(parameters) do
			parameter.current = previous_values[index]
		end

		return value.list({})
	end)
	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", "parameterize expected at least one body form")
	end

	local thunk_fn = value.builtin("parameterize-body", function(_, _, thunk_execution)
		return eval_sequence(body, scope, eval_form_impl, thunk_execution)
	end)

	return perform_dynamic_wind(before_fn, thunk_fn, after_fn, execution)
end)

local function eval_local_syntax_form(
	name,
	form,
	scope,
	eval_form_impl,
	local_scope,
	definition_scope,
	execution
)
	expect_form_count(name, form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	local bindings = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", string.format("%s bindings must be pairs", name))
		end

		local target = binding.items[1]

		if not value.is_symbol(target) then
			errors.raise("type", string.format("%s binding names must be symbols", name))
		end

		table.insert(bindings, binding)
	end

	if definition_scope == local_scope then
		for _, binding in ipairs(bindings) do
			env.define(local_scope, binding.items[1].name, value.syntax(binding.items[1].name, nil))
		end
	end

	for _, binding in ipairs(bindings) do
		local target = binding.items[1]
		local transformer = compile_transformer(target.name, binding.items[2], definition_scope)

		if definition_scope == local_scope then
			env.set(local_scope, target.name, transformer)
		else
			env.define(local_scope, target.name, transformer)
		end
	end

	local body = {}

	for index = 3, #form.items do
		table.insert(body, form.items[index])
	end

	if #body == 0 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	local result = eval_sequence(body, local_scope, eval_form_impl, execution)

	for binding_name, item in pairs(local_scope.values) do
		if not value.is_syntax(item) then
			local frame = env.find_frame(scope, binding_name)

			if frame == nil then
				env.define(scope, binding_name, item)
			end
		end
	end

	return result
end

register_special_form("let-syntax", function(form, scope, eval_form_impl, execution)
	local local_scope = env.new(scope)
	return eval_local_syntax_form(
		"let-syntax",
		form,
		scope,
		eval_form_impl,
		local_scope,
		scope,
		execution
	)
end)

register_special_form("letrec-syntax", function(form, scope, eval_form_impl, execution)
	local local_scope = env.new(scope)
	return eval_local_syntax_form(
		"letrec-syntax",
		form,
		scope,
		eval_form_impl,
		local_scope,
		local_scope,
		execution
	)
end)

local function assign_setf_place(place, new_value, scope, eval_form_impl, execution)
	if value.is_symbol(place) then
		setq_like(scope, place.name, new_value)
		return new_value
	end

	if not value.is_list(place) or not value.is_symbol(place.items[1]) then
		errors.raise("type", "setf expected a symbol or place form")
	end

	local head_name = place.items[1].name

	if (head_name == "car" or head_name == "cdr") and #place.items == 2 then
		local cell = eval_form_impl(place.items[2], scope, execution)

		if not value.is_list(cell) or #cell.items == 0 then
			errors.raise("type", string.format("setf of %s expected a non-empty pair", head_name))
		end

		if head_name == "car" then
			cell.items[1] = new_value
		elseif value.is_list(new_value) then
			local next_items = {
				cell.items[1],
			}

			for _, item in ipairs(new_value.items) do
				next_items[#next_items + 1] = item
			end

			cell.items = next_items
			cell.tail = new_value.tail
		else
			cell.items = {
				cell.items[1],
			}
			cell.tail = new_value
		end

		return new_value
	end

	local setter
	local ok, setter_or_error = pcall(function()
		return env.get(scope, cl_setter_name(head_name))
	end)

	if ok then
		setter = setter_or_error
	else
		local accessor = env.get(scope, head_name)
		local simple_place = closure_simple_place(accessor)

		if simple_place ~= nil and #place.items == 2 then
			local rewritten = value.list({
				value.symbol(simple_place),
				place.items[2],
			})

			return assign_setf_place(rewritten, new_value, scope, eval_form_impl, execution)
		end

		error(setter_or_error, 0)
	end

	local args = {
		new_value,
	}

	for index = 2, #place.items do
		args[#args + 1] = eval_form_impl(place.items[index], scope, execution)
	end

	return apply_callable(setter, args, execution)
end

register_special_form("defparameter", function(form, scope, eval_form_impl, execution)
	expect_form_count("defparameter", form.items, 1, 3)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "defparameter expected a symbol name")
	end

	local item = value.list({})

	if form.items[3] ~= nil then
		item = eval_form_impl(form.items[3], scope, execution)
	end

	env.mark_global_special(scope, target.name)
	env.define(scope, target.name, item)

	if form.items[4] ~= nil then
		env.set_doc(scope, "variable", target.name, form.items[4])
	end

	return target
end)

register_special_form("defvar", function(form, scope, eval_form_impl, execution)
	expect_form_count("defvar", form.items, 1, 3)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "defvar expected a symbol name")
	end

	env.mark_global_special(scope, target.name)

	if env.find_frame(scope, target.name) == nil then
		local item = value.list({})

		if form.items[3] ~= nil then
			item = eval_form_impl(form.items[3], scope, execution)
		end

		env.define(scope, target.name, item)
	end

	if form.items[4] ~= nil then
		env.set_doc(scope, "variable", target.name, form.items[4])
	end

	return target
end)

register_special_form("function", function(form, scope, eval_form_impl, execution)
	expect_form_count("function", form.items, 1, 1)

	local target = form.items[2]
	local function_name = cl_function_name(target)

	if function_name ~= nil then
		return env.get(scope, function_name)
	end

	return eval_form_impl(target, scope, execution)
end)

register_special_form("setf", function(form, scope, eval_form_impl, execution)
	if (#form.items - 1) % 2 ~= 0 then
		errors.raise("arity", "setf expected place/value pairs")
	end

	local result = value.list({})

	for index = 2, #form.items, 2 do
		local new_value = eval_form_impl(form.items[index + 1], scope, execution)
		result = assign_setf_place(form.items[index], new_value, scope, eval_form_impl, execution)
	end

	return result
end)

register_special_form("block", function(form, scope, eval_form_impl, execution)
	expect_form_count("block", form.items, 1)

	local name = cl_block_name(form.items[2])

	if name == nil then
		errors.raise("type", "block expected a symbol name or nil")
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	local token = {}

	return with_block_frame(execution, name, token, function()
		if #body == 0 then
			return value.list({})
		end

			return eval_sequence(body, scope, eval_form_impl, execution)
	end)
end)

register_special_form("return-from", function(form, scope, eval_form_impl, execution)
	expect_form_count("return-from", form.items, 1, 2)

	local name = cl_block_name(form.items[2])

	if name == nil then
		errors.raise("type", "return-from expected a block name symbol or nil")
	end

	local frame = find_block_frame(execution, name)

	if frame == nil then
		errors.raise("name", string.format("return-from target '%s' is not active", name))
	end

	local result = value.list({})

	if form.items[3] ~= nil then
		result = eval_form_impl(form.items[3], scope, execution)
	end

	error({
		kind = "block_return",
		token = frame.token,
		value = result,
	}, 0)
end)

register_special_form("incf", function(form, scope, eval_form_impl, execution)
	expect_form_count("incf", form.items, 1, 2)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "incf expected a symbol place")
	end

	local delta = 1

	if form.items[3] ~= nil then
		delta = cl_numeric_delta("incf", eval_form_impl(form.items[3], scope, execution))
	end

	local current = cl_numeric_delta("incf", env.get(scope, target.name))
	local next_value = current + delta
	setq_like(scope, target.name, next_value)
	return next_value
end)

register_special_form("decf", function(form, scope, eval_form_impl, execution)
	expect_form_count("decf", form.items, 1, 2)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "decf expected a symbol place")
	end

	local delta = 1

	if form.items[3] ~= nil then
		delta = cl_numeric_delta("decf", eval_form_impl(form.items[3], scope, execution))
	end

	local current = cl_numeric_delta("decf", env.get(scope, target.name))
	local next_value = current - delta
	setq_like(scope, target.name, next_value)
	return next_value
end)

register_special_form("flet", function(form, scope, eval_form_impl, execution)
	return eval_cl_local_function_form(form, scope, eval_form_impl, execution)
end)

register_special_form("macrolet", function(form, scope, eval_form_impl, execution)
	return eval_cl_macrolet_form(form, scope, execution)
end)

register_special_form("declare", function()
	return value.list({})
end)

register_special_form("locally", function(form, scope, eval_form_impl, execution)
	expect_form_count("locally", form.items, 0)
	local body, special_names = collect_special_names(form.items, 2)

	if #body == 0 then
		return value.list({})
	end

	if next(special_names) == nil then
			return eval_sequence(body, scope, eval_form_impl, execution)
	end

	local local_scope = env.new(scope)
	env.mark_specials(local_scope, special_names)
		return eval_sequence(body, local_scope, eval_form_impl, execution)
end)

register_special_form("tagbody", function(form, scope, eval_form_impl, execution)
	local tags = {}

	for index = 2, #form.items do
		local key = datum_tag_key(form.items[index])

		if key ~= nil then
			tags[key] = index
		end
	end

	execution.cl_tagbodies = execution.cl_tagbodies or {}
	local frame = {
		tags = tags,
	}
	execution.cl_tagbodies[#execution.cl_tagbodies + 1] = frame

	local index = 2
	local result = value.list({})

	while index <= #form.items do
		local item = form.items[index]

		if datum_tag_key(item) ~= nil then
			index = index + 1
		else
			local ok, produced = pcall(function()
				return eval_form_impl(item, scope, execution)
			end)

			if ok then
				result = produced
				index = index + 1
			elseif type(produced) == "table" and produced.kind == "go_signal" and produced.frame == frame then
				index = frame.tags[produced.tag]

				if index == nil then
					table.remove(execution.cl_tagbodies)
					errors.raise("name", "go target is not active")
				end
			else
				table.remove(execution.cl_tagbodies)
				error(produced, 0)
			end
		end
	end

	table.remove(execution.cl_tagbodies)
	return result
end)

register_special_form("go", function(form, scope, _, execution)
	expect_form_count("go", form.items, 1, 1)

	local frame, key = find_tagbody_frame(execution, form.items[2])

	if frame == nil or key == nil then
		errors.raise("name", "go target is not active")
	end

	error({
		kind = "go_signal",
		frame = frame,
		tag = key,
	}, 0)
end)

register_special_form("return", function(form, scope, eval_form_impl, execution)
	local items = {
		value.symbol("return-from"),
		value.list({}),
	}

	if form.items[2] ~= nil then
		items[2] = value.symbol("nil")
		items[3] = form.items[2]
	else
		items[2] = value.symbol("nil")
	end

	return eval_form_impl(value.list(items), scope, execution)
end)

register_special_form("prog", function(form, scope, eval_form_impl, execution)
	expect_form_count("prog", form.items, 1)

	local translated = {
		value.symbol("block"),
		value.symbol("nil"),
		value.list({
			value.symbol("let"),
			form.items[2],
			value.list({
				value.symbol("tagbody"),
			}),
		}),
	}

	for index = 3, #form.items do
		translated[3].items[3].items[#translated[3].items[3].items + 1] = form.items[index]
	end

	return eval_form_impl(value.list(translated), scope, execution)
end)

register_special_form("loop", function(form, scope, eval_form_impl, execution)
	return eval_loop_clauses(form, scope, eval_form_impl, execution)
end)

register_special_form("ignore-errors", function(form, scope, eval_form_impl, execution)
	local body = {}

	for index = 2, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		return value.list({})
	end

	local ok, result = pcall(function()
			return eval_sequence(body, scope, eval_form_impl, execution)
	end)

	if ok then
		return result
	end

	if errors.is_flow_control(result) then
		error(result, 0)
	end

	return value.list({})
end)

register_special_form("dolist", function(form, scope, eval_form_impl, execution)
	expect_form_count("dolist", form.items, 2)

	local spec = form.items[2]

	if not value.is_list(spec) or #spec.items < 2 or #spec.items > 3 or not value.is_symbol(spec.items[1]) then
		errors.raise("type", "dolist expected a (var list [result]) spec")
	end

	local sequence = eval_form_impl(spec.items[2], scope, execution)

	if not value.is_list(sequence) or sequence.tail ~= nil then
		errors.raise("type", "dolist expected a proper list")
	end

	local result_form = spec.items[3]
	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	local loop_scope = env.new(scope)

	for _, item in ipairs(sequence.items) do
		setq_like(loop_scope, spec.items[1].name, item)

		if #body > 0 then
				eval_sequence(body, loop_scope, eval_form_impl, execution)
		end
	end

	setq_like(loop_scope, spec.items[1].name, value.list({}))

	if result_form ~= nil then
		return eval_form_impl(result_form, loop_scope, execution)
	end

	return value.list({})
end)

register_special_form("signals-error", function(form, scope, eval_form_impl, execution)
	expect_form_count("signals-error", form.items, 2, 2)

	local ok = pcall(function()
		eval_form_impl(form.items[2], scope, execution)
	end)

	if ok then
		return value.list({})
	end

	return true
end)

register_special_form("setq", function(form, scope, eval_form_impl, execution)
	if (#form.items - 1) % 2 ~= 0 then
		errors.raise("arity", "setq expected name/value pairs")
	end

	local result = value.list({})

	for index = 2, #form.items, 2 do
		local target = form.items[index]

		if not value.is_symbol(target) then
			errors.raise("type", "setq expected symbol names")
		end

		result = eval_form_impl(form.items[index + 1], scope, execution)
		setq_like(scope, target.name, result)
	end

	return result
end)

register_special_form("set!", function(form, scope, eval_form_impl, execution)
	expect_form_count("set!", form.items, 2, 2)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "set! expected a symbol target")
	end

	local item = eval_form_impl(form.items[3], scope, execution)
	return env.set(scope, target.name, item)
end)

apply_callable_direct = apply_callable
eval_sequence_direct = eval_sequence
eval_form_direct = eval_form
eval_expanded_form_direct = eval_expanded_form
eval_expanded_sequence_direct = eval_expanded_sequence

local function register_special_form_cps(name, handler)
	special_forms_cps[name] = handler
end

local function eval_args_cps(items, start_index, scope, execution, args, k)
	if start_index > #items then
		return k(args)
	end

	return eval_form_cps(items[start_index], scope, execution, function(arg)
		local next_args = value.copy_items(args)
		next_args[#next_args + 1] = arg
		return eval_args_cps(items, start_index + 1, scope, execution, next_args, k)
	end)
end

-- CPS uses the same dynamic-wind rules as the direct evaluator, but each phase
-- is itself continuation-aware so stored continuations can re-enter correctly.
local function run_dynamic_transition_cps(execution, from_stack, to_stack, k)
	local active_from = copy_dynamic_stack(from_stack)
	local active_to = copy_dynamic_stack(to_stack)
	local prefix = common_dynamic_prefix(active_from, active_to)
	local run_before

	local function run_after(index)
		if index <= prefix then
			if execution ~= nil then
				execution.dynamic_stack = copy_dynamic_stack(active_from)
			end

			return run_before(prefix + 1)
		end

		return apply_callable_cps(active_from[index].after, {}, execution, function()
			return run_after(index - 1)
		end)
	end

	run_before = function(index)
		if index > #active_to then
			if execution ~= nil then
				execution.dynamic_stack = active_to
			end

			return k()
		end

		return apply_callable_cps(active_to[index].before, {}, execution, function()
			return run_before(index + 1)
		end)
	end

	return run_after(#active_from)
end

local function apply_callable_sync(callable, args, execution)
	return run_cps(execution, function(k)
		return apply_callable_cps(callable, args, execution, k)
	end)
end

function apply_callable_cps(callable, args, execution, k)
	if value.is_builtin(callable) then
		if callable.is_parameter then
			if #args == 0 then
				return k(callable.current)
			end

			if #args ~= 1 then
				errors.raise(
					"arity",
					string.format("%s expected 0..1 arguments, got %d", callable.name, #args)
				)
			end

			local function store(next_value)
				callable.current = next_value
				return k(value.list({}))
			end

			if callable.converter ~= nil then
				if value.is_builtin(callable.converter) and callable.converter.cps then
					return apply_callable_cps(callable.converter, {
						args[1],
					}, execution, store)
				end

				return store(apply_callable_sync(callable.converter, {
					args[1],
				}, execution))
			end

			return store(args[1])
		end

		if callable.cps then
			return callable.fn(args, apply_callable_cps, execution, k)
		end

		return k(callable.fn(args, apply_callable_sync, execution))
	end

	if value.is_closure(callable) then
		local call_scope

		if callable.param_spec.keywords ~= nil and callable.param_spec.keywords.cl then
			call_scope = bind.bind_cl_args(callable.env, callable.param_spec, args, eval_form, execution)
		else
			call_scope = bind.bind_args(callable.env, callable.param_spec, args)
		end

		local body_scope = call_scope
		local body_forms = callable.body

		if cl_compat_enabled(call_scope, execution) then
			local stripped_body, special_names = collect_special_names(callable.body, 1)

			if next(special_names) ~= nil then
				body_scope = env.new(call_scope)
				env.mark_specials(body_scope, special_names)
				body_forms = stripped_body
			elseif #stripped_body ~= #callable.body then
				body_forms = stripped_body
			end
		end

		if callable.preexpand_body then
			local expanded_body = callable.expanded_body

			if expanded_body == nil then
				expanded_body = {}

				for index, form in ipairs(body_forms) do
					expanded_body[index] = expand.form(form, body_scope)
				end
			end

			return eval_expanded_sequence_cps(expanded_body, body_scope, execution, k)
		end

		return eval_sequence_cps(body_forms, body_scope, execution, k)
	end

	errors.raise("type", "attempted to call a non-function value")
end

-- These walkers keep intermediate sequence state outside the Lua call stack so
-- stored continuations can resume after the original frames are gone.
function eval_sequence_cps(forms, scope, execution, k)
	local function iterate(index, result)
		if index > #forms then
			return k(result)
		end

		checkpoint(execution)
		return eval_form_cps(forms[index], scope, execution, function(next_result)
			return iterate(index + 1, next_result)
		end)
	end

	return iterate(1, value.list({}))
end

function eval_expanded_sequence_cps(forms, scope, execution, k)
	local function iterate(index, result)
		if index > #forms then
			return k(result)
		end

		checkpoint(execution)
		return eval_expanded_form_cps(forms[index], scope, execution, function(next_result)
			return iterate(index + 1, next_result)
		end)
	end

	return iterate(1, value.list({}))
end

local function perform_dynamic_wind_cps(before_fn, thunk_fn, after_fn, execution, k)
	local previous_stack = copy_dynamic_stack(current_dynamic_stack(execution))
	local frame = {
		before = before_fn,
		after = after_fn,
	}
	local entered_stack = copy_dynamic_stack(previous_stack)

	return apply_callable_cps(before_fn, {}, execution, function()
		entered_stack[#entered_stack + 1] = frame

		if execution ~= nil then
			execution.dynamic_stack = entered_stack
		end

		local ok, result = pcall(function()
			return apply_callable_cps(thunk_fn, {}, execution, function(thunk_result)
				local active_stack = current_dynamic_stack(execution)

				if stack_contains_frame(active_stack, frame) then
					if execution ~= nil then
						execution.dynamic_stack = previous_stack
					end

					return apply_callable_cps(after_fn, {}, execution, function()
						return k(thunk_result)
					end)
				end

				return k(thunk_result)
			end)
		end)

		if ok then
			return result
		end

		if errors.is_flow_control(result) then
			error(result, 0)
		end

		local active_stack = current_dynamic_stack(execution)

		if stack_contains_frame(active_stack, frame) then
			if execution ~= nil then
				execution.dynamic_stack = previous_stack
			end

			local after_ok, after_result = pcall(function()
				return apply_callable_sync(after_fn, {}, execution)
			end)

			if not after_ok then
				error(after_result, 0)
			end
		end

		error(result, 0)
	end)
end

local function eval_binding_form_cps(name, form, scope, sequential, execution, k)
	expect_form_count(name, form.items, 2)

	local bindings_index = 2
	local named_target = nil

	if name == "let" and value.is_symbol(form.items[2]) then
		named_target = form.items[2]
		bindings_index = 3
	end

	local bindings_form = form.items[bindings_index]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	local body, special_names, ordered_special_names = collect_special_names(form.items, bindings_index + 1)
	add_global_special_bindings(scope, special_names, ordered_special_names, bindings_form)

	if #body == 0 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	if named_target ~= nil then
		local fixed = {}

		local function collect_named(index, args)
			if index > #bindings_form.items then
				local let_scope = env.new(scope)

				env.define(let_scope, named_target.name, value.uninitialized(named_target.name))

				local closure = value.closure(value.param_spec(fixed, nil, {}), body, let_scope, {
					needs_cps = body_needs_cps(body),
					preexpand_body = body_allows_preexpand(body),
				})
				env.set(let_scope, named_target.name, closure)
				return apply_callable_cps(closure, args, execution, k)
			end

			local binding = bindings_form.items[index]

			if not value.is_list(binding) or #binding.items ~= 2 then
				errors.raise("type", string.format("%s bindings must be pairs", name))
			end

			if not value.is_symbol(binding.items[1]) then
				errors.raise("type", string.format("%s binding names must be symbols", name))
			end

			fixed[#fixed + 1] = binding.items[1].name
			return eval_form_cps(binding.items[2], scope, execution, function(item)
				local next_args = value.copy_items(args)
				next_args[#next_args + 1] = item
				return collect_named(index + 1, next_args)
			end)
		end

		return collect_named(1, {})
	end

	if sequential then
		local let_scope = env.new(scope)
		local special_values = {}

		local function bind_next(index)
			if index > #bindings_form.items then
				if next(special_names) == nil then
					return eval_sequence_cps(body, let_scope, execution, k)
				end

				local body_scope = env.new(let_scope)
				env.mark_specials(body_scope, special_names)

				for _, special_name in ipairs(ordered_special_names) do
					if special_values[special_name] ~= nil then
						body_scope.values[special_name] = nil
					end
				end

				return with_special_bindings(
					execution,
					make_special_binding_list(ordered_special_names, special_values),
					function()
						return eval_sequence_cps(body, body_scope, execution, k)
					end
				)
			end

			local binding = bindings_form.items[index]

			if not value.is_list(binding) or #binding.items ~= 2 then
				errors.raise("type", string.format("%s bindings must be pairs", name))
			end

			local name_form = binding.items[1]

			if not value.is_symbol(name_form) then
				errors.raise("type", string.format("%s binding names must be symbols", name))
			end

			return eval_form_cps(binding.items[2], let_scope, execution, function(item)
				if special_names[name_form.name] then
					special_values[name_form.name] = item
				end

				env.define(let_scope, name_form.name, item)
				return bind_next(index + 1)
			end)
		end

		return bind_next(1)
	end

	local names = {}
	local special_values = {}

	local function collect_values(index, values_now)
		if index > #bindings_form.items then
			local let_scope = env.extend(scope, names, values_now)
			env.mark_specials(let_scope, special_names)

			for _, special_name in ipairs(ordered_special_names) do
				let_scope.values[special_name] = nil
			end

			return with_special_bindings(
				execution,
				make_special_binding_list(ordered_special_names, special_values),
				function()
					return eval_sequence_cps(body, let_scope, execution, k)
				end
			)
		end

		local binding = bindings_form.items[index]

		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", string.format("%s bindings must be pairs", name))
		end

		local name_form = binding.items[1]

		if not value.is_symbol(name_form) then
			errors.raise("type", string.format("%s binding names must be symbols", name))
		end

		names[#names + 1] = name_form.name
		return eval_form_cps(binding.items[2], scope, execution, function(item)
			if special_names[name_form.name] then
				special_values[name_form.name] = item
			end

			local next_values = value.copy_items(values_now)
			next_values[#next_values + 1] = item
			return collect_values(index + 1, next_values)
		end)
	end

	return collect_values(1, {})
end

local function eval_letrec_form_cps(name, form, scope, execution, k)
	expect_form_count(name, form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	local let_scope = env.new(scope)
	local bindings = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", string.format("%s bindings must be pairs", name))
		end

		local name_form = binding.items[1]

		if not value.is_symbol(name_form) then
			errors.raise("type", string.format("%s binding names must be symbols", name))
		end

		bindings[#bindings + 1] = binding
		env.define(let_scope, name_form.name, value.uninitialized(name_form.name))
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	local function initialize(index)
		if index > #bindings then
			return eval_sequence_cps(body, let_scope, execution, k)
		end

		local binding = bindings[index]
		local name_form = binding.items[1]

		return eval_form_cps(binding.items[2], let_scope, execution, function(item)
			env.set(let_scope, name_form.name, item)
			return initialize(index + 1)
		end)
	end

	return initialize(1)
end

local function eval_values_form_cps(name, form, scope, sequential, execution, k)
	expect_form_count(name, form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	local let_scope = env.new(scope)
	local source_scope = sequential and let_scope or scope

	local function bind_next(index)
		if index > #bindings_form.items then
			local body = {}

			for body_index = 3, #form.items do
				body[#body + 1] = form.items[body_index]
			end

			if #body == 0 then
				errors.raise("arity", string.format("%s expected at least one body form", name))
			end

			return eval_sequence_cps(body, let_scope, execution, k)
		end

		local binding = bindings_form.items[index]

		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", string.format("%s bindings must be pairs", name))
		end

		return eval_form_cps(binding.items[2], source_scope, execution, function(item)
			bind_clause_values(let_scope, binding.items[1], normalize_values(item))
			return bind_next(index + 1)
		end)
	end

	return bind_next(1)
end

local function eval_local_syntax_form_cps(name, form, scope, local_scope, definition_scope, execution, k)
	expect_form_count(name, form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	local bindings = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", string.format("%s bindings must be pairs", name))
		end

		local target = binding.items[1]

		if not value.is_symbol(target) then
			errors.raise("type", string.format("%s binding names must be symbols", name))
		end

		bindings[#bindings + 1] = binding
	end

	if definition_scope == local_scope then
		for _, binding in ipairs(bindings) do
			env.define(local_scope, binding.items[1].name, value.syntax(binding.items[1].name, nil))
		end
	end

	for _, binding in ipairs(bindings) do
		local target = binding.items[1]
		local transformer = compile_transformer(target.name, binding.items[2], definition_scope)

		if definition_scope == local_scope then
			env.set(local_scope, target.name, transformer)
		else
			env.define(local_scope, target.name, transformer)
		end
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	return eval_sequence_cps(body, local_scope, execution, function(result)
		for binding_name, item in pairs(local_scope.values) do
			if not value.is_syntax(item) then
				local frame = env.find_frame(scope, binding_name)

				if frame == nil then
					env.define(scope, binding_name, item)
				end
			end
		end

		return k(result)
	end)
end

register_special_form_cps("quote", function(form, _, _, k)
	expect_form_count("quote", form.items, 1, 1)
	return k(form.items[2])
end)

register_special_form_cps("if", function(form, scope, execution, k)
	expect_form_count("if", form.items, 2, 3)
	return eval_form_cps(form.items[2], scope, execution, function(condition)
		if is_truthy_for_mode(condition, scope, execution) then
			return eval_form_cps(form.items[3], scope, execution, k)
		end

		if form.items[4] ~= nil then
			return eval_form_cps(form.items[4], scope, execution, k)
		end

		return k(value.list({}))
	end)
end)

register_special_form_cps("begin", function(form, scope, execution, k)
	expect_form_count("begin", form.items, 0)
	local body = {}

	for index = 2, #form.items do
		body[#body + 1] = form.items[index]
	end

	return eval_sequence_cps(body, scope, execution, k)
end)

register_special_form_cps("and", function(form, scope, execution, k)
	local function iterate(index, result)
		if index > #form.items then
			return k(result)
		end

		return eval_form_cps(form.items[index], scope, execution, function(item)
			if not is_truthy_for_mode(item, scope, execution) then
				if index == #form.items then
					return k(item)
				end

				return k(primary_value(item))
			end

			return iterate(index + 1, item)
		end)
	end

	return iterate(2, true)
end)

register_special_form_cps("or", function(form, scope, execution, k)
	local function iterate(index)
		if index > #form.items then
			return k(false)
		end

		return eval_form_cps(form.items[index], scope, execution, function(item)
			if is_truthy_for_mode(item, scope, execution) then
				if index == #form.items then
					return k(item)
				end

				return k(primary_value(item))
			end

			if index == #form.items then
				return k(item)
			end

			return iterate(index + 1)
		end)
	end

	return iterate(2)
end)

register_special_form_cps("define", function(form, scope, execution, k)
	expect_form_count("define", form.items, 2, 2)
	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "define expected a symbol or function signature")
	end

	return eval_form_cps(form.items[3], scope, execution, function(item)
		return k(env.define(scope, target.name, item))
	end)
end)

register_special_form_cps("define-values", function(form, scope, execution, k)
	expect_form_count("define-values", form.items, 2, 2)
	return eval_form_cps(form.items[3], scope, execution, function(item)
		local produced = normalize_values(item)
		local clause_scope = bind.bind_args(scope, bind.parse_param_spec(form.items[2]), produced)

		for name, produced_item in pairs(clause_scope.values) do
			env.define(scope, name, produced_item)
		end

		return k(value.list({}))
	end)
end)

register_special_form_cps("lambda", function(form, scope, _, k)
	expect_form_count("lambda", form.items, 2)
	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", "lambda expected at least one body form")
	end

	return k(value.closure(bind.parse_param_spec(form.items[2]), body, scope, {
		needs_cps = body_needs_cps(body),
		preexpand_body = body_allows_preexpand(body),
	}))
end)

register_special_form_cps("case-lambda", function(form, scope, _, k)
	expect_form_count("case-lambda", form.items, 1)
	local clauses = {}

	for index = 2, #form.items do
		local clause = form.items[index]

		if not value.is_list(clause) or #clause.items < 2 then
			errors.raise("type", "case-lambda clauses must be (formals body...) lists")
		end

		local body = {}

		for body_index = 2, #clause.items do
			body[#body + 1] = clause.items[body_index]
		end

		clauses[#clauses + 1] = {
			param_spec = bind.parse_param_spec(clause.items[1]),
			body = body,
			needs_cps = body_needs_cps(body),
			preexpand_body = body_allows_preexpand(body),
		}
	end

	return k(value.builtin("case-lambda", function(args, _, execution, next_k)
		for _, clause in ipairs(clauses) do
			local fixed = clause.param_spec.fixed or {}
			local rest = clause.param_spec.rest
			local matches = rest == nil and #args == #fixed or (rest ~= nil and #args >= #fixed)

			if matches then
				local clause_scope = bind.bind_args(scope, clause.param_spec, args)
				local expanded_body = clause.expanded_body

				if clause.preexpand_body and expanded_body == nil then
					expanded_body = {}

					for body_index, body_form in ipairs(clause.body) do
						expanded_body[body_index] = expand.form(body_form, clause_scope)
					end
				end

				if clause.needs_cps then
					if expanded_body ~= nil then
						return eval_expanded_sequence_cps(expanded_body, clause_scope, execution, next_k)
					end

					return eval_sequence_cps(clause.body, clause_scope, execution, next_k)
				end

				if expanded_body ~= nil then
					return next_k(eval_expanded_sequence(expanded_body, clause_scope, execution))
				end

				return next_k(eval_sequence_direct(clause.body, clause_scope, eval_form_direct, execution))
			end
		end

		errors.raise("arity", string.format("case-lambda did not match %d arguments", #args))
	end, {
		cps = true,
	}))
end)

register_special_form_cps("delay", function(form, scope, execution, k)
	expect_form_count("delay", form.items, 1, 1)
	return k(value.promise(function(run_execution)
		return eval_form(form.items[2], scope, run_execution or execution)
	end))
end)

register_special_form_cps("delay-force", function(form, scope, execution, k)
	expect_form_count("delay-force", form.items, 1, 1)
	return k(value.promise(function(run_execution)
		return eval_form(form.items[2], scope, run_execution or execution)
	end))
end)

register_special_form_cps("dynamic-wind", function(form, scope, execution, k)
	expect_form_count("dynamic-wind", form.items, 3, 3)
	return eval_form_cps(form.items[2], scope, execution, function(before_fn)
		return eval_form_cps(form.items[3], scope, execution, function(thunk_fn)
			return eval_form_cps(form.items[4], scope, execution, function(after_fn)
				return perform_dynamic_wind_cps(before_fn, thunk_fn, after_fn, execution, k)
			end)
		end)
	end)
end)

register_special_form_cps("let", function(form, scope, execution, k)
	return eval_binding_form_cps("let", form, scope, false, execution, k)
end)

register_special_form_cps("let*", function(form, scope, execution, k)
	return eval_binding_form_cps("let*", form, scope, true, execution, k)
end)

register_special_form_cps("letrec", function(form, scope, execution, k)
	return eval_letrec_form_cps("letrec", form, scope, execution, k)
end)

register_special_form_cps("letrec*", function(form, scope, execution, k)
	return eval_letrec_form_cps("letrec*", form, scope, execution, k)
end)

register_special_form_cps("let-values", function(form, scope, execution, k)
	return eval_values_form_cps("let-values", form, scope, false, execution, k)
end)

register_special_form_cps("let*-values", function(form, scope, execution, k)
	return eval_values_form_cps("let*-values", form, scope, true, execution, k)
end)

register_special_form_cps("cond", function(form, scope, execution, k)
	expect_form_count("cond", form.items, 1)

	local function check_clause(index)
		if index > #form.items then
			return k(value.list({}))
		end

		local clause = form.items[index]

		if not value.is_list(clause) or #clause.items == 0 then
			errors.raise("type", "cond clauses must be non-empty lists")
		end

		local test_form = clause.items[1]

		if is_unbound_keyword(scope, test_form, "else") then
			if index ~= #form.items then
				errors.raise("syntax", "cond else clause must be last")
			end

			local body = {}

			for clause_index = 2, #clause.items do
				body[#body + 1] = clause.items[clause_index]
			end

			if #body == 0 then
				errors.raise("arity", "cond clauses must have at least one body form")
			end

			return eval_sequence_cps(body, scope, execution, k)
		end

		return eval_form_cps(test_form, scope, execution, function(test_value)
			if not is_truthy_for_mode(test_value, scope, execution) then
				return check_clause(index + 1)
			end

			if #clause.items == 3 and is_unbound_keyword(scope, clause.items[2], "=>") then
				return eval_form_cps(clause.items[3], scope, execution, function(recipient)
					return apply_callable_cps(recipient, {
						test_value,
					}, execution, k)
				end)
			end

			if #clause.items == 1 then
				return k(test_value)
			end

			local body = {}

			for clause_index = 2, #clause.items do
				body[#body + 1] = clause.items[clause_index]
			end

			return eval_sequence_cps(body, scope, execution, k)
		end)
	end

	return check_clause(2)
end)

register_special_form_cps("case", function(form, scope, execution, k)
	expect_form_count("case", form.items, 2)

	return eval_form_cps(form.items[2], scope, execution, function(key)
		local function check_clause(index)
			if index > #form.items then
				return k(value.list({}))
			end

			local clause = form.items[index]

			if not value.is_list(clause) or #clause.items < 2 then
				errors.raise("type", "case clauses must be lists with a matcher and body")
			end

			local matcher = clause.items[1]
			local matches = false

			if is_unbound_keyword(scope, matcher, "else") then
				if index ~= #form.items then
					errors.raise("syntax", "case else clause must be last")
				end

				matches = true
			else
				if not value.is_list(matcher) then
					errors.raise("type", "case matchers must be datum lists")
				end

				for _, datum in ipairs(matcher.items) do
					if datum_eqv(key, datum) then
						matches = true
						break
					end
				end
			end

			if not matches then
				return check_clause(index + 1)
			end

			if #clause.items == 3 and is_unbound_keyword(scope, clause.items[2], "=>") then
				return eval_form_cps(clause.items[3], scope, execution, function(recipient)
					return apply_callable_cps(recipient, {
						key,
					}, execution, k)
				end)
			end

			local body = {}

			for clause_index = 2, #clause.items do
				body[#body + 1] = clause.items[clause_index]
			end

			return eval_sequence_cps(body, scope, execution, k)
		end

		return check_clause(3)
	end)
end)

register_special_form_cps("set!", function(form, scope, execution, k)
	expect_form_count("set!", form.items, 2, 2)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "set! expected a symbol target")
	end

	return eval_form_cps(form.items[3], scope, execution, function(item)
		return k(env.set(scope, target.name, item))
	end)
end)

register_special_form_cps("block", function(form, scope, execution, k)
	expect_form_count("block", form.items, 1)

	local name = cl_block_name(form.items[2])

	if name == nil then
		errors.raise("type", "block expected a symbol name or nil")
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	local token = {}

	return with_block_frame_cps(execution, name, token, function()
		if #body == 0 then
			return k(value.list({}))
		end

		return eval_sequence_cps(body, scope, execution, k)
	end, k)
end)

register_special_form_cps("return-from", function(form, scope, execution, _)
	expect_form_count("return-from", form.items, 1, 2)

	local name = cl_block_name(form.items[2])

	if name == nil then
		errors.raise("type", "return-from expected a block name symbol or nil")
	end

	local frame = find_block_frame(execution, name)

	if frame == nil then
		errors.raise("name", string.format("return-from target '%s' is not active", name))
	end

	local function raise_return(value_now)
		error({
			kind = "block_return",
			token = frame.token,
			value = value_now,
		}, 0)
	end

	if form.items[3] == nil then
		return raise_return(value.list({}))
	end

	return eval_form_cps(form.items[3], scope, execution, raise_return)
end)

register_special_form_cps("incf", function(form, scope, execution, k)
	expect_form_count("incf", form.items, 1, 2)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "incf expected a symbol place")
	end

	local function apply_delta(delta)
		local current = cl_numeric_delta("incf", env.get(scope, target.name))
		local next_value = current + delta
		setq_like(scope, target.name, next_value)
		return k(next_value)
	end

	if form.items[3] == nil then
		return apply_delta(1)
	end

	return eval_form_cps(form.items[3], scope, execution, function(delta)
		return apply_delta(cl_numeric_delta("incf", delta))
	end)
end)

register_special_form_cps("decf", function(form, scope, execution, k)
	expect_form_count("decf", form.items, 1, 2)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "decf expected a symbol place")
	end

	local function apply_delta(delta)
		local current = cl_numeric_delta("decf", env.get(scope, target.name))
		local next_value = current - delta
		setq_like(scope, target.name, next_value)
		return k(next_value)
	end

	if form.items[3] == nil then
		return apply_delta(1)
	end

	return eval_form_cps(form.items[3], scope, execution, function(delta)
		return apply_delta(cl_numeric_delta("decf", delta))
	end)
end)

register_special_form_cps("flet", function(form, scope, execution, k)
	return eval_cl_local_function_form_cps(form, scope, execution, k)
end)

register_special_form_cps("macrolet", function(form, scope, execution, k)
	return eval_cl_macrolet_form_cps(form, scope, execution, k)
end)

register_special_form_cps("declare", function(_, _, _, k)
	return k(value.list({}))
end)

register_special_form_cps("locally", function(form, scope, execution, k)
	expect_form_count("locally", form.items, 0)
	local body, special_names = collect_special_names(form.items, 2)

	if #body == 0 then
		return k(value.list({}))
	end

	if next(special_names) == nil then
		return eval_sequence_cps(body, scope, execution, k)
	end

	local local_scope = env.new(scope)
	env.mark_specials(local_scope, special_names)
	return eval_sequence_cps(body, local_scope, execution, k)
end)

register_special_form_cps("tagbody", function(form, scope, execution, k)
	local tags = {}

	for index = 2, #form.items do
		local key = datum_tag_key(form.items[index])

		if key ~= nil then
			tags[key] = index
		end
	end

	execution.cl_tagbodies = execution.cl_tagbodies or {}
	local frame = {
		tags = tags,
	}
	execution.cl_tagbodies[#execution.cl_tagbodies + 1] = frame

	local function step(index, last_value)
		if index > #form.items then
			table.remove(execution.cl_tagbodies)
			return k(last_value or value.list({}))
		end

		local item = form.items[index]

		if datum_tag_key(item) ~= nil then
			return step(index + 1, last_value)
		end

		local ok, produced = pcall(function()
			return eval_form_cps(item, scope, execution, function(result)
				return result
			end)
		end)

		if ok then
			return step(index + 1, produced)
		end

		if type(produced) == "table" and produced.kind == "go_signal" and produced.frame == frame then
			local target = frame.tags[produced.tag]

			if target == nil then
				table.remove(execution.cl_tagbodies)
				errors.raise("name", "go target is not active")
			end

			return step(target, last_value)
		end

		table.remove(execution.cl_tagbodies)
		error(produced, 0)
	end

	return step(2, value.list({}))
end)

register_special_form_cps("go", function(form, scope, execution, _)
	expect_form_count("go", form.items, 1, 1)

	local frame, key = find_tagbody_frame(execution, form.items[2])

	if frame == nil or key == nil then
		errors.raise("name", "go target is not active")
	end

	error({
		kind = "go_signal",
		frame = frame,
		tag = key,
	}, 0)
end)

register_special_form_cps("return", function(form, scope, execution, k)
	local items = {
		value.symbol("return-from"),
		value.symbol("nil"),
	}

	if form.items[2] ~= nil then
		items[3] = form.items[2]
	end

	return eval_form_cps(value.list(items), scope, execution, k)
end)

register_special_form_cps("prog", function(form, scope, execution, k)
	expect_form_count("prog", form.items, 1)

	local tagbody_form = {
		value.symbol("tagbody"),
	}

	for index = 3, #form.items do
		tagbody_form[#tagbody_form + 1] = form.items[index]
	end

	local translated = value.list({
		value.symbol("block"),
		value.symbol("nil"),
		value.list({
			value.symbol("let"),
			form.items[2],
			value.list(tagbody_form),
		}),
	})

	return eval_form_cps(translated, scope, execution, k)
end)

register_special_form_cps("loop", function(form, scope, execution, k)
	return k(eval_loop_clauses(form, scope, eval_form_direct, execution))
end)

register_special_form_cps("ignore-errors", function(form, scope, execution, k)
	local body = {}

	for index = 2, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		return k(value.list({}))
	end

	local ok, result = pcall(function()
		return eval_sequence_cps(body, scope, execution, function(item)
			return item
		end)
	end)

	if ok then
		return k(result)
	end

	if errors.is_flow_control(result) then
		error(result, 0)
	end

	return k(value.list({}))
end)

register_special_form_cps("dolist", function(form, scope, execution, k)
	expect_form_count("dolist", form.items, 2)

	local spec = form.items[2]

	if not value.is_list(spec) or #spec.items < 2 or #spec.items > 3 or not value.is_symbol(spec.items[1]) then
		errors.raise("type", "dolist expected a (var list [result]) spec")
	end

	return eval_form_cps(spec.items[2], scope, execution, function(sequence)
		if not value.is_list(sequence) or sequence.tail ~= nil then
			errors.raise("type", "dolist expected a proper list")
		end

		local result_form = spec.items[3]
		local body = {}

		for index = 3, #form.items do
			body[#body + 1] = form.items[index]
		end

		local loop_scope = env.new(scope)
		local items = sequence.items

		local function iterate(index)
			if index > #items then
				setq_like(loop_scope, spec.items[1].name, value.list({}))

				if result_form ~= nil then
					return eval_form_cps(result_form, loop_scope, execution, k)
				end

				return k(value.list({}))
			end

			setq_like(loop_scope, spec.items[1].name, items[index])

			if #body == 0 then
				return iterate(index + 1)
			end

			return eval_sequence_cps(body, loop_scope, execution, function()
				return iterate(index + 1)
			end)
		end

		return iterate(1)
	end)
end)

register_special_form_cps("signals-error", function(form, scope, execution, k)
	expect_form_count("signals-error", form.items, 2, 2)

	local ok, result = pcall(function()
		return eval_form_cps(form.items[2], scope, execution, function(item)
			return item
		end)
	end)

	if ok then
		return k(value.list({}))
	end

	if errors.is_flow_control(result) then
		error(result, 0)
	end

	return k(true)
end)

register_special_form_cps("do", function(form, scope, execution, k)
	expect_form_count("do", form.items, 2)

	local bindings_form = form.items[2]
	local test_clause = form.items[3]

	if not value.is_list(bindings_form) then
		errors.raise("type", "do bindings must be a list")
	end

	if not value.is_list(test_clause) or #test_clause.items == 0 then
		errors.raise("type", "do termination clause must be a non-empty list")
	end

	local binding_specs = {}
	local names = {}

	local function collect_initial(index, initial_values)
		if index > #bindings_form.items then
			local body = {}

			for body_index = 4, #form.items do
				body[#body + 1] = form.items[body_index]
			end

			local function iterate(values_now)
				local loop_scope = env.extend(scope, names, values_now)

				return eval_form_cps(test_clause.items[1], loop_scope, execution, function(done)
					if is_truthy_for_mode(done, scope, execution) then
						if #test_clause.items == 1 then
							return k(value.list({}))
						end

						local results = {}

						for result_index = 2, #test_clause.items do
							results[#results + 1] = test_clause.items[result_index]
						end

						return eval_sequence_cps(results, loop_scope, execution, k)
					end

					local function step_loop()
						local function compute_steps(step_index, next_values)
							if step_index > #binding_specs then
								return iterate(next_values)
							end

							local binding = binding_specs[step_index]

							if binding.step == nil then
								local copied_values = value.copy_items(next_values)
								copied_values[#copied_values + 1] = values_now[step_index]
								return compute_steps(step_index + 1, copied_values)
							end

							return eval_form_cps(binding.step, loop_scope, execution, function(step_value)
								local copied_values = value.copy_items(next_values)
								copied_values[#copied_values + 1] = step_value
								return compute_steps(step_index + 1, copied_values)
							end)
						end

						return compute_steps(1, {})
					end

					if #body > 0 then
						return eval_sequence_cps(body, loop_scope, execution, function()
							return step_loop()
						end)
					end

					return step_loop()
				end)
			end

			return iterate(initial_values)
		end

		local binding = bindings_form.items[index]

		if not value.is_list(binding) or #binding.items < 2 or #binding.items > 3 then
			errors.raise("type", "do bindings must be (name init [step]) forms")
		end

		local name_form = binding.items[1]

		if not value.is_symbol(name_form) then
			errors.raise("type", "do binding names must be symbols")
		end

		binding_specs[#binding_specs + 1] = {
			name = name_form.name,
			step = binding.items[3],
		}
		names[#names + 1] = name_form.name

		return eval_form_cps(binding.items[2], scope, execution, function(item)
			local next_values = value.copy_items(initial_values)
			next_values[#next_values + 1] = item
			return collect_initial(index + 1, next_values)
		end)
	end

	return collect_initial(1, {})
end)

register_special_form_cps("parameterize", function(form, scope, execution, k)
	expect_form_count("parameterize", form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", "parameterize bindings must be a list")
	end

	local parameters = {}
	local converted_values = {}
	local previous_values = {}

	local function bind_next(index)
		if index > #bindings_form.items then
			local before_fn = value.builtin("parameterize-before", function()
				for parameter_index, parameter in ipairs(parameters) do
					parameter.current = converted_values[parameter_index]
				end

				return value.list({})
			end)
			local after_fn = value.builtin("parameterize-after", function()
				for parameter_index, parameter in ipairs(parameters) do
					parameter.current = previous_values[parameter_index]
				end

				return value.list({})
			end)
			local body = {}

			for body_index = 3, #form.items do
				body[#body + 1] = form.items[body_index]
			end

			if #body == 0 then
				errors.raise("arity", "parameterize expected at least one body form")
			end

			local thunk_fn = value.builtin("parameterize-body", function(_, _, thunk_execution, next_k)
				return eval_sequence_cps(body, scope, thunk_execution or execution, next_k)
			end, {
				cps = true,
			})

			return perform_dynamic_wind_cps(before_fn, thunk_fn, after_fn, execution, k)
		end

		local binding = bindings_form.items[index]

		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", "parameterize bindings must be pairs")
		end

		return eval_form_cps(binding.items[1], scope, execution, function(parameter)
			if not value.is_builtin(parameter) or parameter.is_parameter ~= true then
				errors.raise("type", "parameterize expected parameter objects")
			end

			return eval_form_cps(binding.items[2], scope, execution, function(next_value)
				local function store(converted)
					parameters = value.copy_items(parameters)
					converted_values = value.copy_items(converted_values)
					previous_values = value.copy_items(previous_values)
					parameters[#parameters + 1] = parameter
					converted_values[#converted_values + 1] = converted
					previous_values[#previous_values + 1] = parameter.current
					return bind_next(index + 1)
				end

				if parameter.converter ~= nil then
					return apply_callable_cps(parameter.converter, {
						next_value,
					}, execution, store)
				end

				return store(next_value)
			end)
		end)
	end

	return bind_next(1)
end)

register_special_form_cps("let-syntax", function(form, scope, execution, k)
	local local_scope = env.new(scope)
	return eval_local_syntax_form_cps("let-syntax", form, scope, local_scope, scope, execution, k)
end)

register_special_form_cps("letrec-syntax", function(form, scope, execution, k)
	local local_scope = env.new(scope)
	return eval_local_syntax_form_cps("letrec-syntax", form, scope, local_scope, local_scope, execution, k)
end)

register_special_form_cps("guard", function(form, scope, execution, k)
	expect_form_count("guard", form.items, 2)

	local clause_spec = form.items[2]

	if not value.is_list(clause_spec) or #clause_spec.items < 1 then
		errors.raise("type", "guard expected a clause spec list")
	end

	local condition_name = clause_spec.items[1]

	if not value.is_symbol(condition_name) then
		errors.raise("type", "guard expected a condition variable symbol")
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		errors.raise("arity", "guard expected at least one body form")
	end

	local token = {}

	local function handle_condition(condition)
		local clause_scope = env.new(scope)
		env.define(clause_scope, condition_name.name, condition)

		local function check_clause(index)
			if index > #clause_spec.items then
				return builtins.raise_condition_cps(condition, false, apply_callable_cps, execution, k)
			end

			local clause = clause_spec.items[index]

			if not value.is_list(clause) or #clause.items == 0 then
				errors.raise("type", "guard clauses must be non-empty lists")
			end

			local test_form = clause.items[1]

			if is_unbound_keyword(clause_scope, test_form, "else") then
				if index ~= #clause_spec.items then
					errors.raise("syntax", "guard else clause must be last")
				end

				if #clause.items == 1 then
					return k(condition)
				end

				local clause_body = {}

				for clause_index = 2, #clause.items do
					clause_body[#clause_body + 1] = clause.items[clause_index]
				end

				return eval_sequence_cps(clause_body, clause_scope, execution, k)
			end

			return eval_form_cps(test_form, clause_scope, execution, function(test_value)
				if not is_truthy_for_mode(test_value, scope, execution) then
					return check_clause(index + 1)
				end

				if #clause.items == 1 then
					return k(test_value)
				end

				if #clause.items == 3 and is_unbound_keyword(clause_scope, clause.items[2], "=>") then
					return eval_form_cps(clause.items[3], clause_scope, execution, function(recipient)
						return apply_callable_cps(recipient, {
							test_value,
						}, execution, k)
					end)
				end

				local clause_body = {}

				for clause_index = 2, #clause.items do
					clause_body[#clause_body + 1] = clause.items[clause_index]
				end

				return eval_sequence_cps(clause_body, clause_scope, execution, k)
			end)
		end

		return check_clause(2)
	end

	local handler = value.builtin("guard-handler", function(args)
		error({
			kind = "guard_raise",
			token = token,
			condition = args[1],
		}, 0)
	end, {
	})
	local handlers = execution.exception_handlers or {}

	execution.exception_handlers = handlers
	table.insert(handlers, handler)

	local ok, result = pcall(function()
		return eval_sequence_cps(body, scope, execution, function(item)
			if handlers[#handlers] == handler then
				table.remove(handlers)
			end

			return k(item)
		end)
	end)

	if ok then
		return result
	end

	if handlers[#handlers] == handler then
		table.remove(handlers)
	end

	local condition

	if errors.is_flow_control(result) then
		if type(result) ~= "table" or result.kind ~= "guard_raise" or result.token ~= token then
			error(result, 0)
		end

		condition = result.condition
	else
		condition = errors.to_condition(result)
	end

	return handle_condition(condition)
end)

-- All continuation-aware evaluation funnels through this dispatcher. The
-- direct evaluator above stays the readability-first path for ordinary forms.
function eval_expanded_form_cps(form, scope, execution, k)
	checkpoint(execution)

	if is_cl_keyword_symbol(form, scope, execution) then
		return k(form)
	end

	if value.is_symbol(form) then
		if use_special_lookup(scope, form.name, execution) then
			return k(resolve_special_value(binding_scope(scope, form), form.name, execution))
		end

		return k(env.get(binding_scope(scope, form), form.name))
	end

	if not value.is_list(form) then
		return k(form)
	end

	if #form.items == 0 then
		return k(form)
	end

	local head = form.items[1]

	if value.is_symbol(head) then
		local binding = lookup_binding(scope, head)

		if value.is_syntax(binding) then
			local expanded = expand_syntax_binding(binding.transformer, form, scope, execution)
			return eval_form_cps(expanded, scope, execution, k)
		end

		local handler = special_forms_cps[head.name]

		if handler ~= nil and binding == nil then
			if cl_only_special_forms[head.name] and not cl_compat_enabled(scope, execution) then
				handler = nil
			end
		end

		if handler ~= nil and binding == nil then
			return handler(form, scope, execution, k)
		end

		local direct_handler = special_forms[head.name]

		if direct_handler ~= nil and binding == nil then
			if cl_only_special_forms[head.name] and not cl_compat_enabled(scope, execution) then
				direct_handler = nil
			end
		end

		if direct_handler ~= nil and binding == nil then
			return k(direct_handler(form, scope, eval_form, execution))
		end
	end

	return eval_form_cps(form.items[1], scope, execution, function(callable)
		return eval_args_cps(form.items, 2, scope, execution, {}, function(args)
			return apply_callable_cps(callable, args, execution, k)
		end)
	end)
end

function eval_form_cps(form, scope, execution, k)
	return eval_expanded_form_cps(expand.form(form, scope), scope, execution, k)
end

-- run_cps is the synchronous boundary between the interpreter's internal
-- continuation protocol and ordinary host callers.
function run_cps(execution, starter)
	local finished = false
	local result

	local function finish(item)
		finished = true
		result = item
		return item
	end

	local current = function()
		return starter(finish)
	end

	while true do
		local ok, err = pcall(current)

		if ok then
			if finished then
				return result
			end

			return result
		end

		if type(err) ~= "table" or err.kind ~= "continuation_transfer" then
			error(err, 0)
		end

		finished = false
		current = function()
			return run_dynamic_transition_cps(
				execution,
				current_dynamic_stack(execution),
				err.target_stack or {},
				function()
					execution.exception_handlers = builtins.copy_exception_handlers(err.target_handlers or {})
					return err.target_k(err.value)
				end
			)
		end
	end
end

apply_callable = function(callable, args, execution)
	return run_cps(execution, function(k)
		return apply_callable_cps(callable, args, execution, k)
	end)
end

eval_sequence = function(forms, scope, _, execution)
	return run_cps(execution, function(k)
		return eval_sequence_cps(forms, scope, execution, k)
	end)
end

eval_expanded_form = function(form, scope, execution)
	return run_cps(execution, function(k)
		return eval_expanded_form_cps(form, scope, execution, k)
	end)
end

eval_form = function(form, scope, execution)
	return run_cps(execution, function(k)
		return eval_form_cps(form, scope, execution, k)
	end)
end

function evaluator.new_execution(options)
	options = options or {}

	return {
		cancelled = false,
		engine = options.engine or "interp",
		step_budget = options.step_budget,
		yield_every = options.yield_every,
		on_yield = options.on_yield,
		steps = 0,
		yield_counter = 0,
		dynamic_stack = {},
		exception_handlers = {},
	}
end

local function attach_execution_helpers(execution)
	execution.copy_dynamic_stack = copy_dynamic_stack
	execution.continue_to = function(target_k, target_stack, target_handlers, item)
		error({
			kind = "continuation_transfer",
			target_k = target_k,
			target_stack = copy_dynamic_stack(target_stack or {}),
			target_handlers = builtins.copy_exception_handlers(target_handlers or {}),
			value = item,
		}, 0)
	end
	execution.eval_in_env = function(form, scope)
		if form_needs_cps(form) then
			return run_cps(execution, function(k)
				return eval_form_cps(form, scope, execution, k)
			end)
		end

		return eval_form_direct(form, scope, execution)
	end

	return execution
end

-- The public evaluator API stays synchronous even though the engine underneath
-- may switch into CPS on demand for continuations, exceptions, or dynamic-wind.
function evaluator.eval_form(form, scope, execution)
	local run_execution = attach_execution_helpers(execution or evaluator.new_execution())
	run_execution.dialect = scope ~= nil and scope.dialect or run_execution.dialect
	local dialect = run_execution.dialect or "scheme"

	if dialect == "scheme" and (run_execution.engine == "auto" or run_execution.engine == "vm") then
		local expanded = expand.form(form, scope)

		if not form_needs_cps(expanded) then
			local chunk = vm.try_compile_form(expanded, scope)

			if chunk.compiled ~= false then
				return vm.run_chunk(chunk, scope, run_execution, apply_callable_direct)
			end
		end

		if run_execution.engine == "vm" then
			errors.raise("unsupported", "form is not supported by the Scheme VM")
		end
	end

	if form_needs_cps(form) then
		return run_cps(run_execution, function(k)
			return eval_form_cps(form, scope, run_execution, k)
		end)
	end

	return eval_form_direct(form, scope, run_execution)
end

function evaluator.eval_source(source, scope, execution)
	local run_execution = attach_execution_helpers(execution or evaluator.new_execution())
	run_execution.dialect = scope ~= nil and scope.dialect or run_execution.dialect
	local dialect = scope ~= nil and scope.dialect or "scheme"
	local forms = reader.read_all(source, {
		dialect = dialect,
	})

	if dialect == "scheme" and (run_execution.engine == "auto" or run_execution.engine == "vm") then
		local expanded_forms = {}

		for index, form in ipairs(forms) do
			expanded_forms[index] = expand.form(form, scope)
		end

		if not body_needs_cps(expanded_forms) then
			local chunk = vm.try_compile_forms(expanded_forms, scope)

			if chunk.compiled ~= false then
				return vm.run_chunk(chunk, scope, run_execution, apply_callable_direct)
			end
		end

		if run_execution.engine == "vm" then
			errors.raise("unsupported", "source is not supported by the Scheme VM")
		end
	end

	if body_needs_cps(forms) then
		return run_cps(run_execution, function(k)
			return eval_sequence_cps(forms, scope, run_execution, k)
		end)
	end

	return eval_sequence_direct(forms, scope, eval_form_direct, run_execution)
end

function evaluator.new_env(parent)
	return env.new(parent)
end

function evaluator.add_builtins(scope, io_adapter)
	return builtins.add(scope, io_adapter)
end

evaluator.apply_callable_direct = function(callable, args, execution)
	return apply_callable_direct(callable, args, execution)
end

return evaluator
