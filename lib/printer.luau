local value = require("./value")

-- Printer for Scheme-visible runtime values.
-- The goal is readable, round-trippable output where possible, while still
-- supporting shared/cyclic structure and exact/inexact numeric metadata.

local printer = {}

local function escape_string(value)
	value = string.gsub(value, "\\", "\\\\")
	value = string.gsub(value, "\"", "\\\"")
	value = string.gsub(value, "\n", "\\n")
	value = string.gsub(value, "\t", "\\t")
	return value
end

local function encode_char(char)
	local named = {
		[" "] = "space",
		["\n"] = "newline",
		["\r"] = "return",
		["\t"] = "tab",
		[string.char(7)] = "alarm",
		[string.char(8)] = "backspace",
		[string.char(27)] = "escape",
		[string.char(127)] = "delete",
		[string.char(0)] = "null",
	}

	if named[char] ~= nil then
		return "#\\" .. named[char]
	end

	return "#\\" .. char
end

-- Symbol names are emitted plain when safe and bar-quoted otherwise so odd
-- identifiers like |+i| survive a read/write round-trip.
local function encode_symbol_name(name)
	local looks_numberish = string.match(name, "^%d") ~= nil
		or string.match(name, "^%.%d") ~= nil
		or string.match(name, "^[%+%-].+") ~= nil
		or name == "+i"
		or name == "-i"
		or string.find(string.lower(name), "inf.0", 1, true) ~= nil
		or string.find(string.lower(name), "nan.0", 1, true) ~= nil

	if name == ""
		or name == "."
		or looks_numberish
		or string.match(name, "[%s%(%)\"'`,;|\\]") ~= nil then
		local escaped = string.gsub(name, "\\", "\\\\")
		escaped = string.gsub(escaped, "|", "\\|")
		return "|" .. escaped .. "|"
	end

	return name
end

-- Numeric formatting keeps enough syntax metadata to preserve Scheme-visible
-- distinctions such as exactness markers, forced decimals, and negative zero.
local function format_number(number, force_decimal, negative_zero)
	if number ~= number then
		return "+nan.0"
	end

	if number == math.huge then
		return "+inf.0"
	end

	if number == -math.huge then
		return "-inf.0"
	end

	if negative_zero == true and number == 0 then
		if force_decimal then
			return "-0.0"
		end

		return "-0"
	end

	local integer = nil

	if number == math.floor(number) then
		integer = math.floor(number)
	end

	if integer ~= nil and not force_decimal then
		return tostring(integer)
	end

	local text = tostring(number)

	if string.find(text, ".", 1, true) == nil and string.find(text, "[eE]") == nil then
		text = text .. ".0"
	end

	return text
end

local function format_complex(item)
	local real = item.real
	local imag = item.imag
	local imag_abs = math.abs(imag)
	local imag_sign = "+"

	if imag < 0 or (imag == 0 and 1 / imag == -math.huge) then
		imag_sign = "-"
	end

	local imag_text

	if item.imag_repr ~= nil then
		imag_text = string.gsub(string.gsub(item.imag_repr, "^%-", ""), "^%+", "") .. "i"
	elseif imag_abs == 1 and item.imag_inexact ~= true then
		imag_text = "i"
	else
		imag_text = string.gsub(format_number(imag_abs, item.imag_inexact == true), "^%+", "") .. "i"
	end

	if real == 0 and item.real_inexact ~= true then
		if imag_sign == "-" then
			return "-" .. imag_text
		end

		if imag_abs == 1 then
			return "+" .. imag_text
		end

		return imag_text
	end

	return string.format(
		"%s%s%s",
		item.real_repr or format_number(real, item.real_inexact == true),
		imag_sign,
		imag_text
	)
end

function printer.to_string(item)
	local value_type = type(item)

	if value_type == "nil" then
		return "nil"
	end

	if value_type == "number" then
		return format_number(item, false)
	end

	if value.is_real(item) then
		if item.exact_repr ~= nil then
			return item.exact_repr
		end

		return format_number(item.value, item.force_decimal == true, item.negative_zero == true)
	end

	if value.is_bigint(item) then
		return item.text
	end

	if value_type == "boolean" then
		if item then
			return "#t"
		end

		return "#f"
	end

	if value.is_symbol(item) then
		return encode_symbol_name(item.name)
	end

	if value.is_string(item) then
		return string.format("\"%s\"", escape_string(value.string_to_utf8(item)))
	end

	if value.is_char(item) then
		return encode_char(item.value)
	end

	if value.is_list(item) then
		local parts = {}

		for index, part in ipairs(item.items) do
			parts[index] = printer.to_string(part)
		end

		if item.tail ~= nil then
			parts[#parts + 1] = "."
			parts[#parts + 1] = printer.to_string(item.tail)
		end

		return string.format("(%s)", table.concat(parts, " "))
	end

	if value.is_vector(item) then
		local parts = {}

		for index, part in ipairs(item.items) do
			parts[index] = printer.to_string(part)
		end

		return string.format("#(%s)", table.concat(parts, " "))
	end

	if value.is_complex(item) then
		return format_complex(item)
	end

	if value.is_bytevector(item) then
		local parts = {}

		for index, part in ipairs(item.items) do
			parts[index] = tostring(part)
		end

		return string.format("#u8(%s)", table.concat(parts, " "))
	end

	if value.is_closure(item) then
		return "<closure>"
	end

	if value.is_builtin(item) then
		return string.format("<builtin:%s>", item.name)
	end

	if value.is_syntax(item) then
		return string.format("<syntax:%s>", item.name)
	end

	if value.is_uninitialized(item) then
		return string.format("<uninitialized:%s>", item.name)
	end

	if value.is_promise(item) then
		if item.forced then
			return string.format("<promise:%s>", printer.to_string(item.value))
		end

		return "<promise>"
	end

	if value.is_multi_values(item) then
		local parts = {}

		for index, part in ipairs(item.items) do
			parts[index] = printer.to_string(part)
		end

		return string.format("<values:%s>", table.concat(parts, " "))
	end

	if value.is_eof(item) then
		return "#!eof"
	end

	if value.is_port(item) then
		return string.format("<%s-port>", item.mode or "unknown")
	end

	if value.is_record(item) then
		return string.format("<record:%s>", tostring(item.type_name))
	end

	if value.is_exception(item) then
		return string.format("<error:%s>", tostring(item.message))
	end

	return tostring(item)
end

return printer
--[[
SPDX-License-Identifier: MPL-2.0
]]
