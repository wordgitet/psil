local errors = require("../lib/errors")
local builtins = require("../lib/builtins")
local env_mod = require("../lib/env")
local lisp = require("../lib/lisp")
local runner = require("../host/runner")
local value = require("../lib/value")

-- Raw Chibi-suite harness.
-- This is test-runner glue, not language semantics: it splits vendored Scheme
-- files into top-level forms, installs lightweight testing helpers, classifies
-- failures, and compares Psil results against upstream expectations.

local suite_runner = {}

local DEFAULT_VENDORED_ROOT = "tests/upstream/chibi"

local function file_exists(path)
	local handle = io.open(path, "r")

	if handle == nil then
		return false
	end

	handle:close()
	return true
end

local function suite_root()
	local env_root = os.getenv("CHIBI_SUITE_ROOT")

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

local function consume_char_literal(source, index)
	index = index + 2

	while index <= #source do
		local char = string.sub(source, index, index)

		if is_delimiter(char) then
			return index
		end

		index = index + 1
	end

	return index
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
		elseif starts_with(source, index, "#;") then
			index = consume_datum(source, index + 2)
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

	if starts_with(source, index, "#(") or starts_with(source, index, "#u8(") then
		local open_index = string.find(source, "(", index, true)
		return consume_list(source, open_index)
	end

	if starts_with(source, index, "#\\") then
		return consume_char_literal(source, index)
	end

	if char == "\"" then
		return consume_string(source, index)
	end

	if char == "|" then
		return consume_bar_symbol(source, index)
	end

	return consume_atom(source, index)
end

-- The harness needs a tiny source-level splitter because upstream files are
-- collections of top-level forms rather than one Psil-specific entrypoint.
local function split_top_level_forms(source)
	local forms = {}
	local cursor = 1
	local line = 1

	while true do
		local skipped = string.sub(source, cursor)
		local next_cursor = skip_space_comments(source, cursor)

		if next_cursor > #source then
			break
		end

		line = line + select(2, string.sub(source, cursor, next_cursor - 1):gsub("\n", "\n"))

		local form_start = next_cursor
		local form_line = line
		local form_end = consume_datum(source, form_start)
		local form_text = string.sub(source, form_start, form_end - 1)

		line = line + select(2, form_text:gsub("\n", "\n"))
		cursor = form_end

		table.insert(forms, {
			text = form_text,
			line = form_line,
		})
	end

	return forms
end

local function root_symbol_name(form)
	if not value.is_list(form) or #form.items == 0 then
		return nil
	end

	local head = form.items[1]

	if value.is_symbol(head) then
		return head.name
	end

	return nil
end

local function snippet_for(text)
	local compact = string.gsub(text, "%s+", " ")

	if #compact > 88 then
		return string.sub(compact, 1, 85) .. "..."
	end

	return compact
end

-- Failure records are normalized here so summary/expectation logic does not
-- need to understand every raw error shape the runner can encounter.
local function make_record(kind, file_path, form_info, root, message)
	return {
		kind = kind,
		file = file_path,
		line = form_info.line,
		root = root,
		snippet = snippet_for(form_info.text),
		message = message,
	}
end

