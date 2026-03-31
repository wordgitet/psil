--[[
SPDX-License-Identifier: MPL-2.0
]]

local host_io = require("./io")
local lisp = require("../lib/lisp")

local runner = {}

local function read_file(path)
	local handle, open_err = io.open(path, "r")

	if handle == nil then
		error(open_err or string.format("unable to open '%s'", path))
	end

	local source = handle:read("*a")
	handle:close()
	return source
end

function runner.new_env(io_adapter)
	local scope = lisp.new_env(nil)
	lisp.add_builtins(scope, io_adapter or host_io.new())
	return scope
end

function runner.eval_source(source, scope, io_adapter)
	local env_scope = scope or runner.new_env(io_adapter)
	return lisp.eval(source, env_scope)
end

function runner.run_file(path, scope, io_adapter)
	return runner.eval_source(read_file(path), scope, io_adapter)
end

return runner