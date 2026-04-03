--[[
SPDX-License-Identifier: MPL-2.0
]]

local lisp = require("../lib/lisp")
local runner = require("../host/runner")

local argv = { ... }
local mode = argv[1]
local path = argv[2]

if mode == nil or path == nil then
	io.stderr:write("usage: lua bench/psil_bench.lua <scheme-auto|scheme-interp|cl-interp> <file>\n")
	os.exit(1)
end

local dialect = "scheme"
local engine = "auto"

if mode == "scheme-auto" then
	dialect = "scheme"
	engine = "auto"
elseif mode == "scheme-interp" then
	dialect = "scheme"
	engine = "interp"
elseif mode == "cl-interp" then
	dialect = "cl-compat"
	engine = "interp"
else
	io.stderr:write(string.format("unknown benchmark mode '%s'\n", mode))
	os.exit(1)
end

local handle, open_err = io.open(path, "r")

if handle == nil then
	io.stderr:write((open_err or string.format("unable to open '%s'", path)) .. "\n")
	os.exit(1)
end

local source = handle:read("*a")
handle:close()

local scope = runner.new_env(nil, {
	dialect = dialect,
})
local execution = lisp.new_execution({
	engine = engine,
	dialect = dialect,
})

lisp.eval(source, scope, execution)
