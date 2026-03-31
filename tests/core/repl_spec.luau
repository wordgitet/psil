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

	assert_mod.equal(prompts[1], "lisp> ", "repl uses the primary prompt")
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
end

return repl_spec
--[[
SPDX-License-Identifier: MPL-2.0
]]
