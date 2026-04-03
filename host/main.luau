--[[
SPDX-License-Identifier: MPL-2.0
]]

local errors = require("../lib/errors")
local lisp = require("../lib/lisp")
local repl = require("./repl")
local runner = require("./runner")

local argv = { ... }
local dialect = "scheme"
local file_path = nil

for _, argument in ipairs(argv) do
	if argument == "--cl" then
		dialect = "cl-compat"
	elseif file_path == nil then
		file_path = argument
	else
		local line = string.format("error: unexpected argument '%s'\n", argument)

		if io ~= nil and io.stderr ~= nil then
			io.stderr:write(line)
		else
			print(string.gsub(line, "\n$", ""))
		end

		os.exit(1)
	end
end

if file_path ~= nil then
	local scope = runner.new_env(nil, {
		dialect = dialect,
	})
	local ok, result = pcall(runner.run_file, file_path, scope)

	if not ok then
		local line = string.format("error: %s\n", errors.message(result))

		if io ~= nil and io.stderr ~= nil then
			io.stderr:write(line)
		else
			print(string.gsub(line, "\n$", ""))
		end

		os.exit(1)
	end

	print(lisp.to_string(result, {
		dialect = dialect,
	}))
else
	repl.run({
		dialect = dialect,
	})
end
