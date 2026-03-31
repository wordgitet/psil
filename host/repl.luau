--[[
SPDX-License-Identifier: MPL-2.0
]]

local errors = require("../lib/errors")
local lisp = require("../lib/lisp")
local reader = require("../lib/reader")
local runner = require("./runner")

-- Minimal host REPL loop.
-- This stays intentionally small: line I/O comes from callbacks, the evaluator
-- owns semantics, and the REPL's job is mostly to preserve a shared
-- environment, print results, and surface errors cleanly.

local repl = {}

local function default_read_line(prompt)
	io.write(prompt)
	io.flush()
	return io.read("*l")
end

local function default_write_line(text)
	print(text)
end

function repl.run(options)
	local opts = options or {}
	local read_line = opts.read_line or default_read_line
	local write_line = opts.write_line or default_write_line
	local env = opts.env or runner.new_env(opts.io_adapter)
	local buffer = ""

	while true do
		local prompt = "lisp> "

		if buffer ~= "" then
			prompt = "...> "
		end

		local line = read_line(prompt)

		if line == nil then
			break
		end

		if buffer ~= "" then
			buffer = buffer .. "\n"
		end

		buffer = buffer .. line

		if string.match(buffer, "^%s*$") then
			buffer = ""
		else
			if reader.is_complete(buffer) then
				local ok, result =
					pcall(runner.eval_source, buffer, env, opts.io_adapter)

				if ok then
					write_line(lisp.to_string(result))
				else
					write_line(
						string.format("error: %s", errors.message(result))
					)
				end

				buffer = ""
			end
		end
	end
end

return repl