local assert_mod = require("../support/assert")
local errors = require("../../lib/errors")
local session = require("../../roblox/session")

local roblox_session_spec = {}

function roblox_session_spec.run()
	local workspace = session.new()
	local ok, result = workspace:eval_buffer("(begin (define x 10) x)")

	assert_mod.truthy(ok, "buffer evaluation succeeds")
	assert_mod.equal(tostring(result), "10", "buffer evaluation returns defined value")

	ok, result = workspace:eval_line("(+ x 5)")
	assert_mod.truthy(ok, "console evaluation reuses shared scope")
	assert_mod.equal(tostring(result), "15", "console can see editor definitions")

	ok = workspace:eval_line('(print "hello" 42)')
	assert_mod.truthy(ok, "print evaluation succeeds")

	local history = workspace:get_history()
	assert_mod.equal(history[#history - 1].kind, "print", "print history entry is recorded")
	assert_mod.equal(history[#history - 1].text, '"hello" 42', "printed text is captured")
	assert_mod.equal(history[#history].kind, "result", "evaluation result is also logged")

	local before_blank = #history
	ok, result = workspace:eval_line("   ")
	assert_mod.equal(ok, false, "blank repl input is ignored")
	assert_mod.equal(result, nil, "blank repl input has no value")
	assert_mod.equal(
		#workspace:get_history(),
		before_blank,
		"blank repl input does not add history entries"
	)

	workspace:reset()
	ok, result = workspace:eval_line("x")
	assert_mod.equal(ok, false, "reset clears shared bindings")
	assert_mod.equal(
		errors.format(result),
		"name: undefined symbol 'x'",
		"reset removes prior variables"
	)

	workspace:clear_history()
	assert_mod.equal(#workspace:get_history(), 0, "clear_history drops log entries")

	local cancelled = session.new(nil, {
		step_budget = 1000,
		yield_every = 1,
		on_yield = function(execution)
			execution.cancelled = true
		end,
	})

	ok, result = cancelled:eval_line("(begin (define (forever) (forever)) (forever))")
	assert_mod.equal(ok, false, "cancelled evaluation reports failure")
	assert_mod.equal(
		errors.format(result),
		"interrupt: evaluation cancelled",
		"cancelled evaluation surfaces an interrupt error"
	)
	assert_mod.equal(cancelled:is_running(), false, "session is not left running")
	assert_mod.equal(cancelled:is_stopping(), false, "session clears stopping state after interrupt")
end

return roblox_session_spec
--[[
SPDX-License-Identifier: MPL-2.0
]]
