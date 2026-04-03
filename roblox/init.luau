--[[
SPDX-License-Identifier: MPL-2.0
]]

local lisp = require("../lib/lisp")
local roblox_io = require("./io")
local session = require("./session")

local roblox_lisp = {}

function roblox_lisp.new_env(callbacks, options)
	local scope = lisp.new_env(nil, options)
	lisp.add_builtins(scope, roblox_io.new(callbacks))
	return scope
end

function roblox_lisp.parse(source, options)
	return lisp.parse(source, options)
end

function roblox_lisp.eval(source_or_form, scope, options)
	return lisp.eval(source_or_form, scope or roblox_lisp.new_env(nil, options))
end

function roblox_lisp.expand(source_or_form, scope)
	return lisp.expand(source_or_form, scope or roblox_lisp.new_env())
end

function roblox_lisp.to_string(item, options)
	return lisp.to_string(item, options)
end

function roblox_lisp.new_session(callbacks, options)
	return session.new(callbacks, options)
end

return roblox_lisp
