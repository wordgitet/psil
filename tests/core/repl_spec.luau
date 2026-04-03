--[[
SPDX-License-Identifier: MPL-2.0
]]

local assert_mod = require("../support/assert")
local repl = require("../../host/repl")

local repl_spec = {}

function repl_spec.run()
	local inputs = {
		"(define x 4)",
		"(+ x 3)",
		nil,
	}
	local prompts = {}
	local outputs = {}
	local index = 0

	repl.run({
		read_line = function(prompt)
			table.insert(prompts, prompt)
			index = index + 1
			return inputs[index]
		end,
		write_line = function(text)
			table.insert(outputs, text)
		end,
	})

	assert_mod.equal(prompts[1], "scheme> ", "repl uses the scheme prompt by default")
	assert_mod.equal(outputs[1], "4", "repl prints define result")
	assert_mod.equal(
		outputs[2],
		"7",
		"repl evaluates follow-up forms in the same environment"
	)

	local multiline_inputs = {
		"(begin",
		"(define y 8)",
		"(+ y 1))",
		nil,
	}
	local multiline_outputs = {}
	local multiline_prompts = {}
	local multiline_index = 0

	repl.run({
		read_line = function(prompt)
			table.insert(multiline_prompts, prompt)
			multiline_index = multiline_index + 1
			return multiline_inputs[multiline_index]
		end,
		write_line = function(text)
			table.insert(multiline_outputs, text)
		end,
	})

	assert_mod.equal(
		multiline_prompts[2],
		"...> ",
		"repl switches prompts while a form is incomplete"
	)
	assert_mod.equal(
		multiline_outputs[1],
		"9",
		"repl evaluates multiline forms once complete"
	)

	local cl_prompts = {}
	local cl_outputs = {}
	local cl_index = 0
	local cl_inputs = {
		"t",
		nil,
	}

	repl.run({
		dialect = "cl-compat",
		read_line = function(prompt)
			table.insert(cl_prompts, prompt)
			cl_index = cl_index + 1
			return cl_inputs[cl_index]
		end,
		write_line = function(text)
			table.insert(cl_outputs, text)
		end,
	})

	assert_mod.equal(cl_prompts[1], "cl> ", "repl uses the CL prompt in cl-compat mode")
	assert_mod.equal(cl_outputs[1], "t", "cl-compat repl prints CL truth values")

	local mismatch_outputs = {}
	local mismatch_index = 0
	local mismatch_inputs = {
		"(defun fib (n) n)",
		nil,
	}

	repl.run({
		read_line = function()
			mismatch_index = mismatch_index + 1
			return mismatch_inputs[mismatch_index]
		end,
		write_line = function(text)
			table.insert(mismatch_outputs, text)
		end,
	})

	assert_mod.equal(
		mismatch_outputs[1],
		"error: this looks like Common Lisp code, but the current session is in Scheme mode; hint: restart with --cl",
		"repl surfaces a CL hint when CL code is entered in Scheme mode"
	)

	local reverse_mismatch_outputs = {}
	local reverse_mismatch_index = 0
	local reverse_mismatch_inputs = {
		"(define x 1)",
		nil,
	}

	repl.run({
		dialect = "cl-compat",
		read_line = function()
			reverse_mismatch_index = reverse_mismatch_index + 1
			return reverse_mismatch_inputs[reverse_mismatch_index]
		end,
		write_line = function(text)
			table.insert(reverse_mismatch_outputs, text)
		end,
	})

	assert_mod.equal(
		reverse_mismatch_outputs[1],
		"error: this looks like Scheme code, but the current session is in Common Lisp mode; hint: restart without --cl",
		"repl surfaces a Scheme hint when Scheme code is entered in CL mode"
	)
end

return repl_spec
