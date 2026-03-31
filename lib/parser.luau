--[[
SPDX-License-Identifier: MPL-2.0
]]

--!native
--!optimize 2

local errors = require("./errors")
local value = require("./value")

-- Token-to-datum parser for Psil reader output.
-- The reader handles lexical shape; this layer turns tokens into runtime
-- values, including dotted lists, shared-structure labels, and numeric syntax.

local parser = {}
local COMMENT_SKIPPED = {}

-- Lists are normalized so dotted tails like (1 . (2 3)) collapse into the same
-- internal list representation used by the evaluator and printer.
local function normalize_list(items, tail)
	if value.is_proper_list(tail) and not (type(tail) == "table" and tail.label_placeholder == true) then
		local normalized_items = value.copy_items(items)

		for _, item in ipairs(tail.items) do
			normalized_items[#normalized_items + 1] = item
		end

		return value.list(normalized_items)
	end

	return value.list(items, tail)
end

local parse_form

-- Shared-structure labels are resolved during parse so later runtime code sees
-- ordinary cyclic values instead of reader-specific placeholders.
local function parse_list_form(tokens, index, labels, target)
	local items = target ~= nil and target.items or {}
	local cursor = index + 1
	local tail = target ~= nil and target.tail or nil

	while true do
		local next_token = tokens[cursor]

		if next_token == nil then
			errors.raise("parse", "unexpected end of input while reading list")
		end

		if next_token.kind == "close" then
			local parsed = normalize_list(items, tail)

			if target ~= nil then
				target.items = parsed.items
				target.tail = parsed.tail
				target.label_placeholder = nil
				return target, cursor + 1
			end

			return parsed, cursor + 1
		end

		if next_token.kind == "atom" and next_token.value == "." then
			if #items == 0 then
				errors.raise("parse", "unexpected '.' at start of list")
			end

			if tail ~= nil then
				errors.raise("parse", "multiple dotted tails in list")
			end

			tail, cursor = parse_form(tokens, cursor + 1, labels)

			while tail == COMMENT_SKIPPED do
				if tokens[cursor] == nil or tokens[cursor].kind == "close" then
					errors.raise("parse", "dotted list must end with a single tail form")
				end

				tail, cursor = parse_form(tokens, cursor, labels)
			end

			while tokens[cursor] ~= nil and tokens[cursor].kind == "datum_comment" do
				local skipped
				skipped, cursor = parse_form(tokens, cursor, labels)

				if skipped ~= COMMENT_SKIPPED then
					errors.raise("parse", "dotted list must end with a single tail form")
				end
			end

			if tokens[cursor] == nil or tokens[cursor].kind ~= "close" then
				errors.raise("parse", "dotted list must end with a single tail form")
			end

			local parsed = normalize_list(items, tail)

			if target ~= nil then
				target.items = parsed.items
				target.tail = parsed.tail
				target.label_placeholder = nil
				return target, cursor + 1
			end

			return parsed, cursor + 1
		end

		local item
		item, cursor = parse_form(tokens, cursor, labels)

		if item ~= COMMENT_SKIPPED then
			table.insert(items, item)
		end
	end
end

local function parse_vector_form(tokens, index, labels, target)
	local items = target ~= nil and target.items or {}
	local cursor = index + 1

	while true do
		local next_token = tokens[cursor]

		if next_token == nil then
			errors.raise("parse", "unexpected end of input while reading vector")
		end

		if next_token.kind == "close" then
			if target ~= nil then
				target.items = items
				target.label_placeholder = nil
				return target, cursor + 1
			end

			return value.vector(items), cursor + 1
		end

		if next_token.kind == "atom" and next_token.value == "." then
			errors.raise("parse", "vectors do not support dotted tails")
		end

		local item
		item, cursor = parse_form(tokens, cursor, labels)

		if item ~= COMMENT_SKIPPED then
			table.insert(items, item)
		end
	end
end

local function parse_char(atom)
	if string.sub(atom, 1, 2) ~= "#\\" then
		return nil
	end

	local name = string.sub(atom, 3)
	local named = {
		space = " ",
		newline = "\n",
		["return"] = "\r",
		tab = "\t",
		alarm = string.char(7),
		backspace = string.char(8),
		delete = string.char(127),
		escape = string.char(27),
		null = string.char(0),
	}

	if named[name] ~= nil then
		return value.char(named[name])
	end

	if string.sub(name, 1, 1) == "x" and #name > 1 then
		local codepoint = tonumber(string.sub(name, 2), 16)

		if codepoint ~= nil then
			return value.char(utf8.char(codepoint))
		end
	end

	if name ~= "" then
		return value.char(name)
	end

	return nil
end

-- Numeric atom parsing is staged instead of monolithic: prefixes, radix,
-- exactness, real/rational forms, then rectangular complex syntax.
local function atom_to_value(atom)
	local exactness
	local radix = 10
	local cursor = 1

	while string.sub(atom, cursor, cursor) == "#" do
		local marker = string.lower(string.sub(atom, cursor + 1, cursor + 1))

		if marker == "e" then
			exactness = "exact"
			cursor = cursor + 2
		elseif marker == "i" then
			exactness = "inexact"
			cursor = cursor + 2
		elseif marker == "b" then
			radix = 2
			cursor = cursor + 2
		elseif marker == "o" then
			radix = 8
			cursor = cursor + 2
		elseif marker == "d" then
			radix = 10
			cursor = cursor + 2
		elseif marker == "x" then
			radix = 16
			cursor = cursor + 2
		else
			break
		end
	end

	local body = string.sub(atom, cursor)

	local function coerce_exactness(number)
		if exactness == "exact" and math.floor(number) == number then
			return math.floor(number), false
		end

		if exactness == "inexact" then
			return number + 0.0, true
		end

		local kind = math.type ~= nil and math.type(number) or nil
		return number, kind == "float"
	end

	local function gcd_integer(left, right)
		left = math.abs(left)
		right = math.abs(right)

		while right ~= 0 do
			left, right = right, left % right
		end

		return left
	end

	local function parse_radix_integer(text, base)
		local sign = 1
		local digits = text

		if string.sub(digits, 1, 1) == "-" then
			sign = -1
			digits = string.sub(digits, 2)
		elseif string.sub(digits, 1, 1) == "+" then
			digits = string.sub(digits, 2)
		end

		if digits == "" then
			return nil
		end

		local parsed = tonumber(digits, base)

		if parsed == nil then
			return nil
		end

		return parsed * sign
	end

	local function parse_real_number(text)
		local lower_text = string.lower(text)

		if lower_text == "+inf.0" then
			return coerce_exactness(math.huge)
		end

		if lower_text == "-inf.0" then
			return coerce_exactness(-math.huge)
		end

		if lower_text == "+nan.0" or lower_text == "-nan.0" then
			return coerce_exactness(0 / 0)
		end

		local numerator_text, denominator_text = string.match(text, "^([+-]?[%w]+)/([%w]+)$")

		if numerator_text ~= nil then
			local left = parse_radix_integer(numerator_text, radix)
			local right = parse_radix_integer(denominator_text, radix)

			if left ~= nil and right ~= nil and right ~= 0 then
				local divisor = gcd_integer(left, right)
				local numerator = left
				local denominator = right

				if divisor ~= 0 then
					numerator = numerator / divisor
					denominator = denominator / divisor
				end

				local ratio = numerator / denominator

				if exactness == "inexact" then
					return ratio + 0.0, true
				end

				if denominator == 1 then
					return numerator, false
				end

				return ratio, false, string.format("%d/%d", numerator, denominator)
			end
		end

		if radix ~= 10 then
			local sign = 1
			local digits = text

			if string.sub(digits, 1, 1) == "-" then
				sign = -1
				digits = string.sub(digits, 2)
			elseif string.sub(digits, 1, 1) == "+" then
				digits = string.sub(digits, 2)
			end

			if digits ~= "" then
				local parsed = tonumber(digits, radix)

				if parsed ~= nil then
					return coerce_exactness(parsed * sign)
				end
			end

			return nil
		end

		local normalized = string.gsub(text, "([%d%.])([sSdDfFlL])([%+%-]?%d+)", "%1e%3")
		local number = tonumber(normalized)

		if number ~= nil then
			return coerce_exactness(number)
		end

		return nil
	end

	local function wrap_real(number, inexact, text, exact_repr)
		if exact_repr ~= nil then
			return value.real(number, {
				inexact = false,
				exact_repr = exact_repr,
			})
		end

		if inexact ~= true then
			return number
		end

		local lower_text = string.lower(text)
		local force_decimal = exactness == "inexact"
			or string.find(lower_text, ".", 1, true) ~= nil
			or string.find(lower_text, "e", 1, true) ~= nil
			or string.find(lower_text, "s", 1, true) ~= nil
			or string.find(lower_text, "f", 1, true) ~= nil
			or string.find(lower_text, "d", 1, true) ~= nil
			or string.find(lower_text, "l", 1, true) ~= nil
			or number == math.huge
			or number == -math.huge
			or number ~= number

		return value.real(number, {
			inexact = true,
			force_decimal = force_decimal,
			negative_zero = number == 0 and string.match(text, "^%-") ~= nil,
		})
	end

	-- Complex literals are split late so plain identifiers like +i are not
	-- misread as numeric syntax when they were intended as symbols.
	local function find_complex_split(text)
		for index = #text, 2, -1 do
			local char = string.sub(text, index, index)
			local previous = string.sub(text, index - 1, index - 1)

			if (char == "+" or char == "-")
				and previous ~= "e"
				and previous ~= "E"
				and previous ~= "s"
				and previous ~= "S"
				and previous ~= "f"
				and previous ~= "F"
				and previous ~= "d"
				and previous ~= "D"
				and previous ~= "l"
				and previous ~= "L" then
				return index
			end
		end

		return nil
	end

	if atom == "#t" or atom == "#true" then
		return true
	end

	if atom == "#f" or atom == "#false" then
		return false
	end

	local char = parse_char(atom)

	if char ~= nil then
		return char
	end

	if radix == 10 then
		local suffix = string.sub(body, -1)

		if (suffix == "i" or suffix == "I") and body ~= "i" and body ~= "I" then
			local imag_source = string.sub(body, 1, #body - 1)
			local split = find_complex_split(imag_source)
			local real_source
			local imag_text = imag_source

			if split ~= nil then
				real_source = string.sub(imag_source, 1, split - 1)
				imag_text = string.sub(imag_source, split)
			end

			if imag_text == "" or imag_text == "+" then
				imag_text = "1"
			elseif imag_text == "-" then
				imag_text = "-1"
			end

			local imag_value, imag_inexact, imag_repr = parse_real_number(imag_text)

			if imag_value ~= nil then
				local real_value = 0
				local real_inexact = false
				local real_repr

				if real_source ~= nil then
					real_value, real_inexact, real_repr = parse_real_number(real_source)
				end

				if real_source == nil or real_value ~= nil then
					return value.complex(real_value, imag_value, {
						real_inexact = real_inexact,
						imag_inexact = imag_inexact,
						real_repr = real_repr,
						imag_repr = imag_repr,
					})
				end
			end
		end
	end

	local number, inexact, exact_repr = parse_real_number(body)

	if number ~= nil then
		return wrap_real(number, inexact, body, exact_repr)
	end

	return value.symbol(atom)
end

parse_form = function(tokens, index, labels)
	labels = labels or {}
	local token = tokens[index]

	if token == nil then
		errors.raise("parse", "unexpected end of input")
	end

	if token.kind == "quote" then
		local quoted, next_index = parse_form(tokens, index + 1)
		return value.list({
			value.symbol("quote"),
			quoted,
		}), next_index
	end

	if token.kind == "quasiquote" then
		local quoted, next_index = parse_form(tokens, index + 1)
		return value.list({
			value.symbol("quasiquote"),
			quoted,
		}), next_index
	end

	if token.kind == "unquote" then
		local quoted, next_index = parse_form(tokens, index + 1)
		return value.list({
			value.symbol("unquote"),
			quoted,
		}), next_index
	end

	if token.kind == "unquote_splicing" then
		local quoted, next_index = parse_form(tokens, index + 1)
		return value.list({
			value.symbol("unquote-splicing"),
			quoted,
		}), next_index
	end

	if token.kind == "datum_comment" then
		local skipped, next_index = parse_form(tokens, index + 1, labels)

		while skipped == COMMENT_SKIPPED and tokens[next_index] ~= nil do
			skipped, next_index = parse_form(tokens, next_index, labels)
		end

		return COMMENT_SKIPPED, next_index
	end

	if token.kind == "string" then
		return value.string_from_utf8(token.value), index + 1
	end

	if token.kind == "bar_atom" then
		return value.symbol(token.value), index + 1
	end

	if token.kind == "atom" then
		if token.value == "." then
			errors.raise("parse", "unexpected '.' outside dotted list")
		end

		return atom_to_value(token.value), index + 1
	end

	if token.kind == "label_ref" then
		local target = labels[token.value]

		if target == nil then
			errors.raise("parse", string.format("unknown datum label #%d#", token.value))
		end

		return target, index + 1
	end

	if token.kind == "label_def" then
		local next_token = tokens[index + 1]

		if next_token == nil then
			errors.raise("parse", "unexpected end of input after datum label")
		end

		if next_token.kind == "open" then
			local target = value.list({})
			target.label_placeholder = true
			labels[token.value] = target
			return parse_list_form(tokens, index + 1, labels, target)
		end

		if next_token.kind == "vector_open" then
			local target = value.vector({})
			target.label_placeholder = true
			labels[token.value] = target
			return parse_vector_form(tokens, index + 1, labels, target)
		end

		local parsed, next_index = parse_form(tokens, index + 1, labels)
		labels[token.value] = parsed
		return parsed, next_index
	end

	if token.kind == "open" then
		return parse_list_form(tokens, index, labels, nil)
	end

	if token.kind == "vector_open" then
		return parse_vector_form(tokens, index, labels, nil)
	end

	if token.kind == "bytevector_open" then
		local items = {}
		local cursor = index + 1

		while true do
			local next_token = tokens[cursor]

			if next_token == nil then
				errors.raise("parse", "unexpected end of input while reading bytevector")
			end

			if next_token.kind == "close" then
				return value.bytevector(items), cursor + 1
			end

			if next_token.kind == "atom" and next_token.value == "." then
				errors.raise("parse", "bytevectors do not support dotted tails")
			end

			local item
			item, cursor = parse_form(tokens, cursor)

			if type(item) ~= "number" or math.floor(item) ~= item or item < 0 or item > 255 then
				errors.raise("type", "bytevector elements must be integers in 0..255")
			end

			items[#items + 1] = item
		end
	end

	if token.kind == "close" then
		errors.raise("parse", "unexpected ')'")
	end

	errors.raise("parse", string.format("unexpected token '%s'", tostring(token.value)))
end

function parser.parse(tokens)
	local form, next_index = parse_form(tokens, 1)

	while form == COMMENT_SKIPPED and tokens[next_index] ~= nil do
		form, next_index = parse_form(tokens, next_index)
	end

	if tokens[next_index] ~= nil then
		errors.raise("parse", "expected a single form")
	end

	return form
end

function parser.parse_first(tokens, index)
	return parse_form(tokens, index or 1)
end

function parser.parse_all(tokens)
	local forms = {}
	local index = 1

	while tokens[index] ~= nil do
		local form
		form, index = parse_form(tokens, index)

		if form ~= COMMENT_SKIPPED then
			table.insert(forms, form)
		end
	end

	return forms
end

parser.atom_to_value = atom_to_value
parser.is_comment_skipped = function(item)
	return item == COMMENT_SKIPPED
end

return parser