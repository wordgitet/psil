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

local evaluator = {}
local special_forms = {}
local special_forms_cps = {}
local eval_expanded_form
local eval_form
local eval_expanded_form_cps
local eval_form_cps
local apply_callable_cps
local run_cps
local eval_expanded_sequence_cps
local expand_syntax_binding

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

	for _, form in ipairs(forms) do
		checkpoint(execution)
		result = eval_form(form, scope, execution)
	end

	return result
end

local function eval_expanded_sequence(forms, scope, execution)
	local result = value.list({})

	for _, form in ipairs(forms) do
		checkpoint(execution)
		result = eval_expanded_form(form, scope, execution)
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
				next_value = apply_callable(callable.converter, {
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

		return callable.fn(args, apply_callable, execution)
	end

	if value.is_closure(callable) then
		local call_scope = bind.bind_args(callable.env, callable.param_spec, args)

		-- Closures can stay on the simpler direct path when their bodies do not
		-- need continuation-aware evaluation. Pre-expanding once per call keeps
		-- local macro definitions visible without re-expanding each form later.
		if callable.preexpand_body then
			local expanded_body = {}

			for index, form in ipairs(callable.body) do
				expanded_body[index] = expand.form(form, call_scope)
			end

			if callable.needs_cps then
				return run_cps(execution, function(k)
					return eval_expanded_sequence_cps(expanded_body, call_scope, execution, k)
				end)
			end

			return eval_expanded_sequence(expanded_body, call_scope, execution)
		end

		if callable.needs_cps then
			return run_cps(execution, function(k)
				return eval_sequence_cps(callable.body, call_scope, execution, k)
			end)
		end

		return eval_sequence(callable.body, call_scope, eval_form, execution)
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
		apply_callable(active_from[index].after, {}, execution)
	end

	if execution ~= nil then
		execution.dynamic_stack = copy_dynamic_stack(active_from)
	end

	for index = prefix + 1, #active_to do
		apply_callable(active_to[index].before, {}, execution)
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

	apply_callable(before_fn, {}, execution)
	entered_stack[#entered_stack + 1] = frame

	if execution ~= nil then
		execution.dynamic_stack = entered_stack
	end

	local ok, result = pcall(function()
		return apply_callable(thunk_fn, {}, execution)
	end)
	local active_stack = current_dynamic_stack(execution)

	if stack_contains_frame(active_stack, frame) then
		if execution ~= nil then
			execution.dynamic_stack = previous_stack
		end

		apply_callable(after_fn, {}, execution)
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

local function install_syntax_callable_wrappers(target_scope, definition_scope)
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
	["call-with-current-continuation"] = true,
	["call/cc"] = true,
	["with-exception-handler"] = true,
	["raise"] = true,
	["raise-continuable"] = true,
	["error"] = true,
	["guard"] = true,
	["dynamic-wind"] = true,
	["parameterize"] = true,
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

function eval_form(form, scope, execution)
	return eval_expanded_form(expand.form(form, scope), scope, execution)
end

function eval_expanded_form(form, scope, execution)
	checkpoint(execution)

	if value.is_symbol(form) then
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
			return eval_form(expanded, scope, execution)
		end

		local handler = special_forms[head.name]

		if handler ~= nil and binding == nil then
			return handler(form, scope, eval_expanded_form, execution)
		end
	end

	local callable = eval_form(form.items[1], scope, execution)
	local args = {}

	for index = 2, #form.items do
		args[index - 1] = eval_form(form.items[index], scope, execution)
	end

	return apply_callable(callable, args, execution)
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

	if value.is_truthy(condition) then
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
		local test_value = false

		if is_unbound_keyword(clause_scope, test_form, "else") then
			if index ~= #clause_spec.items then
				errors.raise("syntax", "guard else clause must be last")
			end

			matches = true
			test_value = condition
		else
			test_value = eval_form_impl(test_form, clause_scope, execution)
			matches = value.is_truthy(test_value)
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

		if not value.is_truthy(result) then
			return result
		end
	end

	return result
end)

register_special_form("or", function(form, scope, eval_form_impl, execution)
	for index = 2, #form.items do
		local result = eval_form_impl(form.items[index], scope, execution)

		if value.is_truthy(result) then
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
				local expanded_body

				if clause.preexpand_body then
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

	local let_scope

	if sequential then
		let_scope = env.new(scope)

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

			local item = eval_form_impl(binding.items[2], let_scope, execution)
			env.define(let_scope, name_form.name, item)
		end
	else
		local names = {}
		local values = {}

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
			table.insert(values, eval_form_impl(binding.items[2], scope, execution))
		end

		let_scope = env.extend(scope, names, values)
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
	expect_form_count("begin", form.items, 1)
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
			matches = value.is_truthy(eval_form_impl(test_form, scope, execution))
		end

		if matches then
			if #clause.items == 3
				and is_unbound_keyword(scope, clause.items[2], "=>") then
				local test_value

				if is_unbound_keyword(scope, test_form, "else") then
					test_value = true
				else
					test_value = eval_form_impl(test_form, scope, execution)
				end

				local recipient = eval_form_impl(clause.items[3], scope, execution)
				return apply_callable(recipient, {
					test_value,
				}, execution)
			end

			if #clause.items == 1 then
				errors.raise("arity", "cond clauses must have at least one body form")
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

		if value.is_truthy(done) then
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

register_special_form("set!", function(form, scope, eval_form_impl, execution)
	expect_form_count("set!", form.items, 2, 2)

	local target = form.items[2]

	if not value.is_symbol(target) then
		errors.raise("type", "set! expected a symbol target")
	end

	local item = eval_form_impl(form.items[3], scope, execution)
	return env.set(scope, target.name, item)
end)

local apply_callable_direct = apply_callable
local eval_sequence_direct = eval_sequence
local eval_form_direct = eval_form
local eval_expanded_form_direct = eval_expanded_form

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
		local call_scope = bind.bind_args(callable.env, callable.param_spec, args)

		if callable.preexpand_body then
			local expanded_body = {}

			for index, form in ipairs(callable.body) do
				expanded_body[index] = expand.form(form, call_scope)
			end

			return eval_expanded_sequence_cps(expanded_body, call_scope, execution, k)
		end

		return eval_sequence_cps(callable.body, call_scope, execution, k)
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

	local body_start = bindings_index + 1
	local body = {}

	for index = body_start, #form.items do
		body[#body + 1] = form.items[index]
	end

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

		local function bind_next(index)
			if index > #bindings_form.items then
				return eval_sequence_cps(body, let_scope, execution, k)
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
				env.define(let_scope, name_form.name, item)
				return bind_next(index + 1)
			end)
		end

		return bind_next(1)
	end

	local names = {}

	local function collect_values(index, values_now)
		if index > #bindings_form.items then
			local let_scope = env.extend(scope, names, values_now)
			return eval_sequence_cps(body, let_scope, execution, k)
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
		if value.is_truthy(condition) then
			return eval_form_cps(form.items[3], scope, execution, k)
		end

		if form.items[4] ~= nil then
			return eval_form_cps(form.items[4], scope, execution, k)
		end

		return k(value.list({}))
	end)
end)

register_special_form_cps("begin", function(form, scope, execution, k)
	expect_form_count("begin", form.items, 1)
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
			if not value.is_truthy(item) then
				return k(item)
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
			if value.is_truthy(item) then
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
				local expanded_body

				if clause.preexpand_body then
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
			if not value.is_truthy(test_value) then
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
				errors.raise("arity", "cond clauses must have at least one body form")
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
					if value.is_truthy(done) then
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
				if not value.is_truthy(test_value) then
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

	if value.is_symbol(form) then
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
			return handler(form, scope, execution, k)
		end

		local direct_handler = special_forms[head.name]

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

	if form_needs_cps(form) then
		return run_cps(run_execution, function(k)
			return eval_form_cps(form, scope, run_execution, k)
		end)
	end

	return eval_form_direct(form, scope, run_execution)
end

function evaluator.eval_source(source, scope, execution)
	local run_execution = attach_execution_helpers(execution or evaluator.new_execution())
	local forms = reader.read_all(source)

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

return evaluator