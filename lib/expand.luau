--[[
SPDX-License-Identifier: MPL-2.0
]]

local env = require("./env")
local errors = require("./errors")
local value = require("./value")

local expand = {}

local form_expanders = {}

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

local function map_expanded(items, expand_form, start_index)
	local expanded_items = {}
	local offset = start_index or 1

	for index = offset, #items do
		table.insert(expanded_items, expand_form(items[index]))
	end

	return expanded_items
end

local function register_form(name, expander)
	form_expanders[name] = expander
end

local function binding_scope(scope, symbol)
	if symbol.scope ~= nil then
		return symbol.scope
	end

	return scope
end

local function empty_list_literal()
	return value.list({
		value.symbol("quote"),
		value.list({}),
	})
end

local function build_begin_form(body_forms)
	local begin_items = {
		value.symbol("begin"),
	}

	for _, body_form in ipairs(body_forms) do
		table.insert(begin_items, body_form)
	end

	return value.list(begin_items)
end

local function expand_define(form, expand_form)
	expect_form_count("define", form.items, 2)

	local target = form.items[2]

	if value.is_symbol(target) then
		expect_form_count("define", form.items, 2, 2)
		return value.list({
			value.symbol("define"),
			target,
			expand_form(form.items[3]),
		})
	end

	if value.is_list(target) and #target.items >= 1 and value.is_symbol(target.items[1]) then
		local lambda_items = {
			value.symbol("lambda"),
			value.list({}),
		}
		local params_form = value.list({})

		for index = 2, #target.items do
			table.insert(params_form.items, target.items[index])
		end

		lambda_items[2] = params_form

		for _, body_form in ipairs(map_expanded(form.items, expand_form, 3)) do
			table.insert(lambda_items, body_form)
		end

		return value.list({
			value.symbol("define"),
			target.items[1],
			value.list(lambda_items),
		})
	end

	errors.raise("type", "define expected a symbol or function signature")
end

local function expand_define_values(form, expand_form)
	expect_form_count("define-values", form.items, 2, 2)

	return value.list({
		value.symbol("define-values"),
		form.items[2],
		expand_form(form.items[3]),
	})
end

local function expand_lambda(form, expand_form)
	expect_form_count("lambda", form.items, 2)

	local expanded_items = {
		form.items[1],
		form.items[2],
	}

	for _, body_form in ipairs(map_expanded(form.items, expand_form, 3)) do
		table.insert(expanded_items, body_form)
	end

	if #expanded_items == 2 then
		errors.raise("arity", "lambda expected at least one body form")
	end

	return value.list(expanded_items)
end

