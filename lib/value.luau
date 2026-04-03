--[[
SPDX-License-Identifier: MPL-2.0
]]

local value = {}

-- Runtime value constructors and predicates.
-- The interpreter uses tagged Lua tables for language-visible values that do
-- not map cleanly onto plain Lua primitives: pairs, strings, vectors, ports,
-- closures, syntax objects, bigints, promises, and more.

local function utf8_to_codepoints(text)
	local items = {}

	for _, codepoint in utf8.codes(text) do
		items[#items + 1] = codepoint
	end

	return items
end

-- Strings are stored as Unicode codepoints inside the runtime so indexing and
-- mutation use Scheme character positions instead of UTF-8 byte offsets.
local function codepoints_to_utf8(items)
	local parts = {}

	for index, codepoint in ipairs(items) do
		parts[index] = utf8.char(codepoint)
	end

	return table.concat(parts)
end

function value.symbol(name, scope)
	return {
		kind = "symbol",
		name = name,
		scope = scope,
	}
end

function value.list(items, tail)
	return {
		kind = "list",
		items = items or {},
		tail = tail,
	}
end

-- list_root/list_view/list_tail_value let the runtime represent both proper
-- and improper lists without switching the whole interpreter to cons cells.
function value.list_root(item)
	if not value.is_list(item) then
		return nil, nil
	end

	if value.is_list(item.source_list) then
		return item.source_list, item.source_index or 1
	end

	return item, 1
end

function value.list_view(item, start_index)
	local root = item
	local absolute_index = start_index

	if value.is_list(item.source_list) then
		root = item.source_list
		absolute_index = (item.source_index or 1) + start_index - 1
	end

	local items = {}

	for index = absolute_index, #root.items do
		items[#items + 1] = root.items[index]
	end

	local view = value.list(items, root.tail)
	view.source_list = root
	view.source_index = absolute_index
	return view
end

function value.list_item_count(item)
	local root, start_index = value.list_root(item)

	if root == nil or start_index == nil then
		return 0
	end

	if start_index > #root.items then
		return 0
	end

	return #root.items - start_index + 1
end

function value.list_tail_value(item)
	local root = select(1, value.list_root(item))

	if root == nil then
		return nil
	end

	return root.tail
end

function value.vector(items)
	return {
		kind = "vector",
		items = items or {},
	}
end

function value.bytevector(items)
	return {
		kind = "bytevector",
		items = items or {},
	}
end

function value.string(items)
	return {
		kind = "string",
		items = items or {},
	}
end

function value.string_from_utf8(text)
	return value.string(utf8_to_codepoints(text))
end

function value.string_to_utf8(item)
	if not value.is_string(item) then
		return nil
	end

	return codepoints_to_utf8(item.items)
end

function value.string_length(item)
	if not value.is_string(item) then
		return nil
	end

	return #item.items
end

function value.copy_codepoints(items)
	local copy = {}

	for index, item in ipairs(items) do
		copy[index] = item
	end

	return copy
end

function value.string_copy(item, start_index, end_index)
	start_index = start_index or 0
	end_index = end_index or value.string_length(item)

	local copy = {}

	for index = start_index + 1, end_index do
		copy[#copy + 1] = item.items[index]
	end

	return value.string(copy)
end

function value.real(number, options)
	options = options or {}

	return {
		kind = "real",
		value = number,
		inexact = options.inexact ~= false,
		force_decimal = options.force_decimal == true,
		negative_zero = options.negative_zero == true,
		exact_repr = options.exact_repr,
	}
end

-- Bigints are intentionally narrow: exact integer text plus a small handful of
-- operations needed for conformance-heavy numeric paths.
function value.bigint(text)
	return {
		kind = "bigint",
		text = text,
	}
end

function value.complex(real, imag, options)
	options = options or {}

	return {
		kind = "complex",
		real = real,
		imag = imag,
		real_inexact = options.real_inexact == true,
		imag_inexact = options.imag_inexact == true,
		real_repr = options.real_repr,
		imag_repr = options.imag_repr,
	}
end

function value.char(char)
	return {
		kind = "char",
		value = char,
	}
end

function value.eof()
	return {
		kind = "eof",
	}
end

function value.port(mode, options)
	options = options or {}

	return {
		kind = "port",
		mode = mode,
		binary = options.binary == true,
		source = options.source or "",
		position = options.position or 1,
		buffer = options.buffer or {},
		source_bytes = options.source_bytes or {},
		buffer_bytes = options.buffer_bytes or {},
		closed = options.closed == true,
		io_adapter = options.io_adapter,
	}
end

-- Closures carry small evaluator hints so ordinary code can stay on the direct
-- fast path while continuation-sensitive bodies opt into CPS.
function value.closure(params, body, env, options)
	options = options or {}

	return {
		kind = "closure",
		param_spec = params,
		params = params.fixed or {},
		body = body,
		env = env,
		needs_cps = options.needs_cps == true,
		preexpand_body = options.preexpand_body == true,
		expanded_body = options.expanded_body,
		vm_chunk = options.vm_chunk,
		vm_captures = options.vm_captures,
	}
end

function value.builtin(name, fn, options)
	options = options or {}

	return {
		kind = "builtin",
		name = name,
		fn = fn,
		cps = options.cps == true,
	}
end

function value.syntax(name, transformer)
	return {
		kind = "syntax",
		name = name,
		transformer = transformer,
	}
end

function value.syntactic_closure(scope, free_names, expr)
	return {
		kind = "syntactic_closure",
		scope = scope,
		free_names = free_names or {},
		expr = expr,
	}
end

function value.uninitialized(name)
	return {
		kind = "uninitialized",
		name = name,
	}
end

function value.record(type_name, fields)
	return {
		kind = "record",
		type_name = type_name,
		fields = fields or {},
	}
end

function value.exception(message, irritants, flags)
	flags = flags or {}

	return {
		kind = "exception",
		message = message,
		irritants = irritants or {},
		file_error = flags.file_error == true,
		read_error = flags.read_error == true,
	}
end

function value.promise(thunk)
	return {
		kind = "promise",
		thunk = thunk,
		forced = false,
		value = nil,
	}
end

function value.multi_values(items)
	return {
		kind = "multi_values",
		items = items or {},
	}
end

function value.param_spec(fixed, rest, keywords)
	return {
		kind = "param_spec",
		fixed = fixed or {},
		rest = rest,
		keywords = keywords or {},
	}
end

function value.is_symbol(item)
	return type(item) == "table" and item.kind == "symbol"
end

function value.symbol_name(item)
	if not value.is_symbol(item) then
		return nil
	end

	return item.name
end

function value.is_symbol_named(item, name)
	return value.is_symbol(item) and item.name == name
end

function value.is_list(item)
	return type(item) == "table" and item.kind == "list"
end

function value.is_closure(item)
	return type(item) == "table" and item.kind == "closure"
end

function value.is_vector(item)
	return type(item) == "table" and item.kind == "vector"
end

function value.is_string(item)
	return type(item) == "table" and item.kind == "string"
end

function value.is_bytevector(item)
	return type(item) == "table" and item.kind == "bytevector"
end

function value.is_complex(item)
	return type(item) == "table" and item.kind == "complex"
end

function value.is_bigint(item)
	return type(item) == "table" and item.kind == "bigint"
end

function value.is_real(item)
	return type(item) == "table" and item.kind == "real"
end

function value.is_char(item)
	return type(item) == "table" and item.kind == "char"
end

function value.is_eof(item)
	return type(item) == "table" and item.kind == "eof"
end

function value.is_port(item)
	return type(item) == "table" and item.kind == "port"
end

function value.is_builtin(item)
	return type(item) == "table" and item.kind == "builtin"
end

function value.is_syntax(item)
	return type(item) == "table" and item.kind == "syntax"
end

function value.is_syntactic_closure(item)
	return type(item) == "table" and item.kind == "syntactic_closure"
end

function value.is_uninitialized(item)
	return type(item) == "table" and item.kind == "uninitialized"
end

function value.is_record(item)
	return type(item) == "table" and item.kind == "record"
end

function value.is_exception(item)
	return type(item) == "table" and item.kind == "exception"
end

function value.is_promise(item)
	return type(item) == "table" and item.kind == "promise"
end

function value.is_multi_values(item)
	return type(item) == "table" and item.kind == "multi_values"
end

function value.is_param_spec(item)
	return type(item) == "table" and item.kind == "param_spec"
end

function value.is_callable(item)
	return value.is_closure(item) or value.is_builtin(item)
end

function value.is_truthy(item)
	return item ~= false
end

function value.copy_items(items)
	local copy = {}

	for index, item in ipairs(items) do
		copy[index] = item
	end

	return copy
end

function value.is_proper_list(item)
	return value.is_list(item) and value.list_tail_value(item) == nil
end

return value
