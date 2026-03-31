--!native
--!optimize 2

local errors = require("./errors")
local parser = require("./parser")

-- Reader/tokenizer for Scheme surface syntax.
-- This layer is responsible for token boundaries, datum comments, directives,
-- strings, bar symbols, and reader sugar; parser.luau handles the semantic
-- meaning of those tokens afterward.

local reader = {}

-- String tokenization already applies Scheme escape handling so the parser sees
-- a decoded string datum instead of raw source escapes.
local function read_string(source, start_index)
	local chars = {}
	local index = start_index + 1

	while index <= #source do
		local char = string.sub(source, index, index)

		if char == "\\" then
			local escaped = string.sub(source, index + 1, index + 1)

			if escaped == "" then
				errors.raise("parse", "unexpected end of input in string escape")
			end

			if escaped == " " or escaped == "\t" or escaped == "\r" or escaped == "\n" then
				local cursor = index + 1
				local saw_newline = false

				while cursor <= #source do
					local continuation_char = string.sub(source, cursor, cursor)

					if continuation_char == " " or continuation_char == "\t" or continuation_char == "\r" then
						cursor = cursor + 1
					elseif continuation_char == "\n" then
						saw_newline = true
						cursor = cursor + 1
						break
					else
						break
					end
				end

				if saw_newline then
					while cursor <= #source do
						local continuation_char = string.sub(source, cursor, cursor)

						if continuation_char == " " or continuation_char == "\t" or continuation_char == "\r" then
							cursor = cursor + 1
						else
							break
						end
					end

					index = cursor
				else
					table.insert(chars, escaped)
					index = index + 2
				end
			elseif escaped == "n" then
				table.insert(chars, "\n")
				index = index + 2
			elseif escaped == "a" then
				table.insert(chars, string.char(7))
				index = index + 2
			elseif escaped == "b" then
				table.insert(chars, string.char(8))
				index = index + 2
			elseif escaped == "r" then
				table.insert(chars, "\r")
				index = index + 2
			elseif escaped == "t" then
				table.insert(chars, "\t")
				index = index + 2
			elseif escaped == "x" then
				local cursor = index + 2
				local hex = {}

				while cursor <= #source do
					local hex_char = string.sub(source, cursor, cursor)

					if hex_char == ";" then
						break
					end

					if string.match(hex_char, "[0-9A-Fa-f]") == nil then
						errors.raise("parse", "invalid hexadecimal string escape")
					end

					hex[#hex + 1] = hex_char
					cursor = cursor + 1
				end

				if cursor > #source or string.sub(source, cursor, cursor) ~= ";" or #hex == 0 then
					errors.raise("parse", "unterminated hexadecimal string escape")
				end

				table.insert(chars, utf8.char(tonumber(table.concat(hex), 16)))
				index = cursor + 1
			elseif escaped == "\"" then
				table.insert(chars, "\"")
				index = index + 2
			elseif escaped == "\\" then
				table.insert(chars, "\\")
				index = index + 2
			else
				table.insert(chars, escaped)
				index = index + 2
			end
		elseif char == "\"" then
			return table.concat(chars), index + 1
		else
			table.insert(chars, char)
			index = index + 1
		end
	end

	errors.raise("parse", "unexpected end of input in string literal")
end

-- Bar symbols preserve exact spelling, including characters that would
-- otherwise terminate or normalize ordinary symbol tokens.
local function read_bar_symbol(source, start_index)
	local chars = {}
	local index = start_index + 1

	while index <= #source do
		local char = string.sub(source, index, index)

		if char == "\\" then
			local escaped = string.sub(source, index + 1, index + 1)

			if escaped == "" then
				errors.raise("parse", "unexpected end of input in symbol escape")
			end

			if escaped == "x" then
				local cursor = index + 2
				local hex = {}

				while cursor <= #source do
					local hex_char = string.sub(source, cursor, cursor)

					if hex_char == ";" then
						break
					end

					if string.match(hex_char, "[0-9A-Fa-f]") == nil then
						errors.raise("parse", "invalid hexadecimal symbol escape")
					end

					hex[#hex + 1] = hex_char
					cursor = cursor + 1
				end

				if cursor > #source or string.sub(source, cursor, cursor) ~= ";" or #hex == 0 then
					errors.raise("parse", "unterminated hexadecimal symbol escape")
				end

				chars[#chars + 1] = utf8.char(tonumber(table.concat(hex), 16))
				index = cursor + 1
			else
				chars[#chars + 1] = escaped
				index = index + 2
			end
		elseif char == "|" then
			return table.concat(chars), index + 1
		else
			chars[#chars + 1] = char
			index = index + 1
		end
	end

	errors.raise("parse", "unexpected end of input in symbol literal")
end

function reader.tokenize(source)
	local tokens = {}
	local index = 1
	local fold_case = false

	-- Reader-level directives and comments are handled here so the parser can
	-- stay oblivious to whitespace, #; datum comments, and fold-case toggles.
	local function push_token(kind, value, start_index, end_index)
		tokens[#tokens + 1] = {
			kind = kind,
			value = value,
			start = start_index,
			finish = end_index,
		}
	end

	while index <= #source do
		local char = string.sub(source, index, index)

		if string.match(char, "%s") then
			index = index + 1
		elseif char == ";" then
			while index <= #source and string.sub(source, index, index) ~= "\n" do
				index = index + 1
			end
		elseif string.match(string.sub(source, index), "^#%d+=") ~= nil then
			local label = string.match(string.sub(source, index), "^#(%d+)=")
			local finish = index + #label + 1
			push_token("label_def", tonumber(label), index, finish)
			index = finish + 1
		elseif string.match(string.sub(source, index), "^#%d+#") ~= nil then
			local label = string.match(string.sub(source, index), "^#(%d+)#")
			local finish = index + #label + 1
			push_token("label_ref", tonumber(label), index, finish)
			index = finish + 1
		elseif string.sub(source, index, index + 10) == "#!fold-case" then
			fold_case = true
			index = index + 11
		elseif string.sub(source, index, index + 13) == "#!no-fold-case" then
			fold_case = false
			index = index + 14
		elseif string.sub(source, index, index + 1) == "#;" then
			push_token("datum_comment", "#;", index, index + 1)
			index = index + 2
		elseif char == "(" then
			push_token("open", char, index, index)
			index = index + 1
		elseif string.sub(source, index, index + 3) == "#u8(" then
			push_token("bytevector_open", "#u8(", index, index + 3)
			index = index + 4
		elseif char == "#" and string.sub(source, index + 1, index + 1) == "(" then
			push_token("vector_open", "#(", index, index + 1)
			index = index + 2
		elseif char == ")" then
			push_token("close", char, index, index)
			index = index + 1
		elseif char == "'" then
			push_token("quote", char, index, index)
			index = index + 1
		elseif char == "`" then
			push_token("quasiquote", char, index, index)
			index = index + 1
		elseif char == "," then
			local next_char = string.sub(source, index + 1, index + 1)

			if next_char == "@" then
				push_token("unquote_splicing", ",@", index, index + 1)
				index = index + 2
			else
				push_token("unquote", char, index, index)
				index = index + 1
			end
		elseif char == "\"" then
			local value
			local start_index = index
			value, index = read_string(source, index)
			push_token("string", value, start_index, index - 1)
		elseif char == "|" then
			local symbol
			local start_index = index
			symbol, index = read_bar_symbol(source, index)
			push_token("bar_atom", symbol, start_index, index - 1)
		else
			local start_index = index

			while index <= #source do
				local current = string.sub(source, index, index)

				if string.match(current, "%s")
					or current == "("
					or current == ")"
					or current == "'"
					or current == "`"
					or current == ","
					or current == "\""
					or current == "|"
					or current == ";" then
					break
				end

				index = index + 1
			end

			local atom = string.sub(source, start_index, index - 1)

			if fold_case then
				atom = string.lower(atom)
			end

			push_token("atom", atom, start_index, index - 1)
		end
	end

	return tokens
end

function reader.read(source)
	return parser.parse(reader.tokenize(source))
end

function reader.read_all(source)
	return parser.parse_all(reader.tokenize(source))
end

function reader.is_complete(source)
	local ok, err = pcall(reader.read_all, source)

	if ok then
		return true
	end

	local message = errors.message(err)

	if string.find(message, "unexpected end of input", 1, true) ~= nil then
		return false
	end

	return true
end

return reader
--[[
SPDX-License-Identifier: MPL-2.0
]]
