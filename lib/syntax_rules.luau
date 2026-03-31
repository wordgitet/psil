local env = require("./env")
local errors = require("./errors")
local value = require("./value")

-- syntax-rules and related hygiene helpers.
-- This module owns pattern matching, repeated capture bookkeeping, template
-- expansion, and binder-renaming for hygienic introduced identifiers.

local syntax_rules = {}
local gensym_counter = 0

local function is_symbol_named(item, name)
	return value.is_symbol(item) and item.name == name
end

-- Literal identifiers compare by lexical identity when scopes exist, and by
-- name only for unscoped datums.
local function identifier_matches_literal(pattern, datum)
	if not value.is_symbol(datum) then
		return false
	end

	if pattern.scope ~= nil or datum.scope ~= nil then
		return pattern.scope ~= nil and pattern.scope == datum.scope
	end

	return pattern.name == datum.name
end

local function datum_equal(left, right)
	if value.is_symbol(left) and value.is_symbol(right) then
		return left.name == right.name
	end

	if value.is_list(left) and value.is_list(right) then
		if #left.items ~= #right.items then
			return false
		end

		for index = 1, #left.items do
			if not datum_equal(left.items[index], right.items[index]) then
				return false
			end
		end

		return datum_equal(left.tail, right.tail)
	end

	return left == right
end

local function copy_capture(captures)
	local copy = {
		single = {},
		repeated = {},
	}

	for name, item in pairs(captures.single) do
		copy.single[name] = item
	end

	for name, items in pairs(captures.repeated) do
		local repeated_items = {}

		for index, item in ipairs(items) do
			repeated_items[index] = item
		end

		copy.repeated[name] = repeated_items
	end

	return copy
end

-- Repetition capture is tracked occurrence-by-occurrence so ellipsis templates
-- can later replay the same shape during expansion.
local function append_occurrence(captures, occurrence)
	for name, item in pairs(occurrence) do
		local items = captures.repeated[name]

		if items == nil then
			items = {}
			captures.repeated[name] = items
		end

		table.insert(items, item)
	end
end

local function merge_occurrence(occurrence, additions)
	for name, item in pairs(additions) do
		local existing = occurrence[name]

		if existing ~= nil and not datum_equal(existing, item) then
			return false
		end

		occurrence[name] = item
	end

	return true
end

local function scope_datum(item, scope)
	if value.is_symbol(item) then
		if item.scope ~= nil then
			return item
		end

		return value.symbol(item.name, scope)
	end

	if value.is_list(item) then
		local items = {}

		for index, child in ipairs(item.items) do
			items[index] = scope_datum(child, scope)
		end

		local tail

		if item.tail ~= nil then
			tail = scope_datum(item.tail, scope)
		end

		return value.list(items, tail)
	end

	if value.is_vector(item) then
		local items = {}

		for index, child in ipairs(item.items) do
			items[index] = scope_datum(child, scope)
		end

		return value.vector(items)
	end

	return item
end

-- Scoping captured input before substitution preserves definition-site meaning
-- for free identifiers while introduced binders are renamed later.
local function scope_captures(captures, scope)
	local scoped = {
		single = {},
		repeated = {},
	}

	for name, item in pairs(captures.single) do
		scoped.single[name] = scope_datum(item, scope)
	end

	for name, items in pairs(captures.repeated) do
		local repeated = {}

		for index, item in ipairs(items) do
			repeated[index] = scope_datum(item, scope)
		end

		scoped.repeated[name] = repeated
	end

	return scoped
end

local function bind_single(captures, name, item)
	local existing = captures.single[name]

	if existing ~= nil then
		return datum_equal(existing, item)
	end

	captures.single[name] = item
	return true
end

local function collect_pattern_variables(pattern, context, names)
	if value.is_symbol(pattern) then
		local name = pattern.name

		if name ~= "_"
			and name ~= context.ellipsis
			and not context.literal_names[name] then
			names[name] = true
		end

		return
	end

	if not value.is_list(pattern) then
		return
	end

	for _, item in ipairs(pattern.items) do
		collect_pattern_variables(item, context, names)
	end

	if pattern.tail ~= nil then
		collect_pattern_variables(pattern.tail, context, names)
	end
end

