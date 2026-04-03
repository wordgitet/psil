--[[
SPDX-License-Identifier: MPL-2.0
]]

local errors = require("../lib/errors")
local dialect_hint = require("../lib/dialect_hint")
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
	local source = runner.read_file(file_path)
	local hint = dialect_hint.build_error(source, dialect, "host")

	if hint ~= nil then
		local line = string.format("error: %s\n", errors.message(hint))

		if io ~= nil and io.stderr ~= nil then
			io.stderr:write(line)
		else
			print(string.gsub(line, "\n$", ""))
		end

		os.exit(1)
	end

	local scope = runner.new_env(nil, {
		dialect = dialect,
	})
	local ok, result = pcall(runner.eval_source, source, scope)

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
