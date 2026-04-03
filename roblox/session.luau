--[[
SPDX-License-Identifier: MPL-2.0
]]

local errors = require("../lib/errors")
local dialect_hint = require("../lib/dialect_hint")
local lisp = require("../lib/lisp")
local roblox_io = require("./io")

local session = {}
local session_methods = {}
local default_options = {
	step_budget = 200000,
	yield_every = 2000,
}

local function is_blank(source)
	return string.match(source, "^%s*$") ~= nil
end

local function emit(self, kind, text, target)
	local entry = {
		kind = kind,
		text = text,
		target = target or "both",
	}

	table.insert(self.history, entry)

	if type(self.callbacks.on_output) == "function" then
		self.callbacks.on_output(entry)
	end

	return entry
end

local function notify_state(self)
	if type(self.callbacks.on_state_change) == "function" then
		self.callbacks.on_state_change({
			running = self.running,
			stopping = self.stopping,
		})
	end
end

local function set_state(self, running, stopping)
	self.running = running
	self.stopping = stopping
	notify_state(self)
end

local function new_scope(self)
	local scope = lisp.new_env(nil, {
		dialect = self.dialect,
	})

	lisp.add_builtins(scope, roblox_io.new({
		write = function(_, text)
			emit(self, "print", text, self.active_target or "both")
		end,
	}))

	return scope
end

local function default_yield_callback()
	if task ~= nil and type(task.wait) == "function" then
		task.wait()
	end
end

local function new_execution(self)
	return lisp.new_execution({
		dialect = self.dialect,
		step_budget = self.options.step_budget,
		yield_every = self.options.yield_every,
		on_yield = self.options.on_yield or default_yield_callback,
	})
end

local function evaluate(self, source, mode)
	if type(source) ~= "string" then
		errors.raise("type", "expected source to be a string")
	end

	if self.running then
		local err = {
			kind = "state",
			message = "evaluation already running",
		}

		emit(self, "error", errors.format(err), "both")
		return false, err
	end

	if is_blank(source) then
		return false, nil
	end

	local mismatch = dialect_hint.build_error(source, self.dialect, "roblox")

	if mismatch ~= nil then
		emit(self, "error", errors.format(mismatch), mode == "buffer" and "editor" or "repl")
		return false, mismatch
	end

	local execution = new_execution(self)

	self.active_target = mode == "buffer" and "editor" or "repl"
	self.current_execution = execution
	set_state(self, true, false)

	local ok, result = pcall(lisp.eval, source, self.scope, execution)

	self.current_execution = nil

	if not ok then
		local message = errors.format(result)
		emit(self, "error", message, self.active_target)
		self.active_target = nil
		set_state(self, false, false)
		return false, result
	end

	local printed_during_eval = false

	for index = #self.history, 1, -1 do
		local entry = self.history[index]

		if entry.kind == "print" then
			printed_during_eval = true
			break
		end

		if entry.kind ~= "status" then
			break
		end
	end

	local result_text = lisp.to_string(result, {
		dialect = self.dialect,
	})

	if not (mode == "buffer" and printed_during_eval) then
		emit(self, "result", result_text, self.active_target)
	end

	self.active_target = nil
	set_state(self, false, false)
	return true, result
end

function session_methods.eval_buffer(self, source)
	return evaluate(self, source, "buffer")
end

function session_methods.eval_line(self, source)
	return evaluate(self, source, "repl")
end

function session_methods.reset(self)
	if self.running then
		return self.scope
	end

	self.scope = new_scope(self)
	return self.scope
end

function session_methods.clear_history(self)
	if self.running then
		return
	end

	for index = #self.history, 1, -1 do
		self.history[index] = nil
	end

	if type(self.callbacks.on_clear) == "function" then
		self.callbacks.on_clear()
	end
end

function session_methods.get_history(self)
	local copy = {}

	for index, entry in ipairs(self.history) do
		copy[index] = {
			kind = entry.kind,
			text = entry.text,
		}
	end

	return copy
end

function session_methods.get_env(self)
	return self.scope
end

function session_methods.cancel(self)
	if self.current_execution == nil or self.current_execution.cancelled then
		return false
	end

	self.current_execution.cancelled = true
	set_state(self, true, true)
	return true
end

function session_methods.is_running(self)
	return self.running
end

function session_methods.is_stopping(self)
	return self.stopping
end

function session.new(callbacks, options)
	local self = setmetatable({
		callbacks = callbacks or {},
		dialect = "scheme",
		history = {},
		options = {
			step_budget = default_options.step_budget,
			yield_every = default_options.yield_every,
			on_yield = nil,
		},
		scope = nil,
		running = false,
		stopping = false,
		current_execution = nil,
		active_target = nil,
	}, {
		__index = session_methods,
	})

	if options ~= nil then
		for name, item in pairs(options) do
			if name == "dialect" then
				self.dialect = item
			else
				self.options[name] = item
			end
		end
	end

	self:reset()
	return self
end

return session