-- Pattern matching is the semantic heart of syntax-rules. The recursive list
-- matcher below handles proper lists, dotted tails, literals, and repeated
-- subpatterns using the same capture shape the template expander expects.
local function match_pattern(pattern, datum, context, captures, occurrence)
	if value.is_symbol(pattern) then
		local name = pattern.name

		if name == context.ellipsis then
			return value.is_symbol(datum) and datum.name == name
		end

		if context.literal_names[name] then
			if context.syntax_name == name then
				return value.is_symbol(datum) and datum.name == name
			end

			return identifier_matches_literal(pattern, datum)
		end

		if name == "_" then
			return true
		end

		if occurrence ~= nil then
			local existing = occurrence[name]

			if existing ~= nil then
				return datum_equal(existing, datum)
			end

			occurrence[name] = datum
			return true
		end

		return bind_single(captures, name, datum)
	end

	if value.is_list(pattern) then
		if not value.is_list(datum) then
			return false
		end

		local current_captures = captures

		if occurrence ~= nil then
			current_captures = {
				single = {},
				repeated = {},
			}
		end

		local function match_list(pattern_items, pattern_tail, datum_items, datum_tail, current)
			local function step(pattern_index, datum_index, state)
				if pattern_index > #pattern_items then
					if pattern_tail ~= nil then
						local remaining_items = {}

						for index = datum_index, #datum_items do
							remaining_items[#remaining_items + 1] = datum_items[index]
						end

						local remaining = value.list(remaining_items, datum_tail)
						local trial = copy_capture(state)

						if match_pattern(pattern_tail, remaining, context, trial, nil) then
							return trial
						end

						return nil
					end

					if datum_index > #datum_items and datum_tail == nil then
						return state
					end

					return nil
				end

				local pattern_item = pattern_items[pattern_index]
				local next_pattern = pattern_items[pattern_index + 1]

				if next_pattern ~= nil and is_symbol_named(next_pattern, context.ellipsis) then
					for repeat_count = (#datum_items - datum_index + 1), 0, -1 do
						local trial = copy_capture(state)
						local repeated_names = {}
						local ok = true

						collect_pattern_variables(pattern_item, context, repeated_names)

						for name in pairs(repeated_names) do
							if trial.repeated[name] == nil then
								trial.repeated[name] = {}
							end
						end

						for repeat_index = 1, repeat_count do
							local occurrence = {}
							local item = datum_items[datum_index + repeat_index - 1]

							if not match_pattern(pattern_item, item, context, trial, occurrence) then
								ok = false
								break
							end

							append_occurrence(trial, occurrence)
						end

						if ok then
							local rest = step(
								pattern_index + 2,
								datum_index + repeat_count,
								trial
							)

							if rest ~= nil then
								return rest
							end
						end
					end

					return nil
				end

				local datum_item = datum_items[datum_index]

				if datum_item == nil then
					return nil
				end

				local trial = copy_capture(state)

				if not match_pattern(pattern_item, datum_item, context, trial, nil) then
					return nil
				end

				return step(pattern_index + 1, datum_index + 1, trial)
			end

			return step(1, 1, current)
		end

		local matched = match_list(
			pattern.items,
			pattern.tail,
			datum.items,
			datum.tail,
			current_captures
		)

		if matched == nil then
			return false
		end

		if occurrence ~= nil and not merge_occurrence(occurrence, matched.single) then
			return false
		end

		if occurrence == nil then
			captures.single = matched.single
			captures.repeated = matched.repeated
		end

		return true
	end

	return datum_equal(pattern, datum)
end

local function collect_repeated_names(template, captures, names)
	if value.is_symbol(template) then
		if captures.repeated[template.name] ~= nil then
			names[template.name] = true
		end

		return
	end

	if not value.is_list(template) then
		return
	end

	for _, item in ipairs(template.items) do
		collect_repeated_names(item, captures, names)
	end

	if template.tail ~= nil then
		collect_repeated_names(template.tail, captures, names)
	end
end

local function repetition_count(template, captures)
	local names = {}

	collect_repeated_names(template, captures, names)

	local count

	for name in pairs(names) do
		local items = captures.repeated[name] or {}

		if count == nil then
			count = #items
		elseif count ~= #items then
			errors.raise("syntax", "macro template ellipsis variables expanded at different lengths")
		end
	end

	if count == nil then
		errors.raise("syntax", "macro template used ellipsis without a repeated pattern variable")
	end

	return count
end

local function literal_ellipsis_context(context)
	return {
		ellipsis = "__psil_literal_ellipsis__",
		literal_names = context.literal_names,
		syntax_name = context.syntax_name,
		definition_scope = context.definition_scope,
	}
end

local function extend_rename_env(rename_env, additions)
	local extended = {}

	for name, item in pairs(rename_env or {}) do
		extended[name] = item
	end

	for name, item in pairs(additions or {}) do
		extended[name] = item
	end

	return extended
end

local function fresh_symbol(symbol)
	gensym_counter = gensym_counter + 1
	return value.symbol(
		string.format("__psil_macro_%d_%s", gensym_counter, symbol.name),
		symbol.scope
	)
end

local function fresh_binding_symbol(symbol)
	gensym_counter = gensym_counter + 1
	return value.symbol(
		string.format("__psil_macro_%d_%s", gensym_counter, symbol.name)
	)
end

local function is_introduced_symbol(item)
	return value.is_symbol(item) and item.scope ~= nil
end

local expand_template

-- Introduced binders must be renamed before template substitution so macro
-- output does not accidentally capture user code.
local function rename_symbol_binding(symbol, rename_env)
	if not is_introduced_symbol(symbol) then
		return symbol, rename_env
	end

	local renamed = fresh_binding_symbol(symbol)
	local additions = {
		[symbol.name] = renamed,
	}

	return renamed, extend_rename_env(rename_env, additions)
end

-- This is where hygiene and template substitution meet: captures are replayed,
-- repeated groups are expanded, and introduced binders get fresh names.
local function expand_binding_symbol(template, context, captures, repetition_index, rename_env)
	local expanded = expand_template(template, context, captures, repetition_index, rename_env)
	local renamed

	renamed, rename_env = rename_symbol_binding(expanded, rename_env)
	return renamed, rename_env
end

expand_template = function(template, context, captures, repetition_index, rename_env)
	if value.is_symbol(template) then
		local name = template.name

		if template.scope == nil then
			local repeated = captures.repeated[name]

			if repeated ~= nil then
				if repetition_index == nil then
					errors.raise(
						"syntax",
						string.format("macro template repeated variable '%s' used outside ellipsis", name)
					)
				end

				local item = repeated[repetition_index]

				if item == nil then
					errors.raise(
						"syntax",
						string.format("macro template repeated variable '%s' was missing a value", name)
					)
				end

				return item
			end

			local single = captures.single[name]

			if single ~= nil then
				return single
			end
		end

		local renamed = rename_env and rename_env[name]

		if renamed ~= nil then
			return renamed
		end

		return value.symbol(name, template.scope or context.definition_scope)
	end

	if value.is_list(template) then
		if #template.items == 2
			and template.tail == nil
			and is_symbol_named(template.items[1], context.ellipsis) then
			return expand_template(
				template.items[2],
				literal_ellipsis_context(context),
				captures,
				repetition_index,
				rename_env
			)
		end

		local head = template.items[1]

		if value.is_symbol(head) then
			local head_name = head.name

			if head_name == "syntax-rules" then
				local nested_captures = scope_captures(captures, context.definition_scope)
				local nested_context = {
					ellipsis = context.ellipsis,
					literal_names = context.literal_names,
					syntax_name = context.syntax_name,
					definition_scope = nil,
				}
				local items = {
					head,
				}
				local rule_index = 3

				if value.is_symbol(template.items[2]) and value.is_list(template.items[3]) then
					items[#items + 1] = template.items[2]
					items[#items + 1] = template.items[3]
					rule_index = 4
				else
					items[#items + 1] = template.items[2]
				end

				for index = rule_index, #template.items do
					local rule = template.items[index]

					if not value.is_list(rule) or #rule.items ~= 2 then
						errors.raise("syntax", "nested syntax-rules clauses must be pairs")
					end

					items[#items + 1] = value.list({
						expand_template(
							rule.items[1],
							nested_context,
							nested_captures,
							repetition_index,
							rename_env
						),
						expand_template(
							rule.items[2],
							nested_context,
							nested_captures,
							repetition_index,
							rename_env
						),
					})
				end

				return value.list(items)
			end

			if head_name == "define" and #template.items >= 3 then
				local items = {
					expand_template(head, context, captures, repetition_index, rename_env),
				}
				local target_form = template.items[2]
				local body_renames = rename_env or {}

				if value.is_list(target_form) and #target_form.items >= 1 then
					local target_items = {
						expand_template(
							target_form.items[1],
							context,
							captures,
							repetition_index,
							rename_env
						),
					}
					local target_tail

					for index = 2, #target_form.items do
						target_items[index], body_renames = expand_binding_symbol(
							target_form.items[index],
							context,
							captures,
							repetition_index,
							body_renames
						)
					end

					if target_form.tail ~= nil then
						target_tail, body_renames = expand_binding_symbol(
							target_form.tail,
							context,
							captures,
							repetition_index,
							body_renames
						)
					end

					items[#items + 1] = value.list(target_items, target_tail)
				else
					items[#items + 1] = expand_template(
						target_form,
						context,
						captures,
						repetition_index,
						rename_env
					)
				end

				for index = 3, #template.items do
					items[#items + 1] = expand_template(
						template.items[index],
						context,
						captures,
						repetition_index,
						body_renames
					)
				end

				return value.list(items)
			end

			if head_name == "lambda" and #template.items >= 3 then
				local lambda_head = expand_template(head, context, captures, repetition_index, rename_env)
				local params_form = template.items[2]
				local body_renames = rename_env or {}
				local expanded_params

				if value.is_list(params_form) then
					local params = {}

					for _, param in ipairs(params_form.items) do
						if not value.is_symbol(param) then
							errors.raise("syntax", "macro-expanded lambda parameters must be identifiers")
						end

						local expanded_param = expand_template(
							param,
							context,
							captures,
							repetition_index,
							rename_env
						)
						local renamed_param

						renamed_param, body_renames = rename_symbol_binding(expanded_param, body_renames)
						table.insert(params, renamed_param)
					end

					expanded_params = value.list(params)
				elseif value.is_symbol(params_form) then
					local expanded_param = expand_template(
						params_form,
						context,
						captures,
						repetition_index,
						rename_env
					)
					local renamed_param

					renamed_param, body_renames = rename_symbol_binding(expanded_param, body_renames)
					expanded_params = renamed_param
				else
					errors.raise("syntax", "macro-expanded lambda parameters must be identifiers")
				end

				local items = {
					lambda_head,
					expanded_params,
				}

				for index = 3, #template.items do
					table.insert(
						items,
						expand_template(
							template.items[index],
							context,
							captures,
							repetition_index,
							body_renames
						)
					)
				end

				return value.list(items)
			end

			if (head_name == "let" or head_name == "let*" or head_name == "letrec") and #template.items >= 3 then
				local let_head = expand_template(head, context, captures, repetition_index, rename_env)
				local bindings_form = template.items[2]

				if not value.is_list(bindings_form) then
					errors.raise("syntax", "macro-expanded let bindings must be a list")
				end

				local body_renames = rename_env or {}
				local binding_renames = rename_env or {}
				local bindings = {}
				local pending_bindings = {}

				for _, binding in ipairs(bindings_form.items) do
					if not value.is_list(binding) or #binding.items ~= 2 then
						errors.raise("syntax", "macro-expanded let bindings must be pairs")
					end

					local expanded_name = expand_template(
						binding.items[1],
						context,
						captures,
						repetition_index,
						rename_env
					)
					local renamed_name

					renamed_name, body_renames = rename_symbol_binding(expanded_name, body_renames)
					table.insert(pending_bindings, {
						name = renamed_name,
						value_form = binding.items[2],
					})
				end

				if head_name == "let*" then
					binding_renames = body_renames
				elseif head_name == "letrec" then
					binding_renames = body_renames
				end

				for index, binding in ipairs(pending_bindings) do
					local rhs_renames = rename_env or {}

					if head_name == "let*" then
						rhs_renames = binding_renames
					elseif head_name == "letrec" then
						rhs_renames = body_renames
					end

					local expanded_value = expand_template(
						binding.value_form,
						context,
						captures,
						repetition_index,
						rhs_renames
					)

					table.insert(bindings, value.list({
						binding.name,
						expanded_value,
					}))

					if head_name == "let*" then
						binding_renames = extend_rename_env(binding_renames, {
							[binding.name.name] = binding.name,
						})
					end
				end

				local items = {
					let_head,
					value.list(bindings),
				}

				for index = 3, #template.items do
					table.insert(
						items,
						expand_template(
							template.items[index],
							context,
							captures,
							repetition_index,
							body_renames
						)
					)
				end

				return value.list(items)
			end

			if (head_name == "let-syntax" or head_name == "letrec-syntax") and #template.items >= 3 then
				local syntax_head = expand_template(head, context, captures, repetition_index, rename_env)
				local bindings_form = template.items[2]

				if not value.is_list(bindings_form) then
					errors.raise("syntax", "macro-expanded let-syntax bindings must be a list")
				end

				local body_renames = rename_env or {}
				local rhs_renames = rename_env or {}
				local bindings = {}
				local pending_bindings = {}

				for _, binding in ipairs(bindings_form.items) do
					if not value.is_list(binding) or #binding.items ~= 2 then
						errors.raise("syntax", "macro-expanded let-syntax bindings must be pairs")
					end

					local renamed_name

					renamed_name, body_renames = expand_binding_symbol(
						binding.items[1],
						context,
						captures,
						repetition_index,
						body_renames
					)
					pending_bindings[#pending_bindings + 1] = {
						name = renamed_name,
						value_form = binding.items[2],
					}
				end

				if head_name == "letrec-syntax" then
					rhs_renames = body_renames
				end

				for _, binding in ipairs(pending_bindings) do
					bindings[#bindings + 1] = value.list({
						binding.name,
						expand_template(
							binding.value_form,
							context,
							captures,
							repetition_index,
							rhs_renames
						),
					})
				end

				local items = {
					syntax_head,
					value.list(bindings),
				}

				for index = 3, #template.items do
					items[#items + 1] = expand_template(
						template.items[index],
						context,
						captures,
						repetition_index,
						body_renames
					)
				end

				return value.list(items)
			end
		end

		local items = {}
		local index = 1

		while index <= #template.items do
			local item = template.items[index]
			local next_item = template.items[index + 1]

			if next_item ~= nil and is_symbol_named(next_item, context.ellipsis) then
				local count = repetition_count(item, captures)

				for repeat_index = 1, count do
					table.insert(
						items,
						expand_template(item, context, captures, repeat_index, rename_env)
					)
				end

				index = index + 2
			else
				table.insert(
					items,
					expand_template(item, context, captures, repetition_index, rename_env)
				)
				index = index + 1
			end
		end

		local tail

		if template.tail ~= nil then
			tail = expand_template(
				template.tail,
				context,
				captures,
				repetition_index,
				rename_env
			)
		end

		return value.list(items, tail)
	end

	return template
end

local function compile_rule(form)
	if not value.is_list(form) or #form.items ~= 2 then
		errors.raise("syntax", "syntax-rules clauses must be (pattern template) pairs")
	end

	return {
		pattern = form.items[1],
		template = form.items[2],
	}
end

function syntax_rules.compile(form, definition_scope, syntax_name)
	if not value.is_list(form)
		or #form.items < 3
		or not is_symbol_named(form.items[1], "syntax-rules") then
		errors.raise("syntax", "define-syntax expected a syntax-rules transformer")
	end

	local ellipsis = "..."
	local literals_form
	local rule_index = 3

	if value.is_symbol(form.items[2]) and value.is_list(form.items[3]) then
		ellipsis = form.items[2].name
		literals_form = form.items[3]
		rule_index = 4
	elseif value.is_list(form.items[2]) then
		literals_form = form.items[2]

		if env.find_frame(definition_scope, "...") ~= nil then
			ellipsis = "__psil_disabled_ellipsis__"
		end
	else
		errors.raise("syntax", "syntax-rules expected a literals list")
	end

	local literal_names = {}

	for _, literal in ipairs(literals_form.items) do
		if not value.is_symbol(literal) then
			errors.raise("syntax", "syntax-rules literals must be identifiers")
		end

		literal_names[literal.name] = true
	end

	if literal_names[ellipsis] then
		ellipsis = "__psil_disabled_ellipsis__"
	end

	local rules = {}

	for index = rule_index, #form.items do
		table.insert(rules, compile_rule(form.items[index]))
	end

	if #rules == 0 then
		errors.raise("syntax", "syntax-rules expected at least one clause")
	end

	return {
		kind = "syntax_rules",
		syntax_name = syntax_name,
		ellipsis = ellipsis,
		literal_names = literal_names,
		rules = rules,
		definition_scope = definition_scope,
	}
end

function syntax_rules.expand(transformer, form)
	if transformer == nil or transformer.kind ~= "syntax_rules" then
		errors.raise("syntax", "unsupported macro transformer")
	end

	for _, rule in ipairs(transformer.rules) do
		local captures = {
			single = {},
			repeated = {},
		}
		local context = {
			ellipsis = transformer.ellipsis,
			literal_names = transformer.literal_names,
			syntax_name = transformer.syntax_name,
			definition_scope = transformer.definition_scope,
		}

		context.literal_names[transformer.syntax_name] = true

		local pattern = rule.pattern

		if value.is_list(pattern) and value.is_symbol(pattern.items[1]) then
			local items = value.copy_items(pattern.items)
			items[1] = value.symbol(transformer.syntax_name, pattern.items[1].scope)
			pattern = value.list(items, pattern.tail)
		end

		if match_pattern(pattern, form, context, captures, nil) then
			return expand_template(rule.template, context, captures, nil, {})
		end
	end

	errors.raise(
		"syntax",
		string.format("macro '%s' did not match any syntax-rules clause", transformer.syntax_name)
	)
end

return syntax_rules
--[[
SPDX-License-Identifier: MPL-2.0
]]
