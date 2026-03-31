--[[
SPDX-License-Identifier: MPL-2.0
]]

local replicated_storage = game:GetService("ReplicatedStorage")
local psil = require(replicated_storage:WaitForChild("Psil"))

local scope = psil.new_env()
local result = psil.eval("(begin (define x 10) (+ x 32))", scope)

print("Psil demo:", psil.to_string(result))