local function normalize_path(path, root)
	local normalized = string.gsub(path, "\\", "/")
	local normalized_root = string.gsub(root or "", "\\", "/")

	if normalized_root ~= "" then
		local prefix = normalized_root

		if string.sub(prefix, -1) ~= "/" then
			prefix = prefix .. "/"
		end

		if string.sub(normalized, 1, #prefix) == prefix then
			return string.sub(normalized, #prefix + 1)
		end
	end

	local cwd = string.gsub((os.getenv("PWD") or ""), "\\", "/")

	if cwd ~= "" then
		local cwd_prefix = cwd

		if string.sub(cwd_prefix, -1) ~= "/" then
			cwd_prefix = cwd_prefix .. "/"
		end

		if string.sub(normalized, 1, #cwd_prefix) == cwd_prefix then
			return string.sub(normalized, #cwd_prefix + 1)
		end
	end

	return normalized
end

local function expectation_key(path, line, root)
	return string.format("%s:%d", normalize_path(path, root), line)
end

local function load_expectations(root)
	local env_path = os.getenv("CHIBI_EXPECTATIONS")
	local path = env_path

	if path == nil or path == "" then
		path = root .. "/expectations.luau"
	end

	if not file_exists(path) then
		return {}, {}
	end

	local chunk, load_err = loadfile(path)

	if chunk == nil then
		error(load_err or string.format("unable to load expectations '%s'", path), 0)
	end

	local ok, result = pcall(chunk)

	if not ok then
		error(result, 0)
	end

	local expectations = result or {}
	local remaining = {}

	for key, entry in pairs(expectations) do
		remaining[key] = entry
	end

	return expectations, remaining
end

local function relevant_expectation_ids(paths, root)
	local ids = {}

	for _, path in ipairs(paths) do
		local normalized = normalize_path(path, root)
		ids[normalized] = true
	end

	return ids
end

local function add_failure(state, record)
	state.total_failures = state.total_failures + 1
	state.by_kind[record.kind] = (state.by_kind[record.kind] or 0) + 1
	record.id = expectation_key(record.file, record.line, state.suite_root)

	local expected = state.expectations[record.id]

	if expected ~= nil and (expected.kind == nil or expected.kind == record.kind) then
		record.expected = true
		state.expected_failures[#state.expected_failures + 1] = record
		state.remaining_expectations[record.id] = nil
	else
		record.expected = false
		state.failures[#state.failures + 1] = record
	end

	if record.kind == "unsupported_name" then
		local symbol = string.match(record.message or "", "undefined symbol '([^']+)'")

		if symbol ~= nil then
			state.missing_symbols[symbol] = (state.missing_symbols[symbol] or 0) + 1
		end
	end
end

local function classify_error(err)
	local message = errors.message(err)
	local kind = type(err) == "table" and err.kind or nil

	if kind == "name" or string.find(message, "undefined symbol", 1, true) ~= nil then
		return "unsupported_name", message
	end

	if kind == "parse" then
		return "parse_error", message
	end

	if kind == "syntax" then
		return "unsupported_syntax", message
	end

	if kind == "type" then
		return "type_error", message
	end

	if kind == "arity" then
		return "arity_error", message
	end

	if kind == "value" then
		return "value_error", message
	end

	return "runtime_error", message
end

-- Value comparison is deliberately a little looser than printer equality:
-- inexact numbers use tolerance, while exact values and structured data still
-- compare recursively and strictly.
local function compare_values(left, right)
	if builtins.is_numeric(left) and builtins.is_numeric(right) then
		if builtins.components_equal(left, right) or lisp.to_string(left) == lisp.to_string(right) then
			return true
		end

		if builtins.is_inexact_value(left) or builtins.is_inexact_value(right) then
			local left_real, left_imag = builtins.numeric_parts(left)
			local right_real, right_imag = builtins.numeric_parts(right)

			local function close_enough(a, b)
				local scale = math.max(1.0, math.abs(a), math.abs(b))
				return math.abs(a - b) <= 1e-6 * scale
			end

			return close_enough(left_real, right_real) and close_enough(left_imag, right_imag)
		end

		return false
	end

	if value.is_list(left) and value.is_list(right) then
		if #left.items ~= #right.items then
			return false
		end

		for index = 1, #left.items do
			if not compare_values(left.items[index], right.items[index]) then
				return false
			end
		end

		if left.tail == nil and right.tail == nil then
			return true
		end

		if left.tail == nil or right.tail == nil then
			return false
		end

		return compare_values(left.tail, right.tail)
	end

	if value.is_vector(left) and value.is_vector(right) then
		if #left.items ~= #right.items then
			return false
		end

		for index = 1, #left.items do
			if not compare_values(left.items[index], right.items[index]) then
				return false
			end
		end

		return true
	end

	if value.is_multi_values(left) and value.is_multi_values(right) then
		if #left.items ~= #right.items then
			return false
		end

		for index = 1, #left.items do
			if not compare_values(left.items[index], right.items[index]) then
				return false
			end
		end

		return true
	end

	return lisp.to_string(left) == lisp.to_string(right)
end

local function feature_matches(requirement, features)
	if value.is_symbol(requirement) then
		if requirement.name == "else" then
			return true
		end

		return features[requirement.name] == true
	end

	if not value.is_list(requirement) or #requirement.items == 0 then
		return false
	end

	local head = root_symbol_name(requirement)

	if head == "and" then
		for index = 2, #requirement.items do
			if not feature_matches(requirement.items[index], features) then
				return false
			end
		end

		return true
	end

	if head == "or" then
		for index = 2, #requirement.items do
			if feature_matches(requirement.items[index], features) then
				return true
			end
		end

		return false
	end

	if head == "not" and requirement.items[2] ~= nil then
		return not feature_matches(requirement.items[2], features)
	end

	return false
end

local run_top_level_form

local function handle_test_form(form, state, file_path, form_info)
	local root = root_symbol_name(form)

	if root == "test-begin" or root == "test-end" or root == "import" then
		state.meta_skipped = state.meta_skipped + 1
		return
	end

	if root == "define" and value.is_symbol(form.items[2]) then
		local name = form.items[2].name

		if name == "*tests-run*"
			or name == "*tests-passed*"
			or name == "test-begin"
			or name == "test-end" then
			state.meta_skipped = state.meta_skipped + 1
			return
		end
	end

	if root == "define-syntax" and value.is_symbol(form.items[2]) then
		local name = form.items[2].name

		if name == "test" or name == "test-assert" or name == "test-error" then
			state.meta_skipped = state.meta_skipped + 1
			return
		end
	end

	if root == "cond-expand" then
		for index = 2, #form.items do
			local clause = form.items[index]

			if value.is_list(clause) and #clause.items >= 1 then
				local requirement = clause.items[1]

				if feature_matches(requirement, state.features) then
					for clause_index = 2, #clause.items do
						run_top_level_form(clause.items[clause_index], state, file_path, form_info)
					end

					return
				end
			end
		end

		state.meta_skipped = state.meta_skipped + 1
		return
	end

	if root == "begin" then
		for index = 2, #form.items do
			run_top_level_form(form.items[index], state, file_path, form_info)
		end

		return
	end

	state.current_context = {
		file = file_path,
		form_info = form_info,
		root = root,
	}

	local ok_setup, result = pcall(lisp.eval, form, state.env)
	state.current_context = nil

	if ok_setup then
		state.setup_forms = state.setup_forms + 1
		return
	end

	local kind, message = classify_error(result)
	add_failure(state, make_record(kind, file_path, form_info, root, message))
end

function run_top_level_form(form, state, file_path, form_info)
	local ok_expand, expanded = pcall(lisp.expand, form, state.env)
	local root = root_symbol_name(form)

	if not ok_expand then
		local kind, message = classify_error(expanded)
		add_failure(state, make_record(kind, file_path, form_info, root, message))
		return
	end

	handle_test_form(expanded, state, file_path, form_info)
end

local function new_state(paths)
	local root = suite_root()
	local expectations, remaining_expectations = load_expectations(root)
	local relevant_ids = relevant_expectation_ids(paths, root)

	for key, _ in pairs(remaining_expectations) do
		local file_key = string.match(key, "^(.-):%d+$")

		if file_key == nil or not relevant_ids[file_key] then
			remaining_expectations[key] = nil
		end
	end

	local state = {
		env = runner.new_env(),
		suite_root = root,
		tests_run = 0,
		tests_passed = 0,
		total_failures = 0,
		setup_forms = 0,
		meta_skipped = 0,
		failures = {},
		expected_failures = {},
		by_kind = {},
		missing_symbols = {},
		expectations = expectations,
		remaining_expectations = remaining_expectations,
		features = {
			r7rs = true,
			psil = true,
		},
	}

	local function record_assertion(message)
		local current = state.current_context or {
			file = "<internal>",
			form_info = {
				line = 0,
				text = "__suite__",
			},
			root = "__suite__",
		}

		add_failure(
			state,
			make_record(
				"assertion_failure",
				current.file,
				current.form_info,
				current.root,
				message
			)
		)
	end

	env_mod.define(state.env, "__suite-record", value.builtin("__suite-record", function(args)
		if #args ~= 2 then
			errors.raise("arity", string.format("__suite-record expected 2 arguments, got %d", #args))
		end

		state.tests_run = state.tests_run + 1

		if compare_values(args[1], args[2]) then
			state.tests_passed = state.tests_passed + 1
		else
			record_assertion(
				string.format(
					"expected %s but got %s",
					lisp.to_string(args[1]),
					lisp.to_string(args[2])
				)
			)
		end

		return args[2]
	end))

	env_mod.define(state.env, "__suite-test-error", value.builtin("__suite-test-error", function(args, apply_callable, execution)
		if #args ~= 1 then
			errors.raise(
				"arity",
				string.format("__suite-test-error expected 1 argument, got %d", #args)
			)
		end

		state.tests_run = state.tests_run + 1

		local ok = pcall(function()
			return apply_callable(args[1], {}, execution)
		end)

		if ok then
			record_assertion("expected an error, but evaluation succeeded")
		else
			state.tests_passed = state.tests_passed + 1
		end

		return value.list({})
	end))

	lisp.eval([[
(begin
	(define (__suite-in-string text)
		(let loop ((index 0) (chars '()))
			(if (= index (string-length text))
				(reverse chars)
				(loop (+ index 1) (cons (string-ref text index) chars)))))
	(define (__suite-in-string-reverse text)
		(let loop ((index 0) (chars '()))
			(if (= index (string-length text))
				chars
				(loop (+ index 1) (cons (string-ref text index) chars)))))
	(define-syntax test
		(syntax-rules ()
			((test name expect expr)
				(test expect expr))
			((test expect expr)
				(__suite-record expect expr))))
	(define-syntax test-values
		(syntax-rules ()
			((test-values expect expr)
				(__suite-record expect expr))))
	(define-syntax test-assert
		(syntax-rules ()
			((test-assert name expr)
				(test-assert expr))
			((test-assert expr)
				(__suite-record #t expr))))
	(define-syntax test-error
		(syntax-rules ()
			((test-error expr)
				(__suite-test-error (lambda () expr)))))
	(define-syntax loop
		(syntax-rules (for in-string in-string-reverse listing =>)
			((loop ((for item (in-string text)) (for result (listing item))) => result)
				(__suite-in-string text))
			((loop ((for item (in-string-reverse text)) (for result (listing item))) => result)
				(__suite-in-string-reverse text))))
	(define (test-begin . name) #f)
	(define (test-end . name) #f))
]], state.env)

	return state
end

local function run_file(path, state)
	local source = read_file(path)
	local forms = split_top_level_forms(source)

	for _, form_info in ipairs(forms) do
		local ok_parse, parsed = pcall(lisp.parse, form_info.text)

		if not ok_parse then
			local kind, message = classify_error(parsed)
			add_failure(
				state,
				make_record(kind, path, form_info, nil, message)
			)
		else
			run_top_level_form(parsed, state, path, form_info)
		end
	end
end

local function sorted_pairs(map)
	local entries = {}

	for key, count in pairs(map) do
		entries[#entries + 1] = {
			key = key,
			count = count,
		}
	end

	table.sort(entries, function(left, right)
		if left.count == right.count then
			return left.key < right.key
		end

		return left.count > right.count
	end)

	return entries
end

local function sorted_expectation_entries(map)
	local entries = {}

	for key, entry in pairs(map) do
		entries[#entries + 1] = {
			key = key,
			entry = entry,
		}
	end

	table.sort(entries, function(left, right)
		return left.key < right.key
	end)

	return entries
end

local function print_summary(state)
	local stale = sorted_expectation_entries(state.remaining_expectations)

	print(string.format("tests: %d", state.tests_run))
	print(string.format("passed: %d", state.tests_passed))
	print(string.format("failed: %d", state.total_failures))
	print(string.format("expected failures: %d", #state.expected_failures))
	print(string.format("unexpected failures: %d", #state.failures))
	print(string.format("stale expectations: %d", #stale))
	print(string.format("setup forms evaluated: %d", state.setup_forms))
	print(string.format("meta forms skipped: %d", state.meta_skipped))

	print("")
	print("failure classes:")

	for _, entry in ipairs(sorted_pairs(state.by_kind)) do
		print(string.format("  %s: %d", entry.key, entry.count))
	end

	if next(state.missing_symbols) ~= nil then
		print("")
		print("top missing symbols:")

		for index, entry in ipairs(sorted_pairs(state.missing_symbols)) do
			if index > 15 then
				break
			end

			print(string.format("  %s: %d", entry.key, entry.count))
		end
	end

	if #state.failures > 0 then
		print("")
		print("sample unexpected failures:")

		for index = 1, math.min(#state.failures, 20) do
			local failure = state.failures[index]
			print(
				string.format(
					"  [%s] %s:%d %s",
					failure.kind,
					failure.file,
					failure.line,
					failure.snippet
				)
			)
			print(string.format("    %s", failure.message))
		end
	end

	if #stale > 0 then
		print("")
		print("stale expectations:")

		for index = 1, math.min(#stale, 20) do
			local entry = stale[index]
			local kind = entry.entry.kind or "any"
			local reason = entry.entry.reason or ""
			print(string.format("  %s [%s]%s", entry.key, kind, reason ~= "" and " - " .. reason or ""))
		end
	end
end

-- The no-arg entrypoint intentionally defaults to the fast official slice.
-- Heavier files like the full raw r7rs suite can still be requested directly.
local function default_suite_paths()
	local root = suite_root()
	local paths = {
		root .. "/r5rs-tests.scm",
		root .. "/division-tests.scm",
		root .. "/syntax-tests.scm",
		root .. "/unicode-tests.scm",
	}

	for _, path in ipairs(paths) do
		if not file_exists(path) then
			error(
				string.format(
					"unable to find Chibi suite file '%s' (set CHIBI_SUITE_ROOT to the vendored or upstream tests directory)",
					path
				),
				0
			)
		end
	end

	return paths
end

function suite_runner.main(argv)
	local paths = {}
	local include_all = false

	for _, arg in ipairs(argv) do
		if arg == "--all" then
			include_all = true
		else
			paths[#paths + 1] = arg
		end
	end

	if #paths == 0 then
		paths = default_suite_paths()

		if include_all then
			paths[#paths + 1] = suite_root() .. "/r7rs-tests.scm"
		end
	end

	local state = new_state(paths)

	for _, path in ipairs(paths) do
		run_file(path, state)
	end

	print_summary(state)

	if #state.failures > 0 or next(state.remaining_expectations) ~= nil then
		os.exit(1)
	end
end

return suite_runner.main({ ... })
--[[
SPDX-License-Identifier: MPL-2.0
]]
