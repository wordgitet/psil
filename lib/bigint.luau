--[[
SPDX-License-Identifier: MPL-2.0
]]

local bigint = {}

-- Narrow decimal-string bigint support.
-- This is not a general arbitrary-precision tower; it exists to cover exact
-- integer operations that the Scheme suite exercises beyond machine range.

local function strip_leading_zeros(text)
	local stripped = string.gsub(text, "^0+", "")

	if stripped == "" then
		return "0"
	end

	return stripped
end

local function split_sign(text)
	if string.sub(text, 1, 1) == "-" then
		return -1, strip_leading_zeros(string.sub(text, 2))
	end

	if string.sub(text, 1, 1) == "+" then
		return 1, strip_leading_zeros(string.sub(text, 2))
	end

	return 1, strip_leading_zeros(text)
end

function bigint.normalize(text)
	local sign, digits = split_sign(text)

	if digits == "0" then
		return "0"
	end

	if sign < 0 then
		return "-" .. digits
	end

	return digits
end

function bigint.compare_unsigned(left, right)
	left = strip_leading_zeros(left)
	right = strip_leading_zeros(right)

	if #left ~= #right then
		if #left < #right then
			return -1
		end

		return 1
	end

	if left < right then
		return -1
	end

	if left > right then
		return 1
	end

	return 0
end

