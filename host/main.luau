--[[
SPDX-License-Identifier: MPL-2.0
]]

local errors = require("../lib/errors")
local lisp = require("../lib/lisp")
local repl = require("./repl")
local runner = require("./runner")

local argv = { ... }

if #argv >= 1 then
	local ok, result = pcall(runner.run_file, argv[1])

	if not ok then
		local line = string.format("error: %s\n", errors.message(result))

		if io ~= nil and io.stderr ~= nil then
			io.stderr:write(line)
		else
			print(string.gsub(line, "\n$", ""))
		end

		os.exit(1)
	end

	print(lisp.to_string(result))
else
	repl.run()
end