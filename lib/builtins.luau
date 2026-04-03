--[[
SPDX-License-Identifier: MPL-2.0
]]

--!native
--!optimize 2

-- Standard procedures and host-facing runtime helpers for Psil.
-- This module intentionally spans a lot of surface area: numbers, strings,
-- ports, vectors, exceptions, and environment helpers all live here so the
-- evaluator can stay focused on language semantics.

local errors = require("./errors")
local env = require("./env")
local parser = require("./parser")
local printer = require("./printer")
local reader = require("./reader")
local unicode = require("./unicode")
local value = require("./value")

local builtins = {}

function builtins.is_truthy(item, execution)
	if value.is_multi_values(item) then
		if #item.items == 0 then
			item = value.list({})
		else
			item = item.items[1]
		end
	end

	if execution ~= nil and execution.dialect == "cl-compat" then
		return item ~= false and not (value.is_list(item) and #item.items == 0 and item.tail == nil)
	end

	return value.is_truthy(item)
end

-- Multi-value procedures can flow through ordinary call paths, so builtin
-- helpers normalize single values and value packs the same way everywhere.
local function normalize_values(item)
	if value.is_multi_values(item) then
		return item.items
	end

	return {
		item,
	}
end

local function expect_count(name, args, expected)
	if #args ~= expected then
		errors.raise(
			"arity",
			string.format("%s expected %d arguments, got %d", name, expected, #args)
		)
	end
end

local function expect_min_count(name, args, expected)
	if #args < expected then
		errors.raise(
			"arity",
			string.format("%s expected at least %d arguments, got %d", name, expected, #args)
		)
	end
end

-- Bigints exist only for Psil's narrow exact-integer path. Procedures that
-- fundamentally depend on machine-number semantics reject them explicitly.
local function expect_number(name, item)
	if value.is_bigint(item) then
		errors.raise("type", string.format("%s expected a machine number", name))
	end

	if value.is_real(item) then
		return item.value
	end

	if type(item) ~= "number" then
		errors.raise("type", string.format("%s expected a number", name))
	end

	return item
end

local function expect_numeric(name, item)
	if type(item) == "number" or value.is_real(item) or value.is_complex(item) or value.is_bigint(item) then
		return item
	end

	errors.raise("type", string.format("%s expected a number", name))
end

local function expect_list(name, item)
	if not value.is_list(item) then
		errors.raise("type", string.format("%s expected a list", name))
	end

	return item
end

local function expect_proper_list(name, item)
	local list = expect_list(name, item)

	if not value.is_proper_list(list) then
		errors.raise("type", string.format("%s expected a proper list", name))
	end

	return list
end

local function expect_index(name, item)
	local number = expect_number(name, item)

	if number < 0 or math.floor(number) ~= number then
		errors.raise("type", string.format("%s expected a non-negative integer", name))
	end

	return number
end

local function expect_vector(name, item)
	if not value.is_vector(item) then
		errors.raise("type", string.format("%s expected a vector", name))
	end

	return item
end

local function expect_char(name, item)
	if not value.is_char(item) then
		errors.raise("type", string.format("%s expected a character", name))
	end

	return item
end

local function expect_string(name, item)
	if not value.is_string(item) then
		errors.raise("type", string.format("%s expected a string", name))
	end

	return item
end

local function expect_port(name, item, mode)
	if not value.is_port(item) then
		errors.raise("type", string.format("%s expected a port", name))
	end

	if item.closed then
		errors.raise("value", string.format("%s expected an open port", name))
	end

	if mode ~= nil and item.mode ~= mode then
		errors.raise("type", string.format("%s expected a %s port", name, mode))
	end

	return item
end

local function symbol_set_from_list(name, item)
	local list = expect_proper_list(name, item)
	local names = {}

	for _, child in ipairs(list.items) do
		if not value.is_symbol(child) then
			errors.raise("type", string.format("%s expected a list of symbols", name))
		end

		names[child.name] = true
	end

	return names
end

function builtins.expect_environment(name, item)
	if type(item) ~= "table" or type(item.values) ~= "table" then
		errors.raise("type", string.format("%s expected an environment", name))
	end

	return item
end

function builtins.number_type(item)
	if value.is_bigint(item) then
		return "integer"
	end

	if value.is_real(item) then
		local number = item.value

		if number ~= number or number == math.huge or number == -math.huge then
			return nil
		end

		return "float"
	end

	if value.is_complex(item) then
		return nil
	end

	if type(item) ~= "number" or item ~= item or item == math.huge or item == -math.huge then
		return nil
	end

	if math.type ~= nil then
		return math.type(item)
	end

	if math.floor(item) == item then
		return "integer"
	end

	return "float"
end

function builtins.is_numeric(item)
	return type(item) == "number" or value.is_real(item) or value.is_complex(item) or value.is_bigint(item)
end

function builtins.numeric_parts(item)
	if value.is_complex(item) then
		return item.real, item.imag, item
	end

	if value.is_bigint(item) then
		return require("./bigint").to_number(item.text), 0, item
	end

	if value.is_real(item) then
		return item.value, 0, item
	end

	if type(item) == "number" then
		return item, 0, nil
	end

	errors.raise("type", "expected a numeric value")
end

-- Complex numbers stay represented explicitly so predicates and printers can
-- preserve Scheme-visible intent even when the imaginary part is zero.
function builtins.make_complex(real, imag, source)
	if imag == 0 then
		if value.is_real(source) then
			return value.real(real, {
				inexact = true,
				force_decimal = source.force_decimal == true,
				negative_zero = source.negative_zero == true and real == 0,
			})
		end

		if source == nil then
			return real
		end
	end

	local options = {}

	if source ~= nil then
		options.real_inexact = source.real_inexact == true
		options.imag_inexact = source.imag_inexact == true
	else
		options.real_inexact = builtins.number_type(real) == "float"
		options.imag_inexact = builtins.number_type(imag) == "float"
	end

	return value.complex(real, imag, options)
end

function builtins.is_real_number(item)
	if type(item) == "number" or value.is_real(item) or value.is_bigint(item) then
		return true
	end

	if value.is_complex(item) then
		return item.imag == 0 and item.imag_inexact ~= true
	end

	return false
end

function builtins.expect_real_number(name, item)
	if type(item) == "number" then
		return item
	end

	if value.is_real(item) then
		return item.value
	end

	if value.is_bigint(item) then
		local number = require("./bigint").to_number(item.text)

		if number ~= nil then
			return number
		end
	end

	if value.is_complex(item) and item.imag == 0 and item.imag_inexact ~= true then
		return item.real
	end

	errors.raise("type", string.format("%s expected a real number", name))
end

function builtins.components_equal(left, right)
	local left_real, left_imag = builtins.numeric_parts(left)
	local right_real, right_imag = builtins.numeric_parts(right)
	return left_real == right_real and left_imag == right_imag
end

function builtins.numeric_add(left, right)
	if not value.is_complex(left) and not value.is_complex(right) then
		local left_text = nil
		local right_text = nil

		if value.is_bigint(left) then
			left_text = left.text
		elseif not builtins.is_inexact_value(left) then
			local left_real = expect_number("+", left)
			if math.floor(left_real) == left_real then
				left_text = require("./bigint").from_integer(left_real)
			end
		end

		if value.is_bigint(right) then
			right_text = right.text
		elseif not builtins.is_inexact_value(right) then
			local right_real = expect_number("+", right)
			if math.floor(right_real) == right_real then
				right_text = require("./bigint").from_integer(right_real)
			end
		end

		if left_text ~= nil and right_text ~= nil then
			local result_text = require("./bigint").add(left_text, right_text)
			local result_number = tonumber(result_text)

			if result_number ~= nil and math.abs(result_number) <= 9007199254740991 then
				return result_number
			end

			return value.bigint(result_text)
		end

		local left_real = expect_number("+", left)
		local right_real = expect_number("+", right)
		return builtins.normalize_real_result(
			left_real + right_real,
			builtins.is_inexact_value(left) or builtins.is_inexact_value(right)
		)
	end

	local left_real, left_imag, left_source = builtins.numeric_parts(left)
	local right_real, right_imag, right_source = builtins.numeric_parts(right)

	return builtins.make_complex(left_real + right_real, left_imag + right_imag, left_source or right_source)
end

function builtins.numeric_sub(left, right)
	if not value.is_complex(left) and not value.is_complex(right) then
		local left_text = nil
		local right_text = nil

		if value.is_bigint(left) then
			left_text = left.text
		elseif not builtins.is_inexact_value(left) then
			local left_real = expect_number("-", left)
			if math.floor(left_real) == left_real then
				left_text = require("./bigint").from_integer(left_real)
			end
		end

		if value.is_bigint(right) then
			right_text = right.text
		elseif not builtins.is_inexact_value(right) then
			local right_real = expect_number("-", right)
			if math.floor(right_real) == right_real then
				right_text = require("./bigint").from_integer(right_real)
			end
		end

		if left_text ~= nil and right_text ~= nil then
			local result_text = require("./bigint").subtract(left_text, right_text)
			local result_number = tonumber(result_text)

			if result_number ~= nil and math.abs(result_number) <= 9007199254740991 then
				return result_number
			end

			return value.bigint(result_text)
		end

		local left_real = expect_number("-", left)
		local right_real = expect_number("-", right)
		return builtins.normalize_real_result(
			left_real - right_real,
			builtins.is_inexact_value(left) or builtins.is_inexact_value(right)
		)
	end

	local left_real, left_imag, left_source = builtins.numeric_parts(left)
	local right_real, right_imag, right_source = builtins.numeric_parts(right)

	return builtins.make_complex(left_real - right_real, left_imag - right_imag, left_source or right_source)
end

function builtins.numeric_mul(left, right)
	if not value.is_complex(left) and not value.is_complex(right) then
		local left_real = expect_number("*", left)
		local right_real = expect_number("*", right)
		return builtins.normalize_real_result(
			left_real * right_real,
			builtins.is_inexact_value(left) or builtins.is_inexact_value(right)
		)
	end

	local left_real, left_imag, left_source = builtins.numeric_parts(left)
	local right_real, right_imag, right_source = builtins.numeric_parts(right)

	return builtins.make_complex(
		left_real * right_real - left_imag * right_imag,
		left_real * right_imag + left_imag * right_real,
		left_source or right_source
	)
end

function builtins.numeric_div(left, right)
	if not value.is_complex(left) and not value.is_complex(right) then
		local left_real = expect_number("/", left)
		local right_real = expect_number("/", right)
		return builtins.normalize_real_result(
			left_real / right_real,
			builtins.is_inexact_value(left) or builtins.is_inexact_value(right)
		)
	end

	local left_real, left_imag, left_source = builtins.numeric_parts(left)
	local right_real, right_imag, right_source = builtins.numeric_parts(right)
	local denominator = right_real * right_real + right_imag * right_imag

	return builtins.make_complex(
		(left_real * right_real + left_imag * right_imag) / denominator,
		(left_imag * right_real - left_real * right_imag) / denominator,
		left_source or right_source
	)
end

function builtins.signal_scheme_raise(condition, continuable)
	error({
		kind = "scheme_raise",
		object = condition,
		continuable = continuable == true,
	}, 0)
end

-- Scheme raises travel through tagged internal objects so continuations and
-- exception handlers can distinguish them from interpreter bugs.
function builtins.raise_condition(condition, continuable, apply_callable, execution)
	local handlers = execution ~= nil and execution.exception_handlers or nil

	if handlers ~= nil and #handlers > 0 then
		local handler = table.remove(handlers)
		local ok, result = pcall(function()
			return apply_callable(handler, {
				condition,
			}, execution)
		end)

		table.insert(handlers, handler)

		if not ok then
			error(result, 0)
		end

		if continuable then
			return result
		end

		table.remove(handlers)
		local reraised_ok, reraised = pcall(function()
			return builtins.raise_condition(condition, false, apply_callable, execution)
		end)
		table.insert(handlers, handler)

		if reraised_ok then
			return reraised
		end

		error(reraised, 0)
	end

	builtins.signal_scheme_raise(condition, continuable)
end

function builtins.gcd_integer(left, right)
	left = math.abs(left)
	right = math.abs(right)

	while right ~= 0 do
		left, right = right, left % right
	end

	return left
end

function builtins.copy_exception_handlers(handlers)
	local copy = {}

	for index, handler in ipairs(handlers or {}) do
		copy[index] = handler
	end

	return copy
end

function builtins.ratio_parts(number)
	local kind = builtins.number_type(number)

	if kind == nil then
		errors.raise("type", "expected a finite real number")
	end

	if kind == "integer" then
		return number, 1, false
	end

	local text = string.format("%.17g", number)
	local sign = 1

	if string.sub(text, 1, 1) == "-" then
		sign = -1
		text = string.sub(text, 2)
	elseif string.sub(text, 1, 1) == "+" then
		text = string.sub(text, 2)
	end

	local mantissa, exponent_text = string.match(text, "^([^eE]+)[eE]([+-]?%d+)$")
	local exponent = 0

	if mantissa == nil then
		mantissa = text
	else
		exponent = tonumber(exponent_text) or 0
	end

	local whole, fraction = string.match(mantissa, "^(%d+)%.(%d+)$")
	local numerator
	local denominator

	if whole ~= nil then
		numerator = tonumber(whole .. fraction) or 0
		denominator = 10 ^ #fraction
	else
		numerator = tonumber(mantissa) or 0
		denominator = 1
	end

	if exponent > 0 then
		numerator = numerator * (10 ^ exponent)
	elseif exponent < 0 then
		denominator = denominator * (10 ^ (-exponent))
	end

	local divisor = builtins.gcd_integer(numerator, denominator)

	if divisor ~= 0 then
		numerator = numerator / divisor
		denominator = denominator / divisor
	end

	return numerator * sign, denominator, true
end

local function slice_utf8(str, start_index, end_index)
	local length = utf8.len(str)

	if length == nil then
		errors.raise("value", "invalid UTF-8 string")
	end

	start_index = start_index or 0
	end_index = end_index or length

	if start_index < 0 or end_index < start_index or end_index > length then
		errors.raise("value", "substring indices out of range")
	end

	local start_byte = utf8.offset(str, start_index + 1)
	local end_byte

	if end_index >= length then
		end_byte = #str + 1
	else
		end_byte = utf8.offset(str, end_index + 1)
	end

	if start_byte == nil then
		return ""
	end

	return string.sub(str, start_byte, end_byte - 1)
end

-- Runtime strings are stored as codepoints, but ports still move UTF-8 text.
-- These helpers keep slicing and indexing in character space.
local function string_slice_value(name, item, start_index, end_index)
	local text = expect_string(name, item)
	local length = value.string_length(text)

	start_index = start_index or 0
	end_index = end_index or length

	if start_index < 0 or end_index < start_index or end_index > length then
		errors.raise("value", string.format("%s indices out of range", name))
	end

	return value.string_copy(text, start_index, end_index)
end

local function string_codepoint_at(name, item, index)
	local text = expect_string(name, item)
	local codepoint = text.items[index + 1]

	if codepoint == nil then
		errors.raise("value", string.format("%s index out of range", name))
	end

	return codepoint
end

local function skip_reader_space(source, position)
	local index = position
	local length = #source

	local function skip_block_comment(cursor)
		local depth = 1

		while cursor <= length do
			local pair = string.sub(source, cursor, cursor + 1)

			if pair == "#|" then
				depth = depth + 1
				cursor = cursor + 2
			elseif pair == "|#" then
				depth = depth - 1
				cursor = cursor + 2

				if depth == 0 then
					return cursor
				end
			else
				cursor = cursor + 1
			end
		end

		errors.raise("parse", "unterminated block comment")
	end

	while index <= length do
		local char = string.sub(source, index, index)
		local pair = string.sub(source, index, index + 1)

		if string.match(char, "%s") ~= nil then
			index = index + 1
		elseif char == ";" then
			while index <= length and string.sub(source, index, index) ~= "\n" do
				index = index + 1
			end
		elseif pair == "#|" then
			index = skip_block_comment(index + 2)
		else
			break
		end
	end

	return index
end

local function read_next_form_from_source(source, position)
	local start = skip_reader_space(source, position or 1)

	if start > #source then
		return nil, start
	end

	local remaining = string.sub(source, start)
	local tokens = reader.tokenize(remaining)

	if #tokens == 0 then
		return nil, start
	end

	local parsed, next_index = parser.parse_first(tokens, 1)

	while parser.is_comment_skipped(parsed) and tokens[next_index] ~= nil do
		parsed, next_index = parser.parse_first(tokens, next_index)
	end

	local next_token = tokens[next_index]

	if next_token == nil then
		return parsed, #source + 1
	end

	return parsed, start + next_token.start - 1
end

local function port_write_text(port, text)
	if port.io_adapter ~= nil and type(port.io_adapter.write) == "function" and port.mode == "output" then
		port.io_adapter:write(text)
		return
	end

	table.insert(port.buffer, text)
end

-- Equality follows the Scheme split: eq?/eqv? stay shallow and identity-like,
-- while equal? walks composite values structurally.
local function eq_impl(left, right)
	if value.is_real(left) or value.is_real(right) then
		if builtins.is_numeric(left) and builtins.is_numeric(right) then
			local left_real, left_imag = builtins.numeric_parts(left)
			local right_real, right_imag = builtins.numeric_parts(right)
			return left_real == right_real and left_imag == right_imag
		end

		return false
	end

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

	if value.is_vector(left) or value.is_vector(right) then
		return left == right
	end

	if value.is_string(left) and value.is_string(right) then
		return value.string_to_utf8(left) == value.string_to_utf8(right)
	end

	if value.is_string(left) or value.is_string(right) then
		return false
	end

	if value.is_complex(left) or value.is_complex(right) then
		if builtins.is_numeric(left) and builtins.is_numeric(right) then
			return builtins.components_equal(left, right)
		end

		return false
	end

	if value.is_char(left) and value.is_char(right) then
		return left.value == right.value
	end

	if value.is_char(left) or value.is_char(right) then
		return false
	end

	if value.is_eof(left) and value.is_eof(right) then
		return true
	end

	if value.is_closure(left) or value.is_closure(right) then
		return left == right
	end

	if value.is_builtin(left) or value.is_builtin(right) then
		return left == right
	end

	return left == right
end

local function equal_impl(left, right)
	if value.is_real(left) or value.is_real(right) then
		if builtins.is_numeric(left) and builtins.is_numeric(right) then
			local left_real, left_imag = builtins.numeric_parts(left)
			local right_real, right_imag = builtins.numeric_parts(right)
			return left_real == right_real and left_imag == right_imag
		end

		return false
	end

	if value.is_symbol(left) and value.is_symbol(right) then
		return left.name == right.name
	end

	if value.is_string(left) and value.is_string(right) then
		if #left.items ~= #right.items then
			return false
		end

		for index = 1, #left.items do
			if left.items[index] ~= right.items[index] then
				return false
			end
		end

		return true
	end

	if value.is_list(left) and value.is_list(right) then
		if #left.items ~= #right.items then
			return false
		end

		for index = 1, #left.items do
			if not equal_impl(left.items[index], right.items[index]) then
				return false
			end
		end

		return equal_impl(left.tail, right.tail)
	end

	if value.is_vector(left) and value.is_vector(right) then
		if #left.items ~= #right.items then
			return false
		end

		for index = 1, #left.items do
			if not equal_impl(left.items[index], right.items[index]) then
				return false
			end
		end

		return true
	end

	if value.is_vector(left) or value.is_vector(right) then
		return false
	end

	if value.is_complex(left) or value.is_complex(right) then
		if builtins.is_numeric(left) and builtins.is_numeric(right) then
			return builtins.components_equal(left, right)
		end

		return false
	end

	if value.is_char(left) and value.is_char(right) then
		return left.value == right.value
	end

	if value.is_char(left) or value.is_char(right) then
		return false
	end

	if value.is_eof(left) and value.is_eof(right) then
		return true
	end

	if value.is_list(left) or value.is_list(right) then
		return false
	end

	if value.is_closure(left) or value.is_closure(right) then
		return left == right
	end

	if value.is_builtin(left) or value.is_builtin(right) then
		return left == right
	end

	return left == right
end

local function arithmetic(name, fn, identity)
	return function(args)
		if #args == 0 then
			if identity == nil then
				errors.raise("arity", string.format("%s expected at least 1 argument", name))
			end

			return identity
		end

		local result = expect_numeric(name, args[1])

		if #args == 1 and name == "-" then
			return builtins.numeric_sub(0, result)
		end

		if #args == 1 and name == "/" then
			return builtins.numeric_div(1, result)
		end

		for index = 2, #args do
			result = fn(result, expect_numeric(name, args[index]))
		end

		return result
	end
end

local function compare(name, fn)
	return function(args)
		expect_min_count(name, args, 1)

		for index = 2, #args do
			local left = args[index - 1]
			local right = args[index]

			if name ~= "=" then
				left = builtins.expect_real_number(name, left)
				right = builtins.expect_real_number(name, right)
			else
				left = expect_numeric(name, left)
				right = expect_numeric(name, right)
			end

			if not fn(left, right) then
				return false
			end
		end

		return true
	end
end

local function cons(args)
	expect_count("cons", args, 2)

	local tail = args[2]
	local items = {
		args[1],
	}

	if value.is_list(tail) then
		for _, item in ipairs(tail.items) do
			table.insert(items, item)
		end

		return value.list(items, tail.tail)
	end

	return value.list(items, tail)
end

local function car(args, _, execution)
	expect_count("car", args, 1)

	local list = expect_list("car", args[1])
	local root, start_index = value.list_root(list)

	if root == nil or start_index == nil or start_index > #root.items then
		if execution ~= nil and execution.dialect == "cl-compat" then
			return value.list({})
		end

		errors.raise("value", "car expected a non-empty list")
	end

	return root.items[start_index]
end

local function cdr(args, _, execution)
	expect_count("cdr", args, 1)

	local list = expect_list("cdr", args[1])
	local root, start_index = value.list_root(list)

	if root == nil or start_index == nil or start_index > #root.items then
		if execution ~= nil and execution.dialect == "cl-compat" then
			return value.list({})
		end

		errors.raise("value", "cdr expected a non-empty list")
	end

	if start_index == #root.items then
		if root.tail ~= nil then
			return root.tail
		end

		return value.list({})
	end

	return value.list_view(root, start_index + 1)
end

local function set_cdr_fn(args)
	expect_count("set-cdr!", args, 2)

	local list = expect_list("set-cdr!", args[1])
	local root, start_index = value.list_root(list)

	if root == nil or start_index == nil or start_index > #root.items then
		errors.raise("value", "set-cdr! expected a non-empty pair")
	end

	local new_tail = args[2]
	local prefix = {}

	for index = 1, start_index do
		prefix[index] = root.items[index]
	end

	if new_tail == list or new_tail == root then
		root.items = prefix
		root.tail = root
	elseif value.is_list(new_tail) then
		root.items = prefix

		for _, item in ipairs(new_tail.items) do
			root.items[#root.items + 1] = item
		end

		root.tail = value.list_tail_value(new_tail)
	else
		root.items = prefix
		root.tail = new_tail
	end

	if list ~= root then
		local refreshed = value.list_view(root, start_index)
		list.items = refreshed.items
		list.tail = refreshed.tail
		list.source_list = refreshed.source_list
		list.source_index = refreshed.source_index
	end

	return value.list({})
end

local function list_fn(args)
	return value.list(value.copy_items(args))
end

local function make_list_fn(args)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("make-list expected 1..2 arguments, got %d", #args))
	end

	local count = expect_index("make-list", args[1])
	local fill = false

	if args[2] ~= nil then
		fill = args[2]
	end

	local items = {}

	for index = 1, count do
		items[index] = fill
	end

	return value.list(items)
end

local function append_fn(args)
	if #args == 0 then
		return value.list({})
	end

	local items = {}
	local tail = nil

	for index = 1, #args - 1 do
		local list = expect_proper_list("append", args[index])

		for _, list_item in ipairs(list.items) do
			table.insert(items, list_item)
		end
	end

	local last = args[#args]

	if value.is_list(last) then
		for _, list_item in ipairs(last.items) do
			table.insert(items, list_item)
		end

		tail = last.tail
	else
		if #items == 0 then
			return last
		end

		tail = last
	end

	return value.list(items, tail)
end

local function null_fn(args)
	expect_count("null?", args, 1)
	return value.is_list(args[1]) and #args[1].items == 0 and args[1].tail == nil
end

local function not_fn(args, _, execution)
	expect_count("not", args, 1)
	return not builtins.is_truthy(args[1], execution)
end

local function symbol_fn(args)
	expect_count("symbol?", args, 1)
	return value.is_symbol(args[1])
end

local function symbol_eq_fn(args)
	expect_min_count("symbol=?", args, 1)

	for _, item in ipairs(args) do
		if not value.is_symbol(item) then
			errors.raise("type", "symbol=? expected symbols")
		end
	end

	for index = 2, #args do
		if args[index].name ~= args[index - 1].name then
			return false
		end
	end

	return true
end

local function number_fn(args)
	expect_count("number?", args, 1)
	return builtins.is_numeric(args[1])
end

local function string_fn(args)
	expect_count("string?", args, 1)
	return value.is_string(args[1])
end

local function char_fn(args)
	expect_count("char?", args, 1)
	return value.is_char(args[1])
end

local function boolean_fn(args)
	expect_count("boolean?", args, 1)
	return type(args[1]) == "boolean"
end

local function list_predicate_fn(args)
	expect_count("list?", args, 1)
	return value.is_proper_list(args[1])
end

local function pair_fn(args)
	expect_count("pair?", args, 1)
	return value.is_list(args[1]) and value.list_item_count(args[1]) > 0
end

local function procedure_fn(args)
	expect_count("procedure?", args, 1)
	return value.is_callable(args[1])
end

local function promise_fn(args)
	expect_count("promise?", args, 1)
	return value.is_promise(args[1])
end

local function atom_fn(args)
	expect_count("atom?", args, 1)
	return not value.is_list(args[1]) or (
		value.list_item_count(args[1]) == 0 and value.list_tail_value(args[1]) == nil
	)
end

local function eq_fn(args)
	expect_count("eq?", args, 2)
	return eq_impl(args[1], args[2])
end

local function eqv_fn(args)
	expect_count("eqv?", args, 2)
	return eq_impl(args[1], args[2])
end

local function equal_fn(args)
	expect_count("equal?", args, 2)
	return equal_impl(args[1], args[2])
end

local function boolean_eq_fn(args)
	expect_min_count("boolean=?", args, 1)

	for _, item in ipairs(args) do
		if type(item) ~= "boolean" then
			errors.raise("type", "boolean=? expected booleans")
		end
	end

	for index = 2, #args do
		if args[index] ~= args[index - 1] then
			return false
		end
	end

	return true
end

local function length_fn(args)
	expect_count("length", args, 1)
	return #expect_proper_list("length", args[1]).items
end

local function reverse_fn(args)
	expect_count("reverse", args, 1)

	local list = expect_proper_list("reverse", args[1])
	local items = {}

	for index = #list.items, 1, -1 do
		table.insert(items, list.items[index])
	end

	return value.list(items)
end

local function nth_fn(args)
	expect_count("nth", args, 2)

	local index = expect_index("nth", args[1])
	local list = expect_proper_list("nth", args[2])
	local item = list.items[index + 1]

	if item == nil then
		errors.raise("value", string.format("nth index %d out of range", index))
	end

	return item
end

local function list_ref_fn(args)
	expect_count("list-ref", args, 2)
	return nth_fn({
		args[2],
		args[1],
	})
end

local function list_tail_fn(args)
	expect_count("list-tail", args, 2)

	local index = expect_index("list-tail", args[2])
	local current = expect_list("list-tail", args[1])

	for _ = 1, index do
		current = cdr({
			current,
		})

		if not value.is_list(current) then
			errors.raise("type", "list-tail expected a proper tail")
		end
	end

	return current
end

local function list_set_fn(args)
	expect_count("list-set!", args, 3)

	local index = expect_index("list-set!", args[2])
	local list = expect_proper_list("list-set!", args[1])

	if index >= #list.items then
		errors.raise("value", "list-set! index out of range")
	end

	list.items[index + 1] = args[3]
	return list
end

local function cadr_fn(args)
	expect_count("cadr", args, 1)
	return car({
		cdr(args),
	})
end

local function build_tail_list(items, start_index)
	local tail_items = {}

	for index = start_index, #items do
		table.insert(tail_items, items[index])
	end

	return value.list(tail_items)
end

local function copy_list(list)
	local items = {}

	for index, item in ipairs(list.items) do
		items[index] = item
	end

	local tail = list.tail

	if value.is_list(tail) then
		tail = copy_list(tail)
	end

	return value.list(items, tail)
end

local function list_copy_fn(args)
	expect_count("list-copy", args, 1)

	if value.is_string(args[1]) then
		return value.string_copy(args[1], 0, value.string_length(args[1]))
	end

	return copy_list(expect_list("list-copy", args[1]))
end

local function member_impl(name, args, comparer)
	expect_count(name, {
		args[1],
		args[2],
	}, 2)

	local needle = args[1]
	local list = expect_proper_list(name, args[2])

	for index, item in ipairs(list.items) do
		if comparer(needle, item) then
			return build_tail_list(list.items, index)
		end
	end

	return false
end

local function assoc_impl(name, args, comparer)
	expect_count(name, {
		args[1],
		args[2],
	}, 2)

	local needle = args[1]
	local list = expect_proper_list(name, args[2])

	for _, entry in ipairs(list.items) do
		if not value.is_list(entry) or #entry.items == 0 then
			errors.raise("type", string.format("%s expected an alist of non-empty lists", name))
		end

		if comparer(needle, entry.items[1]) then
			return entry
		end
	end

	return false
end

local function member_fn(args)
	return member_impl("member", args, equal_impl)
end

local function member_with_compare_fn(args, apply_callable, execution)
	if #args < 2 or #args > 3 then
		errors.raise("arity", string.format("member expected 2..3 arguments, got %d", #args))
	end

	if args[3] == nil then
		return member_impl("member", args, equal_impl)
	end

	if apply_callable == nil then
		errors.raise("state", "member requires evaluator support for custom comparators")
	end

	local needle = args[1]
	local list = expect_proper_list("member", args[2])
	local comparer = args[3]

	if not value.is_callable(comparer) then
		errors.raise("type", "member expected a comparison procedure")
	end

	for index, item in ipairs(list.items) do
		local matches = apply_callable(comparer, {
			needle,
			item,
		}, execution)

		if value.is_truthy(matches) then
			return build_tail_list(list.items, index)
		end
	end

	return false
end

local function memq_fn(args)
	return member_impl("memq", args, eq_impl)
end

local function memv_fn(args)
	return member_impl("memv", args, eq_impl)
end

local function assoc_fn(args)
	return assoc_impl("assoc", args, equal_impl)
end

local function assoc_with_compare_fn(args, apply_callable, execution)
	if #args < 2 or #args > 3 then
		errors.raise("arity", string.format("assoc expected 2..3 arguments, got %d", #args))
	end

	if args[3] == nil then
		return assoc_impl("assoc", args, equal_impl)
	end

	if apply_callable == nil then
		errors.raise("state", "assoc requires evaluator support for custom comparators")
	end

	local needle = args[1]
	local list = expect_proper_list("assoc", args[2])
	local comparer = args[3]

	if not value.is_callable(comparer) then
		errors.raise("type", "assoc expected a comparison procedure")
	end

	for _, entry in ipairs(list.items) do
		if not value.is_list(entry) or #entry.items == 0 then
			errors.raise("type", "assoc expected an alist of non-empty lists")
		end

		local matches = apply_callable(comparer, {
			needle,
			entry.items[1],
		}, execution)

		if value.is_truthy(matches) then
			return entry
		end
	end

	return false
end

local function assq_fn(args)
	return assoc_impl("assq", args, eq_impl)
end

local function assv_fn(args)
	return assoc_impl("assv", args, eq_impl)
end

local function map_like(name, args, apply_callable, execution, keep_results)
	expect_min_count(name, args, 2)

	if apply_callable == nil then
		errors.raise("state", string.format("%s requires evaluator support", name))
	end

	local callable = args[1]
	local lists = {}
	local results = {}

	for index = 2, #args do
		lists[#lists + 1] = expect_list(name, args[index])
	end

	while true do
		local call_args = {}
		local exhausted = false

		for list_index, list in ipairs(lists) do
			local root, start_index = value.list_root(list)

			if root == nil or start_index == nil then
				errors.raise("type", string.format("%s expected lists", name))
			end

			if start_index > #root.items then
				if root.tail ~= nil then
					errors.raise("type", string.format("%s expected proper or cyclic lists", name))
				end

				exhausted = true
				break
			end

			call_args[list_index] = root.items[start_index]
		end

		if exhausted then
			break
		end

		local result = apply_callable(callable, call_args, execution)

		if keep_results then
			results[#results + 1] = result
		end

		for list_index, list in ipairs(lists) do
			lists[list_index] = cdr({
				list,
			})
		end
	end

	if keep_results then
		return value.list(results)
	end

	return value.list({})
end

local function map_fn(args, apply_callable, execution)
	return map_like("map", args, apply_callable, execution, true)
end

local function for_each_fn(args, apply_callable, execution)
	return map_like("for-each", args, apply_callable, execution, false)
end

function builtins.member_with_compare_cps(args, apply_callable, execution, k)
	if #args < 2 or #args > 3 then
		errors.raise("arity", string.format("member expected 2..3 arguments, got %d", #args))
	end

	if args[3] == nil then
		return k(member_impl("member", args, equal_impl))
	end

	if apply_callable == nil then
		errors.raise("state", "member requires evaluator support for custom comparators")
	end

	local needle = args[1]
	local list = expect_proper_list("member", args[2])
	local comparer = args[3]

	if not value.is_callable(comparer) then
		errors.raise("type", "member expected a comparison procedure")
	end

	local function search(index)
		if index > #list.items then
			return k(false)
		end

		return apply_callable(comparer, {
			needle,
			list.items[index],
		}, execution, function(matches)
			if value.is_truthy(matches) then
				return k(build_tail_list(list.items, index))
			end

			return search(index + 1)
		end)
	end

	return search(1)
end

function builtins.assoc_with_compare_cps(args, apply_callable, execution, k)
	if #args < 2 or #args > 3 then
		errors.raise("arity", string.format("assoc expected 2..3 arguments, got %d", #args))
	end

	if args[3] == nil then
		return k(assoc_impl("assoc", args, equal_impl))
	end

	if apply_callable == nil then
		errors.raise("state", "assoc requires evaluator support for custom comparators")
	end

	local needle = args[1]
	local list = expect_proper_list("assoc", args[2])
	local comparer = args[3]

	if not value.is_callable(comparer) then
		errors.raise("type", "assoc expected a comparison procedure")
	end

	local function search(index)
		if index > #list.items then
			return k(false)
		end

		local entry = list.items[index]

		if not value.is_list(entry) or #entry.items == 0 then
			errors.raise("type", "assoc expected an alist of non-empty lists")
		end

		return apply_callable(comparer, {
			needle,
			entry.items[1],
		}, execution, function(matches)
			if value.is_truthy(matches) then
				return k(entry)
			end

			return search(index + 1)
		end)
	end

	return search(1)
end

function builtins.map_like_cps(name, args, apply_callable, execution, keep_results, k)
	expect_min_count(name, args, 2)

	if apply_callable == nil then
		errors.raise("state", string.format("%s requires evaluator support", name))
	end

	local callable = args[1]
	local lists = {}
	local results = {}

	for index = 2, #args do
		lists[#lists + 1] = expect_list(name, args[index])
	end

	local function iterate()
		local call_args = {}

		for list_index, list in ipairs(lists) do
			local root, start_index = value.list_root(list)

			if root == nil or start_index == nil then
				errors.raise("type", string.format("%s expected lists", name))
			end

			if start_index > #root.items then
				if root.tail ~= nil then
					errors.raise("type", string.format("%s expected proper or cyclic lists", name))
				end

				if keep_results then
					return k(value.list(results))
				end

				return k(value.list({}))
			end

			call_args[list_index] = root.items[start_index]
		end

		return apply_callable(callable, call_args, execution, function(result)
			if keep_results then
				results[#results + 1] = result
			end

			for list_index, list in ipairs(lists) do
				lists[list_index] = cdr({
					list,
				})
			end

			return iterate()
		end)
	end

	return iterate()
end

function builtins.string_for_each_cps(args, apply_callable, execution, k)
	expect_min_count("string-for-each", args, 2)

	if apply_callable == nil then
		errors.raise("state", "string-for-each requires evaluator support")
	end

	local callable = args[1]
	local strings = {}
	local shortest

	for index = 2, #args do
		local text = expect_string("string-for-each", args[index])
		local chars = {}

		for _, codepoint in ipairs(text.items) do
			chars[#chars + 1] = value.char(utf8.char(codepoint))
		end

		strings[#strings + 1] = chars

		if shortest == nil or #chars < shortest then
			shortest = #chars
		end
	end

	local function iterate(index)
		if index > (shortest or 0) then
			return k(value.list({}))
		end

		local call_args = {}

		for string_index, chars in ipairs(strings) do
			call_args[string_index] = chars[index]
		end

		return apply_callable(callable, call_args, execution, function()
			return iterate(index + 1)
		end)
	end

	return iterate(1)
end

function builtins.vector_for_each_cps(args, apply_callable, execution, k)
	expect_min_count("vector-for-each", args, 2)

	if apply_callable == nil then
		errors.raise("state", "vector-for-each requires evaluator support")
	end

	local callable = args[1]
	local vectors = {}
	local shortest

	for index = 2, #args do
		local vector = expect_vector("vector-for-each", args[index])
		vectors[#vectors + 1] = vector

		if shortest == nil or #vector.items < shortest then
			shortest = #vector.items
		end
	end

	local function iterate(index)
		if index > (shortest or 0) then
			return k(value.list({}))
		end

		local call_args = {}

		for vector_index, vector in ipairs(vectors) do
			call_args[vector_index] = vector.items[index]
		end

		return apply_callable(callable, call_args, execution, function()
			return iterate(index + 1)
		end)
	end

	return iterate(1)
end

function builtins.apply_cps(args, apply_callable, execution, k)
	if #args < 2 then
		errors.raise("arity", string.format("apply expected at least 2 arguments, got %d", #args))
	end

	if apply_callable == nil then
		errors.raise("state", "apply requires evaluator support")
	end

	local callable = args[1]
	local tail = expect_proper_list("apply", args[#args])
	local final_args = {}

	for index = 2, #args - 1 do
		table.insert(final_args, args[index])
	end

	for _, item in ipairs(tail.items) do
		table.insert(final_args, item)
	end

	return apply_callable(callable, final_args, execution, k)
end

function builtins.call_with_values_cps(args, apply_callable, execution, k)
	expect_count("call-with-values", args, 2)

	if apply_callable == nil then
		errors.raise("state", "call-with-values requires evaluator support")
	end

	return apply_callable(args[1], {}, execution, function(produced)
		return apply_callable(args[2], normalize_values(produced), execution, k)
	end)
end

function builtins.raise_condition_cps(condition, continuable, apply_callable, execution, k)
	local handlers = execution ~= nil and execution.exception_handlers or nil

	if handlers ~= nil and #handlers > 0 then
		local handler = handlers[#handlers]

		return apply_callable(handler, {
			condition,
		}, execution, function(result)
			if continuable then
				return k(result)
			end

			if handlers[#handlers] == handler then
				table.remove(handlers)
			end

			return builtins.raise_condition_cps(condition, false, apply_callable, execution, k)
		end)
	end

	error({
		kind = "scheme_raise",
		object = condition,
		continuable = continuable == true,
	}, 0)
end

function builtins.error_cps(args, apply_callable, execution, k)
	local message = "error"
	local irritants = {}

	if args[1] ~= nil then
		if value.is_string(args[1]) then
			message = value.string_to_utf8(args[1])
		else
			message = printer.to_string(args[1])
		end
	end

	for index = 2, #args do
		irritants[#irritants + 1] = args[index]
	end

	return builtins.raise_condition_cps(errors.exception(message, irritants), false, apply_callable, execution, k)
end

function builtins.raise_cps(args, apply_callable, execution, k)
	expect_count("raise", args, 1)
	return builtins.raise_condition_cps(args[1], false, apply_callable, execution, k)
end

function builtins.raise_continuable_cps(args, apply_callable, execution, k)
	expect_count("raise-continuable", args, 1)
	return builtins.raise_condition_cps(args[1], true, apply_callable, execution, k)
end

function builtins.with_exception_handler_cps(args, apply_callable, execution, k)
	expect_count("with-exception-handler", args, 2)

	if apply_callable == nil then
		errors.raise("state", "with-exception-handler requires evaluator support")
	end

	if execution == nil then
		errors.raise("state", "with-exception-handler requires execution state")
	end

	local handler = args[1]
	local thunk = args[2]
	local handlers = execution.exception_handlers or {}

	execution.exception_handlers = handlers
	table.insert(handlers, handler)

	local ok, result = pcall(function()
		return apply_callable(thunk, {}, execution, function(item)
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

	error(result, 0)
end

function builtins.call_cc_cps(args, apply_callable, execution, k)
	expect_count("call-with-current-continuation", args, 1)

	if apply_callable == nil then
		errors.raise("state", "call-with-current-continuation requires evaluator support")
	end

	if execution == nil or execution.continue_to == nil then
		errors.raise("state", "call-with-current-continuation requires CPS execution support")
	end

	local proc = args[1]
	local captured_stack = execution.copy_dynamic_stack(execution.dynamic_stack or {})
	local captured_handlers = builtins.copy_exception_handlers(execution.exception_handlers or {})
	local continuation = value.builtin("continuation", function(cont_args, _, call_execution)
		expect_count("continuation", cont_args, 1)
		return call_execution.continue_to(k, captured_stack, captured_handlers, cont_args[1])
	end, {
		cps = true,
	})

	return apply_callable(proc, {
		continuation,
	}, execution, k)
end

local function string_for_each_fn(args, apply_callable, execution)
	expect_min_count("string-for-each", args, 2)

	if apply_callable == nil then
		errors.raise("state", "string-for-each requires evaluator support")
	end

	local callable = args[1]
	local strings = {}
	local shortest

	for index = 2, #args do
		local chars = {}
		local text = expect_string("string-for-each", args[index])

		for _, codepoint in ipairs(text.items) do
			chars[#chars + 1] = value.char(utf8.char(codepoint))
		end

		strings[#strings + 1] = chars

		if shortest == nil or #chars < shortest then
			shortest = #chars
		end
	end

	for char_index = 1, shortest or 0 do
		local call_args = {}

		for string_index, chars in ipairs(strings) do
			call_args[string_index] = chars[char_index]
		end

		apply_callable(callable, call_args, execution)
	end

	return value.list({})
end

local function vector_for_each_fn(args, apply_callable, execution)
	expect_min_count("vector-for-each", args, 2)

	if apply_callable == nil then
		errors.raise("state", "vector-for-each requires evaluator support")
	end

	local callable = args[1]
	local vectors = {}
	local shortest

	for index = 2, #args do
		local vector = expect_vector("vector-for-each", args[index])
		vectors[#vectors + 1] = vector

		if shortest == nil or #vector.items < shortest then
			shortest = #vector.items
		end
	end

	for vector_index = 1, shortest or 0 do
		local call_args = {}

		for arg_index, vector in ipairs(vectors) do
			call_args[arg_index] = vector.items[vector_index]
		end

		apply_callable(callable, call_args, execution)
	end

	return value.list({})
end

local function apply_fn(args, apply_callable, execution)
	expect_min_count("apply", args, 2)

	if apply_callable == nil then
		errors.raise("state", "apply requires evaluator support")
	end

	local callable = args[1]
	local tail = expect_proper_list("apply", args[#args])
	local final_args = {}

	for index = 2, #args - 1 do
		table.insert(final_args, args[index])
	end

	for _, item in ipairs(tail.items) do
		table.insert(final_args, item)
	end

	return apply_callable(callable, final_args, execution)
end

local function call_cc_fn(args, apply_callable, execution)
	expect_count("call-with-current-continuation", args, 1)

	if apply_callable == nil then
		errors.raise("state", "call-with-current-continuation requires evaluator support")
	end

	local proc = args[1]
	local token = {}
	local continuation = value.builtin("continuation", function(cont_args)
		expect_count("continuation", cont_args, 1)
		error({
			kind = "continuation_escape",
			token = token,
			value = cont_args[1],
		}, 0)
	end)

	local ok, result = pcall(function()
		return apply_callable(proc, {
			continuation,
		}, execution)
	end)

	if ok then
		return result
	end

	if type(result) == "table"
		and result.kind == "continuation_escape"
		and result.token == token then
		return result.value
	end

	error(result, 0)
end

local function values_fn(args)
	if #args == 1 then
		return args[1]
	end

	return value.multi_values(value.copy_items(args))
end

local function call_with_values_fn(args, apply_callable, execution)
	expect_count("call-with-values", args, 2)

	if apply_callable == nil then
		errors.raise("state", "call-with-values requires evaluator support")
	end

	local produced = apply_callable(args[1], {}, execution)
	local final_args

	if value.is_multi_values(produced) then
		final_args = value.copy_items(produced.items)
	else
		final_args = {
			produced,
		}
	end

	return apply_callable(args[2], final_args, execution)
end

local function force_impl(item, execution)
	if not value.is_promise(item) then
		return item
	end

	if item.forced then
		return item.value
	end

	local result = item.thunk(execution)

	while value.is_promise(result) do
		result = force_impl(result, execution)
	end

	item.value = result
	item.forced = true
	item.thunk = nil
	return result
end

local function force_fn(args, _, execution)
	expect_count("force", args, 1)
	return force_impl(args[1], execution)
end

local function make_promise_fn(args)
	expect_count("make-promise", args, 1)

	if value.is_promise(args[1]) then
		return args[1]
	end

	local item = args[1]
	return value.promise(function()
		return item
	end)
end

local function make_vector_fn(args)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("make-vector expected 1..2 arguments, got %d", #args))
	end

	local size = expect_index("make-vector", args[1])
	local fill = false

	if args[2] ~= nil then
		fill = args[2]
	end

	local items = {}

	for index = 1, size do
		items[index] = fill
	end

	return value.vector(items)
end

local function vector_length_fn(args)
	expect_count("vector-length", args, 1)
	return #expect_vector("vector-length", args[1]).items
end

local function vector_set_fn(args)
	expect_count("vector-set!", args, 3)

	local vector = expect_vector("vector-set!", args[1])
	local index = expect_index("vector-set!", args[2])

	if index >= #vector.items then
		errors.raise("value", string.format("vector-set! index %d out of range", index))
	end

	vector.items[index + 1] = args[3]
	return value.list({})
end

local function vector_ref_fn(args)
	expect_count("vector-ref", args, 2)

	local vector = expect_vector("vector-ref", args[1])
	local index = expect_index("vector-ref", args[2])
	local item = vector.items[index + 1]

	if item == nil then
		errors.raise("value", string.format("vector-ref index %d out of range", index))
	end

	return item
end

local function vector_predicate_fn(args)
	expect_count("vector?", args, 1)
	return value.is_vector(args[1])
end

local function vector_fn(args)
	return value.vector(value.copy_items(args))
end

local function vector_copy_fn(args)
	if #args < 1 or #args > 3 then
		errors.raise("arity", string.format("vector-copy expected 1..3 arguments, got %d", #args))
	end

	local vector = expect_vector("vector-copy", args[1])
	local start_index = 0
	local end_index = #vector.items

	if args[2] ~= nil then
		start_index = expect_index("vector-copy", args[2])
	end

	if args[3] ~= nil then
		end_index = expect_index("vector-copy", args[3])
	end

	local items = {}

	for index = start_index + 1, end_index do
		items[#items + 1] = vector.items[index]
	end

	return value.vector(items)
end

local function vector_append_fn(args)
	local items = {}

	for _, vector in ipairs(args) do
		vector = expect_vector("vector-append", vector)

		for _, item in ipairs(vector.items) do
			items[#items + 1] = item
		end
	end

	return value.vector(items)
end

local function vector_fill_fn(args)
	if #args < 2 or #args > 4 then
		errors.raise("arity", string.format("vector-fill! expected 2..4 arguments, got %d", #args))
	end

	local vector = expect_vector("vector-fill!", args[1])
	local start_index = 0
	local end_index = #vector.items

	if args[3] ~= nil then
		start_index = expect_index("vector-fill!", args[3])
	end

	if args[4] ~= nil then
		end_index = expect_index("vector-fill!", args[4])
	end

	for index = start_index + 1, end_index do
		vector.items[index] = args[2]
	end

	return vector
end

local function vector_copy_bang_fn(args)
	if #args < 3 or #args > 5 then
		errors.raise("arity", string.format("vector-copy! expected 3..5 arguments, got %d", #args))
	end

	local target = expect_vector("vector-copy!", args[1])
	local at = expect_index("vector-copy!", args[2])
	local source = expect_vector("vector-copy!", args[3])
	local start_index = 0
	local end_index = #source.items

	if args[4] ~= nil then
		start_index = expect_index("vector-copy!", args[4])
	end

	if args[5] ~= nil then
		end_index = expect_index("vector-copy!", args[5])
	end

	local copied = {}

	for index = start_index + 1, end_index do
		copied[#copied + 1] = source.items[index]
	end

	for index, item in ipairs(copied) do
		target.items[at + index] = item
	end

	return target
end

local function vector_to_list_fn(args)
	if #args < 1 or #args > 3 then
		errors.raise("arity", string.format("vector->list expected 1..3 arguments, got %d", #args))
	end

	local vector = expect_vector("vector->list", args[1])
	local start_index = 0
	local end_index = #vector.items

	if args[2] ~= nil then
		start_index = expect_index("vector->list", args[2])
	end

	if args[3] ~= nil then
		end_index = expect_index("vector->list", args[3])
	end

	local items = {}

	for index = start_index + 1, math.min(end_index, #vector.items) do
		items[#items + 1] = vector.items[index]
	end

	return value.list(items)
end

local function list_to_vector_fn(args)
	expect_count("list->vector", args, 1)
	local list = expect_proper_list("list->vector", args[1])
	return value.vector(value.copy_items(list.items))
end

local function zero_fn(args)
	expect_count("zero?", args, 1)
	local real, imag = builtins.numeric_parts(expect_numeric("zero?", args[1]))
	return real == 0 and imag == 0
end

local function even_fn(args)
	expect_count("even?", args, 1)
	local number = expect_number("even?", args[1])

	if math.floor(number) ~= number then
		errors.raise("type", "even? expected an integer")
	end

	return number % 2 == 0
end

local function odd_fn(args)
	expect_count("odd?", args, 1)
	local number = expect_number("odd?", args[1])

	if math.floor(number) ~= number then
		errors.raise("type", "odd? expected an integer")
	end

	return math.abs(number % 2) == 1
end

local function positive_fn(args)
	expect_count("positive?", args, 1)
	return builtins.expect_real_number("positive?", args[1]) > 0
end

local function negative_fn(args)
	expect_count("negative?", args, 1)
	return builtins.expect_real_number("negative?", args[1]) < 0
end

local function abs_fn(args)
	expect_count("abs", args, 1)
	local item = expect_numeric("abs", args[1])

	if value.is_complex(item) then
		return math.sqrt(item.real * item.real + item.imag * item.imag)
	end

	return math.abs(expect_number("abs", item))
end

local function max_fn(args)
	expect_min_count("max", args, 1)
	local result = builtins.expect_real_number("max", args[1])
	local inexact = builtins.is_inexact_value(args[1])

	for index = 2, #args do
		local item = builtins.expect_real_number("max", args[index])
		inexact = inexact or builtins.is_inexact_value(args[index])

		if item > result then
			result = item
		end
	end

	return builtins.normalize_real_result(result, inexact)
end

local function min_fn(args)
	expect_min_count("min", args, 1)
	local result = builtins.expect_real_number("min", args[1])
	local inexact = builtins.is_inexact_value(args[1])

	for index = 2, #args do
		local item = builtins.expect_real_number("min", args[index])
		inexact = inexact or builtins.is_inexact_value(args[index])

		if item < result then
			result = item
		end
	end

	return builtins.normalize_real_result(result, inexact)
end

local function trunc_division(a, b)
	local quotient = a / b

	if quotient >= 0 then
		return math.floor(quotient)
	end

	return math.ceil(quotient)
end

function builtins.is_non_finite_number(item)
	return item ~= item or item == math.huge or item == -math.huge
end

function builtins.any_inexact_numbers(...)
	local count = select("#", ...)

	for index = 1, count do
		if builtins.number_type(select(index, ...)) == "float" then
			return true
		end
	end

	return false
end

function builtins.is_inexact_value(item)
	if value.is_real(item) then
		return item.inexact == true
	end

	if value.is_complex(item) then
		return item.real_inexact == true or item.imag_inexact == true
	end

	return false
end

function builtins.normalize_real_result(item, inexact)
	if item == 0 then
		item = 0
	end

	if inexact then
		local number = item + 0.0
		return value.real(number, {
			inexact = true,
			force_decimal = true,
			negative_zero = number == 0 and 1 / number == -math.huge,
		})
	end

	return item
end

function builtins.is_negative_zero(item)
	local number = item

	if value.is_real(item) then
		number = item.value
	elseif type(item) ~= "number" then
		return false
	end

	return number == 0 and 1 / number == -math.huge
end

function builtins.round_to_even_quotient(ratio)
	local lower = math.floor(ratio)
	local fraction = ratio - lower

	if fraction < 0.5 then
		return lower
	end

	if fraction > 0.5 then
		return lower + 1
	end

	if lower % 2 == 0 then
		return lower
	end

	return lower + 1
end

function builtins.balanced_quotient_value(left, right)
	local ratio = left / right
	local lower = math.floor(ratio)
	local upper = math.ceil(ratio)

	if lower == upper then
		return lower
	end

	local lower_distance = math.abs(ratio - lower)
	local upper_distance = math.abs(upper - ratio)

	if lower_distance < upper_distance then
		return lower
	end

	if upper_distance < lower_distance then
		return upper
	end

	local lower_remainder = left - lower * right
	local upper_remainder = left - upper * right

	if lower_remainder < 0 and upper_remainder >= 0 then
		return lower
	end

	if upper_remainder < 0 and lower_remainder >= 0 then
		return upper
	end

	return upper
end

function builtins.division_quotient_value(mode, left, right)
	if mode == "ceiling" then
		return math.ceil(left / right)
	end

	if mode == "floor" then
		return math.floor(left / right)
	end

	if mode == "truncate" then
		return trunc_division(left, right)
	end

	if mode == "round" then
		return builtins.round_to_even_quotient(left / right)
	end

	if mode == "euclidean" then
		if right > 0 then
			return math.floor(left / right)
		end

		return math.ceil(left / right)
	end

	if mode == "balanced" then
		return builtins.balanced_quotient_value(left, right)
	end

	errors.raise("state", string.format("unknown division mode '%s'", tostring(mode)))
end

-- All quotient/remainder families route through one shared model so euclidean,
-- balanced, floor, truncate, and round behavior stay consistent.
function builtins.compute_division_pair(name, mode, left_item, right_item)
	local left = builtins.expect_real_number(name, left_item)
	local right = builtins.expect_real_number(name, right_item)

	if right == 0 then
		errors.raise("value", string.format("%s division by zero", name))
	end

	if builtins.is_non_finite_number(left) or builtins.is_non_finite_number(right) then
		errors.raise("value", string.format("%s expected finite operands", name))
	end

	local inexact = builtins.is_inexact_value(left_item) or builtins.is_inexact_value(right_item)
	local quotient = builtins.division_quotient_value(mode, left, right)
	local remainder = left - quotient * right

	if math.abs(remainder) < 1e-12 then
		remainder = 0
	end

	return builtins.normalize_real_result(quotient, inexact), builtins.normalize_real_result(remainder, inexact)
end

function builtins.division_pair_values(name, mode, args)
	expect_count(name, args, 2)
	local quotient, remainder = builtins.compute_division_pair(name, mode, args[1], args[2])
	return value.multi_values({
		quotient,
		remainder,
	})
end

function builtins.division_quotient_fn(name, mode)
	return function(args)
		expect_count(name, args, 2)
		local quotient = builtins.compute_division_pair(name, mode, args[1], args[2])
		return quotient
	end
end

function builtins.division_remainder_fn(name, mode)
	return function(args)
		expect_count(name, args, 2)
		local _, remainder = builtins.compute_division_pair(name, mode, args[1], args[2])
		return remainder
	end
end

local function remainder_fn(args)
	expect_count("remainder", args, 2)
	local left = builtins.expect_real_number("remainder", args[1])
	local right = builtins.expect_real_number("remainder", args[2])

	if right == 0 then
		errors.raise("value", "remainder division by zero")
	end

	if builtins.is_non_finite_number(left) or builtins.is_non_finite_number(right) then
		errors.raise("value", "remainder expected finite operands")
	end

	return builtins.normalize_real_result(
		left - trunc_division(left, right) * right,
		builtins.is_inexact_value(args[1]) or builtins.is_inexact_value(args[2])
	)
end

local function modulo_fn(args)
	expect_count("modulo", args, 2)
	local left = builtins.expect_real_number("modulo", args[1])
	local right = builtins.expect_real_number("modulo", args[2])

	if right == 0 then
		errors.raise("value", "modulo division by zero")
	end

	return builtins.normalize_real_result(
		left - math.floor(left / right) * right,
		builtins.is_inexact_value(args[1]) or builtins.is_inexact_value(args[2])
	)
end

local function gcd_pair(a, b)
	a = math.abs(a)
	b = math.abs(b)

	while b ~= 0 do
		a, b = b, a % b
	end

	return a
end

local function gcd_fn(args)
	if #args == 0 then
		return 0
	end

	local inexact = false
	local result = math.abs(expect_number("gcd", args[1]))
	inexact = inexact or builtins.is_inexact_value(args[1])

	for index = 2, #args do
		result = gcd_pair(result, expect_number("gcd", args[index]))
		inexact = inexact or builtins.is_inexact_value(args[index])
	end

	return builtins.normalize_real_result(result, inexact)
end

local function lcm_fn(args)
	if #args == 0 then
		return 1
	end

	local inexact = false
	local result = math.abs(expect_number("lcm", args[1]))
	inexact = inexact or builtins.is_inexact_value(args[1])

	for index = 2, #args do
		local item = math.abs(expect_number("lcm", args[index]))
		inexact = inexact or builtins.is_inexact_value(args[index])

		if result == 0 or item == 0 then
			result = 0
		else
			result = math.abs(result * item) / gcd_pair(result, item)
		end
	end

	return builtins.normalize_real_result(result, inexact)
end

local function expt_fn(args)
	expect_count("expt", args, 2)

	local base_text = nil
	local exponent_number

	if value.is_bigint(args[1]) then
		base_text = args[1].text
	elseif not builtins.is_inexact_value(args[1]) then
		local base_number = expect_number("expt", args[1])

		if math.floor(base_number) == base_number then
			base_text = require("./bigint").from_integer(base_number)
		end
	end

	if base_text ~= nil and not builtins.is_inexact_value(args[2]) then
		local ok = pcall(function()
			exponent_number = expect_number("expt", args[2])
		end)

		if ok and math.floor(exponent_number) == exponent_number and exponent_number >= 0 then
			local big = require("./bigint")
			local result_text = big.normalize(big.pow_text(base_text, exponent_number))
			local result_number = tonumber(result_text)

			if result_number ~= nil and math.abs(result_number) <= 9007199254740991 then
				return result_number
			end

			return value.bigint(result_text)
		end
	end

	return builtins.normalize_real_result(
		expect_number("expt", args[1]) ^ expect_number("expt", args[2]),
		builtins.is_inexact_value(args[1]) or builtins.is_inexact_value(args[2])
	)
end

local function square_fn(args)
	expect_count("square", args, 1)

	if value.is_bigint(args[1]) then
		local result_text = require("./bigint").pow_text(args[1].text, 2)
		local result_number = tonumber(result_text)

		if result_number ~= nil and math.abs(result_number) <= 9007199254740991 then
			return result_number
		end

		return value.bigint(result_text)
	end

	local number = expect_number("square", args[1])
	return number * number
end

local function exp_fn(args)
	expect_count("exp", args, 1)
	return builtins.normalize_real_result(math.exp(builtins.expect_real_number("exp", args[1])), true)
end

local function log_fn(args)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("log expected 1..2 arguments, got %d", #args))
	end

	local value_item = expect_numeric("log", args[1])

	if value.is_complex(value_item) then
		local magnitude = math.sqrt(value_item.real * value_item.real + value_item.imag * value_item.imag)
		local angle = math.atan(value_item.imag, value_item.real)
		local result = value.complex(math.log(magnitude), angle, {
			real_inexact = true,
			imag_inexact = true,
		})

		if args[2] == nil then
			return result
		end

		return builtins.numeric_div(result, log_fn({
			args[2],
		}))
	end

	local number = expect_number("log", value_item)

	if number < 0 then
		local complex_result = value.complex(math.log(math.abs(number)), math.pi, {
			real_inexact = true,
			imag_inexact = true,
		})

		if args[2] == nil then
			return complex_result
		end

		return builtins.numeric_div(complex_result, log_fn({
			args[2],
		}))
	end

	local result = math.log(number)

	if args[2] == nil then
		return builtins.normalize_real_result(result, true)
	end

	local base = log_fn({
		args[2],
	})

	local quotient = builtins.numeric_div(result, base)

	if type(quotient) == "number" then
		local rounded = math.floor(quotient + 0.5)

		if math.abs(quotient - rounded) < 1e-12 then
			return builtins.normalize_real_result(rounded, true)
		end
	end

	return quotient
end

local function round_fn(args)
	expect_count("round", args, 1)
	local number = builtins.expect_real_number("round", args[1])
	return builtins.normalize_real_result(
		builtins.round_to_even_quotient(number),
		builtins.is_inexact_value(args[1])
	)
end

local function symbol_to_string_fn(args)
	expect_count("symbol->string", args, 1)

	if not value.is_symbol(args[1]) then
		errors.raise("type", "symbol->string expected a symbol")
	end

	return value.string_from_utf8(args[1].name)
end

local function string_to_symbol_fn(args)
	expect_count("string->symbol", args, 1)

	return value.symbol(value.string_to_utf8(expect_string("string->symbol", args[1])))
end

local function string_length_fn(args)
	expect_count("string-length", args, 1)
	return value.string_length(expect_string("string-length", args[1]))
end

local function string_append_fn(args)
	local parts = {}

	for index, item in ipairs(args) do
		local text = expect_string("string-append", item)

		for _, codepoint in ipairs(text.items) do
			parts[#parts + 1] = codepoint
		end
	end

	return value.string(parts)
end

local function substring_fn(args)
	expect_count("substring", args, 3)
	return string_slice_value(
		"substring",
		args[1],
		expect_index("substring", args[2]),
		expect_index("substring", args[3])
	)
end

local function string_ref_fn(args)
	expect_count("string-ref", args, 2)
	local index = expect_index("string-ref", args[2])
	return value.char(utf8.char(string_codepoint_at("string-ref", args[1], index)))
end

local function string_compare(name, comparator)
	return function(args)
		expect_min_count(name, args, 1)

		for index = 2, #args do
			local left = expect_string(name, args[index - 1])
			local right = expect_string(name, args[index])

			if not comparator(left, right) then
				return false
			end
		end

		return true
	end
end

local function char_compare(name, transform, comparator)
	return function(args)
		expect_min_count(name, args, 1)

		for index = 2, #args do
			local left = transform(expect_char(name, args[index - 1]).value)
			local right = transform(expect_char(name, args[index]).value)

			if not comparator(left, right) then
				return false
			end
		end

		return true
	end
end

local function simple_upper(text)
	return value.string(unicode.map_codepoints(expect_string("string-upcase", text).items, "upper"))
end

local function simple_lower(text)
	return value.string(unicode.map_codepoints(expect_string("string-downcase", text).items, "lower"))
end

local function string_copy_fn(args)
	if #args < 1 or #args > 3 then
		errors.raise("arity", string.format("string-copy expected 1..3 arguments, got %d", #args))
	end

	local start_index = 0
	local end_index = value.string_length(expect_string("string-copy", args[1]))

	if args[2] ~= nil then
		start_index = expect_index("string-copy", args[2])
	end

	if args[3] ~= nil then
		end_index = expect_index("string-copy", args[3])
	end

	return string_slice_value("string-copy", args[1], start_index, end_index)
end

local function string_downcase_fn(args)
	expect_count("string-downcase", args, 1)
	return simple_lower(args[1])
end

local function string_upcase_fn(args)
	expect_count("string-upcase", args, 1)
	return simple_upper(args[1])
end

local function string_foldcase_impl(text)
	return value.string(unicode.map_codepoints(expect_string("string-foldcase", text).items, "fold"))
end

local function string_foldcase_fn(args)
	expect_count("string-foldcase", args, 1)
	return string_foldcase_impl(args[1])
end

local function char_map_fn(name, args, mapper)
	expect_count(name, args, 1)
	return value.char(mapper(expect_char(name, args[1]).value))
end

local function char_predicate_fn(name, args, predicate)
	expect_count(name, args, 1)
	return predicate(expect_char(name, args[1]).value)
end

local function ascii_alpha(char)
	return string.match(char, "^[A-Za-z]$") ~= nil
end

local function char_upper_case_fn(args)
	return char_predicate_fn("char-upper-case?", args, function(char)
		return ascii_alpha(char) and char == simple_upper(char) and char ~= simple_lower(char)
	end)
end

local function char_lower_case_fn(args)
	return char_predicate_fn("char-lower-case?", args, function(char)
		return ascii_alpha(char) and char == simple_lower(char) and char ~= simple_upper(char)
	end)
end

local function char_alphabetic_fn(args)
	return char_predicate_fn("char-alphabetic?", args, ascii_alpha)
end

local function char_numeric_fn(args)
	return char_predicate_fn("char-numeric?", args, function(char)
		return string.match(char, "^%d$") ~= nil
	end)
end

local function char_downcase_fn(args)
	return char_map_fn("char-downcase", args, simple_lower)
end

local function char_upcase_fn(args)
	return char_map_fn("char-upcase", args, simple_upper)
end

local function char_foldcase_fn(args)
	return char_map_fn("char-foldcase", args, string_foldcase_impl)
end

local function string_to_list_fn(args)
	if #args < 1 or #args > 3 then
		errors.raise("arity", string.format("string->list expected 1..3 arguments, got %d", #args))
	end

	local start_index = 0
	local end_index = value.string_length(expect_string("string->list", args[1]))

	if args[2] ~= nil then
		start_index = expect_index("string->list", args[2])
	end

	if args[3] ~= nil then
		end_index = expect_index("string->list", args[3])
	end

	local items = {}

	for index = start_index + 1, end_index do
		items[#items + 1] = value.char(utf8.char(args[1].items[index]))
	end

	return value.list(items)
end

local function list_to_string_fn(args)
	expect_count("list->string", args, 1)

	local list = expect_proper_list("list->string", args[1])
	local parts = {}

	for index, item in ipairs(list.items) do
		parts[index] = expect_char("list->string", item).value
	end

	return value.string_from_utf8(table.concat(parts))
end

local function make_string_fn(args)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("make-string expected 1..2 arguments, got %d", #args))
	end

	local length = expect_index("make-string", args[1])
	local fill = " "

	if args[2] ~= nil then
		fill = expect_char("make-string", args[2]).value
	end

	local items = {}
	local codepoint = utf8.codepoint(fill)

	for index = 1, length do
		items[index] = codepoint
	end

	return value.string(items)
end

local function string_constructor_fn(args)
	local parts = {}

	for index, item in ipairs(args) do
		parts[index] = expect_char("string", item).value
	end

	return value.string_from_utf8(table.concat(parts))
end

local function string_fill_fn(args)
	if #args < 2 or #args > 4 then
		errors.raise("arity", string.format("string-fill! expected 2..4 arguments, got %d", #args))
	end

	local text = expect_string("string-fill!", args[1])
	local start_index = 0
	local end_index = value.string_length(text)

	if args[3] ~= nil then
		start_index = expect_index("string-fill!", args[3])
	end

	if args[4] ~= nil then
		end_index = expect_index("string-fill!", args[4])
	end

	local fill = utf8.codepoint(expect_char("string-fill!", args[2]).value)

	for index = start_index + 1, end_index do
		text.items[index] = fill
	end

	return text
end

local function string_copy_bang_fn(args)
	if #args < 3 or #args > 5 then
		errors.raise("arity", string.format("string-copy! expected 3..5 arguments, got %d", #args))
	end

	local target = expect_string("string-copy!", args[1])
	local at = expect_index("string-copy!", args[2])
	local source = expect_string("string-copy!", args[3])
	local start_index = 0
	local end_index = value.string_length(source)

	if args[4] ~= nil then
		start_index = expect_index("string-copy!", args[4])
	end

	if args[5] ~= nil then
		end_index = expect_index("string-copy!", args[5])
	end

	local copied = {}

	for index = start_index + 1, end_index do
		copied[#copied + 1] = source.items[index]
	end

	for index, codepoint in ipairs(copied) do
		local write_index = at + index

		if target.items[write_index] == nil then
			errors.raise("value", "string-copy! destination out of range")
		end

		target.items[write_index] = codepoint
	end

	return target
end

local function string_to_vector_fn(args)
	if #args < 1 or #args > 3 then
		errors.raise("arity", string.format("string->vector expected 1..3 arguments, got %d", #args))
	end

	local list = string_to_list_fn(args)
	return value.vector(value.copy_items(list.items))
end

local function vector_to_string_fn(args)
	if #args < 1 or #args > 3 then
		errors.raise("arity", string.format("vector->string expected 1..3 arguments, got %d", #args))
	end

	local vector = expect_vector("vector->string", args[1])
	local start_index = 0
	local end_index = #vector.items

	if args[2] ~= nil then
		start_index = expect_index("vector->string", args[2])
	end

	if args[3] ~= nil then
		end_index = expect_index("vector->string", args[3])
	end

	local parts = {}

	for index = start_index + 1, end_index do
		parts[#parts + 1] = expect_char("vector->string", vector.items[index]).value
	end

	return value.string_from_utf8(table.concat(parts))
end

local function char_to_integer_fn(args)
	expect_count("char->integer", args, 1)
	return utf8.codepoint(expect_char("char->integer", args[1]).value)
end

local function digit_value_fn(args)
	expect_count("digit-value", args, 1)
	local codepoint = utf8.codepoint(expect_char("digit-value", args[1]).value)

	if codepoint >= 48 and codepoint <= 57 then
		return codepoint - 48
	end

	if codepoint >= 0x0660 and codepoint <= 0x0669 then
		return codepoint - 0x0660
	end

	if codepoint >= 0x0AE6 and codepoint <= 0x0AEF then
		return codepoint - 0x0AE6
	end

	if codepoint >= 0x0E50 and codepoint <= 0x0E59 then
		return codepoint - 0x0E50
	end

	return false
end

local function integer_to_char_fn(args)
	expect_count("integer->char", args, 1)
	return value.char(utf8.char(expect_index("integer->char", args[1])))
end

local function char_whitespace_fn(args)
	expect_count("char-whitespace?", args, 1)
	local char = expect_char("char-whitespace?", args[1]).value
	return char == " "
		or char == "\t"
		or char == "\n"
		or char == "\r"
		or char == "\v"
		or char == "\f"
		or utf8.codepoint(char) == 0x1680
end

local function char_alphabetic_fn(args)
	expect_count("char-alphabetic?", args, 1)
	local char = expect_char("char-alphabetic?", args[1]).value
	return unicode.is_alphabetic(utf8.codepoint(char))
end

local function char_numeric_fn(args)
	expect_count("char-numeric?", args, 1)
	return digit_value_fn(args) ~= false
end

local function char_upper_case_fn(args)
	expect_count("char-upper-case?", args, 1)
	local char = expect_char("char-upper-case?", args[1]).value
	return unicode.is_upper(utf8.codepoint(char))
end

local function char_lower_case_fn(args)
	expect_count("char-lower-case?", args, 1)
	local char = expect_char("char-lower-case?", args[1]).value
	return unicode.is_lower(utf8.codepoint(char))
end

local function char_upcase_fn(args)
	expect_count("char-upcase", args, 1)
	local mapped = unicode.upper_char(expect_char("char-upcase", args[1]).value)

	if mapped == nil then
		return args[1]
	end

	return value.char(mapped)
end

local function char_downcase_fn(args)
	expect_count("char-downcase", args, 1)
	local mapped = unicode.lower_char(expect_char("char-downcase", args[1]).value)

	if mapped == nil then
		return args[1]
	end

	return value.char(mapped)
end

local function char_foldcase_fn(args)
	expect_count("char-foldcase", args, 1)
	local mapped = unicode.fold_char(expect_char("char-foldcase", args[1]).value)

	if mapped == nil then
		return args[1]
	end

	return value.char(mapped)
end

local function number_to_string_fn(args)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("number->string expected 1..2 arguments, got %d", #args))
	end

	local number_item = expect_numeric("number->string", args[1])
	local radix = 10

	if args[2] ~= nil then
		radix = expect_number("number->string", args[2])
	end

	if radix ~= 2 and radix ~= 8 and radix ~= 10 and radix ~= 16 then
		errors.raise("value", "number->string expected radix 2, 8, 10, or 16")
	end

	if value.is_complex(number_item) then
		if radix ~= 10 then
			errors.raise("value", "number->string expected radix 10 for complex numbers")
		end

		return value.string_from_utf8(printer.to_string(number_item))
	end

	local number = expect_number("number->string", number_item)

	if math.floor(number) ~= number and radix ~= 10 then
		errors.raise("value", "number->string expected an integer for non-decimal radix")
	end

	if radix == 10 then
		if value.is_bigint(number_item) then
			return value.string_from_utf8(number_item.text)
		end

		local raw = number

		if raw ~= raw then
			return value.string_from_utf8("+nan.0")
		end

		if raw == math.huge then
			return value.string_from_utf8("+inf.0")
		end

		if raw == -math.huge then
			return value.string_from_utf8("-inf.0")
		end

		local force_decimal = value.is_real(number_item) and number_item.force_decimal == true
		local negative_zero = builtins.is_negative_zero(number_item)
		local integer = nil
		local text

		if raw == math.floor(raw) then
			integer = math.floor(raw)
		end

		if integer ~= nil and not force_decimal then
			text = tostring(integer)
		else
			if negative_zero and force_decimal then
				text = "-0.0"
			else
				local magnitude = math.abs(raw)

				if magnitude > 0 and magnitude < 1e-307 then
					text = string.format("%.15g", raw)
				else
					text = string.format("%.17g", raw)
				end

				if string.find(text, ".", 1, true) == nil and string.find(text, "[eE]") == nil then
					text = text .. ".0"
				end
			end
		end

		return value.string_from_utf8(text)
	end

	local negative = number < 0
	local current = math.abs(number)

	if current == 0 then
		return "0"
	end

	local digits = {}
	local alphabet = "0123456789abcdef"

	while current > 0 do
		local remainder = current % radix
		digits[#digits + 1] = string.sub(alphabet, remainder + 1, remainder + 1)
		current = math.floor(current / radix)
	end

	local chars = {}

	for index = #digits, 1, -1 do
		chars[#chars + 1] = digits[index]
	end

	local text = table.concat(chars)

	if negative then
		return value.string_from_utf8("-" .. text)
	end

	return value.string_from_utf8(text)
end

local function string_to_number_fn(args)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("string->number expected 1..2 arguments, got %d", #args))
	end

	local radix = 10

	if args[2] ~= nil then
		radix = expect_number("string->number", args[2])
	end

	if radix ~= 2 and radix ~= 8 and radix ~= 10 and radix ~= 16 then
		errors.raise("value", "string->number expected radix 2, 8, 10, or 16")
	end

	local text = string.match(value.string_to_utf8(expect_string("string->number", args[1])), "^%s*(.-)%s*$")

	if text == "" then
		return false
	end

	if radix == 10 then
		local parsed = parser.atom_to_value(text)

		if value.is_symbol(parsed) or value.is_char(parsed) or type(parsed) == "boolean" then
			return false
		end

		return parsed
	end

	local sign = 1
	local cursor = 1

	if string.sub(text, 1, 1) == "-" then
		sign = -1
		cursor = 2
	elseif string.sub(text, 1, 1) == "+" then
		cursor = 2
	end

	if cursor > #text then
		return false
	end

	local parsed = 0

	for index = cursor, #text do
		local char = string.lower(string.sub(text, index, index))
		local digit = string.find("0123456789abcdef", char, 1, true)

		if digit == nil then
			return false
		end

		digit = digit - 1

		if digit >= radix then
			return false
		end

		parsed = parsed * radix + digit
	end

	return parsed * sign
end

local function eof_object_fn(args)
	expect_count("eof-object?", args, 1)
	return value.is_eof(args[1])
end

local function input_port_fn(args)
	expect_count("input-port?", args, 1)
	return value.is_port(args[1]) and args[1].mode == "input"
end

local function port_fn(args)
	expect_count("port?", args, 1)
	return value.is_port(args[1])
end

local function output_port_fn(args)
	expect_count("output-port?", args, 1)
	return value.is_port(args[1]) and args[1].mode == "output"
end

local function textual_port_fn(args)
	expect_count("textual-port?", args, 1)
	return value.is_port(args[1]) and not args[1].binary
end

local function binary_port_fn(args)
	expect_count("binary-port?", args, 1)
	return value.is_port(args[1]) and args[1].binary
end

local function input_port_open_fn(args)
	expect_count("input-port-open?", args, 1)
	return value.is_port(args[1]) and args[1].mode == "input" and not args[1].closed
end

local function output_port_open_fn(args)
	expect_count("output-port-open?", args, 1)
	return value.is_port(args[1]) and args[1].mode == "output" and not args[1].closed
end

local function close_port_impl(args, mode, name)
	expect_count(name, args, 1)
	local port = expect_port(name, args[1], mode)
	port.closed = true
	return value.list({})
end

local function open_input_string_fn(args)
	expect_count("open-input-string", args, 1)

	return value.port("input", {
		source = value.string_to_utf8(expect_string("open-input-string", args[1])),
	})
end

local function open_output_string_fn(args)
	expect_count("open-output-string", args, 0)
	return value.port("output", {})
end

local function get_output_string_fn(args)
	expect_count("get-output-string", args, 1)
	return value.string_from_utf8(table.concat(expect_port("get-output-string", args[1], "output").buffer))
end

local function read_fn(args, _, _, default_input_port)
	if #args > 1 then
		errors.raise("arity", string.format("read expected 0..1 arguments, got %d", #args))
	end

	local port = default_input_port

	if args[1] ~= nil then
		port = expect_port("read", args[1], "input")
	elseif port == nil then
		errors.raise("state", "read without an explicit port is not supported")
	end

	local form, next_position = read_next_form_from_source(port.source, port.position)

	if form == nil then
		return value.eof()
	end

	port.position = next_position
	return form
end

local function read_char_fn(args, _, _, default_input_port)
	if #args > 1 then
		errors.raise("arity", string.format("read-char expected 0..1 arguments, got %d", #args))
	end

	local port = default_input_port

	if args[1] ~= nil then
		port = expect_port("read-char", args[1], "input")
	elseif port == nil then
		errors.raise("state", "read-char without an explicit port is not supported")
	end

	if port.position > #port.source then
		return value.eof()
	end

	local start_byte = port.position
	local next_byte = utf8.offset(port.source, 2, start_byte)
	local char

	if next_byte == nil then
		char = string.sub(port.source, start_byte)
		port.position = #port.source + 1
	else
		char = string.sub(port.source, start_byte, next_byte - 1)
		port.position = next_byte
	end

	return value.char(char)
end

local function peek_char_fn(args, _, _, default_input_port)
	if #args > 1 then
		errors.raise("arity", string.format("peek-char expected 0..1 arguments, got %d", #args))
	end

	local port = default_input_port

	if args[1] ~= nil then
		port = expect_port("peek-char", args[1], "input")
	elseif port == nil then
		errors.raise("state", "peek-char without an explicit port is not supported")
	end

	if port.position > #port.source then
		return value.eof()
	end

	local start_byte = port.position
	local next_byte = utf8.offset(port.source, 2, start_byte)

	if next_byte == nil then
		return value.char(string.sub(port.source, start_byte))
	end

	return value.char(string.sub(port.source, start_byte, next_byte - 1))
end

local function read_line_fn(args, _, _, default_input_port)
	if #args > 1 then
		errors.raise("arity", string.format("read-line expected 0..1 arguments, got %d", #args))
	end

	local port = default_input_port

	if args[1] ~= nil then
		port = expect_port("read-line", args[1], "input")
	elseif port == nil then
		errors.raise("state", "read-line without an explicit port is not supported")
	end

	if port.position > #port.source then
		return value.eof()
	end

	local newline = string.find(port.source, "\n", port.position, true)

	if newline == nil then
		local line = string.sub(port.source, port.position)
		port.position = #port.source + 1
		return value.string_from_utf8(line)
	end

	local line = string.sub(port.source, port.position, newline - 1)
	port.position = newline + 1
	return value.string_from_utf8(line)
end

local function read_string_fn(args)
	expect_count("read-string", args, 2)
	local count = expect_index("read-string", args[1])
	local port = expect_port("read-string", args[2], "input")

	if port.position > #port.source then
		return value.eof()
	end

	local start = port.position
	local read = 0
	local cursor = start

	while cursor <= #port.source and read < count do
		local next_cursor = utf8.offset(port.source, 2, cursor)
		read = read + 1

		if next_cursor == nil then
			cursor = #port.source + 1
			break
		end

		cursor = next_cursor
	end

	local text = string.sub(port.source, start, cursor - 1)
	port.position = cursor
	return value.string_from_utf8(text)
end

-- Shared/cyclic structure printing needs a pre-pass so write-shared can assign
-- labels before the actual rendering walk starts.
local function write_renderer(mode, item)
	local counts = {}
	local cyclic = {}
	local labels = {}
	local next_label = 0
	local rendering = {}

	local function list_render_parts(current)
		local root, start_index = value.list_root(current)

		if root == nil or start_index == nil then
			return {}, nil
		end

		local items = {}

		for index = start_index, #root.items do
			items[#items + 1] = root.items[index]
		end

		return items, root.tail
	end

	local function collect_shared_refs(current, visiting)
		if value.is_list(current) then
			counts[current] = (counts[current] or 0) + 1

			if visiting[current] then
				cyclic[current] = true
				return
			end

			visiting[current] = true

			local items, tail = list_render_parts(current)

			for _, child in ipairs(items) do
				collect_shared_refs(child, visiting)
			end

			if tail ~= nil then
				collect_shared_refs(tail, visiting)
			end

			visiting[current] = nil
			return
		end

		if value.is_vector(current) then
			counts[current] = (counts[current] or 0) + 1

			if visiting[current] then
				cyclic[current] = true
				return
			end

			visiting[current] = true

			for _, child in ipairs(current.items) do
				collect_shared_refs(child, visiting)
			end

			visiting[current] = nil
		end
	end

	collect_shared_refs(item, {})

	local function render(current)
		if value.is_list(current) then
			local needs_label = false

			if mode == "write-shared" then
				needs_label = (counts[current] or 0) > 1
			elseif mode == "write" then
				needs_label = cyclic[current] == true
			end

			local existing = labels[current]

			if existing ~= nil then
				return string.format("#%d#", existing)
			end

			local prefix = ""

			if needs_label then
				labels[current] = next_label
				prefix = string.format("#%d=", next_label)
				next_label = next_label + 1
			elseif rendering[current] then
				return "#<cycle>"
			end

			rendering[current] = true

			local items, tail = list_render_parts(current)
			local parts = {}

			for index, child in ipairs(items) do
				parts[index] = render(child)
			end

			if tail ~= nil then
				parts[#parts + 1] = "."
				parts[#parts + 1] = render(tail)
			end

			rendering[current] = nil
			return prefix .. string.format("(%s)", table.concat(parts, " "))
		end

		if value.is_vector(current) then
			local needs_label = mode == "write-shared" and (counts[current] or 0) > 1
			local existing = labels[current]

			if existing ~= nil then
				return string.format("#%d#", existing)
			end

			local prefix = ""

			if needs_label then
				labels[current] = next_label
				prefix = string.format("#%d=", next_label)
				next_label = next_label + 1
			elseif rendering[current] then
				return "#<cycle>"
			end

			rendering[current] = true

			local parts = {}

			for index, child in ipairs(current.items) do
				parts[index] = render(child)
			end

			rendering[current] = nil
			return prefix .. string.format("#(%s)", table.concat(parts, " "))
		end

		return printer.to_string(current)
	end

	return render(item)
end

local function write_like(name, args, default_output_port, renderer)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("%s expected 1..2 arguments, got %d", name, #args))
	end

	local port = default_output_port

	if args[2] ~= nil then
		port = expect_port(name, args[2], "output")
	end

	port_write_text(port, renderer(args[1]))
	return value.list({})
end

local function write_fn(args, _, _, default_output_port)
	return write_like("write", args, default_output_port, function(item)
		return write_renderer("write", item)
	end)
end

local function display_fn(args, _, _, default_output_port)
	return write_like("display", args, default_output_port, function(item)
		if value.is_string(item) then
			return value.string_to_utf8(item)
		end

		if value.is_char(item) then
			return item.value
		end

		return printer.to_string(item)
	end)
end

local function newline_fn(args, _, _, default_output_port)
	if #args > 1 then
		errors.raise("arity", string.format("newline expected 0..1 arguments, got %d", #args))
	end

	local port = default_output_port

	if args[1] ~= nil then
		port = expect_port("newline", args[1], "output")
	end

	port_write_text(port, "\n")
	return value.list({})
end

local function write_char_fn(args, _, _, default_output_port)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("write-char expected 1..2 arguments, got %d", #args))
	end

	local port = default_output_port

	if args[2] ~= nil then
		port = expect_port("write-char", args[2], "output")
	end

	port_write_text(port, expect_char("write-char", args[1]).value)
	return value.list({})
end

local function flush_output_port_fn(args, _, _, default_output_port)
	if #args > 1 then
		errors.raise("arity", string.format("flush-output-port expected 0..1 arguments, got %d", #args))
	end

	if args[1] ~= nil then
		expect_port("flush-output-port", args[1], "output")
	elseif default_output_port ~= nil then
		expect_port("flush-output-port", default_output_port, "output")
	end

	return value.list({})
end

local function char_ready_fn(args, _, _, default_input_port)
	if #args > 1 then
		errors.raise("arity", string.format("char-ready? expected 0..1 arguments, got %d", #args))
	end

	if args[1] ~= nil then
		local port = expect_port("char-ready?", args[1], "input")
		return port.position <= #port.source
	elseif default_input_port ~= nil then
		return default_input_port.position <= #default_input_port.source
	end

	return false
end

function builtins.complex_fn(args)
	expect_count("complex?", args, 1)
	return builtins.is_numeric(args[1])
end

function builtins.real_fn(args)
	expect_count("real?", args, 1)
	return builtins.is_real_number(args[1])
end

function builtins.rational_fn(args)
	expect_count("rational?", args, 1)
	if not builtins.is_real_number(args[1]) then
		return false
	end

	local number = builtins.expect_real_number("rational?", args[1])
	return number == number and number ~= math.huge and number ~= -math.huge
end

function builtins.integer_fn(args)
	expect_count("integer?", args, 1)
	if value.is_bigint(args[1]) then
		return true
	end

	if not builtins.is_real_number(args[1]) then
		return false
	end

	local number = builtins.expect_real_number("integer?", args[1])
	return math.floor(number) == number
end

function builtins.exact_predicate_fn(args)
	expect_count("exact?", args, 1)
	if value.is_bigint(args[1]) then
		return true
	end

	if value.is_complex(args[1]) then
		return args[1].real_inexact ~= true and args[1].imag_inexact ~= true
	end

	if value.is_real(args[1]) then
		return args[1].inexact ~= true
	end

	return builtins.number_type(args[1]) == "integer"
end

function builtins.inexact_predicate_fn(args)
	expect_count("inexact?", args, 1)

	if value.is_bigint(args[1]) then
		return false
	end

	if value.is_complex(args[1]) then
		return args[1].real_inexact == true or args[1].imag_inexact == true
	end

	if value.is_real(args[1]) then
		return args[1].inexact == true
	end

	local kind = builtins.number_type(args[1])

	return kind == nil or kind == "float"
end

local function features_fn(args)
	expect_count("features", args, 0)
	return value.list({
		value.symbol("r7rs"),
		value.symbol("psil"),
	})
end

-- exact-integer-sqrt is the main place where Psil's narrow bigint support
-- matters: small exact integers use machine arithmetic, oversized exact values
-- take the slower decimal-string path.
local function exact_integer_sqrt_fn(args)
	expect_count("exact-integer-sqrt", args, 1)

	if value.is_bigint(args[1]) then
		if string.sub(args[1].text, 1, 1) == "-" then
			errors.raise("type", "exact-integer-sqrt expected a non-negative integer")
		end

		local root_text, remainder_text = require("./bigint").integer_sqrt(args[1].text)
		local root_number = tonumber(root_text)
		local remainder_number = tonumber(remainder_text)

		return value.multi_values({
			(root_number ~= nil and root_number <= 9007199254740991) and root_number or value.bigint(root_text),
			(remainder_number ~= nil and remainder_number <= 9007199254740991) and remainder_number or value.bigint(remainder_text),
		})
	end

	local number = expect_number("exact-integer-sqrt", args[1])

	if number < 0 or math.floor(number) ~= number then
		errors.raise("type", "exact-integer-sqrt expected a non-negative integer")
	end

	local root = math.floor(math.sqrt(number))
	local upper = root + 1

	-- Lua numbers are inexact doubles here, so unbounded correction loops can
	-- go pathological on very large inputs from the raw R7RS suite. We keep a
	-- tiny bounded correction window, which preserves exact behavior for normal
	-- integer-sized inputs while staying total on oversized numeric tests.
	for _ = 1, 8 do
		if upper * upper <= number then
			root = upper
			upper = upper + 1
		elseif root * root > number then
			root = root - 1
			upper = root + 1
		else
			break
		end
	end

	return value.multi_values({
		root,
		number - root * root,
	})
end

function builtins.inexact_convert_fn(args)
	expect_count("inexact", args, 1)
	local item = expect_numeric("inexact", args[1])

	if value.is_complex(item) then
		return value.complex(item.real + 0.0, item.imag + 0.0, {
			real_inexact = true,
			imag_inexact = true,
		})
	end

	if value.is_bigint(item) then
		local number = tonumber(item.text) + 0.0
		return value.real(number, {
			inexact = true,
			force_decimal = true,
			negative_zero = number == 0 and 1 / number == -math.huge,
		})
	end

	local number = expect_number("inexact", item) + 0.0
	return value.real(number, {
		inexact = true,
		force_decimal = true,
		negative_zero = number == 0 and 1 / number == -math.huge,
	})
end

function builtins.exact_fn_convert(args)
	expect_count("exact", args, 1)
	local item = expect_numeric("exact", args[1])

	if value.is_complex(item) then
		local real = item.real
		local imag = item.imag

		if real == math.floor(real) then
			real = math.floor(real)
		end

		if imag == math.floor(imag) then
			imag = math.floor(imag)
		end

		return value.complex(real, imag)
	end

	local number = expect_number("exact", item)

	if number == math.floor(number) then
		return math.floor(number)
	end

	return number
end

local function atan_fn(args)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("atan expected 1..2 arguments, got %d", #args))
	end

	if args[2] ~= nil then
		local result = math.atan(expect_number("atan", args[1]), expect_number("atan", args[2]))
		local wrapped = builtins.normalize_real_result(result, true)

		if result == 0 and builtins.is_negative_zero(args[1]) and expect_number("atan", args[2]) > 0 then
			return value.real(0.0, {
				inexact = true,
				force_decimal = true,
				negative_zero = true,
			})
		end

		return wrapped
	end

	return builtins.normalize_real_result(math.atan(expect_number("atan", args[1])), true)
end

function builtins.make_rectangular_fn(args)
	expect_count("make-rectangular", args, 2)
	return builtins.make_complex(
		builtins.expect_real_number("make-rectangular", args[1]),
		builtins.expect_real_number("make-rectangular", args[2])
	)
end

function builtins.make_polar_fn(args)
	expect_count("make-polar", args, 2)
	local magnitude = builtins.expect_real_number("make-polar", args[1])
	local angle = builtins.expect_real_number("make-polar", args[2])

	return value.complex(
		magnitude * math.cos(angle),
		magnitude * math.sin(angle),
		{
			real_inexact = true,
			imag_inexact = true,
		}
	)
end

function builtins.real_part_fn(args)
	expect_count("real-part", args, 1)

	if value.is_complex(args[1]) then
		return args[1].real
	end

	return expect_number("real-part", args[1])
end

function builtins.imag_part_fn(args)
	expect_count("imag-part", args, 1)

	if value.is_complex(args[1]) then
		return args[1].imag
	end

	expect_number("imag-part", args[1])
	return 0
end

function builtins.magnitude_fn(args)
	expect_count("magnitude", args, 1)
	return abs_fn(args)
end

function builtins.angle_fn(args)
	expect_count("angle", args, 1)

	if value.is_complex(args[1]) then
		return builtins.normalize_real_result(math.atan(args[1].imag, args[1].real), true)
	end

	local number = expect_number("angle", args[1])

	if number < 0 then
		return builtins.normalize_real_result(math.pi, true)
	end

	return builtins.normalize_real_result(0.0, true)
end

local function numerator_fn(args)
	expect_count("numerator", args, 1)
	local numerator, denominator, inexact = builtins.ratio_parts(expect_number("numerator", args[1]))
	inexact = builtins.is_inexact_value(args[1])

	if denominator == 1 then
		return builtins.normalize_real_result(numerator, inexact)
	end

	return builtins.normalize_real_result(numerator, inexact)
end

local function denominator_fn(args)
	expect_count("denominator", args, 1)
	local _, denominator, inexact = builtins.ratio_parts(expect_number("denominator", args[1]))
	inexact = builtins.is_inexact_value(args[1])

	return builtins.normalize_real_result(denominator, inexact)
end

local function make_parameter_fn(args, apply_callable, execution)
	if #args < 1 or #args > 2 then
		errors.raise("arity", string.format("make-parameter expected 1..2 arguments, got %d", #args))
	end

	local converter = args[2]
	local current = args[1]

	if converter ~= nil then
		current = apply_callable(converter, {
			current,
		}, execution)
	end

	local parameter = value.builtin("parameter", function()
		errors.raise("state", "parameter objects are invoked by the evaluator")
	end)
	parameter.is_parameter = true
	parameter.current = current
	parameter.converter = converter
	return parameter
end

local function error_fn(args, apply_callable, execution)
	local message = "error"
	local irritants = {}

	if args[1] ~= nil then
		if value.is_string(args[1]) then
			message = value.string_to_utf8(args[1])
		else
			message = printer.to_string(args[1])
		end
	end

	for index = 2, #args do
		irritants[#irritants + 1] = args[index]
	end

	builtins.raise_condition(errors.exception(message, irritants), false, apply_callable, execution)
end

local function raise_fn(args, apply_callable, execution)
	expect_count("raise", args, 1)
	builtins.raise_condition(args[1], false, apply_callable, execution)
end

local function raise_continuable_fn(args, apply_callable, execution)
	expect_count("raise-continuable", args, 1)
	return builtins.raise_condition(args[1], true, apply_callable, execution)
end

local function with_exception_handler_fn(args, apply_callable, execution)
	expect_count("with-exception-handler", args, 2)

	if apply_callable == nil then
		errors.raise("state", "with-exception-handler requires evaluator support")
	end

	if execution == nil then
		errors.raise("state", "with-exception-handler requires execution state")
	end

	local handler = args[1]
	local thunk = args[2]
	local handlers = execution.exception_handlers or {}

	execution.exception_handlers = handlers
	table.insert(handlers, handler)

	local ok, result = pcall(function()
		return apply_callable(thunk, {}, execution)
	end)

	if handlers[#handlers] == handler then
		table.remove(handlers)
	end

	if ok then
		return result
	end

	if errors.is_flow_control(result) then
		error(result, 0)
	end

	if type(result) == "table" and result.kind == "scheme_raise" then
		error(result, 0)
	end

	local condition = errors.to_condition(result)
	local handled_ok, handled = pcall(function()
		return apply_callable(handler, {
			condition,
		}, execution)
	end)

	if not handled_ok then
		error(handled, 0)
	end

	error(result, 0)
end

local function print_fn(io_adapter, dialect)
	return function(args)
		local parts = {}

		for index, item in ipairs(args) do
			parts[index] = printer.to_string(item, {
				dialect = dialect,
			})
		end

		local line = table.concat(parts, " ")

		if io_adapter ~= nil and type(io_adapter.write) == "function" then
			io_adapter:write(line)
		else
			print(line)
		end

		if dialect == "cl-compat" and #args > 0 then
			return args[#args]
		end

		return value.list({})
	end
end

-- add() wires the standard environment together in one place so host and
-- Roblox runs can share the same builtins while swapping only the I/O adapter.
function builtins.add(scope, io_adapter)
	local dialect = scope ~= nil and scope.dialect or "scheme"
	local current_input_port = value.port("input", {
		source = "",
		io_adapter = io_adapter,
	})
	local current_output_port = value.port("output", {
		io_adapter = io_adapter,
	})
	local current_error_port = value.port("output", {
		io_adapter = io_adapter,
	})
	local function fresh_language_env(with_builtins)
		local language_scope = env.new(nil)

		if with_builtins ~= false then
			builtins.add(language_scope, io_adapter)
		end

		return language_scope
	end
	local function with_ports(fn)
		return function(args, apply_callable, execution)
			return fn(args, apply_callable, execution, current_input_port, current_output_port)
		end
	end
	local function resolve_function_designator(item)
		if dialect == "cl-compat" and value.is_symbol(item) then
			return env.get(scope, item.name)
		end

		return item
	end
	local function with_input_port(fn)
		return function(args, apply_callable, execution)
			return fn(args, apply_callable, execution, current_input_port)
		end
	end
	local function with_output_port(fn)
		return function(args, apply_callable, execution)
			return fn(args, apply_callable, execution, current_output_port)
		end
	end
	local entries = {
		["+"] = arithmetic("+", function(a, b)
			return builtins.numeric_add(a, b)
		end, 0),
		["-"] = arithmetic("-", function(a, b)
			return builtins.numeric_sub(a, b)
		end),
		["*"] = arithmetic("*", function(a, b)
			return builtins.numeric_mul(a, b)
		end, 1),
		["/"] = arithmetic("/", function(a, b)
			return builtins.numeric_div(a, b)
		end),
		["="] = compare("=", function(a, b)
			return builtins.components_equal(a, b)
		end),
		["<"] = compare("<", function(a, b)
			return a < b
		end),
		[">"] = compare(">", function(a, b)
			return a > b
		end),
		["<="] = compare("<=", function(a, b)
			return a <= b
		end),
		[">="] = compare(">=", function(a, b)
			return a >= b
		end),
		cons = cons,
		car = car,
		cdr = cdr,
		["set-cdr!"] = set_cdr_fn,
		list = list_fn,
		append = append_fn,
		["null?"] = null_fn,
		["not"] = not_fn,
		["symbol?"] = symbol_fn,
		["number?"] = number_fn,
		["string?"] = string_fn,
		["char?"] = char_fn,
		["boolean?"] = boolean_fn,
		["list?"] = list_predicate_fn,
		["pair?"] = pair_fn,
		["procedure?"] = procedure_fn,
		["promise?"] = promise_fn,
		["atom?"] = atom_fn,
		["eq?"] = eq_fn,
		["eqv?"] = eqv_fn,
		["equal?"] = equal_fn,
		["boolean=?"] = boolean_eq_fn,
		length = length_fn,
		reverse = reverse_fn,
		nth = nth_fn,
		cadr = cadr_fn,
		["list-ref"] = list_ref_fn,
		member = {
			fn = builtins.member_with_compare_cps,
			cps = true,
		},
		memq = memq_fn,
		memv = memv_fn,
		assoc = {
			fn = builtins.assoc_with_compare_cps,
			cps = true,
		},
		assq = assq_fn,
		assv = assv_fn,
		["list-tail"] = list_tail_fn,
		["list-set!"] = list_set_fn,
		map = {
			fn = function(args, apply_callable, execution, k)
				return builtins.map_like_cps("map", args, apply_callable, execution, true, k)
			end,
			cps = true,
		},
		["for-each"] = {
			fn = function(args, apply_callable, execution, k)
				return builtins.map_like_cps("for-each", args, apply_callable, execution, false, k)
			end,
			cps = true,
		},
		["string-for-each"] = {
			fn = builtins.string_for_each_cps,
			cps = true,
		},
		["vector-for-each"] = {
			fn = builtins.vector_for_each_cps,
			cps = true,
		},
		apply = {
			fn = function(args, apply_callable, execution, k)
				if #args < 2 then
					errors.raise("arity", string.format("apply expected at least 2 arguments, got %d", #args))
				end

				local normalized = {}

				for index, item in ipairs(args) do
					normalized[index] = item
				end

				normalized[1] = resolve_function_designator(args[1])
				return builtins.apply_cps(normalized, apply_callable, execution, k)
			end,
			cps = true,
		},
		["call-with-values"] = {
			fn = builtins.call_with_values_cps,
			cps = true,
		},
		values = values_fn,
		force = force_fn,
		["make-promise"] = make_promise_fn,
		["make-vector"] = make_vector_fn,
		["vector-length"] = vector_length_fn,
		vector = vector_fn,
		["vector-copy"] = vector_copy_fn,
		["vector-append"] = vector_append_fn,
		["vector-fill!"] = vector_fill_fn,
		["vector-copy!"] = vector_copy_bang_fn,
		["vector->list"] = vector_to_list_fn,
		["list->vector"] = list_to_vector_fn,
		["vector-set!"] = vector_set_fn,
		["vector-ref"] = vector_ref_fn,
		["vector?"] = vector_predicate_fn,
		["zero?"] = zero_fn,
		["even?"] = even_fn,
		["odd?"] = odd_fn,
		["positive?"] = positive_fn,
		["negative?"] = negative_fn,
		abs = abs_fn,
		max = max_fn,
		min = min_fn,
		remainder = remainder_fn,
		modulo = modulo_fn,
		gcd = gcd_fn,
		lcm = lcm_fn,
		expt = expt_fn,
		square = square_fn,
		exp = exp_fn,
		log = log_fn,
		["make-rectangular"] = builtins.make_rectangular_fn,
		["make-polar"] = builtins.make_polar_fn,
		["real-part"] = builtins.real_part_fn,
		["imag-part"] = builtins.imag_part_fn,
		magnitude = builtins.magnitude_fn,
		angle = builtins.angle_fn,
		round = round_fn,
		["symbol->string"] = symbol_to_string_fn,
		["string->symbol"] = string_to_symbol_fn,
		["number->string"] = number_to_string_fn,
		["string->number"] = string_to_number_fn,
		["string-length"] = string_length_fn,
		["string-append"] = string_append_fn,
		substring = substring_fn,
		["string-ref"] = string_ref_fn,
	}

	entries["string=?"] = string_compare("string=?", function(a, b)
		return value.string_to_utf8(a) == value.string_to_utf8(b)
	end)
	entries["string<?"] = string_compare("string<?", function(a, b)
		return value.string_to_utf8(a) < value.string_to_utf8(b)
	end)
	entries["string<=?"] = string_compare("string<=?", function(a, b)
		return value.string_to_utf8(a) <= value.string_to_utf8(b)
	end)
	entries["string>?"] = string_compare("string>?", function(a, b)
		return value.string_to_utf8(a) > value.string_to_utf8(b)
	end)
	entries["string>=?"] = string_compare("string>=?", function(a, b)
		return value.string_to_utf8(a) >= value.string_to_utf8(b)
	end)
	entries["string-ci=?"] = string_compare("string-ci=?", function(a, b)
		return value.string_to_utf8(string_foldcase_impl(a))
			== value.string_to_utf8(string_foldcase_impl(b))
	end)
	entries["string-copy"] = string_copy_fn
	entries["string-set!"] = function(args)
		expect_count("string-set!", args, 3)
		local text = expect_string("string-set!", args[1])
		local index = expect_index("string-set!", args[2])
		local replacement = utf8.codepoint(expect_char("string-set!", args[3]).value)
		local length = value.string_length(text)

		if index >= length then
			errors.raise("value", "string-set! index out of range")
		end

		text.items[index + 1] = replacement
		return text
	end
	entries["string->list"] = string_to_list_fn
	entries["list->string"] = list_to_string_fn
	entries["string-fill!"] = string_fill_fn
	entries["string-copy!"] = string_copy_bang_fn
	entries["string-downcase"] = string_downcase_fn
	entries["string-upcase"] = string_upcase_fn
	entries["string-foldcase"] = string_foldcase_fn
	entries["make-string"] = make_string_fn
	entries.string = string_constructor_fn
	entries["char->integer"] = char_to_integer_fn
	entries["integer->char"] = integer_to_char_fn
	entries["digit-value"] = digit_value_fn
	entries["char-alphabetic?"] = char_alphabetic_fn
	entries["char-numeric?"] = char_numeric_fn
	entries["char-upper-case?"] = char_upper_case_fn
	entries["char-lower-case?"] = char_lower_case_fn
	entries["char-downcase"] = char_downcase_fn
	entries["char-upcase"] = char_upcase_fn
	entries["char-foldcase"] = char_foldcase_fn
	entries["char-whitespace?"] = char_whitespace_fn
	entries["eof-object?"] = eof_object_fn
	entries["eof-object"] = function(args)
		expect_count("eof-object", args, 0)
		return value.eof()
	end
	entries["port?"] = port_fn
	entries["input-port?"] = input_port_fn
	entries["output-port?"] = output_port_fn
	entries["textual-port?"] = textual_port_fn
	entries["binary-port?"] = binary_port_fn
	entries["input-port-open?"] = input_port_open_fn
	entries["output-port-open?"] = output_port_open_fn
	entries["close-input-port"] = function(args)
		return close_port_impl(args, "input", "close-input-port")
	end
	entries["close-output-port"] = function(args)
		return close_port_impl(args, "output", "close-output-port")
	end
	entries["close-port"] = function(args)
		expect_count("close-port", args, 1)
		local port = expect_port("close-port", args[1])
		port.closed = true
		return value.list({})
	end
	entries["open-input-string"] = open_input_string_fn
	entries["open-output-string"] = open_output_string_fn
	entries["get-output-string"] = get_output_string_fn
	entries.read = with_input_port(read_fn)
	entries["read-char"] = with_input_port(read_char_fn)
	entries["peek-char"] = with_input_port(peek_char_fn)
	entries["read-line"] = with_input_port(read_line_fn)
	entries["read-string"] = read_string_fn
	entries["write-string"] = function(args, _, _, default_output_port)
		if #args < 2 or #args > 4 then
			errors.raise("arity", string.format("write-string expected 2..4 arguments, got %d", #args))
		end
		local text = expect_string("write-string", args[1])
		local port = default_output_port
		local start_index = 0
		local end_index = value.string_length(text)

		if args[2] ~= nil then
			port = expect_port("write-string", args[2], "output")
		end
		if args[3] ~= nil then
			start_index = expect_index("write-string", args[3])
		end
		if args[4] ~= nil then
			end_index = expect_index("write-string", args[4])
		end

		port_write_text(port, value.string_to_utf8(string_slice_value("write-string", text, start_index, end_index)))
		return value.list({})
	end
	entries.write = with_output_port(write_fn)
	entries["write-simple"] = with_output_port(function(args, _, _, default_output_port)
		return write_like("write-simple", args, default_output_port, function(item)
			return write_renderer("write-simple", item)
		end)
	end)
	entries["write-shared"] = with_output_port(function(args, _, _, default_output_port)
		return write_like("write-shared", args, default_output_port, function(item)
			return write_renderer("write-shared", item)
		end)
	end)
	entries.display = with_output_port(display_fn)
	entries.newline = with_output_port(newline_fn)
	entries["write-char"] = with_output_port(write_char_fn)
	entries["flush-output-port"] = with_output_port(flush_output_port_fn)
	entries["char-ready?"] = with_input_port(char_ready_fn)
	entries["current-input-port"] = function(args)
		expect_count("current-input-port", args, 0)
		return current_input_port
	end
	entries["current-output-port"] = function(args)
		expect_count("current-output-port", args, 0)
		return current_output_port
	end
	entries["complex?"] = builtins.complex_fn
	entries["real?"] = builtins.real_fn
	entries["rational?"] = builtins.rational_fn
	entries["integer?"] = builtins.integer_fn
	entries["exact?"] = builtins.exact_predicate_fn
	entries["inexact?"] = builtins.inexact_predicate_fn
	entries.exact = builtins.exact_fn_convert
	entries.inexact = builtins.inexact_convert_fn
	entries.atan = atan_fn
	entries["exact-integer-sqrt"] = exact_integer_sqrt_fn
	entries["list-copy"] = list_copy_fn
	entries["make-list"] = make_list_fn
	entries.features = features_fn
	entries["make-parameter"] = make_parameter_fn
	entries["call-with-current-continuation"] = {
		fn = builtins.call_cc_cps,
		cps = true,
	}
	entries["call/cc"] = {
		fn = builtins.call_cc_cps,
		cps = true,
	}
	entries["with-exception-handler"] = {
		fn = builtins.with_exception_handler_cps,
		cps = true,
	}
	entries.raise = {
		fn = builtins.raise_cps,
		cps = true,
	}
	entries["raise-continuable"] = {
		fn = builtins.raise_continuable_cps,
		cps = true,
	}
	entries.error = {
		fn = builtins.error_cps,
		cps = true,
	}
		entries.print = print_fn(io_adapter, dialect)

	entries["vector->string"] = vector_to_string_fn
	entries["string->vector"] = string_to_vector_fn
	entries["string-ci<?"] = string_compare("string-ci<?", function(a, b)
		return value.string_to_utf8(string_foldcase_impl(a))
			< value.string_to_utf8(string_foldcase_impl(b))
	end)
	entries["string-ci<=?"] = string_compare("string-ci<=?", function(a, b)
		return value.string_to_utf8(string_foldcase_impl(a))
			<= value.string_to_utf8(string_foldcase_impl(b))
	end)
	entries["string-ci>?"] = string_compare("string-ci>?", function(a, b)
		return value.string_to_utf8(string_foldcase_impl(a))
			> value.string_to_utf8(string_foldcase_impl(b))
	end)
	entries["string-ci>=?"] = string_compare("string-ci>=?", function(a, b)
		return value.string_to_utf8(string_foldcase_impl(a))
			>= value.string_to_utf8(string_foldcase_impl(b))
	end)
	entries["finite?"] = function(args)
		expect_count("finite?", args, 1)
		local real, imag = builtins.numeric_parts(expect_numeric("finite?", args[1]))
		return real == real
			and imag == imag
			and real ~= math.huge
			and real ~= -math.huge
			and imag ~= math.huge
			and imag ~= -math.huge
	end
	entries["infinite?"] = function(args)
		expect_count("infinite?", args, 1)
		local real, imag = builtins.numeric_parts(expect_numeric("infinite?", args[1]))
		return real == math.huge or real == -math.huge or imag == math.huge or imag == -math.huge
	end
	entries["nan?"] = function(args)
		expect_count("nan?", args, 1)
		local real, imag = builtins.numeric_parts(expect_numeric("nan?", args[1]))
		return real ~= real or imag ~= imag
	end
	entries["symbol=?"] = symbol_eq_fn
	entries["cddr"] = function(args)
		expect_count("cddr", args, 1)
		return cdr({
			cdr(args),
		})
	end
	entries.acos = function(args)
		expect_count("acos", args, 1)
		return builtins.normalize_real_result(math.acos(builtins.expect_real_number("acos", args[1])), true)
	end
	entries["char-ci<?"] = char_compare("char-ci<?", function(char)
		return unicode.fold_char(char) or char
	end, function(a, b)
		return a < b
	end)
	entries["char-ci<=?"] = char_compare("char-ci<=?", function(char)
		return unicode.fold_char(char) or char
	end, function(a, b)
		return a <= b
	end)
	entries["char-ci>?"] = char_compare("char-ci>?", function(char)
		return unicode.fold_char(char) or char
	end, function(a, b)
		return a > b
	end)
	entries["char-ci>=?"] = char_compare("char-ci>=?", function(char)
		return unicode.fold_char(char) or char
	end, function(a, b)
		return a >= b
	end)
	entries["char=?"] = char_compare("char=?", function(char)
		return char
	end, function(a, b)
		return a == b
	end)
	entries["char<?"] = char_compare("char<?", function(char)
		return char
	end, function(a, b)
		return a < b
	end)
	entries["char<=?"] = char_compare("char<=?", function(char)
		return char
	end, function(a, b)
		return a <= b
	end)
	entries["char>?"] = char_compare("char>?", function(char)
		return char
	end, function(a, b)
		return a > b
	end)
	entries["char>=?"] = char_compare("char>=?", function(char)
		return char
	end, function(a, b)
		return a >= b
	end)
	entries["char-ci=?"] = char_compare("char-ci=?", function(char)
		return unicode.fold_char(char) or char
	end, function(a, b)
		return a == b
	end)
	entries["vector-map"] = function(args, apply_callable, execution)
		expect_min_count("vector-map", args, 2)

		if apply_callable == nil then
			errors.raise("state", "vector-map requires evaluator support")
		end

		local callable = args[1]
		local vectors = {}
		local limit

		for index = 2, #args do
			local vector = expect_vector("vector-map", args[index])

			vectors[#vectors + 1] = vector

			if limit == nil or #vector.items < limit then
				limit = #vector.items
			end
		end

		local items = {}

		for item_index = 1, limit or 0 do
			local call_args = {}

			for vector_index, vector in ipairs(vectors) do
				call_args[vector_index] = vector.items[item_index]
			end

			items[item_index] = apply_callable(callable, call_args, execution)
		end

		return value.vector(items)
	end
	entries["string-map"] = function(args, apply_callable, execution)
		expect_min_count("string-map", args, 2)

		if apply_callable == nil then
			errors.raise("state", "string-map requires evaluator support")
		end

		local callable = args[1]
		local texts = {}
		local limit

		for index = 2, #args do
			local text = expect_string("string-map", args[index])
			texts[#texts + 1] = text
			local text_length = value.string_length(text)

			if limit == nil or text_length < limit then
				limit = text_length
			end
		end

		local parts = {}

		for item_index = 0, (limit or 0) - 1 do
			local call_args = {}

			for text_index, text in ipairs(texts) do
				call_args[text_index] = value.char(utf8.char(text.items[item_index + 1]))
			end

			parts[#parts + 1] = utf8.codepoint(expect_char(
				"string-map",
				apply_callable(callable, call_args, execution)
			).value)
		end

		return value.string(parts)
	end
	entries["bytevector?"] = function(args)
		expect_count("bytevector?", args, 1)
		return value.is_bytevector(args[1])
	end
	entries["make-bytevector"] = function(args)
		if #args < 1 or #args > 2 then
			errors.raise("arity", string.format("make-bytevector expected 1..2 arguments, got %d", #args))
		end

		local length = expect_index("make-bytevector", args[1])
		local fill = 0

		if args[2] ~= nil then
			fill = expect_index("make-bytevector", args[2])
			if fill > 255 then
				errors.raise("value", "make-bytevector fill must be in 0..255")
			end
		end

		local items = {}
		for index = 1, length do
			items[index] = fill
		end
		return value.bytevector(items)
	end
	entries.bytevector = function(args)
		local items = {}

		for index, item in ipairs(args) do
			local byte = expect_index("bytevector", item)
			if byte > 255 then
				errors.raise("value", "bytevector elements must be in 0..255")
			end
			items[index] = byte
		end

		return value.bytevector(items)
	end
	entries["bytevector-length"] = function(args)
		expect_count("bytevector-length", args, 1)
		if not value.is_bytevector(args[1]) then
			errors.raise("type", "bytevector-length expected a bytevector")
		end
		return #args[1].items
	end
	entries["bytevector-u8-ref"] = function(args)
		expect_count("bytevector-u8-ref", args, 2)
		if not value.is_bytevector(args[1]) then
			errors.raise("type", "bytevector-u8-ref expected a bytevector")
		end
		local index = expect_index("bytevector-u8-ref", args[2])
		local byte = args[1].items[index + 1]
		if byte == nil then
			errors.raise("value", "bytevector-u8-ref index out of range")
		end
		return byte
	end
	entries["bytevector-u8-set!"] = function(args)
		expect_count("bytevector-u8-set!", args, 3)
		if not value.is_bytevector(args[1]) then
			errors.raise("type", "bytevector-u8-set! expected a bytevector")
		end
		local index = expect_index("bytevector-u8-set!", args[2])
		local byte = expect_index("bytevector-u8-set!", args[3])
		if byte > 255 then
			errors.raise("value", "bytevector-u8-set! expected a byte in 0..255")
		end
		if args[1].items[index + 1] == nil then
			errors.raise("value", "bytevector-u8-set! index out of range")
		end
		args[1].items[index + 1] = byte
		return value.list({})
	end
	entries["bytevector-copy"] = function(args)
		if #args < 1 or #args > 3 then
			errors.raise("arity", string.format("bytevector-copy expected 1..3 arguments, got %d", #args))
		end
		if not value.is_bytevector(args[1]) then
			errors.raise("type", "bytevector-copy expected a bytevector")
		end
		local start_index = 0
		local end_index = #args[1].items
		if args[2] ~= nil then
			start_index = expect_index("bytevector-copy", args[2])
		end
		if args[3] ~= nil then
			end_index = expect_index("bytevector-copy", args[3])
		end
		local items = {}
		for index = start_index + 1, math.min(end_index, #args[1].items) do
			items[#items + 1] = args[1].items[index]
		end
		return value.bytevector(items)
	end
	entries["bytevector-copy!"] = function(args)
		if #args < 3 or #args > 5 then
			errors.raise("arity", string.format("bytevector-copy! expected 3..5 arguments, got %d", #args))
		end
		if not value.is_bytevector(args[1]) or not value.is_bytevector(args[3]) then
			errors.raise("type", "bytevector-copy! expected bytevectors")
		end
		local target = args[1]
		local at = expect_index("bytevector-copy!", args[2])
		local source = args[3]
		local start_index = 0
		local end_index = #source.items
		if args[4] ~= nil then
			start_index = expect_index("bytevector-copy!", args[4])
		end
		if args[5] ~= nil then
			end_index = expect_index("bytevector-copy!", args[5])
		end
		local copied = {}
		for index = start_index + 1, math.min(end_index, #source.items) do
			copied[#copied + 1] = source.items[index]
		end
		for index, item in ipairs(copied) do
			target.items[at + index] = item
		end
		return value.list({})
	end
	entries["bytevector-append"] = function(args)
		local items = {}
		for _, item in ipairs(args) do
			if not value.is_bytevector(item) then
				errors.raise("type", "bytevector-append expected bytevectors")
			end
			for _, byte in ipairs(item.items) do
				items[#items + 1] = byte
			end
		end
		return value.bytevector(items)
	end
	entries["utf8->string"] = function(args)
		if #args < 1 or #args > 3 then
			errors.raise("arity", string.format("utf8->string expected 1..3 arguments, got %d", #args))
		end
		if not value.is_bytevector(args[1]) then
			errors.raise("type", "utf8->string expected a bytevector")
		end
		local start_index = 0
		local end_index = #args[1].items
		if args[2] ~= nil then
			start_index = expect_index("utf8->string", args[2])
		end
		if args[3] ~= nil then
			end_index = expect_index("utf8->string", args[3])
		end
		local bytes = {}
		for index = start_index + 1, math.min(end_index, #args[1].items) do
			bytes[#bytes + 1] = string.char(args[1].items[index])
		end
		return value.string_from_utf8(table.concat(bytes))
	end
	entries["string->utf8"] = function(args)
		if #args < 1 or #args > 3 then
			errors.raise("arity", string.format("string->utf8 expected 1..3 arguments, got %d", #args))
		end
		local text = expect_string("string->utf8", args[1])
		local start_index = 0
		local end_index = value.string_length(text)
		if args[2] ~= nil then
			start_index = expect_index("string->utf8", args[2])
		end
		if args[3] ~= nil then
			end_index = expect_index("string->utf8", args[3])
		end
		local text_value = string_slice_value("string->utf8", text, start_index, end_index)
		local utf8_text = value.string_to_utf8(text_value)
		local bytes = {
			string.byte(utf8_text, 1, #utf8_text),
		}
		return value.bytevector(bytes)
	end
	entries["open-input-bytevector"] = function(args)
		expect_count("open-input-bytevector", args, 1)
		if not value.is_bytevector(args[1]) then
			errors.raise("type", "open-input-bytevector expected a bytevector")
		end
		return value.port("input", {
			binary = true,
			source_bytes = value.copy_items(args[1].items),
			position = 1,
		})
	end
	entries["open-output-bytevector"] = function(args)
		expect_count("open-output-bytevector", args, 0)
		return value.port("output", {
			binary = true,
			buffer_bytes = {},
		})
	end
	entries["get-output-bytevector"] = function(args)
		expect_count("get-output-bytevector", args, 1)
		local port = expect_port("get-output-bytevector", args[1], "output")
		if not port.binary then
			errors.raise("type", "get-output-bytevector expected a binary output port")
		end
		return value.bytevector(value.copy_items(port.buffer_bytes or {}))
	end
	entries["read-u8"] = function(args, _, _, default_input_port)
		if #args > 1 then
			errors.raise("arity", string.format("read-u8 expected 0..1 arguments, got %d", #args))
		end
		local port = default_input_port
		if args[1] ~= nil then
			port = expect_port("read-u8", args[1], "input")
		end
		if port == nil or not port.binary then
			errors.raise("type", "read-u8 expected a binary input port")
		end
		local bytes = port.source_bytes or {}
		if port.position > #bytes then
			return value.eof()
		end
		local byte = bytes[port.position]
		port.position = port.position + 1
		return byte
	end
	entries["u8-ready?"] = function(args, _, _, default_input_port)
		if #args > 1 then
			errors.raise("arity", string.format("u8-ready? expected 0..1 arguments, got %d", #args))
		end
		local port = default_input_port
		if args[1] ~= nil then
			port = expect_port("u8-ready?", args[1], "input")
		end
		return port ~= nil and port.binary and port.position <= #(port.source_bytes or {})
	end
	entries["read-bytevector"] = function(args)
		expect_count("read-bytevector", args, 2)
		local count = expect_index("read-bytevector", args[1])
		local port = expect_port("read-bytevector", args[2], "input")
		if not port.binary then
			errors.raise("type", "read-bytevector expected a binary input port")
		end
		local bytes = port.source_bytes or {}
		if port.position > #bytes then
			return value.eof()
		end
		local items = {}
		for _ = 1, count do
			if port.position > #bytes then
				break
			end
			items[#items + 1] = bytes[port.position]
			port.position = port.position + 1
		end
		return value.bytevector(items)
	end
	entries["read-bytevector!"] = function(args)
		if #args < 2 or #args > 4 then
			errors.raise("arity", string.format("read-bytevector! expected 2..4 arguments, got %d", #args))
		end
		if not value.is_bytevector(args[1]) then
			errors.raise("type", "read-bytevector! expected a bytevector")
		end
		local target = args[1]
		local port = expect_port("read-bytevector!", args[2], "input")
		if not port.binary then
			errors.raise("type", "read-bytevector! expected a binary input port")
		end
		local start_index = 0
		local end_index = #target.items
		if args[3] ~= nil then
			start_index = expect_index("read-bytevector!", args[3])
		end
		if args[4] ~= nil then
			end_index = expect_index("read-bytevector!", args[4])
		end
		local bytes = port.source_bytes or {}
		if port.position > #bytes then
			return value.eof()
		end
		local write_index = start_index + 1
		while write_index <= end_index and port.position <= #bytes do
			target.items[write_index] = bytes[port.position]
			write_index = write_index + 1
			port.position = port.position + 1
		end
		return target
	end
	entries["write-u8"] = function(args, _, _, default_output_port)
		if #args < 1 or #args > 2 then
			errors.raise("arity", string.format("write-u8 expected 1..2 arguments, got %d", #args))
		end
		local byte = expect_index("write-u8", args[1])
		if byte > 255 then
			errors.raise("value", "write-u8 expected a byte in 0..255")
		end
		local port = default_output_port
		if args[2] ~= nil then
			port = expect_port("write-u8", args[2], "output")
		end
		if port == nil or not port.binary then
			errors.raise("type", "write-u8 expected a binary output port")
		end
		port.buffer_bytes = port.buffer_bytes or {}
		port.buffer_bytes[#port.buffer_bytes + 1] = byte
		return value.list({})
	end
	entries["write-bytevector"] = function(args, _, _, default_output_port)
		if #args < 2 or #args > 4 then
			errors.raise("arity", string.format("write-bytevector expected 2..4 arguments, got %d", #args))
		end
		if not value.is_bytevector(args[1]) then
			errors.raise("type", "write-bytevector expected a bytevector")
		end
		local port = default_output_port
		if args[2] ~= nil then
			port = expect_port("write-bytevector", args[2], "output")
		end
		if port == nil or not port.binary then
			errors.raise("type", "write-bytevector expected a binary output port")
		end
		local start_index = 0
		local end_index = #args[1].items
		if args[3] ~= nil then
			start_index = expect_index("write-bytevector", args[3])
		end
		if args[4] ~= nil then
			end_index = expect_index("write-bytevector", args[4])
		end
		port.buffer_bytes = port.buffer_bytes or {}
		for index = start_index + 1, math.min(end_index, #args[1].items) do
			port.buffer_bytes[#port.buffer_bytes + 1] = args[1].items[index]
		end
		return value.list({})
	end
	entries["current-error-port"] = function(args)
		expect_count("current-error-port", args, 0)
		return current_error_port
	end
	entries["open-input-file"] = function(args)
		expect_count("open-input-file", args, 1)
		errors.raise("file", string.format("unable to open file '%s'", tostring(args[1])))
	end
	entries["delete-file"] = function(args)
		expect_count("delete-file", args, 1)
		errors.raise("file", string.format("unable to delete file '%s'", tostring(args[1])))
	end
	entries["error-object?"] = function(args)
		expect_count("error-object?", args, 1)
		return value.is_exception(args[1])
	end
	entries["error-object-message"] = function(args)
		expect_count("error-object-message", args, 1)
		if not value.is_exception(args[1]) then
			errors.raise("type", "error-object-message expected an error object")
		end
		return value.string_from_utf8(args[1].message)
	end
	entries["error-object-irritants"] = function(args)
		expect_count("error-object-irritants", args, 1)
		if not value.is_exception(args[1]) then
			errors.raise("type", "error-object-irritants expected an error object")
		end
		return value.list(value.copy_items(args[1].irritants or {}))
	end
	entries["file-error?"] = function(args)
		expect_count("file-error?", args, 1)
		return value.is_exception(args[1]) and args[1].file_error == true
	end
	entries["read-error?"] = function(args)
		expect_count("read-error?", args, 1)
		return value.is_exception(args[1]) and args[1].read_error == true
	end
	entries["null-environment"] = function(args)
		expect_count("null-environment", args, 1)
		return fresh_language_env(false)
	end
	entries["scheme-report-environment"] = function(args)
		expect_count("scheme-report-environment", args, 1)
		return fresh_language_env(true)
	end
	entries["interaction-environment"] = function(args)
		expect_count("interaction-environment", args, 0)
		return scope
	end
	entries.environment = function(args)
		for _, spec in ipairs(args) do
			if not value.is_list(spec) then
				errors.raise("type", "environment expected library specifications")
			end
		end
		return fresh_language_env(true)
	end
	entries.eval = function(args, _, execution)
		if scope ~= nil and scope.dialect == "cl-compat" then
			expect_min_count("eval", args, 1)

			if #args > 2 then
				errors.raise("arity", string.format("eval expected 1..2 arguments, got %d", #args))
			end
		else
			expect_count("eval", args, 2)
		end

		local target_scope = scope

		if args[2] ~= nil then
			target_scope = builtins.expect_environment("eval", args[2])
		end

		if execution == nil or execution.eval_in_env == nil then
			errors.raise("state", "eval requires evaluator support")
		end

		return execution.eval_in_env(args[1], target_scope)
	end
	entries["exact-integer?"] = function(args)
		expect_count("exact-integer?", args, 1)
		return builtins.is_real_number(args[1]) and builtins.number_type(args[1]) == "integer"
	end
	entries.numerator = numerator_fn
	entries.denominator = denominator_fn
	entries.quotient = function(args)
		return builtins.division_quotient_fn("quotient", "truncate")(args)
	end
	entries.floor = function(args)
		expect_count("floor", args, 1)
		local number = builtins.expect_real_number("floor", args[1])
		return builtins.normalize_real_result(math.floor(number), builtins.number_type(args[1]) == "float")
	end
	entries.ceiling = function(args)
		expect_count("ceiling", args, 1)
		local number = builtins.expect_real_number("ceiling", args[1])
		return builtins.normalize_real_result(math.ceil(number), builtins.number_type(args[1]) == "float")
	end
	entries.truncate = function(args)
		expect_count("truncate", args, 1)
		local number = builtins.expect_real_number("truncate", args[1])
		return builtins.normalize_real_result(trunc_division(number, 1), builtins.number_type(args[1]) == "float")
	end
	entries.rationalize = function(args)
		expect_count("rationalize", args, 2)
		local number = expect_number("rationalize", args[1])
		local tolerance = math.abs(expect_number("rationalize", args[2]))
		local best_numerator = 0
		local best_denominator = 1
		local best_size = math.huge
		local best_distance = math.huge

		for denominator = 1, 64 do
			local numerator = math.floor(number * denominator + 0.5)
			local approximation = numerator / denominator
			local distance = math.abs(approximation - number)

			if distance <= tolerance then
				local size = math.abs(numerator) + denominator

				if size < best_size or (size == best_size and distance < best_distance) then
					best_numerator = numerator
					best_denominator = denominator
					best_size = size
					best_distance = distance
				end
			end
		end

		if best_distance == math.huge then
			return number
		end

		local divisor = builtins.gcd_integer(best_numerator, best_denominator)

		if divisor ~= 0 then
			best_numerator = best_numerator / divisor
			best_denominator = best_denominator / divisor
		end

		return best_numerator / best_denominator
	end
	entries.sin = function(args)
		expect_count("sin", args, 1)
		return builtins.normalize_real_result(math.sin(builtins.expect_real_number("sin", args[1])), true)
	end
	entries.asin = function(args)
		expect_count("asin", args, 1)
		return builtins.normalize_real_result(math.asin(builtins.expect_real_number("asin", args[1])), true)
	end
	entries.cos = function(args)
		expect_count("cos", args, 1)
		return builtins.normalize_real_result(math.cos(builtins.expect_real_number("cos", args[1])), true)
	end
	entries.tan = function(args)
		expect_count("tan", args, 1)
		return builtins.normalize_real_result(math.tan(builtins.expect_real_number("tan", args[1])), true)
	end
	entries.sqrt = function(args)
		expect_count("sqrt", args, 1)
		local item = expect_numeric("sqrt", args[1])

		if value.is_complex(item) then
			local magnitude = math.sqrt(item.real * item.real + item.imag * item.imag)
			local real = math.sqrt((magnitude + item.real) / 2)
			local imag_sign = 1

			if item.imag < 0 then
				imag_sign = -1
			end

			local imag = imag_sign * math.sqrt((magnitude - item.real) / 2)
			return value.complex(real, imag, {
				real_inexact = true,
				imag_inexact = true,
			})
		end

		local number = expect_number("sqrt", item)

		if number < 0 then
			return value.complex(0.0, math.sqrt(-number), {
				real_inexact = true,
				imag_inexact = true,
			})
		end

		return math.sqrt(number)
	end
	entries["current-second"] = function(args)
		expect_count("current-second", args, 0)
		return os.time() + 0.0
	end
	entries["current-jiffy"] = function(args)
		expect_count("current-jiffy", args, 0)
		return math.floor(os.clock() * 1000000)
	end
	entries["jiffies-per-second"] = function(args)
		expect_count("jiffies-per-second", args, 0)
		return 1000000
	end
	entries["command-line"] = function(args)
		expect_count("command-line", args, 0)

		if io_adapter ~= nil and type(io_adapter.argv) == "table" then
			local items = {}

			for index, item in ipairs(io_adapter.argv) do
				items[index] = value.string_from_utf8(tostring(item))
			end

			return value.list(items)
		end

		return value.list({})
	end
	entries["get-environment-variable"] = function(args)
		expect_count("get-environment-variable", args, 1)
		local name = value.string_to_utf8(expect_string("get-environment-variable", args[1]))

		if io_adapter ~= nil and type(io_adapter.env) == "table" then
			local item = io_adapter.env[name]

			if type(item) == "string" then
				return value.string_from_utf8(item)
			end
		end

		if os ~= nil and type(os.getenv) == "function" then
			local item = os.getenv(name)

			if item ~= nil then
				return value.string_from_utf8(item)
			end
		end

		return false
	end
	entries["make-syntactic-closure"] = function(args)
		expect_count("make-syntactic-closure", args, 3)
		local scope = builtins.expect_environment("make-syntactic-closure", args[1])
		local free_names = symbol_set_from_list("make-syntactic-closure", args[2])
		return value.syntactic_closure(scope, free_names, args[3])
	end
	entries["get-environment-variables"] = function(args)
		expect_count("get-environment-variables", args, 0)
		local items = {}
		local source = io_adapter ~= nil and io_adapter.env or nil

		if type(source) == "table" then
			for name, item in pairs(source) do
				if type(name) == "string" and type(item) == "string" then
					items[#items + 1] = value.list({
						value.string_from_utf8(name),
					}, value.string_from_utf8(item))
				end
			end
		end

		table.sort(items, function(left, right)
			return value.string_to_utf8(left.items[1]) < value.string_to_utf8(right.items[1])
		end)

		return value.list(items)
	end
	entries["file-exists?"] = function(args)
		expect_count("file-exists?", args, 1)
		local path = value.string_to_utf8(expect_string("file-exists?", args[1]))

		if io == nil or io.open == nil then
			return false
		end

		local handle = io.open(path, "rb")

		if handle == nil then
			return false
		end

		handle:close()
		return true
	end
	entries["floor/"] = function(args)
		return builtins.division_pair_values("floor/", "floor", args)
	end
	entries["ceiling/"] = function(args)
		return builtins.division_pair_values("ceiling/", "ceiling", args)
	end
	entries["truncate/"] = function(args)
		return builtins.division_pair_values("truncate/", "truncate", args)
	end
	entries["round/"] = function(args)
		return builtins.division_pair_values("round/", "round", args)
	end
	entries["euclidean/"] = function(args)
		return builtins.division_pair_values("euclidean/", "euclidean", args)
	end
	entries["balanced/"] = function(args)
		return builtins.division_pair_values("balanced/", "balanced", args)
	end
	entries["ceiling-quotient"] = builtins.division_quotient_fn("ceiling-quotient", "ceiling")
	entries["ceiling-remainder"] = builtins.division_remainder_fn("ceiling-remainder", "ceiling")
	entries["floor-quotient"] = builtins.division_quotient_fn("floor-quotient", "floor")
	entries["floor-remainder"] = builtins.division_remainder_fn("floor-remainder", "floor")
	entries["truncate-quotient"] = builtins.division_quotient_fn("truncate-quotient", "truncate")
	entries["truncate-remainder"] = builtins.division_remainder_fn("truncate-remainder", "truncate")
	entries["round-quotient"] = builtins.division_quotient_fn("round-quotient", "round")
	entries["round-remainder"] = builtins.division_remainder_fn("round-remainder", "round")
	entries["euclidean-quotient"] = builtins.division_quotient_fn("euclidean-quotient", "euclidean")
	entries["euclidean-remainder"] = builtins.division_remainder_fn("euclidean-remainder", "euclidean")
	entries["balanced-quotient"] = builtins.division_quotient_fn("balanced-quotient", "balanced")
	entries["balanced-remainder"] = builtins.division_remainder_fn("balanced-remainder", "balanced")

	if dialect == "cl-compat" then
		entries.null = null_fn
		entries.atom = atom_fn
		entries.eq = eq_fn
		entries.eql = eqv_fn
		entries.equal = equal_fn
		entries.equalp = equal_fn
		entries.symbolp = symbol_fn
		entries.numberp = number_fn
		entries.stringp = string_fn
		entries.characterp = char_fn
		entries.listp = list_predicate_fn
		entries.consp = pair_fn
		entries.functionp = procedure_fn
		entries.funcall = function(args, apply_callable, execution)
			expect_min_count("funcall", args, 1)
			local fn = resolve_function_designator(args[1])
			local call_args = {}

			for index = 2, #args do
				call_args[index - 1] = args[index]
			end

			return apply_callable(fn, call_args, execution)
		end
		entries["symbol-value"] = function(args)
			expect_count("symbol-value", args, 1)

			if value.is_list(args[1]) and #args[1].items == 0 and args[1].tail == nil then
				return value.list({})
			end

			if args[1] == true then
				return true
			end

			if not value.is_symbol(args[1]) then
				errors.raise("type", "symbol-value expected a symbol")
			end

			return env.get(scope, args[1].name)
		end
		entries.boundp = function(args)
			expect_count("boundp", args, 1)

			if not value.is_symbol(args[1]) then
				errors.raise("type", "boundp expected a symbol")
			end

			return env.find_frame(scope, args[1].name) ~= nil
		end
		entries.fboundp = function(args)
			expect_count("fboundp", args, 1)

			if not value.is_symbol(args[1]) then
				errors.raise("type", "fboundp expected a symbol")
			end

			local frame = env.find_frame(scope, args[1].name)
			return frame ~= nil and value.is_callable(frame.values[args[1].name])
		end
		entries["symbol-function"] = function(args)
			expect_count("symbol-function", args, 1)

			if not value.is_symbol(args[1]) then
				errors.raise("type", "symbol-function expected a symbol")
			end

			return env.get(scope, args[1].name)
		end
		entries.identity = function(args)
			expect_count("identity", args, 1)
			return args[1]
		end
		entries.gensym = function(args)
			local prefix = "G"

			if args[1] ~= nil then
				if value.is_symbol(args[1]) then
					prefix = args[1].name
				elseif value.is_string(args[1]) then
					prefix = value.string_to_utf8(args[1])
				elseif type(args[1]) == "string" then
					prefix = args[1]
				else
					errors.raise("type", "gensym expected a string or symbol prefix")
				end
			end

			builtins._gensym_counter = (builtins._gensym_counter or 0) + 1
			return value.symbol(string.format("%s%d", prefix, builtins._gensym_counter))
		end
		entries["1+"] = function(args)
			expect_count("1+", args, 1)
			return expect_number("1+", args[1]) + 1
		end
		entries["1-"] = function(args)
			expect_count("1-", args, 1)
			return expect_number("1-", args[1]) - 1
		end
		entries.min = function(args)
			expect_min_count("min", args, 1)
			local result = expect_number("min", args[1])

			for index = 2, #args do
				local item = expect_number("min", args[index])

				if item < result then
					result = item
				end
			end

			return result
		end
		entries["make-list"] = function(args)
			expect_min_count("make-list", args, 1)
			local count = expect_number("make-list", args[1])

			if count < 0 or count ~= math.floor(count) then
				errors.raise("type", "make-list expected a non-negative integer length")
			end

			local fill = value.list({})
			local index = 2

			while index <= #args do
				local key = args[index]

				if not value.is_symbol(key) or key.name ~= ":initial-element" then
					errors.raise("type", "make-list only supports :initial-element keyword arguments")
				end

				if args[index + 1] == nil then
					errors.raise("arity", "make-list expected a value after :initial-element")
				end

				fill = args[index + 1]
				index = index + 2
			end

			local items = {}

			for item_index = 1, count do
				items[item_index] = fill
			end

			return value.list(items)
		end
		entries.mapcar = function(args, apply_callable, execution)
			expect_min_count("mapcar", args, 2)
			local fn = args[1]
			local lists = {}
			local shortest = nil

			for index = 2, #args do
				local list = args[index]

				if not value.is_list(list) or list.tail ~= nil then
					errors.raise("type", "mapcar expected proper list arguments")
				end

				lists[#lists + 1] = list

				if shortest == nil or #list.items < shortest then
					shortest = #list.items
				end
			end

			local results = {}

			for item_index = 1, shortest do
				local call_args = {}

				for list_index, list in ipairs(lists) do
					call_args[list_index] = list.items[item_index]
				end

				results[#results + 1] = apply_callable(fn, call_args, execution)
			end

			return value.list(results)
		end
		entries.documentation = function(args)
			expect_count("documentation", args, 2)

			if not value.is_symbol(args[1]) or not value.is_symbol(args[2]) then
				errors.raise("type", "documentation expected symbol arguments")
			end

			local doc = env.get_doc(scope, args[2].name, args[1].name)

			if doc == nil then
				return value.list({})
			end

			return doc
		end
		entries.makunbound = function(args)
			expect_count("makunbound", args, 1)

			if not value.is_symbol(args[1]) then
				errors.raise("type", "makunbound expected a symbol")
			end

			env.unbind(scope, args[1].name)
			return args[1]
		end
	end

	for name, fn in pairs(entries) do
		if type(fn) == "table" then
			env.define(scope, name, value.builtin(name, fn.fn, {
				cps = fn.cps == true,
			}))
		else
			env.define(scope, name, value.builtin(name, fn))
		end
	end

	if dialect == "cl-compat" then
		env.define(scope, "nil", value.list({}))
		env.define(scope, "t", true)
		env.define(scope, "lambda-list-keywords", value.list({
			value.symbol("&optional"),
			value.symbol("&rest"),
			value.symbol("&key"),
			value.symbol("&aux"),
		}))
	end

	return scope
end

return builtins