-- Arithmetic is done directly on decimal strings so the implementation stays
-- portable across Lua/Luau runtimes without relying on host bigint support.
function bigint.add_unsigned(left, right)
	local carry = 0
	local parts = {}
	local left_index = #left
	local right_index = #right

	while left_index > 0 or right_index > 0 or carry > 0 do
		local left_digit = 0
		local right_digit = 0

		if left_index > 0 then
			left_digit = string.byte(left, left_index) - 48
			left_index = left_index - 1
		end

		if right_index > 0 then
			right_digit = string.byte(right, right_index) - 48
			right_index = right_index - 1
		end

		local total = left_digit + right_digit + carry
		parts[#parts + 1] = string.char(48 + (total % 10))
		carry = math.floor(total / 10)
	end

	local chars = {}

	for index = #parts, 1, -1 do
		chars[#chars + 1] = parts[index]
	end

	return table.concat(chars)
end

function bigint.subtract_unsigned(left, right)
	local borrow = 0
	local parts = {}
	local left_index = #left
	local right_index = #right

	while left_index > 0 do
		local left_digit = string.byte(left, left_index) - 48 - borrow
		local right_digit = 0

		if right_index > 0 then
			right_digit = string.byte(right, right_index) - 48
			right_index = right_index - 1
		end

		if left_digit < right_digit then
			left_digit = left_digit + 10
			borrow = 1
		else
			borrow = 0
		end

		parts[#parts + 1] = string.char(48 + (left_digit - right_digit))
		left_index = left_index - 1
	end

	local chars = {}

	for index = #parts, 1, -1 do
		chars[#chars + 1] = parts[index]
	end

	return strip_leading_zeros(table.concat(chars))
end

function bigint.multiply_small_unsigned(left, factor)
	if factor == 0 or left == "0" then
		return "0"
	end

	local carry = 0
	local parts = {}

	for index = #left, 1, -1 do
		local digit = string.byte(left, index) - 48
		local total = digit * factor + carry
		parts[#parts + 1] = string.char(48 + (total % 10))
		carry = math.floor(total / 10)
	end

	while carry > 0 do
		parts[#parts + 1] = string.char(48 + (carry % 10))
		carry = math.floor(carry / 10)
	end

	local chars = {}

	for index = #parts, 1, -1 do
		chars[#chars + 1] = parts[index]
	end

	return strip_leading_zeros(table.concat(chars))
end

function bigint.multiply_unsigned(left, right)
	left = strip_leading_zeros(left)
	right = strip_leading_zeros(right)

	if left == "0" or right == "0" then
		return "0"
	end

	local result = {}

	for index = 1, #left + #right do
		result[index] = 0
	end

	for left_index = #left, 1, -1 do
		local carry = 0
		local left_digit = string.byte(left, left_index) - 48
		local target = #left - left_index + 1

		for right_index = #right, 1, -1 do
			local right_digit = string.byte(right, right_index) - 48
			local position = target + (#right - right_index)
			local total = result[position] + left_digit * right_digit + carry
			result[position] = total % 10
			carry = math.floor(total / 10)
		end

		local position = target + #right

		while carry > 0 do
			local total = result[position] + carry
			result[position] = total % 10
			carry = math.floor(total / 10)
			position = position + 1
		end
	end

	local chars = {}
	local started = false

	for index = #result, 1, -1 do
		local digit = result[index]

		if digit ~= 0 or started then
			started = true
			chars[#chars + 1] = string.char(48 + digit)
		end
	end

	return strip_leading_zeros(table.concat(chars))
end

function bigint.multiply_by_power_of_10_unsigned(left, power)
	if left == "0" then
		return "0"
	end

	return left .. string.rep("0", power)
end

function bigint.add(left, right)
	local left_sign, left_digits = split_sign(left)
	local right_sign, right_digits = split_sign(right)

	if left_sign == right_sign then
		local digits = bigint.add_unsigned(left_digits, right_digits)

		if left_sign < 0 and digits ~= "0" then
			return "-" .. digits
		end

		return digits
	end

	local order = bigint.compare_unsigned(left_digits, right_digits)

	if order == 0 then
		return "0"
	end

	if order > 0 then
		local digits = bigint.subtract_unsigned(left_digits, right_digits)

		if left_sign < 0 and digits ~= "0" then
			return "-" .. digits
		end

		return digits
	end

	local digits = bigint.subtract_unsigned(right_digits, left_digits)

	if right_sign < 0 and digits ~= "0" then
		return "-" .. digits
	end

	return digits
end

function bigint.subtract(left, right)
	if string.sub(right, 1, 1) == "-" then
		return bigint.add(left, string.sub(right, 2))
	end

	return bigint.add(left, "-" .. right)
end

function bigint.from_integer(number)
	return bigint.normalize(tostring(number))
end

function bigint.to_number(text)
	return tonumber(text)
end

function bigint.pow_integer(base, exponent)
	local sign, digits = split_sign(bigint.from_integer(base))
	local current = digits
	local result = "1"
	local power = exponent

	while power > 0 do
		if power % 2 == 1 then
			result = bigint.multiply_unsigned(result, current)
		end

		power = math.floor(power / 2)

		if power > 0 then
			current = bigint.multiply_unsigned(current, current)
		end
	end

	if sign < 0 and exponent % 2 == 1 and result ~= "0" then
		return "-" .. result
	end

	return result
end

function bigint.pow_text(text, exponent)
	local sign, digits = split_sign(text)
	local current = digits
	local result = "1"
	local power = exponent

	while power > 0 do
		if power % 2 == 1 then
			result = bigint.multiply_unsigned(result, current)
		end

		power = math.floor(power / 2)

		if power > 0 then
			current = bigint.multiply_unsigned(current, current)
		end
	end

	if sign < 0 and exponent % 2 == 1 and result ~= "0" then
		return "-" .. result
	end

	return result
end

-- integer_sqrt uses exact decimal-string arithmetic so oversized exact inputs
-- never have to round-trip through floating point.
function bigint.integer_sqrt(text)
	local sign, digits = split_sign(text)

	if sign < 0 then
		error("integer_sqrt expected non-negative input", 0)
	end

	if digits == "0" then
		return "0", "0"
	end

	local pairs = {}
	local start_index = 1

	if #digits % 2 == 1 then
		pairs[1] = string.sub(digits, 1, 1)
		start_index = 2
	end

	for index = start_index, #digits, 2 do
		pairs[#pairs + 1] = string.sub(digits, index, index + 1)
	end

	local root = "0"
	local remainder = "0"

	for _, pair in ipairs(pairs) do
		remainder = bigint.add_unsigned(
			bigint.multiply_by_power_of_10_unsigned(remainder, 2),
			strip_leading_zeros(pair)
		)

		local prefix = bigint.multiply_small_unsigned(root, 20)
		local digit = 0

		for candidate = 9, 0, -1 do
			local probe = bigint.multiply_small_unsigned(
				bigint.add_unsigned(prefix, tostring(candidate)),
				candidate
			)

			if bigint.compare_unsigned(probe, remainder) <= 0 then
				digit = candidate
				remainder = bigint.subtract_unsigned(remainder, probe)
				break
			end
		end

		root = bigint.add_unsigned(bigint.multiply_small_unsigned(root, 10), tostring(digit))
	end

	return strip_leading_zeros(root), strip_leading_zeros(remainder)
end

return bigint