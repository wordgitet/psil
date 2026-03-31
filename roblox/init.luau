--[[
SPDX-License-Identifier: MPL-2.0
]]

local lisp = require("../lib/lisp")
local roblox_io = require("./io")
local session = require("./session")

local roblox_lisp = {}

function roblox_lisp.new_env(callbacks)
	local scope = lisp.new_env(nil)
	lisp.add_builtins(scope, roblox_io.new(callbacks))
	return scope
end

function roblox_lisp.parse(source)
	return lisp.parse(source)
end

function roblox_lisp.eval(source_or_form, scope)
	return lisp.eval(source_or_form, scope or roblox_lisp.new_env())
end

function roblox_lisp.expand(source_or_form, scope)
	return lisp.expand(source_or_form, scope or roblox_lisp.new_env())
end

function roblox_lisp.to_string(item)
	return lisp.to_string(item)
end

function roblox_lisp.new_session(callbacks)
	return session.new(callbacks)
end

return roblox_lisp