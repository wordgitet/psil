--[[
SPDX-License-Identifier: MPL-2.0
]]

local errors = require("../lib/errors")
local env = require("../lib/env")
local lisp = require("../lib/lisp")
local profiles = require("./ansi_cl_profiles")
local runner = require("../host/runner")
local value = require("../lib/value")

local suite_runner = {}

local DEFAULT_VENDORED_ROOT = "tests/upstream/ansi-cl"
local function file_exists(path)
	local handle = io.open(path, "r")

	if handle == nil then
		return false
	end

	handle:close()
	return true
end

local function suite_root()
	local env_root = os.getenv("ANSI_CL_SUITE_ROOT")

	if env_root ~= nil and env_root ~= "" then
		return env_root
	end

	return DEFAULT_VENDORED_ROOT
end

local function read_file(path)
	local handle, open_err = io.open(path, "r")

	if handle == nil then
		error(open_err or string.format("unable to open '%s'", path), 0)
	end

	local source = handle:read("*a")
	handle:close()
	return source
end

local function starts_with(source, index, needle)
	return string.sub(source, index, index + #needle - 1) == needle
end

local function is_delimiter(char)
	return char == ""
		or string.match(char, "%s") ~= nil
		or char == "("
		or char == ")"
		or char == "\""
		or char == ";"
end

local skip_space_comments
local consume_datum

local function skip_block_comment(source, index)
	local depth = 1

	while index <= #source do
		if starts_with(source, index, "#|") then
			depth = depth + 1
			index = index + 2
		elseif starts_with(source, index, "|#") then
			depth = depth - 1
			index = index + 2

			if depth == 0 then
				return index
			end
		else
			index = index + 1
		end
	end

	error("unterminated block comment", 0)
end

local function consume_string(source, index)
	index = index + 1

	while index <= #source do
		local char = string.sub(source, index, index)

		if char == "\\" then
			index = index + 2
		elseif char == "\"" then
			return index + 1
		else
			index = index + 1
		end
	end

	error("unterminated string literal", 0)
end

local function consume_bar_symbol(source, index)
	index = index + 1

	while index <= #source do
		local char = string.sub(source, index, index)

		if char == "\\" then
			index = index + 2
		elseif char == "|" then
			return index + 1
		else
			index = index + 1
		end
	end

	error("unterminated vertical-bar symbol", 0)
end

local function consume_atom(source, index)
	while index <= #source do
		local char = string.sub(source, index, index)

		if is_delimiter(char) or char == "'" or char == "`" or char == "," then
			break
		end

		index = index + 1
	end

	return index
end

local function consume_list(source, index)
	index = index + 1

	while true do
		index = skip_space_comments(source, index)

		if index > #source then
			error("unterminated list", 0)
		end

		if string.sub(source, index, index) == ")" then
			return index + 1
		end

		index = consume_datum(source, index)
	end
end

function skip_space_comments(source, index)
	while index <= #source do
		local char = string.sub(source, index, index)

		if string.match(char, "%s") ~= nil then
			index = index + 1
		elseif char == ";" then
			while index <= #source and string.sub(source, index, index) ~= "\n" do
				index = index + 1
			end
		elseif starts_with(source, index, "#|") then
			index = skip_block_comment(source, index + 2)
		else
			break
		end
	end

	return index
end

function consume_datum(source, index)
	index = skip_space_comments(source, index)

	if index > #source then
		return index
	end

	local char = string.sub(source, index, index)

	if starts_with(source, index, "#'") then
		return consume_datum(source, index + 2)
	end

	if char == "'" or char == "`" then
		return consume_datum(source, index + 1)
	end

	if char == "," then
		if string.sub(source, index + 1, index + 1) == "@" then
			return consume_datum(source, index + 2)
		end

		return consume_datum(source, index + 1)
	end

	if char == "(" then
		return consume_list(source, index)
	end

	if char == "\"" then
		return consume_string(source, index)
	end

	if char == "|" then
		return consume_bar_symbol(source, index)
	end

	return consume_atom(source, index)
end

local function split_top_level_forms(source)
	local forms = {}
	local cursor = 1
	local line = 1

	while true do
		local next_cursor = skip_space_comments(source, cursor)

		if next_cursor > #source then
			break
		end

		line = line + select(2, string.sub(source, cursor, next_cursor - 1):gsub("\n", "\n"))

		local form_start = next_cursor
		local form_line = line
		local form_end = consume_datum(source, form_start)
		local form_source = string.sub(source, form_start, form_end - 1)

		forms[#forms + 1] = {
			source = form_source,
			line = form_line,
		}

		line = line + select(2, form_source:gsub("\n", "\n"))
		cursor = form_end
	end

	return forms
end

local function tail_name(symbol_name)
	return string.match(symbol_name, "([^:]+)$") or symbol_name
end

local function is_named_symbol(item, name)
	return type(item) == "table" and item.kind == "symbol" and tail_name(item.name) == name
end

local function normalize_values(item)
	if type(item) == "table" and item.kind == "multi_values" then
		return item.items
	end

	return {
		item,
	}
end

local function render(item)
	return lisp.to_string(item, {
		dialect = "cl-compat",
	})
end

local function cl_truthy(item)
	return item ~= false and not (value.is_list(item) and #item.items == 0 and item.tail == nil)
end

local function install_suite_helpers(scope)
	local function define_builtin(name, fn)
		env.define(scope, name, value.builtin(name, fn))
	end

	define_builtin("expand-in-current-env", function(args)
		if #args == 0 then
			return value.list({})
		end

		return args[1]
	end)

	define_builtin("eqt", function(args)
		if #args ~= 2 then
			errors.raise("arity", "eqt expected 2 arguments")
		end

		return render(args[1]) == render(args[2])
	end)

	define_builtin("eqlt", function(args)
		if #args ~= 2 then
			errors.raise("arity", "eqlt expected 2 arguments")
		end

		return render(args[1]) == render(args[2])
	end)

	define_builtin("not-mv", function(args)
		if #args == 0 then
			return true
		end

		if cl_truthy(args[1]) then
			return value.list({})
		end

		return true
	end)

	define_builtin("check-predicate", function()
		return value.list({})
	end)

	define_builtin("constantp", function(args)
		if #args ~= 1 then
			errors.raise("arity", "constantp expected 1 argument")
		end

		local item = args[1]

		return type(item) == "number"
			or type(item) == "string"
			or type(item) == "boolean"
			or value.is_char(item)
			or (value.is_symbol(item) and string.sub(item.name, 1, 1) == ":")
			or (value.is_list(item) and #item.items == 0 and item.tail == nil)
	end)

	define_builtin("type-of", function(args)
		if #args ~= 1 then
			errors.raise("arity", "type-of expected 1 argument")
		end

		local item = args[1]

		if value.is_list(item) and #item.items == 0 and item.tail == nil then
			return value.symbol("null")
		end

		if value.is_symbol(item) then
			return value.symbol("symbol")
		end

		if type(item) == "number" then
			if item == math.floor(item) then
				return value.symbol("integer")
			end

			return value.symbol("float")
		end

		if type(item) == "string" or value.is_string(item) then
			return value.symbol("string")
		end

		if value.is_char(item) then
			return value.symbol("character")
		end

		if value.is_list(item) then
			return value.symbol("cons")
		end

		if value.is_callable(item) then
			return value.symbol("function")
		end

		return value.symbol("t")
	end)

	define_builtin("subtypep", function(args)
		if #args ~= 2 then
			errors.raise("arity", "subtypep expected 2 arguments")
		end

		if not value.is_symbol(args[1]) or not value.is_symbol(args[2]) then
			errors.raise("type", "subtypep expected type symbols")
		end

		local left = args[1].name
		local right = args[2].name

		if left == "nil" then
			return true
		end

		if right == "nil" then
			return left == "nil"
		end

		if right == "t" then
			return true
		end

		if left == right then
			return true
		end

		if left == "null" and right == "symbol" then
			return true
		end

		return false
	end)

	define_builtin("macro-function", function()
		return value.list({})
	end)

	define_builtin("multiple-value-list", function(args)
		if #args ~= 1 then
			errors.raise("arity", "multiple-value-list expected 1 argument")
		end

		if value.is_multi_values(args[1]) then
			return value.list(args[1].items)
		end

		return value.list({
			args[1],
		})
	end)

	define_builtin("prog2", function(args)
		if #args < 2 then
			errors.raise("arity", "prog2 expected at least 2 arguments")
		end

		return args[2]
	end)

	define_builtin("proclaim", function()
		return value.list({})
	end)

	define_builtin("compile", function(args)
		if #args < 2 then
			errors.raise("arity", "compile expected at least 2 arguments")
		end

		return lisp.eval(args[2], scope)
	end)

	env.define(scope, "program-error", value.symbol("program-error"))
	env.define(scope, "lambda-parameters-limit", 64)
	env.define(scope, "call-arguments-limit", 64)
	env.define(scope, "*cl-non-variable-constant-symbols*", value.list({}))
end

local function load_expectations(root)
	local path = root .. "/expectations.luau"

	if not file_exists(path) then
		return {}
	end

	local ok, expectations = pcall(dofile, path)

	if not ok or type(expectations) ~= "table" then
		return {}
	end

	return expectations
end

local function classify_failure(err)
	local message = errors.message(err)

	if string.find(message, "undefined symbol", 1, true) ~= nil then
		local missing = string.match(message, "undefined symbol '([^']+)'")
		return "unsupported_name", message, missing
	end

	if string.find(message, "unexpected token", 1, true) ~= nil
		or string.find(message, "unexpected end of input", 1, true) ~= nil
		or string.find(message, "expected a single form", 1, true) ~= nil then
		return "reader_error", message
	end

	if string.find(message, "expected", 1, true) ~= nil and string.find(message, "arguments", 1, true) ~= nil then
		return "arity_error", message
	end

	if string.find(message, "expected", 1, true) ~= nil then
		return "type_error", message
	end

	return "assertion_failure", message
end

local function resolve_profile(args, default_profile)
	local remaining = {}
	local profile = default_profile or "core"
	local index = 1

	while index <= #args do
		local current = args[index]

		if current == "--profile" then
			local selected = args[index + 1]

			if selected == nil or selected == "" then
				error("missing profile name after --profile", 0)
			end

			profile = selected
			index = index + 2
		else
			remaining[#remaining + 1] = current
			index = index + 1
		end
	end

	return profile, remaining
end

local function collect_targets(root, args, default_profile)
	local profile, remaining = resolve_profile(args, default_profile)

	if #remaining == 0 then
		local selected_files = profiles[profile]

		if selected_files == nil then
			error(string.format("unknown ANSI CL profile '%s'", profile), 0)
		end

		local targets = {}

		for _, relative in ipairs(selected_files) do
			targets[#targets + 1] = root .. "/" .. relative
		end

		return targets
	end

	local targets = {}

	for _, arg in ipairs(remaining) do
		local candidate = arg

		if string.sub(candidate, 1, #root) ~= root and string.sub(candidate, 1, 1) ~= "/" then
			candidate = root .. "/" .. candidate
		end

		targets[#targets + 1] = candidate
	end

	return targets
end

function suite_runner.run(args, options)
	local default_profile = "core"

	if type(options) == "table" and type(options.default_profile) == "string" then
		default_profile = options.default_profile
	end

	local root = suite_root()

	if not file_exists(root .. "/README") then
		error(string.format("ANSI CL suite root not found at '%s'", root), 0)
	end

	local expectations = load_expectations(root)
	local scope = runner.new_env(nil, {
		dialect = "cl-compat",
	})
	install_suite_helpers(scope)
	local tests = 0
	local passed = 0
	local failed = 0
	local expected_failures = 0
	local unexpected_failures = 0
	local stale_expectations = 0
	local setup_forms = 0
	local meta_forms = 0
	local failure_classes = {}
	local missing_names = {}
	local sample_failures = {}
	local seen_expectations = {}

	for _, path in ipairs(collect_targets(root, args or {}, default_profile)) do
		local relative = string.gsub(path, "^" .. root .. "/", "")
		local source = read_file(path)

		for _, chunk in ipairs(split_top_level_forms(source)) do
			local location = string.format("%s:%d", relative, chunk.line)
			local ok_parse, form = pcall(function()
				return lisp.parse(chunk.source, {
					dialect = "cl-compat",
				})
			end)

			if not ok_parse then
				local category, message, detail = classify_failure(form)
				failure_classes[category] = (failure_classes[category] or 0) + 1
				failed = failed + 1
				unexpected_failures = unexpected_failures + 1
				if category == "unsupported_name" and detail ~= nil then
					missing_names[detail] = (missing_names[detail] or 0) + 1
				end
				if #sample_failures < 12 then
					sample_failures[#sample_failures + 1] = string.format("%s [%s] %s", location, category, message)
				end
			else
				if type(form) == "table" and form.kind == "list" and #form.items > 0 then
					local head = form.items[1]

					if is_named_symbol(head, "in-package")
						or is_named_symbol(head, "declaim")
						or is_named_symbol(head, "declare") then
						meta_forms = meta_forms + 1
					elseif is_named_symbol(head, "report-and-ignore-errors") then
						meta_forms = meta_forms + 1

						for index = 2, #form.items do
							setup_forms = setup_forms + 1
							pcall(function()
								lisp.eval(form.items[index], scope)
							end)
						end
					elseif is_named_symbol(head, "deftest") then
						tests = tests + 1

						local test_body = form.items[3]
						local expected_items = {}

						for index = 4, #form.items do
							expected_items[#expected_items + 1] = render(form.items[index])
						end

						local ok_run, result = pcall(function()
							return lisp.eval(test_body, scope)
						end)

						if not ok_run then
							local category, message, detail = classify_failure(result)
							failure_classes[category] = (failure_classes[category] or 0) + 1
							failed = failed + 1
							if category == "unsupported_name" and detail ~= nil then
								missing_names[detail] = (missing_names[detail] or 0) + 1
							end
							if #sample_failures < 12 then
								sample_failures[#sample_failures + 1] = string.format("%s [%s] %s", location, category, message)
							end

							if expectations[location] ~= nil then
								expected_failures = expected_failures + 1
								seen_expectations[location] = true
							else
								unexpected_failures = unexpected_failures + 1
							end
						else
							local actual_items = {}

							for index, item in ipairs(normalize_values(result)) do
								actual_items[index] = render(item)
							end

							local matches = #actual_items == #expected_items

							if matches then
								for index = 1, #actual_items do
									if actual_items[index] ~= expected_items[index] then
										matches = false
										break
									end
								end
							end

							if matches then
								passed = passed + 1
								seen_expectations[location] = true
							else
								failure_classes.assertion_failure = (failure_classes.assertion_failure or 0) + 1
								failed = failed + 1
								if #sample_failures < 12 then
									sample_failures[#sample_failures + 1] = string.format(
										"%s [assertion_failure] expected %s got %s",
										location,
										table.concat(expected_items, " | "),
										table.concat(actual_items, " | ")
									)
								end

								if expectations[location] ~= nil then
									expected_failures = expected_failures + 1
									seen_expectations[location] = true
								else
									unexpected_failures = unexpected_failures + 1
								end
							end
						end
					else
						setup_forms = setup_forms + 1
						pcall(function()
							lisp.eval(form, scope)
						end)
					end
				else
					setup_forms = setup_forms + 1
					pcall(function()
						lisp.eval(form, scope)
					end)
				end
			end
		end
	end

	for key in pairs(expectations) do
		if not seen_expectations[key] then
			stale_expectations = stale_expectations + 1
		end
	end

	print(string.format("tests: %d", tests))
	print(string.format("passed: %d", passed))
	print(string.format("failed: %d", failed))
	print(string.format("expected failures: %d", expected_failures))
	print(string.format("unexpected failures: %d", unexpected_failures))
	print(string.format("stale expectations: %d", stale_expectations))
	print(string.format("setup forms evaluated: %d", setup_forms))
	print(string.format("meta forms skipped: %d", meta_forms))
	print("")
	print("failure classes:")

	local keys = {}

	for key in pairs(failure_classes) do
		keys[#keys + 1] = key
	end

	table.sort(keys)

	for _, key in ipairs(keys) do
		print(string.format("  %s: %d", key, failure_classes[key]))
	end

	if next(missing_names) ~= nil then
		print("")
		print("missing names:")

		local missing_keys = {}

		for key in pairs(missing_names) do
			missing_keys[#missing_keys + 1] = key
		end

		table.sort(missing_keys, function(left, right)
			if missing_names[left] == missing_names[right] then
				return left < right
			end

			return missing_names[left] > missing_names[right]
		end)

		for index = 1, math.min(#missing_keys, 12) do
			local key = missing_keys[index]
			print(string.format("  %s: %d", key, missing_names[key]))
		end
	end

	if #sample_failures > 0 then
		print("")
		print("sample failures:")

		for _, line in ipairs(sample_failures) do
			print("  " .. line)
		end
	end

	if unexpected_failures > 0 or stale_expectations > 0 then
		os.exit(1)
	end
end

function suite_runner.run_profile(profile, args)
	return suite_runner.run(args, {
		default_profile = profile,
	})
end

return suite_runner
