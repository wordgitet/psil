--[[
SPDX-License-Identifier: MPL-2.0
]]

--!native
--!optimize 2

local bind = require("./bind")
local builtins = require("./builtins")
local env = require("./env")
local errors = require("./errors")
local value = require("./value")

local vm = {}

local OP_CONST = 1
local OP_MOVE = 2
local OP_LOAD_LOCAL = 3
local OP_STORE_LOCAL = 4
local OP_LOAD_CAPTURE = 5
local OP_STORE_CAPTURE = 6
local OP_LOAD_GLOBAL = 7
local OP_DEFINE_GLOBAL = 8
local OP_STORE_GLOBAL = 9
local OP_JUMP = 10
local OP_JUMP_IF_FALSE = 11
local OP_CALL = 12
local OP_TAIL_CALL = 13
local OP_RETURN = 14
local OP_MAKE_CLOSURE = 15
local OP_NUM_ADD = 16
local OP_NUM_SUB = 17
local OP_NUM_EQ = 18
local OP_NUM_LT = 19
local OP_CONS = 20
local OP_CALL_GLOBAL = 21
local OP_TAIL_CALL_GLOBAL = 22

local EMPTY_LIST = value.list({})
local FALLBACK_UNSUPPORTED_SPECIAL_FORM = "unsupported_special_form"
local FALLBACK_UNSUPPORTED_LAMBDA_LIST = "unsupported_lambda_list"
local FALLBACK_UNSUPPORTED_BINDING_FORM = "unsupported_binding_form"
local FALLBACK_UNSUPPORTED_CALL_SHAPE = "unsupported_call_shape"
local FALLBACK_REQUIRES_INTERPRETER_CONTROL = "requires_interpreter_control"
local RESERVED_SPECIAL_FORMS = {
	["begin"] = true,
	["case"] = true,
	["case-lambda"] = true,
	["cond"] = true,
	["define"] = true,
	["define-record-type"] = true,
	["define-syntax"] = true,
	["define-values"] = true,
	["delay"] = true,
	["do"] = true,
	["dynamic-wind"] = true,
	["guard"] = true,
	["if"] = true,
	["lambda"] = true,
	["let-values"] = true,
	["let*-values"] = true,
	["let-syntax"] = true,
	["letrec"] = true,
	["letrec*"] = true,
	["letrec-syntax"] = true,
	["parameterize"] = true,
	["quasiquote"] = true,
	["quote"] = true,
	["set!"] = true,
}
local INTERPRETER_CONTROL_FORMS = {
	["call-with-current-continuation"] = true,
	["call/cc"] = true,
	["delay"] = true,
	["do"] = true,
	["dynamic-wind"] = true,
	["guard"] = true,
	["parameterize"] = true,
	["with-exception-handler"] = true,
	["raise"] = true,
	["raise-continuable"] = true,
}

local create_array = table.create or function(size, fill)
	local items = {}

	if fill ~= nil then
		for index = 1, size do
			items[index] = fill
		end
	end

	return items
end

local function make_cell(item)
	return {
		__psil_vm_cell = true,
		value = item,
	}
end

local function is_cell(item)
	return type(item) == "table" and item.__psil_vm_cell == true
end

local function read_slot(slots, index)
	local item = slots[index]

	if is_cell(item) then
		return item.value
	end

	return item
end

local function write_slot(slots, index, item)
	local current = slots[index]

	if is_cell(current) then
		current.value = item
	else
		slots[index] = item
	end
end

