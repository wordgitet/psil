local unicode = {}

local upper_to_lower = {}
local lower_to_upper = {}
local fold_map = {}
local digit_zero_bases = {
	0x0030,
	0x0660,
	0x0AE6,
	0x0E50,
}
local combining_dot_above = 0x0307
local combining_caron = 0x030C

local function add_pair(upper, lower)
	upper_to_lower[upper] = {
		lower,
	}
	lower_to_upper[lower] = {
		upper,
	}
	fold_map[upper] = {
		lower,
	}
	fold_map[lower] = {
		lower,
	}
end

for codepoint = string.byte("A"), string.byte("Z") do
	add_pair(codepoint, codepoint + 32)
end

add_pair(0x0391, 0x03B1)
add_pair(0x0392, 0x03B2)
add_pair(0x0393, 0x03B3)
add_pair(0x0395, 0x03B5)
add_pair(0x039B, 0x03BB)
add_pair(0x039C, 0x03BC)
add_pair(0x039D, 0x03BD)
add_pair(0x039F, 0x03BF)
add_pair(0x03A3, 0x03C3)
add_pair(0x0388, 0x03AD)
add_pair(0x038C, 0x03CC)
add_pair(0x038F, 0x03CE)
lower_to_upper[0x03C2] = {
	0x03A3,
}

upper_to_lower[0x0130] = {
	string.byte("i"),
	combining_dot_above,
}
lower_to_upper[0x00DF] = {
	string.byte("S"),
	string.byte("S"),
}
lower_to_upper[0x01F0] = {
	string.byte("J"),
	combining_caron,
}
fold_map[0x0130] = {
	string.byte("i"),
	combining_dot_above,
}
fold_map[0x00DF] = {
	string.byte("s"),
	string.byte("s"),
}
fold_map[0x017F] = {
	string.byte("s"),
}
fold_map[0x03A3] = {
	0x03C3,
}
fold_map[0x03C2] = {
	0x03C3,
}

local alphabetic = {}

for upper, mapping in pairs(upper_to_lower) do
	alphabetic[upper] = true

	for _, codepoint in ipairs(mapping) do
		alphabetic[codepoint] = true
	end
end

for lower, mapping in pairs(lower_to_upper) do
	alphabetic[lower] = true

	for _, codepoint in ipairs(mapping) do
		alphabetic[codepoint] = true
	end
end

alphabetic[0x017F] = true
alphabetic[0x00DF] = true
alphabetic[0x01F0] = true
alphabetic[0x03C2] = true

local function copy_items(items)
	local copy = {}

	for index, item in ipairs(items) do
		copy[index] = item
	end

	return copy
end

local function append_all(target, items)
	for _, item in ipairs(items) do
		target[#target + 1] = item
	end
end

local function as_single_char(items)
	if #items ~= 1 then
		return nil
	end

	return utf8.char(items[1])
end

function unicode.char_digit_value(codepoint)
	for _, zero in ipairs(digit_zero_bases) do
		if codepoint >= zero and codepoint <= zero + 9 then
			return codepoint - zero
		end
	end

	return nil
end

function unicode.is_digit(codepoint)
	return unicode.char_digit_value(codepoint) ~= nil
end

function unicode.is_alphabetic(codepoint)
	return alphabetic[codepoint] == true
end

function unicode.is_upper(codepoint)
	return upper_to_lower[codepoint] ~= nil
end

function unicode.is_lower(codepoint)
	return lower_to_upper[codepoint] ~= nil or codepoint == 0x03C2 or codepoint == 0x017F
end

function unicode.uppercase_codepoints(codepoint)
	local mapping = lower_to_upper[codepoint]

	if mapping ~= nil then
		return copy_items(mapping)
	end

	return {
		codepoint,
	}
end

function unicode.lowercase_codepoints(codepoint)
	local mapping = upper_to_lower[codepoint]

	if mapping ~= nil then
		return copy_items(mapping)
	end

	return {
		codepoint,
	}
end

function unicode.foldcase_codepoints(codepoint)
	local mapping = fold_map[codepoint]

	if mapping ~= nil then
		return copy_items(mapping)
	end

	if unicode.is_upper(codepoint) then
		return unicode.lowercase_codepoints(codepoint)
	end

	return {
		codepoint,
	}
end

function unicode.upper_char(char)
	local codepoint = utf8.codepoint(char)
	return as_single_char(unicode.uppercase_codepoints(codepoint))
end

function unicode.lower_char(char)
	local codepoint = utf8.codepoint(char)
	return as_single_char(unicode.lowercase_codepoints(codepoint))
end

function unicode.fold_char(char)
	local codepoint = utf8.codepoint(char)
	return as_single_char(unicode.foldcase_codepoints(codepoint))
end

function unicode.map_codepoints(items, mode)
	local mapped = {}

	for _, codepoint in ipairs(items) do
		if mode == "upper" then
			append_all(mapped, unicode.uppercase_codepoints(codepoint))
		elseif mode == "lower" then
			append_all(mapped, unicode.lowercase_codepoints(codepoint))
		else
			append_all(mapped, unicode.foldcase_codepoints(codepoint))
		end
	end

	return mapped
end

return unicode
--[[
SPDX-License-Identifier: MPL-2.0
]]