local function expand_case_lambda(form, expand_form)
	expect_form_count("case-lambda", form.items, 1)

	local expanded_items = {
		form.items[1],
	}

	for index = 2, #form.items do
		local clause = form.items[index]

		if not value.is_list(clause) or #clause.items < 2 then
			errors.raise("type", "case-lambda clauses must be (formals body...) lists")
		end

		local expanded_clause = {
			clause.items[1],
		}

		for body_index = 2, #clause.items do
			expanded_clause[#expanded_clause + 1] = expand_form(clause.items[body_index])
		end

		expanded_items[#expanded_items + 1] = value.list(expanded_clause)
	end

	return value.list(expanded_items)
end

local function expand_quote(form)
	expect_form_count("quote", form.items, 1, 1)
	return form
end

local function expand_if(form, expand_form)
	expect_form_count("if", form.items, 2, 3)

	local expanded_items = {
		form.items[1],
		expand_form(form.items[2]),
		expand_form(form.items[3]),
	}

	if form.items[4] ~= nil then
		table.insert(expanded_items, expand_form(form.items[4]))
	end

	return value.list(expanded_items)
end

local function expand_begin(form, expand_form)
	expect_form_count("begin", form.items, 1)

	local expanded_items = {
		form.items[1],
	}

	for _, body_form in ipairs(map_expanded(form.items, expand_form, 2)) do
		table.insert(expanded_items, body_form)
	end

	return value.list(expanded_items)
end

local function expand_dynamic_wind(form, expand_form)
	expect_form_count("dynamic-wind", form.items, 3, 3)
	return value.list({
		form.items[1],
		expand_form(form.items[2]),
		expand_form(form.items[3]),
		expand_form(form.items[4]),
	})
end

local function expand_when_like(name, form, expand_form, inverted)
	expect_form_count(name, form.items, 2)

	local condition = expand_form(form.items[2])
	local body_forms = map_expanded(form.items, expand_form, 3)

	if #body_forms == 0 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	local begin_form = build_begin_form(body_forms)

	if inverted then
		return value.list({
			value.symbol("if"),
			condition,
			empty_list_literal(),
			begin_form,
		})
	end

	return value.list({
		value.symbol("if"),
		condition,
		begin_form,
	})
end

local function expand_cond(form, expand_form)
	expect_form_count("cond", form.items, 1)

	local expanded_items = {
		form.items[1],
	}

	for index = 2, #form.items do
		local clause = form.items[index]

		if not value.is_list(clause) or #clause.items == 0 then
			errors.raise("type", "cond clauses must be non-empty lists")
		end

		local expanded_clause = {
			clause.items[1],
		}

		for clause_index = 2, #clause.items do
			table.insert(expanded_clause, expand_form(clause.items[clause_index]))
		end

		if #expanded_clause == 1 then
			errors.raise("arity", "cond clauses must have at least one body form")
		end

		table.insert(expanded_items, value.list(expanded_clause))
	end

	return value.list(expanded_items)
end

local function expand_binding_form(name, form, expand_form)
	expect_form_count(name, form.items, 2)

	if name == "let" and value.is_symbol(form.items[2]) then
		local bindings_form = form.items[3]

		if not value.is_list(bindings_form) then
			errors.raise("type", "let bindings must be a list")
		end

		local expanded_bindings = {}
		local expanded_items = {
			form.items[1],
			form.items[2],
		}

		for _, binding in ipairs(bindings_form.items) do
			if not value.is_list(binding) or #binding.items ~= 2 then
				errors.raise("type", "let bindings must be pairs")
			end

			if not value.is_symbol(binding.items[1]) then
				errors.raise("type", "let binding names must be symbols")
			end

			table.insert(expanded_bindings, value.list({
				binding.items[1],
				expand_form(binding.items[2]),
			}))
		end

		table.insert(expanded_items, value.list(expanded_bindings))

		for _, body_form in ipairs(map_expanded(form.items, expand_form, 4)) do
			table.insert(expanded_items, body_form)
		end

		if #expanded_items == 3 then
			errors.raise("arity", "let expected at least one body form")
		end

		return value.list(expanded_items)
	end

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	local expanded_bindings = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", string.format("%s bindings must be pairs", name))
		end

		if not value.is_symbol(binding.items[1]) then
			errors.raise("type", string.format("%s binding names must be symbols", name))
		end

		table.insert(expanded_bindings, value.list({
			binding.items[1],
			expand_form(binding.items[2]),
		}))
	end

	local expanded_items = {
		form.items[1],
		value.list(expanded_bindings),
	}

	for index = 3, #form.items do
		table.insert(expanded_items, form.items[index])
	end

	if #expanded_items == 2 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	return value.list(expanded_items)
end

local function expand_define_syntax(form)
	expect_form_count("define-syntax", form.items, 2, 2)
	return form
end

local function expand_local_syntax_form(name, form, expand_form)
	expect_form_count(name, form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", string.format("%s bindings must be a list", name))
	end

	local expanded_bindings = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", string.format("%s bindings must be pairs", name))
		end

		if not value.is_symbol(binding.items[1]) then
			errors.raise("type", string.format("%s binding names must be symbols", name))
		end

		table.insert(expanded_bindings, value.list({
			binding.items[1],
			binding.items[2],
		}))
	end

	local expanded_items = {
		form.items[1],
		value.list(expanded_bindings),
	}

	for _, body_form in ipairs(map_expanded(form.items, expand_form, 3)) do
		table.insert(expanded_items, body_form)
	end

	if #expanded_items == 2 then
		errors.raise("arity", string.format("%s expected at least one body form", name))
	end

	return value.list(expanded_items)
end

local function expand_parameterize(form, expand_form)
	expect_form_count("parameterize", form.items, 2)

	local bindings_form = form.items[2]

	if not value.is_list(bindings_form) then
		errors.raise("type", "parameterize bindings must be a list")
	end

	local expanded_bindings = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding) or #binding.items ~= 2 then
			errors.raise("type", "parameterize bindings must be pairs")
		end

		expanded_bindings[#expanded_bindings + 1] = value.list({
			expand_form(binding.items[1]),
			expand_form(binding.items[2]),
		})
	end

	local expanded_items = {
		form.items[1],
		value.list(expanded_bindings),
	}

	for _, body_form in ipairs(map_expanded(form.items, expand_form, 3)) do
		expanded_items[#expanded_items + 1] = body_form
	end

	if #expanded_items == 2 then
		errors.raise("arity", "parameterize expected at least one body form")
	end

	return value.list(expanded_items)
end

register_form("quote", expand_quote)
register_form("if", expand_if)
register_form("define", expand_define)
register_form("define-values", expand_define_values)
register_form("define-syntax", expand_define_syntax)
register_form("lambda", expand_lambda)
register_form("case-lambda", expand_case_lambda)
register_form("begin", expand_begin)
register_form("dynamic-wind", expand_dynamic_wind)
register_form("progn", function(form, expand_form)
	expect_form_count("progn", form.items, 1)

	local begin_items = {
		value.symbol("begin"),
	}

	for _, body_form in ipairs(map_expanded(form.items, expand_form, 2)) do
		table.insert(begin_items, body_form)
	end

	return value.list(begin_items)
end)
register_form("when", function(form, expand_form)
	return expand_when_like("when", form, expand_form, false)
end)
register_form("unless", function(form, expand_form)
	return expand_when_like("unless", form, expand_form, true)
end)
register_form("cond", expand_cond)
register_form("let", function(form, expand_form)
	return expand_binding_form("let", form, expand_form)
end)
register_form("let*", function(form, expand_form)
	return expand_binding_form("let*", form, expand_form)
end)
register_form("let-syntax", function(form, expand_form)
	return expand_local_syntax_form("let-syntax", form, expand_form)
end)
register_form("letrec-syntax", function(form, expand_form)
	return expand_local_syntax_form("letrec-syntax", form, expand_form)
end)
register_form("parameterize", expand_parameterize)

function expand.form(form, scope)
	if value.is_symbol(form) or not value.is_list(form) then
		return form
	end

	if #form.items == 0 then
		return form
	end

	local head = form.items[1]

	if value.is_symbol(head) then
		if env.find_frame(binding_scope(scope, head), head.name) ~= nil then
			return form
		end

		local expander = form_expanders[head.name]

		if expander ~= nil then
			return expander(form, function(child)
				return expand.form(child, scope)
			end, scope)
		end
	end

	return form
end

function expand.all(forms, scope)
	local expanded_forms = {}

	for _, form in ipairs(forms) do
		table.insert(expanded_forms, expand.form(form, scope))
	end

	return expanded_forms
end

return expand