local function add_constant(chunk, item)
	local constants = chunk.constants
	constants[#constants + 1] = item
	return #constants
end

local function add_proto(chunk, proto)
	local protos = chunk.protos
	protos[#protos + 1] = proto
	return #protos
end

local function add_global(chunk, name)
	local globals = chunk.global_names

	for index, item in ipairs(globals) do
		if item == name then
			return index
		end
	end

	globals[#globals + 1] = name
	return #globals
end

local function emit(ctx, op, a, b, c, d)
	local code = ctx.chunk.code
	code[#code + 1] = {
		op = op,
		a = a,
		b = b,
		c = c,
		d = d,
	}
	return #code
end

local function patch_jump(ctx, pc, target)
	local instruction = ctx.chunk.code[pc]

	if instruction.op == OP_JUMP then
		instruction.a = target
	else
		instruction.b = target
	end
end

local function alloc_reg(ctx)
	ctx.next_reg = ctx.next_reg + 1

	if ctx.next_reg > ctx.chunk.max_register then
		ctx.chunk.max_register = ctx.next_reg
	end

	return ctx.next_reg
end

local function reserve_regs(ctx, count)
	local start = ctx.next_reg + 1
	ctx.next_reg = ctx.next_reg + count

	if ctx.next_reg > ctx.chunk.max_register then
		ctx.chunk.max_register = ctx.next_reg
	end

	return start
end

local function new_context(scope, parent)
	local ctx = {
		scope = scope,
		parent = parent,
		next_reg = 0,
		locals = {},
		captures = {},
		chunk = {
			code = {},
			constants = {},
			protos = {},
			global_names = {},
			max_register = 0,
			param_spec = nil,
			param_count = 0,
			capture_specs = {},
			captured_locals = {},
		},
	}

	return ctx
end

local function unsupported(reason, detail)
	return {
		compiled = false,
		fallback_reason = reason,
		fallback_detail = detail,
		stats = {
			instruction_count = 0,
			register_count = 0,
			capture_count = 0,
		},
	}
end

local function clone_capture_spec(spec)
	return {
		kind = spec.kind,
		index = spec.index,
		name = spec.name,
	}
end

local resolve_name

local function add_capture(ctx, spec)
	local existing = ctx.captures[spec.name]

	if existing ~= nil then
		return existing
	end

	local capture_specs = ctx.chunk.capture_specs
	capture_specs[#capture_specs + 1] = clone_capture_spec(spec)
	local resolved = {
		kind = "capture",
		index = #capture_specs,
		name = spec.name,
	}
	ctx.captures[spec.name] = resolved
	return resolved
end

resolve_name = function(ctx, name)
	local local_slot = ctx.locals[name]

	if local_slot ~= nil then
		return {
			kind = "local",
			index = local_slot,
			name = name,
		}
	end

	local capture = ctx.captures[name]

	if capture ~= nil then
		return capture
	end

	if ctx.parent ~= nil then
		local parent_ref = resolve_name(ctx.parent, name)

		if parent_ref.kind == "local" then
			ctx.parent.chunk.captured_locals[parent_ref.index] = true
			return add_capture(ctx, parent_ref)
		end

		if parent_ref.kind == "capture" then
			return add_capture(ctx, parent_ref)
		end
	end

	return {
		kind = "global",
		name = name,
	}
end

local compile_expr
local compile_sequence

local function push_local(ctx, name, register)
	local previous = ctx.locals[name]
	ctx.locals[name] = register
	return {
		name = name,
		previous = previous,
	}
end

local function restore_locals(ctx, restores)
	for index = #restores, 1, -1 do
		local restore = restores[index]

		if restore.previous == nil then
			ctx.locals[restore.name] = nil
		else
			ctx.locals[restore.name] = restore.previous
		end
	end
end

local function parse_bindings(form_name, bindings_form)
	if value.is_symbol(bindings_form) then
		return nil, unsupported(
			FALLBACK_UNSUPPORTED_SPECIAL_FORM,
			string.format("%s does not support named binding syntax", form_name)
		)
	end

	if not value.is_list(bindings_form) or bindings_form.tail ~= nil then
		return nil, unsupported(
			FALLBACK_UNSUPPORTED_BINDING_FORM,
			string.format("%s expected a proper binding list", form_name)
		)
	end

	local bindings = {}

	for _, binding in ipairs(bindings_form.items) do
		if not value.is_list(binding)
			or binding.tail ~= nil
			or #binding.items ~= 2
			or not value.is_symbol(binding.items[1]) then
			return nil, unsupported(
				FALLBACK_UNSUPPORTED_BINDING_FORM,
				string.format("%s expected (name init) bindings", form_name)
			)
		end

		bindings[#bindings + 1] = {
			name = binding.items[1].name,
			init = binding.items[2],
		}
	end

	return bindings
end

local function compile_let_like(ctx, form, target, tail_position, sequential)
	local bindings, binding_err = parse_bindings(
		sequential and "let*" or "let",
		form.items[2]
	)

	if bindings == nil then
		return nil, binding_err
	end

	local restores = {}
	local ok = nil
	local err = nil

	if sequential then
		for _, binding in ipairs(bindings) do
			local init_reg = alloc_reg(ctx)
			ok, err = compile_expr(ctx, binding.init, init_reg, false)

			if not ok then
				restore_locals(ctx, restores)
				return nil, err
			end

			restores[#restores + 1] = push_local(ctx, binding.name, init_reg)
		end
	else
		local init_regs = {}

		for _, binding in ipairs(bindings) do
			local init_reg = alloc_reg(ctx)
			ok, err = compile_expr(ctx, binding.init, init_reg, false)

			if not ok then
				restore_locals(ctx, restores)
				return nil, err
			end

			init_regs[#init_regs + 1] = init_reg
		end

		for index, binding in ipairs(bindings) do
			restores[#restores + 1] = push_local(ctx, binding.name, init_regs[index])
		end
	end

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	ok, err = compile_sequence(ctx, body, target, tail_position)
	restore_locals(ctx, restores)

	if not ok then
		return nil, err
	end

	return true
end

local function compile_and(ctx, form, target, tail_position)
	if #form.items == 1 then
		local true_index = add_constant(ctx.chunk, true)
		emit(ctx, OP_CONST, target, true_index)
		return true
	end

	local jump_end = {}

	for index = 2, #form.items do
		local ok, err = compile_expr(ctx, form.items[index], target, tail_position and index == #form.items)

		if not ok then
			return nil, err
		end

		if index < #form.items then
			jump_end[#jump_end + 1] = emit(ctx, OP_JUMP_IF_FALSE, target, 0)
		end
	end

	local end_pc = #ctx.chunk.code + 1

	for _, pc in ipairs(jump_end) do
		patch_jump(ctx, pc, end_pc)
	end

	return true
end

local function compile_or(ctx, form, target, tail_position)
	if #form.items == 1 then
		local false_index = add_constant(ctx.chunk, false)
		emit(ctx, OP_CONST, target, false_index)
		return true
	end

	local jump_end = {}

	for index = 2, #form.items do
		local ok, err = compile_expr(ctx, form.items[index], target, tail_position and index == #form.items)

		if not ok then
			return nil, err
		end

		if index < #form.items then
			local jump_next = emit(ctx, OP_JUMP_IF_FALSE, target, 0)
			jump_end[#jump_end + 1] = emit(ctx, OP_JUMP, 0)
			patch_jump(ctx, jump_next, #ctx.chunk.code + 1)
		end
	end

	local end_pc = #ctx.chunk.code + 1

	for _, pc in ipairs(jump_end) do
		patch_jump(ctx, pc, end_pc)
	end

	return true
end

local function compile_when_like(ctx, form, target, tail_position, run_on_false)
	local cond_reg = alloc_reg(ctx)
	local cond_ok, cond_err = compile_expr(ctx, form.items[2], cond_reg, false)

	if not cond_ok then
		return nil, cond_err
	end

	if run_on_false then
		local jump_body = emit(ctx, OP_JUMP_IF_FALSE, cond_reg, 0)
		local empty_index = add_constant(ctx.chunk, EMPTY_LIST)
		emit(ctx, OP_CONST, target, empty_index)
		local jump_end = emit(ctx, OP_JUMP, 0)
		patch_jump(ctx, jump_body, #ctx.chunk.code + 1)
		local body = {}

		for index = 3, #form.items do
			body[#body + 1] = form.items[index]
		end

		local body_ok, body_err = compile_sequence(ctx, body, target, tail_position)

		if not body_ok then
			return nil, body_err
		end

		patch_jump(ctx, jump_end, #ctx.chunk.code + 1)
		return true
	end

	local jump_empty = emit(ctx, OP_JUMP_IF_FALSE, cond_reg, 0)
	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	local body_ok, body_err = compile_sequence(ctx, body, target, tail_position)

	if not body_ok then
		return nil, body_err
	end

	local jump_end = emit(ctx, OP_JUMP, 0)
	patch_jump(ctx, jump_empty, #ctx.chunk.code + 1)
	local empty_index = add_constant(ctx.chunk, EMPTY_LIST)
	emit(ctx, OP_CONST, target, empty_index)
	patch_jump(ctx, jump_end, #ctx.chunk.code + 1)
	return true
end

local function compile_intrinsic_call(ctx, name, form, target)
	local argc = #form.items - 1

	if name == "+" then
		if argc == 0 then
			local zero_index = add_constant(ctx.chunk, 0)
			emit(ctx, OP_CONST, target, zero_index)
			return true
		end

		local ok, err = compile_expr(ctx, form.items[2], target, false)

		if not ok then
			return nil, err
		end

		for index = 3, #form.items do
			local right_reg = alloc_reg(ctx)
			local right_ok, right_err = compile_expr(ctx, form.items[index], right_reg, false)

			if not right_ok then
				return nil, right_err
			end

			emit(ctx, OP_NUM_ADD, target, target, right_reg)
		end

		return true
	end

	if name == "-" then
		if argc == 0 then
			return nil, unsupported(
				FALLBACK_UNSUPPORTED_CALL_SHAPE,
				"'-' expects at least one argument in the Scheme VM"
			)
		end

		if argc == 1 then
			local zero_reg = alloc_reg(ctx)
			local zero_index = add_constant(ctx.chunk, 0)
			emit(ctx, OP_CONST, zero_reg, zero_index)
			local right_ok, right_err = compile_expr(ctx, form.items[2], target, false)

			if not right_ok then
				return nil, right_err
			end

			emit(ctx, OP_NUM_SUB, target, zero_reg, target)
			return true
		end

		local ok, err = compile_expr(ctx, form.items[2], target, false)

		if not ok then
			return nil, err
		end

		for index = 3, #form.items do
			local right_reg = alloc_reg(ctx)
			local right_ok, right_err = compile_expr(ctx, form.items[index], right_reg, false)

			if not right_ok then
				return nil, right_err
			end

			emit(ctx, OP_NUM_SUB, target, target, right_reg)
		end

		return true
	end

	if name == "=" or name == "<" then
		if argc ~= 2 then
			return nil, unsupported(
				FALLBACK_UNSUPPORTED_CALL_SHAPE,
				string.format("'%s' expects exactly two arguments in the Scheme VM", name)
			)
		end

		local left_ok, left_err = compile_expr(ctx, form.items[2], target, false)

		if not left_ok then
			return nil, left_err
		end

		local right_reg = alloc_reg(ctx)
		local right_ok, right_err = compile_expr(ctx, form.items[3], right_reg, false)

		if not right_ok then
			return nil, right_err
		end

		emit(ctx, name == "=" and OP_NUM_EQ or OP_NUM_LT, target, target, right_reg)
		return true
	end

	if name == "cons" and argc == 2 then
		local left_ok, left_err = compile_expr(ctx, form.items[2], target, false)

		if not left_ok then
			return nil, left_err
		end

		local right_reg = alloc_reg(ctx)
		local right_ok, right_err = compile_expr(ctx, form.items[3], right_reg, false)

		if not right_ok then
			return nil, right_err
		end

		emit(ctx, OP_CONS, target, target, right_reg)
		return true
	end

	return false
end

local function compile_lambda(form, ctx, target)
	local param_spec = bind.parse_param_spec(form.items[2])

	if param_spec.rest ~= nil then
		return nil, unsupported(
			FALLBACK_UNSUPPORTED_LAMBDA_LIST,
			"rest parameters are not supported by the Scheme VM"
		)
	end

	if param_spec.keywords ~= nil and param_spec.keywords.cl then
		return nil, unsupported(
			FALLBACK_UNSUPPORTED_LAMBDA_LIST,
			"cl lambda lists are not supported by the Scheme VM"
		)
	end

	local child = new_context(ctx.scope, ctx)
	child.chunk.param_spec = param_spec
	child.chunk.param_count = #param_spec.fixed

	for index, name in ipairs(param_spec.fixed) do
		child.locals[name] = index
	end

	child.next_reg = #param_spec.fixed
	child.chunk.max_register = #param_spec.fixed

	local body = {}

	for index = 3, #form.items do
		body[#body + 1] = form.items[index]
	end

	if #body == 0 then
		return nil, unsupported(
			FALLBACK_UNSUPPORTED_LAMBDA_LIST,
			"lambda body missing"
		)
	end

	for body_index, body_form in ipairs(body) do
		local dst = alloc_reg(child)
		local ok, err = compile_expr(child, body_form, dst, body_index == #body)

		if not ok then
			return nil, err
		end

		if body_index == #body then
			emit(child, OP_RETURN, dst)
		end
	end

	local proto_index = add_proto(ctx.chunk, child.chunk)
	emit(ctx, OP_MAKE_CLOSURE, target, proto_index)
	return true
end

compile_sequence = function(ctx, forms, target, tail_position)
	if #forms == 0 then
		local empty_index = add_constant(ctx.chunk, EMPTY_LIST)
		emit(ctx, OP_CONST, target, empty_index)
		return true
	end

	for index, form in ipairs(forms) do
		local ok, err = compile_expr(ctx, form, target, tail_position and index == #forms)

		if not ok then
			return nil, err
		end
	end

	return true
end

local function compile_define(ctx, form, target)
	local target_form = form.items[2]

	if not value.is_symbol(target_form) then
		return nil, unsupported(
			FALLBACK_UNSUPPORTED_BINDING_FORM,
			"define target must be a symbol"
		)
	end

	local ok, err = compile_expr(ctx, form.items[3], target, false)

	if not ok then
		return nil, err
	end

	emit(ctx, OP_DEFINE_GLOBAL, target, add_global(ctx.chunk, target_form.name))
	return true
end

local function compile_set(ctx, form, target)
	local target_form = form.items[2]

	if not value.is_symbol(target_form) then
		return nil, unsupported(
			FALLBACK_UNSUPPORTED_BINDING_FORM,
			"set! target must be a symbol"
		)
	end

	local ok, err = compile_expr(ctx, form.items[3], target, false)

	if not ok then
		return nil, err
	end

	local resolved = resolve_name(ctx, target_form.name)

	if resolved.kind == "local" then
		emit(ctx, OP_STORE_LOCAL, resolved.index, target)
	elseif resolved.kind == "capture" then
		emit(ctx, OP_STORE_CAPTURE, resolved.index, target)
	else
		emit(ctx, OP_STORE_GLOBAL, target, add_global(ctx.chunk, target_form.name))
	end

	return true
end

local function compile_call(ctx, form, target, tail_position)
	if value.is_symbol(form.items[1]) then
		local head_name = form.items[1].name
		local specialized, specialized_err = compile_intrinsic_call(ctx, head_name, form, target)

		if specialized ~= false then
			return specialized, specialized_err
		end

		local resolved_head = resolve_name(ctx, head_name)

		if resolved_head.kind == "global" then
			local argc = #form.items - 1
			local args_start = reserve_regs(ctx, argc)

			for index = 2, #form.items do
				local arg_reg = alloc_reg(ctx)
				local arg_ok, arg_err = compile_expr(ctx, form.items[index], arg_reg, false)

				if not arg_ok then
					return nil, arg_err
				end

				emit(ctx, OP_MOVE, args_start + index - 2, arg_reg)
			end

			emit(
				ctx,
				tail_position and OP_TAIL_CALL_GLOBAL or OP_CALL_GLOBAL,
				target,
				add_global(ctx.chunk, head_name),
				args_start,
				argc
			)
			return true
		end
	end

	local fn_reg = alloc_reg(ctx)
	local ok, err = compile_expr(ctx, form.items[1], fn_reg, false)

	if not ok then
		return nil, err
	end

	local argc = #form.items - 1
	local args_start = reserve_regs(ctx, argc)

	for index = 2, #form.items do
		local arg_reg = alloc_reg(ctx)
		local arg_ok, arg_err = compile_expr(ctx, form.items[index], arg_reg, false)

		if not arg_ok then
			return nil, arg_err
		end

		emit(ctx, OP_MOVE, args_start + index - 2, arg_reg)
	end

	emit(ctx, tail_position and OP_TAIL_CALL or OP_CALL, target, fn_reg, args_start, argc)
	return true
end

compile_expr = function(ctx, form, target, tail_position)
	if value.is_symbol(form) then
		local resolved = resolve_name(ctx, form.name)

		if resolved.kind == "local" then
			emit(ctx, OP_LOAD_LOCAL, target, resolved.index)
		elseif resolved.kind == "capture" then
			emit(ctx, OP_LOAD_CAPTURE, target, resolved.index)
		else
			emit(ctx, OP_LOAD_GLOBAL, target, add_global(ctx.chunk, form.name))
		end

		return true
	end

	if not value.is_list(form) then
		local constant_index = add_constant(ctx.chunk, form)
		emit(ctx, OP_CONST, target, constant_index)
		return true
	end

	if #form.items == 0 then
		local empty_index = add_constant(ctx.chunk, form)
		emit(ctx, OP_CONST, target, empty_index)
		return true
	end

	local head = form.items[1]

	if value.is_symbol(head) then
		if head.name == "quote" then
			local constant_index = add_constant(ctx.chunk, form.items[2] or EMPTY_LIST)
			emit(ctx, OP_CONST, target, constant_index)
			return true
		end

		if head.name == "if" then
			local cond_reg = alloc_reg(ctx)
			local cond_ok, cond_err = compile_expr(ctx, form.items[2], cond_reg, false)

			if not cond_ok then
				return nil, cond_err
			end

			local jump_false = emit(ctx, OP_JUMP_IF_FALSE, cond_reg, 0)
			local then_ok, then_err = compile_expr(ctx, form.items[3], target, tail_position)

			if not then_ok then
				return nil, then_err
			end

			local jump_end = emit(ctx, OP_JUMP, 0)

			patch_jump(ctx, jump_false, #ctx.chunk.code + 1)

			if form.items[4] ~= nil then
				local else_ok, else_err = compile_expr(ctx, form.items[4], target, tail_position)

				if not else_ok then
					return nil, else_err
				end
			else
				local empty_index = add_constant(ctx.chunk, EMPTY_LIST)
				emit(ctx, OP_CONST, target, empty_index)
			end

			patch_jump(ctx, jump_end, #ctx.chunk.code + 1)

			return true
		end

		if head.name == "begin" then
			local body = {}

			for index = 2, #form.items do
				body[#body + 1] = form.items[index]
			end

			return compile_sequence(ctx, body, target, tail_position)
		end

		if head.name == "lambda" then
			return compile_lambda(form, ctx, target)
		end

		if head.name == "let" then
			return compile_let_like(ctx, form, target, tail_position, false)
		end

		if head.name == "let*" then
			return compile_let_like(ctx, form, target, tail_position, true)
		end

		if head.name == "and" then
			return compile_and(ctx, form, target, tail_position)
		end

		if head.name == "or" then
			return compile_or(ctx, form, target, tail_position)
		end

		if head.name == "when" then
			return compile_when_like(ctx, form, target, tail_position, false)
		end

		if head.name == "unless" then
			return compile_when_like(ctx, form, target, tail_position, true)
		end

		if head.name == "define" then
			return compile_define(ctx, form, target)
		end

		if head.name == "set!" then
			return compile_set(ctx, form, target)
		end

		if INTERPRETER_CONTROL_FORMS[head.name] then
			return nil, unsupported(
				FALLBACK_REQUIRES_INTERPRETER_CONTROL,
				string.format("'%s' requires interpreter control flow", head.name)
			)
		end

		if RESERVED_SPECIAL_FORMS[head.name] then
			return nil, unsupported(
				FALLBACK_UNSUPPORTED_SPECIAL_FORM,
				string.format("unsupported special form '%s'", head.name)
			)
		end
	end

	return compile_call(ctx, form, target, tail_position)
end

function vm.try_compile_forms(forms, scope)
	local ctx = new_context(scope, nil)
	local target = alloc_reg(ctx)
	local ok, err = compile_sequence(ctx, forms, target, true)

	if not ok then
		return err
	end

	if #ctx.chunk.code == 0 or ctx.chunk.code[#ctx.chunk.code].op ~= OP_RETURN then
		emit(ctx, OP_RETURN, target)
	end

	ctx.chunk.compiled = true
	ctx.chunk.fallback_reason = nil
	ctx.chunk.stats = {
		instruction_count = #ctx.chunk.code,
		register_count = ctx.chunk.max_register,
		capture_count = #(ctx.chunk.capture_specs or {}),
	}

	return ctx.chunk
end

function vm.compile_forms(forms, scope)
	local chunk = vm.try_compile_forms(forms, scope)

	if chunk.compiled == false then
		return nil, chunk
	end

	return chunk
end

function vm.try_compile_form(form, scope)
	return vm.try_compile_forms({
		form,
	}, scope)
end

function vm.compile_form(form, scope)
	return vm.compile_forms({
		form,
	}, scope)
end

local function build_vm_closure(proto, scope, captures)
	return value.closure(proto.param_spec or value.param_spec({}, nil, {}), {}, scope, {
		vm_chunk = proto,
		vm_captures = captures,
	})
end

local function acquire_frame(chunk)
	local pool = chunk.frame_pool

	if pool ~= nil then
		local frame = pool[#pool]

		if frame ~= nil then
			pool[#pool] = nil
			return frame
		end
	end

	return {}
end

local function acquire_regs(chunk)
	local pool = chunk.reg_pool

	if pool ~= nil then
		local regs = pool[#pool]

		if regs ~= nil then
			pool[#pool] = nil
			return regs
		end
	end

	return create_array(chunk.max_register)
end

local function release_frame(frame)
	local chunk = frame.chunk
	local regs = frame.regs

	if regs ~= nil then
		for index = 1, chunk.max_register do
			regs[index] = nil
		end

		chunk.reg_pool = chunk.reg_pool or {}
		chunk.reg_pool[#chunk.reg_pool + 1] = regs
	end

	frame.chunk = nil
	frame.scope = nil
	frame.captures = nil
	frame.regs = nil
	frame.pc = nil
	frame.return_reg = nil

	chunk.frame_pool = chunk.frame_pool or {}
	chunk.frame_pool[#chunk.frame_pool + 1] = frame
end

local function build_frame_from_registers(chunk, scope, captures, source_regs, start_index, count)
	if chunk.param_count ~= nil and count ~= chunk.param_count then
		errors.raise(
			"arity",
			string.format("expected %d arguments, got %d", chunk.param_count, count)
		)
	end

	local regs = acquire_regs(chunk)

	for index = 1, count do
		local item = source_regs[start_index + index - 1]

		if chunk.captured_locals[index] then
			regs[index] = make_cell(item)
		else
			regs[index] = item
		end
	end

	local frame = acquire_frame(chunk)
	frame.chunk = chunk
	frame.scope = scope
	frame.captures = captures or {}
	frame.regs = regs
	frame.pc = 1
	frame.return_reg = nil
	return frame
end

local function build_frame(chunk, scope, captures, args)
	return build_frame_from_registers(chunk, scope, captures, args, 1, #args)
end

local function collect_args(frame, start_index, count)
	local args = {}

	for index = 0, count - 1 do
		args[#args + 1] = frame.regs[start_index + index]
	end

	return args
end

local function ensure_global_cache(chunk, scope)
	if chunk.global_cache_scope ~= scope or chunk.global_frames == nil then
		chunk.global_cache_scope = scope
		chunk.global_frames = {}
	end

	return chunk.global_frames
end

local function get_cached_global_frame(frame, index)
	local chunk = frame.chunk
	local global_frames = ensure_global_cache(chunk, frame.scope)
	local cached = global_frames[index]

	if cached == false then
		cached = nil
	end

	if cached == nil then
		cached = env.find_frame(frame.scope, chunk.global_names[index])
		global_frames[index] = cached or false
	end

	return cached, chunk.global_names[index], global_frames
end

local function load_global(frame, index)
	local global_frame, name = get_cached_global_frame(frame, index)

	if global_frame == nil then
		errors.raise("name", string.format("undefined symbol '%s'", name))
	end

	local item = global_frame.values[name]

	if value.is_uninitialized(item) then
		errors.raise(
			"name",
			string.format("letrec binding '%s' accessed before initialization", name)
		)
	end

	return item
end

local function define_global(frame, index, item)
	local chunk = frame.chunk
	local name = chunk.global_names[index]
	local global_frames = ensure_global_cache(chunk, frame.scope)

	frame.scope.values[name] = item
	global_frames[index] = frame.scope
	return item
end

local function store_global(frame, index, item)
	local global_frame, name = get_cached_global_frame(frame, index)

	if global_frame == nil then
		errors.raise("name", string.format("cannot set undefined symbol '%s'", name))
	end

	global_frame.values[name] = item
	return item
end

local function dispatch_call(frames, frame, callable, call_args, execution, apply_callable_fn, target_reg, tail_call)
	if value.is_closure(callable) and callable.vm_chunk ~= nil then
		local next_frame = build_frame(callable.vm_chunk, callable.env, callable.vm_captures, call_args)

		if tail_call then
			next_frame.return_reg = frame.return_reg
			frames[#frames] = next_frame
		else
			frame.pc = frame.pc + 1
			next_frame.return_reg = target_reg
			frames[#frames + 1] = next_frame
		end

		return
	end

	local result = apply_callable_fn(callable, call_args, execution)

	if not tail_call then
		frame.regs[target_reg] = result
		frame.pc = frame.pc + 1
		return
	end

	local finished_frame = table.remove(frames)
	local return_reg = finished_frame.return_reg
	release_frame(finished_frame)

	if #frames == 0 then
		return result, true
	end

	local caller = frames[#frames]
	caller.regs[return_reg] = result
	return nil, false
end

function vm.run_chunk(chunk, scope, execution, apply_callable_fn, captures, args)
	local frames = {
		build_frame(chunk, scope, captures, args or {}),
	}

	while #frames > 0 do
		local frame = frames[#frames]
		local instruction = frame.chunk.code[frame.pc]

		if instruction == nil then
			instruction = {
				op = OP_RETURN,
				a = 1,
			}
		end

		if instruction.op == OP_CONST then
			frame.regs[instruction.a] = frame.chunk.constants[instruction.b]
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_MOVE then
			frame.regs[instruction.a] = frame.regs[instruction.b]
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_LOAD_LOCAL then
			frame.regs[instruction.a] = read_slot(frame.regs, instruction.b)
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_STORE_LOCAL then
			write_slot(frame.regs, instruction.a, frame.regs[instruction.b])
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_LOAD_CAPTURE then
			frame.regs[instruction.a] = read_slot(frame.captures, instruction.b)
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_STORE_CAPTURE then
			write_slot(frame.captures, instruction.a, frame.regs[instruction.b])
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_LOAD_GLOBAL then
			frame.regs[instruction.a] = load_global(frame, instruction.b)
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_DEFINE_GLOBAL then
			local item = frame.regs[instruction.a]
			frame.regs[instruction.a] = define_global(frame, instruction.b, item)
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_STORE_GLOBAL then
			local item = frame.regs[instruction.a]
			frame.regs[instruction.a] = store_global(frame, instruction.b, item)
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_JUMP then
			frame.pc = instruction.a
		elseif instruction.op == OP_JUMP_IF_FALSE then
			if frame.regs[instruction.a] == false then
				frame.pc = instruction.b
			else
				frame.pc = frame.pc + 1
			end
		elseif instruction.op == OP_MAKE_CLOSURE then
			local proto = frame.chunk.protos[instruction.b]
			local capture_values = {}

			for index, spec in ipairs(proto.capture_specs or {}) do
				if spec.kind == "local" then
					local captured = frame.regs[spec.index]

					if not is_cell(captured) then
						captured = make_cell(captured)
						frame.regs[spec.index] = captured
					end

					capture_values[index] = captured
				else
					capture_values[index] = frame.captures[spec.index]
				end
			end

			frame.regs[instruction.a] = build_vm_closure(proto, frame.scope, capture_values)
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_NUM_ADD then
			frame.regs[instruction.a] = builtins.numeric_add(frame.regs[instruction.b], frame.regs[instruction.c])
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_NUM_SUB then
			frame.regs[instruction.a] = builtins.numeric_sub(frame.regs[instruction.b], frame.regs[instruction.c])
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_NUM_EQ then
			frame.regs[instruction.a] = builtins.components_equal(frame.regs[instruction.b], frame.regs[instruction.c])
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_NUM_LT then
			frame.regs[instruction.a] = builtins.expect_real_number("<", frame.regs[instruction.b])
				< builtins.expect_real_number("<", frame.regs[instruction.c])
			frame.pc = frame.pc + 1
		elseif instruction.op == OP_CONS then
			local tail = frame.regs[instruction.c]
			local items = {
				frame.regs[instruction.b],
			}

			if value.is_list(tail) then
				for _, item in ipairs(tail.items) do
					items[#items + 1] = item
				end

				frame.regs[instruction.a] = value.list(items, tail.tail)
			else
				frame.regs[instruction.a] = value.list(items, tail)
			end

			frame.pc = frame.pc + 1
		elseif instruction.op == OP_CALL or instruction.op == OP_TAIL_CALL then
			local callable = frame.regs[instruction.b]
			local result = nil
			local finished = false

			if value.is_closure(callable) and callable.vm_chunk ~= nil then
				local next_frame = build_frame_from_registers(
					callable.vm_chunk,
					callable.env,
					callable.vm_captures,
					frame.regs,
					instruction.c,
					instruction.d
				)

				if instruction.op == OP_TAIL_CALL then
					local return_reg = frame.return_reg
					release_frame(frame)
					next_frame.return_reg = return_reg
					frames[#frames] = next_frame
				else
					frame.pc = frame.pc + 1
					next_frame.return_reg = instruction.a
					frames[#frames + 1] = next_frame
				end
			else
				local call_args = collect_args(frame, instruction.c, instruction.d)
				result, finished = dispatch_call(
					frames,
					frame,
					callable,
					call_args,
					execution,
					apply_callable_fn,
					instruction.a,
					instruction.op == OP_TAIL_CALL
				)
			end

			if finished then
				return result
			end
		elseif instruction.op == OP_CALL_GLOBAL or instruction.op == OP_TAIL_CALL_GLOBAL then
			local callable = load_global(frame, instruction.b)
			local result = nil
			local finished = false

			if value.is_closure(callable) and callable.vm_chunk ~= nil then
				local next_frame = build_frame_from_registers(
					callable.vm_chunk,
					callable.env,
					callable.vm_captures,
					frame.regs,
					instruction.c,
					instruction.d
				)

				if instruction.op == OP_TAIL_CALL_GLOBAL then
					local return_reg = frame.return_reg
					release_frame(frame)
					next_frame.return_reg = return_reg
					frames[#frames] = next_frame
				else
					frame.pc = frame.pc + 1
					next_frame.return_reg = instruction.a
					frames[#frames + 1] = next_frame
				end
			else
				local call_args = collect_args(frame, instruction.c, instruction.d)
				result, finished = dispatch_call(
					frames,
					frame,
					callable,
					call_args,
					execution,
					apply_callable_fn,
					instruction.a,
					instruction.op == OP_TAIL_CALL_GLOBAL
				)
			end

			if finished then
				return result
			end
		elseif instruction.op == OP_RETURN then
			local result = frame.regs[instruction.a]
			local finished_frame = table.remove(frames)
			local return_reg = finished_frame.return_reg
			release_frame(finished_frame)

			if #frames == 0 then
				return result
			end

			local caller = frames[#frames]
			caller.regs[return_reg] = result
		else
			errors.raise("runtime", "unknown vm opcode")
		end
	end

	return EMPTY_LIST
end

return vm
